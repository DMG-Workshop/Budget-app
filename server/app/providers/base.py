"""Provider-facing types, shared by the four adapters."""

from __future__ import annotations

import base64
from dataclasses import dataclass, field
from typing import Any, Protocol


@dataclass(frozen=True)
class Attachment:
    """A document sent alongside the prompt."""

    data: bytes
    filename: str
    media_type: str = "application/pdf"

    @property
    def base64_data(self) -> str:
        return base64.b64encode(self.data).decode("ascii")

    @property
    def encoded_length(self) -> int:
        # Both APIs measure their limit against the encoded payload.
        return -(-len(self.data) * 4 // 3)


@dataclass(frozen=True)
class Turn:
    role: str  # 'user' | 'assistant'
    content: str


@dataclass(frozen=True)
class StructureResponse:
    raw_text: str
    input_tokens: int | None = None
    output_tokens: int | None = None
    model: str | None = None


@dataclass(frozen=True)
class ProviderConfig:
    kind: str  # anthropic | gemini | openai | local
    model: str
    api_key: str | None = None
    base_url: str | None = None
    flavor: str = "ollama"  # ollama | lmstudio, for local only

    @property
    def needs_api_key(self) -> bool:
        return self.kind != "local"


class ProviderError(Exception):
    """A provider returned something unusable. Never carries the API key."""

    def __init__(self, provider: str, status_code: int, message: str) -> None:
        super().__init__(f"{provider} ({status_code}): {message}")
        self.provider = provider
        self.status_code = status_code
        self.message = message


class Provider(Protocol):
    name: str

    @property
    def reads_documents(self) -> bool: ...

    @property
    def max_document_bytes(self) -> int: ...

    async def structure(
        self,
        *,
        system: str,
        user_content: str,
        schema: dict[str, Any],
        prior_turns: list[Turn] = ...,
        attachment: Attachment | None = ...,
    ) -> StructureResponse: ...

    async def test(self) -> dict[str, Any]: ...


def error_message(body: Any, raw: str) -> str:
    """Pulls the human-readable message out of a provider error body.

    Anthropic and OpenAI use {"error": {"message": ...}}; Ollama and LM Studio
    use {"error": "..."}. Falls back to the raw body, which is often an HTML
    page from a proxy in front of a local model server.
    """
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict) and isinstance(error.get("message"), str):
            return error["message"]
        if isinstance(error, str):
            return error
        if isinstance(body.get("message"), str):
            return body["message"]
    return raw
