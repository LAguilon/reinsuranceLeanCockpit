#!/usr/bin/env python3
"""Generate the Q3 2026 US facultative loss bordereau (24 claims).

Deterministic: the CSV is a fixture, but the billed amounts are *derived* from
the compiled Lean audit so the status distribution is exact rather than
hand-arithmetic that drifts. Run:

    python3 scripts/generate_bordereau.py
"""

import csv
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".lake" / "build" / "bin" / "cockpit"
OUT = ROOT / "examples" / "bordereaux" / "Q3_2026_US_Fac_Bordereau_24_Claims.csv"

CEDENTS = ["Liberty Commercial", "Hartford National", "Chubb Specialty",
           "Travelers Excess", "CNA Global"]

# (line, attachment, limit, share_bps, alae, paid_ind, paid_alae, oslr_ind,
#  oslr_alae, prior, prior_oslr, gross_prem, brokerage, paid_prem, offset, subjectivity)
AGD_ROWS = [
    ("AutoLiability", 500_000, 500_000, 10_000, "proRataInAddition", 720_000, 0, 0, 0, 0, 0, 60_000, 1500, 60_000, False, ""),
    ("GeneralLiability", 500_000, 1_000_000, 5_000, "proRataInAddition", 1_400_000, 120_000, 0, 0, 0, 0, 90_000, 1500, 90_000, False, ""),
    ("WorkersComp", 250_000, 500_000, 10_000, "excluded", 610_000, 0, 0, 0, 100_000, 0, 45_000, 1000, 45_000, False, ""),
    ("DirectorsOfficers", 10_000_000, 10_000_000, 1_500, "includedInLimit", 18_000_000, 4_000_000, 500_000, 100_000, 0, 0, 120_000, 2000, 120_000, False, ""),
    ("AutoLiability", 1_000_000, 1_000_000, 2_500, "proRataInAddition", 1_600_000, 80_000, 0, 0, 0, 0, 55_000, 1500, 55_000, False, ""),
    ("GeneralLiability", 750_000, 750_000, 10_000, "includedInLimit", 1_100_000, 150_000, 0, 0, 0, 0, 70_000, 1250, 70_000, False, ""),
    ("WorkersComp", 500_000, 500_000, 7_500, "excluded", 900_000, 0, 0, 0, 0, 0, 40_000, 1000, 40_000, False, ""),
    ("AutoLiability", 250_000, 750_000, 10_000, "proRataInAddition", 800_000, 40_000, 0, 0, 50_000, 0, 35_000, 1500, 35_000, False, ""),
    ("DirectorsOfficers", 5_000_000, 5_000_000, 3_000, "includedInLimit", 7_000_000, 1_000_000, 0, 0, 0, 0, 80_000, 2000, 80_000, False, ""),
    ("GeneralLiability", 1_000_000, 2_000_000, 4_000, "proRataInAddition", 2_600_000, 200_000, 300_000, 50_000, 0, 0, 110_000, 1500, 110_000, False, ""),
    ("WorkersComp", 750_000, 750_000, 10_000, "excluded", 1_400_000, 0, 0, 0, 200_000, 0, 65_000, 1000, 65_000, False, ""),
    ("AutoLiability", 500_000, 250_000, 10_000, "proRataInAddition", 700_000, 30_000, 0, 0, 0, 0, 25_000, 1500, 25_000, False, ""),
    ("GeneralLiability", 2_000_000, 2_000_000, 2_000, "includedInLimit", 3_000_000, 400_000, 0, 0, 0, 0, 95_000, 1500, 95_000, False, ""),
]

OFFSET_ROWS = [
    ("AutoLiability", 500_000, 500_000, 10_000, "proRataInAddition", 680_000, 0, 0, 0, 0, 0, 48_000, 1500, 0, True, ""),
    ("GeneralLiability", 500_000, 500_000, 10_000, "proRataInAddition", 760_000, 60_000, 0, 0, 0, 0, 60_000, 1500, 20_000, True, ""),
    ("WorkersComp", 500_000, 500_000, 10_000, "excluded", 950_000, 0, 0, 0, 0, 0, 52_000, 1000, 0, True, ""),
]

