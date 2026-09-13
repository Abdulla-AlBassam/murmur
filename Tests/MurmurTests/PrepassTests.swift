import XCTest
@testable import Murmur

/// The deterministic layers of the cleaner: what the user gets when the
/// model is off or its answer is rejected.
final class PrepassTests: XCTestCase {
    func testStripsFillerSounds() {
        XCTAssertEqual(
            TranscriptCleaner.prepass("um so meet at, uh, three, erm, tomorrow"),
            "So meet at, three, tomorrow")
    }

    func testKeepsWordsThatContainFillerLetters() {
        let text = "Summer umbrellas ahead, hmm is a name here: Hmm Ahmed"
        XCTAssertEqual(TranscriptCleaner.prepass(text), "Summer umbrellas ahead, is a name here: Ahmed")
    }

    func testCapitalisesFirstLetterAndTidiesSpacing() {
        XCTAssertEqual(TranscriptCleaner.prepass("  hello   there ,  world . "), "Hello there, world.")
    }

    func testLeavesCleanTextAlone() {
        let text = "On examination, the patient was stable with no signs of distress."
        XCTAssertEqual(TranscriptCleaner.prepass(text), text)
    }

    func testDictionaryTermsGetTheirExactCasing() {
        let terms = ["eJPT", "Sigma Forge", "Abdulla"]
        XCTAssertEqual(
            TranscriptCleaner.applyExactTerms(terms, to: "abdulla passed the ejpt at sigma forge."),
            "Abdulla passed the eJPT at Sigma Forge.")
    }

    func testDictionaryMatchesWholeWordsOnly() {
        XCTAssertEqual(TranscriptCleaner.applyExactTerms(["Ali"], to: "Alice and ali met."), "Alice and Ali met.")
    }

    func testDictionaryIgnoresBlankTerms() {
        XCTAssertEqual(TranscriptCleaner.applyExactTerms(["", "  "], to: "unchanged"), "unchanged")
    }
}
