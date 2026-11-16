#!/usr/bin/env python3
"""Extract a `BoundContract` from a reinsurance slip (.pdf or .txt).

Pure Python standard library. Two formats are supported:

* our own generated PDF 1.4 slips (uncompressed text streams), and
* simple external PDFs whose text lives in `BT ... ET` blocks, optionally
  Flate-compressed.

This is not a general PDF reader and does not pretend to be one. It reads the
one thing a slip actually contains — labelled fields — and reports what it could
not find instead of guessing silently.
"""

import re
import zlib
from pathlib import Path

FIELD_KEYS = {
    "contract_id", "contract_name", "counterparty", "credit_rating",
    "direction", "currency", "perils", "peril", "inuring_priority",
    "contract_type", "attachment", "occurrence_limit", "occ_limit",
    "aggregate_limit", "agg_limit", "reinstatement_rate_bps",
    "reinst_rate_bps", "base_premium", "share_bps", "event_cap",
    "commission_bps", "retention_line", "num_lines", "agg_attachment",
}

TYPE_ALIASES = {
    "xol": "xol", "xl": "xol", "excessofloss": "xol", "excess_of_loss": "xol",
    "quotashare": "quotaShare", "quota_share": "quotaShare", "qs": "quotaShare",
    "surplusshare": "surplusShare", "surplus_share": "surplusShare", "surplus": "surplusShare",
    "aggregatestoploss": "aggregateStopLoss", "aggregate_stop_loss": "aggregateStopLoss",
    "stoploss": "aggregateStopLoss", "stop_loss": "aggregateStopLoss",
}

RATINGS = {"AAA", "AA", "A", "BBB", "Unrated"}
DIRECTIONS = {"Inward", "Outward"}
CURRENCIES = {"EUR", "USD", "GBP", "JPY"}
PERILS = {"Windstorm", "Earthquake", "Flood", "Cyber"}


# --------------------------------------------------------------------------
# PDF text extraction
# --------------------------------------------------------------------------

