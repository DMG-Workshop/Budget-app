"""The server must send exactly what the app sends.

Two different implementations of one prompt is how two clients start giving
different answers to the same statement. These tests compare what this server
produces against the contract Dart exported.
"""

from app.contract import audit_schema, reference_prompt
from app.prompts import system_prompt


def test_text_prompt_matches_the_exported_contract():
    assert system_prompt(attached=False, reference_date="2026-01-01") == (
        reference_prompt(attached=False)
    )


def test_attached_prompt_matches_the_exported_contract():
    assert system_prompt(
        attached=True,
        reference_date="2026-01-01",
        currency_hint="GBP",
    ) == reference_prompt(attached=True)


def test_user_context_block_matches_dart():
    from app.contract import CONTRACT_DIR

    expected = (CONTRACT_DIR / "harsh_auditor.context.txt").read_text(
        encoding="utf-8"
    )
    assert system_prompt(
        attached=False,
        reference_date="2026-01-01",
        user_context="{{USER_CONTEXT}}",
    ) == expected


def test_the_date_is_substituted():
    prompt = system_prompt(attached=False, reference_date="2026-09-19")
    assert "Today is 2026-09-19." in prompt
    assert "2026-01-01" not in prompt


def test_a_currency_hint_replaces_the_unknown_clause():
    prompt = system_prompt(
        attached=False, reference_date="2026-01-01", currency_hint="EUR"
    )
    assert "believes the currency is EUR" in prompt
    assert "Determine the currency from the document." not in prompt


def test_dropping_the_hint_on_the_attached_path_restores_the_unknown_clause():
    prompt = system_prompt(attached=True, reference_date="2026-01-01")
    assert "Determine the currency from the document." in prompt
    assert "believes the currency is" not in prompt


def test_schema_is_the_exported_one():
    schema = audit_schema()
    assert schema["type"] == "object"
    assert "harsh_audit_summary" in schema["required"]
    assert schema["additionalProperties"] is False
