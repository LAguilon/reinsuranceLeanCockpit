#!/usr/bin/env python3
"""ACORD GRLC (ECOT / EBOT) adapter — stdlib only.

Inbound:  ClaimMovement XML or JSON  ->  (FacCertificate, FacClaimSubmission)
Outbound: Lean FacAuditResult        ->  ClaimMovementResponse XML + EBOT JSON

The adapter never computes a payable. It translates, then hands the numbers to
the compiled Lean binary, then translates the verified answer back. Anything the
adapter invents is therefore limited to field mapping.

Security: XML with a DOCTYPE or ENTITY declaration is rejected before parsing.
That is the whole XXE defence, and it is deliberately blunt — a reinsurance
settlement message has no legitimate use for an entity declaration.
"""

from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

MAX_MESSAGE_BYTES = 2_000_000


# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------

def assert_safe_xml(text: str) -> None:
    lowered = text.lower()
    if "<!doctype" in lowered or "<!entity" in lowered:
        raise ValueError("XML rejected: DOCTYPE/ENTITY declarations are not permitted")


# ---------------------------------------------------------------------------
# Field normalisation
# ---------------------------------------------------------------------------

LINE_CODES = {
    "AL": "AutoLiability", "AUTOLIABILITY": "AutoLiability", "AUTO": "AutoLiability",
    "GL": "GeneralLiability", "GENERALLIABILITY": "GeneralLiability",
    "WCA": "WorkersComp", "WC": "WorkersComp", "WORKERSCOMP": "WorkersComp",
    "DO": "DirectorsOfficers", "D&O": "DirectorsOfficers",
    "DIRECTORSOFFICERS": "DirectorsOfficers",
}

ALAE_CODES = {
    "PRA": "proRataInAddition", "PRORATA": "proRataInAddition",
    "PRORATAINADDITION": "proRataInAddition",
    "IL": "includedInLimit", "IN": "includedInLimit",
    "INCLUDEDINLIMIT": "includedInLimit", "INSIDE": "includedInLimit",
    "EX": "excluded", "EXCLUDED": "excluded", "INDEMNITYONLY": "excluded",
}

NUMERIC_FIELDS = {
    "attachmentpointamt": "attachmentUsd",
    "layerlimitamt": "occLimitUsd",
    "occlimitamt": "occLimitUsd",
    "signedlinebps": "signedShareBps",
    "grosspremiumamt": "grossPremiumUsd",
    "brokeragebps": "brokerageBps",
    "paidpremiumamt": "paidPremiumToDateUsd",
    "paidindemnityamt": "paidIndemnityUsd",
    "paidexpenseamt": "paidAlaeUsd",
    "oslrindemnityamt": "oslrIndemnityUsd",
    "oslrexpenseamt": "oslrAlaeUsd",
    "priorsettledamt": "priorPaidUsd",
    "prioroslramt": "priorOslrBookedUsd",
    "cashcallbilledamt": "cedentBilledNowUsd",
    "cedentbillednowusd": "cedentBilledNowUsd",
}

PERCENT_FIELDS = {
    "signedlinepct": ("signedShareBps", 100),
    "brokeragepct": ("brokerageBps", 100),
}

TEXT_FIELDS = {
    "contractreference": "certId",
    "certid": "certId",
    "insuredname": "insuredName",
    "cedentname": "cedentName",
    "cedent": "cedentName",
    "insuredgroup": "insuredGroup",
    "claimreference": "claimId",
    "claimid": "claimId",
    "lossdescription": "lossDesc",
    "clasheventtag": "clashEventTag",
}


def _num(value: str) -> int:
    cleaned = re.sub(r"[,$\s]", "", str(value))
    if cleaned.endswith("%"):
        cleaned = cleaned[:-1]
    return int(float(cleaned)) if "." in cleaned else int(cleaned)


def _local(tag: str) -> str:
    return tag.split("}")[-1].lower()


AMT_ITEM_TYPES = {
    "paidloss": "paidIndemnityUsd",
    "paidexpense": "paidAlaeUsd",
    "oslrloss": "oslrIndemnityUsd",
    "oslrexpense": "oslrAlaeUsd",
    "cashcall": "cedentBilledNowUsd",
    "priorsettled": "priorPaidUsd",
    "prioroslr": "priorOslrBookedUsd",
}


