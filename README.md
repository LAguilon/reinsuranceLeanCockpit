# reinsuranceLeanCockpit

Formal verification and risk intelligence for **bound** reinsurance portfolios.

Contracts are total functions over exact integers. Accounting identities and risk
bounds are *theorems*, proved by the Lean 4 kernel for every loss from 0 to ∞ and
every FX rate in range. No Mathlib, no `Float`, no `sorry`.

**v0.2** turns the v0.1 case study into a data-driven engine: a general bound
contract schema with four composable forms, an induction proof over retrocession
towers of arbitrary depth, a static loophole scanner with five structural
classes, a JSON ingestion pipeline, and a three-mode CLI.

```bash
lake build                                  # ~7s from clean, zero dependencies
lake exe cockpit                            # full report
lake exe cockpit audit examples/continental_re_portfolio.json
lake exe cockpit audit examples/continental_re_portfolio.json --json
```

---

## What is actually proved

### v0.1 — layer arithmetic

| Theorem | Statement |
|---|---|
| `xolPayout_le_loss` | a layer never pays more than the loss |
| `xolPayout_bounded` | never more than the occurrence limit or the remaining aggregate |
| `xol_loss_conservation` | net retained + ceded = gross, for every loss |
| `qsPayout_le_loss` | a quota share with `share ≤ 100%` never pays more than the loss |
| `stepXoLTreaty_agg_safe` | one treaty step partitions available aggregate capacity exactly |
| `alpine_safe_at_inception_fx` | the naive Alpine structure is safe at 0.80 EUR/USD for every loss |
| `alpine_fixed_fx_safe` | the currency-matched structure stays under €25M for every loss and every FX ≤ 1.00 |

### v0.2 — general contracts and inductive towers

| Theorem | Statement |
|---|---|
| `surplusPayout_le_loss` | a surplus share never pays more than the loss |
| `stopLossPayout_le_loss` | an aggregate stop loss never pays more than the annual loss |
| `evalContractPayout_le_loss` | **for every valid contract — any of the four forms — payout ≤ loss** |
| `applyInuringTower_conservation` | **by induction: net retained + total recovered = gross, for a tower of any depth** |
| `applyInuringTower_recovered_le` | **by induction: total recovered ≤ gross, however many contracts are bound** |
| `applyInuringTower_net_le` | net retained ≤ gross, as a corollary |
| `portfolioStress_totalScr` | the printed SCR total equals its four printed components |
| `portfolioStress_isSolvent_iff` | the solvency flag is exactly "ratio ≥ 100%" |
| `tally_sum` | the three severity counts partition the finding list |
| `surplusPayout_mono`, `surplusPayout_zero_below`, `stopLossPayout_zero_below` | shape of the two new forms |

`scripts/AxiomAudit.lean` runs `#print axioms` on all 26 theorems. None depends on
anything beyond `propext`, `Classical.choice` and `Quot.sound`; there is no
`sorryAx` anywhere, and `grep -rn sorry --include='*.lean'` returns nothing.

The two tower theorems are the point of the release. They are proved by structural
recursion on the contract list, not by a bounded loop or a decision procedure, so
they hold for *n* contracts for arbitrary *n* — including a tower with a gap, a
duplicate layer or an unrated counterparty, where the theorem still says the
accounting adds up even though the risk does not.

---

## The four contract forms

| Form | Payout on a loss | Params |
|---|---|---|
| **XoL** | `min (min (loss − attachment) occLimit) (min remAgg aggLimit)` | attachment, occLimit, aggLimit, reinstRateBps, basePremium |
| **Quota share** | `min (loss × shareBps / 10000) eventCap` | shareBps, eventCap, commissionBps |
| **Surplus share** | `min (min (loss − retentionLine) (numLines × retentionLine)) eventCap` | retentionLine, numLines, eventCap |
| **Aggregate stop loss** | `min (annualNetLoss − aggAttachment) aggLimit` | aggAttachment, aggLimit |

Notes on the modelling choices, because they are choices:

* **Surplus share is written in amount terms.** It cedes the layer
  `numLines × retentionLine xs retentionLine` — the standard amount view of a
  surplus treaty. The proportional view `numLines/(numLines+1)` is what this layer
  converges to once the loss exhausts the capacity. The amount form avoids a
  division that would make `payout ≤ loss` depend on rounding.
* **Reinstatements are inferred from the rate.** `ContractKind` carries
  `reinstRateBps` but no count, so a zero rate means no reinstatement was
  purchased. The diagnostics module reads it that way.
* **Validity gates the theorems, not the functions.** `evalContractPayout` is total
  for every contract; `isValid` supplies the `shareBps ≤ 10000` hypothesis that
  the quota-share bound needs.

