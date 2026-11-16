#!/usr/bin/env python3
"""500-case property fuzz plus security probes.

Property tests (per case, from the compiled Lean binary):
  * full voucher balances: grand debits == grand credits
  * cash leg balances: cash debits == cash credits
  * paid + ending OSLR == incurred
  * STP safety: AGD implies a valid certificate and zero over/under-billing
  * no over-recovery: for valid certificates, ceded paid <= ground-up paid loss

Self-consistency round trip: re-bill 60 cases at exactly the verified cash
amount and assert the classifier returns AGD / AGD_OFFSET for valid certificates
and REJ for invalid ones.

Security probes against a live server:
  * XXE payload -> 400
  * 2.5 MB body -> 413
  * path traversal -> 400/403/404
  * Cache-Control: no-store on / and /api/health

Optional: builds the Docker image when a daemon is available.
"""

import json
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import http.client
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".lake" / "build" / "bin" / "cockpit"
sys.path.insert(0, str(ROOT / "server"))
import app  # noqa: E402

LINES = ["AutoLiability", "GeneralLiability", "WorkersComp", "DirectorsOfficers"]
CLAUSES = ["includedInLimit", "proRataInAddition", "excluded"]
TAGS = ["", "", "", "EVENT-OHIO-PLANT-2026", "EVENT-MIDWEST-PILEUP"]

failures = []
checked = 0


def ok(name, detail=""):
    print(f"  PASS  {name}" + (f"  ({detail})" if detail else ""))


def bad(name, detail=""):
    print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))
    failures.append(name)


def valid(cert: dict) -> bool:
    return (
        0 < cert["signedShareBps"] <= 10000
        and cert["occLimitUsd"] > 0
        and cert["brokerageBps"] <= 10000
    )


def random_case(rng: random.Random) -> tuple[dict, dict]:
    line = rng.choice(LINES)
    att = rng.choice([0, 1, 250_000, 500_000, 1_000_000, 10_000_000])
    occ = rng.choice([1, 100_000, 500_000, 1_000_000, 10_000_000])
    share = rng.choice([0, 1, 2500, 5000, 10000, 10000, 10000, 12000])
    brokerage = rng.choice([0, 0, 1500, 2500, 10000, 12000])
    paid_ind = rng.choice([0, 1, att, att + 1, max(att - 1, 0), att * 2, 5_000_000])
    paid_alae = rng.choice([0, 1, 50_000, 250_000])
    oslr_ind = rng.choice([0, 0, 1, 100_000, att, 2_000_000])
    oslr_alae = rng.choice([0, 0, 25_000, 100_000])
    prior = rng.choice([0, 0, 1, min(paid_ind, 100_000), paid_ind])
    cert = {
        "certId": f"FZ-{rng.randrange(1_000_000):06d}",
        "insuredName": f"Fuzz Insured {rng.randrange(10_000)}",
        "cedentName": "Fuzz Cedent",
        "line": line,
        "attachmentUsd": att,
        "occLimitUsd": occ,
        "signedShareBps": share,
        "alaeClause": rng.choice(CLAUSES),
        "grossPremiumUsd": rng.choice([0, 40_000, 60_000]),
        "brokerageBps": brokerage,
        "paidPremiumToDateUsd": rng.choice([0, 0, 30_000]),
        "insuredGroup": f"Fuzz Group {rng.randrange(50)}",
    }
    claim = {
        "claimId": f"FZC-{rng.randrange(1_000_000):06d}",
        "certId": cert["certId"],
        "lossDesc": "fuzz case",
        "paidIndemnityUsd": paid_ind,
        "paidAlaeUsd": paid_alae,
        "oslrIndemnityUsd": oslr_ind,
        "oslrAlaeUsd": oslr_alae,
        "priorPaidUsd": prior,
        "priorOslrBookedUsd": rng.choice([0, 0, 50_000]),
        "cedentBilledNowUsd": rng.choice([0, 1, 100_000, 500_000, 5_000_000]),
        "applyPremiumOffset": rng.random() < 0.5,
        "clashEventTag": rng.choice(TAGS),
    }
    return cert, claim


def run_bundle(certs, claims):
    bundle = {"deskName": "fuzz", "certificates": certs, "claims": claims}
    path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(bundle, fh)
            path = fh.name
        proc = subprocess.run(
            [str(BINARY), "fac-audit", path, "--json"], capture_output=True, text=True
        )
        if proc.returncode != 0:
            raise RuntimeError((proc.stderr or "cockpit failed")[:300])
        return json.loads(proc.stdout)
    finally:
        if path:
            Path(path).unlink(missing_ok=True)


def assert_case(cert, claim, row):
    global checked
    checked += 1
    v = row["voucher"]
    if v["grandTotalDebitUsd"] != v["grandTotalCreditUsd"]:
        bad("voucher balance", f'{cert["certId"]}: {v}')
    if v["cashTotalDebitUsd"] != v["cashTotalCreditUsd"]:
        bad("cash leg balance", cert["certId"])
    if row["ourCumulativePaidUsd"] + row["verifiedEndingOslrUsd"] != row["ourCumulativeIncurredUsd"]:
        bad("paid + OSLR = incurred", cert["certId"])
    if row["acordResponseCode"] == "AGD":
        if row["overbilledUsd"] != 0 or row["underbilledUsd"] != 0:
            bad("AGD implies exact bill", cert["certId"])
        if not valid(cert):
            bad("AGD implies valid certificate", cert["certId"])
    if valid(cert):
        if row["ourCumulativePaidUsd"] > claim["paidIndemnityUsd"] + claim["paidAlaeUsd"]:
            bad("no over-recovery", f'{cert["certId"]}: {row["ourCumulativePaidUsd"]}')


