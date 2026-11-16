#!/usr/bin/env python3
"""Universal facultative intake: PDF, ACORD XML/JSON, or a broker email.

The parser is deterministic and offline. Every number it produces is then
re-verified by the compiled Lean binary, so a mis-parse is caught by the
gatekeeper rather than paid.

An optional LLM pass exists (`OPENAI_API_KEY`) purely as a second opinion on
extraction. It never computes a payable: if it is unavailable, slow, or wrong,
the deterministic parser's output is what gets audited.
"""

from __future__ import annotations

import base64
import json
import os
import re
import urllib.request

import acord_adapter
import slip_parser

MAX_INTAKE_BYTES = 2_000_000


# ---------------------------------------------------------------------------
# Clause scanner
# ---------------------------------------------------------------------------

UNMODELED_CLAUSES = [
    ("punitive damages", r"punitive\s+damages?"),
    ("exemplary damages", r"exemplary\s+damages?"),
    ("declaratory judgment", r"declaratory\s+judg"),
    ("DJ expense", r"\bDJ\s+expense"),
    ("hammer clause", r"hammer\s+clause"),
    ("consent to settle", r"consent\s+to\s+settle"),
    ("sunset clause", r"sunset\s+clause"),
    ("batch clause", r"batch\s+clause"),
    ("pollution exclusion", r"pollution\s+exclusion"),
    ("PFAS", r"\bPFAS\b"),
    ("nuclear", r"\bnuclear\b"),
    ("subrogation", r"subrogation"),
]


def scan_casualty_clauses(text: str) -> list:
    found = []
    for label, pattern in UNMODELED_CLAUSES:
        if re.search(pattern, text, re.IGNORECASE):
            found.append(
                f"Clause '{label}' detected in the source text but is NOT modeled in the "
                f"Lean facultative certificate - review manually!"
            )
    return found


# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------

def parse_money(token: str) -> int:
    cleaned = token.strip().replace("$", "").replace(",", "").replace(" ", "")
    multiplier = 1
    if cleaned and cleaned[-1] in "kK":
        multiplier, cleaned = 1_000, cleaned[:-1]
    elif cleaned and cleaned[-1] in "mM":
        multiplier, cleaned = 1_000_000, cleaned[:-1]
    if "." in cleaned:
        return int(round(float(cleaned) * multiplier))
    return int(cleaned) * multiplier


def parse_pct(token: str) -> int:
    return int(round(float(token.strip().replace("%", "")) * 100))


LINE_PATTERNS = [
    (r"auto\s*liability|\bAL\b", "AutoLiability"),
    (r"general\s*liability|\bGL\b", "GeneralLiability"),
    (r"workers?\s*comp|\bWCA?\b", "WorkersComp"),
    (r"directors?\s*(?:&|and|/)\s*officers|\bD&O\b|\bDO\b", "DirectorsOfficers"),
]

ALAE_PATTERNS = [
    (r"pro[\s-]*rata\s*(?:in\s*)?addition", "proRataInAddition"),
    (r"(?:included|inside|within)\s*(?:the\s*)?(?:limits|limit)", "includedInLimit"),
    (r"indemnity\s*only|excluding\s*alae|alae\s*excluded", "excluded"),
]


LINE_NAMES = {"AutoLiability", "GeneralLiability", "WorkersComp", "DirectorsOfficers"}
ALAE_NAMES = {"proRataInAddition", "includedInLimit", "excluded"}


def line_from_text(value: str) -> str:
    token = value.strip()
    if token in LINE_NAMES:
        return token
    return _first(LINE_PATTERNS, token, "GeneralLiability")


def alae_from_text(value: str) -> str:
    token = value.strip()
    if token in ALAE_NAMES:
        return token
    return _first(ALAE_PATTERNS, token, "proRataInAddition")


def _first(patterns, text, default):
    for pattern, value in patterns:
        if re.search(pattern, text, re.IGNORECASE):
            return value
    return default


# ---------------------------------------------------------------------------
# Free-form / label parser
# ---------------------------------------------------------------------------

