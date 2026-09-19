"""Pulls a JSON object out of a model response.

A port of transcript_core's `json_extract.dart`, with the same behaviour and
the same reasoning: providers in a native structured-output mode return clean
JSON and this is a no-op for them, while local models wrap the object in a
markdown fence, open with "Here is the JSON:", or add a closing remark.
Tolerating that is far cheaper than a repair round-trip.
"""

from __future__ import annotations

import json
import re
from typing import Any

_FENCE = re.compile(r"```(?:json)?\s*\n?([\s\S]*?)```", re.MULTILINE)


def extract_json_object(raw: str) -> dict[str, Any] | None:
    direct = _try_decode(raw.strip())
    if direct is not None:
        return direct

    fenced = _FENCE.search(raw)
    if fenced:
        decoded = _try_decode(fenced.group(1).strip())
        if decoded is not None:
            return decoded

    span = _outermost_object(raw)
    if span is not None:
        return _try_decode(span)

    return None


def _try_decode(text: str) -> dict[str, Any] | None:
    if not text:
        return None
    try:
        decoded = json.loads(text)
    except ValueError:
        return None
    return decoded if isinstance(decoded, dict) else None


def _outermost_object(raw: str) -> str | None:
    """The outermost balanced {...}, ignoring braces inside strings."""
    depth = 0
    start = -1
    in_string = False
    escaped = False

    for i, ch in enumerate(raw):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue

        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start >= 0:
                return raw[start : i + 1]

    return None