---

## The static scanner

Five structural anomalies, each a pure function of the portfolio. Run twice, the
report is identical.

| Finding | Rule | Severity |
|---|---|---|
| `VerticalTowerGap` | two *adjacent* outward XoL layers, same peril/currency/priority, `lower.attachment + lower.occLimit < upper.attachment` | CRITICAL |
| `VerticalTowerOverlap` | same, but `upper.attachment < lower.attachment + lower.occLimit` | WARNING |
| `CurrencyBasisMismatch` | a peril written inward in a currency that no outward cover for that peril uses | CRITICAL |
| `AggregateExhaustionMismatch` | inward aggregate − outward aggregate > 2 × single-event appetite, **or** inward reinstates onto outward that does not | CRITICAL / WARNING |
| `CounterpartyCreditCliff` | outward recoverable with a `BBB` or `Unrated` counterparty, with the default charge quantified | WARNING / CRITICAL |

Only *adjacent* layers are compared. Reporting `Layer 1 → Layer 3` as a gap when
`Layer 2` fills the space is the false positive that would discredit every other
finding in the report; `hasIntermediate` suppresses it.

---

## Sample audit: `examples/continental_re_portfolio.json`

```text
==================================================================
  PORTFOLIO AUDIT: Continental Re
  10 bound contracts | 7 findings (6 CRITICAL, 1 WARNING, 0 INFO)
==================================================================

EXPOSURE BY CURRENCY (EUR, single-event limits)
  segment      inward      outward     net unhedged
  EUR          €23.0M       €12.0M       €11.0M
  USD          €73.6M       €36.8M       €36.8M
  GBP          €0.0M        €0.0M        €0.0M
  JPY          €120.0M      €0.0M        €120.0M

EXPOSURE BY PERIL (EUR, single-event limits)
  segment      inward      outward     net unhedged
  Windstorm    €73.6M       €36.8M       €36.8M
  Earthquake   €120.0M      €12.0M       €108.0M
  Flood        €8.0M        €0.0M        €8.0M
  Cyber        €15.0M       €0.0M        €15.0M

------------------------------------------------------------------
STRUCTURAL LOOPHOLES
------------------------------------------------------------------
  [CRITICAL] VerticalTowerGap  (€9.2M)
      CNT-WS-L1 ends at €20.0M but CNT-WS-L2 attaches at €30.0M: unhedged vertical gap
  [CRITICAL] CurrencyBasisMismatch  (€120.0M)
      Earthquake is written in JPY but retroceded in EUR; €120.0M of single-event inward cover is untranslated
  [CRITICAL] AggregateExhaustionMismatch  (€66.6M)
      Windstorm: inward aggregate €147.2M vs outward €80.6M; uncovered €66.6M (appetite cap €80.0M)
  [CRITICAL] AggregateExhaustionMismatch  (€108.0M)
      Earthquake: inward aggregate €120.0M vs outward €12.0M; uncovered €108.0M (appetite cap €80.0M)
  [CRITICAL] AggregateExhaustionMismatch  (€16.0M)
      Flood: €16.0M of inward aggregate sits on a layer with no reinstating outward cover (appetite cap €80.0M)
  [CRITICAL] CounterpartyCreditCliff  (€5.7M)
      CNT-WS-L2 placed with Bermuda Cell 42 (Unrated); recoverable €23.0M carries a 2500 bps default charge
  [WARNING] CounterpartyCreditCliff  (€2.4M)
      CNT-FL-SL placed with Atlas Re (BBB); recoverable €30.0M carries a 800 bps default charge

------------------------------------------------------------------
SOLVENCY II STRESS
------------------------------------------------------------------
  Scenario:          Static stress: max unhedged single-event exposure, full reinstatement drag
  Net Cat Loss:      €108.0M
  Reinstatement Fee: €0.0M
  Counterparty SCR:  €8.9M
  Other SCR:         €10.0M
  Total SCR:         €126.9M (Own Funds: €120.0M)
  Solvency II Ratio: 94% -> REGULATORY BREACH (<100%)
==================================================================
```

The same portfolio after restructuring (`examples/continental_re_fixed.json`):
**0 findings**, Solvency II ratio **168%**, 12 contracts — the three extra contracts
are a closing Layer 3, a JPY-matched earthquake retro and a reinstating flood layer.

| | As bound | Restructured |
|---|---|---|
| Findings | 7 (6 CRITICAL, 1 WARNING) | 0 |
| Solvency II ratio | 94% — breach | 168% |
| Unhedged JPY single-event exposure | €120.0M | €0.0M |

---

## JSON pipeline

