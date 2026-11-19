import Foundation
import ImageIO

public struct APIError: Error {
    public let status: Int
    public let message: String
    public init(_ message: String) { self.init(400, message) }
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var json: [String: Any] { ["error": ["message": message, "type": status == 401 ? "authentication_error" : status == 429 ? "rate_limit_error" : status >= 500 ? "server_error" : "invalid_request_error"]] }
}
public func jsonData(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func object(_ data: Data) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data), let dict = value as? [String: Any] else { throw APIError("Expected a JSON object") }
    return dict
}
func integer(_ value: Any?, default fallback: Int, range: ClosedRange<Int>, name: String) throws -> Int {
    guard let value else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue, range.contains(number.intValue) else { throw APIError("Invalid \(name); expected integer in \(range)") }
    return number.intValue
}
import CoreFoundation
func number(_ value: Any?, default fallback: Float, range: ClosedRange<Float>, name: String) throws -> Float {
    guard let value else { return fallback }
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.floatValue.isFinite, range.contains(n.floatValue) else { throw APIError("Invalid \(name)") }
    return n.floatValue
}
func safeText(_ text: String) throws -> String {
    // Raw special tokens can violate upstream's image-splice preconditions.
    for token in ["<img>", "</img>", "<IMG_CONTEXT>", "<image>", "<|im_start|>", "<|im_end|>"] {
        if text.contains(token) { throw APIError("Reserved model token in text: \(token)") }
    }
    return text
}
public func validateImage(_ data: Data) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 20_000_000,
          CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw APIError("Invalid image or image exceeds 8192 per side / 20 million pixels") }
}
public func decodeDataURI(_ uri: String) throws -> Data {
    guard uri.hasPrefix("data:image/"), let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
          let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])), !data.isEmpty else { throw APIError("image_url must be a base64 image data URI; http(s) URLs are not supported") }
    try validateImage(data)
    return data
}
public struct Message {
    public let role: String
    public let text: String
    public let images: [Data]
}
public struct ChatRequest {
    public let messages: [Message]
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float
    public let stream: Bool
    public init(data: Data) throws {
        let obj = try object(data)
        guard let raw = obj["messages"] as? [[String: Any]], !raw.isEmpty, raw.count <= 128 else { throw APIError("messages must contain 1...128 messages") }
        var parsed: [Message] = []
        var imageCount = 0
        for message in raw {
            guard let role = message["role"] as? String, ["system", "user", "assistant"].contains(role) else { throw APIError("Supported roles: system, user, assistant") }
            var text = ""; var images: [Data] = []
            if let string = message["content"] as? String { text = try safeText(string) }
            else if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    if part["type"] as? String == "text", let string = part["text"] as? String { text += try safeText(string) }
                    else if part["type"] as? String == "image_url", role == "user", let image = part["image_url"] as? [String: Any], let url = image["url"] as? String {
                        images.append(try decodeDataURI(url))
                    } else { throw APIError("Invalid content part; images are supported in user messages only") }
                }
                // The model's VQA format puts the images before the question (upstream
                // sensenova-cli: "<image>\n" + prompt). With the question first and greedy
                // decoding, some images make the model end its answer at the first token.
                text = String(repeating: "<image>\n", count: images.count) + text
            } else { throw APIError("content must be a string or text/image_url parts") }
            imageCount += images.count
            parsed.append(Message(role: role, text: text, images: images))
        }
        guard parsed.last?.role == "user", imageCount <= 4 else { throw APIError("End with a user message; at most four images per request") }
        messages = parsed
        maxTokens = try integer(obj["max_tokens"], default: 1536, range: 1...4096, name: "max_tokens")
        temperature = try number(obj["temperature"], default: 0, range: 0...2, name: "temperature")
        topP = try number(obj["top_p"], default: 1, range: 0.001...1, name: "top_p")
        if let value = obj["stream"] {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw APIError("stream must be boolean") }
        }
        stream = obj["stream"] as? Bool ?? false
    }
}
public struct ImageRequest {
    public let prompt: String
    public let width: Int
    public let height: Int
    public let steps: Int
    public let cfg: Float
    public let seed: UInt64
    public let image: Data?
    public init(fields: [String: Any], image: Data? = nil, quality: Bool = false) throws {
        guard let prompt = fields["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError("prompt is required") }
        self.prompt = try safeText(prompt)
        guard prompt.count <= 16000 else { throw APIError("prompt is too long") }
        let size = fields["size"] as? String ?? "1024x1024"
        let components = size.split(separator: "x", omittingEmptySubsequences: false)
        let dimensions = components.compactMap { Int($0) }
        guard components.count == 2, dimensions.count == 2, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { throw APIError("size must be WxH") }
        let w = dimensions[0], h = dimensions[1]
        guard w >= 256, h >= 256, w <= 2048, h <= 2048, w % 32 == 0, h % 32 == 0, max(w, h) <= min(w, h) * 4 else { throw APIError("size must be multiples of 32, 256...2048 per side, aspect ratio <= 4") }
        width = w; height = h
        _ = try integer(fields["n"], default: 1, range: 1...1, name: "n")
        guard fields["response_format"] == nil || fields["response_format"] as? String == "b64_json" else { throw APIError("Only response_format=b64_json is supported") }
        steps = try integer(fields["steps"], default: quality ? 50 : 8, range: 1...100, name: "steps")
        cfg = try number(fields["cfg"], default: quality ? 4 : 1, range: 1...10, name: "cfg")
        seed = UInt64(try integer(fields["seed"], default: 42, range: 0...Int.max, name: "seed"))
        if let image { try validateImage(image) }; self.image = image
    }
    public init(data: Data, quality: Bool = false) throws { try self.init(fields: object(data), quality: quality) }
}
public struct Multipart {
    public var fields: [String: Any] = [:]
    public var image: Data?
    public init(data: Data, contentType: String) throws {
        let params = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard params.first?.lowercased() == "multipart/form-data", let param = params.first(where: { $0.hasPrefix("boundary=") }) else { throw APIError("Expected multipart/form-data with boundary") }
        let boundary = String(param.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !boundary.isEmpty, boundary.utf8.count <= 70 else { throw APIError("Invalid multipart boundary") }
        let delimiter = Data(("\r\n--" + boundary).utf8)
        let first = Data(("--" + boundary + "\r\n").utf8)
        guard data.starts(with: first) else { throw APIError("Invalid multipart body") }
        var cursor = first.count
        var names = Set<String>()
        while cursor < data.count {
            guard let endHeaders = data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.count), endHeaders.lowerBound - cursor < 8192,
                  let headers = String(data: data[cursor..<endHeaders.lowerBound], encoding: .utf8),
                  let nameStart = headers.range(of: "name=\""), let nameEnd = headers[nameStart.upperBound...].firstIndex(of: "\"") else { throw APIError("Invalid multipart headers") }
            let name = String(headers[nameStart.upperBound..<nameEnd])
            guard names.insert(name).inserted else { throw APIError("Duplicate multipart field") }
            let start = endHeaders.upperBound
            guard let end = data.range(of: delimiter, in: start..<data.count) else { throw APIError("Unterminated multipart body") }
            let value = Data(data[start..<end.lowerBound])
            if name == "image" || name == "image[]" { guard image == nil else { throw APIError("Only one edit image is supported") }; image = value }
            else if let string = String(data: value, encoding: .utf8) {
                if ["n", "steps", "seed"].contains(name) { guard let v = Int(string) else { throw APIError("Invalid \(name)") }; fields[name] = v }
                else if name == "cfg" { guard let v = Float(string) else { throw APIError("Invalid cfg") }; fields[name] = v }
                else { fields[name] = string }
            } else { throw APIError("Invalid multipart text") }
            cursor = end.upperBound
            if data[cursor...].starts(with: Data("--".utf8)) { break }
            guard data[cursor...].starts(with: Data("\r\n".utf8)) else { throw APIError("Invalid multipart separator") }
            cursor += 2
        }
        guard image != nil else { throw APIError("image is required") }
    }
}
