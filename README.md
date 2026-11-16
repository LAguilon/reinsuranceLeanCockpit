# reinsuranceLeanCockpit — v1.1.0

[![CI](https://github.com/LAguilon/reinsuranceLeanCockpit/actions/workflows/ci.yml/badge.svg)](https://github.com/LAguilon/reinsuranceLeanCockpit/actions/workflows/ci.yml)

Agentic AI plus Lean 4 formal verification for US facultative reinsurance
accounting. Two audiences, one engine: technical accountants who need the number
to be right, and group executives who need to see the capital it protects.

Every figure in the browser is produced by a compiled Lean 4 binary. Python is
transport; the kernel is the calculator. No Mathlib, no floating point, no
`sorry`.

```bash
lake build && python3 server/app.py     # → http://localhost:8080
```

---

## The numbers

Six Q3 cedent cash calls, audited by the kernel:

| | Amount |
|---|---|
| Cedent billed | **$3,610,000** |
| Cash verified payable | **$2,630,000** |
| **Leakage prevented** | **$980,000** across four disputes |
| Unpaid net premium offset | **$51,000** |
| Net wire authorised | **$2,579,000** |
| Verified ending OSLR / IFRS 17 LIC | **$280,000** |
| Ruschlikon STP auto-settled | **2 of 6 (33%)** |

A quarterly **24-claim carrier bordereau** runs through the same engine in a
single batch and prevents **over $1.4 million** of leakage, producing a
ready-to-post SAP FS-RI / IFRS 17 journal CSV.

The four cash-call disputes are the four failure modes that actually happen:

* **Defence cannot pierce an attachment.** $450,000 of indemnity against a
  $500,000 attachment means no ceded indemnity and therefore no pro-rata ALAE —
  yet the cedent billed $130,000.
* **Defence inside limits caps the layer.** A $22M D&O loss is capped at the
  $10M limit; 20% of that is $2,000,000, not 20% of the pre-cap total.
* **Prior paid is cumulative.** Billing the full $350,000 layer position without
  deducting $200,000 already settled.
* **A case reserve is not cash.** Paid indemnity of $400,000 is below the
  attachment, so the $280,000 incurred position is a reserve to book, not a
  wire. The cedent asked for $250,000 in cash.

---

## Architecture

```
PDF / ACORD XML / broker email / CSV bordereau
        │
        ├─ intake parser (stdlib only, deterministic)
        │
        ▼
Lean 4 kernel  ──  gatekeeper (isValid) → audit (paid vs incurred, ALAE, offset)
        │
        ├─ Ruschlikon classifier (AGD / AGD_OFFSET / QRY / REJ)
        ├─ four-eyes subjectivity gate (claims examiner + technical accountant)
        ├─ two-leg voucher (cash settlement + OSLR movement)
        ▼
server/app.py  ──  JSON API, hash-chained audit ledger (SQLite)
        │
        ▼
vanilla HTML/CSS/JS cockpit (no framework, no build step)
```

There is no second implementation of the arithmetic to drift out of sync, and
the browser never computes a number.

---

## The desk

Six cash calls, four lines (Auto Liability, General Liability, Workers' Comp,
D&O), three ALAE clauses. Each row shows the cedent's bill, the verified cash,
the ending case reserve, a double-entry voucher and a broker memo.

**Paid versus incurred.** The layer responds to incurred; only paid can be
wired. The cockpit computes `verifiedEndingOslr = max(incurred, paid) − paid`,
books it, and refuses to wire it. A cedent billing cash while paid indemnity is
still below the attachment gets `DISPUTE_PREMATURE_OSLR_CASHCALL`.

**Premium offset.** Unpaid net premium (gross less brokerage, less cash
received) is netted against an approved wire when elected.

**Two-leg voucher.** Leg A settles cash (paid claims expense against premium
offset and wire). Leg B moves the reserve (OSLR expense/liability, or release).
Both are proved to balance for every claim.

---

## Formal guarantees

13 named specifications in a tactic-free `TrustBoundary.lean`, discharged at
their exact declared types in `TrustProofs.lean`, and 96+ kernel-checked
theorems overall. The headline invariants:

| Theorem | Statement |
|---|---|
| `fac_no_overrecovery` | across all three ALAE clauses, payout ≤ ground-up indemnity + ALAE |
| `facIncluded_capped_by_share` | defence inside limits capped by limit × signed share |
| `paid_plus_endingOslr_eq_incurred` | paid + ending reserve = incurred |
| `fullFacVoucher_balanced` | total debits = total credits, every claim |
| `stpAutoAgreed_implies_valid_and_zero_overbill` | STP auto-agreement implies a valid, exact bill |
| `selfApproval_rejected` | the same person cannot fill both four-eyes roles |
| `unattestedSubjectivity_holds_wire` | unattested subjectivity always holds the wire |
| `disputedClaim_never_authorized` | a queried or rejected claim is never authorized |
| `rollup_wire_plus_offset_le_verified` | batch: offset + net wire = verified cash |
| `groupView_protectedRatio_ge` | preventing leakage can only raise the group ratio |

`python3 scripts/paranoid_audit.py` answers the four trust questions: the
statements are readable and tactic-free, the build produces the artefact, no
theorem escapes through `sorry`/`axiom`/`native_decide`, and every axiom set is
within `{propext, Classical.choice, Quot.sound}`.

---

## Ruschlikon / ACORD GRLC

`Acord.lean` classifies every audit as `AGD`, `AGD_OFFSET`, `QRY` or `REJ`.
`server/acord_adapter.py` parses authentic `<Jv-Ins-Reinsurance Version="2016-1">`
messages (`ClaimMovement` → `ReferredContract` → `Claim` → `ClaimEntry` →
`ClaimMovementAmtItem`) and still accepts the flat tag layout, then emits a
`ClaimMovementResponse` with `<AcknowledgementStatus>` and both ledger legs.
XML with a `DOCTYPE` or `ENTITY` declaration is rejected before parsing.

---

## Universal intake

Drop a PDF, an ACORD message, or paste a broker email. Three panels come back:
the extracted text, the exact compilable Lean 4 definitions for that certificate
and claim, and the plain-English back-translation of what was verified. Amber
warnings list clauses the model cannot represent — hammer, punitive damages,
consent to settle, PFAS, subrogation and others. An optional `OPENAI_API_KEY`
pass may annotate extraction; Lean still performs every validation.

---

## Four eyes, and a tamper-evident trail

Subjective clauses — declaratory judgment fees, hammer / consent to settle,
punitive damages, policy-period certification — cannot be auto-wired. They
require a claims examiner **and** a technical accountant, with different names.
The kernel proves self-approval is rejected and that an unattested requirement
always holds the wire.

Every sign-off and audit event is appended to a SHA-256 hash chain in SQLite
(`data/cockpit_audit.db`). `GET /api/audit-ledger` re-verifies every link from
the genesis hash and reports `chainIntact`.

---

## Quarterly bordereau

Upload a carrier loss bordereau CSV (24 claims in the sample) and the whole book
is audited in one Lean call: clean STP rows, premium-offset rows, disputed rows
and four-eyes holds. The batch exports a balanced SAP FS-RI / IFRS 17 posting
CSV with debit/credit lines for every authorized wire and OSLR movement.

---

## Verification

```bash
rm -rf .lake data/cockpit_audit.db && lake build
python3 scripts/paranoid_audit.py
python3 scripts/verify_ui_integrity.py
python3 scripts/test_e2e.py
python3 scripts/fuzz_stress_suite.py
```

* `paranoid_audit.py` — Buzzard Q1–Q4: auditable statements, artefact, axiom
  hygiene, optional independent kernel replay.
* `verify_ui_integrity.py` — JS parses, every element id exists, every button is
  styled, every API route the UI calls is implemented, versions agree.
* `test_e2e.py` — the full HTTP surface, including four-eyes segregation and the
  24-claim bordereau.
* `fuzz_stress_suite.py` — 500 randomized certificates plus security probes
  (XXE, oversized bodies, path traversal, cache headers).

---

## Deployment

`Dockerfile` is multi-stage: the builder installs elan, builds, generates the
sample PDFs and runs the paranoid audit, so **a failing proof fails the image**.
`render.yaml` is a Render blueprint; `docs/DEPLOYMENT.md` covers Fly.io, Railway
and a VPS.

---

## Repository layout

```
ReinsuranceLeanCockpit/
  Core.lean  Solvency.lean  AlpineShowcase.lean
  Contracts.lean  Diagnostics.lean  Validation.lean
  Simulation.lean  Monotonicity.lean  TrustBoundary.lean  TrustProofs.lean
  Facultative.lean  Acord.lean  Subjectivity.lean  GroupBridge.lean
  Ingestion.lean
Main.lean
server/   app.py  slip_parser.py  acord_adapter.py  fac_intake.py
          bordereau_processor.py  audit_ledger.py
web/      index.html  styles.css  app.js
scripts/  generate_sample_pdfs.py  paranoid_audit.py  test_e2e.py
          verify_ui_integrity.py  fuzz_stress_suite.py  AxiomAudit.lean
examples/ us_facultative_desk.json  slips/  fac_slips/  fac_intake/
          acord/  bordereaux/
docs/     USER_GUIDE.md  DEPLOYMENT.md
```

## License

Apache-2.0.
