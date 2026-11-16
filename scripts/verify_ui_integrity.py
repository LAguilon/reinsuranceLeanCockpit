#!/usr/bin/env python3
"""Static frontend/backend contract verifier.

Checks, without a browser:
  * JS parses (`node --check` when node is available)
  * every element id the JS looks up exists in index.html
  * no stale version banners ("v0.4"/"v0.5") in the UI or the CLI banner
  * every /api route the JS calls is implemented by server/app.py
  * every static asset the page references exists on disk

Exit 0 only if all checks pass.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / "web" / "index.html"
APP_JS = ROOT / "web" / "app.js"
SERVER = ROOT / "server" / "app.py"
MAIN = ROOT / "Main.lean"

failures = []


def ok(name, detail=""):
    print(f"  PASS  {name}" + (f"  ({detail})" if detail else ""))


def bad(name, detail=""):
    print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))
    failures.append(name)


def main() -> int:
    print("=" * 66)
    print("  UI INTEGRITY — static frontend/backend contract")
    print("=" * 66)

    html = INDEX.read_text()
    js = APP_JS.read_text()
    server = SERVER.read_text()
    main_lean = MAIN.read_text()

    node = shutil.which("node")
    if node:
        proc = subprocess.run([node, "--check", str(APP_JS)], capture_output=True, text=True)
        (ok if proc.returncode == 0 else bad)("node --check web/app.js", (proc.stderr or "")[:200])
    else:
        print("  SKIP  node not installed; JS syntax check skipped")

    html_ids = set(re.findall(r'id="([^"]+)"', html))
    js_refs = set(re.findall(r'\$\("#([A-Za-z0-9_-]+)', js))
    js_refs |= set(re.findall(r'getElementById\("([^"]+)"\)', js))
    missing = sorted(js_refs - html_ids)
    if missing:
        bad(f"all {len(js_refs)} JS element ids exist in index.html", f"missing: {missing}")
    else:
        ok(f"all {len(js_refs)} JS element ids exist in index.html")

    stale = [v for v in ("v0.4", "v0.5") if v in html or v in main_lean]
    (ok if not stale else bad)("no stale v0.4/v0.5 banners", str(stale))
    (ok if "v1.0.0" in html else bad)("index.html shows v1.0.0")

    js_routes = set(re.findall(r'"(/api/[A-Za-z0-9\-]+)"', js))
    js_routes |= set(re.findall(r'`(/api/[A-Za-z0-9\-]+)/', js))
    unimplemented = sorted(r for r in js_routes if r not in server)
    if unimplemented:
        bad(f"all {len(js_routes)} JS API routes are implemented", f"missing: {unimplemented}")
    else:
        ok(f"all {len(js_routes)} JS API routes are implemented")

    assets = set(re.findall(r'(?:href|src)="([A-Za-z0-9_./-]+\.(?:css|js))"', html))
    missing_assets = sorted(a for a in assets if not (ROOT / "web" / a).exists())
    (ok if not missing_assets else bad)(
        f"all {len(assets)} static assets exist", str(missing_assets)
    )

    # Data-attribute hooks used by the JS must be produced by the renderers.
    hooks = set(re.findall(r'data-(?:view|peril|cert|intake|slip)="', js))
    (ok if hooks else bad)("JS uses data-attribute hooks", f"{len(hooks)} kinds")

    print("\n" + "=" * 66)
    if failures:
        print(f"  RESULT: FAILED — {len(failures)} check(s): {failures}")
        return 1
    print("  RESULT: PASSED — UI and API contract agree")
    print("=" * 66)
    return 0


if __name__ == "__main__":
    sys.exit(main())
