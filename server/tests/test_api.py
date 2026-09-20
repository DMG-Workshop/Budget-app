"""The HTTP surface, driven end to end against a fake provider."""

import json

import pytest
from fastapi.testclient import TestClient

from .conftest import FakeProvider, valid_audit, valid_audit_json


@pytest.fixture
def env(tmp_path, monkeypatch):
    """A server with its own data directory and no ambient configuration."""
    from app import config as config_module
    from app import main as main_module

    for name in (
        "COLDWATER_PROVIDER", "COLDWATER_MODEL", "COLDWATER_API_KEY",
        "COLDWATER_BASE_URL", "COLDWATER_CURRENCY", "COLDWATER_KEEP_HISTORY",
        "COLDWATER_LOCAL_FLAVOR",
    ):
        monkeypatch.delenv(name, raising=False)

    monkeypatch.setattr(config_module, "DATA_DIR", tmp_path)
    monkeypatch.setattr(config_module, "CONFIG_FILE", tmp_path / "config.json")
    monkeypatch.setattr(main_module, "AUTH_TOKEN", None)
    return main_module, monkeypatch


@pytest.fixture
def client(env):
    main_module, _ = env
    with TestClient(main_module.app) as c:
        yield c


def use_provider(env, provider):
    main_module, monkeypatch = env
    monkeypatch.setattr(main_module, "build_provider", lambda config, http: provider)
    return provider


def upload(client, pdf: bytes, name: str = "march.pdf"):
    return client.post(
        "/api/audit", files={"file": (name, pdf, "application/pdf")}
    )


class TestHealthAndConfig:
    def test_health_reports_the_configured_provider(self, client):
        body = client.get("/api/health").json()
        assert body["ok"] is True
        assert body["provider"] == "local"
        assert body["auth_required"] is False

    def test_defaults_to_a_local_provider_and_no_history(self, client):
        config = client.get("/api/config").json()
        assert config["kind"] == "local"
        assert config["keep_history"] is False
        assert config["has_api_key"] is False

    def test_never_returns_the_api_key(self, client):
        client.put("/api/config", json={"kind": "anthropic", "api_key": "sk-secret"})
        body = client.get("/api/config").text
        assert "sk-secret" not in body
        assert json.loads(body)["has_api_key"] is True

    def test_switching_provider_switches_to_its_default_model(self, client):
        config = client.put("/api/config", json={"kind": "anthropic"}).json()
        assert config["model"] == "claude-opus-5"

    def test_an_omitted_key_keeps_the_stored_one(self, client):
        client.put("/api/config", json={"kind": "openai", "api_key": "sk-1"})
        config = client.put("/api/config", json={"kind": "openai", "model": "gpt-4o"}).json()
        assert config["has_api_key"] is True

    def test_an_empty_key_clears_it(self, client):
        client.put("/api/config", json={"kind": "openai", "api_key": "sk-1"})
        config = client.put("/api/config", json={"kind": "openai", "api_key": ""}).json()
        assert config["has_api_key"] is False

    def test_rejects_an_unknown_provider(self, client):
        response = client.put("/api/config", json={"kind": "skynet"})
        assert response.status_code == 400

    def test_settings_survive_a_restart(self, env):
        main_module, _ = env
        with TestClient(main_module.app) as first:
            first.put("/api/config", json={"kind": "gemini", "model": "gemini-2.5-pro"})
        with TestClient(main_module.app) as second:
            assert second.get("/api/config").json()["model"] == "gemini-2.5-pro"