# (params, overbill, label) — the six disputed rows
QRY_ROWS = [
    (("AutoLiability", 500_000, 500_000, 10_000, "proRataInAddition", 450_000, 180_000, 0, 0, 0, 0, 0, 0, 0, False, ""),
     350_000, "ALAE pro-rata billed although indemnity is below the attachment"),
    (("AutoLiability", 500_000, 500_000, 10_000, "proRataInAddition", 400_000, 40_000, 350_000, 50_000, 0, 0, 0, 0, 0, False, ""),
     300_000, "Premature OSLR cash call while paid indemnity is below attachment"),
    (("WorkersComp", 500_000, 500_000, 10_000, "excluded", 850_000, 0, 0, 0, 200_000, 0, 0, 0, 0, False, ""),
     260_000, "Prior paid not deducted from the cumulative layer position"),
    (("DirectorsOfficers", 10_000_000, 10_000_000, 2_000, "includedInLimit", 16_000_000, 6_000_000, 0, 0, 0, 0, 0, 0, 0, False, ""),
     230_000, "D&O inside-limits cap applied after the signed share"),
    (("GeneralLiability", 1_000_000, 1_000_000, 10_000, "includedInLimit", 1_800_000, 500_000, 0, 0, 0, 0, 0, 0, 0, False, ""),
     200_000, "Defence inside limits billed as if it were in addition"),
    (("WorkersComp", 750_000, 750_000, 10_000, "excluded", 1_200_000, 0, 0, 0, 150_000, 0, 0, 0, 0, False, ""),
     180_000, "Cumulative indemnity billed twice"),
]

HOLD_ROWS = [
    ("DirectorsOfficers", 5_000_000, 5_000_000, 2_500, "includedInLimit", 7_500_000, 1_500_000, 0, 0, 0, 0, 0, 0, 0, False,
     "declaratoryJudgmentFee"),
    ("GeneralLiability", 1_000_000, 1_000_000, 10_000, "proRataInAddition", 1_500_000, 100_000, 0, 0, 0, 0, 0, 0, 0, False,
     "hammerConsentToSettle"),
]


def make_row(idx, params, cedent, billed, subjectivity=""):
    (line, att, lim, share, alae, pi, pa, oi, oa, prior, prior_oslr,
     gross, brokerage, paid_prem, offset, _ignored) = params
    claim_id = f"BQ-2026-{idx:03d}"
    cert_id = f"FAC-BQ-{idx:03d}"
    return {
        "claim_id": claim_id,
        "cert_id": cert_id,
        "cedent": cedent,
        "insured": f"{cedent.split()[0]} Insured {idx:02d}",
        "line": line,
        "attachment": att,
        "limit": lim,
        "share_bps": share,
        "alae_clause": alae,
        "gross_premium": gross,
        "brokerage_bps": brokerage,
        "paid_premium": paid_prem,
        "paid_ind": pi,
        "paid_alae": pa,
        "oslr_ind": oi,
        "oslr_alae": oa,
        "prior_paid": prior,
        "prior_oslr": prior_oslr,
        "billed": billed,
        "apply_offset": "true" if offset else "false",
        "subjectivity": subjectivity,
    }


