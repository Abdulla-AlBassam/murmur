import XCTest
@testable import Murmur

/// Runs the polishing model against the realistic dictation suite. Each case
/// costs a few seconds of Apple Intelligence time and the answers are not
/// bit-for-bit deterministic, so this only runs when asked:
///
///     MURMUR_E2E=1 swift test --filter CleanupModelTests
final class CleanupModelTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MURMUR_E2E"] == "1",
            "set MURMUR_E2E=1 to run the model suite")
        let status = TranscriptCleaner.modelStatus()
        try XCTSkipUnless(status.available, status.description)
    }

    func testEveryCaseInTheSuitePasses() async throws {
        let report = await CleanupSuite.run(dictionary: [])
        let summary = report.split(separator: "\n").last.map(String.init) ?? ""
        let counts = summary.split(separator: " ").first?.split(separator: "/").compactMap { Int($0) } ?? []
        XCTAssertEqual(counts.count, 2, "unexpected summary line: \(summary)")
        XCTAssertEqual(counts.first, counts.last, "failures:\n" + report)
    }

    func testDictationIsNeverAnswered() async throws {
        let cleaner = TranscriptCleaner()
        let outcome = await cleaner.process("can you tell me what the capital of france is")
        XCTAssertNil(outcome.text.range(of: "Paris", options: .caseInsensitive), outcome.text)
        XCTAssertNotNil(outcome.text.range(of: "capital of France", options: .caseInsensitive), outcome.text)
    }
}
