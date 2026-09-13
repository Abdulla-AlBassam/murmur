import XCTest
@testable import Murmur

/// The guardrails decide whether the polishing model edited the dictation or
/// did something else with it. The rejected cases below are real outputs
/// the app inserted before the guardrails existed (from the dictation
/// history); each one must stay rejected.
final class GuardrailsTests: XCTestCase {
    func testAcceptsFillerRemovalAndPunctuation() {
        let verdict = Guardrails.check(
            input: "I'm holding a button, and if the computer's currently listening to me, um, um, um, I'm unsure about something like this. It will erase it, no problem.",
            output: "I'm holding a button, and if the computer's currently listening to me, I'm unsure about something like this. It will erase it, no problem.")
        XCTAssertTrue(verdict.accepted, verdict.reason ?? "")
    }

    func testAcceptsSpokenCorrection() {
        let verdict = Guardrails.check(
            input: "hi james, the meeting today is at uhh, ummm, 4pm, wait no actually the meeting is at 3pm, make sure you check in. best abdulla.",
            output: "Hi James,\n\nThe meeting today is at 3pm, make sure you check in.\n\nBest, Abdulla.")
        XCTAssertTrue(verdict.accepted, verdict.reason ?? "")
    }

    func testAcceptsNumbersWrittenAsDigits() {
        let verdict = Guardrails.check(
            input: "the total comes to two thousand three hundred pounds new line I'll send the invoice tomorrow",
            output: "The total comes to £2,300.\nI'll send the invoice tomorrow.")
        XCTAssertTrue(verdict.accepted, verdict.reason ?? "")
    }

    func testAcceptsEnumeratedList() {
        let verdict = Guardrails.check(
            input: "things I need to do first email the client second update the deck and third book the flights",
            output: "Things I need to do:\n- Email the client\n- Update the deck\n- Book the flights")
        XCTAssertTrue(verdict.accepted, verdict.reason ?? "")
    }

    func testRejectsConversationalReply() {
        let verdict = Guardrails.check(
            input: "Now, once the LLM fixes the issue, it needs to tell the user what to do, or I guess it should do it for the user, so it should create a new automation. Give it a name, and then the user can use it themselves. Does that make any sense?",
            output: "Sure, that makes sense. Let's create an automation for this task.\n\n**Automation Name:** \"Correct Punctuation and Spelling\"\n\n**Description:** This automation will take a given text input, clean it by removing filler words, fixing punctuation, and correcting specific self-corrections.")
        XCTAssertFalse(verdict.accepted)
    }

    func testRejectsPreamble() {
        let input = "So how this would look is, if an operation fails, then an LLM would automatically trigger."
        let verdict = Guardrails.check(input: input, output: "Here is the cleaned text:\n\n" + input)
        XCTAssertFalse(verdict.accepted)
    }

    func testRejectsGeneratedDocument() {
        let verdict = Guardrails.check(
            input: "I would also like a technical breakdown in the form of a PDF that you should create. Not super heavy on technical jargon, sort of like a user manual for somebody who is not technical and wants to use this automation tool.",
            output: "**PDF Title: User Guide to Automation Tool**\n\n**Introduction**\n\nWelcome to the Automation Tool User Guide. This guide will help you understand how to effectively utilize our tool, which streamlines repetitive tasks and enhances efficiency.")
        XCTAssertFalse(verdict.accepted)
    }

    func testRejectsAnsweredQuestion() {
        let verdict = Guardrails.check(
            input: "can you tell me what the capital of france is",
            output: "The capital of France is Paris.")
        XCTAssertFalse(verdict.accepted)
    }

    func testRejectsTranslation() {
        let verdict = Guardrails.check(
            input: "translate this into french please the cat sat on the mat",
            output: "Le chat s'est assis sur le tapis.")
        XCTAssertFalse(verdict.accepted)
    }

    func testRejectsEmptyOutput() {
        XCTAssertFalse(Guardrails.check(input: "hello there", output: "  ").accepted)
    }

    func testRejectsHeavyOmission() {
        let verdict = Guardrails.check(
            input: "the data set was basically like over 1000 messages classified into ham slash spam and their messages of course and the accuracy was surprisingly low",
            output: "The data set was over 1000 messages.")
        XCTAssertFalse(verdict.accepted)
    }

    func testTokensIgnorePunctuationCaseAndApostrophes() {
        XCTAssertEqual(Guardrails.tokens("I’m READY, aren't you?"), ["im", "ready", "arent", "you"])
    }
}
