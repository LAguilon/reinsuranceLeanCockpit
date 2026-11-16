# reinsuranceLeanCockpit

Formal verification and risk intelligence for **bound** reinsurance portfolios.

Contracts are total functions over exact integers. Every accounting identity and
risk bound is a theorem proved by the Lean 4 kernel — for every loss, every FX
rate, and every retrocession tower depth. No Mathlib, no `Float`, no `sorry`.

**v0.4** fixes the post-season balance sheet. Own funds now erode by the realised
season drain, aggregate limits erode across events, and the solvency curve is
proved monotone in `Monotonicity.lean` — a bigger loss can no longer leave the
ratio flat, let alone raise it.

**v0.3** closed the loop from paper to balance sheet:

```
PDF/MRC slip ──► Python extractor ──► Lean gatekeeper ──► static scanner ──► multi-event simulator
   (.pdf)          (stdlib only)        (isValid)         (5 loophole classes)   (FX + cat season)
```

A broker's slip is parsed, admitted or rejected by the same `isValid` predicate
the theorems consume, scanned for structural flaws, and then stressed through a
catastrophe season. The browser never computes a number; it renders what the
compiled Lean binary returned.

```bash
lake build                 # ~10s from clean, zero dependencies
python3 server/app.py      # → http://localhost:8080
python3 scripts/test_e2e.py
```

---

## v0.4 — why the solvency ratio could misbehave

The v0.3 simulator reported `ownFunds / (netLoss + reinstatement + SCR)`. Capital
never moved, and the loss appeared in the *denominator*, so the ratio fell while
losses were below the stop-loss attachment and then **stopped changing entirely**
once every inward limit and the stop loss bound. Measured on the as-bound book:

| Ground-up | v0.3 ratio | v0.4 post-season ratio |
|---|---|---|
| $0 | 634% | 203% |
| $25M | 308% | 169% |
| $100M | 308% | 169% |
| $500M | 308% | 169% |

A ratio that is flat from $25M to $500M reads as "this loss does not matter",
which is the accounting error underneath: a realised catastrophe does not merely
add to a requirement, it consumes capital.

v0.4 changes the physics, not the display:

* `seasonLossDrainEur := annualFinalNetLossEur + totalReinstFeeEur`
* `postSeasonOwnFundsEur := initialOwnFundsEur − drain` (truncated at zero)
* `postSeasonScrEur := otherScrEur + counterpartyScrEur + maxSingleEventAppetiteEur`
* `solvencyRatioPct := postSeasonOwnFunds / postSeasonScr` (headline)
* `preSeasonSolvencyRatioPct` keeps the old build-up for comparison

Aggregate limits now erode per contract across the season, and each layer's
reinstatement premium is charged on **what that layer actually pays**, not on the
pre-tower gross.

`Monotonicity.lean` proves the three layers of the argument: each contract form
is monotone in the loss (payout and net), the inuring tower preserves it by
induction, and post-season capital/ratio are antitone in the drain.

---

## Quickstart

```bash
# 1. build the kernel-checked engine
lake build

# 2. build the sample PDF slips (pure Python, no pip installs)
python3 scripts/generate_sample_pdfs.py

# 3. run the cockpit
python3 server/app.py            # PORT=8080 by default
# → open http://localhost:8080
```

CLI, unchanged from v0.2 plus two new modes:

```bash
lake exe cockpit
lake exe cockpit audit examples/continental_re_portfolio.json
lake exe cockpit audit examples/continental_re_portfolio.json --json
lake exe cockpit simulate examples/continental_re_portfolio.json \
                          examples/scenarios/global_twin_cat_fx_shock.json [--json]
lake exe cockpit theorems [--json]
```

---

## The pipeline, step by step

**1. Extract.** `server/slip_parser.py` reads a PDF (or `.txt`) and pulls the
labelled MRC fields out of the `BT … ET` text blocks, decompressing Flate streams
when present. It is not a general PDF reader; it reads the one thing a slip
contains and reports what it could not find instead of guessing.

