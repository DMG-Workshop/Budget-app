"""The four backends, over httpx.

Request shapes are deliberately identical to the Dart adapters in
transcript_core and audit_core — the same endpoints, the same content blocks,
the same schema dialects — so a statement audited in a browser and on a phone
takes the same path to the same model.
"""

from __future__ import annotations

from typing import Any

import httpx

from ..dialects import SchemaDialect, render_schema
from .base import (
    Attachment,
    ProviderConfig,
    ProviderError,
    StructureResponse,
    Turn,
    error_message,
)

# Local models are slow to first token when cold — loading a 7B from disk can
# take most of a minute — so a cloud-scale timeout produces spurious failures.
_LOCAL_TIMEOUT = httpx.Timeout(600.0, connect=10.0)
_CLOUD_TIMEOUT = httpx.Timeout(600.0, connect=20.0)


class AnthropicProvider:
    name = "Claude"
    default_model = "claude-opus-5"
    api_version = "2023-06-01"

    def __init__(self, config: ProviderConfig, client: httpx.AsyncClient) -> None:
        self._config = config
        self._client = client
        self._base = (config.base_url or "https://api.anthropic.com").rstrip("/")

    @property
    def reads_documents(self) -> bool:
        return True

    @property
    def max_document_bytes(self) -> int:
        return 32 * 1024 * 1024

    @property
    def _headers(self) -> dict[str, str]:
        return {
            "x-api-key": self._config.api_key or "",
            "anthropic-version": self.api_version,
            "accept": "application/json",
        }

    async def structure(
        self,
        *,
        system: str,
        user_content: str,
        schema: dict[str, Any],
        prior_turns: list[Turn] | None = None,
        attachment: Attachment | None = None,
    ) -> StructureResponse:
        content: Any = user_content
        if attachment is not None:
            content = [
                {
                    "type": "document",
                    "source": {
                        "type": "base64",
                        "media_type": attachment.media_type,
                        "data": attachment.base64_data,
                    },
                    # Caches the parsed document so a repair round-trip does
                    # not pay to re-read the statement.
                    "cache_control": {"type": "ephemeral"},
                },
                {"type": "text", "text": user_content},
            ]

        response = await self._client.post(
            f"{self._base}/v1/messages",
            headers=self._headers,
            timeout=_CLOUD_TIMEOUT,
            json={
                "model": self._config.model,
                "max_tokens": 16000,
                "system": [
                    {
                        "type": "text",
                        "text": system,
                        "cache_control": {"type": "ephemeral"},
                    }
                ],
                "messages": [
                    *[{"role": t.role, "content": t.content} for t in (prior_turns or [])],
                    {"role": "user", "content": content},
                ],
                "output_config": {
                    "format": {
                        "type": "json_schema",
                        "schema": render_schema(schema, SchemaDialect.PLAIN),
                    }
                },
            },
        )

        body = _json_or_none(response)
        if response.status_code >= 400:
            raise ProviderError(
                self.name, response.status_code, error_message(body, response.text)
            )

        body = body or {}
        # A refusal arrives as HTTP 200; check before reading content or an
        # empty block is parsed as malformed JSON.
        if body.get("stop_reason") == "refusal":
            raise ProviderError(
                self.name, 200, "The model declined to process this statement."
            )

        text = "".join(
            block.get("text", "")
            for block in body.get("content", [])
            if isinstance(block, dict) and block.get("type") == "text"
        )
        usage = body.get("usage") or {}
        return StructureResponse(
            raw_text=text,
            input_tokens=usage.get("input_tokens"),
            output_tokens=usage.get("output_tokens"),
            model=body.get("model"),
        )

    async def test(self) -> dict[str, Any]:
        response = await self._client.get(
            f"{self._base}/v1/models",
            headers=self._headers,
            timeout=httpx.Timeout(15.0),
        )
        return _describe_test(self.name, response, self._config.model)


