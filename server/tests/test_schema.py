"""The schema the server sends must be the one the app sends."""

import pytest

from app.contract import audit_schema
from app.dialects import SchemaDialect, render_schema
from app.validator import SchemaValidator

from .conftest import valid_audit


def _objects(node, found=None):
    found = [] if found is None else found
    if isinstance(node, list):
        for item in node:
            _objects(item, found)
    elif isinstance(node, dict):
        if node.get("type") == "object" and isinstance(node.get("properties"), dict):
            found.append(node)
        for value in node.values():
            _objects(value, found)
    return found


def test_every_property_is_required_as_openai_strict_demands():
    for obj in _objects(audit_schema()):
        assert set(obj["properties"]) <= set(obj.get("required", []))


def test_every_object_forbids_additional_properties():
    for obj in _objects(audit_schema()):
        assert obj["additionalProperties"] is False


def test_plain_keeps_defs_and_drops_annotations():
    rendered = render_schema(audit_schema(), SchemaDialect.PLAIN)
    assert "$defs" in rendered
    assert "$schema" not in rendered
    assert "$id" not in rendered


def test_openai_strict_inlines_every_reference():
    rendered = render_schema(audit_schema(), SchemaDialect.OPENAI_STRICT)
    assert "$defs" not in rendered
    assert "$ref" not in str(rendered)


def test_gemini_drops_additional_properties_and_uses_nullable():
    rendered = render_schema(audit_schema(), SchemaDialect.GEMINI)
    assert "additionalProperties" not in str(rendered)
    assert "$ref" not in str(rendered)

    date = rendered["properties"]["needs"]["items"]["properties"]["evidence"][
        "properties"
    ]["date"]
    assert date["nullable"] is True
    assert date["type"] == "string"
    assert "propertyOrdering" in rendered


def test_gemini_refuses_a_union_it_cannot_express():
    schema = {"type": "object", "properties": {"x": {"type": ["string", "number"]}}}
    with pytest.raises(ValueError, match="cannot express a union"):
        render_schema(schema, SchemaDialect.GEMINI)


class TestValidation:
    validator = SchemaValidator(audit_schema())

    def test_accepts_a_well_formed_audit(self):
        assert self.validator.validate(valid_audit()) == []

    def test_rejects_a_missing_required_field(self):
        audit = valid_audit()
        del audit["harsh_audit_summary"]
        pointers = [v.pointer for v in self.validator.validate(audit)]
        assert "/harsh_audit_summary" in pointers

    def test_rejects_an_unknown_severity(self):
        audit = valid_audit()
        audit["wasteful_leaks"][0]["severity"] = "apocalyptic"
        assert self.validator.validate(audit)

    def test_rejects_a_field_the_model_invented(self):
        audit = valid_audit()
        audit["encouragement"] = "You are doing great!"
        pointers = [v.pointer for v in self.validator.validate(audit)]
        assert "/encouragement" in pointers

    def test_accepts_a_null_evidence_date(self):
        audit = valid_audit()
        audit["needs"][0]["evidence"]["date"] = None
        assert self.validator.validate(audit) == []

    def test_a_bool_is_not_an_integer(self):
        # Python says isinstance(True, int); JSON Schema does not.
        assert SchemaValidator({"type": "integer"}).validate(True)
