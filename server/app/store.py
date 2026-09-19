"""Audit history, in SQLite.

Off unless the user turns it on. A stored audit contains the model's verdict
on every line of a bank statement, which is about as sensitive as a document
gets — so the default is to keep nothing, and the UI says so.

The PDF itself is never stored. Only the audit JSON is.
"""

from __future__ import annotations

import json
import sqlite3
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_SCHEMA = """
CREATE TABLE IF NOT EXISTS audits (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at  TEXT    NOT NULL,
    filename    TEXT    NOT NULL,
    currency    TEXT    NOT NULL,
    period_start TEXT   NOT NULL,
    period_end  TEXT    NOT NULL,
    net_cashflow_minor INTEGER NOT NULL,
    provider    TEXT    NOT NULL,
    model       TEXT,
    outcome     TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS audits_created_at ON audits (created_at DESC);
"""


@dataclass(frozen=True)
class StoredAudit:
    id: int
    created_at: str
    filename: str
    currency: str
    period_start: str
    period_end: str
    net_cashflow: float
    provider: str
    model: str | None

    def to_json(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "created_at": self.created_at,
            "filename": self.filename,
            "currency": self.currency,
            "period_start": self.period_start,
            "period_end": self.period_end,
            "net_cashflow": self.net_cashflow,
            "provider": self.provider,
            "model": self.model,
        }


class AuditStore:
    def __init__(self, path: Path) -> None:
        self._path = path
        self._path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self._connect()) as db:
            db.executescript(_SCHEMA)
            db.commit()

    def _connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self._path)
        db.row_factory = sqlite3.Row
        return db

    def save(
        self,
        *,
        filename: str,
        provider: str,
        outcome_json: dict[str, Any],
    ) -> int:
        report = outcome_json["report"]
        with closing(self._connect()) as db:
            cursor = db.execute(
                """
                INSERT INTO audits (
                    created_at, filename, currency, period_start, period_end,
                    net_cashflow_minor, provider, model, outcome
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    filename,
                    report["currency"],
                    report["period_start"],
                    report["period_end"],
                    round(report["net_cashflow"] * 100),
                    provider,
                    outcome_json.get("model"),
                    json.dumps(outcome_json),
                ),
            )
            db.commit()
            return int(cursor.lastrowid or 0)

    def list(self, limit: int = 50) -> list[StoredAudit]:
        with closing(self._connect()) as db:
            rows = db.execute(
                "SELECT * FROM audits ORDER BY created_at DESC, id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [_row_to_audit(row) for row in rows]

    def get(self, audit_id: int) -> dict[str, Any] | None:
        with closing(self._connect()) as db:
            row = db.execute(
                "SELECT outcome FROM audits WHERE id = ?", (audit_id,)
            ).fetchone()
        return json.loads(row["outcome"]) if row else None

    def delete(self, audit_id: int) -> bool:
        with closing(self._connect()) as db:
            cursor = db.execute("DELETE FROM audits WHERE id = ?", (audit_id,))
            db.commit()
            return cursor.rowcount > 0

    def clear(self) -> int:
        with closing(self._connect()) as db:
            cursor = db.execute("DELETE FROM audits")
            db.commit()
            return cursor.rowcount


def _row_to_audit(row: sqlite3.Row) -> StoredAudit:
    return StoredAudit(
        id=row["id"],
        created_at=row["created_at"],
        filename=row["filename"],
        currency=row["currency"],
        period_start=row["period_start"],
        period_end=row["period_end"],
        net_cashflow=row["net_cashflow_minor"] / 100,
        provider=row["provider"],
        model=row["model"],
    )
