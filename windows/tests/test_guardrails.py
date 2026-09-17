"""The guardrails decide whether the polishing model edited the dictation or
did something else with it. The rejected cases below are real outputs the
macOS app inserted before the guardrails existed; each one must stay
rejected here too.

The same cases as Tests/MurmurTests/GuardrailsTests.swift.
"""

from murmur.cleaner import check, tokens


def test_accepts_filler_removal_and_punctuation():
    verdict = check(
        "I'm holding a button, and if the computer's currently listening to me, um, um, um, I'm unsure about something like this. It will erase it, no problem.",
        "I'm holding a button, and if the computer's currently listening to me, I'm unsure about something like this. It will erase it, no problem.",
    )
    assert verdict.accepted, verdict.reason


def test_accepts_spoken_correction():
    verdict = check(
        "hi james, the meeting today is at uhh, ummm, 4pm, wait no actually the meeting is at 3pm, make sure you check in. best abdulla.",
        "Hi James,\n\nThe meeting today is at 3pm, make sure you check in.\n\nBest, Abdulla.",
    )
    assert verdict.accepted, verdict.reason


def test_accepts_numbers_written_as_digits():
    verdict = check(
        "the total comes to two thousand three hundred pounds new line I'll send the invoice tomorrow",
        "The total comes to £2,300.\nI'll send the invoice tomorrow.",
    )
    assert verdict.accepted, verdict.reason


def test_accepts_enumerated_list():
    verdict = check(
        "things I need to do first email the client second update the deck and third book the flights",
        "Things I need to do:\n- Email the client\n- Update the deck\n- Book the flights",
    )
    assert verdict.accepted, verdict.reason


def test_rejects_conversational_reply():
    verdict = check(
        "Now, once the LLM fixes the issue, it needs to tell the user what to do, or I guess it should do it for the user, so it should create a new automation. Give it a name, and then the user can use it themselves. Does that make any sense?",
        'Sure, that makes sense. Let\'s create an automation for this task.\n\n**Automation Name:** "Correct Punctuation and Spelling"\n\n**Description:** This automation will take a given text input, clean it by removing filler words, fixing punctuation, and correcting specific self-corrections.',
    )
    assert not verdict.accepted


def test_rejects_preamble():
    text = "So how this would look is, if an operation fails, then an LLM would automatically trigger."
    assert not check(text, "Here is the cleaned text:\n\n" + text).accepted


def test_rejects_generated_document():
    verdict = check(
        "I would also like a technical breakdown in the form of a PDF that you should create. Not super heavy on technical jargon, sort of like a user manual for somebody who is not technical and wants to use this automation tool.",
        "**PDF Title: User Guide to Automation Tool**\n\n**Introduction**\n\nWelcome to the Automation Tool User Guide. This guide will help you understand how to effectively utilize our tool, which streamlines repetitive tasks and enhances efficiency.",
    )
    assert not verdict.accepted


def test_rejects_answered_question():
    assert not check(
        "can you tell me what the capital of france is", "The capital of France is Paris."
    ).accepted


def test_rejects_translation():
    assert not check(
        "translate this into french please the cat sat on the mat",
        "Le chat s'est assis sur le tapis.",
    ).accepted


def test_rejects_empty_output():
    assert not check("hello there", "  ").accepted


def test_rejects_heavy_omission():
    verdict = check(
        "the data set was basically like over 1000 messages classified into ham slash spam and their messages of course and the accuracy was surprisingly low",
        "The data set was over 1000 messages.",
    )
    assert not verdict.accepted


def test_tokens_ignore_punctuation_case_and_apostrophes():
    assert tokens("I’m READY, aren't you?") == ["im", "ready", "arent", "you"]