LABEL_MAP = {
    "cash_call_id": ("claim", "claimId"),
    "claim_id": ("claim", "claimId"),
    "certificate_id": ("cert", "certId"),
    "cert_id": ("cert", "certId"),
    "insured": ("cert", "insuredName"),
    "insured_name": ("cert", "insuredName"),
    "cedent": ("cert", "cedentName"),
    "cedent_name": ("cert", "cedentName"),
    "line": ("cert", "line"),
    "attachment_usd": ("cert", "attachmentUsd"),
    "attachment": ("cert", "attachmentUsd"),
    "occurrence_limit_usd": ("cert", "occLimitUsd"),
    "occurrence_limit": ("cert", "occLimitUsd"),
    "signed_share_bps": ("cert", "signedShareBps"),
    "signed_share_pct": ("cert", "signedSharePct"),
    "alae_clause": ("cert", "alaeClause"),
    "gross_premium_usd": ("cert", "grossPremiumUsd"),
    "gross_premium": ("cert", "grossPremiumUsd"),
    "brokerage_bps": ("cert", "brokerageBps"),
    "brokerage_pct": ("cert", "brokeragePct"),
    "paid_premium_to_date_usd": ("cert", "paidPremiumToDateUsd"),
    "insured_group": ("cert", "insuredGroup"),
    "paid_indemnity": ("claim", "paidIndemnityUsd"),
    "paid_indemnity_usd": ("claim", "paidIndemnityUsd"),
    "paid_alae": ("claim", "paidAlaeUsd"),
    "paid_alae_usd": ("claim", "paidAlaeUsd"),
    "oslr_indemnity": ("claim", "oslrIndemnityUsd"),
    "oslr_indemnity_usd": ("claim", "oslrIndemnityUsd"),
    "case_reserve_indemnity": ("claim", "oslrIndemnityUsd"),
    "case_reserve_indemnity_usd": ("claim", "oslrIndemnityUsd"),
    "oslr_alae": ("claim", "oslrAlaeUsd"),
    "oslr_alae_usd": ("claim", "oslrAlaeUsd"),
    "case_reserve_alae": ("claim", "oslrAlaeUsd"),
    "case_reserve_alae_usd": ("claim", "oslrAlaeUsd"),
    "prior_paid": ("claim", "priorPaidUsd"),
    "prior_paid_usd": ("claim", "priorPaidUsd"),
    "prior_oslr_booked_usd": ("claim", "priorOslrBookedUsd"),
    "cedent_billed_now": ("claim", "cedentBilledNowUsd"),
    "cedent_billed_now_usd": ("claim", "cedentBilledNowUsd"),
    "apply_premium_offset": ("claim", "applyPremiumOffset"),
    "clash_event_tag": ("claim", "clashEventTag"),
}

NUMERIC_LABELS = {
    "attachmentUsd", "occLimitUsd", "signedShareBps", "signedSharePct",
    "grossPremiumUsd", "brokerageBps", "brokeragePct", "paidPremiumToDateUsd",
    "paidIndemnityUsd", "paidAlaeUsd", "oslrIndemnityUsd", "oslrAlaeUsd",
    "priorPaidUsd", "priorOslrBookedUsd", "cedentBilledNowUsd",
}


def blank_cert() -> dict:
    return {
        "certId": "INTAKE-UNKNOWN", "insuredName": "", "cedentName": "",
        "line": "GeneralLiability", "attachmentUsd": 0, "occLimitUsd": 0,
        "signedShareBps": 10000, "alaeClause": "proRataInAddition",
        "grossPremiumUsd": 0, "brokerageBps": 0, "paidPremiumToDateUsd": 0,
        "insuredGroup": "",
    }


def blank_claim() -> dict:
    return {
        "claimId": "INTAKE-CLAIM", "certId": "INTAKE-UNKNOWN",
        "lossDesc": "Free-form broker cash call",
        "paidIndemnityUsd": 0, "paidAlaeUsd": 0, "oslrIndemnityUsd": 0,
        "oslrAlaeUsd": 0, "priorPaidUsd": 0, "priorOslrBookedUsd": 0,
        "cedentBilledNowUsd": 0, "applyPremiumOffset": False, "clashEventTag": "",
    }


