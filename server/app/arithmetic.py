"""Re-does the model's sums. A port of `arithmetic_check.dart`.

The model is trusted to find and categorise transactions and trusted with
nothing that can be recomputed from them.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date
from enum import Enum
from typing import Any

from .models import AuditReport, LeakSeverity, SpendItem
from .money import Money

_KEY = re.compile(r"[^a-z0-9]")


class FindingSeverity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class AuditFinding:
    pointer: str
    message: str
    severity: FindingSeverity

    def to_json(self) -> dict[str, Any]:
        return {
            "pointer": self.pointer,
            "message": self.message,
            "severity": self.severity.value,
        }


@dataclass(frozen=True)
class ArithmeticReport:
    findings: list[AuditFinding]
    declared_expenses: Money
    computed_expenses: Money

    @property
    def is_clean(self) -> bool:
        return not self.findings

    @property
    def has_errors(self) -> bool:
        return any(f.severity is FindingSeverity.ERROR for f in self.findings)

    def to_json(self) -> dict[str, Any]:
        return {
            "findings": [f.to_json() for f in self.findings],
            "declared_expenses": self.declared_expenses.as_float,
            "computed_expenses": self.computed_expenses.as_float,
            "is_clean": self.is_clean,
            "has_errors": self.has_errors,
        }


def verify_arithmetic(report: AuditReport, tolerance: Money | None = None) -> ArithmeticReport:
    findings: list[AuditFinding] = []

    item_count = len(report.needs) + len(report.wants)
    slack = tolerance or Money(100 + item_count)

    computed = report.needs_total + report.wants_total
    drift = (computed - report.total_expenses).abs

    if drift.minor_units > slack.minor_units:
        findings.append(
            AuditFinding(
                "/total_expenses",
                f"Declared total is {report.currency} {report.total_expenses}, "
                f"but the {item_count} line items add up to {report.currency} "
                f"{computed} — a difference of {report.currency} {drift}. "
                "Either an item is missing from the breakdown or the total is "
                "wrong.",
                FindingSeverity.ERROR,
            )
        )

    if report.total_net_income.is_negative:
        findings.append(
            AuditFinding(
                "/total_net_income",
                "Net income is negative, which is not possible — money paid "
                "out is an expense, not negative income.",
                FindingSeverity.ERROR,
            )
        )

    _check_positive(report.needs, "needs", findings)
    _check_positive(report.wants, "wants", findings)
    _check_leaks(report, findings, slack)
    _check_severities(report, findings)
    _check_period(report, findings)

    if not report.action_plan:
        findings.append(
            AuditFinding(
                "/action_plan",
                "The audit produced no action plan.",
                FindingSeverity.WARNING,
            )
        )

    return ArithmeticReport(
        findings=findings,
        declared_expenses=report.total_expenses,
        computed_expenses=computed,
    )


def _check_positive(
    items: list[SpendItem], field: str, findings: list[AuditFinding]
) -> None:
    for i, item in enumerate(items):
        if item.amount.is_negative:
            findings.append(
                AuditFinding(
                    f"/{field}/{i}/amount",
                    f'"{item.label}" has a negative amount. Refunds should be '
                    "netted off the purchase, not listed as negative spending.",
                    FindingSeverity.WARNING,
                )
            )


def _check_leaks(
    report: AuditReport, findings: list[AuditFinding], slack: Money
) -> None:
    by_label: dict[str, Money] = {}
    for item in [*report.needs, *report.wants]:
        key = _key(item.label)
        by_label[key] = by_label.get(key, Money.zero()) + item.amount

    for i, leak in enumerate(report.wasteful_leaks):
        source = by_label.get(_key(leak.label))

        if source is None:
            findings.append(
                AuditFinding(
                    f"/wasteful_leaks/{i}",
                    f'"{leak.label}" is flagged as a leak but appears in '
                    "neither needs nor wants. Leaks are drawn from spending "
                    "already listed, so this is either miscategorised or was "
                    "never in the statement.",
                    FindingSeverity.ERROR,
                )
            )
            continue

        if (leak.amount - source).minor_units > slack.minor_units:
            findings.append(
                AuditFinding(
                    f"/wasteful_leaks/{i}/amount",
                    f'"{leak.label}" is flagged at {report.currency} '
                    f"{leak.amount} but only {report.currency} {source} of it "
                    "appears in the breakdown.",
                    FindingSeverity.ERROR,
                )
            )

    if report.leaks_total.minor_units > (report.total_expenses + slack).minor_units:
        findings.append(
            AuditFinding(
                "/wasteful_leaks",
                f"Flagged leaks total {report.currency} {report.leaks_total}, "
                "which is more than all spending in the period.",
                FindingSeverity.ERROR,
            )
        )


def _check_severities(report: AuditReport, findings: list[AuditFinding]) -> None:
    income = report.total_net_income
    if income.minor_units <= 0:
        return

    for i, leak in enumerate(report.wasteful_leaks):
        share = leak.amount.fraction_of(income)
        if share > 0.08:
            expected = LeakSeverity.CRITICAL
        elif share > 0.03:
            expected = LeakSeverity.SEVERE
        elif share > 0.01:
            expected = LeakSeverity.MODERATE
        else:
            expected = LeakSeverity.MINOR

        if leak.severity.rank < expected.rank:
            findings.append(
                AuditFinding(
                    f"/wasteful_leaks/{i}/severity",
                    f'"{leak.label}" is {share * 100:.1f}% of net income and '
                    f"is graded {leak.severity.value}; the thresholds make it "
                    f"{expected.value}.",
                    FindingSeverity.WARNING,
                )
            )


def _check_period(report: AuditReport, findings: list[AuditFinding]) -> None:
    start = _parse_date(report.period_start)
    end = _parse_date(report.period_end)

    if start is None or end is None:
        findings.append(
            AuditFinding(
                "/period_start",
                "The statement period could not be read as a pair of dates.",
                FindingSeverity.INFO,
            )
        )
        return

    if end < start:
        findings.append(
            AuditFinding(
                "/period_end",
                f"The statement period ends ({report.period_end}) before it "
                f"begins ({report.period_start}).",
                FindingSeverity.WARNING,
            )
        )


def _parse_date(value: str) -> date | None:
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def _key(label: str) -> str:
    return _KEY.sub("", label.lower())


@dataclass(frozen=True)
class SpendingBreakdown:
    """Segments for the bar. Leaks are carved out, never added."""

    needs: Money
    wants: Money
    leaks: Money
    unattributed_leaks: Money

    @property
    def total(self) -> Money:
        return self.needs + self.wants + self.leaks

    @staticmethod
    def of(report: AuditReport) -> "SpendingBreakdown":
        needs_by_label = _totals(report.needs)
        wants_by_label = _totals(report.wants)

        leak_from_needs = Money.zero()
        leak_from_wants = Money.zero()
        unattributed = Money.zero()

        for leak in report.wasteful_leaks:
            key = _key(leak.label)
            if key in wants_by_label:
                leak_from_wants += _min(leak.amount, wants_by_label[key])
            elif key in needs_by_label:
                leak_from_needs += _min(leak.amount, needs_by_label[key])
            else:
                unattributed += leak.amount

        return SpendingBreakdown(
            needs=report.needs_total - leak_from_needs,
            wants=report.wants_total - leak_from_wants,
            leaks=leak_from_needs + leak_from_wants,
            unattributed_leaks=unattributed,
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "needs": self.needs.as_float,
            "wants": self.wants.as_float,
            "leaks": self.leaks.as_float,
            "unattributed_leaks": self.unattributed_leaks.as_float,
            "total": self.total.as_float,
        }


def _totals(items: list[SpendItem]) -> dict[str, Money]:
    out: dict[str, Money] = {}
    for item in items:
        key = _key(item.label)
        out[key] = out.get(key, Money.zero()) + item.amount
    return out


def _min(a: Money, b: Money) -> Money:
    return a if a.minor_units <= b.minor_units else b
