"""Coldwater, self-hosted.

The same audit the phone app runs, served as a web page on your own network.
It reads the same exported contract, sends the same prompt to the same four
backends, and applies the same offline checks afterwards.
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import config as config_module
from .audit import AuditError, AuditPipeline
from .ingest.pdf import MAX_BYTES, extract_text
from .providers.adapters import build_provider
from .providers.base import ProviderError
from .store import AuditStore

WEB_DIR = Path(__file__).resolve().parent.parent / "web"

#: Optional shared secret. Unset by default: on a home network behind the
#: appliance's own reverse proxy there is nobody else to keep out, and a
#: password nobody set is a password nobody can lose. Set it when the server
#: is reachable by anyone you would not hand the statement to.
AUTH_TOKEN = os.environ.get("COLDWATER_TOKEN") or None


@asynccontextmanager
async def lifespan(app: FastAPI):
    # One client for the process: connection reuse matters most against a
    # local model server, which is often on the other side of Wi-Fi.
    app.state.http = httpx.AsyncClient(follow_redirects=False)
    app.state.store = AuditStore(config_module.DATA_DIR / "audits.db")
    try:
        yield
    finally:
        await app.state.http.aclose()


app = FastAPI(title="Coldwater", version="0.1.0", lifespan=lifespan)


def require_auth(request: Request) -> None:
    if AUTH_TOKEN is None:
        return
    supplied = request.headers.get("x-coldwater-token") or request.query_params.get(
        "token"
    )
    if supplied != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Bad or missing token.")


def _settings() -> config_module.Settings:
    return config_module.load_settings()


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------


@app.get("/api/health")
async def health() -> dict[str, Any]:
    settings = _settings()
    return {
        "ok": True,
        "provider": settings.provider.kind,
        "model": settings.provider.model,
        "auth_required": AUTH_TOKEN is not None,
    }


@app.get("/api/config", dependencies=[Depends(require_auth)])
async def get_config() -> dict[str, Any]:
    return _settings().to_public_json()


@app.put("/api/config", dependencies=[Depends(require_auth)])
async def put_config(update: dict[str, Any]) -> dict[str, Any]:
    try:
        settings = config_module.apply_update(_settings(), update)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    config_module.save_settings(settings)
    return settings.to_public_json()


@app.post("/api/config/test", dependencies=[Depends(require_auth)])
async def test_config(request: Request) -> dict[str, Any]:
    settings = _settings()
    provider = build_provider(settings.provider, request.app.state.http)
    try:
        return await provider.test()
    except httpx.HTTPError as exc:
        return {
            "ok": False,
            "summary": f"Could not reach {provider.name}",
            "detail": _explain_transport(exc),
        }


@app.post("/api/audit", dependencies=[Depends(require_auth)])
async def audit(
    request: Request,
    file: UploadFile = File(...),
    currency_hint: str | None = Form(default=None),
    user_context: str | None = Form(default=None),
) -> JSONResponse:
    data = await file.read()

    if not data:
        raise HTTPException(status_code=400, detail="That file is empty.")
    if len(data) > MAX_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"That file is {len(data) / 1024 / 1024:.1f} MB. The limit "
            f"is {MAX_BYTES // 1024 // 1024} MB — bank statements are rarely "
            "more than a few.",
        )

    settings = _settings()
    if settings.provider.needs_api_key and not settings.provider.api_key:
        raise HTTPException(
            status_code=400,
            detail=f"No API key configured for {settings.provider.kind}. Add "
            "one in settings, or switch to a local model, which needs no key.",
        )

    extraction = extract_text(data)
    provider = build_provider(settings.provider, request.app.state.http)

    try:
        outcome = await AuditPipeline(provider).run(
            filename=file.filename or "statement.pdf",
            pdf_bytes=data,
            extracted_text=extraction.text,
            currency_hint=currency_hint or settings.currency_hint,
            user_context=user_context or settings.user_context,
        )
    except AuditError as exc:
        return JSONResponse(
            status_code=422,
            content={
                "detail": exc.message,
                "violations": exc.violations,
                "last_response": (exc.last_response or "")[:2000],
                "extraction_failure": extraction.failure,
            },
        )
    except ProviderError as exc:
        return JSONResponse(
            status_code=502,
            content={"detail": f"{exc.provider} returned {exc.status_code}.", "provider_message": exc.message},
        )
    except httpx.HTTPError as exc:
        return JSONResponse(
            status_code=502,
            content={"detail": _explain_transport(exc)},
        )

    payload = outcome.to_json()
    payload["filename"] = file.filename
    payload["extraction_failure"] = extraction.failure
    payload["page_count"] = extraction.page_count

    if settings.keep_history:
        payload["id"] = request.app.state.store.save(
            filename=file.filename or "statement.pdf",
            provider=settings.provider.kind,
            outcome_json=payload,
        )

    return JSONResponse(payload)


@app.get("/api/audits", dependencies=[Depends(require_auth)])
async def list_audits(request: Request) -> dict[str, Any]:
    return {
        "keep_history": _settings().keep_history,
        "audits": [a.to_json() for a in request.app.state.store.list()],
    }


@app.get("/api/audits/{audit_id}", dependencies=[Depends(require_auth)])
async def get_audit(request: Request, audit_id: int) -> dict[str, Any]:
    stored = request.app.state.store.get(audit_id)
    if stored is None:
        raise HTTPException(status_code=404, detail="No such audit.")
    return stored


@app.delete("/api/audits/{audit_id}", dependencies=[Depends(require_auth)])
async def delete_audit(request: Request, audit_id: int) -> dict[str, Any]:
    if not request.app.state.store.delete(audit_id):
        raise HTTPException(status_code=404, detail="No such audit.")
    return {"deleted": audit_id}


@app.delete("/api/audits", dependencies=[Depends(require_auth)])
async def clear_audits(request: Request) -> dict[str, Any]:
    return {"deleted": request.app.state.store.clear()}


# ---------------------------------------------------------------------------
# The web UI
# ---------------------------------------------------------------------------


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(WEB_DIR / "index.html")


@app.get("/manifest.webmanifest")
async def manifest() -> FileResponse:
    return FileResponse(
        WEB_DIR / "manifest.webmanifest", media_type="application/manifest+json"
    )


@app.get("/sw.js")
async def service_worker() -> FileResponse:
    # Served from the root so its scope covers the whole origin.
    return FileResponse(WEB_DIR / "sw.js", media_type="text/javascript")


if WEB_DIR.is_dir():
    app.mount("/static", StaticFiles(directory=WEB_DIR), name="static")


def _explain_transport(exc: httpx.HTTPError) -> str:
    """Turns a transport failure into the remedy rather than the symptom."""
    if isinstance(exc, httpx.ConnectError):
        return (
            "Nothing answered at that address. Check the model server is "
            "running and listening on the network rather than only on its own "
            "loopback."
        )
    if isinstance(exc, httpx.ConnectTimeout):
        return "The connection timed out before the server answered."
    if isinstance(exc, httpx.ReadTimeout):
        return (
            "The model did not answer in time. A local model loading for the "
            "first time can take a while; try again once it is warm."
        )
    return str(exc) or "The request could not be sent."
