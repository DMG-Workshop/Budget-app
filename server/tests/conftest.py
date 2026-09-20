"""Shared fixtures.

The PDF helper builds a real, structurally valid PDF with a text layer rather
than mocking the reader. Text extraction is the step most likely to break
quietly on a real statement, so the tests exercise pypdf against actual bytes.
"""

from __future__ import annotations

import json
from typing import Any

import pytest

STATEMENT_LINES = [
    "FIRST DIRECT CURRENT ACCOUNT",
    "Statement period 01 Mar 2026 to 31 Mar 2026",
    "02 Mar  ACME LTD SALARY          3000.00 CR",
    "03 Mar  GREENFIELD LETTINGS RENT 1200.00",
    "05 Mar  BRITISH GAS ENERGY        150.00",
    "07 Mar  DELIVEROO ORDER            60.00",
    "11 Mar  DELIVEROO ORDER            55.00",
    "14 Mar  TESCO STORES              400.00",
    "18 Mar  DELIVEROO ORDER            70.00",
    "22 Mar  SPOTIFY PREMIUM            10.00",
    "26 Mar  DELIVEROO ORDER            55.00",
]


def make_pdf(lines: list[str]) -> bytes:
    """A minimal single-page PDF containing `lines` as real text.

    Offsets in the cross-reference table are computed rather than guessed, so
    the file is valid and pypdf does not have to fall back to reconstructing
    it — which would make the test pass for the wrong reason.
    """
    escaped = [
        line.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")
        for line in lines
    ]
    text = "BT /F1 11 Tf 54 740 Td 14 TL\n" + "\n".join(
        f"({line}) Tj T*" for line in escaped
    ) + "\nET"
    stream = text.encode("latin-1")

    objects = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]"
        b"/Resources<</Font<</F1 4 0 R>>>>/Contents 5 0 R>>",
        b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>",
        b"<</Length %d>>stream\n" % len(stream) + stream + b"\nendstream",
    ]

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj" % number + body + b"endobj\n"

    xref_at = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset

    out += b"trailer<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1,
        xref_at,
    )
    return bytes(out)


@pytest.fixture
def statement_pdf() -> bytes:
    return make_pdf(STATEMENT_LINES)


@pytest.fixture
def statement_text() -> str:
    return "\n".join(STATEMENT_LINES)


def valid_audit() -> dict[str, Any]:
    """An audit that reconciles: needs + wants = total, leaks drawn from wants."""
    return {
        "currency": "GBP",
        "period_start": "2026-03-01",
        "period_end": "2026-03-31",
        "total_net_income": 3000.00,
        "total_expenses": 2000.00,
        "needs": [
            {
                "label": "Rent",
                "amount": 1200.00,
                "category": "housing",
                "evidence": {
                    "quote": "GREENFIELD LETTINGS RENT 1200.00",
                    "date": "2026-03-03",
                },
            },
            {
                "label": "British Gas",
                "amount": 150.00,
                "category": "utilities",
                "evidence": {
                    "quote": "BRITISH GAS ENERGY 150.00",
                    "date": "2026-03-05",
                },
            },
        ],
        "wants": [
            {
                "label": "Deliveroo",
                "amount": 240.00,
                "category": "delivery",
                "evidence": {"quote": "DELIVEROO ORDER 60.00", "date": "2026-03-07"},
            },
            {
                "label": "Tesco",
                "amount": 400.00,
                "category": "groceries",
                "evidence": {"quote": "TESCO STORES 400.00", "date": "2026-03-14"},
            },
            {
                "label": "Spotify",
                "amount": 10.00,
                "category": "subscriptions",
                "evidence": {"quote": "SPOTIFY PREMIUM 10.00", "date": "2026-03-22"},
            },
        ],
        "wasteful_leaks": [
            {
                "label": "Deliveroo",
                "amount": 240.00,
                "monthly_equivalent": 240.00,
                "severity": "severe",
                "verdict": "Four deliveries cost you 240.00 this month.",
                "evidence": {"quote": "DELIVEROO ORDER 60.00", "date": "2026-03-07"},
            }
        ],
        "harsh_audit_summary": "You kept 1000.00 of 3000.00.",
        "action_plan": ["Cancel Deliveroo.", "Move the surplus on payday."],
    }


def valid_audit_json() -> str:
    return json.dumps(valid_audit())


class FakeProvider:
    """Replays queued responses and records what it was sent."""

    def __init__(
        self,
        responses: list[str],
        *,
        name: str = "Fake",
        reads_documents: bool = False,
        max_document_bytes: int = 32 * 1024 * 1024,
    ) -> None:
        self._responses = list(responses)
        self.name = name
        self._reads_documents = reads_documents
        self._max_document_bytes = max_document_bytes
        self.calls: list[dict[str, Any]] = []

    @property
    def reads_documents(self) -> bool:
        return self._reads_documents

    @property
    def max_document_bytes(self) -> int:
        return self._max_document_bytes

    async def structure(
        self, *, system, user_content, schema, prior_turns=None, attachment=None
    ):
        from app.providers.base import StructureResponse

        self.calls.append(
            {
                "system": system,
                "user_content": user_content,
                "prior_turns": list(prior_turns or []),
                "attachment": attachment,
            }
        )
        if not self._responses:
            raise AssertionError(f"ran out of responses on call {len(self.calls)}")
        return StructureResponse(
            raw_text=self._responses.pop(0), input_tokens=100, output_tokens=50,
            model="fake-1",
        )

    async def test(self) -> dict[str, Any]:
        return {"ok": True, "summary": "Connected · fake"}
