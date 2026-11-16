#!/usr/bin/env python3
"""Quarterly loss bordereau batch engine.

Parses a carrier loss bordereau CSV, audits the whole book in one Lean call,
evaluates the four-eyes settlement gate per claim (with any active sign-offs),
and emits a balanced SAP FS-RI / IFRS 17 posting batch.

Standard library only. Every amount comes from the compiled Lean binary.
"""

from __future__ import annotations

import csv
import io
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".lake" / "build" / "bin" / "cockpit"
PRESET = ROOT / "examples" / "bordereaux" / "Q3_2026_US_Fac_Bordereau_24_Claims.csv"

GL = {
    "paid_claims": ("510100", "Paid claims expense"),
    "premium_receivable": ("110300", "Premium receivable"),
    "cedent_payable": ("210200", "Cedent payable"),
    "oslr_expense": ("520100", "OSLR / LIC expense"),
    "oslr_liability": ("220200", "OSLR / LIC liability"),
}


def preset_path() -> Path:
    return PRESET


def preset_csv() -> str:
    return preset_path().read_text(encoding="utf-8")


def _num(value: str, default: int = 0) -> int:
    text = (value or "").strip().replace(",", "").replace("$", "")
    if not text:
        return default
    return int(float(text))


def parse_csv(text: str) -> tuple[list[dict], dict]:
    reader = csv.DictReader(io.StringIO(text))
    rows = []
    certs, claims = [], []
    for raw in reader:
        row = {
            "claimId": raw["claim_id"].strip(),
            "certId": raw["cert_id"].strip(),
            "cedent": raw["cedent"].strip(),
            "insured": raw["insured"].strip(),
            "line": raw["line"].strip(),
            "attachmentUsd": _num(raw["attachment"]),
            "occLimitUsd": _num(raw["limit"]),
            "signedShareBps": _num(raw["share_bps"]),
            "alaeClause": raw["alae_clause"].strip(),
            "grossPremiumUsd": _num(raw.get("gross_premium")),
            "brokerageBps": _num(raw.get("brokerage_bps")),
            "paidPremiumToDateUsd": _num(raw.get("paid_premium")),
            "paidIndemnityUsd": _num(raw.get("paid_ind")),
            "paidAlaeUsd": _num(raw.get("paid_alae")),
            "oslrIndemnityUsd": _num(raw.get("oslr_ind")),
            "oslrAlaeUsd": _num(raw.get("oslr_alae")),
            "priorPaidUsd": _num(raw.get("prior_paid")),
            "priorOslrBookedUsd": _num(raw.get("prior_oslr")),
            "cedentBilledNowUsd": _num(raw.get("billed")),
            "applyPremiumOffset": (raw.get("apply_offset", "").strip().lower() == "true"),
            "subjectivity": [s.strip() for s in (raw.get("subjectivity") or "").split(";") if s.strip()],
        }
        rows.append(row)
        certs.append({
            "certId": row["certId"], "insuredName": row["insured"], "cedentName": row["cedent"],
            "line": row["line"], "attachmentUsd": row["attachmentUsd"],
            "occLimitUsd": row["occLimitUsd"], "signedShareBps": row["signedShareBps"],
            "alaeClause": row["alaeClause"], "grossPremiumUsd": row["grossPremiumUsd"],
            "brokerageBps": row["brokerageBps"],
            "paidPremiumToDateUsd": row["paidPremiumToDateUsd"],
            "insuredGroup": row["cedent"],
        })
        claims.append({
            "claimId": row["claimId"], "certId": row["certId"], "lossDesc": "Q3 bordereau",
            "paidIndemnityUsd": row["paidIndemnityUsd"], "paidAlaeUsd": row["paidAlaeUsd"],
            "oslrIndemnityUsd": row["oslrIndemnityUsd"], "oslrAlaeUsd": row["oslrAlaeUsd"],
            "priorPaidUsd": row["priorPaidUsd"], "priorOslrBookedUsd": row["priorOslrBookedUsd"],
            "cedentBilledNowUsd": row["cedentBilledNowUsd"],
            "applyPremiumOffset": row["applyPremiumOffset"], "clashEventTag": "",
        })
    return rows, {"deskName": "Quarterly bordereau", "certificates": certs, "claims": claims}


def _run_lean(args: list, timeout: int = 30):
    proc = subprocess.run([str(BINARY), *args], capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or "cockpit failed")[:400])
    return proc.stdout


def audit_bundle(bundle: dict) -> tuple[dict, float]:
    import time
    path = None
    started = time.perf_counter()
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(bundle, fh)
            path = fh.name
        report = json.loads(_run_lean(["fac-audit", path, "--json"]))
        return report, round((time.perf_counter() - started) * 1000, 2)
    finally:
        if path:
            Path(path).unlink(missing_ok=True)


def evaluate_gate(code: str, kinds: list, attestation: dict | None) -> str:
    args = ["gate", code, *kinds, "--json"]
    if attestation:
        args.append(f"--attest={attestation['claimsExaminer']}|{attestation['technicalAccountant']}")
    return json.loads(_run_lean(args))["gate"]


