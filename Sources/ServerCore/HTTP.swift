import Foundation
import Network

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let length: Int
    public static let bodyLimit = 25 * 1024 * 1024
    public init(header: Data) throws {
        guard let text = String(data: header, encoding: .utf8) else { throw APIError("Invalid HTTP headers") }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0", first[1].hasPrefix("/") else { throw APIError("Invalid HTTP request line") }
        method = String(first[0]); path = String(first[1].split(separator: "?", maxSplits: 1)[0])
        var fields = [String: String]()
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw APIError("Invalid HTTP header") }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }), fields[key] == nil else { throw APIError("Invalid or duplicate HTTP header") }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["transfer-encoding"] == nil else { throw APIError(411, "Send Content-Length; chunked request bodies are not supported") }
        if let raw = fields["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(raw), n >= 0 else { throw APIError("Invalid Content-Length") }
            guard n <= Self.bodyLimit else { throw APIError(413, "Request body exceeds 25 MiB") }
            length = n
        } else {
            guard method != "POST" else { throw APIError(411, "Content-Length is required") }
            length = 0
        }
        headers = fields
    }
}
public final class HTTPServer {
    private let listener: NWListener
    private let network = DispatchQueue(label: "sensenova.network", attributes: .concurrent)
    private let jobs: JobQueue
    private let engine: Engine
    private let config: Configuration
    private let key: String
    private let lock = NSLock()
    private var clients: [UUID: Client] = [:]
    public init(config: Configuration, key: String, jobs: JobQueue, engine: Engine) throws {
        self.config = config; self.key = key; self.jobs = jobs; self.engine = engine
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: config.port)!)
        listener = try NWListener(using: parameters)
    }
    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            guard self.clients.count < 64 else { self.lock.unlock(); connection.cancel(); return }
            let id = UUID()
            let client = Client(connection: connection, key: self.key, network: self.network, route: self.route) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.clients.removeValue(forKey: id); self.lock.unlock()
            }
            self.clients[id] = client
            self.lock.unlock()
            client.start()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { print("Listening on \(self.config.host):\(self.config.port)") }
            if case .failed(let error) = state { fputs("Listener failed: \(error)\n", stderr); exit(1) }
        }
        listener.start(queue: network)
    }
    public func stop() { listener.cancel() }
    public func waitForResponsesAndExit() {
        network.async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                self.lock.lock(); let empty = self.clients.isEmpty; self.lock.unlock()
                if empty { exit(0) }
                Thread.sleep(forTimeInterval: 0.02)
            }
            exit(0)
        }
    }
    private func route(_ request: HTTPRequest, _ body: Data, _ client: Client) {
        do {
            if request.path == "/health", request.method == "GET" { client.respond(jobs.health); return }
            if request.path == "/v1/models", request.method == "GET" {
                client.respond(["object": "list", "data": [["id": config.modelID, "object": "model", "created": 0, "owned_by": "local"]]]); return
            }
            guard request.method == "POST" else { throw APIError(404, "Route not found") }
            let work: () throws -> Void
            switch request.path {
            case "/v1/chat/completions":
                try requireJSON(request)
                let chat = try ChatRequest(data: body)
                let id = "chatcmpl-" + UUID().uuidString
                let created = Int(Date().timeIntervalSince1970)
                if chat.stream {
                    work = {
                        client.beginSSE()
                        func chunk(_ delta: [String: Any], finish: Any = NSNull(), usage: Any? = nil) {
                            var value: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": self.config.modelID,
                                "choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
                            if let usage { value["usage"] = usage }
                            client.event(value)
                        }
                        chunk(["role": "assistant"])
                        do {
                            let result = try self.engine.chat(chat) { chunk(["content": $0]) }
                            chunk([:], finish: result["finish_reason"]!, usage: result["usage"])
                        } catch { client.event((error as? APIError ?? APIError(500, "Inference failed")).json) }
                        client.endSSE()
                    }
                } else {
                    work = {
                        let result = try self.engine.chat(chat)
                        client.respond(["id": id, "object": "chat.completion", "created": created, "model": self.config.modelID,
                            "choices": [["index": 0, "message": ["role": "assistant", "content": result["content"]!], "finish_reason": result["finish_reason"]!]], "usage": result["usage"]!])
                    }
                }
            case "/v1/images/generations":
                try requireJSON(request)
                let image = try ImageRequest(data: body, quality: config.quality)
                work = { client.respond(try self.engine.image(image)) }
            case "/v1/images/edits":
                let form = try Multipart(data: body, contentType: request.headers["content-type"] ?? "")
                let image = try ImageRequest(fields: form.fields, image: form.image, quality: config.quality)
                work = { client.respond(try self.engine.image(image)) }
            default: throw APIError(404, "Route not found")
            }
            try jobs.submit {
                autoreleasepool {
                    do { try work() }
                    catch let error as APIError { client.respond(error.json, status: error.status) }
                    catch { fputs("Inference error: \(error)\n", stderr); client.respond(APIError(500, "Inference failed").json, status: 500) }
                }
            }
        } catch let error as APIError { client.respond(error.json, status: error.status) }
        catch { client.respond(APIError(400, "Invalid request").json, status: 400) }
    }
    private func requireJSON(_ request: HTTPRequest) throws {
        guard request.headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/json" else { throw APIError(415, "Expected application/json") }
    }
}
private final class Client {
    private let connection: NWConnection
    private let key: String
    private let network: DispatchQueue
    private let route: (HTTPRequest, Data, Client) -> Void
    private let closed: () -> Void
    private let receiveQueue = DispatchQueue(label: "sensenova.http.receive")
    private var buffer = Data()
    private var request: HTTPRequest?
    private var timeout: DispatchWorkItem?
    init(connection: NWConnection, key: String, network: DispatchQueue, route: @escaping (HTTPRequest, Data, Client) -> Void, closed: @escaping () -> Void) {
        self.connection = connection; self.key = key; self.network = network; self.route = route; self.closed = closed
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.closed() }
            if case .failed = state { self?.connection.cancel() }
        }
        connection.start(queue: receiveQueue)
        let timeout = DispatchWorkItem { [weak self] in self?.respond(APIError(408, "Request upload timed out").json, status: 408) }
        self.timeout = timeout
        receiveQueue.asyncAfter(deadline: .now() + 30, execute: timeout)
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            do {
                if request == nil {
                    if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        guard range.upperBound <= 16384 else { throw APIError(431, "Headers exceed 16 KiB") }
                        let parsed = try HTTPRequest(header: Data(buffer[..<range.lowerBound]))
                        if parsed.path != "/health" { try Auth.check(parsed.headers["authorization"], key: key) }
                        request = parsed
                        buffer.removeSubrange(..<range.upperBound)
                        if parsed.headers["expect"]?.lowercased() == "100-continue" { send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
                    } else if buffer.count > 16384 { throw APIError(431, "Headers exceed 16 KiB") }
                }
                if let request, buffer.count >= request.length {
                    timeout?.cancel(); timeout = nil
                    guard buffer.count == request.length else { throw APIError("Pipelining or excess body bytes are not supported") }
                    let body = buffer; buffer = Data()
                    network.async { self.route(request, body, self) }
                    return
                }
                if complete || error != nil { connection.cancel(); return }
                receive()
            } catch let error as APIError { respond(error.json, status: error.status) }
            catch { respond(APIError(400, "Invalid HTTP request").json, status: 400) }
        }
    }
    private func send(_ data: Data, final: Bool = false) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if final || error != nil { self?.connection.cancel() }
        })
    }
    func respond(_ value: Any, status: Int = 200) {
        timeout?.cancel()
        let data = jsonData(value)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 408: "Request Timeout", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        if status == 401 { header += "WWW-Authenticate: Bearer\r\n" }
        if status == 429 { header += "Retry-After: 5\r\n" }
        send(Data((header + "\r\n").utf8) + data, final: true)
    }
    func beginSSE() { send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n".utf8)) }
    func event(_ value: Any) { send(Data("data: ".utf8) + jsonData(value) + Data("\n\n".utf8)) }
    func endSSE() { send(Data("data: [DONE]\n\n".utf8), final: true) }
}
