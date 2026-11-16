#!/usr/bin/env python3
"""End-to-end test for the v0.3 stack.

Starts the real HTTP handler on an ephemeral port in a background thread, then
drives it exactly as the browser would: preset load, audit, PDF slip binding,
gatekeeper rejection, and a multi-event simulation. Every number asserted here
came out of the compiled Lean binary.

Exit code 0 and the string ALL E2E CHECKS PASSED on success.
"""

import json
import subprocess
import sys
import threading
import urllib.error
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))

import app  # noqa: E402

failures = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        failures.append(name)


def request(base: str, path: str, payload=None):
    url = base + path
    if payload is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
    with urllib.request.urlopen(req, timeout=30) as res:
        return json.loads(res.read().decode())


def main() -> int:
    print("== ReinsuranceLean Cockpit v0.4 — end-to-end ==")

    binary = ROOT / ".lake" / "build" / "bin" / "cockpit"
    check("Lean binary exists", binary.exists(), str(binary))
    if not binary.exists():
        print("run `lake build` first")
        return 1

    server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{port}"
    print(f"server on {base}")

    try:
        health = request(base, "/api/health")
        check("GET /api/health", health.get("status") == "ok" and health.get("leanBinaryExists") is True)

        theorems = request(base, "/api/theorems")
        check(
            "GET /api/theorems count >= 32",
            theorems.get("count", 0) >= 32,
            f"count={theorems.get('count')}",
        )

        presets = request(base, "/api/presets")
        check("GET /api/presets: 2 portfolios", len(presets.get("portfolios", [])) == 2)
        check("GET /api/presets: scenario present", presets.get("scenario") is not None)
        check("GET /api/presets: 4 slips", len(presets.get("slips", [])) == 4)

        as_bound = presets["portfolios"][0]["portfolio"]
        fixed = presets["portfolios"][1]["portfolio"]

        report = request(base, "/api/audit", {"portfolio": as_bound})
        check(
            "audit as-bound: ratio 94, insolvent",
            report["stress"]["solvencyRatioPct"] == 94 and report["stress"]["isSolvent"] is False,
            f"ratio={report['stress']['solvencyRatioPct']} solvent={report['stress']['isSolvent']}",
        )
        check("audit as-bound: 7 findings", report["totalFound"] == 7, str(report["totalFound"]))

        fixed_report = request(base, "/api/audit", {"portfolio": fixed})
        check(
            "audit fixed: ratio 168, zero findings",
            fixed_report["stress"]["solvencyRatioPct"] == 168 and fixed_report["totalFound"] == 0,
            f"ratio={fixed_report['stress']['solvencyRatioPct']} findings={fixed_report['totalFound']}",
        )

        def bind(slip_name):
            return request(
                base,
                "/api/parse-slip",
                {"sampleSlipName": slip_name, "portfolio": as_bound},
            )

        slip1 = bind("SLIP_01_Valid_Gap_Closer_USD.pdf")
        check("slip 1: parsed from PDF", slip1["contract"]["id"] == "CNT-WS-GAP-FIX")
        after1 = slip1["auditAfterBind"]
        check("slip 1: passes the gate", after1["allContractsValid"] is True)
        gap_before = any(f["kind"] == "VerticalTowerGap" for f in report["findings"])
        gap_after = any(f["kind"] == "VerticalTowerGap" for f in after1["findings"])
        check("slip 1: closes the vertical gap", gap_before and not gap_after)
        check("slip 1: reduces findings", after1["totalFound"] < report["totalFound"])

        slip2 = bind("SLIP_02_Trap_Unrated_FX_Mismatch.pdf")
        check("slip 2: parsed from PDF", slip2["contract"]["id"] == "CNT-EQ-CAYMAN-99")
        cliffs_before = sum(1 for f in report["findings"] if f["kind"] == "CounterpartyCreditCliff")
        cliffs_after = sum(
            1 for f in slip2["auditAfterBind"]["findings"] if f["kind"] == "CounterpartyCreditCliff"
        )
        check(
            "slip 2: triggers a new counterparty credit cliff",
            cliffs_after > cliffs_before,
            f"{cliffs_before} -> {cliffs_after}",
        )
        check(
            "slip 2: cites the Cayman cell",
            any("Cayman Cell 99" in f["message"] for f in slip2["auditAfterBind"]["findings"]),
        )

        slip4 = bind("SLIP_04_Lost_In_Translation_Hours_Excl.pdf")
        check("slip 4: parsed from PDF", slip4["contract"]["id"] == "CNT-US-FL-EXCL")
        check(
            "slip 4: Lean back-translation is non-empty",
            len(slip4.get("leanBackTranslation") or "") > 40,
            str(slip4.get("leanBackTranslation"))[:60],
        )
        check(
            "slip 4: back-translation names the attachment",
            "25000000" in (slip4.get("leanBackTranslation") or ""),
        )
        divergences = " | ".join(slip4.get("translationWarnings") or [])
        check("slip 4: catches the 72 hours clause", "72 hours" in divergences, divergences[:120])
        check("slip 4: catches the exclusion wording", "excluding" in divergences.lower())
        check(
            "slip 4: gatekeeper still admits the numbers",
            slip4["auditAfterBind"]["allContractsValid"] is True,
        )

        slip3 = bind("SLIP_03_Illegal_115pct_QuotaShare.pdf")
        check("slip 3: parsed from PDF", slip3["contract"]["kind"]["shareBps"] == 11500)
        after3 = slip3["auditAfterBind"]
        check("slip 3: gatekeeper rejects", after3["allContractsValid"] is False)
        check(
            "slip 3: rejection names the 115% share",
            any("11500" in e for e in after3["validationErrors"]),
            str(after3.get("validationErrors")),
        )

        sim = request(
            base,
            "/api/simulate",
            {"portfolio": as_bound, "scenario": presets["scenario"]},
        )
        check(
            "simulate: conservation of money",
            sim["annualNetBeforeStopLossEur"] + sim["annualOutwardRecoveredEur"]
            == sim["annualInwardGrossEur"],
            f"{sim['annualNetBeforeStopLossEur']} + {sim['annualOutwardRecoveredEur']} != {sim['annualInwardGrossEur']}",
        )
        check(
            "simulate: SCR equals its four components",
            sim["totalScrEur"]
            == sim["annualFinalNetLossEur"]
            + sim["totalReinstFeeEur"]
            + sim["counterpartyScrEur"]
            + sim["otherScrEur"],
        )
        check("simulate: three events priced", len(sim["events"]) == 3)
        check("simulate: all contracts admissible", sim["allContractsValid"] is True)

        # ---- Monotonicity Stress Sweep -------------------------------------
        print("\n-- Monotonicity Stress Sweep ($0 -> $500M US windstorm) --")
        sweep_losses = [0, 25_000_000, 60_000_000, 100_000_000, 200_000_000, 500_000_000]
        sweep = []
        for loss in sweep_losses:
            scenario = {
                "scenarioName": f"monotonicity sweep @ {loss}",
                "fxOverridesToEurCents": [
                    {"currency": "EUR", "cents": 100},
                    {"currency": "USD", "cents": 100},
                ],
                "events": [
                    {
                        "eventName": "US windstorm",
                        "peril": "Windstorm",
                        "currency": "USD",
                        "groundUpLoss": loss,
                    }
                ],
            }
            sweep.append(request(base, "/api/simulate", {"portfolio": as_bound, "scenario": scenario}))

        print(f"  {'loss':>12} {'inward':>12} {'netFinal':>12} {'drain':>12} {'postFunds':>12} {'ratio':>6}")
        for loss, row in zip(sweep_losses, sweep):
            print(
                f"  {loss:>12} {row['annualInwardGrossEur']:>12} {row['annualFinalNetLossEur']:>12} "
                f"{row['seasonLossDrainEur']:>12} {row['postSeasonOwnFundsEur']:>12} {row['solvencyRatioPct']:>6}"
            )

        def nondecreasing(xs):
            return all(a <= b for a, b in zip(xs, xs[1:]))

        def nonincreasing(xs):
            return all(a >= b for a, b in zip(xs, xs[1:]))

        inward = [r["annualInwardGrossEur"] for r in sweep]
        final_net = [r["annualFinalNetLossEur"] for r in sweep]
        post_funds = [r["postSeasonOwnFundsEur"] for r in sweep]
        ratios = [r["solvencyRatioPct"] for r in sweep]

        check("sweep: inward gross is non-decreasing", nondecreasing(inward), str(inward))
        check("sweep: final net loss is non-decreasing", nondecreasing(final_net), str(final_net))
        check("sweep: post-season own funds are non-increasing", nonincreasing(post_funds), str(post_funds))
        check("sweep: post-season ratio is non-increasing", nonincreasing(ratios), str(ratios))
        check(
            "sweep: ratio strictly falls from $0 to $500M",
            ratios[0] > ratios[-1],
            f"{ratios[0]} -> {ratios[-1]}",
        )
        check(
            "sweep: ratio strictly falls from $0 to $200M",
            ratios[0] > ratios[3],
            f"{ratios[0]} -> {ratios[3]}",
        )
        check(
            "sweep: own funds never exceed initial capital",
            all(r["postSeasonOwnFundsEur"] <= r["initialOwnFundsEur"] for r in sweep),
        )
        check(
            "sweep: drain identity holds at every step",
            all(
                r["seasonLossDrainEur"]
                == r["annualFinalNetLossEur"] + r["totalReinstFeeEur"]
                for r in sweep
            ),
        )
        check(
            "sweep: post-season capital identity holds at every step",
            all(
                r["postSeasonOwnFundsEur"]
                == max(r["initialOwnFundsEur"] - r["seasonLossDrainEur"], 0)
                for r in sweep
            ),
        )

        # ---- US facultative desk (v0.6) ------------------------------------
        fac = request(base, "/api/fac-presets")
        check("GET /api/fac-presets: 6 US facultative cases", len(fac["cases"]) == 6)
        report0 = fac["report"]
        check(
            "fac presets: billed / cash verified / leakage totals",
            report0["totalBilledUsd"] == 3_610_000
            and report0["totalVerifiedUsd"] == 2_630_000
            and report0["totalOverbilledUsd"] == 980_000,
            f"{report0['totalBilledUsd']}/{report0['totalVerifiedUsd']}/{report0['totalOverbilledUsd']}",
        )
        check("fac presets: 4 of 6 disputed", report0["disputeCount"] == 4)
        check("fac presets: premium offset total 51,000", report0["totalPremiumOffsetUsd"] == 51_000)
        check("fac presets: net wire total 2,579,000", report0["totalNetWireUsd"] == 2_579_000)
        check("fac presets: ending OSLR total 280,000", report0["totalEndingOslrUsd"] == 280_000)

        for case in fac["cases"]:
            with urllib.request.urlopen(base + case["pdfUrl"]) as res:
                is_pdf = res.headers.get("Content-Type") == "application/pdf"
                body = res.read()
            check(f"fac PDF served: {case['certId']}", is_pdf and body.startswith(b"%PDF"))

        fac_audit = request(base, "/api/fac-audit", {"bundle": fac["bundle"]})
        expected = {
            "FAC-AL-01": (0, 130_000, "DISPUTE_OVERBILLED", "QRY"),
            "FAC-DO-02": (2_000_000, 400_000, "DISPUTE_OVERBILLED", "QRY"),
            "FAC-WCA-03": (150_000, 200_000, "DISPUTE_OVERBILLED", "QRY"),
            "FAC-GL-04": (280_000, 0, "APPROVED_EXACT", "AGD"),
            "FAC-AL-05": (0, 250_000, "DISPUTE_PREMATURE_OSLR_CASHCALL", "QRY"),
            "FAC-GL-06": (200_000, 0, "APPROVED_EXACT", "AGD_OFFSET"),
        }
        for row in fac_audit["results"]:
            cash, over_usd, verdict, code = expected[row["certId"]]
            check(
                f"fac audit {row['certId']}: {verdict}",
                row["grossCashPayableNowUsd"] == cash
                and row["overbilledUsd"] == over_usd
                and row["verdict"] == verdict
                and row["acordResponseCode"] == code,
                f"cash={row['grossCashPayableNowUsd']} over={row['overbilledUsd']} code={row['acordResponseCode']}",
            )
            check(
                f"fac voucher balanced: {row['certId']}",
                row["voucher"]["grandTotalDebitUsd"] == row["voucher"]["grandTotalCreditUsd"]
                and row["voucher"]["cashTotalDebitUsd"] == row["voucher"]["cashTotalCreditUsd"],
            )
            check(
                f"fac paid+OSLR=incurred: {row['certId']}",
                row["ourCumulativePaidUsd"] + row["verifiedEndingOslrUsd"] == row["ourCumulativeIncurredUsd"],
            )
            check(f"fac memo non-empty: {row['certId']}", len(row["brokerMemo"]) > 100)
            check(f"fac lean spec generated: {row['certId']}", "auditFacClaim certificate claim" in row["leanSpecCode"])

        oslr_row = next(r for r in fac_audit["results"] if r["certId"] == "FAC-AL-05")
        check("fac case 5 books 280,000 OSLR with zero cash", oslr_row["verifiedEndingOslrUsd"] == 280_000 and oslr_row["netCashWireDueUsd"] == 0)
        offset_row = next(r for r in fac_audit["results"] if r["certId"] == "FAC-GL-06")
        check(
            "fac case 6 offsets 51,000 and wires 149,000",
            offset_row["premiumOffsetUsd"] == 51_000 and offset_row["netCashWireDueUsd"] == 149_000,
        )
        check("fac workflow trace has 4 steps", len(fac_audit["workflowTrace"]) == 4)

        custom = json.loads(json.dumps(fac["bundle"]))
        custom["claims"][3]["cedentBilledNowUsd"] = 260_000
        custom_audit = request(base, "/api/fac-audit", {"bundle": custom})
        check(
            "fac custom run flags underbilling",
            custom_audit["results"][3]["verdict"] == "REVIEW_UNDERBILLED"
            and custom_audit["results"][3]["underbilledUsd"] == 20_000,
            custom_audit["results"][3]["verdict"],
        )

        guide = ROOT / "docs" / "USER_GUIDE.md"
        check("docs/USER_GUIDE.md exists", guide.exists())
        check(
            "docs/USER_GUIDE.md is comprehensive (>150 lines)",
            guide.exists() and guide.read_text().count("\n") > 150,
            f"{guide.read_text().count(chr(10)) if guide.exists() else 0} lines",
        )

        # ---- Universal intake (v0.8) ---------------------------------------
        intake_samples = fac.get("intakeSamples", [])
        check("presets expose 4 intake samples", len(intake_samples) == 4)
        intake_expected = {
            "EMAIL_01_URGENT_AL_Trucking.txt": ("text", "DISPUTE_OVERBILLED", 78_000, 0),
            "EMAIL_03_Punitive_Hammer_Warning.txt": ("text", "DISPUTE_OVERBILLED", 400_000, 5),
            "ACORD_ECOT_02_AL_OSLR_Premature_CashCall.xml": (
                "acord_xml", "DISPUTE_PREMATURE_OSLR_CASHCALL", 250_000, 0),
            "FAC-AL-05_Premature_OSLR_Cash_Call.pdf": (
                "pdf", "DISPUTE_PREMATURE_OSLR_CASHCALL", 250_000, 0),
        }
        for sample in intake_samples:
            out = request(base, "/api/fac-intake", {"sampleName": sample["name"]})
            fmt, verdict, over, warns = intake_expected[sample["name"]]
            row = out["report"]["results"][0]
            check(
                f"intake {sample['name']}: format/verdict/overbill",
                out["sourceFormat"] == fmt and row["verdict"] == verdict and row["overbilledUsd"] == over,
                f"{out['sourceFormat']}/{row['verdict']}/{row['overbilledUsd']}",
            )
            check(
                f"intake {sample['name']}: translation warnings",
                len(out["translationWarnings"]) == warns,
                str(len(out["translationWarnings"])),
            )
            check(
                f"intake {sample['name']}: generated Lean compiles to a def",
                "def certificate" in row["leanSpecCode"] and "def claim" in row["leanSpecCode"],
            )
            check(f"intake {sample['name']}: back-translation present", len(row["backTranslation"]) > 40)

        # ---- Executive group bridge (v0.9) ---------------------------------
        execu = request(base, "/api/executive-summary", {})
        rollup = execu["group"]["rollup"]
        check(
            "executive rollup: leakage 980k / offset 51k / OSLR 280k",
            rollup["totalLeakagePreventedUsd"] == 980_000
            and rollup["totalPremiumOffsetRecoveredUsd"] == 51_000
            and rollup["totalEndingOslrBookedUsd"] == 280_000,
            str(rollup),
        )
        check("executive rollup: net wire 2,579,000", rollup["totalNetWireUsd"] == 2_579_000)
        check("executive rollup: STP rate 16%", rollup["stpRatePct"] == 16)
        clashes = execu["group"]["clashes"]
        check("executive: two clash findings", len(clashes) == 2, str(len(clashes)))
        check(
            "executive: WCA + GL pileup exceeds threshold",
            any(
                "Workers Compensation" in c["lines"] and "General Liability" in c["lines"] and c["exceedsThreshold"]
                for c in clashes
            ),
        )
        check(
            "executive: protected ratio >= group ratio",
            execu["group"]["protectedRatioPct"] >= execu["group"]["ratioPct"],
        )
        check("executive: treaty stress still 94%", execu["treaty"]["solvencyRatioPct"] == 94)

        # ---- ACORD GRLC / Ruschlikon STP (v0.7) ----------------------------
        acord = request(base, "/api/acord-samples")
        check("GET /api/acord-samples: 3 messages", len(acord["samples"]) == 3)
        codes = {}
        for sample in acord["samples"]:
            out = request(base, "/api/acord-process", {"sampleName": sample["name"]})
            row = out["report"]["results"][0]
            codes[sample["name"]] = row["acordResponseCode"]
            check(
                f"acord {sample['name']}: outbound XML",
                out["outboundXml"].startswith("<?xml") and "<ResponseStatusCode>" in out["outboundXml"],
            )
            check(
                f"acord {sample['name']}: outbound JSON ledger balanced",
                out["outboundJson"]["ledger"]["grandTotalDebitUsd"]
                == out["outboundJson"]["ledger"]["grandTotalCreditUsd"],
            )
            check(
                f"acord {sample['name']}: inbound echoes to outbound",
                out["inbound"]["certificate"]["certId"] == row["certId"],
            )
        check(
            "acord responses are AGD / QRY / QRY",
            list(codes.values()) == ["AGD", "QRY", "QRY"],
            str(codes),
        )

        def post_status(path, payload, size=None):
            data = json.dumps(payload).encode() if size is None else b" " * size
            req = urllib.request.Request(
                base + path, data=data, headers={"Content-Type": "application/json"}, method="POST"
            )
            try:
                with urllib.request.urlopen(req) as res:
                    return res.status
            except urllib.error.HTTPError as err:
                return err.code

        xxe = '<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><ACORD><X>&xxe;</X></ACORD>'
        check("acord XXE payload rejected with 400", post_status("/api/acord-process", {"content": xxe}) == 400)
        check("oversized payload rejected with 413", post_status("/api/acord-process", {}, 2_500_000) == 413)

        audit = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "paranoid_audit.py")],
            capture_output=True, text=True,
        )
        check("paranoid audit (Buzzard Q1..Q4) exits 0", audit.returncode == 0, audit.stdout[-200:])

        with urllib.request.urlopen(base + "/api/slips/SLIP_01_Valid_Gap_Closer_USD.pdf") as res:
            content_type = res.headers.get("Content-Type", "")
            payload = res.read()
        check(
            "GET /api/slips serves application/pdf",
            content_type == "application/pdf" and payload.startswith(b"%PDF"),
            f"content-type={content_type}",
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    if failures:
        print(f"\n{len(failures)} CHECK(S) FAILED: {failures}")
        return 1
    print("\nALL E2E CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
