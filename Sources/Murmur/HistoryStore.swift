import Foundation

struct DictationEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let text: String  // what was inserted
    let raw: String?  // original transcript, only kept when cleanup changed it
}

/// Recent dictations, newest first, persisted as JSON in Application Support.
/// Doubles as a safety net for dictating into fields that swallow the paste.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [DictationEntry] = []

    private static let capacity = 100
    private let fileURL: URL

    private init() {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        load()
    }

    func add(text: String, raw: String?) {
        entries.insert(DictationEntry(id: UUID(), date: Date(), text: text, raw: raw), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([DictationEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