def to_bundle(rows):
    certs, claims = [], []
    for r in rows:
        certs.append({
            "certId": r["cert_id"], "insuredName": r["insured"], "cedentName": r["cedent"],
            "line": r["line"], "attachmentUsd": r["attachment"], "occLimitUsd": r["limit"],
            "signedShareBps": r["share_bps"], "alaeClause": r["alae_clause"],
            "grossPremiumUsd": r["gross_premium"], "brokerageBps": r["brokerage_bps"],
            "paidPremiumToDateUsd": r["paid_premium"], "insuredGroup": r["cedent"],
        })
        claims.append({
            "claimId": r["claim_id"], "certId": r["cert_id"], "lossDesc": "Q3 bordereau",
            "paidIndemnityUsd": r["paid_ind"], "paidAlaeUsd": r["paid_alae"],
            "oslrIndemnityUsd": r["oslr_ind"], "oslrAlaeUsd": r["oslr_alae"],
            "priorPaidUsd": r["prior_paid"], "priorOslrBookedUsd": r["prior_oslr"],
            "cedentBilledNowUsd": r["billed"],
            "applyPremiumOffset": r["apply_offset"] == "true", "clashEventTag": "",
        })
    return {"deskName": "Q3 2026 US Facultative Bordereau", "certificates": certs, "claims": claims}


def audit(bundle):
    path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(bundle, fh)
            path = fh.name
        proc = subprocess.run([str(BINARY), "fac-audit", path, "--json"],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr[:400])
        return json.loads(proc.stdout)
    finally:
        if path:
            Path(path).unlink(missing_ok=True)


def main() -> None:
    rows = []
    idx = 1
    for i, params in enumerate(AGD_ROWS):
        rows.append(make_row(idx, params, CEDENTS[i % len(CEDENTS)], 0))
        idx += 1
    for i, params in enumerate(OFFSET_ROWS):
        rows.append(make_row(idx, params, CEDENTS[(i + 2) % len(CEDENTS)], 0))
        idx += 1
    qry_start = idx
    for params, over, _label in QRY_ROWS:
        rows.append(make_row(idx, params, CEDENTS[(idx + 1) % len(CEDENTS)], 0))
        idx += 1
    hold_start = idx
    for params in HOLD_ROWS:
        subj = params[-1]
        rows.append(make_row(idx, params, CEDENTS[(idx + 3) % len(CEDENTS)], 0, subj))
        idx += 1

    # First pass: learn the verified cash for every row.
    first = audit(to_bundle(rows))
    cash = {r["certId"]: r["grossCashPayableNowUsd"] for r in first["results"]}

    # Set bills: exact for AGD/OFFSET/HOLD, cash + planned overbill for QRY.
    for i, row in enumerate(rows):
        row["billed"] = cash[row["cert_id"]]
    qry_start_index = len(AGD_ROWS) + len(OFFSET_ROWS)
    for j, (params, over, _label) in enumerate(QRY_ROWS):
        rows[qry_start_index + j]["billed"] += over

    second = audit(to_bundle(rows))
    codes = [r["acordResponseCode"] for r in second["results"]]
    leakage = sum(r["overbilledUsd"] for r in second["results"])

    hold_count = sum(1 for r in rows if r["subjectivity"])
    expected = {"AGD": 13, "AGD_OFFSET": 3, "QRY": 6, "REJ": 0, "HOLD": 2}
    actual = {
        "AGD": codes.count("AGD") - hold_count,
        "AGD_OFFSET": codes.count("AGD_OFFSET"),
        "QRY": codes.count("QRY"),
        "REJ": codes.count("REJ"),
        "HOLD": hold_count,
    }
    if actual != expected:
        raise SystemExit(f"status distribution mismatch: {actual} != {expected}")
    if leakage <= 1_400_000:
        raise SystemExit(f"leakage too low: {leakage}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    columns = list(rows[0].keys())
    with OUT.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)

    print(f"wrote {OUT} ({len(rows)} rows)")
    print(f"statuses: {actual}")
    print(f"leakage prevented: ${leakage:,}")
    print(f"billed: ${second['totalBilledUsd']:,} | verified cash: ${second['totalVerifiedUsd']:,}")
    print(f"offset: ${second['totalPremiumOffsetUsd']:,} | OSLR: ${second['totalEndingOslrUsd']:,}")


if __name__ == "__main__":
    main()
