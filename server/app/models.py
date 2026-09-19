"""The audit report, mirroring `audit_core`'s Dart model."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any

from .money import Money, total


class LeakSeverity(str, Enum):
    MINOR = "minor"
    MODERATE = "moderate"
    SEVERE = "severe"
    CRITICAL = "critical"

    @property
    def rank(self) -> int:
        return list(LeakSeverity).index(self)

    @staticmethod
    def from_wire(value: str) -> "LeakSeverity":
        try:
            return LeakSeverity(value)
        except ValueError:
            return LeakSeverity.MODERATE


@dataclass(frozen=True)
class Evidence:
    quote: str = ""
    date: str | None = None

    @staticmethod
    def from_json(data: dict[str, Any] | None) -> "Evidence":
        data = data or {}
        return Evidence(
            quote=data.get("quote") or "",
            date=data.get("date"),
        )


@dataclass(frozen=True)
class SpendItem:
    label: str
    amount: Money
    category: str
    evidence: Evidence

    @staticmethod
    def from_json(data: dict[str, Any]) -> "SpendItem":
        return SpendItem(
            label=data.get("label") or "Unlabelled",
            amount=Money.parse(data.get("amount")) or Money.zero(),
            category=data.get("category") or "other",
            evidence=Evidence.from_json(data.get("evidence")),
        )


@dataclass(frozen=True)
class WastefulLeak:
    label: str
    amount: Money
    monthly_equivalent: Money
    severity: LeakSeverity
    verdict: str
    evidence: Evidence

    @property
    def annual_cost(self) -> Money:
        return self.monthly_equivalent * 12

    @staticmethod
    def from_json(data: dict[str, Any]) -> "WastefulLeak":
        amount = Money.parse(data.get("amount")) or Money.zero()
        return WastefulLeak(
            label=data.get("label") or "Unlabelled",
            amount=amount,
            monthly_equivalent=Money.parse(data.get("monthly_equivalent")) or amount,
            severity=LeakSeverity.from_wire(data.get("severity") or "moderate"),
            verdict=data.get("verdict") or "",
            evidence=Evidence.from_json(data.get("evidence")),
        )


@dataclass(frozen=True)
class AuditReport:
    currency: str
    period_start: str
    period_end: str
    total_net_income: Money
    total_expenses: Money
    needs: list[SpendItem] = field(default_factory=list)
    wants: list[SpendItem] = field(default_factory=list)
    wasteful_leaks: list[WastefulLeak] = field(default_factory=list)
    harsh_audit_summary: str = ""
    action_plan: list[str] = field(default_factory=list)

    @property
    def net_cashflow(self) -> Money:
        return self.total_net_income - self.total_expenses

    @property
    def is_deficit(self) -> bool:
        return self.net_cashflow.is_negative

    @property
    def needs_total(self) -> Money:
        return total(item.amount for item in self.needs)

    @property
    def wants_total(self) -> Money:
        return total(item.amount for item in self.wants)

    @property
    def leaks_total(self) -> Money:
        return total(leak.amount for leak in self.wasteful_leaks)

    @property
    def annualised_leak_cost(self) -> Money:
        return total(leak.annual_cost for leak in self.wasteful_leaks)

    @property
    def leaks_by_severity(self) -> list[WastefulLeak]:
        return sorted(
            self.wasteful_leaks,
            key=lambda leak: (-leak.severity.rank, -leak.amount.minor_units),
        )

    @staticmethod
    def from_json(data: dict[str, Any]) -> "AuditReport":
        return AuditReport(
            currency=data.get("currency") or "USD",
            period_start=data.get("period_start") or "",
            period_end=data.get("period_end") or "",
            total_net_income=Money.parse(data.get("total_net_income")) or Money.zero(),
            total_expenses=Money.parse(data.get("total_expenses")) or Money.zero(),
            needs=[SpendItem.from_json(x) for x in data.get("needs") or [] if isinstance(x, dict)],
            wants=[SpendItem.from_json(x) for x in data.get("wants") or [] if isinstance(x, dict)],
            wasteful_leaks=[
                WastefulLeak.from_json(x)
                for x in data.get("wasteful_leaks") or []
                if isinstance(x, dict)
            ],
            harsh_audit_summary=data.get("harsh_audit_summary") or "",
            action_plan=[s for s in data.get("action_plan") or [] if isinstance(s, str)],
        )

    def to_display_json(self) -> dict[str, Any]:
        """What the web UI consumes. Money as decimals, plus the derived
        figures the browser would otherwise have to recompute (and could get
        subtly wrong)."""
        return {
            "currency": self.currency,
            "period_start": self.period_start,
            "period_end": self.period_end,
            "total_net_income": self.total_net_income.as_float,
            "total_expenses": self.total_expenses.as_float,
            "net_cashflow": self.net_cashflow.as_float,
            "is_deficit": self.is_deficit,
            "needs": [_item_json(i) for i in self.needs],
            "wants": [_item_json(i) for i in self.wants],
            "wasteful_leaks": [
                {
                    "label": leak.label,
                    "amount": leak.amount.as_float,
                    "monthly_equivalent": leak.monthly_equivalent.as_float,
                    "annual_cost": leak.annual_cost.as_float,
                    "severity": leak.severity.value,
                    "verdict": leak.verdict,
                    "evidence": {
                        "quote": leak.evidence.quote,
                        "date": leak.evidence.date,
                    },
                }
                for leak in self.leaks_by_severity
            ],
            "harsh_audit_summary": self.harsh_audit_summary,
            "action_plan": self.action_plan,
            "annualised_leak_cost": self.annualised_leak_cost.as_float,
        }


def _item_json(item: SpendItem) -> dict[str, Any]:
    return {
        "label": item.label,
        "amount": item.amount.as_float,
        "category": item.category,
        "evidence": {"quote": item.evidence.quote, "date": item.evidence.date},
    }
