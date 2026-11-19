import Foundation

public enum ServerLog {
    private static let lock = NSLock()
    public static func line(_ message: String, at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date) + " " + message
    }
    public static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        // Split embedded newlines so every physical line gets its own timestamp.
        for part in message.components(separatedBy: .newlines) {
            fputs(line(part) + "\n", stdout)
        }
        fflush(stdout)
    }
}

public struct JobTiming {
    public let id: String
    public let queueDepth: Int
    public let queuedSeconds: Double
    public func fields(runSeconds: Double, loadSeconds: Double?) -> String {
        var result = "id=\(id) queued_s=\(queuedSeconds) run_s=\(runSeconds) queue_depth=\(queueDepth)"
        if let loadSeconds { result += " load_s=\(loadSeconds)" }
        return result
    }
}