def _unescape_pdf(s: bytes) -> str:
    out = []
    i = 0
    while i < len(s):
        c = s[i:i + 1]
        if c == b"\\" and i + 1 < len(s):
            nxt = s[i + 1:i + 2]
            mapping = {b"n": b"\n", b"r": b"\r", b"t": b"\t",
                       b"(": b"(", b")": b")", b"\\": b"\\"}
            out.append(mapping.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return b"".join(out).decode("latin-1")


def extract_pdf_text(data: bytes) -> str:
    """Pull text out of `BT ... ET` blocks, decompressing streams when possible."""
    if not data.startswith(b"%PDF"):
        raise ValueError("not a PDF: missing %PDF header")

    streams = []
    for match in re.finditer(rb"stream\r?\n(.*?)endstream", data, re.S):
        raw = match.group(1)
        try:
            streams.append(zlib.decompress(raw))
        except Exception:
            streams.append(raw)
    haystack = b"\n".join(streams) if streams else data

    lines = []
    # Word boundaries matter: "MARKET" contains "ET", and a naive
    # `BT(.*?)ET` would truncate the block before the first text literal.
    blocks = re.findall(rb"\bBT\b(.*?)\bET\b", haystack, re.S)
    for block in blocks:
        for literal in re.findall(rb"\((?:\\.|[^\\()])*\)", block, re.S):
            lines.append(_unescape_pdf(literal[1:-1]))

    if not lines:
        # No text layer we recognise. Return what is printable rather than
        # claiming the document is empty.
        decoded = data.decode("latin-1", errors="ignore")
        lines = [ln for ln in decoded.splitlines() if ln.strip()]
    return "\n".join(lines)


def extract_text(data: bytes, filename: str = "") -> str:
    if data.startswith(b"%PDF"):
        return extract_pdf_text(data)
    if filename.lower().endswith(".pdf"):
        raise ValueError("file has .pdf extension but no %PDF header")
    return data.decode("utf-8", errors="replace")


# --------------------------------------------------------------------------
# Field parsing
# --------------------------------------------------------------------------

def _norm_key(key: str) -> str:
    return re.sub(r"[\s\-]+", "_", key.strip().lower())


def _num(value: str) -> int:
    cleaned = re.sub(r"[,_\s]", "", value)
    return int(cleaned)


def parse_fields(text: str) -> dict:
    fields = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        norm = _norm_key(key)
        if norm in FIELD_KEYS and norm not in fields:
            fields[norm] = value.strip()
    return fields


def _perils(value: str, warnings: list) -> list:
    raw = re.split(r"[,/|]", value)
    out = []
    for item in raw:
        name = item.strip()
        if not name:
            continue
        canonical = name[:1].upper() + name[1:].lower() if name.lower() != "cyber" else "Cyber"
        if canonical in PERILS:
            out.append(canonical)
        else:
            warnings.append(f"unknown peril '{name}' dropped")
    return out or ["Windstorm"]


def parse_contract(text: str) -> tuple[dict, list]:
    fields = parse_fields(text)
    warnings = []

    def get(key, default=None):
        if key not in fields:
            if default is None:
                warnings.append(f"missing field '{key}'")
            return default
        return fields[key]

    cid = get("contract_id", "UNKNOWN")
    name = get("contract_name", cid)
    counterparty = get("counterparty", "Unknown Counterparty")

    rating = get("credit_rating", "Unrated")
    if rating not in RATINGS:
        warnings.append(f"unknown rating '{rating}', treated as Unrated")
        rating = "Unrated"

    direction = (get("direction", "Outward") or "Outward").strip().capitalize()
    if direction not in DIRECTIONS:
        warnings.append(f"unknown direction '{direction}', treated as Outward")
        direction = "Outward"
    # Lean's codec uses the lowercase token; the slip uses the market spelling.
    direction = direction.lower()

    currency = (get("currency", "EUR") or "EUR").strip().upper()
    if currency not in CURRENCIES:
        warnings.append(f"unknown currency '{currency}', treated as EUR")
        currency = "EUR"

    perils = _perils(fields.get("perils", fields.get("peril", "Windstorm")), warnings)

    def int_field(*keys, default=0):
        """First key present wins; aliases do not warn when the canonical one is set."""
        for key in keys:
            raw = fields.get(key)
            if raw is None:
                continue
            try:
                return _num(raw)
            except ValueError:
                warnings.append(f"non-numeric '{key}' = '{raw}', defaulted to {default}")
                return default
        warnings.append(f"missing numeric field '{keys[0]}', defaulted to {default}")
        return default

    priority = int_field("inuring_priority", 0)
    raw_type = (get("contract_type", "XoL") or "XoL").strip()
    ctype = TYPE_ALIASES.get(_norm_key(raw_type), None)
    if ctype is None:
        warnings.append(f"unknown contract type '{raw_type}', treated as XoL")
        ctype = "xol"

    if ctype == "xol":
        kind = {
            "type": "xol",
            "attachment": int_field("attachment"),
            "occLimit": int_field("occurrence_limit", "occ_limit"),
            "aggLimit": int_field("aggregate_limit", "agg_limit"),
            "reinstRateBps": int_field("reinstatement_rate_bps", "reinst_rate_bps"),
            "basePremium": int_field("base_premium"),
        }
    elif ctype == "quotaShare":
        kind = {
            "type": "quotaShare",
            "shareBps": int_field("share_bps"),
            "eventCap": int_field("event_cap"),
            "commissionBps": int_field("commission_bps"),
        }
    elif ctype == "surplusShare":
        kind = {
            "type": "surplusShare",
            "retentionLine": int_field("retention_line"),
            "numLines": int_field("num_lines"),
            "eventCap": int_field("event_cap"),
        }
    else:
        kind = {
            "type": "aggregateStopLoss",
            "aggAttachment": int_field("agg_attachment", "attachment"),
            "aggLimit": int_field("agg_limit", "aggregate_limit"),
        }

    contract = {
        "id": cid,
        "name": name,
        "counterparty": counterparty,
        "rating": rating,
        "direction": direction,
        "currency": currency,
        "perils": perils,
        "inuringPriority": priority,
        "kind": kind,
    }
    return contract, warnings


def parse_slip_bytes(data: bytes, filename: str = "") -> dict:
    text = extract_text(data, filename)
    contract, warnings = parse_contract(text)
    return {"extractedText": text, "contract": contract, "parseWarnings": warnings}


def parse_slip_file(path: str) -> dict:
    p = Path(path)
    return parse_slip_bytes(p.read_bytes(), p.name)


if __name__ == "__main__":
    import json
    import sys

    for arg in sys.argv[1:]:
        result = parse_slip_file(arg)
        print(f"=== {arg} ===")
        print(json.dumps(result["contract"], indent=2))
        if result["parseWarnings"]:
            print("warnings:", result["parseWarnings"])
