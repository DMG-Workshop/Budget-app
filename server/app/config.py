"""Server configuration.

Layered deliberately: environment variables win, then the JSON file in the
data directory, then defaults. The environment is how the container is
configured at boot; the file is how the web UI persists a change the user
made at runtime; and a stock appliance boots with neither and still serves a
page that explains what to set.

The API key is the one value that never appears in a response body. It is
stored, it is used, and `/api/config` reports only whether one is present.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .providers.base import ProviderConfig

DATA_DIR = Path(os.environ.get("COLDWATER_DATA_DIR", "/data"))
CONFIG_FILE = DATA_DIR / "config.json"

_DEFAULT_MODELS = {
    "anthropic": "claude-opus-5",
    "gemini": "gemini-2.5-flash",
    "openai": "gpt-4o",
    "local": "llama3.1:8b",
}

VALID_KINDS = tuple(_DEFAULT_MODELS)
VALID_FLAVORS = ("ollama", "lmstudio")


@dataclass(frozen=True)
class Settings:
    provider: ProviderConfig
    #: Currency the user says their statements are in. The model is still told
    #: to prefer whatever the document says.
    currency_hint: str | None = None
    #: Free text about the user's circumstances, passed to the prompt as facts
    #: rather than instructions.
    user_context: str | None = None
    #: Off by default. A bank statement is about as sensitive as a document
    #: gets, and keeping a history of them is a choice the user makes.
    keep_history: bool = False

    def to_public_json(self) -> dict[str, Any]:
        """What the web UI is allowed to see. Never the key itself."""
        return {
            "kind": self.provider.kind,
            "model": self.provider.model,
            "base_url": self.provider.base_url,
            "flavor": self.provider.flavor,
            "has_api_key": bool(self.provider.api_key),
            "needs_api_key": self.provider.needs_api_key,
            "currency_hint": self.currency_hint,
            "user_context": self.user_context,
            "keep_history": self.keep_history,
        }


def default_model_for(kind: str) -> str:
    return _DEFAULT_MODELS.get(kind, "")


def load_settings() -> Settings:
    stored: dict[str, Any] = {}
    if CONFIG_FILE.is_file():
        try:
            stored = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except ValueError:
            # A corrupt config file must not stop the server booting; the UI
            # can write a good one over the top.
            stored = {}

    kind = _first(
        os.environ.get("COLDWATER_PROVIDER"),
        stored.get("kind"),
        "local",
    )
    if kind not in VALID_KINDS:
        kind = "local"

    flavor = _first(
        os.environ.get("COLDWATER_LOCAL_FLAVOR"), stored.get("flavor"), "ollama"
    )
    if flavor not in VALID_FLAVORS:
        flavor = "ollama"

    return Settings(
        provider=ProviderConfig(
            kind=kind,
            model=_first(
                os.environ.get("COLDWATER_MODEL"),
                stored.get("model"),
                default_model_for(kind),
            ),
            api_key=_first(
                os.environ.get("COLDWATER_API_KEY"), stored.get("api_key"), None
            ),
            base_url=_first(
                os.environ.get("COLDWATER_BASE_URL"), stored.get("base_url"), None
            ),
            flavor=flavor,
        ),
        currency_hint=_first(
            os.environ.get("COLDWATER_CURRENCY"), stored.get("currency_hint"), None
        ),
        user_context=stored.get("user_context"),
        keep_history=_as_bool(
            _first(
                os.environ.get("COLDWATER_KEEP_HISTORY"),
                stored.get("keep_history"),
                False,
            )
        ),
    )


def save_settings(settings: Settings) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "kind": settings.provider.kind,
        "model": settings.provider.model,
        "api_key": settings.provider.api_key,
        "base_url": settings.provider.base_url,
        "flavor": settings.provider.flavor,
        "currency_hint": settings.currency_hint,
        "user_context": settings.user_context,
        "keep_history": settings.keep_history,
    }
    CONFIG_FILE.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    # The file holds an API key, so it is not world-readable even on a
    # single-user appliance.
    CONFIG_FILE.chmod(0o600)


def apply_update(current: Settings, update: dict[str, Any]) -> Settings:
    """Merges a partial update from the web UI onto the current settings."""
    provider = current.provider

    kind = update.get("kind", provider.kind)
    if kind not in VALID_KINDS:
        raise ValueError(f"Unknown provider: {kind}")

    flavor = update.get("flavor", provider.flavor)
    if flavor not in VALID_FLAVORS:
        raise ValueError(f"Unknown local flavour: {flavor}")

    # Switching backend switches to that backend's default model unless a
    # model is named in the same change; carrying "claude-opus-5" over to
    # Ollama would produce a confusing 404 from the local server.
    model = update.get("model")
    if not model:
        model = provider.model if kind == provider.kind else default_model_for(kind)

    # An omitted key keeps the stored one; an empty string clears it.
    api_key = update["api_key"] if "api_key" in update else provider.api_key
    if api_key == "":
        api_key = None

    base_url = update.get("base_url", provider.base_url) or None

    return replace(
        current,
        provider=ProviderConfig(
            kind=kind,
            model=model,
            api_key=api_key,
            base_url=base_url,
            flavor=flavor,
        ),
        currency_hint=(update.get("currency_hint", current.currency_hint) or None),
        user_context=(update.get("user_context", current.user_context) or None),
        keep_history=_as_bool(update.get("keep_history", current.keep_history)),
    )


def _first(*values: Any) -> Any:
    for value in values:
        if value is not None and value != "":
            return value
    return None


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)
