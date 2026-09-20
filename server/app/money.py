"""Exact money, in minor units.

The same reasoning as the Dart side: a statement's arithmetic never runs on
floats. Python has Decimal, but the wire format is JSON numbers and the
storage is SQLite, so integers of minor units stay the simplest thing that is
exactly right.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

_STRIP = re.compile(r"[^0-9.,]")
_PLAIN = re.compile(r"^-?\d+(\.\d+)?$")


@dataclass(frozen=True, order=True)
class Money:
    minor_units: int

    @staticmethod
    def zero() -> "Money":
        return Money(0)

    @staticmethod
    def from_float(value: float) -> "Money":
        # Round half away from zero, the way a statement rounds, rather than
        # Python's bankers' rounding.
        return Money(int(value * 100 + (0.5 if value >= 0 else -0.5)))

    @staticmethod
    def parse(value: object) -> "Money | None":
        """Parses whatever the model emitted, or returns None."""
        if value is None or isinstance(value, bool):
            return None
        if isinstance(value, int):
            return Money(value * 100)
        if isinstance(value, float):
            return Money.from_float(value)
        if not isinstance(value, str):
            return None

        text = value.strip()
        if not text:
            return None

        negative = False
        if text.startswith("(") and text.endswith(")"):
            negative = True
            text = text[1:-1].strip()
        if text.startswith("-"):
            negative = not negative
            text = text[1:].strip()

        text = _STRIP.sub("", text)
        if not text:
            return None

        last_dot = text.rfind(".")
        last_comma = text.rfind(",")

        if last_dot >= 0 and last_comma >= 0:
            grouping, decimal = ("," , ".") if last_dot > last_comma else (".", ",")
            text = text.replace(grouping, "")
            at = text.rfind(decimal)
            text = f"{text[:at]}.{text[at + 1:]}"
        elif last_comma >= 0:
            trailing = len(text) - last_comma - 1
            single = text.find(",") == last_comma
            text = (
                f"{text[:last_comma]}.{text[last_comma + 1:]}"
                if single and trailing == 2
                else text.replace(",", "")
            )

        if not _PLAIN.match(text):
            return None

        money = Money.from_float(float(text))
        return Money(-money.minor_units) if negative else money

    @property
    def as_float(self) -> float:
        return self.minor_units / 100

    @property
    def is_negative(self) -> bool:
        return self.minor_units < 0

    @property
    def abs(self) -> "Money":
        return Money(abs(self.minor_units))

    def __add__(self, other: "Money") -> "Money":
        return Money(self.minor_units + other.minor_units)

    def __sub__(self, other: "Money") -> "Money":
        return Money(self.minor_units - other.minor_units)

    def __mul__(self, factor: int) -> "Money":
        return Money(self.minor_units * factor)

    def fraction_of(self, total: "Money") -> float:
        return 0.0 if total.minor_units == 0 else self.minor_units / total.minor_units

    def __str__(self) -> str:
        sign = "-" if self.minor_units < 0 else ""
        units = abs(self.minor_units)
        return f"{sign}{units // 100}.{units % 100:02d}"


def total(values) -> Money:
    out = Money.zero()
    for value in values:
        out = out + value
    return out
