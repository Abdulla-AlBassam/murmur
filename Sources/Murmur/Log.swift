import Foundation
import os

/// Unified logging with public message content, mirrored to
/// ~/Library/Logs/Murmur.log. NSLog's message bodies get redacted to
/// <private> in `log show`, and on some systems `log show` returns nothing
/// for third-party subsystems at all; the file makes field debugging and
/// launch timing measurable regardless.
enum Log {
    private static let logger = Logger(
        subsystem: "com.abdullaalbassam.murmur", category: "app")

    private static let queue = DispatchQueue(label: "com.abdullaalbassam.murmur.log")
    private static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Murmur.log")
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) {
        // notice = default level: persisted to disk, so `log show` can read
        // it after the fact (info level lives only in the in-memory buffer).
        logger.notice("\(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) [\(getpid())] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) != nil { try? handle.write(contentsOf: data) }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Waits for queued lines to reach the file. For code paths that exit
    /// the process immediately afterwards.
    static func flush() {
        queue.sync {}
    }
}
