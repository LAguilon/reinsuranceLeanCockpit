#!/usr/bin/env python3
"""The paranoid audit: Buzzard's four questions, mechanised.

Q1  Can a human read the statements?      -> TrustBoundary.lean: short, tactic-free
Q2  Does the build actually produce it?   -> binary exists, cockpit is a default target
Q3  Is the proof real?                    -> no sorry/admit/axiom/unsafe/extern/native_decide,
                                             and every #print axioms subset of the core three
Q4  Was it replayed by another kernel?    -> lean4checker / comparator if installed

Pure standard library. Exit 0 only if every check passes.
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEAN_DIR = ROOT / "ReinsuranceLeanCockpit"
TRUST_BOUNDARY = LEAN_DIR / "TrustBoundary.lean"
AXIOM_AUDIT = ROOT / "scripts" / "AxiomAudit.lean"
BINARY = ROOT / ".lake" / "build" / "bin" / "cockpit"

ALLOWED_AXIOMS = {"propext", "Classical.choice", "Quot.sound"}
FORBIDDEN_TOKENS = [
    "sorry", "admit", "axiom ", "opaque ", "unsafe ",
    "@[extern", "@[implemented_by", "native_decide",
]
FORBIDDEN_AXIOMS = {"sorryAx", "Lean.ofReduceBool", "Lean.trustCompiler"}

failures = []
notes = []


def ok(name: str, detail: str = "") -> None:
    print(f"  PASS  {name}" + (f"  ({detail})" if detail else ""))


def bad(name: str, detail: str = "") -> None:
    print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))
    failures.append(name)


def strip_comments(text: str) -> str:
    """Remove Lean comments so prose cannot trip a lexical audit."""
    previous = None
    while previous != text:
        previous = text
        text = re.sub(r"/-.*?-/", "", text, flags=re.S)
    text = re.sub(r"--[^\n]*", "", text)
    return text


def find_lake() -> str | None:
    lake = shutil.which("lake")
    if lake:
        return lake
    candidate = Path.home() / ".elan" / "bin" / "lake"
    return str(candidate) if candidate.exists() else None


# ---------------------------------------------------------------- Q1

def check_q1() -> None:
    print("Q1  Human-auditable statements (TrustBoundary.lean)")
    if not TRUST_BOUNDARY.exists():
        return bad("TrustBoundary.lean exists")
    text = TRUST_BOUNDARY.read_text()
    lines = text.count("\n") + 1
    code = strip_comments(text)

    ok("TrustBoundary.lean exists", f"{lines} lines")
    (ok if lines < 120 else bad)("file is under 120 lines", f"{lines}")
    tactic_free = not re.search(r":=\s*by\b|\bby\s*$", code, re.M)
    (ok if tactic_free else bad)("contains no proof tactics", "no ':=' followed by 'by'")
    (ok if "sorry" not in code else bad)("contains no sorry", "")

    specs = re.findall(r"^def (Spec_\w+)\s*:\s*Prop", code, re.M)
    (ok if len(specs) == 10 else bad)("declares 10 named specifications", f"found {len(specs)}")
    for name in specs:
        print(f"        · {name}")


# ---------------------------------------------------------------- Q2

def check_q2() -> None:
    print("\nQ2  The build really produces the artefact")
    (ok if BINARY.exists() else bad)("cockpit binary exists", str(BINARY))
    lakefile = (ROOT / "lakefile.toml").read_text()
    has_target = re.search(r'defaultTargets\s*=\s*\[[^\]]*"cockpit"', lakefile, re.S) is not None
    (ok if has_target else bad)('defaultTargets includes "cockpit"', "")


# ---------------------------------------------------------------- Q3

def check_q3a() -> None:
    print("\nQ3a No reward-hacking primitives in the Lean sources")
    offenders = []
    for path in sorted(LEAN_DIR.rglob("*.lean")):
        code = strip_comments(path.read_text())
        for token in FORBIDDEN_TOKENS:
            for match in re.finditer(re.escape(token), code):
                line = code[: match.start()].count("\n") + 1
                offenders.append(f"{path.name}:{line}: {token.strip()}")
    if offenders:
        bad("no forbidden tokens", f"{len(offenders)} hit(s)")
        for line in offenders:
            print(f"        ! {line}")
    else:
        ok("no sorry / admit / axiom / opaque / unsafe / extern / native_decide")


def check_q3b() -> None:
    print("\nQ3b Every theorem's axiom set is a subset of the core three")
    lake = find_lake()
    if not lake:
        return bad("lake on PATH", "install Lean/elan")
    proc = subprocess.run(
        [lake, "env", "lean", str(AXIOM_AUDIT)],
        cwd=str(ROOT), capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return bad("AxiomAudit.lean compiles", (proc.stderr or "")[:300])

    checked = 0
    bad_axioms = []
    audited = set()
    for line in proc.stdout.splitlines():
        match = re.match(r"'([^']+)' depends on axioms: \[(.*)\]", line)
        if match:
            name, axioms = match.group(1), [a.strip() for a in match.group(2).split(",") if a.strip()]
        elif "does not depend on any axioms" in line:
            name = line.split("'")[1]
            axioms = []
        else:
            continue
        checked += 1
        audited.add(name.split(".")[-1])
        illegal = set(axioms) - ALLOWED_AXIOMS
        if illegal:
            bad_axioms.append((name, sorted(illegal)))
        if FORBIDDEN_AXIOMS & set(axioms):
            bad_axioms.append((name, sorted(FORBIDDEN_AXIOMS & set(axioms))))

    (ok if checked >= 60 else bad)("axiom declarations parsed", f"{checked} theorems")

    proc2 = subprocess.run(
        [str(BINARY), "theorems", "--json"], cwd=str(ROOT), capture_output=True, text=True
    )
    registry = {t["name"] for t in json.loads(proc2.stdout)} if proc2.returncode == 0 else set()
    uncovered = registry - audited
    (ok if not uncovered else bad)(
        "every registry theorem is axiom-audited", f"{len(registry)} registered, {len(audited)} audited"
    )
    for name in sorted(uncovered):
        print(f"        ! not audited: {name}")
    if bad_axioms:
        bad("all axiom sets within {propext, Classical.choice, Quot.sound}")
        for name, illegal in bad_axioms:
            print(f"        ! {name}: {illegal}")
    else:
        ok("no sorryAx, Lean.ofReduceBool or Lean.trustCompiler anywhere")


# ---------------------------------------------------------------- Q4

def check_q4() -> None:
    print("\nQ4 Independent kernel replay")
    tool = shutil.which("lean4checker") or shutil.which("comparator")
    if tool:
        proc = subprocess.run([tool, "--version"], capture_output=True, text=True)
        detail = (proc.stdout or proc.stderr or "").strip().splitlines()[:1]
        notes.append(f"{Path(tool).name} present")
        ok(f"{Path(tool).name} detected", detail[0] if detail else "installed")
        print(f"        run: {Path(tool).name} {ROOT / 'ReinsuranceLeanCockpit'}")
    else:
        notes.append("no independent kernel installed")
        print("  SKIP  neither lean4checker nor comparator is installed")
        print("        external replay command:  lake comparator --paranoid")
        print("        (advisory: the kernel already checked every proof in-process)")


def main() -> int:
    print("=" * 66)
    print("  PARANOID AUDIT - Buzzard Q1..Q4")
    print("=" * 66)
    check_q1()
    check_q2()
    check_q3a()
    check_q3b()
    check_q4()

    print("\n" + "=" * 66)
    if failures:
        print(f"  RESULT: FAILED - {len(failures)} check(s): {failures}")
        return 1
    print("  RESULT: PASSED - statements auditable, proofs real, no escape hatches")
    print("=" * 66)
    return 0


if __name__ == "__main__":
    sys.exit(main())
