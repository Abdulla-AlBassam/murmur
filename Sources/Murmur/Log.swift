import os

/// Unified logging with public message content. NSLog's message bodies get
/// redacted to <private> in `log show` on modern macOS, which makes field
/// debugging impossible; an os.Logger with explicit public privacy does not.
enum Log {
    private static let logger = Logger(
        subsystem: "com.abdullaalbassam.murmur", category: "app")

    static func info(_ message: String) {
        // notice = default level: persisted to disk, so `log show` can read
        // it after the fact (info level lives only in the in-memory buffer).
        logger.notice("\(message, privacy: .public)")
    }
}
