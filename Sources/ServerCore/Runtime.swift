import Foundation
import Security
import Darwin
import MLX
import SenseNovaU1

public struct Configuration: Sendable {
    public var host = "0.0.0.0"
    public var port: UInt16 = 8003
    public var weights = NSHomeDirectory() + "/sensenova/SenseNova-U1.5-8B-MoT-8step-v2-8bit"
    public var keyFile = NSHomeDirectory() + "/.sensenova/api-key"
    public var idleMinutes: Double = 0
    public var quality: Bool { weights.lowercased().contains("bf16") }
    public var modelID: String { quality ? "sensenova-u1.5-bf16" : "sensenova-u1.5-8step" }
    public init(arguments: [String] = Array(CommandLine.arguments.dropFirst()), env: [String: String] = ProcessInfo.processInfo.environment) throws {
        var values = [String: String]()
        for name in ["host", "port", "weights", "api-key-file", "idle-unload-minutes"] {
            values[name] = env["SENSENOVA_" + name.replacingOccurrences(of: "-", with: "_").uppercased()]
        }
        var i = 0
        while i < arguments.count {
            let name = String(arguments[i].dropFirst(2))
            guard arguments[i].hasPrefix("--"), ["host", "port", "weights", "api-key-file", "idle-unload-minutes"].contains(name), i + 1 < arguments.count else { throw APIError("Unknown or missing option: \(arguments[i])") }
            values[name] = arguments[i + 1]; i += 2
        }
        if let v = values["host"] { host = v }
        if let v = values["port"] { guard let p = UInt16(v), p > 0 else { throw APIError("Invalid port") }; port = p }
        if let v = values["weights"] { weights = (v as NSString).expandingTildeInPath }
        if let v = values["api-key-file"] { keyFile = (v as NSString).expandingTildeInPath }
        if let v = values["idle-unload-minutes"] { guard let n = Double(v), n.isFinite, n >= 0 else { throw APIError("Invalid idle timeout") }; idleMinutes = n }
    }
}
public enum Auth {
    public static func loadKey(path: String) throws -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 {
            var bytes = [UInt8](repeating: 0, count: 36)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { close(fd); unlink(path); throw APIError(500, "Cannot generate API key") }
            let data = Data((Data(bytes).base64EncodedString() + "\n").utf8)
            let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard count == data.count else { unlink(path); throw APIError(500, "Cannot write API key") }
        } else if errno != EEXIST { throw APIError(500, "Cannot create API key file") }
        let readFD = open(path, O_RDONLY | O_NOFOLLOW)
        guard readFD >= 0 else { throw APIError(500, "Cannot open API key file") }
        defer { close(readFD) }
        var info = stat()
        guard fstat(readFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_uid == getuid(), info.st_size <= 4096 else { throw APIError(500, "API key file must be a private regular file owned by this user (mode 600)") }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(readFD, &buffer, buffer.count)
        guard count > 0, let key = String(bytes: buffer.prefix(count), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), key.utf8.count >= 40 else { throw APIError(500, "API key must contain at least 40 characters") }
        return key
    }
    public static func check(_ header: String?, key: String) throws {
        let expected = Array(("Bearer " + key).utf8), actual = Array((header ?? "").utf8)
        var difference = expected.count ^ actual.count
        for i in expected.indices { difference |= Int(expected[i] ^ (i < actual.count ? actual[i] : 0)) }
        guard difference == 0 else { throw APIError(401, "Invalid or missing Bearer API key") }
    }
}
// Mutable accounting is protected by lock; GPU execution is confined to worker.
public final class JobQueue: @unchecked Sendable {
    public let worker = DispatchQueue(label: "sensenova.gpu")
    private let lock = NSLock()
    private var outstanding = 0
    private var loaded = false
    private var accepting = true
    public init() {}
    public func reserve() throws {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { throw APIError(503, "Server is shutting down") }
        guard outstanding < 9 else { throw APIError(429, "GPU queue is full (one active plus eight waiting)") }
        outstanding += 1
    }
    public func submit(_ work: @escaping () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { throw APIError(503, "Server is shutting down") }
        guard outstanding < 9 else { throw APIError(429, "GPU queue is full (one active plus eight waiting)") }
        outstanding += 1
        worker.async { defer { self.finish() }; work() }
    }
    public func drain(_ completion: @escaping () -> Void) {
        lock.lock(); accepting = false
        worker.async(execute: DispatchWorkItem(block: completion))
        lock.unlock()
    }
    public func finish() { lock.lock(); outstanding -= 1; lock.unlock() }
    public func setLoaded(_ value: Bool) { lock.lock(); loaded = value; lock.unlock() }
    public var health: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["status": "ok", "model_loaded": loaded, "queue": max(0, outstanding - 1)]
    }
}
public enum PNG {
    public static func encode(_ tensor: MLXArray) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try SenseNovaImageIO.savePNG(tensor, to: url)
        return try Data(contentsOf: url)
    }
}
// Compare UTF-8 bytes: adding a combining mark / ZWJ changes Character boundaries.
// Tokenizer decoding may end in a replacement character until the next token completes UTF-8.
struct DecodedTextStream {
    private var emitted = ""
    mutating func delta(_ text: String, final: Bool = false) -> String? {
        guard (final || !text.hasSuffix("\u{fffd}")), text.utf8.starts(with: emitted.utf8) else { return nil }
        let suffix = String(decoding: text.utf8.dropFirst(emitted.utf8.count), as: UTF8.self)
        emitted = text
        return suffix.isEmpty ? nil : suffix
    }
}
// The non-Sendable upstream model/tokenizer never leave jobs.worker after initialization.
// Preconditions on every entry point enforce that confinement.
public final class Engine: @unchecked Sendable {
    private let config: Configuration
    private let jobs: JobQueue
    private var model: NEOChatModel?
    private let tokenizer: SenseNovaTokenizer
    private var lastUse = Date()
    public init(config: Configuration, jobs: JobQueue, tokenizer: SenseNovaTokenizer) {
        self.config = config; self.jobs = jobs; self.tokenizer = tokenizer
    }
    public func load() throws {
        dispatchPrecondition(condition: .onQueue(jobs.worker))
        if model == nil {
            // Bound allocator retention independently of the resident model / live tensors.
            Memory.cacheLimit = 1 << 30
            let start = Date()
            model = try WeightLoading.loadArtifact(from: URL(fileURLWithPath: config.weights))
            jobs.setLoaded(true)
            print("Model loaded in \(Date().timeIntervalSince(start))s; MLX active \(Memory.activeMemory) bytes")
        }
    }
    public func unloadIfIdle() {
        dispatchPrecondition(condition: .onQueue(jobs.worker))
        if config.idleMinutes > 0 && Date().timeIntervalSince(lastUse) >= config.idleMinutes * 60 {
            model = nil; Memory.clearCache(); jobs.setLoaded(false)
        }
    }
    /// One line per job. `type` is chat (text only), vqa (chat with images), generate or edit;
    /// `ok`/`error` because the line is written from a defer, also when the job throws.
    private func done(_ start: Date, type: String, detail: String, ok: Bool) {
        lastUse = Date(); Memory.clearCache()
        print("Job finished in \(lastUse.timeIntervalSince(start))s; type=\(type) \(ok ? "ok" : "error")\(detail.isEmpty ? "" : " " + detail); MLX active \(Memory.activeMemory), peak \(Memory.peakMemory) bytes")
    }
    public func chat(_ request: ChatRequest, onContent: ((String) -> Void)? = nil) throws -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(jobs.worker))
        let start = Date(); var type = "chat", detail = "", ok = false
        defer { done(start, type: type, detail: detail, ok: ok) }
        try load()
        var prompt = ""; var images: [EditImage] = []
        for message in request.messages {
            let refs = try message.images.map { try SenseNovaImageIO.loadEditImage(data: $0) }
            let text = try Conversation.expandImagePlaceholders(prompt: message.text, imageTokenCounts: refs.map(\.tokenCount))
            prompt += Conversation.imStart + message.role + "\n" + text + Conversation.sep
            images += refs
        }
        if !images.isEmpty { type = "vqa" }
        detail = "images=\(images.count) stream=\(onContent != nil ? "yes" : "no")"
        prompt += Conversation.imStart + "assistant\n<think>\n\n</think>\n\n"
        let ids = tokenizer.encode(prompt)
        guard ids.count <= 16384 else { throw APIError("Prompt exceeds server limit of 16384 tokens including image tokens") }
        var sampling = SamplingParams()
        sampling.maxNewTokens = request.maxTokens; sampling.temperature = request.temperature; sampling.topP = request.topP
        var seen: [Int32] = []; var stream = DecodedTextStream()
        let tokens = try model!.chat(ids: ids, images: images, params: sampling) { id in
            guard let onContent else { return }
            seen.append(id)
            let text = self.tokenizer.decode(seen)
            if let delta = stream.delta(text) { onContent(delta) }
        }
        let text = tokenizer.decode(tokens)
        if onContent != nil, let delta = stream.delta(text, final: true) { onContent?(delta) }
        detail += " prompt_tokens=\(ids.count) completion_tokens=\(tokens.count)"; ok = true
        return ["content": text, "finish_reason": tokens.count == request.maxTokens ? "length" : "stop", "usage": ["prompt_tokens": ids.count, "completion_tokens": tokens.count, "total_tokens": ids.count + tokens.count]]
    }
    public func image(_ request: ImageRequest) throws -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(jobs.worker))
        let start = Date(); var ok = false
        defer { done(start, type: request.image == nil ? "generate" : "edit",
                     detail: "\(request.width)x\(request.height) steps=\(request.steps) cfg=\(request.cfg)", ok: ok) }
        try load()
        var params = T2IParams(); params.numSteps = request.steps; params.cfgScale = request.cfg; params.seed = request.seed
        let result: MLXArray
        if let data = request.image {
            let image = try SenseNovaImageIO.loadEditImage(data: data)
            let counts = [image.tokenCount]
            let cond = try tokenizer.encode(Conversation.editCondPrompt(request.prompt, imageTokenCounts: counts))
            let imgCond = try tokenizer.encode(Conversation.editImgCondPrompt(imageTokenCounts: counts))
            result = try model!.it2iGenerate(condIds: cond, imgCondIds: imgCond, uncondIds: nil, images: [image], width: request.width, height: request.height, params: params, imgCfgScale: 1)
        } else {
            let ids = tokenizer.t2iIDs(prompt: request.prompt)
            result = try model!.t2iGenerate(condIds: ids.cond, uncondIds: request.cfg > 1 ? ids.uncond : nil, width: request.width, height: request.height, params: params)
        }
        eval(result)
        let png = try PNG.encode(result).base64EncodedString(); ok = true
        return ["created": Int(Date().timeIntervalSince1970), "data": [["b64_json": png]]]
    }
}