**2. Admit.** `ReinsuranceLeanCockpit/Validation.lean` is the gate. A contract
with `shareBps = 11500` is not merely implausible — it falls outside
`evalContractPayout_le_loss`, whose hypothesis is `c.isValid = true`. The gate
returns exactly the blocking errors, and

```lean
theorem validateContract_isEmpty_iff (c : BoundContract) :
    (validateContract c).isEmpty = c.isValid
```

guarantees the gate and the theorem precondition are the same predicate, not two
implementations that happen to agree today.

**3. Scan.** `Diagnostics.lean` reports five structural classes: vertical tower
gaps, tower overlaps, currency basis mismatch, aggregate exhaustion, and
counterparty credit cliffs. Only *adjacent* layers are compared, so a layer that
fills a gap suppresses the false positive.

**4. Simulate.** `Simulation.lean` prices a season: each event is converted into
every inward contract's currency, priced, converted back to EUR, and passed down
the outward tower in inuring order. Stop losses then apply to the season total.

---

## What is proved

57 theorems, no `sorry`, no `sorryAx`. The core of the portfolio argument:

| Theorem | Statement |
|---|---|
| `evalContractPayout_le_loss` | every valid contract, of any of the four forms, pays at most the loss |
| `applyInuringTower_conservation` | **by induction:** net retained + total recovered = gross, for a tower of any depth |
| `applyInuringTower_recovered_le` | **by induction:** total recoveries never exceed the gross loss |
| `applyInuringTower_net_le` | net retained never exceeds the gross loss |
| `xolPayout_le_loss` / `xolPayout_bounded` | a layer never pays more than the loss or its limits |
| `xol_loss_conservation` | net + ceded = gross for one layer |
| `qsPayout_le_loss` | quota share bounded when the share is at most 100% |
| `surplusPayout_le_loss` / `stopLossPayout_le_loss` | the two added forms are bounded |
| `stepXoLTreaty_agg_safe` | one treaty step partitions aggregate capacity exactly |
| `alpine_safe_at_inception_fx` / `alpine_fixed_fx_safe` | the FX case study, for every loss and every rate |
| `isPortfolioValid_forall` | **the gate implies the theorem precondition, for every contract in a portfolio** |
| `validateContract_isEmpty_iff` | the gate's error list is empty exactly when the contract is valid |
| `portfolioStress_totalScr` | the printed SCR total equals its components |
| `scenarioReport_scr_sum` | the simulator's SCR total equals its four components |
| `netAfterStopLoss_conservation` | the stop loss moves money, it does not make it |
| `tally_sum` / `auditPortfolio_counts_sum` | severity counts partition the findings |
| `evalContractPayout_mono` | every valid contract's payout is monotone in the loss |
| `evalContractNet_mono` | every valid contract's net retention is monotone in the loss |
| `applyInuringTower_net_mono` | **by induction:** a bigger gross loss leaves a bigger net retained loss |
| `postSeasonOwnFunds_antitone` | a bigger drain leaves less capital |
| `postSeasonRatio_antitone` | a bigger drain can only lower the post-season ratio |
| `solvencyRatioPct_mono_ownFunds` | adding capital never lowers the ratio |

`scripts/AxiomAudit.lean` runs `#print axioms` over the headline set; nothing
depends on `sorryAx`, and the strongest entries rest on `propext` and
`Quot.sound` alone.

---

## The web cockpit

Five panels, vanilla HTML/CSS/JS, no framework and no build step:

1. **Header + portfolio bar** — live theorem count fetched from
   `GET /api/theorems`, kernel latency per request, and a preset switcher
   (as-bound 94% breach vs restructured 168% solvent).
2. **Solvency gauge** — SVG semicircle, stacked SCR bar, KPI strip including the
   gatekeeper verdict.
3. **Tower visualiser** — per-peril tabs, inward layers against the outward
   tower, scaled by attachment and limit, with unhedged gaps drawn as striped
   red blocks and BBB/Unrated layers badged.
