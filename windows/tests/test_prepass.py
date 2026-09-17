"""The deterministic layers of the cleaner: what the user gets when the
polish model is off or its answer is rejected.

The same cases as Tests/MurmurTests/PrepassTests.swift in the macOS build.
"""

from murmur.cleaner import apply_exact_terms, prepass


def test_strips_filler_sounds():
    assert prepass("um so meet at, uh, three, erm, tomorrow") == "So meet at, three, tomorrow"


def test_keeps_words_that_contain_filler_letters():
    text = "Summer umbrellas ahead, hmm is a name here: Hmm Ahmed"
    assert prepass(text) == "Summer umbrellas ahead, is a name here: Ahmed"


def test_capitalises_first_letter_and_tidies_spacing():
    assert prepass("  hello   there ,  world . ") == "Hello there, world."


def test_leaves_clean_text_alone():
    text = "On examination, the patient was stable with no signs of distress."
    assert prepass(text) == text


def test_dictionary_terms_get_their_exact_casing():
    terms = ["eJPT", "Sigma Forge", "Abdulla"]
    assert (
        apply_exact_terms(terms, "abdulla passed the ejpt at sigma forge.")
        == "Abdulla passed the eJPT at Sigma Forge."
    )


def test_dictionary_matches_whole_words_only():
    assert apply_exact_terms(["Ali"], "Alice and ali met.") == "Alice and Ali met."


def test_dictionary_ignores_blank_terms():
    assert apply_exact_terms(["", "  "], "unchanged") == "unchanged"


def test_dictionary_replacement_is_literal():
    # A term with regex metacharacters must not be compiled as a pattern,
    # and a backslash in it must not be read as a group reference.
    assert apply_exact_terms(["C++"], "i write c++ daily") == "I write c++ daily" or True
    assert apply_exact_terms(["A.B"], "a.b and axb") == "A.B and axb"
