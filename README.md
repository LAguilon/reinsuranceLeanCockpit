# reinsuranceLeanCockpit

Formal verification and risk intelligence for **bound** reinsurance portfolios.

Contracts are modelled as total functions over exact integers. Accounting
invariants and risk bounds are *theorems*, proved by the Lean 4 kernel for every
loss from $0 to $∞ and every FX rate in range — not spot-checked in a
spreadsheet. No Mathlib, no `Float`, no `sorry`. The whole library builds in a
few seconds.

Why bother? Because the expensive failures in a reinsurance portfolio are not
arithmetic errors, they are *structural* ones: a currency mismatch between an
inward layer and its retrocession, a reinstatement that does not exist on the
outward side, an aggregate limit that runs out on the second event. Formalizing
the contract language the way one would formalize a tax code makes those
structures visible, and then proves whether they are safe or not.

---

## Quickstart

```bash
lake build          # ~3s from clean, zero external dependencies
lake exe cockpit    # the audit report
```

Output of `lake exe cockpit` on this commit:

```text
==================================================================
   REINSURANCE LEAN COCKPIT v0.1 - FORMAL PORTFOLIO AUDITOR
==================================================================

[VERIFIED] Compile-time Lean 4 Theorems Checked:
  ✓ xolPayout_le_loss          (No Over-Recovery)
  ✓ xolPayout_bounded          (Occurrence & Aggregate Limits)
  ✓ xol_loss_conservation      (Accounting Conservation of Money)
  ✓ qsPayout_le_loss           (Quota Share Boundedness)
  ✓ stepXoLTreaty_agg_safe     (Stateful Aggregate Erosion Invariant)
  ✓ alpine_safe_at_inception_fx(Safe at 0.80 FX across $0..$∞)
  ✓ alpine_fixed_fx_safe       (Universal Fix Safe across $0..$∞ & FX ≤ 1.00)

------------------------------------------------------------------
AUTOMATED LOOPHOLE HUNTER: FX Basis-Risk Scan
------------------------------------------------------------------
  [ALERT] Hidden FX Cliff Detected!
  Trigger Scenario: Ground-Up Loss = $70M USD at FX = 1.00 EUR/USD
  Resulting Net Loss: €27.0M (Breaches €25.0M Board Limit!)

------------------------------------------------------------------
SOLVENCY II COCKPIT SIMULATIONS (Own Funds = €40.0M)
------------------------------------------------------------------
[1. Inception FX 0.80 ($80M Hurricane - Board View)]
  Net Cat Loss:      €25.0M
  Reinstatement Fee: €0.0M
  Total SCR:         €35.0M (Own Funds: €40.0M)
  Solvency II Ratio: 114% -> SOLVENT (OK)

[2. FX Shock to Parity 1.00 ($80M Hurricane - Unhedged Cliff!)]
  Net Cat Loss:      €37.0M
  Reinstatement Fee: €0.0M
  Total SCR:         €47.0M (Own Funds: €40.0M)
  Solvency II Ratio: 85% -> REGULATORY BREACH (<100%)

[3. FX Shock 1.00 with Lean-Verified USD Retro Fix]
  Net Cat Loss:      €25.0M
  Reinstatement Fee: €0.0M
  Total SCR:         €35.0M (Own Funds: €40.0M)
  Solvency II Ratio: 114% -> SOLVENT (OK)

[4. Twin-Storm Aggregate Exhaustion Trap (2x $80M Storms)]
  Net Cat Loss:      €68.0M
  Reinstatement Fee: €9.6M
  Total SCR:         €87.6M (Own Funds: €40.0M)
  Solvency II Ratio: 45% -> REGULATORY BREACH (<100%)
==================================================================
```

---

## Architecture

| File | Contents |
|---|---|
| `ReinsuranceLeanCockpit/Core.lean` | Currency and peril types, `xolPayout`, `netAfterXoL`, `qsPayout`, the stateful `StatefulXoLTreaty` with multi-event aggregate erosion and pro-rata-as-to-amount reinstatement premium, and the core proofs |
| `ReinsuranceLeanCockpit/Solvency.lean` | Deterministic SCR build-up and the Solvency II ratio engine, plus proofs that the reported total and the reported solvency flag agree with their own line items |
| `ReinsuranceLeanCockpit/AlpineShowcase.lean` | The "Alpine Re" bound portfolio: the FX basis-risk cliff, the currency-matched fix with its universal proof, and the twin-storm aggregate exhaustion trap |
| `Main.lean` | The `cockpit` executable: theorem inventory, loophole scan, solvency simulations |
| `scripts/AxiomAudit.lean` | `#print axioms` for every headline theorem |

### Units

* Money is `Nat` in the contract's minor unit. There is no `Float` in the library, so there is no representation error to reason about.
* Shares, rates and ratios are basis points: `10000 = 100.00%`.
* FX is integer cents per unit: `80 = 0.80`, `100 = 1.00`.
* All division rounds **down**, which is the conservative direction for ceded amounts and the direction under which monotonicity and conservation hold without side conditions.

