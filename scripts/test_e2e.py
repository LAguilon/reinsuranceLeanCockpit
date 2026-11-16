#!/usr/bin/env python3
"""End-to-end test for the v0.3 stack.

Starts the real HTTP handler on an ephemeral port in a background thread, then
drives it exactly as the browser would: preset load, audit, PDF slip binding,
gatekeeper rejection, and a multi-event simulation. Every number asserted here
came out of the compiled Lean binary.

Exit code 0 and the string ALL E2E CHECKS PASSED on success.
"""

import json
import sys
import threading
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
    print("== ReinsuranceLean Cockpit v0.3 — end-to-end ==")

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
        check("GET /api/presets: 3 slips", len(presets.get("slips", [])) == 3)

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