4. **Slip validator** — drag-and-drop or three one-click demo PDFs. Binding the
   gap-closer removes the red block; the Cayman slip adds a credit cliff; the
   115% quota share is rejected with the failing bound quoted.
5. **Simulator + proof registry** — editable FX rates and event list, a live
   `POST /api/simulate`, and the collapsible table of all 57 theorems.

### API

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | liveness + whether the Lean binary is present |
| GET | `/api/theorems` | kernel proof registry |
| GET | `/api/presets` | portfolios, default scenario, sample slips |
| POST | `/api/audit` | run `cockpit audit --json` on a posted portfolio |
| POST | `/api/simulate` | run `cockpit simulate --json` |
| POST | `/api/parse-slip` | parse a PDF/base64 slip, optionally bind + re-audit |
| GET | `/api/slips/<name>` | serve the raw PDF |

Every POST writes to a `tempfile`, invokes the binary with a 10 s timeout,
deletes the temp file, and returns the Lean JSON plus `leanExecMs`.

---

## Sample PDF slips

Generated by `scripts/generate_sample_pdfs.py`, a pure-stdlib PDF 1.4 writer
with a correct `xref` table:

| Slip | What it proves |
|---|---|
| `SLIP_01_Valid_Gap_Closer_USD.pdf` | 10M USD xs 20M closes the vertical gap between Layer 1 (ends 20M) and Layer 2 (attaches 30M). Findings fall; the gap disappears. |
| `SLIP_02_Trap_Unrated_FX_Mismatch.pdf` | Unrated Cayman cell, EUR-denominated against JPY inward business. Adds a `CounterpartyCreditCliff` and leaves the currency mismatch standing. |
| `SLIP_03_Illegal_115pct_QuotaShare.pdf` | `Share_Bps: 11500`. The gate rejects it and names the violated bound. |

`server/slip_parser.py` round-trips all three back into the exact JSON schema
`Ingestion.lean` expects.

---

## End-to-end test

```bash
python3 scripts/test_e2e.py
```

Starts the real handler on an ephemeral port and asserts: health, ≥32 theorems,
presets, 94%/breach and 168%/0-findings audits, all three slips (gap closure,
new credit cliff, gatekeeper rejection), simulation conservation
(`netBefore + recovered == gross`), and `application/pdf` delivery.

---

## Deliberate simplifications

* The SCR is a deterministic stress build-up, not the Standard Formula.
* The simulated stress loss is the book's own maximum unhedged single-event
  exposure; it is not a return-period loss.
* Counterparty charges apply to full outward aggregate capacity, undiscounted.
* FX is one rate per currency per request; no volatility, no basis, no hedge.
* Perils gate applicability by membership; event-window aggregation from the
  v0.1 hours clause is not yet wired into `BoundContract`.
* The PDF extractor handles simple text-layer PDFs, not scanned images or
  complex encodings.
* The solvency sweep plateaus once every inward limit and the stop loss bind
  (about $80M ground-up on the sample book). That is the correct shape for this
  portfolio, not a monotonicity failure: the ratio stops falling because the
  loss stops growing.

## Repository layout

```text
ReinsuranceLeanCockpit/
  Core.lean  Solvency.lean  AlpineShowcase.lean      # v0.1
  Contracts.lean  Diagnostics.lean                   # v0.2
  Validation.lean  Simulation.lean  Ingestion.lean   # v0.3
  Monotonicity.lean                                  # v0.4
Main.lean
server/app.py  server/slip_parser.py
web/index.html  web/styles.css  web/app.js
scripts/generate_sample_pdfs.py  scripts/test_e2e.py  scripts/AxiomAudit.lean
examples/continental_re_portfolio.json  examples/continental_re_fixed.json
examples/scenarios/global_twin_cat_fx_shock.json
examples/slips/*.pdf  examples/slips/*.txt
```

## License

Apache-2.0.