def _apply_label(cert: dict, claim: dict, key: str, raw: str, warnings: list) -> None:
    target, field = LABEL_MAP[key]
    dest = cert if target == "cert" else claim
    if field in NUMERIC_LABELS:
        try:
            value = parse_pct(raw) if field.endswith("Pct") else parse_money(raw)
        except ValueError:
            warnings.append(f"could not read number for {key}: {raw!r}")
            return
        if field == "signedSharePct":
            cert["signedShareBps"] = value
        elif field == "brokeragePct":
            cert["brokerageBps"] = value
        else:
            dest[field] = value
    elif field == "applyPremiumOffset":
        claim["applyPremiumOffset"] = raw.strip().lower() in {"true", "1", "yes", "y"}
    elif field == "line":
        dest[field] = line_from_text(raw)
    elif field == "alaeClause":
        dest[field] = alae_from_text(raw)
    else:
        dest[field] = raw.strip()


def parse_freeform(text: str) -> tuple[dict, dict, list]:
    """Parse labelled slips and messy broker emails."""
    cert, claim, warnings = blank_cert(), blank_claim(), []

    for line in text.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        norm = re.sub(r"[\s\-]+", "_", key.strip().lower())
        if norm in LABEL_MAP:
            _apply_label(cert, claim, norm, value, warnings)

    # Inline email form: "Insured: X | Cedant: Y | Layer: 50% part of $500k xs $500k Auto Liability"
    for chunk in re.split(r"[|\n]", text):
        if ":" not in chunk:
            continue
        key, _, value = chunk.partition(":")
        norm = re.sub(r"[\s\-]+", "_", key.strip().lower())
        if norm in LABEL_MAP and norm not in {"certificate_id", "cash_call_id"}:
            # Only fill if the labelled pass did not already set it.
            target, field = LABEL_MAP[norm]
            dest = cert if target == "cert" else claim
            if dest.get(field) in (None, "", 0) and not (
                field in NUMERIC_LABELS and dest.get(field) not in (0, None)
            ):
                _apply_label(cert, claim, norm, value, warnings)

    # "50% part of $500k xs $500k" / "20% of $10m xs $10m"
    layer = re.search(
        r"(\d+(?:\.\d+)?)\s*%\s*(?:(?:part\s*)?of\s*)?\$?\s*([\d.,]+\s*[kKmM]?)\s*xs\s*\$?\s*([\d.,]+\s*[kKmM]?)",
        text,
        re.IGNORECASE,
    )
    if layer:
        cert["signedShareBps"] = parse_pct(layer.group(1))
        cert["occLimitUsd"] = parse_money(layer.group(2))
        cert["attachmentUsd"] = parse_money(layer.group(3))

    if cert["occLimitUsd"] == 0:
        m = re.search(r"\$?\s*([\d.,]+\s*[kKmM]?)\s*xs\s*\$?\s*([\d.,]+\s*[kKmM]?)", text, re.IGNORECASE)
        if m:
            cert["occLimitUsd"] = parse_money(m.group(1))
            cert["attachmentUsd"] = parse_money(m.group(2))

    cert["line"] = line_from_text(cert["line"]) if cert["line"] != "GeneralLiability" else _first(LINE_PATTERNS, text, cert["line"])
    cert["alaeClause"] = alae_from_text(cert["alaeClause"]) if cert["alaeClause"] != "proRataInAddition" else _first(ALAE_PATTERNS, text, cert["alaeClause"])

    prem = re.search(r"gross\s*prem(?:ium)?\s*:\s*\$?\s*([\d.,]+\s*[kKmM]?)", text, re.IGNORECASE)
    if prem:
        cert["grossPremiumUsd"] = parse_money(prem.group(1))
    broker = re.search(r"(\d+(?:\.\d+)?)\s*%\s*brokerage", text, re.IGNORECASE)
    if broker:
        cert["brokerageBps"] = parse_pct(broker.group(1))
    paid_prem = re.search(r"\$\s*([\d.,]+\s*[kKmM]?)\s*paid", text, re.IGNORECASE)
    if paid_prem:
        cert["paidPremiumToDateUsd"] = parse_money(paid_prem.group(1))

    wire = re.search(r"(?:please\s+wire|billed|billing|cash\s*call(?:\s*of)?)\s*:?\s*\$?\s*([\d.,]+\s*[kKmM]?)", text, re.IGNORECASE)
    if wire:
        claim["cedentBilledNowUsd"] = parse_money(wire.group(1))

    if not cert["insuredGroup"]:
        cert["insuredGroup"] = cert["insuredName"] or "Unknown Group"
    claim["certId"] = cert["certId"]
    if claim["claimId"] in ("", "INTAKE-CLAIM"):
        claim["claimId"] = f"CC-{cert['certId']}"
    if not claim["lossDesc"]:
        claim["lossDesc"] = "Free-form broker cash call"

    if cert["occLimitUsd"] == 0:
        warnings.append("no layer limit found in the text")
    if cert["attachmentUsd"] == 0 and cert["occLimitUsd"] > 0:
        warnings.append("no attachment found; treated as ground-up")
    return cert, claim, warnings