class GeminiProvider:
    name = "Gemini"
    default_model = "gemini-2.5-flash"

    def __init__(self, config: ProviderConfig, client: httpx.AsyncClient) -> None:
        self._config = config
        self._client = client
        self._base = (
            config.base_url or "https://generativelanguage.googleapis.com"
        ).rstrip("/")

    @property
    def reads_documents(self) -> bool:
        return True

    @property
    def max_document_bytes(self) -> int:
        # Inline data tops out around 20 MB on generateContent; held under it.
        return 18 * 1024 * 1024

    async def structure(
        self,
        *,
        system: str,
        user_content: str,
        schema: dict[str, Any],
        prior_turns: list[Turn] | None = None,
        attachment: Attachment | None = None,
    ) -> StructureResponse:
        parts: list[dict[str, Any]] = []
        if attachment is not None:
            parts.append(
                {
                    "inlineData": {
                        "mimeType": attachment.media_type,
                        "data": attachment.base64_data,
                    }
                }
            )
        parts.append({"text": user_content})

        response = await self._client.post(
            f"{self._base}/v1beta/models/{self._config.model}:generateContent",
            headers={
                "x-goog-api-key": self._config.api_key or "",
                "accept": "application/json",
            },
            timeout=_CLOUD_TIMEOUT,
            json={
                "systemInstruction": {"parts": [{"text": system}]},
                "contents": [
                    *[
                        {
                            "role": "model" if t.role == "assistant" else "user",
                            "parts": [{"text": t.content}],
                        }
                        for t in (prior_turns or [])
                    ],
                    {"role": "user", "parts": parts},
                ],
                "generationConfig": {
                    "responseMimeType": "application/json",
                    "responseSchema": render_schema(schema, SchemaDialect.GEMINI),
                },
            },
        )

        body = _json_or_none(response)
        if response.status_code >= 400:
            raise ProviderError(
                self.name, response.status_code, error_message(body, response.text)
            )

        body = body or {}
        candidates = body.get("candidates") or []
        parts_out = (
            (candidates[0].get("content") or {}).get("parts") or []
            if candidates and isinstance(candidates[0], dict)
            else []
        )
        text = "".join(p.get("text", "") for p in parts_out if isinstance(p, dict))
        usage = body.get("usageMetadata") or {}
        return StructureResponse(
            raw_text=text,
            input_tokens=usage.get("promptTokenCount"),
            output_tokens=usage.get("candidatesTokenCount"),
            model=body.get("modelVersion"),
        )

    async def test(self) -> dict[str, Any]:
        response = await self._client.get(
            f"{self._base}/v1beta/models",
            headers={"x-goog-api-key": self._config.api_key or ""},
            timeout=httpx.Timeout(15.0),
        )
        return _describe_test(self.name, response, self._config.model)


