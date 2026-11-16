# ReinsuranceLean Cockpit — User & Architecture Guide

_For accountants, actuaries, and the managers who have to sign off on both._

This guide explains what the cockpit does, why it is built the way it is, and how
to demonstrate it in three minutes. No Lean, no mathematics, and no programming
knowledge is assumed.

---

## 1. Why this exists: AI + formal verification for reinsurance accounting

### The problem with asking a chatbot to check a cash call

A large language model is very good at reading a slip and very bad at
guaranteeing a number. Ask one to add up a facultative claim and it will produce
a fluent, confident answer that may be wrong by an arbitrary amount. Ask it which
ALAE clause applies and it may pick the wrong one, because both readings are
grammatical. In accounting, a fluent wrong answer is worse than no answer: it
gets pasted into a ledger.

There is a second, subtler failure. Even when the model's arithmetic is right
today, nothing forces it to be right tomorrow. The model is not a specification;
it is a sample. You cannot audit a sample.

### What "agentic" actually means here

Agentic does **not** mean "a chatbot with a personality". It means a workflow in
which a sequence of steps each consume the previous step's structured output, and
the hand-offs are inspectable. In this cockpit there are four:

1. **Intake** — read the certificate and the cedent's cash call into structured
   fields (limit, attachment, signed share, ALAE clause, ground-up loss, prior
   paid, amount billed).
2. **Verification** — recompute what the certificate actually owes, in exact
   integer arithmetic, and compare it to what was billed.
3. **Ledger** — post the verified amount as a double-entry voucher: indemnity
   and ALAE debits against a cedent-payable credit.
4. **Settlement** — draft the broker memo: approve, dispute with an exact
   adjustment, or flag for review.

Step 2 is not done by a language model. It is done by a compiled Lean 4 program,
and the program's central claims are theorems checked by Lean's kernel. That is
the difference between "the AI thinks the number is $2,000,000" and "the number
is $2,000,000, and here is a proof that no valid reading of the clause can
produce a larger one".

### What Lean 4 buys you, concretely

* **No floating point.** Money is an exact integer number of cents. `0.1 + 0.2`
  cannot equal `0.30000000000000004` because there are no decimals.
* **No silent overflow or negative amounts.** All arithmetic is on natural
  numbers; subtraction saturates at zero rather than wrapping.
* **Debits equal credits, always.** `facJournal_balanced` is a theorem, not a
  reconciliation report that someone remembers to run.
* **Clauses cannot pay more than the loss.** `fac_no_overrecovery` covers all
  three ALAE clauses at once.
* **The gate and the proofs agree.** `validateContract_isEmpty_iff` states that
  the ingestion check accepts exactly the contracts the theorems apply to.

---

## 2. US facultative excess-of-loss: the rules this desk models

A facultative certificate is a single-risk layer. The cedent keeps losses below
the **attachment**; the reinsurer pays the next slice up to the **occurrence
limit**; the **signed share** is the percentage of that slice the reinsurer
actually took.

### The four lines

| Line | Typical structure | What makes it interesting |
|---|---|---|
| Auto Liability (AL) | $500,000 xs $500,000, 100% | Defence costs usually sit **outside** the limit |
| General Liability (GL) | $500,000 xs $500,000, 100% | Same, but with long-tail allocation questions |
| Workers' Compensation (WCA) | $500,000 xs $500,000, 100% | Indemnity only; medical may be separate |
| Directors & Officers (D&O) | 20% of $10,000,000 xs $10,000,000 | Defence is almost always **inside** the limit |

### ALAE: three clauses, three different answers

ALAE means "allocated loss adjustment expense" — defence lawyers, adjusters,
experts. Where it sits changes the payment.

**ALAE Pro-Rata in Addition (AL and GL in this desk).** The limit applies to
indemnity only. Defence is paid on top, in proportion to the ceded indemnity:

```
ceded indemnity = min(ground-up indemnity − attachment, limit) × share
ceded ALAE      = ground-up ALAE × (ceded indemnity / ground-up indemnity)
```

The critical consequence: **if ground-up indemnity is below the attachment,
ceded indemnity is zero, so ceded ALAE is zero.** Defence cannot be used to
pierce an attachment. This is the single most common overbilling error in the
sample book.