# ---------------------------------------------------------------------------
# Optional LLM second opinion
# ---------------------------------------------------------------------------

def maybe_llm_extract(text: str) -> dict | None:
    """Optional extraction pass. Never authoritative, never required."""
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        return None
    payload = {
        "model": os.environ.get("OPENAI_MODEL", "gpt-4o-mini"),
        "messages": [
            {"role": "system", "content": "Extract facultative certificate and claim fields as JSON. Numbers in USD, shares in basis points."},
            {"role": "user", "content": text[:6000]},
        ],
        "temperature": 0,
    }
    try:
        req = urllib.request.Request(
            "https://api.openai.com/v1/chat/completions",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=8) as res:
            body = json.loads(res.read())
        content = body["choices"][0]["message"]["content"]
        return json.loads(content[content.find("{"): content.rfind("}") + 1])
    except Exception:  # noqa: BLE001 - fall back silently to the deterministic parse
        return None


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def detect_format(data: bytes, filename: str) -> str:
    if data.startswith(b"%PDF"):
        return "pdf"
    stripped = data.lstrip()
    if stripped.startswith(b"<"):
        return "acord_xml"
    if stripped.startswith(b"{"):
        return "acord_json"
    return "text"


def intake_bytes(data: bytes, filename: str = "") -> dict:
    if len(data) > MAX_INTAKE_BYTES:
        raise ValueError("intake payload too large")
    fmt = detect_format(data, filename)

    if fmt in ("acord_xml", "acord_json"):
        cert, claim = acord_adapter.parse_acord(data.decode("utf-8", errors="replace"))
        warnings = []
        text = data.decode("utf-8", errors="replace")
    elif fmt == "pdf":
        text = slip_parser.extract_text(data, filename)
        cert, claim, warnings = parse_freeform(text)
    else:
        text = data.decode("utf-8", errors="replace")
        cert, claim, warnings = parse_freeform(text)

    llm = maybe_llm_extract(text)
    return {
        "sourceFormat": fmt,
        "certificate": cert,
        "claim": claim,
        "parseWarnings": warnings,
        "translationWarnings": scan_casualty_clauses(text),
        "extractedText": text,
        "llmUsed": llm is not None,
    }


def intake_base64(content_b64: str, filename: str = "") -> dict:
    return intake_bytes(base64.b64decode(content_b64), filename)


def bundle_for(cert: dict, claim: dict, desk: str = "Universal intake") -> dict:
    return {"deskName": desk, "certificates": [cert], "claims": [claim]}


if __name__ == "__main__":
    import sys

    for path in sys.argv[1:]:
        result = intake_bytes(open(path, "rb").read(), path)
        print(json.dumps({k: v for k, v in result.items() if k != "extractedText"}, indent=2))