class OpenAiCompatibleProvider:
    """OpenAI, and every local server that speaks its chat-completions API.

    Ollama and LM Studio both serve /v1/chat/completions, which is what makes
    one adapter enough for all three. The differences that matter are the
    timeout, whether a key is required, and whether strict structured output
    is supported — a local runtime usually ignores response_format, which is
    exactly why the pipeline still parses tolerantly and repairs.
    """

    def __init__(self, config: ProviderConfig, client: httpx.AsyncClient) -> None:
        self._config = config
        self._client = client
        self._is_local = config.kind == "local"
        default = (
            "http://127.0.0.1:11434"
            if config.flavor == "ollama"
            else "http://127.0.0.1:1234"
        )
        self._base = (
            config.base_url or (default if self._is_local else "https://api.openai.com")
        ).rstrip("/")
        self.name = (
            ("Ollama" if config.flavor == "ollama" else "LM Studio")
            if self._is_local
            else "OpenAI"
        )

    @property
    def reads_documents(self) -> bool:
        return False

    @property
    def max_document_bytes(self) -> int:
        return 0

    @property
    def _headers(self) -> dict[str, str]:
        headers = {"accept": "application/json"}
        if self._config.api_key:
            headers["authorization"] = f"Bearer {self._config.api_key}"
        return headers

    async def structure(
        self,
        *,
        system: str,
        user_content: str,
        schema: dict[str, Any],
        prior_turns: list[Turn] | None = None,
        attachment: Attachment | None = None,
    ) -> StructureResponse:
        # Attachments are not representable here; the pipeline routes around
        # this rather than silently dropping the document.
        del attachment

        response = await self._client.post(
            f"{self._base}/v1/chat/completions",
            headers=self._headers,
            timeout=_LOCAL_TIMEOUT if self._is_local else _CLOUD_TIMEOUT,
            json={
                "model": self._config.model,
                "messages": [
                    {"role": "system", "content": system},
                    *[{"role": t.role, "content": t.content} for t in (prior_turns or [])],
                    {"role": "user", "content": user_content},
                ],
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {
                        "name": "audit_report",
                        "strict": True,
                        "schema": render_schema(schema, SchemaDialect.OPENAI_STRICT),
                    },
                },
            },
        )

        body = _json_or_none(response)
        if response.status_code >= 400:
            detail = (
                _wrong_endpoint_detail(self._base)
                if response.status_code in _NOT_A_CHAT_ENDPOINT
                else error_message(body, response.text)
            )
            raise ProviderError(self.name, response.status_code, detail)

        body = body or {}
        choices = body.get("choices") or []
        text = ""
        if choices and isinstance(choices[0], dict):
            text = (choices[0].get("message") or {}).get("content") or ""

        usage = body.get("usage") or {}
        return StructureResponse(
            raw_text=text,
            input_tokens=usage.get("prompt_tokens"),
            output_tokens=usage.get("completion_tokens"),
            model=body.get("model"),
        )

    async def test(self) -> dict[str, Any]:
        listing = await self._client.get(
            f"{self._base}/v1/models",
            headers=self._headers,
            timeout=httpx.Timeout(10.0),
        )
        described = _describe_test(self.name, listing, self._config.model)
        if not described["ok"]:
            return described

        # Listing models proves almost nothing: a web UI in front of Ollama
        # serves /v1/models with the real model list and then refuses the
        # chat path, which reads as "Connected" and fails on the first
        # audit. So the test does what the audit does, for one token.
        return await self._probe_chat(described)

    async def _probe_chat(self, described: dict[str, Any]) -> dict[str, Any]:
        try:
            response = await self._client.post(
                f"{self._base}/v1/chat/completions",
                headers=self._headers,
                # Short: this is a reachability probe, and a cold model
                # taking longer is reported as a caveat rather than a
                # failure below.
                timeout=httpx.Timeout(30.0, connect=10.0),
                json={
                    "model": self._config.model,
                    "messages": [{"role": "user", "content": "hi"}],
                    "max_tokens": 1,
                },
            )
        except (httpx.ReadTimeout, httpx.WriteTimeout, httpx.PoolTimeout):
            return {
                **described,
                "summary": f"Connected · {self._config.model} · slow to answer",
                "detail": "The model server is reachable but did not reply "
                "within 30 seconds, which usually means the model is still "
                "loading. The first audit will be slow.",
            }
        except httpx.HTTPError as exc:
            return {
                **described,
                "ok": False,
                "summary": f"Could not reach {self.name}",
                "detail": str(exc),
            }

        if response.status_code in _NOT_A_CHAT_ENDPOINT:
            return {
                **described,
                "ok": False,
                "summary": f"That is not a model API ({response.status_code})",
                "detail": _wrong_endpoint_detail(self._base),
            }

        if response.status_code >= 400:
            return {
                **described,
                "ok": False,
                "summary": f"{self.name} returned {response.status_code}",
                "detail": error_message(
                    _json_or_none(response), response.text
                )[:400],
            }

        return described


def build_provider(config: ProviderConfig, client: httpx.AsyncClient):
    if config.kind == "anthropic":
        return AnthropicProvider(config, client)
    if config.kind == "gemini":
        return GeminiProvider(config, client)
    if config.kind in ("openai", "local"):
        return OpenAiCompatibleProvider(config, client)
    raise ValueError(f"Unknown provider kind: {config.kind}")


#: Statuses that mean the path is not a chat-completions endpoint. 405 in
#: particular is what a web UI in front of a model returns: its static-file
#: handler matches the path for GET and refuses POST.
_NOT_A_CHAT_ENDPOINT = (404, 405)


def _wrong_endpoint_detail(base_url: str) -> str:
    return (
        f"{base_url} answered, but it does not accept POST on "
        "/v1/chat/completions. That is what a web front-end for a model "
        "looks like — Open WebUI and similar serve /v1/models happily and "
        "refuse the chat path. Point this at the model server itself: "
        "Ollama listens on port 11434 and LM Studio on 1234."
    )


def _json_or_none(response: httpx.Response) -> Any:
    try:
        return response.json()
    except ValueError:
        return None


def _describe_test(name: str, response: httpx.Response, model: str) -> dict[str, Any]:
    if response.status_code >= 400:
        body = _json_or_none(response)
        return {
            "ok": False,
            "summary": f"{name} returned {response.status_code}",
            "detail": error_message(body, response.text)[:400],
        }

    body = _json_or_none(response) or {}
    raw = body.get("data") or body.get("models") or []
    models = [
        m.get("id") or m.get("name")
        for m in raw
        if isinstance(m, dict) and (m.get("id") or m.get("name"))
    ]

    if models and model not in models:
        return {
            "ok": False,
            "summary": f"Connected, but {model} is not available",
            "detail": "Available: " + ", ".join(str(m) for m in models[:8]),
            "models": models,
        }

    return {
        "ok": True,
        "summary": f"Connected · {model}",
        "models": models,
    }
