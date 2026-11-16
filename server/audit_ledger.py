#!/usr/bin/env python3
"""Tamper-evident audit trail and four-eyes persistence (stdlib only).

Every audit event and every sign-off is appended to a SHA-256 hash chain in
SQLite. Changing any historical row breaks the chain from that point forward,
which is what `chainIntact` reports.

    entry_hash = sha256(prev_hash | timestamp | event_type | actor | entity | summary)

The genesis entry chains from sixty-four zeros.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "data" / "cockpit_audit.db"
GENESIS = "0" * 64


def _connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with _connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS audit_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp_utc TEXT NOT NULL,
                event_type TEXT NOT NULL,
                actor TEXT NOT NULL,
                entity_ref TEXT NOT NULL,
                summary TEXT NOT NULL,
                prev_hash TEXT NOT NULL,
                entry_hash TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS four_eyes_signoffs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                claim_id TEXT NOT NULL,
                subjectivity_type TEXT NOT NULL,
                claims_examiner TEXT NOT NULL,
                technical_accountant TEXT NOT NULL,
                approved INTEGER NOT NULL,
                timestamp_utc TEXT NOT NULL
            );
            """
        )
        count = conn.execute("SELECT COUNT(*) AS n FROM audit_events").fetchone()["n"]
        if count == 0:
            _append(conn, "GENESIS", "system", "ledger", "genesis entry", GENESIS)


def _hash(prev: str, ts: str, event_type: str, actor: str, entity: str, summary: str) -> str:
    payload = f"{prev}|{ts}|{event_type}|{actor}|{entity}|{summary}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _append(conn: sqlite3.Connection, event_type: str, actor: str,
            entity: str, summary: str, prev_override: str | None = None) -> dict:
    row = conn.execute("SELECT entry_hash FROM audit_events ORDER BY id DESC LIMIT 1").fetchone()
    prev = prev_override if prev_override is not None else (row["entry_hash"] if row else GENESIS)
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    entry = _hash(prev, ts, event_type, actor, entity, summary)
    conn.execute(
        "INSERT INTO audit_events (timestamp_utc, event_type, actor, entity_ref, summary, prev_hash, entry_hash)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)",
        (ts, event_type, actor, entity, summary, prev, entry),
    )
    return {"timestamp_utc": ts, "event_type": event_type, "actor": actor,
            "entity_ref": entity, "summary": summary, "prev_hash": prev, "entry_hash": entry}


def append_event(event_type: str, actor: str, entity: str, summary: str) -> dict:
    init_db()
    with _connect() as conn:
        event = _append(conn, event_type, actor, entity, summary)
    return event


def record_signoff(claim_id: str, subjectivity_type: str, claims_examiner: str,
                   technical_accountant: str, approved: bool = True) -> dict:
    init_db()
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with _connect() as conn:
        conn.execute(
            "INSERT INTO four_eyes_signoffs"
            " (claim_id, subjectivity_type, claims_examiner, technical_accountant, approved, timestamp_utc)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (claim_id, subjectivity_type, claims_examiner, technical_accountant, 1 if approved else 0, ts),
        )
        event = _append(
            conn, "FOUR_EYES_SIGNOFF", claims_examiner, claim_id,
            f"{subjectivity_type} approved by {claims_examiner} / {technical_accountant}",
        )
    return {"claimId": claim_id, "subjectivityType": subjectivity_type,
            "claimsExaminer": claims_examiner, "technicalAccountant": technical_accountant,
            "approved": approved, "timestampUtc": ts, "event": event}


def list_signoffs() -> list[dict]:
    init_db()
    with _connect() as conn:
        rows = conn.execute("SELECT * FROM four_eyes_signoffs ORDER BY id DESC").fetchall()
    return [dict(r) for r in rows]


def signoffs_by_claim() -> dict:
    """Shape expected by the bordereau gate: claim -> list of attestations."""
    out: dict[str, list] = {}
    for row in list_signoffs():
        if not row["approved"]:
            continue
        out.setdefault(row["claim_id"], []).append({
            "claimsExaminer": row["claims_examiner"],
            "technicalAccountant": row["technical_accountant"],
            "subjectivityType": row["subjectivity_type"],
        })
    return out


def verify_chain() -> tuple[bool, int]:
    init_db()
    with _connect() as conn:
        rows = conn.execute("SELECT * FROM audit_events ORDER BY id ASC").fetchall()
    prev = GENESIS
    for row in rows:
        expected = _hash(prev, row["timestamp_utc"], row["event_type"], row["actor"],
                         row["entity_ref"], row["summary"])
        if row["prev_hash"] != prev or row["entry_hash"] != expected:
            return False, len(rows)
        prev = row["entry_hash"]
    return True, len(rows)


def list_events(limit: int = 50) -> list[dict]:
    init_db()
    with _connect() as conn:
        rows = conn.execute(
            "SELECT * FROM audit_events ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
    return [dict(r) for r in rows]


def reset() -> dict:
    init_db()
    with _connect() as conn:
        conn.execute("DELETE FROM four_eyes_signoffs")
        conn.execute("DELETE FROM audit_events")
        _append(conn, "GENESIS", "system", "ledger", "genesis entry", GENESIS)
    intact, length = verify_chain()
    return {"ok": True, "chainIntact": intact, "events": length}


def snapshot() -> dict:
    intact, length = verify_chain()
    return {
        "events": list_events(50),
        "eventCount": length,
        "chainIntact": intact,
        "fourEyesSignoffs": list_signoffs(),
    }


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "reset":
        print(json.dumps(reset(), indent=2))
    else:
        print(json.dumps(snapshot(), indent=2))
