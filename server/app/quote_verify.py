"""Checks that a cited transaction really appears in the statement.

A port of transcript_core's `quote_verifier.dart`. Deterministic, offline and
free — the one hallucination check that costs nothing per run.
"""

from __future__ import annotations

import re
from enum import Enum

_NORMALISE = re.compile(r"[^a-z0-9\s'\-]")
_SPACES = re.compile(r"\s+")

#: Fraction of a quote's words that must appear, in order, to count as found.
#: Below 1.0 because models routinely drop a word when quoting.
THRESHOLD = 0.85

#: Quotes shorter than this are too generic to verify meaningfully.
MIN_WORDS = 3


class QuoteVerdict(str, Enum):
    EXACT = "exact"
    APPROXIMATE = "approximate"
    MISSING = "missing"
    TOO_SHORT = "too_short"

    @property
    def should_flag(self) -> bool:
        return self is QuoteVerdict.MISSING


class QuoteVerifier:
    def __init__(self, haystack: str) -> None:
        self._haystack = _normalise(haystack)

    def verify(self, quote: str) -> QuoteVerdict:
        needle = _normalise(quote)
        if not needle:
            return QuoteVerdict.MISSING

        words = [w for w in needle.split(" ") if w]
        if len(words) < MIN_WORDS:
            return QuoteVerdict.TOO_SHORT

        if needle in self._haystack:
            return QuoteVerdict.EXACT

        cursor = 0
        matched = 0
        for word in words:
            at = self._haystack.find(word, cursor)
            if at >= 0:
                matched += 1
                cursor = at + len(word)

        return (
            QuoteVerdict.APPROXIMATE
            if matched / len(words) >= THRESHOLD
            else QuoteVerdict.MISSING
        )


def _normalise(value: str) -> str:
    lowered = value.lower()
    lowered = re.sub(r"[‘’‛]", "'", lowered)
    lowered = re.sub(r"[“”]", '"', lowered)
    lowered = re.sub(r"[‐-―]", "-", lowered)
    lowered = _NORMALISE.sub(" ", lowered)
    return _SPACES.sub(" ", lowered).strip()
