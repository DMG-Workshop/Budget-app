from app.store import AuditStore

from .conftest import valid_audit


def outcome(net: float = 1000.0) -> dict:
    report = valid_audit()
    return {
        "report": {
            "currency": report["currency"],
            "period_start": report["period_start"],
            "period_end": report["period_end"],
            "net_cashflow": net,
        },
        "model": "fake-1",
    }


def test_round_trips_an_audit(tmp_path):
    store = AuditStore(tmp_path / "audits.db")
    audit_id = store.save(
        filename="march.pdf", provider="local", outcome_json=outcome()
    )

    listed = store.list()
    assert len(listed) == 1
    assert listed[0].filename == "march.pdf"
    assert listed[0].net_cashflow == 1000.0
    assert listed[0].provider == "local"
    assert store.get(audit_id)["model"] == "fake-1"


def test_stores_money_in_minor_units(tmp_path):
    store = AuditStore(tmp_path / "audits.db")
    store.save(filename="a.pdf", provider="local", outcome_json=outcome(-1234.56))
    assert store.list()[0].net_cashflow == -1234.56


def test_newest_first(tmp_path):
    store = AuditStore(tmp_path / "audits.db")
    for name in ("one.pdf", "two.pdf", "three.pdf"):
        store.save(filename=name, provider="local", outcome_json=outcome())
    assert [a.filename for a in store.list()] == ["three.pdf", "two.pdf", "one.pdf"]


def test_delete_and_clear(tmp_path):
    store = AuditStore(tmp_path / "audits.db")
    first = store.save(filename="a.pdf", provider="local", outcome_json=outcome())
    store.save(filename="b.pdf", provider="local", outcome_json=outcome())

    assert store.delete(first) is True
    assert store.delete(first) is False
    assert len(store.list()) == 1
    assert store.clear() == 1
    assert store.list() == []


def test_missing_audit_is_none(tmp_path):
    assert AuditStore(tmp_path / "audits.db").get(999) is None


def test_creates_its_directory(tmp_path):
    store = AuditStore(tmp_path / "nested" / "deeper" / "audits.db")
    assert store.list() == []