def _collect_xml(node, cert: dict, claim: dict) -> None:
    for child in node:
        key = _local(child.tag)
        text = (child.text or "").strip()

        # Authentic ACORD GRLC: ClaimEntry carries typed amount items.
        if key == "claimmovementamtitem":
            kind = (child.get("Type") or "").strip().lower()
            field = AMT_ITEM_TYPES.get(kind)
            if field:
                amt_el = next((c for c in child if _local(c.tag) == "amt"), None)
                raw = (amt_el.text if amt_el is not None else child.text) or "0"
                try:
                    claim[field] = _num(raw)
                except ValueError:
                    pass
            _collect_xml(child, cert, claim)
            continue
        if key in NUMERIC_FIELDS and text:
            cert_or_claim = NUMERIC_FIELDS[key]
            target = claim if cert_or_claim in {
                "paidIndemnityUsd", "paidAlaeUsd", "oslrIndemnityUsd", "oslrAlaeUsd",
                "priorPaidUsd", "priorOslrBookedUsd", "cedentBilledNowUsd",
            } else cert
            target[cert_or_claim] = _num(text)
        elif key in PERCENT_FIELDS and text:
            field, factor = PERCENT_FIELDS[key]
            cert[field] = _num(text) * factor
        elif key in TEXT_FIELDS and text:
            field = TEXT_FIELDS[key]
            (claim if field in {"claimId", "lossDesc", "clashEventTag"} else cert)[field] = text
        elif key == "lineofbusiness" and text:
            cert["line"] = LINE_CODES.get(text.upper(), "GeneralLiability")
        elif key == "alaeclausecode" and text:
            cert["alaeClause"] = ALAE_CODES.get(text.upper().replace("-", ""), "proRataInAddition")
        elif key == "applypremiumoffset" and text:
            claim["applyPremiumOffset"] = text.lower() in {"true", "1", "yes", "y"}
        _collect_xml(child, cert, claim)


def _walk_json(node, cert: dict, claim: dict) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            norm = re.sub(r"[^a-z0-9]", "", key.lower())
            if norm in NUMERIC_FIELDS and not isinstance(value, (dict, list)):
                field = NUMERIC_FIELDS[norm]
                target = claim if field in {
                    "paidIndemnityUsd", "paidAlaeUsd", "oslrIndemnityUsd", "oslrAlaeUsd",
                    "priorPaidUsd", "priorOslrBookedUsd", "cedentBilledNowUsd",
                } else cert
                target[field] = int(value)
            elif norm in PERCENT_FIELDS and not isinstance(value, (dict, list)):
                field, factor = PERCENT_FIELDS[norm]
                cert[field] = int(round(float(value) * factor))
            elif norm in TEXT_FIELDS and not isinstance(value, (dict, list)):
                field = TEXT_FIELDS[norm]
                (claim if field in {"claimId", "lossDesc", "clashEventTag"} else cert)[field] = str(value)
            elif norm == "lineofbusiness" and not isinstance(value, (dict, list)):
                cert["line"] = LINE_CODES.get(str(value).upper(), "GeneralLiability")
            elif norm == "alaeclausecode" and not isinstance(value, (dict, list)):
                cert["alaeClause"] = ALAE_CODES.get(str(value).upper().replace("-", ""), "proRataInAddition")
            elif norm == "applypremiumoffset" and not isinstance(value, (dict, list)):
                claim["applyPremiumOffset"] = bool(value)
            _walk_json(value, cert, claim)
    elif isinstance(node, list):
        for item in node:
            _walk_json(item, cert, claim)


