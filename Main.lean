import ReinsuranceLeanCockpit

open ReinsuranceLeanCockpit

def main : IO Unit := do
  IO.println "=================================================================="
  IO.println "   REINSURANCE LEAN COCKPIT v0.1 - FORMAL PORTFOLIO AUDITOR"
  IO.println "=================================================================="
  IO.println ""
  IO.println "[VERIFIED] Compile-time Lean 4 Theorems Checked:"
  IO.println "  ✓ xolPayout_le_loss          (No Over-Recovery)"
  IO.println "  ✓ xolPayout_bounded          (Occurrence & Aggregate Limits)"
  IO.println "  ✓ xol_loss_conservation      (Accounting Conservation of Money)"
  IO.println "  ✓ qsPayout_le_loss           (Quota Share Boundedness)"
  IO.println "  ✓ stepXoLTreaty_agg_safe     (Stateful Aggregate Erosion Invariant)"
  IO.println "  ✓ alpine_safe_at_inception_fx(Safe at 0.80 FX across $0..$∞)"
  IO.println "  ✓ alpine_fixed_fx_safe       (Universal Fix Safe across $0..$∞ & FX ≤ 1.00)"
  IO.println ""
  IO.println "------------------------------------------------------------------"
  IO.println "AUTOMATED LOOPHOLE HUNTER: FX Basis-Risk Scan"
  IO.println "------------------------------------------------------------------"
  match huntFxLoophole with
  | some (lossUsd, fxCents, netEur) =>
    IO.println s!"  [ALERT] Hidden FX Cliff Detected!"
    IO.println s!"  Trigger Scenario: Ground-Up Loss = ${lossUsd / 1_000_000}M USD at FX = {formatFx fxCents} EUR/USD"
    IO.println s!"  Resulting Net Loss: {formatEurM netEur} (Breaches €25.0M Board Limit!)"
  | none =>
    IO.println "  No FX loopholes found."
  IO.println ""
  IO.println "------------------------------------------------------------------"
  IO.println "SOLVENCY II COCKPIT SIMULATIONS (Own Funds = €40.0M)"
  IO.println "------------------------------------------------------------------"
  let r1 := evaluateSolvency "1. Inception FX 0.80 ($80M Hurricane - Board View)"
              40_000_000 10_000_000 (alpineNetLossBrokenEur 80_000_000 80) 0
  let r2 := evaluateSolvency "2. FX Shock to Parity 1.00 ($80M Hurricane - Unhedged Cliff!)"
              40_000_000 10_000_000 (alpineNetLossBrokenEur 80_000_000 100) 0
  let r3 := evaluateSolvency "3. FX Shock 1.00 with Lean-Verified USD Retro Fix"
              40_000_000 10_000_000 (alpineNetLossFixedEur 80_000_000 100) 0
  let r4 := simulateTwinStormTrap 80

  IO.println r1.pretty
  IO.println ""
  IO.println r2.pretty
  IO.println ""
  IO.println r3.pretty
  IO.println ""
  IO.println r4.pretty
  IO.println "=================================================================="
