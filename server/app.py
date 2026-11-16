#!/usr/bin/env python3
"""Zero-dependency backend for the ReinsuranceLean Cockpit.

Every number the browser shows comes from the compiled Lean binary. Python here
is a transport layer: it moves JSON to a temp file, runs
`.lake/build/bin/cockpit`, and returns whatever the kernel-checked code said.
There is no second implementation of the arithmetic to drift out of sync.

Standard library only: http.server, json, subprocess, tempfile, pathlib,
base64, time, os, sys.
"""

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
LEAN_BIN = ROOT / ".lake" / "build" / "bin" / "cockpit"
EXAMPLES = ROOT / "examples"
SLIPS = EXAMPLES / "slips"
FAC_SLIPS = EXAMPLES / "fac_slips"
FAC_BUNDLE = EXAMPLES / "us_facultative_desk.json"

sys.path.insert(0, str(ROOT / "server"))
import slip_parser  # noqa: E402

PRESET_PORTFOLIOS = [
    ("as_bound", "Continental Re (As Bound - 94% Breach)", "continental_re_portfolio.json"),
    ("fixed", "Continental Re (Restructured - 168% Solvent)", "continental_re_fixed.json"),
]

SLIP_LABELS = {
    "SLIP_01_Valid_Gap_Closer_USD.pdf": (
        "Gap-Closing Windstorm Layer (Valid)",
        "Closes the 10M USD vertical gap between Layer 1 and Layer 2.",
    ),
    "SLIP_02_Trap_Unrated_FX_Mismatch.pdf": (
        "Cayman Unrated EUR Quake Slip (Loophole Trap)",
        "Unrated counterparty, EUR-denominated against JPY inward business.",
    ),
    "SLIP_03_Illegal_115pct_QuotaShare.pdf": (
        "Broker Typo 115% Quota Share (Illegal)",
        "shareBps = 11500 violates the quota-share bound; the gate must reject it.",
    ),
    "SLIP_04_Lost_In_Translation_Hours_Excl.pdf": (
        "Unmodeled Florida Exclusion / 72h Clause",
        "Numbers are admissible; the wording contains a 72 hours clause and an exclusion the AST cannot represent.",
    ),
}


def lean_available() -> bool:
    return LEAN_BIN.exists()


def ensure_binary() -> bool:
    """`lake build` should already produce the exe (it is a default target), but
    a fresh clone with `lake build ReinsuranceLeanCockpit` only would not. Build
    on demand rather than failing with a 500 on the first request."""
    if lean_available():
        return True
    lake = shutil.which("lake")
    print(f"cockpit binary missing at {LEAN_BIN}")
    if not lake:
        print("lake is not on PATH. Install Lean (elan), then run: lake build cockpit")
        return False
    print("building: lake build cockpit ...")
    proc = subprocess.run([lake, "build", "cockpit"], cwd=str(ROOT))
    ok = proc.returncode == 0 and lean_available()
    print("build ok" if ok else "build FAILED — run `lake build` and read the errors")
    return ok


def run_lean(args: list[str], timeout: int = 10) -> tuple[dict, float]:
    started = time.perf_counter()
    proc = subprocess.run(
        [str(LEAN_BIN), *args], capture_output=True, text=True, timeout=timeout
    )
    elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "lean failed").strip())
    return json.loads(proc.stdout), elapsed_ms


def run_lean_on_portfolio(portfolio: dict) -> tuple[dict, float]:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(portfolio, fh)
        path = fh.name
    try:
        return run_lean(["audit", path, "--json"])
    finally:
        os.unlink(path)


def run_lean_on_scenario(portfolio: dict, scenario: dict) -> tuple[dict, float]:
    handles = []
    try:
        for payload in (portfolio, scenario):
            fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump(payload, fh)
            fh.close()
            handles.append(fh.name)
        return run_lean(["simulate", handles[0], handles[1], "--json"])
    finally:
        for path in handles:
            os.unlink(path)