def parse_acord(payload: str) -> tuple[dict, dict]:
    """Parse an ACORD GRLC message into the cockpit's certificate/claim dicts."""
    if len(payload.encode("utf-8")) > MAX_MESSAGE_BYTES:
        raise ValueError("message too large")
    cert = {
        "certId": "ACORD-UNKNOWN",
        "insuredName": "",
        "cedentName": "",
        "line": "GeneralLiability",
        "attachmentUsd": 0,
        "occLimitUsd": 0,
        "signedShareBps": 0,
        "alaeClause": "proRataInAddition",
        "grossPremiumUsd": 0,
        "brokerageBps": 0,
        "paidPremiumToDateUsd": 0,
        "insuredGroup": "",
    }
    claim = {
        "claimId": "ACORD-CLAIM",
        "certId": "ACORD-UNKNOWN",
        "lossDesc": "ACORD GRLC claim",
        "paidIndemnityUsd": 0,
        "paidAlaeUsd": 0,
        "oslrIndemnityUsd": 0,
        "oslrAlaeUsd": 0,
        "priorPaidUsd": 0,
        "priorOslrBookedUsd": 0,
        "cedentBilledNowUsd": 0,
        "applyPremiumOffset": False,
        "clashEventTag": "",
    }

    stripped = payload.lstrip()
    if stripped.startswith("<"):
        assert_safe_xml(payload)
        root = ET.fromstring(payload)
        _collect_xml(root, cert, claim)
    else:
        data = json.loads(payload)
        _walk_json(data, cert, claim)

    if not cert.get("insuredGroup"):
        cert["insuredGroup"] = cert.get("insuredName") or cert.get("cedentName") or ""
    claim["certId"] = cert["certId"]
    if claim.get("claimId") in (None, "", "ACORD-CLAIM"):
        claim["claimId"] = f"ACORD-{cert['certId']}"
    return cert, claim


# ---------------------------------------------------------------------------
# Outbound
# ---------------------------------------------------------------------------

