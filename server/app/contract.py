"""The audit contract, loaded from the files Dart exports.

The schema and the prompt are authored once, in `packages/audit_core`, and
written out by `dart run tool/export_contract.dart`. This module reads those
files rather than restating them, so the server and the app cannot disagree
about what a valid audit looks like. `tests/test_contract_parity.py` fails the
build if the rendered prompt drifts from the exported reference.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

# server/app/contract.py -> server/app -> server -> repository root
_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = Path(
    # Set in the container image, where the contract is copied in beside the
    # application rather than sitting two directories up in a git checkout.
    __import__("os").environ.get("COLDWATER_CONTRACT_DIR", _ROOT / "contracts")
)


@lru_cache(maxsize=1)
def audit_schema() -> dict[str, Any]:
    """The canonical JSON schema, exactly as the app sends it."""
    path = CONTRACT_DIR / "audit_report.schema.json"
    if not path.is_file():
        raise FileNotFoundError(
            f"The audit contract is missing at {path}. Run "
            "`dart run tool/export_contract.dart` in packages/audit_core, or "
            "set COLDWATER_CONTRACT_DIR."
        )
    return json.loads(path.read_text(encoding="utf-8"))


@lru_cache(maxsize=2)
def reference_prompt(attached: bool) -> str:
    """The exported prompt for one of the two ingestion paths.

    Used by the parity test, not at request time — the server builds its
    prompt from the same rules so it can substitute a live date.
    """
    name = "harsh_auditor.attached.txt" if attached else "harsh_auditor.text.txt"
    return (CONTRACT_DIR / name).read_text(encoding="utf-8")
