import pytest

from app.money import Money, total


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (12.34, 1234),
        (5, 500),
        (0, 0),
        ("£1,234.56", 123456),
        ("$1,234.56", 123456),
        ("1 234.56 GBP", 123456),
        ("1.234,56", 123456),   # European decimal comma
        ("1,23", 123),          # decimal comma, two trailing digits
        ("1,234", 123400),      # thousands separator
        ("(45.00)", -4500),     # accounting parentheses
        ("-45.00", -4500),
        ("-£45.00", -4500),
        (12.345, 1235),         # half away from zero, as a statement rounds
        (12.344, 1234),
    ],
)
def test_parses_what_a_model_actually_emits(raw, expected):
    parsed = Money.parse(raw)
    assert parsed is not None
    assert parsed.minor_units == expected


@pytest.mark.parametrize("raw", [None, "", "not a number", [], True])
def test_returns_none_rather_than_a_wrong_number(raw):
    assert Money.parse(raw) is None


def test_sums_exactly_where_floats_would_drift():
    assert total([Money(10), Money(20)]) == Money(30)
    assert total([Money(1010)] * 1000) == Money(1010000)


def test_subtracts_into_a_deficit():
    assert Money(100000) - Money(250000) == Money(-150000)
    assert (Money(100000) - Money(250000)).is_negative


def test_annualises_by_multiplication():
    assert Money(2499) * 12 == Money(29988)


def test_fraction_of_zero_is_zero_not_a_crash():
    assert Money(500).fraction_of(Money.zero()) == 0
    assert Money(2500).fraction_of(Money(10000)) == 0.25


@pytest.mark.parametrize(
    ("minor", "text"),
    [(5, "0.05"), (50, "0.50"), (123456, "1234.56"), (-4500, "-45.00")],
)
def test_always_shows_two_minor_digits(minor, text):
    assert str(Money(minor)) == text