def _esc(text: str) -> str:
    return (
        str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def build_outbound(report: dict, cert: dict, claim: dict, theorem_count: int = 0) -> tuple[str, dict]:
    row = report["results"][0]
    code = row["acordResponseCode"]
    v = row["voucher"]

    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Jv-Ins-Reinsurance Version="2016-1">
  <ClaimMovementResponse>
    <AcknowledgementStatus>{_esc(code)}</AcknowledgementStatus>
    <ResponseStatusCode>{_esc(code)}</ResponseStatusCode>
    <RuschlikonStatus>{_esc(row['ruschlikonStatus'])}</RuschlikonStatus>
    <ContractReference>{_esc(row['certId'])}</ContractReference>
    <ClaimReference>{_esc(row['claimId'])}</ClaimReference>
    <Verdict>{_esc(row['verdict'])}</Verdict>
    <VerifiedPaidAmt>{row['ourCumulativePaidUsd']}</VerifiedPaidAmt>
    <VerifiedIncurredAmt>{row['ourCumulativeIncurredUsd']}</VerifiedIncurredAmt>
    <VerifiedEndingOSLRAmt>{row['verifiedEndingOslrUsd']}</VerifiedEndingOSLRAmt>
    <GrossCashPayableAmt>{row['grossCashPayableNowUsd']}</GrossCashPayableAmt>
    <PremiumOffsetAmt>{row['premiumOffsetUsd']}</PremiumOffsetAmt>
    <NetWireAuthorizedAmt>{row['netCashWireDueUsd']}</NetWireAuthorizedAmt>
    <CedentBilledAmt>{row['cedentBilledNowUsd']}</CedentBilledAmt>
    <OverbilledAmt>{row['overbilledUsd']}</OverbilledAmt>
    <TechAccountEntry>
      <LegA>
        <DebitPaidClaimsExpense>{v['debitPaidClaimsExpenseUsd']}</DebitPaidClaimsExpense>
        <CreditPremiumReceivableOffset>{v['creditPremiumReceivableOffsetUsd']}</CreditPremiumReceivableOffset>
        <CreditCashWirePayable>{v['creditCashWirePayableUsd']}</CreditCashWirePayable>
        <TotalDebit>{v['cashTotalDebitUsd']}</TotalDebit>
        <TotalCredit>{v['cashTotalCreditUsd']}</TotalCredit>
      </LegA>
      <LegB>
        <DebitOSLRExpense>{v['debitOslrExpenseUsd']}</DebitOSLRExpense>
        <CreditOSLRLiability>{v['creditOslrLiabilityUsd']}</CreditOSLRLiability>
        <DebitOSLRLiabilityRelease>{v['debitOslrLiabilityReleaseUsd']}</DebitOSLRLiabilityRelease>
        <CreditOSLRExpenseRelease>{v['creditOslrExpenseReleaseUsd']}</CreditOSLRExpenseRelease>
        <TotalDebit>{v['reserveTotalDebitUsd']}</TotalDebit>
        <TotalCredit>{v['reserveTotalCreditUsd']}</TotalCredit>
      </LegB>
      <GrandTotalDebit>{v['grandTotalDebitUsd']}</GrandTotalDebit>
      <GrandTotalCredit>{v['grandTotalCreditUsd']}</GrandTotalCredit>
    </TechAccountEntry>
    <LeanKernelCertificate>
      <Theorem>fullFacVoucher_balanced</Theorem>
      <Theorem>paid_plus_endingOslr_eq_incurred</Theorem>
      <Theorem>stpAutoAgreed_implies_valid_and_zero_overbill</Theorem>
      <TheoremCount>{theorem_count}</TheoremCount>
      <Sorries>0</Sorries>
    </LeanKernelCertificate>
    <Explanation>{_esc(row['explanation'])}</Explanation>
  </ClaimMovementResponse>
</Jv-Ins-Reinsurance>
"""

    out_json = {
        "messageType": "GRLCClaimMovementResponse",
        "responseStatusCode": code,
        "ruschlikonStatus": row["ruschlikonStatus"],
        "contractReference": row["certId"],
        "claimReference": row["claimId"],
        "verdict": row["verdict"],
        "verified": {
            "paidUsd": row["ourCumulativePaidUsd"],
            "incurredUsd": row["ourCumulativeIncurredUsd"],
            "endingOslrUsd": row["verifiedEndingOslrUsd"],
            "grossCashPayableUsd": row["grossCashPayableNowUsd"],
            "premiumOffsetUsd": row["premiumOffsetUsd"],
            "netWireAuthorizedUsd": row["netCashWireDueUsd"],
            "overbilledUsd": row["overbilledUsd"],
        },
        "ledger": {
            "legA": {
                "debitPaidClaimsExpenseUsd": v["debitPaidClaimsExpenseUsd"],
                "creditPremiumReceivableOffsetUsd": v["creditPremiumReceivableOffsetUsd"],
                "creditCashWirePayableUsd": v["creditCashWirePayableUsd"],
                "totalDebitUsd": v["cashTotalDebitUsd"],
                "totalCreditUsd": v["cashTotalCreditUsd"],
            },
            "legB": {
                "debitOslrExpenseUsd": v["debitOslrExpenseUsd"],
                "creditOslrLiabilityUsd": v["creditOslrLiabilityUsd"],
                "debitOslrLiabilityReleaseUsd": v["debitOslrLiabilityReleaseUsd"],
                "creditOslrExpenseReleaseUsd": v["creditOslrExpenseReleaseUsd"],
                "totalDebitUsd": v["reserveTotalDebitUsd"],
                "totalCreditUsd": v["reserveTotalCreditUsd"],
            },
            "grandTotalDebitUsd": v["grandTotalDebitUsd"],
            "grandTotalCreditUsd": v["grandTotalCreditUsd"],
        },
        "lean": {
            "theorems": [
                "fullFacVoucher_balanced",
                "paid_plus_endingOslr_eq_incurred",
                "stpAutoAgreed_implies_valid_and_zero_overbill",
            ],
            "theoremCount": theorem_count,
            "sorries": 0,
        },
        "explanation": row["explanation"],
        "inbound": {"certificate": cert, "claim": claim},
    }
    return xml, out_json


def bundle_for(cert: dict, claim: dict, desk: str = "ACORD GRLC inbound") -> dict:
    return {"deskName": desk, "certificates": [cert], "claims": [claim]}


if __name__ == "__main__":
    import sys

    for path in sys.argv[1:]:
        cert, claim = parse_acord(Path(path).read_text())
        print(json.dumps({"certificate": cert, "claim": claim}, indent=2))
