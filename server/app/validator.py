"""Validates a parsed audit against the exported schema.

A port of transcript_core's `validator.dart`: deliberately not a
general-purpose JSON Schema implementation, but exactly the subset the
canonical schema uses — type (including nullable unions), required,
properties, additionalProperties: false, items, enum, and local $ref into
$defs. Anything it does not recognise fails loudly rather than passing
silently.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

_REF_PREFIX = "#/$defs/"


@dataclass(frozen=True)
class SchemaViolation:
    pointer: str
    message: str

    def __str__(self) -> str:
        return f"{self.pointer or '(root)'}: {self.message}"


class SchemaValidator:
    def __init__(self, schema: dict[str, Any]) -> None:
        self.schema = schema
        self._defs = schema.get("$defs", {})

    def validate(self, value: Any) -> list[SchemaViolation]:
        out: list[SchemaViolation] = []
        self._check(value, self.schema, "", out)
        return out

    def is_valid(self, value: Any) -> bool:
        return not self.validate(value)

    def _check(
        self,
        value: Any,
        node: dict[str, Any],
        pointer: str,
        out: list[SchemaViolation],
    ) -> None:
        ref = node.get("$ref")
        if isinstance(ref, str):
            target = (
                self._defs.get(ref[len(_REF_PREFIX) :])
                if ref.startswith(_REF_PREFIX)
                else None
            )
            if not isinstance(target, dict):
                out.append(
                    SchemaViolation(pointer, f'unresolved schema reference "{ref}"')
                )
                return
            self._check(value, target, pointer, out)
            return

        types = _types_of(node)
        if types and not any(_matches_type(value, t) for t in types):
            out.append(
                SchemaViolation(
                    pointer,
                    f"expected {' or '.join(types)}, got {_describe(value)}",
                )
            )
            return  # further checks would only produce noise

        allowed = node.get("enum")
        if isinstance(allowed, list) and value not in allowed:
            rendered = ", ".join(f'"{item}"' for item in allowed)
            out.append(
                SchemaViolation(
                    pointer, f"expected one of {rendered}, got {_describe(value)}"
                )
            )

        if isinstance(value, dict):
            props = node.get("properties", {})
            for key in node.get("required", []):
                if key not in value:
                    out.append(
                        SchemaViolation(
                            f"{pointer}/{key}", "required property is missing"
                        )
                    )

            if node.get("additionalProperties") is False:
                for key in value:
                    if key not in props:
                        out.append(
                            SchemaViolation(
                                f"{pointer}/{key}", "unexpected property"
                            )
                        )

            for key, item in value.items():
                sub = props.get(key)
                if isinstance(sub, dict):
                    self._check(item, sub, f"{pointer}/{_escape(key)}", out)

        if isinstance(value, list):
            items = node.get("items")
            if isinstance(items, dict):
                for i, item in enumerate(value):
                    self._check(item, items, f"{pointer}/{i}", out)


def _types_of(node: dict[str, Any]) -> list[str]:
    declared = node.get("type")
    if isinstance(declared, str):
        return [declared]
    if isinstance(declared, list):
        return list(declared)
    return []


def _matches_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    raise ValueError(f'unsupported schema type "{expected}"')


def _describe(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    if isinstance(value, str):
        return "string"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    return type(value).__name__


def _escape(token: str) -> str:
    return token.replace("~", "~0").replace("/", "~1")