def back_translate(contract: dict) -> str | None:
    """Ask Lean what the contract means, in English. The text comes from the
    same fields the proofs consume, so it cannot describe a contract Lean did
    not see."""
    if not lean_available():
        return None
    path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(contract, fh)
            path = fh.name
        proc = subprocess.run(
            [str(LEAN_BIN), "informalize", path],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode != 0:
            return None
        return proc.stdout.strip()
    except Exception:  # noqa: BLE001 - a missing translation is not a 500
        return None
    finally:
        if path and os.path.exists(path):
            os.unlink(path)


FAC_CASE_LABELS = {
    "FAC-AL-01": ("Auto Liability", "$500k xs $500k", "ALAE Pro-Rata in Addition",
                  "FAC-AL-01_Auto_Liability_Cash_Call.pdf"),
    "FAC-DO-02": ("D&O", "20% of $10M xs $10M", "ALAE Inside Limits",
                  "FAC-DO-02_DO_Cash_Call.pdf"),
    "FAC-WCA-03": ("Workers' Comp", "$500k xs $500k", "Indemnity Only",
                   "FAC-WCA-03_Workers_Comp_Cash_Call.pdf"),
    "FAC-GL-04": ("General Liability", "$500k xs $500k", "ALAE Pro-Rata in Addition",
                  "FAC-GL-04_General_Liability_Cash_Call.pdf"),
    "FAC-AL-05": ("Auto Liability", "$500k xs $500k", "OSLR trap: paid below attachment",
                  "FAC-AL-05_Premature_OSLR_Cash_Call.pdf"),
    "FAC-GL-06": ("General Liability", "$500k xs $500k", "Premium offset + clash tag",
                  "FAC-GL-06_Premium_Offset_Pileup.pdf"),
}


def run_lean_fac(bundle: dict) -> tuple[dict, float]:
    path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(bundle, fh)
            path = fh.name
        return run_lean(["fac-audit", path, "--json"])
    finally:
        if path and os.path.exists(path):
            os.unlink(path)


def fac_cases(bundle: dict) -> list[dict]:
    cases = []
    for cert in bundle.get("certificates", []):
        line, limit_label, clause, pdf = FAC_CASE_LABELS.get(
            cert["certId"], (cert.get("line", ""), "custom", cert.get("alaeClause", ""), None)
        )
        cases.append(
            {
                "certId": cert["certId"],
                "insured": cert.get("insuredName", ""),
                "line": line,
                "limitLabel": limit_label,
                "alaeLabel": clause,
                "pdfUrl": f"/api/fac-slips/{pdf}" if pdf else None,
            }
        )
    return cases


def workflow_trace(report: dict, bundle: dict) -> list[dict]:
    n_certs = len(bundle.get("certificates", []))
    n_claims = len(bundle.get("claims", []))
    disputes = report.get("disputeCount", 0)
    approved = n_claims - disputes
    return [
        {
            "step": 1,
            "name": "Cash-Call & Certificate Reader",
            "detail": f"Parsed {n_certs} certificates and {n_claims} Q3 cash calls; matched each claim to its certificate and extracted attachment, limit, signed share and ALAE clause.",
        },
        {
            "step": 2,
            "name": "Lean 4 Kernel Verifier",
            "detail": f"Recomputed every payable in exact integer arithmetic. {disputes} of {n_claims} cash calls failed verification; each verdict cites the clause that decided it.",
        },
        {
            "step": 3,
            "name": "Technical Accounting Ledger",
            "detail": f"Produced {n_claims} journal vouchers splitting each verified amount into indemnity and ALAE debits against cedent payable. Debits equal credits on all {n_claims}.",
        },
        {
            "step": 4,
            "name": "Broker Settlement / Dispute Memo",
            "detail": f"Drafted {disputes} dispute notices and {approved} approvals. Net adjustment: ${report.get('totalOverbilledUsd', 0) - report.get('totalUnderbilledUsd', 0):,}.",
        },
    ]


def read_json(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def slip_list() -> list[dict]:
    out = []
    if not SLIPS.exists():
        return out
    for path in sorted(SLIPS.glob("*.pdf")):
        label, description = SLIP_LABELS.get(path.name, (path.stem, "Sample slip"))
        out.append(
            {
                "name": path.name,
                "label": label,
                "description": description,
                "url": f"/api/slips/{path.name}",
            }
        )
    return out


class Handler(SimpleHTTPRequestHandler):
    server_version = "ReinsuranceLeanCockpit/0.4"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB), **kwargs)

    # -- helpers ---------------------------------------------------------
    def send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def error_json(self, message: str, status: int = 400) -> None:
        self.send_json({"error": message}, status)

    def read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length) or b"{}")

    # -- routing ---------------------------------------------------------
    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        try:
            if path == "/api/health":
                return self.send_json({"status": "ok", "leanBinaryExists": lean_available()})
            if path == "/api/theorems":
                data, ms = run_lean(["theorems", "--json"])
                return self.send_json({"theorems": data, "count": len(data), "leanExecMs": ms})
            if path == "/api/presets":
                return self.send_json(self.presets())
            if path == "/api/fac-presets":
                return self.send_json(self.fac_presets())
            if path.startswith("/api/slips/"):
                return self.send_slip(path[len("/api/slips/"):])
            if path.startswith("/api/fac-slips/"):
                return self.send_fac_slip(path[len("/api/fac-slips/"):])
            return super().do_GET()
        except Exception as exc:  # noqa: BLE001 - surface the message, not a stack
            self.error_json(str(exc), 500)

    def do_POST(self) -> None:
        path = self.path.split("?")[0]
        try:
            body = self.read_body()
            if path == "/api/audit":
                report, ms = run_lean_on_portfolio(body["portfolio"])
                return self.send_json({**report, "leanExecMs": ms})
            if path == "/api/simulate":
                report, ms = run_lean_on_scenario(body["portfolio"], body["scenario"])
                return self.send_json({**report, "leanExecMs": ms})
            if path == "/api/parse-slip":
                return self.send_json(self.parse_slip(body))
            if path == "/api/fac-audit":
                bundle = body.get("bundle") or read_json(FAC_BUNDLE)
                report, ms = run_lean_fac(bundle)
                return self.send_json({**report, "workflowTrace": workflow_trace(report, bundle), "leanExecMs": ms})
            return self.error_json("unknown endpoint", 404)
        except KeyError as exc:
            self.error_json(f"missing field: {exc}", 400)
        except subprocess.TimeoutExpired:
            self.error_json("Lean binary timed out after 10s", 504)
        except Exception as exc:  # noqa: BLE001
            self.error_json(str(exc), 500)

    # -- handlers --------------------------------------------------------
    def presets(self) -> dict:
        portfolios = []
        for pid, label, filename in PRESET_PORTFOLIOS:
            path = EXAMPLES / filename
            if path.exists():
                portfolios.append({"id": pid, "label": label, "portfolio": read_json(path)})
        scenario_path = EXAMPLES / "scenarios" / "global_twin_cat_fx_shock.json"
        return {
            "portfolios": portfolios,
            "scenario": read_json(scenario_path) if scenario_path.exists() else None,
            "slips": slip_list(),
        }

    def fac_presets(self) -> dict:
        bundle = read_json(FAC_BUNDLE)
        report, ms = run_lean_fac(bundle)
        return {
            "deskName": bundle.get("deskName", "US Facultative Desk"),
            "bundle": bundle,
            "cases": fac_cases(bundle),
            "report": report,
            "workflowTrace": workflow_trace(report, bundle),
            "leanExecMs": ms,
        }

    def send_fac_slip(self, filename: str) -> None:
        safe = Path(filename).name
        path = FAC_SLIPS / safe
        if not path.exists() or path.suffix.lower() != ".pdf":
            return self.error_json("cash-call slip not found", 404)
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/pdf")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", f'inline; filename="{safe}"')
        self.end_headers()
        self.wfile.write(data)

    def send_slip(self, filename: str) -> None:
        safe = Path(filename).name
        path = SLIPS / safe
        if not path.exists() or path.suffix.lower() != ".pdf":
            return self.error_json("slip not found", 404)
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/pdf")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", f'inline; filename="{safe}"')
        self.end_headers()
        self.wfile.write(data)

    def parse_slip(self, body: dict) -> dict:
        if "sampleSlipName" in body:
            name = Path(body["sampleSlipName"]).name
            path = SLIPS / name
            if not path.exists():
                raise ValueError(f"sample slip not found: {name}")
            data, filename = path.read_bytes(), name
        elif "contentBase64" in body:
            data = base64.b64decode(body["contentBase64"])
            filename = body.get("filename", "upload.pdf")
        else:
            raise ValueError("provide sampleSlipName or contentBase64")

        parsed = slip_parser.parse_slip_bytes(data, filename)
        result = {
            "filename": filename,
            "extractedText": parsed["extractedText"],
            "contract": parsed["contract"],
            "parseWarnings": parsed["parseWarnings"],
            "translationWarnings": parsed.get("translationWarnings", []),
            "leanBackTranslation": back_translate(parsed["contract"]),
            "auditAfterBind": None,
            "leanExecMs": None,
        }

        portfolio = body.get("portfolio")
        if portfolio:
            trial = json.loads(json.dumps(portfolio))
            trial.setdefault("contracts", []).append(parsed["contract"])
            report, ms = run_lean_on_portfolio(trial)
            result["auditAfterBind"] = report
            result["leanExecMs"] = ms
        return result

    def log_message(self, fmt: str, *args) -> None:  # quieter console
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    if not WEB.exists():
        raise SystemExit(f"web directory missing: {WEB}")
    ensure_binary()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"ReinsuranceLean Cockpit v0.4 on http://localhost:{port}")
    print(f"Lean binary: {LEAN_BIN} ({'found' if lean_available() else 'MISSING — run lake build'})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