**ALAE Included Within Limits (D&O in this desk).** Indemnity and defence share
one limit. The combined loss is applied to the layer, then split:

```
combined        = indemnity + ALAE
layer total     = min(combined − attachment, limit)
layer indemnity = min(indemnity − attachment, limit)
layer ALAE      = layer total − layer indemnity
```

With a 20% signed share on a $10,000,000 limit, maximum liability is
$2,000,000 — no matter how large the defence spend becomes.

**ALAE Excluded (Workers' Comp in this desk).** Defence is the cedent's problem.
The layer responds to indemnity only.

### Prior paid: cumulative versus incremental

A Q3 cash call states the **cumulative** position of the layer. The amount due
now is:

```
incremental due = cumulative payable − prior paid
```

Billing the cumulative figure again — forgetting to deduct Q1 and Q2 — is the
second classic error. The cockpit compares the billed amount to the incremental
figure, not to the cumulative one.

### The four sample cash calls, worked by hand

**Case 1 — Auto Liability, $500k xs $500k, 100%, pro-rata in addition.**

Ground-up indemnity $450,000 is *below* the $500,000 attachment, so the layer
owes nothing and pro-rata ALAE is zero. Verified due **$0**. Cedent billed
$130,000. **Dispute: overbilled $130,000.**

**Case 2 — D&O, 20% of $10M xs $10M, defence inside limits.**

Combined $22,000,000 → layer total capped at $10,000,000. Indemnity slice
$6,000,000, ALAE slice $4,000,000. At 20%: $1,200,000 + $800,000 = **$2,000,000**.
Cedent billed $2,400,000 — they applied 20% to the layer total *before* the
inside-limits cap. **Dispute: overbilled $400,000.**

**Case 3 — Workers' Comp, $500k xs $500k, indemnity only.**

Ground-up $850,000 → layer pays $350,000 cumulative. Prior paid $200,000, so
incremental due **$150,000**. Cedent billed $350,000 — the whole cumulative
figure. **Dispute: overbilled $200,000.**

**Case 4 — General Liability, $500k xs $500k, pro-rata in addition.**

Indemnity slice $250,000; ALAE $90,000 × 250,000 / 750,000 = $30,000. Verified
due **$280,000**. Cedent billed $280,000. **Approved exactly.**

Totals: billed $3,160,000, verified $2,430,000, **overbilling caught
$730,000 across three disputes.**

---

## 3. The treaty cockpit, and "lost in translation"

The second workspace tab holds the treaty-level tools.

**Solvency II gauge.** The ratio of own funds to a deterministic stress
requirement, after the season's losses have actually reduced capital. The
post-season figure is the honest one: a catastrophe consumes capital, it does not
merely enlarge a requirement.

**Tower visualiser.** Perils on tabs; inward layers on the left, the outward
retrocession tower on the right, scaled by attachment and limit. Red hatched
blocks are **unhedged gaps** — ranges of loss where the cedent has bought inward
business but no outward cover. Amber badges mark BBB or unrated counterparties.

**Static loophole scanner.** Five structural findings: vertical gaps, overlaps,
currency basis mismatch, aggregate exhaustion, and counterparty credit cliffs.
Findings are a pure function of the file: same portfolio in, same findings out.

**PDF slip validator with back-translation.** Upload a slip and the cockpit shows
three things side by side: the text extracted from the PDF, what Lean *modelled*
(rendered back into English from the same fields the proofs consume), and a list
of clauses present in the paper but absent from the model — `franchise`,
`hours clause`, `72 hours`, `excluding`, `sub-limit`, and so on. That third list
is the "lost in translation" warning: a proof about a narrower contract than the
one you signed is not a proof about your contract.

**Multi-event simulator.** A season of catastrophe events with editable FX rates,
priced through every inward contract and down the outward tower, with aggregate
limits eroding as they are consumed. The solvency curve is monotone by theorem:
a larger loss can never improve the ratio.

---

## 4. Three-minute live demo

```bash
lake build                 # builds the kernel-checked engine (~12s from clean)
python3 server/app.py      # http://localhost:8080
```

Then, click by click:

1. **Open the app.** It lands on *US Facultative Accounting Desk*. The summary
   strip reads **$3,160,000 billed**, **$2,430,000 verified**, **$730,000
   overbilling caught**, **3 of 4 disputed**. Say: "this is the Q3 cash-call run,
   already done."
2. **Click the Auto Liability case** (`$500k xs $500k`, ALAE pro-rata in
   addition). Step 2 turns red: `DISPUTE_OVERBILLED`, $130,000. Read the
   explanation aloud: ground-up indemnity is below the attachment, so there is no
   ceded indemnity and defence cannot pierce the attachment. Say: "the cedent
   billed $130,000 for a layer that owes nothing."
3. **Click the D&O case.** Step 2 explains the inside-limits cap: $10,000,000 ×
   20% = $2,000,000, against a $2,400,000 bill. Step 3 shows the journal:
   debit indemnity $1,200,000, debit ALAE $800,000, credit cedent $2,000,000,
   **balanced**.
4. **Click the Workers' Comp case.** Step 2 explains the prior-paid netting:
   cumulative $350,000 less $200,000 already settled = $150,000 due now.
5. **Open "View Cash-Call PDF"** on any case. The original cedent statement is
   served from disk — nothing was retyped into the model.
6. **Edit a number.** Change the Workers' Comp indemnity to $600,000 and press
   *Run Agentic Cash-Call Audit*. The layer now pays only $100,000, and the
   verdict, journal and memo all update. Say: "the arithmetic is re-proved, not
   re-guessed."
7. **Scroll to the memo.** It is a complete broker letter with the exact
   adjustment and the journal references. Press *Copy memo*.
8. **Switch to the Treaty Cockpit tab.** Point at the red hatched gap in the
   windstorm tower and the FX mismatch chip. Say: "same engine, different
   question: is the structure sound?"
9. **Switch to How It Works.** Leave it on screen for questions.

### The proof, if someone asks

```bash
python3 scripts/paranoid_audit.py
```

Four questions, four answers: the statements are readable and tactic-free, the
build produces the binary, no theorem escapes through `sorry`/`axiom`/
`native_decide`, and every axiom set is within the three standard Lean axioms.
The audit prints PASS or FAIL; there is no "probably".

---

## 5. Trust and verification architecture, without a maths PhD

### The trust boundary

`ReinsuranceLeanCockpit/TrustBoundary.lean` contains **no proofs**. It contains
ten named statements in plain mathematics, each with a docstring, including:

* no contract pays more than the loss;
* a tower neither creates nor destroys money;
* payouts and net retentions are monotone in the loss;
* the post-season solvency ratio falls as the drain rises;
* ingestion admits exactly the contracts the theorems apply to;
* the FX fix holds for every loss and every rate at or below parity;
* at least one valid contract actually pays something (the non-vacuity witness);
* the facultative desk never pays more than ground-up indemnity plus ALAE;
* every facultative journal balances.

A reviewer who reads only that file knows precisely what is claimed. If a
statement is wrong, the proofs are irrelevant — which is exactly why the
statements are separated from the proofs and kept short.

`TrustProofs.lean` discharges each statement at its **exact declared type**. No
restatement, no weakening. If someone edits a specification, the proof stops
compiling.

### The paranoid audit

`scripts/paranoid_audit.py` mechanises Kevin Buzzard's four questions:

| Question | How it is answered |
|---|---|
| Can a human read the statements? | TrustBoundary is under 120 lines, tactic-free, ten `Spec_` declarations |
| Does the build produce the artefact? | the binary exists and `cockpit` is a default target |
| Is the proof real? | no `sorry`, `admit`, `axiom`, `opaque`, `unsafe`, `@[extern]`, `native_decide`; every `#print axioms` subset of the core three; every registry theorem audited |
| Was it replayed elsewhere? | `lean4checker` / `comparator` if installed, otherwise the exact replay command is printed — never claimed |

### What is deliberately not modelled

Honesty about scope is part of the architecture:

* the Solvency II figure is a deterministic stress build-up, not the Standard
  Formula;
* the PDF extractor reads text-layer PDFs, not scans;
* the translation scanner is lexical — it prompts a human to read the wording,
  it does not certify that the wording is modelled;
* facultative allocation across multiple claimants is not modelled; each cash
  call is one loss;
* there is no currency conversion inside the facultative desk — US dollars
  throughout, as the certificates are written.

### Where the numbers come from

Every figure displayed in the browser is returned by the compiled Lean binary.
Python is transport: it writes JSON to a temporary file, runs the binary, and
returns what the kernel produced. There is no second implementation of the
arithmetic to drift out of sync, and the browser never computes a number.

---

_See also: `README.md` for the engineering summary, `TrustBoundary.lean` for the
formal claims, and `scripts/paranoid_audit.py` for the audit._

---

# v1.0.0 — what changed for the desk, the broker and the board

## 1. Paid is not incurred

A cedent's quarterly statement has two kinds of number:

* **Paid** — cash already out of the door (indemnity and defence).
* **OSLR** — outstanding case reserve, the best estimate of what is still owed.
  Under IFRS 17 this is the Liability for Incurred Claims (LIC).

The layer responds to **incurred** (paid plus reserve), but only **paid** can be
wired. The cockpit therefore computes both and books the difference:

```
verifiedEndingOslr = max(incurred, paid) − paid
grossCashPayable   = paid − priorPaid
```

If a cedent bills cash while the *paid* position is still below the attachment,
the verdict is `DISPUTE_PREMATURE_OSLR_CASHCALL`. That is not a rounding
disagreement; it is a request to wire money the contract does not yet owe. The
desk books the reserve instead, and the memo says so.

## 2. Unpaid premium is netted, not ignored

A facultative certificate has a gross premium, a brokerage deduction and a cash
received to date. The unpaid net premium is available to offset an approved
claim:

```
netPremiumDue  = gross − gross × brokerageBps / 10000
unpaidNetPrem  = netPremiumDue − paidPremiumToDate
premiumOffset  = min(grossCashPayable, unpaidNetPrem)   (when elected)
netWire        = grossCashPayable − premiumOffset
```

On the sample book, case 6 has $60,000 gross, 15% brokerage, nothing received:
$51,000 unpaid. The verified claim is $200,000; the wire is $149,000, and both
credits appear in the voucher.

## 3. The voucher has two legs

Leg A settles cash:

| Debit | Credit |
|---|---|
| Paid claims expense | Premium receivable offset |
| | Cash wire payable |

Leg B moves the reserve:

| Debit | Credit |
|---|---|
| OSLR expense (increase) | OSLR liability |
| OSLR liability release (decrease) | OSLR expense release |

The kernel proves both legs balance, and the whole voucher balances, for every
claim (`fullFacVoucher_balanced`). A reserve movement is not a cash movement,
and the ledger shows that.

## 4. Ruschlikon straight-through processing

ACORD GRLC messages carry a response code. The cockpit maps its own verdict:

| Code | Meaning |
|---|---|
| `AGD` | clean match, auto-agreed, no human |
| `AGD_OFFSET` | agreed, wire reduced by unpaid net premium |
| `QRY` | queried back to the broker (overbill, underbill, premature OSLR) |
| `REJ` | certificate invalid — rejected at the gate |

The guarantee is a theorem, not a policy: an overbilled claim can never reach
`AGD`. Drop an ECOT XML or JSON message into the intake box and the cockpit
returns the verified audit plus an outbound `ClaimMovementResponse` XML and EBOT
JSON, both downloadable.

## 5. Clause-to-Lean intake

Paste a broker email such as:

> URGENT CASH CALL — Insured: Apex Trucking | Cedant: Liberty Mutual | Layer:
> 50% part of $500k xs $500k Auto Liability | ALAE pro-rata in addition | Gross
> Prem: $40,000 (15% brokerage, $0 paid) | Paid Indemnity: $620,000 | Paid ALAE:
> $124,000 | Case Reserve Indemnity: $180,000 | Prior Paid: $0 | Please wire
> $150,000 today.

The cockpit shows three panels: the raw text, the exact compilable Lean 4
definitions for that certificate and claim, and the plain-English reading of
what Lean verified. Amber warnings list clauses the model cannot represent —
hammer, punitive damages, consent to settle, PFAS, subrogation and others. A
proof about a narrower contract than the one you signed is not a proof about
your contract.

## 6. Clashes and the group view

Workers' Compensation and General Liability can respond to the same explosion.
Booked separately each looks small; together they may breach a clash threshold.
The Group Executive Bridge scans shared occurrence tags and shared insured
groups, reports the affected lines and certificates, and rolls the desk into
euros. It also shows the capital the desk protected: leakage prevented is added
to group own funds, and the ratio can only improve.

## 7. The 60-second tour

Open the app and press **▶ 60s Guided Demo Tour** in the header. Five steps:
the KPI ribbon, the six cash calls, the double-entry voucher, the three-way
intake, and the clash panel. Press `Esc` to leave at any point.

## 8. Deploying it

`docs/DEPLOYMENT.md` covers Render (one click from `render.yaml`), Fly.io,
Railway and a plain VPS. The Docker build runs the paranoid audit, so an image
cannot be produced unless every theorem still checks out.

---

# v1.1.0 — subjectivity, bordereaux, and a trail you can prove

## 1. Not everything is arithmetic

A hammer clause, a declaratory-judgment fee, a punitive-damages exclusion, a
policy-period dispute: these cannot be settled by a formula. The cockpit models
them as **typed subjectivity** and refuses to release cash until two different
people — a claims examiner and a technical accountant — have signed the same
requirement. That is the four-eyes principle (`Vier-Augen-Prinzip`).

The kernel proves the control rather than trusting the form:

* `selfApproval_rejected` — the same name in both boxes is never valid;
* `unattestedSubjectivity_holds_wire` — one unsigned requirement holds the wire;
* `disputedClaim_never_authorized` — a queried or rejected claim is never paid;
* `noSubjectivity_cleanStp_authorized` — no friction where none is needed.

In the UI, the two held claims in the Q3 bordereau show their requirement, two
reviewer fields and a *Sign off* button. Typing the same name twice is rejected
with the theorem cited. Two distinct names release the wire, and the held count
drops immediately.

## 2. The quarterly bordereau

Carriers send loss bordereaux, not single claims. Click **Run Q3 Carrier
Bordereau (24 Claims)** and the whole book is audited in one Lean call:

* 13 clean claims auto-settle;
* 3 settle with unpaid premium offset;
* 6 are queried as disputes, preventing **$1,520,000** of leakage;
* 2 are mathematically clean but held for four-eyes sign-off.

Filter by status, then download the **SAP FS-RI / IFRS 17 posting batch**: one
balanced CSV with debit and credit lines for every authorized wire and every
OSLR movement. Upload your own bordereau with the same columns to run your book.

## 3. A tamper-evident audit trail

Every sign-off and audit event is appended to a SHA-256 hash chain in SQLite.
Each entry hashes the previous entry's hash, the timestamp, the event, the actor,
the entity and the summary. `GET /api/audit-ledger` re-computes every link from
the genesis hash and reports `chainIntact`. Edit a historical row and the chain
breaks from that point — which is the point.

The event log in the UI shows the chain live: timestamps, event types, entities
and the first characters of each hash.

## 4. Authentic ACORD

Inbound messages can use the real `<Jv-Ins-Reinsurance Version="2016-1">`
structure with `ClaimMovement` → `ReferredContract` / `Claim` → `ClaimEntry` →
`ClaimMovementAmtItem Type="PaidLoss|PaidExpense|OSLRLoss|OSLRExpense|CashCall"`.
Flat tags still work, so older feeds keep running. Outbound is a
`ClaimMovementResponse` carrying `<AcknowledgementStatus>` and the verified
amounts.

## 5. Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request: elan and the
pinned toolchain, `lake build`, the paranoid audit, the UI integrity check, the
end-to-end suite and the fuzz suite. The badge at the top of the README is the
result.

## 6. The demo, updated

1. Open the desk: six KPI cards, all populated on boot.
2. Click the D&O case: inside-limits cap, $400,000 dispute.
3. Run the bordereau: 24 claims, $1.52M saved, SAP export enabled.
4. Sign off a held claim with two different names; watch the hold clear.
5. Type the same name twice; watch the kernel refuse, citing
   `selfApproval_rejected`.
6. Open the event log: chain intact, hashes visible.
7. Switch to the Group tab for the EUR roll-up and the clash alert.
