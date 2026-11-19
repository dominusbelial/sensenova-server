import Foundation

/// A chat answer whose first generated token ended the reply (`<|im_end|>`), so the client got
/// nothing. The request is kept — message roles and text, sampling settings, token counts and the
/// images themselves — so it can be replayed. Only the newest `keep` captures stay on disk.
struct EmptyAnswerCapture {
    let directory: URL
    let keep: Int
    init(directory: String, keep: Int = 20) {
        self.directory = URL(fileURLWithPath: directory); self.keep = keep
    }

    @discardableResult
    func write(_ request: ChatRequest, promptTokens: Int, imageTokens: [Int], now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = directory.appendingPathComponent(String(format: "%.3f", now.timeIntervalSince1970))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var imageIndex = 0
        var messages: [[String: Any]] = []
        for message in request.messages {
            var files: [String] = []
            for data in message.images {
                let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : data.starts(with: [0xFF, 0xD8]) ? "jpg" : "bin"
                let file = "image-\(imageIndex).\(ext)"; imageIndex += 1
                try data.write(to: dir.appendingPathComponent(file))
                files.append(file)
            }
            messages.append(["role": message.role, "text": message.text, "images": files])
        }
        let summary: [String: Any] = [
            "messages": messages, "max_tokens": request.maxTokens, "temperature": Double(request.temperature),
            "top_p": Double(request.topP), "stream": request.stream,
            "prompt_tokens": promptTokens, "image_tokens": imageTokens]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("request.json"))
        try prune()
        return dir
    }

    /// Keeps the newest `keep` capture folders (names are capture times in seconds).
    func prune() throws {
        let fm = FileManager.default
        let captures = try fm.contentsOfDirectory(atPath: directory.path)
            .compactMap { name in Double(name).map { (name, $0) } }
            .sorted { $0.1 < $1.1 }
        for (name, _) in captures.dropLast(keep) { try fm.removeItem(at: directory.appendingPathComponent(name)) }
    }
}
