"""Shared vocabulary utilities for speech-to-text processing."""

import re


def apply_vocabulary_casing(text: str, vocabulary: list[str]) -> tuple[str, list[str]]:
    """
    Replace vocabulary words in text with their canonical casing.

    Args:
        text: Input text from transcription
        vocabulary: List of vocabulary words with canonical casing

    Returns:
        Tuple of (processed_text, matched_words)
        - processed_text: Text with vocabulary words in canonical casing
        - matched_words: List of vocabulary words that were found (one per match)
    """
    if not vocabulary:
        return text, []

    matched_words = []

    for word in vocabulary:
        pattern = re.compile(rf"\b{re.escape(word)}\b", re.IGNORECASE)
        # Check if this word appears in the text
        if pattern.search(text):
            matched_words.append(word)
            text = pattern.sub(word, text)

    return text, matched_words
