"""Reading a bank statement PDF on the server."""

from __future__ import annotations

import io
from dataclasses import dataclass

from pypdf import PdfReader
from pypdf.errors import PdfReadError

MAX_BYTES = 50 * 1024 * 1024


@dataclass(frozen=True)
class TextExtraction:
    text: str | None = None
    page_count: int = 0
    failure: str | None = None

    @property
    def succeeded(self) -> bool:
        return bool((self.text or "").strip())


def extract_text(data: bytes) -> TextExtraction:
    """Pulls the text layer out of a PDF.

    Never raises: a statement with no text layer is a normal outcome — a scan,
    or a bank that ships images — and the attachment path may still handle it.
    """
    try:
        reader = PdfReader(io.BytesIO(data))

        if reader.is_encrypted:
            # An empty user password is common on bank statements and pypdf
            # can open those; a real password cannot be guessed.
            try:
                reader.decrypt("")
            except Exception:  # noqa: BLE001 - any failure means "locked"
                return TextExtraction(
                    failure="This PDF is password protected. Remove the "
                    "password and upload it again."
                )

        chunks: list[str] = []
        for number, page in enumerate(reader.pages, start=1):
            content = (page.extract_text() or "").strip()
            if content:
                # Page boundaries are kept: a transaction table continuing
                # across a break reads differently from one that does not.
                chunks.append(f"--- page {number} ---\n{content}")

        if not chunks:
            return TextExtraction(
                page_count=len(reader.pages),
                failure="This PDF has no text layer — it is probably a scan. "
                "Claude and Gemini can still read it directly; a local model "
                "cannot, and would need an OCR pass first.",
            )

        return TextExtraction(
            text="\n".join(chunks), page_count=len(reader.pages)
        )
    except (PdfReadError, OSError, ValueError) as exc:
        return TextExtraction(failure=f"The PDF could not be opened ({exc}).")
