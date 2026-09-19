"""Renders the canonical schema into each provider's dialect.

A port of transcript_core's `dialects.dart`. The schema is authored once and
every provider's shape is derived from it, rather than maintaining parallel
copies that drift.
"""

from __future__ import annotations

from enum import Enum
from typing import Any

_MAX_REF_DEPTH = 16
_REF_PREFIX = "#/$defs/"


class SchemaDialect(str, Enum):
    #: JSON Schema as authored. Anthropic `output_config.format`, Ollama `format`.
    PLAIN = "plain"
    #: OpenAI structured outputs with `strict: true`; rejects $schema/$id.
    OPENAI_STRICT = "openAiStrict"
    #: Gemini `responseSchema`, an OpenAPI 3.0 subset: no $ref, no
    #: additionalProperties, and `nullable: true` rather than a type union.
    GEMINI = "gemini"


def render_schema(schema: dict[str, Any], dialect: SchemaDialect) -> dict[str, Any]:
    defs = schema.get("$defs", {})
    rendered = _walk(schema, dialect, defs, 0)
    assert isinstance(rendered, dict)
    return rendered


def _walk(node: Any, dialect: SchemaDialect, defs: dict[str, Any], depth: int) -> Any:
    if isinstance(node, list):
        return [_walk(item, dialect, defs, depth) for item in node]
    if not isinstance(node, dict):
        return node

    ref = node.get("$ref")
    if isinstance(ref, str) and dialect is not SchemaDialect.PLAIN:
        if depth >= _MAX_REF_DEPTH:
            raise ValueError(
                f'$ref nesting exceeded {_MAX_REF_DEPTH} resolving "{ref}" — '
                "the schema is probably cyclic, which no provider dialect can "
                "express."
            )
        target = _resolve_local_ref(ref, defs)
        # Sibling keys alongside $ref stay and win over the target's.
        merged = {**target, **node}
        merged.pop("$ref", None)
        return _walk(merged, dialect, defs, depth + 1)

    result: dict[str, Any] = {}
    for key, value in node.items():
        if key in ("$schema", "$id"):
            continue

        if key == "$defs":
            if dialect is SchemaDialect.PLAIN:
                result[key] = _walk(value, dialect, defs, depth)
            continue

        if key == "additionalProperties" and dialect is SchemaDialect.GEMINI:
            continue

        if key == "type" and isinstance(value, list) and dialect is SchemaDialect.GEMINI:
            non_null = [t for t in value if t != "null"]
            if "null" in value:
                result["nullable"] = True
            if len(non_null) > 1:
                raise ValueError(
                    "Gemini responseSchema cannot express a union of "
                    f"{'|'.join(non_null)} — express it as a single type plus "
                    "nullable."
                )
            result["type"] = non_null[0] if non_null else "string"
            continue

        result[key] = _walk(value, dialect, defs, depth)

    # Gemini honours declaration order in propertyOrdering; without it the
    # model emits fields in any order, which measurably hurts quality.
    if dialect is SchemaDialect.GEMINI and isinstance(result.get("properties"), dict):
        result["propertyOrdering"] = list(result["properties"].keys())

    return result


def _resolve_local_ref(ref: str, defs: dict[str, Any]) -> dict[str, Any]:
    if not ref.startswith(_REF_PREFIX):
        raise ValueError(f'Only local {_REF_PREFIX} references are supported, got "{ref}".')
    target = defs.get(ref[len(_REF_PREFIX) :])
    if not isinstance(target, dict):
        raise ValueError(f'Unresolved schema reference "{ref}".')
    return target
