import Speech
import XCTest
@testable import Murmur

/// End-to-end check of the speech stage: sentences are synthesised with the
/// system voice, written to AIFF, and run through the same
/// StreamingTranscriber the app uses. No microphone or permissions needed.
/// Skipped when the on-device speech model is not installed.
final class SpeechPipelineTests: XCTestCase {
    private static let sentences = [
        "The meeting is at three pm on Thursday.",
        "Please send the invoice to the client before Friday.",
        "I would like a technical breakdown in the form of a document.",
        "Remind me to buy milk, eggs and bread on the way home.",
    ]

    override func setUp() async throws {
        let locale = await StreamingTranscriber.pickLocale()
        let installed = await SpeechTranscriber.installedLocales
        try XCTSkipUnless(
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) },
            "speech model for \(locale.identifier(.bcp47)) not installed; run Murmur --diag once")
    }

    func testSynthesisedSentencesAreRecognised() async throws {
        var totalErrors = 0
        var totalWords = 0
        for sentence in Self.sentences {
            let url = try Self.synthesise(sentence)
            defer { try? FileManager.default.removeItem(at: url) }
            let transcript = try await FileTranscriber.transcribe(url: url)
            let expected = Guardrails.tokens(sentence)
            let actual = Guardrails.tokens(transcript)
            let errors = Self.editDistance(expected, actual)
            totalErrors += errors
            totalWords += expected.count
            XCTAssertLessThanOrEqual(
                Double(errors) / Double(expected.count), 0.25,
                "expected \"\(sentence)\", recognised \"\(transcript)\"")
        }
        let wer = Double(totalErrors) / Double(totalWords)
        XCTAssertLessThanOrEqual(wer, 0.15, "word error rate across the set was \(wer)")
    }

    func testSilenceProducesNoText() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-silence-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 2)!
        silence.frameLength = silence.frameCapacity
        try file.write(from: silence)

        let transcript = try await FileTranscriber.transcribe(url: url)
        XCTAssertTrue(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "got \"\(transcript)\"")
    }

    // MARK: - Helpers

    private static func synthesise(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-tts-\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw NSError(domain: "MurmurTests", code: Int(say.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "say failed"])
        }
        return url
    }

    /// Word-level Levenshtein distance.
    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where j <= b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }
}
