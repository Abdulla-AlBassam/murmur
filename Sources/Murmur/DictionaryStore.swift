import Foundation

/// The personal dictionary: exact spellings of names and jargon the ASR
/// tends to fumble. Stored as plain text, one term per line.
@MainActor
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    private nonisolated static let defaultsKey = "MurmurDictionary"

    @Published var termsText: String {
        didSet { UserDefaults.standard.set(termsText, forKey: Self.defaultsKey) }
    }

    var terms: [String] { Self.parse(termsText) }

    /// Off-main-actor accessor for the CLI test harness, which keeps the main
    /// thread parked on a semaphore and would deadlock on MainActor.run.
    nonisolated static func currentTerms() -> [String] {
        parse(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }

    private nonisolated static func parse(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private init() {
        termsText = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
    }
}
