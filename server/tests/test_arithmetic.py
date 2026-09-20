import pytest

from app.arithmetic import (
    FindingSeverity,
    SpendingBreakdown,
    verify_arithmetic,
)
from app.models import AuditReport
from app.money import Money

from .conftest import valid_audit


def report(**changes) -> AuditReport:
    audit = valid_audit()
    for path, value in changes.items():
        audit[path] = value
    return AuditReport.from_json(audit)


def pointers(result) -> list[str]:
    return [f.pointer for f in result.findings]


def test_a_consistent_audit_produces_no_findings():
    result = verify_arithmetic(report())
    assert result.findings == []
    assert result.is_clean
    assert result.computed_expenses == Money(200000)


def test_catches_a_total_that_disagrees_with_its_line_items():
    result = verify_arithmetic(report(total_expenses=1500.0))
    assert "/total_expenses" in pointers(result)
    assert result.has_errors
    assert "500.00" in result.findings[0].message


def test_tolerates_per_item_rounding_drift():
    assert verify_arithmetic(report(total_expenses=2000.02)).is_clean


def test_catches_negative_income():
    result = verify_arithmetic(report(total_net_income=-10.0))
    assert "/total_net_income" in pointers(result)
    assert result.has_errors


def test_catches_an_empty_action_plan():
    assert "/action_plan" in pointers(verify_arithmetic(report(action_plan=[])))


def test_catches_a_reversed_period():
    result = verify_arithmetic(
        report(period_start="2026-03-31", period_end="2026-03-01")
    )
    assert "/period_end" in pointers(result)


def test_notes_an_unreadable_period_without_failing_the_audit():
    result = verify_arithmetic(report(period_start="March"))
    assert not result.has_errors
    assert "/period_start" in pointers(result)


def test_catches_a_leak_that_appears_nowhere_in_the_breakdown():
    audit = valid_audit()
    audit["wasteful_leaks"][0]["label"] = "Uber Eats"
    result = verify_arithmetic(AuditReport.from_json(audit))
    assert "/wasteful_leaks/0" in pointers(result)
    assert result.has_errors


def test_matches_leak_labels_case_and_punctuation_insensitively():
    audit = valid_audit()
    audit["wasteful_leaks"][0]["label"] = "DELIVEROO!"
    assert verify_arithmetic(AuditReport.from_json(audit)).is_clean


def test_catches_a_leak_larger_than_its_source():
    audit = valid_audit()
    audit["wasteful_leaks"][0]["amount"] = 500.0
    audit["wasteful_leaks"][0]["severity"] = "critical"
    result = verify_arithmetic(AuditReport.from_json(audit))
    assert "/wasteful_leaks/0/amount" in pointers(result)


def test_catches_an_understated_severity():
    audit = valid_audit()
    audit["wasteful_leaks"][0]["severity"] = "minor"
    result = verify_arithmetic(AuditReport.from_json(audit))
    finding = next(f for f in result.findings if f.pointer.endswith("/severity"))
    assert finding.severity is FindingSeverity.WARNING
    assert "8.0%" in finding.message
    assert "severe" in finding.message


def test_allows_a_severity_harsher_than_the_thresholds_require():
    audit = valid_audit()
    audit["wasteful_leaks"][0]["severity"] = "critical"
    assert verify_arithmetic(AuditReport.from_json(audit)).is_clean


def test_catches_negative_spending():
    audit = valid_audit()
    audit["wants"][1]["amount"] = -400.0
    audit["total_expenses"] = 1200.0
    result = verify_arithmetic(AuditReport.from_json(audit))
    assert "/wants/1/amount" in pointers(result)


class TestBreakdown:
    def test_carves_leaks_out_of_wants_rather_than_adding_them(self):
        breakdown = SpendingBreakdown.of(report())
        assert breakdown.needs == Money(135000)
        assert breakdown.wants == Money(41000)
        assert breakdown.leaks == Money(24000)
        assert breakdown.total == Money(200000)
        assert breakdown.unattributed_leaks == Money.zero()

    def test_carves_a_leak_out_of_needs_when_that_is_its_source(self):
        audit = valid_audit()
        audit["wasteful_leaks"][0]["label"] = "British Gas"
        audit["wasteful_leaks"][0]["amount"] = 150.0
        breakdown = SpendingBreakdown.of(AuditReport.from_json(audit))
        assert breakdown.needs == Money(120000)
        assert breakdown.leaks == Money(15000)
        assert breakdown.total == Money(200000)

    def test_never_carves_out_more_than_the_source_holds(self):
        audit = valid_audit()
        audit["wasteful_leaks"][0]["amount"] = 900.0
        breakdown = SpendingBreakdown.of(AuditReport.from_json(audit))
        # Without the clamp wants would go to -250 and the bar would paint
        # backwards.
        assert breakdown.wants == Money(41000)
        assert breakdown.total == Money(200000)

    def test_keeps_an_unattributable_leak_out_of_the_bar_but_reports_it(self):
        audit = valid_audit()
        audit["wasteful_leaks"][0]["label"] = "Uber Eats"
        breakdown = SpendingBreakdown.of(AuditReport.from_json(audit))
        assert breakdown.leaks == Money.zero()
        assert breakdown.unattributed_leaks == Money(24000)
        assert breakdown.total == Money(200000)


class TestDerivedFigures:
    def test_net_cashflow_and_deficit(self):
        assert report().net_cashflow == Money(100000)
        assert not report().is_deficit
        assert report(total_net_income=1500.0).is_deficit

    def test_annualises_the_leak_cost(self):
        assert report().annualised_leak_cost == Money(288000)

    def test_orders_leaks_worst_first(self):
        audit = valid_audit()
        audit["wasteful_leaks"].append(
            {
                "label": "Spotify",
                "amount": 10.0,
                "monthly_equivalent": 10.0,
                "severity": "critical",
                "verdict": "Unused since January.",
                "evidence": {"quote": "SPOTIFY PREMIUM 10.00", "date": None},
            }
        )
        ordered = [l.label for l in AuditReport.from_json(audit).leaks_by_severity]
        assert ordered == ["Spotify", "Deliveroo"]
