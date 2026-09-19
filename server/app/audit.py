"""Turns a statement into a validated audit. The server's AuditPipeline.

Mirrors `audit_core`'s Dart pipeline: tolerant parse, schema validation,
bounded repair, then the offline checks — arithmetic and evidence quotes —
that do not depend on the model being honest.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from typing import Any

from .arithmetic import ArithmeticReport, SpendingBreakdown, verify_arithmetic
from .contract import audit_schema
from .json_extract import extract_json_object
from .models import AuditReport
from .prompts import (
    USER_CONTENT_FOR_ATTACHMENT,
    system_prompt,
    user_content_for_text,
)
from .providers.base import Attachment, ProviderError, Turn
from .quote_verify import QuoteVerifier
from .validator import SchemaValidator, SchemaViolation

# Verbatim from transcript_core's StructuringPrompts.repair, so a repair turn
# reads identically whichever client sent it.
_REPAIR_TEMPLATE = """Your previous response failed schema validation:

{violations}

Return the corrected JSON object only. Fix exactly these errors and change nothing else —
do not re-extract, do not add items, do not drop items."""


class AuditError(Exception):
    def __init__(
        self,
        message: str,
        violations: list[str] | None = None,
        last_response: str | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.violations = violations or []
        self.last_response = last_response


@dataclass
class AuditOutcome:
    report: AuditReport
    raw: dict[str, Any]
    arithmetic: ArithmeticReport
    breakdown: SpendingBreakdown
    route: str  # 'attachment' | 'extracted_text'
    route_reason: str
    repair_attempts: int = 0
    unverified_evidence: list[str] = field(default_factory=list)
    evidence_checked: bool = False
    input_tokens: int | None = None
    output_tokens: int | None = None
    model: str | None = None

    @property
    def is_fully_verified(self) -> bool:
        return (
            self.arithmetic.is_clean
            and not self.unverified_evidence
            and self.evidence_checked
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "report": self.report.to_display_json(),
            "arithmetic": self.arithmetic.to_json(),
            "breakdown": self.breakdown.to_json(),
            "route": self.route,
            "route_reason": self.route_reason,
            "repair_attempts": self.repair_attempts,
            "unverified_evidence": self.unverified_evidence,
            "evidence_checked": self.evidence_checked,
            "is_fully_verified": self.is_fully_verified,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "model": self.model,
        }


class AuditPipeline:
    def __init__(self, provider, *, max_repair_attempts: int = 2, schema=None) -> None:
        self._provider = provider
        self._max_repair_attempts = max_repair_attempts
        self._schema = schema or audit_schema()
        self._validator = SchemaValidator(self._schema)

    async def run(
        self,
        *,
        filename: str,
        pdf_bytes: bytes | None = None,
        extracted_text: str | None = None,
        reference_date: str | None = None,
        currency_hint: str | None = None,
        user_context: str | None = None,
    ) -> AuditOutcome:
        has_bytes = bool(pdf_bytes)
        has_text = bool((extracted_text or "").strip())

        if not has_bytes and not has_text:
            raise AuditError(
                "There is nothing to audit. The file produced neither readable "
                "text nor bytes to send."
            )

        attachment = (
            Attachment(data=pdf_bytes, filename=filename) if has_bytes else None
        )
        route, reason, attachment = self._choose_route(attachment, has_text)

        if route == "extracted_text" and not has_text:
            raise AuditError(
                "No text could be read from this PDF, and the selected "
                "provider cannot read the file directly. A scanned statement "
                "with no text layer needs either Claude or Gemini, or an OCR "
                "pass first."
            )

        attached = route == "attachment"
        system = system_prompt(
            attached=attached,
            reference_date=reference_date or date.today().isoformat(),
            currency_hint=currency_hint,
            user_context=user_context,
        )
        user_content = (
            USER_CONTENT_FOR_ATTACHMENT
            if attached
            else user_content_for_text(extracted_text or "")
        )

        parsed, attempts, tokens_in, tokens_out, model = await self._structure_validated(
            system=system,
            user_content=user_content,
            attachment=attachment if attached else None,
        )

        report = AuditReport.from_json(parsed)

        return AuditOutcome(
            report=report,
            raw=parsed,
            arithmetic=verify_arithmetic(report),
            breakdown=SpendingBreakdown.of(report),
            route=route,
            route_reason=reason,
            repair_attempts=attempts,
            unverified_evidence=verify_evidence(report, extracted_text),
            evidence_checked=has_text,
            input_tokens=tokens_in,
            output_tokens=tokens_out,
            model=model,
        )

    def _choose_route(
        self, attachment: Attachment | None, has_text: bool
    ) -> tuple[str, str, Attachment | None]:
        if self._provider.reads_documents and attachment is not None:
            if attachment.encoded_length <= self._provider.max_document_bytes:
                return (
                    "attachment",
                    "Sent as a PDF so the model can read the table layout "
                    "directly.",
                    attachment,
                )
            if has_text:
                mb = attachment.encoded_length / (1024 * 1024)
                return (
                    "extracted_text",
                    f"The statement is too large to attach ({mb:.1f} MB "
                    "encoded), so text extracted on the server was sent "
                    "instead.",
                    None,
                )

        if has_text:
            reason = (
                "Sent as text extracted on the server."
                if self._provider.reads_documents
                else f"{self._provider.name} cannot read PDFs, so text "
                "extracted on the server was sent instead."
            )
            return "extracted_text", reason, None

        return "extracted_text", "No text could be read from this PDF.", None

    async def _structure_validated(
        self,
        *,
        system: str,
        user_content: str,
        attachment: Attachment | None,
    ):
        turns: list[Turn] = []
        attempts = 0
        tokens_in: int | None = None
        tokens_out: int | None = None

        while True:
            response = await self._provider.structure(
                system=system,
                user_content=user_content,
                schema=self._schema,
                prior_turns=turns,
                attachment=attachment,
            )

            tokens_in = _add(tokens_in, response.input_tokens)
            tokens_out = _add(tokens_out, response.output_tokens)

            parsed = extract_json_object(response.raw_text)
            violations: list[SchemaViolation] = (
                [SchemaViolation("", "response did not contain a JSON object")]
                if parsed is None
                else self._validator.validate(parsed)
            )

            if parsed is not None and not violations:
                return parsed, attempts, tokens_in, tokens_out, response.model

            if attempts >= self._max_repair_attempts:
                raise AuditError(
                    f"The model could not produce a valid audit after "
                    f"{attempts + 1} attempts.",
                    violations=[str(v) for v in violations],
                    last_response=response.raw_text,
                )

            # Only the violations go back. Re-sending the statement — or the
            # PDF — would pay for the whole prompt again, and on the
            # attachment path the document is already cached provider-side.
            turns = [
                *turns,
                Turn("user", user_content),
                Turn("assistant", response.raw_text),
                Turn(
                    "user",
                    _REPAIR_TEMPLATE.format(
                        violations="\n".join(f"- {v}" for v in violations)
                    ),
                ),
            ]
            attempts += 1


def verify_evidence(report: AuditReport, statement_text: str | None) -> list[str]:
    """Labels whose cited quote is not in the statement.

    Empty when there is nothing to check against; `evidence_checked`
    distinguishes that from a clean pass.
    """
    if not (statement_text or "").strip():
        return []

    verifier = QuoteVerifier(statement_text or "")
    flagged: list[str] = []

    for item in [*report.needs, *report.wants]:
        if verifier.verify(item.evidence.quote).should_flag:
            flagged.append(item.label)
    for leak in report.wasteful_leaks:
        if verifier.verify(leak.evidence.quote).should_flag:
            flagged.append(leak.label)

    return flagged


def _add(a: int | None, b: int | None) -> int | None:
    if a is None and b is None:
        return None
    return (a or 0) + (b or 0)


__all__ = ["AuditError", "AuditOutcome", "AuditPipeline", "ProviderError", "verify_evidence"]
