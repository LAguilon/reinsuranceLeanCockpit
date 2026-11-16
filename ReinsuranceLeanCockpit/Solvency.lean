import ReinsuranceLeanCockpit.Core

namespace ReinsuranceLeanCockpit

/-!
  Solvency II capital and ratio engine.

  The SCR here is a deliberately simplified, deterministic stress build-up:
  net retained catastrophe loss + reinstatement premium drag + baseline
  non-cat SCR. It is *not* the Standard Formula; it is the part of the
  Standard Formula that can be reconciled to contract arithmetic, which is the
  part a formal cockpit can defend.
-/

/-- Convert USD amount to EUR given `eurCentsPerUsd` (e.g., 80 = 0.80 EUR per USD).

Rounds down to the minor unit. Rounding down is conservative on the asset side
and is the convention under which the monotonicity lemmas hold. -/
def usdToEur (usdAmount eurCentsPerUsd : Nat) : Nat :=
  (usdAmount * eurCentsPerUsd) / 100

structure SolvencyReport where
  scenarioName     : String
  netCatLossEur    : Nat
  reinstCostEur    : Nat
  otherScrEur      : Nat
  totalScrEur      : Nat
  ownFundsEur      : Nat
  solvencyRatioPct : Nat
  isSolvent        : Bool
  deriving Repr

/-- Solvency ratio in percent, with `999` as the sentinel for a zero SCR.

Factored out of `evaluateSolvency` so the ratio arithmetic is proved once
instead of being re-derived through structure projections. -/
def solvencyRatioPct (ownFundsEur totalScrEur : Nat) : Nat :=
  if totalScrEur == 0 then 999 else (ownFundsEur * 100) / totalScrEur

/-- Simplified Solvency II Ratio evaluator:
    Total SCR = Net Stress Cat Loss + Reinstatement Premium Drag + Baseline Non-Cat SCR.
    Solvency Ratio < 100% indicates regulatory breach.

`999` is the sentinel for "no SCR at all": no capital requirement, no breach. -/
def evaluateSolvency
    (name : String)
    (ownFundsEur otherScrEur netCatLossEur reinstCostEur : Nat) : SolvencyReport :=
  let totalScr := netCatLossEur + reinstCostEur + otherScrEur
  { scenarioName     := name
    netCatLossEur    := netCatLossEur
    reinstCostEur    := reinstCostEur
    otherScrEur      := otherScrEur
    totalScrEur      := totalScr
    ownFundsEur      := ownFundsEur
    solvencyRatioPct := solvencyRatioPct ownFundsEur totalScr
    isSolvent        := solvencyRatioPct ownFundsEur totalScr ≥ 100 }

/-- Compact euro-millions formatting for the cockpit report. -/
def formatEurM (amount : Nat) : String :=
  let m := amount / 1_000_000
  let rem := (amount % 1_000_000) / 100_000
  s!"€{m}.{rem}M"

/-- FX quote formatting: integer cents per unit rendered as a two-decimal rate.

`80` prints `0.80`, `100` prints `1.00`. Without this, a parity quote would be
misreported as `0.100` — a formatting bug that reads like a pricing bug. -/
def formatFx (centsPerUnit : Nat) : String :=
  let whole := centsPerUnit / 100
  let frac := centsPerUnit % 100
  let fracStr := if frac < 10 then s!"0{frac}" else toString frac
  s!"{whole}.{fracStr}"

def SolvencyReport.pretty (r : SolvencyReport) : String :=
  let status := if r.isSolvent then "SOLVENT (OK)" else "REGULATORY BREACH (<100%)"
  s!"[{r.scenarioName}]\n" ++
  s!"  Net Cat Loss:      {formatEurM r.netCatLossEur}\n" ++
  s!"  Reinstatement Fee: {formatEurM r.reinstCostEur}\n" ++
  s!"  Total SCR:         {formatEurM r.totalScrEur} (Own Funds: {formatEurM r.ownFundsEur})\n" ++
  s!"  Solvency II Ratio: {r.solvencyRatioPct}% -> {status}"

/-! ## Proven properties of the ratio engine -/

/-- The reported total SCR is exactly the sum of its three components: the
cockpit can never print a total that disagrees with its own line items. -/
theorem evaluateSolvency_totalScr
    (name : String) (ownFundsEur otherScrEur netCatLossEur reinstCostEur : Nat) :
    (evaluateSolvency name ownFundsEur otherScrEur netCatLossEur reinstCostEur).totalScrEur =
      netCatLossEur + reinstCostEur + otherScrEur := rfl

/-- The reported solvency flag is exactly the reported ratio compared to 100%. -/
theorem evaluateSolvency_isSolvent_iff
    (name : String) (ownFundsEur otherScrEur netCatLossEur reinstCostEur : Nat) :
    (evaluateSolvency name ownFundsEur otherScrEur netCatLossEur reinstCostEur).isSolvent = true ↔
      (evaluateSolvency name ownFundsEur otherScrEur netCatLossEur reinstCostEur).solvencyRatioPct ≥ 100 := by
  simp [evaluateSolvency]

/-- With no SCR there is nothing to breach. -/
theorem solvencyRatioPct_zero_scr (ownFundsEur : Nat) :
    solvencyRatioPct ownFundsEur 0 = 999 := by
  simp [solvencyRatioPct]

/-- With a positive SCR the ratio is the plain integer percentage, rounded down. -/
theorem solvencyRatioPct_pos {ownFundsEur totalScrEur : Nat} (h : 0 < totalScrEur) :
    solvencyRatioPct ownFundsEur totalScrEur = ownFundsEur * 100 / totalScrEur := by
  unfold solvencyRatioPct
  have hz : (totalScrEur == 0) = false := by simp [Nat.ne_of_gt h]
  simp [hz]

/-- Adding capital never lowers the reported ratio. -/
theorem solvencyRatioPct_mono_ownFunds {a b totalScrEur : Nat} (h : a ≤ b) :
    solvencyRatioPct a totalScrEur ≤ solvencyRatioPct b totalScrEur := by
  by_cases hz : totalScrEur = 0
  · subst hz; simp [solvencyRatioPct_zero_scr]
  · rw [solvencyRatioPct_pos (Nat.pos_of_ne_zero hz),
        solvencyRatioPct_pos (Nat.pos_of_ne_zero hz)]
    exact Nat.div_le_div_right (Nat.mul_le_mul_right 100 h)

/-- Adding capital never makes a previously solvent company insolvent. -/
theorem evaluateSolvency_ratio_mono_ownFunds
    (name : String) (a b otherScrEur netCatLossEur reinstCostEur : Nat) (h : a ≤ b) :
    (evaluateSolvency name a otherScrEur netCatLossEur reinstCostEur).solvencyRatioPct ≤
      (evaluateSolvency name b otherScrEur netCatLossEur reinstCostEur).solvencyRatioPct := by
  simp only [evaluateSolvency]
  exact solvencyRatioPct_mono_ownFunds h

end ReinsuranceLeanCockpit