def build_sap_csv(rows: list) -> tuple[str, int, int]:
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(["document", "claim_id", "gl_account", "account_name",
                     "debit_usd", "credit_usd", "text"])
    total_debit = total_credit = 0
    for row in rows:
        if row["gate"] != "RELEASE_WIRE_AUTHORIZED":
            continue
        doc = f"BORD-{row['claimId']}"
        cash = row["grossCashPayableUsd"]
        offset = row["premiumOffsetUsd"]
        wire = row["netCashWireUsd"]
        lines = [
            (GL["paid_claims"], cash, 0, "paid claims expense"),
            (GL["premium_receivable"], 0, offset, "premium offset"),
            (GL["cedent_payable"], 0, wire, "wire payable"),
        ]
        oslr = row["endingOslrUsd"]
        prior = row["priorOslrBookedUsd"]
        if oslr >= prior and oslr > 0:
            lines.append((GL["oslr_expense"], oslr - prior, 0, "OSLR increase"))
            lines.append((GL["oslr_liability"], 0, oslr - prior, "OSLR liability"))
        elif prior > oslr:
            lines.append((GL["oslr_liability"], prior - oslr, 0, "OSLR release"))
            lines.append((GL["oslr_expense"], 0, prior - oslr, "OSLR expense release"))
        for (account, name), debit, credit, text in lines:
            if debit == 0 and credit == 0:
                continue
            writer.writerow([doc, row["claimId"], account, name, debit, credit, text])
            total_debit += debit
            total_credit += credit
    if total_debit != total_credit:
        raise RuntimeError(f"SAP batch does not balance: {total_debit} != {total_credit}")
    return out.getvalue(), total_debit, total_credit


def run(csv_text: str, attestations: dict | None = None) -> dict:
    attestations = attestations or {}
    rows, bundle = parse_csv(csv_text)
    report, audit_ms = audit_bundle(bundle)
    results = {r["certId"]: r for r in report["results"]}

    out_rows = []
    gate_cache = {}
    for row in rows:
        res = results[row["certId"]]
        code = res["acordResponseCode"]
        kinds = row["subjectivity"]
        att = None
        if kinds:
            for candidate in attestations.get(row["claimId"], []):
                att = candidate
                break
        key = (code, tuple(kinds), att["claimsExaminer"] if att else None,
               att["technicalAccountant"] if att else None)
        if key not in gate_cache:
            gate_cache[key] = evaluate_gate(code, kinds, att)
        gate = gate_cache[key]
        out_rows.append({
            "claimId": row["claimId"],
            "certId": row["certId"],
            "cedent": row["cedent"],
            "insured": row["insured"],
            "line": row["line"],
            "billedUsd": res["cedentBilledNowUsd"],
            "grossCashPayableUsd": res["grossCashPayableNowUsd"],
            "premiumOffsetUsd": res["premiumOffsetUsd"],
            "netCashWireUsd": res["netCashWireDueUsd"],
            "overbilledUsd": res["overbilledUsd"],
            "endingOslrUsd": res["verifiedEndingOslrUsd"],
            "priorOslrBookedUsd": res["priorOslrBookedUsd"],
            "acordResponseCode": code,
            "verdict": res["verdict"],
            "subjectivity": kinds,
            "gate": gate,
        })

    sap_csv, debit_total, credit_total = build_sap_csv(out_rows)
    kpis = {
        "totalRows": len(out_rows),
        "stpAgreedCount": sum(1 for r in out_rows if r["gate"] == "RELEASE_WIRE_AUTHORIZED"),
        "offsetCount": sum(1 for r in out_rows if r["acordResponseCode"] == "AGD_OFFSET"),
        "queriedDisputeCount": sum(1 for r in out_rows if r["acordResponseCode"] == "QRY"),
        "fourEyesHoldCount": sum(1 for r in out_rows if r["gate"] == "HOLD_FOUR_EYES_REQUIRED"),
        "blockedCount": sum(1 for r in out_rows if r["gate"] == "BLOCKED_BY_DISPUTE_OR_INVALID"),
        "totalBilledUsd": sum(r["billedUsd"] for r in out_rows),
        "totalAuthorizedWireUsd": sum(r["netCashWireUsd"] for r in out_rows
                                       if r["gate"] == "RELEASE_WIRE_AUTHORIZED"),
        "totalLeakageSavedUsd": sum(r["overbilledUsd"] for r in out_rows),
        "totalOslrBookedUsd": sum(r["endingOslrUsd"] for r in out_rows
                                  if r["gate"] == "RELEASE_WIRE_AUTHORIZED"),
        "sapDebitTotalUsd": debit_total,
        "sapCreditTotalUsd": credit_total,
        "leanExecMs": audit_ms,
    }
    return {"kpis": kpis, "rows": out_rows, "sapCsv": sap_csv}


if __name__ == "__main__":
    import sys

    text = Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else preset_csv()
    result = run(text)
    print(json.dumps(result["kpis"], indent=2))
