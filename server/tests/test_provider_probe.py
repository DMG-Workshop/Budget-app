"""Connection testing against the endpoint the audit actually uses.

Driven by the real failure: a server address pointing at a web UI in front
of Ollama. `GET /v1/models` returned the genuine model list, so the test
reported "Connected · llama3.1:8b" — and then the first audit got 405 from
the UI's static-file handler, which does not accept POST.
"""

import json

import httpx
import pytest

from app.providers.adapters import OpenAiCompatibleProvider
from app.providers.base import ProviderConfig, ProviderError

MODELS_OK = {"data": [{"id": "llama3.1:8b"}]}

# FastAPI's shape, which is what a Python web UI in front of a model returns
# — not Ollama's {"error": ...}.
METHOD_NOT_ALLOWED = {"detail": "Method Not Allowed"}


def provider(handler, model: str = "llama3.1:8b") -> OpenAiCompatibleProvider:
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return OpenAiCompatibleProvider(
        ProviderConfig(
            kind="local", model=model, base_url="http://10.10.0.80:8080"
        ),
        client,
    )


def routes(chat_status: int = 200, chat_body: dict | None = None):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/models":
            return httpx.Response(200, json=MODELS_OK)
        if request.url.path == "/v1/chat/completions":
            return httpx.Response(
                chat_status,
                json=chat_body
                if chat_body is not None
                else {
                    "model": "llama3.1:8b",
                    "choices": [{"message": {"content": "{}"}}],
                },
            )
        return httpx.Response(404, json={"detail": "Not Found"})

    return handler


class TestConnectionTest:
    async def test_a_ui_in_front_of_the_model_is_not_connected(self):
        """The regression. Models list fine; the chat path refuses POST."""
        result = await provider(
            routes(chat_status=405, chat_body=METHOD_NOT_ALLOWED)
        ).test()

        assert result["ok"] is False
        assert "not a model API" in result["summary"]
        assert "11434" in result["detail"]
        assert "does not accept POST" in result["detail"]

    async def test_a_missing_chat_path_is_also_caught(self):
        result = await provider(chat_status_404()).test()
        assert result["ok"] is False
        assert "11434" in result["detail"]

    async def test_a_real_model_server_connects(self):
        result = await provider(routes()).test()
        assert result["ok"] is True
        assert result["summary"] == "Connected · llama3.1:8b"

    async def test_a_cold_model_is_reported_as_slow_not_broken(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/v1/models":
                return httpx.Response(200, json=MODELS_OK)
            raise httpx.ReadTimeout("too slow", request=request)

        result = await provider(handler).test()
        assert result["ok"] is True
        assert "slow to answer" in result["summary"]
        assert "still loading" in result["detail"]

    async def test_a_model_that_is_not_installed_fails_before_probing(self):
        result = await provider(routes(), model="mistral:7b").test()
        assert result["ok"] is False
        assert "not available" in result["summary"]

    async def test_an_upstream_error_on_the_probe_is_surfaced(self):
        result = await provider(
            routes(chat_status=500, chat_body={"error": "out of memory"})
        ).test()
        assert result["ok"] is False
        assert "out of memory" in result["detail"]


class TestAuditTimeErrors:
    async def test_405_explains_itself_instead_of_echoing_the_body(self):
        with pytest.raises(ProviderError) as caught:
            await provider(
                routes(chat_status=405, chat_body=METHOD_NOT_ALLOWED)
            ).structure(system="s", user_content="u", schema={})

        assert caught.value.status_code == 405
        assert "does not accept POST" in caught.value.message
        assert "11434" in caught.value.message
        # The old behaviour was to surface the raw body, which told the user
        # nothing they could act on.
        assert caught.value.message != json.dumps(METHOD_NOT_ALLOWED)

    async def test_a_genuine_provider_error_is_still_passed_through(self):
        with pytest.raises(ProviderError) as caught:
            await provider(
                routes(chat_status=400, chat_body={"error": "context length"})
            ).structure(system="s", user_content="u", schema={})

        assert "context length" in caught.value.message


def chat_status_404():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/models":
            return httpx.Response(200, json=MODELS_OK)
        return httpx.Response(404, json={"detail": "Not Found"})

    return handler