Input is a portfolio document; output is the full verified audit report.

```json
{
  "name": "Continental Re",
  "ownFundsEur": 120000000,
  "otherScrEur": 10000000,
  "maxSingleEventAppetiteEur": 40000000,
  "fxRatesToEurCents": [
    { "currency": "EUR", "cents": 100 },
    { "currency": "USD", "cents": 92 }
  ],
  "contracts": [
    {
      "id": "CNT-WS-L1",
      "name": "Outward US Windstorm Layer 1: 15M xs 5M",
      "counterparty": "Northwind Re",
      "rating": "AA",
      "direction": "outward",
      "currency": "USD",
      "perils": ["Windstorm"],
      "inuringPriority": 10,
      "kind": {
        "type": "xol",
        "attachment": 5000000,
        "occLimit": 15000000,
        "aggLimit": 30000000,
        "reinstRateBps": 0,
        "basePremium": 1500000
      }
    }
  ]
}
```

`--json` emits the same report as compact JSON (`portfolio`, `contractCount`,
`exposureByCurrency`, `exposureByPeril`, `findings`, `stress`, and the four
counts), ready for a web or PDF pipeline. Malformed input fails with the field
name, not a positional mismatch.

### Units

Money is `Nat` at a fixed minor-unit scale; the formatter divides by 10⁶, so
`120000000` prints as `€120.0M`. FX entries are integer rates in hundredths —
`100` is parity, `USD 92` is a 0.92 quote — and conversion is
`amount * rate / 100`, rounding down. Shares and rates are basis points
(`10000 = 100.00%`). Nothing is ever a `Float`.

---

## Architecture

| File | Contents |
|---|---|
| `ReinsuranceLeanCockpit/Core.lean` | v0.1: currencies, perils, `xolPayout`, `qsPayout`, stateful treaty with aggregate erosion |
| `ReinsuranceLeanCockpit/Solvency.lean` | v0.1: deterministic SCR build-up and ratio engine |
| `ReinsuranceLeanCockpit/AlpineShowcase.lean` | v0.1: the Alpine Re FX cliff and its verified fix |
| `ReinsuranceLeanCockpit/Contracts.lean` | **v0.2:** `CreditRating`, `Direction`, `ContractKind`, `BoundContract`, `evalContractPayout`, `applyInuringTower` and the inductive tower proofs |
| `ReinsuranceLeanCockpit/Diagnostics.lean` | **v0.2:** exposure matrix, five-class scanner, extended Solvency II with counterparty default SCR |
| `ReinsuranceLeanCockpit/Ingestion.lean` | **v0.2:** `ToJson`/`FromJson` for every type, file loader, compact report emitter |
| `Main.lean` | three-mode CLI |
| `scripts/AxiomAudit.lean` | `#print axioms` for all 26 theorems |
| `examples/` | Continental Re portfolio (7 findings) and the restructured twin (0 findings) |

---

## Deliberate simplifications

Stated, not buried, because a verification claim is only as good as its scope:

* The SCR is a deterministic stress build-up — net cat loss + reinstatement drag +
  baseline non-cat + counterparty default — not the Solvency II Standard Formula.
  Correlations, operational risk and the full premium/reserve modules are absent.
* The stress loss is the portfolio's own maximum unhedged single-event exposure.
  That makes the scenario reproducible and impossible to drift from the book, but
  it is not a return-period loss.
* Counterparty default charges are applied to full outward aggregate capacity, not
  to a discounted expected recoverable.
* FX is one rate per currency per portfolio: no volatility, no basis between
  fixing dates, no hedging programme.
* Perils gate applicability by membership; they carry no severity distribution and
  no event-window aggregation (the v0.1 hours-clause machinery is not yet wired
  into `BoundContract`).
* Per-risk XoL is not split-proof: two losses can recover more than one combined
  loss of the same size. That hazard is a property of the form, not a bug in the
  model, and is documented in the v0.1 `AlpineShowcase` reasoning.

---

## Verification status

```text
$ lake build
Build completed successfully (19 jobs).        # 0 errors, 0 warnings

$ lake env lean scripts/AxiomAudit.lean
26 theorems; axioms ⊆ {propext, Classical.choice, Quot.sound}

$ grep -rn "sorry" --include='*.lean' .
(no matches)
```

## Roadmap

* **Phase 3 —** multi-currency aggregate tracking per currency (not just EUR),
  FX correlation stress grids, event-window aggregation wired into the contract
  schema, and a full Standard Formula counterparty module.
* **Phase 4 —** PDF/JSON bound-contract ingestion into the verified core, a web
  front end over the same theorems, and signed audit reports.

## License

Apache-2.0.