class TestAudit:
    def test_audits_a_statement_end_to_end(self, env, client, statement_pdf):
        use_provider(env, FakeProvider([valid_audit_json()]))

        response = upload(client, statement_pdf)
        assert response.status_code == 200

        body = response.json()
        assert body["report"]["currency"] == "GBP"
        assert body["report"]["net_cashflow"] == 1000.0
        assert body["report"]["is_deficit"] is False
        assert body["arithmetic"]["is_clean"] is True
        assert body["breakdown"]["total"] == 2000.0
        assert body["route"] == "extracted_text"
        assert body["filename"] == "march.pdf"

    def test_reports_arithmetic_that_does_not_reconcile(
        self, env, client, statement_pdf
    ):
        audit = valid_audit()
        audit["total_expenses"] = 1500.0
        use_provider(env, FakeProvider([json.dumps(audit)]))

        body = upload(client, statement_pdf).json()
        assert body["arithmetic"]["has_errors"] is True
        assert any(
            f["pointer"] == "/total_expenses" for f in body["arithmetic"]["findings"]
        )

    def test_rejects_an_empty_file(self, client):
        assert upload(client, b"").status_code == 400

    def test_rejects_a_file_that_is_too_large(self, env, client):
        main_module, monkeypatch = env
        monkeypatch.setattr(main_module, "MAX_BYTES", 16)
        response = upload(client, b"x" * 64)
        assert response.status_code == 413
        assert "limit" in response.json()["detail"]

    def test_refuses_a_cloud_provider_with_no_key(self, client, statement_pdf):
        client.put("/api/config", json={"kind": "anthropic", "api_key": ""})
        response = upload(client, statement_pdf)
        assert response.status_code == 400
        assert "No API key" in response.json()["detail"]

    def test_surfaces_an_unfixable_model_as_422(self, env, client, statement_pdf):
        use_provider(env, FakeProvider(["nope", "still nope", "no"]))

        response = upload(client, statement_pdf)
        assert response.status_code == 422
        body = response.json()
        assert "after 3 attempts" in body["detail"]
        assert body["last_response"] == "no"

    def test_surfaces_a_provider_error_as_502(self, env, client, statement_pdf):
        from app.providers.base import ProviderError

        class Failing(FakeProvider):
            async def structure(self, **kwargs):
                raise ProviderError("Claude", 401, "invalid x-api-key")

        use_provider(env, Failing([]))
        response = upload(client, statement_pdf)
        assert response.status_code == 502
        assert response.json()["provider_message"] == "invalid x-api-key"

    def test_reports_why_a_scan_could_not_be_read(self, env, client):
        from .conftest import make_pdf

        use_provider(env, FakeProvider([valid_audit_json()]))
        response = upload(client, make_pdf([]))
        assert response.status_code == 422
        assert "no text layer" in response.json()["extraction_failure"]


class TestHistory:
    def test_nothing_is_stored_by_default(self, env, client, statement_pdf):
        use_provider(env, FakeProvider([valid_audit_json()]))
        body = upload(client, statement_pdf).json()

        assert "id" not in body
        assert client.get("/api/audits").json()["audits"] == []

    def test_stores_when_the_user_turns_it_on(self, env, client, statement_pdf):
        use_provider(env, FakeProvider([valid_audit_json(), valid_audit_json()]))
        client.put("/api/config", json={"keep_history": True})

        stored_id = upload(client, statement_pdf).json()["id"]
        listing = client.get("/api/audits").json()
        assert listing["keep_history"] is True
        assert len(listing["audits"]) == 1
        assert listing["audits"][0]["filename"] == "march.pdf"

        fetched = client.get(f"/api/audits/{stored_id}")
        assert fetched.status_code == 200
        assert fetched.json()["report"]["currency"] == "GBP"

    def test_delete_one_and_all(self, env, client, statement_pdf):
        use_provider(env, FakeProvider([valid_audit_json(), valid_audit_json()]))
        client.put("/api/config", json={"keep_history": True})

        first = upload(client, statement_pdf).json()["id"]
        upload(client, statement_pdf)

        assert client.delete(f"/api/audits/{first}").status_code == 200
        assert client.delete(f"/api/audits/{first}").status_code == 404
        assert client.delete("/api/audits").json()["deleted"] == 1
        assert client.get("/api/audits").json()["audits"] == []

    def test_unknown_audit_is_404(self, client):
        assert client.get("/api/audits/999").status_code == 404


class TestAuth:
    def test_the_token_is_enforced_when_set(self, env):
        main_module, monkeypatch = env
        monkeypatch.setattr(main_module, "AUTH_TOKEN", "letmein")

        with TestClient(main_module.app) as client:
            assert client.get("/api/config").status_code == 401
            assert client.get(
                "/api/config", headers={"x-coldwater-token": "letmein"}
            ).status_code == 200
            assert client.get("/api/config?token=letmein").status_code == 200
            # Health stays open so a container healthcheck needs no secret.
            assert client.get("/api/health").status_code == 200


class TestWebUi:
    def test_serves_the_page_and_its_assets(self, client):
        assert client.get("/").status_code == 200
        assert client.get("/static/css/app.css").status_code == 200
        assert client.get("/static/js/app.js").status_code == 200
        assert client.get("/manifest.webmanifest").status_code == 200
        assert client.get("/sw.js").status_code == 200
