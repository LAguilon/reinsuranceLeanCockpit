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

    stale = [v for v in ("v0.4", "v0.5", "v1.0.0") if v in html or v in main_lean]
    (ok if not stale else bad)("no stale v0.4/v0.5/v1.0.0 banners", str(stale))
    (ok if "v1.1.0" in html else bad)("index.html shows v1.1.0")

    js_routes = set(re.findall(r'"(/api/[A-Za-z0-9\-]+)"', js))
    js_routes |= set(re.findall(r'`(/api/[A-Za-z0-9\-]+)/', js))
    unimplemented = sorted(r for r in js_routes if r not in server)
    if unimplemented:
        bad(f"all {len(js_routes)} JS API routes are implemented", f"missing: {unimplemented}")
    else:
        ok(f"all {len(js_routes)} JS API routes are implemented")

    css = (ROOT / "web" / "styles.css").read_text()

    buttons = re.findall(r"<button[^>]*>", html, re.IGNORECASE)
    classless = [b for b in buttons if not re.search(r'class="', b)]
    (ok if not classless else bad)(
        f"every <button> carries a class ({len(buttons)} buttons)", str(classless[:3])
    )

    unstyled = []
    for button in buttons:
        match = re.search(r'class="([^"]+)"', button)
        if not match:
            continue
        for token in match.group(1).split():
            if not re.search(r"\." + re.escape(token) + r"\b", css):
                unstyled.append(token)
    unstyled = sorted(set(unstyled))
    (ok if not unstyled else bad)("every button class is styled in styles.css", str(unstyled))

    html_classes = set()
    for match in re.findall(r'class="([^"]+)"', html):
        html_classes.update(match.split())
    missing_classes = sorted(
        c for c in html_classes if not re.search(r"\." + re.escape(c) + r"\b", css)
    )
    (ok if not missing_classes else bad)(
        f"all {len(html_classes)} HTML classes have CSS rules", str(missing_classes)
    )

    hidden_ids = set(re.findall(r'\$\("#([A-Za-z0-9_-]+)"\)\.hidden\s*=', js))
    hidden_visible = []
    for eid in sorted(hidden_ids):
        tag = re.search(r'<[^>]*id="' + re.escape(eid) + r'"[^>]*>', html)
        if not tag:
            continue
        cls = re.search(r'class="([^"]+)"', tag.group(0))
        if not cls:
            continue
        for token in cls.group(1).split():
            has_display = re.search(r"\." + re.escape(token) + r"\s*\{[^}]*display\s*:", css)
            has_hidden_rule = re.search(r"\." + re.escape(token) + r"\[hidden\]", css)
            if has_display and not has_hidden_rule:
                hidden_visible.append(f"{eid}.{token}")
    (ok if not hidden_visible else bad)(
        "elements hidden from JS are not kept visible by CSS", str(hidden_visible)
    )

    versions = {
        "web/index.html": html,
        "Main.lean": main_lean,
        "server/app.py": server,
        "README.md": (ROOT / "README.md").read_text(),
    }
    version_bad = [name for name, text in versions.items() if "v1.1.0" not in text and "1.1.0" not in text]
    (ok if not version_bad else bad)("v1.1.0 present in HTML, CLI, server and README", str(version_bad))
    stale_anywhere = [
        name for name, text in versions.items()
        if any(v in text for v in ("v0.4", "v0.5"))
    ]
    (ok if not stale_anywhere else bad)("no stale v0.4/v0.5 in versioned files", str(stale_anywhere))

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