---

## What is actually proved

| Theorem | Statement |
|---|---|
| `xolPayout_le_loss` | a layer never pays more than the loss |
| `xolPayout_bounded` | a layer never pays more than its occurrence limit or its remaining aggregate |
| `xol_loss_conservation` | net retained + ceded = gross, for every loss |
| `qsPayout_le_loss` | a quota share with `share ≤ 100%` never pays more than the loss |
| `stepXoLTreaty_agg_safe` | one treaty step partitions the available aggregate capacity exactly: `payout + remaining = available` |
| `stepXoLTreaty_remAgg_le` | a step can only consume aggregate capacity, never create it |
| `evaluateSolvency_totalScr` | the printed SCR total equals the sum of the printed line items |
| `evaluateSolvency_isSolvent_iff` | the solvency flag is exactly "ratio ≥ 100%" |
| `alpine_safe_at_inception_fx` | the naive structure is safe at 0.80 EUR/USD **for every hurricane size** |
| `alpine_fixed_usd_bounded` | the currency-matched structure retains at most $25M **for every loss** |
| `alpine_fixed_fx_safe` | the currency-matched structure stays under €25M **for every loss and every FX ≤ 1.00** |

`scripts/AxiomAudit.lean` confirms none of these depend on anything beyond
`propext`, `Classical.choice` and `Quot.sound`. There is no `sorryAx` anywhere.

---

## The Alpine Re case

**The structure.** Own funds €40M, other non-cat SCR €10M, board appetite: a
single-event net cat loss must never exceed €25M.

* Inward: US hurricane XoL **$60M xs $20M**, one full reinstatement (aggregate $120M).
* Outward: retro **€23M xs €25M**, no reinstatements (aggregate €23M).

**Loophole 1 — FX basis risk.** At inception FX (0.80) the outward euro layer
tracks the inward dollar layer closely enough that the retained loss is capped
at €25M. That is not luck, it is a theorem: `alpine_safe_at_inception_fx`. Move
the rate to parity and the same $80M hurricane retains €37M — a Solvency II
ratio of 85%, i.e. a breach. The scan finds the first failure at a $70M loss and
1.00 EUR/USD: €27.0M retained.

The fix is to stop translating risk: retrocede **$35M xs $25M in USD**. The
retained dollar loss is then bounded by $25M for every loss
(`alpine_fixed_usd_bounded`), and the euro retained loss is bounded by €25M for
every loss and every rate at or below parity (`alpine_fixed_fx_safe`) — because
`usdToEur` is monotone and the bound is preserved under multiplication by a
factor no greater than 100 cents.

**Loophole 2 — aggregate exhaustion.** Currency matching does not fix capacity
mismatch. The inward treaty can pay a second full $60M event; the outward retro
has $35M of aggregate and no reinstatement. Two $80M storms produce $120M of
inward recovery, $35M of outward recovery, $68M net retained *plus* €9.6M of
inward reinstatement premium — SCR of €87.6M against €40M of own funds.

Neither loophole is visible in a single-scenario spreadsheet. Both fall out of
the contract structure the moment it is written as a total function.

---

## Deliberate simplifications

Stated here rather than buried, because a verification claim is only as good as
its scope:

* The SCR is a deterministic stress build-up (net cat loss + reinstatement drag +
  baseline non-cat SCR), not the Solvency II Standard Formula. Correlations,
  counterparty default and operational risk modules are not modelled.
* FX is a single conversion path at one rate per scenario. No volatility, no
  hedging programme, no basis between fixing dates.
* Perils gate treaty applicability by membership; they do not carry severity
  distributions.
* Reinstatement premium is pro rata as to amount. Pro rata as to time is not
  modelled (it needs the policy period, which is not yet in the treaty record).
* No JSON/PDF ingestion yet: the portfolio is constructed in Lean.

---

## Roadmap

* **Phase 2 — General bound portfolio graph.** Surplus share, aggregate stop
  loss, inuring priority as a DAG with verified ordering, and proofs that no
  contract is applied twice to the same loss.
* **Phase 3 — Multi-currency and counterparty default.** Per-currency aggregate
  tracking, FX correlation stress grids, and a Solvency II Standard Formula
  module for counterparty default risk.
* **Phase 4 — Ingestion and interactive cockpit.** JSON/PDF bound-contract
  ingestion into the verified core, plus a web front end over the same theorems.

---

## Repository layout

```text
.
├── lakefile.toml
├── lean-toolchain
├── ReinsuranceLeanCockpit.lean
├── Main.lean
├── ReinsuranceLeanCockpit/
│   ├── Core.lean
│   ├── Solvency.lean
│   └── AlpineShowcase.lean
├── scripts/
│   └── AxiomAudit.lean
└── README.md
```

## Verification status

```bash
lake build                          # Build completed successfully, 0 errors, 0 warnings
lake env lean scripts/AxiomAudit.lean   # no axioms beyond propext / Classical.choice / Quot.sound
grep -rn "sorry" --include='*.lean' .   # no matches
```

## License

Apache-2.0.