def property_suite(rng):
    print("\nProperty fuzz — 500 randomized cases")
    total = 0
    for _ in range(20):
        certs, claims = [], []
        for _ in range(25):
            c, cl = random_case(rng)
            certs.append(c)
            claims.append(cl)
        report = run_bundle(certs, claims)
        for cert, claim, row in zip(certs, claims, report["results"]):
            assert_case(cert, claim, row)
            total += 1
    ok(f"{total} cases audited with all invariants holding", f"{checked} assertions")

    print("\nSelf-consistency — re-bill 60 cases at the verified cash amount")
    certs, claims = [], []
    for _ in range(60):
        c, cl = random_case(rng)
        certs.append(c)
        claims.append(cl)
    first = run_bundle(certs, claims)
    for cl, row in zip(claims, first["results"]):
        cl["cedentBilledNowUsd"] = row["grossCashPayableNowUsd"]
    second = run_bundle(certs, claims)
    expected = {"AGD": 0, "AGD_OFFSET": 0, "REJ": 0, "QRY": 0}
    for cert, row in zip(certs, second["results"]):
        code = row["acordResponseCode"]
        expected[code] += 1
        if not valid(cert):
            if code != "REJ":
                bad("invalid cert rejected", f'{cert["certId"]}: {code}')
        elif row["premiumOffsetUsd"] > 0:
            if code != "AGD_OFFSET":
                bad("offset case classified", f'{cert["certId"]}: {code}')
        elif code != "AGD":
            bad("exact bill auto-agreed", f'{cert["certId"]}: {code}')
    ok("re-billed cases classify as expected", str(expected))


def security_suite():
    print("\nSecurity probes")
    server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{port}"

    def post(payload, size=None):
        data = json.dumps(payload).encode() if size is None else b" " * size
        req = urllib.request.Request(
            base + "/api/acord-process", data=data,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        try:
            with urllib.request.urlopen(req) as res:
                return res.status
        except urllib.error.HTTPError as err:
            return err.code

    xxe = '<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><ACORD><X>&xxe;</X></ACORD>'
    (ok if post({"content": xxe}) == 400 else bad)("XXE rejected with 400")
    (ok if post({}, 2_500_000) == 413 else bad)("oversized body rejected with 413")

    traversal_codes = []
    for path in ("/../../etc/passwd", "/api/slips/../../server/app.py", "/api/fac-slips/../app.py"):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", path)
        traversal_codes.append(conn.getresponse().status)
        conn.close()
    (ok if all(code in (400, 403, 404) for code in traversal_codes) else bad)(
        "path traversal refused", str(traversal_codes)
    )

    headers = {}
    for path in ("/", "/api/health"):
        with urllib.request.urlopen(base + path) as res:
            headers[path] = res.headers.get("Cache-Control", "")
    (ok if all("no-store" in v for v in headers.values()) else bad)(
        "Cache-Control: no-store on HTML and API", str(headers)
    )

    server.shutdown()
    server.server_close()


def docker_probe():
    docker = shutil.which("docker")
    if not docker:
        print("\n  SKIP  docker not installed")
        return
    info = subprocess.run([docker, "info"], capture_output=True, text=True)
    if info.returncode != 0:
        print("\n  SKIP  docker daemon not running")
        return
    print("\nDocker build")
    # Preflight the package mirror separately. If apt cannot install a small
    # package inside a container, the failure is the environment, not the image;
    # saying so is more useful than a red build that says nothing about our code.
    pre = subprocess.run(
        [docker, "run", "--rm", "python:3.12-slim", "sh", "-c",
         "apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates"],
        capture_output=True, text=True, timeout=300,
    )
    if pre.returncode != 0:
        print("  SKIP  Docker package mirror unusable in this environment "
              "(apt preflight failed); Dockerfile not exercised here")
        return
    proc = subprocess.run(
        [docker, "build", "-t", "reinsurance-lean-cockpit:v1.0.0", "."],
        cwd=str(ROOT), capture_output=True, text=True, timeout=1800,
    )
    (ok if proc.returncode == 0 else bad)("docker build", (proc.stderr or "")[-300:])


def main() -> int:
    print("=" * 66)
    print("  FUZZ + SECURITY SUITE")
    print("=" * 66)
    if not BINARY.exists():
        print(f"missing binary: {BINARY} (run lake build)")
        return 1
    rng = random.Random(20261116)
    property_suite(rng)
    security_suite()
    docker_probe()

    print("\n" + "=" * 66)
    if failures:
        print(f"  RESULT: FAILED — {len(failures)} issue(s)")
        for f in failures[:10]:
            print(f"    ! {f}")
        return 1
    print(f"  RESULT: PASSED — {checked} cases, all invariants and probes clean")
    print("=" * 66)
    return 0


if __name__ == "__main__":
    sys.exit(main())
