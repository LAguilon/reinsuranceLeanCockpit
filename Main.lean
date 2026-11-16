import ReinsuranceLeanCockpit

open ReinsuranceLeanCockpit
open Lean

/-!
  The cockpit CLI.

  Three modes:

  * `cockpit`                                  v0.1 Alpine report + Continental Re audit
  * `cockpit audit <path>`                     human report for any portfolio file
  * `cockpit audit <path> --json`              the verified audit report as JSON
-/

/-! ## Formatting helpers -/

def printExposureTable (title : String) (rows : List ExposureRow) : IO Unit := do
  IO.println title
  IO.println "  segment      inward      outward     net unhedged"
  for r in rows do
    IO.println s!"  {r.label}{String.ofList (List.replicate (13 - r.label.length) ' ')}{formatEurM r.inwardsEur}{String.ofList (List.replicate (13 - (formatEurM r.inwardsEur).length) ' ')}{formatEurM r.outwardsEur}{String.ofList (List.replicate (13 - (formatEurM r.outwardsEur).length) ' ')}{formatEurM r.netUnhedgedEur}"

def printStress (s : PortfolioStress) : IO Unit := do
  let status := if s.isSolvent then "SOLVENT (OK)" else "REGULATORY BREACH (<100%)"
  IO.println s!"  Scenario:          {s.scenarioName}"
  IO.println s!"  Net Cat Loss:      {formatEurM s.netCatLossEur}"
  IO.println s!"  Reinstatement Fee: {formatEurM s.reinstCostEur}"
  IO.println s!"  Counterparty SCR:  {formatEurM s.counterpartyScrEur}"
  IO.println s!"  Other SCR:         {formatEurM s.otherScrEur}"
  IO.println s!"  Total SCR:         {formatEurM s.totalScrEur} (Own Funds: {formatEurM s.ownFundsEur})"
  IO.println s!"  Solvency II Ratio: {s.solvencyRatioPct}% -> {status}"

def printFindings (fs : List LoopholeFinding) : IO Unit := do
  if fs.isEmpty then
    IO.println "  No structural findings."
  else
    for f in fs do
      IO.println s!"  [{f.severity}] {f.kind}  ({formatEurM f.amountEur})"
      IO.println s!"      {f.message}"

/-! ## Audit report -/

def printAudit (r : PortfolioAuditReport) : IO Unit := do
  IO.println "=================================================================="
  IO.println s!"  PORTFOLIO AUDIT: {r.portfolio}"
  IO.println s!"  {r.contractCount} bound contracts | {r.totalFound} findings ({r.criticalCount} CRITICAL, {r.warningCount} WARNING, {r.infoCount} INFO)"
  IO.println "=================================================================="
  IO.println ""
  printExposureTable "EXPOSURE BY CURRENCY (EUR, single-event limits)" r.exposureByCurrency
  IO.println ""
  printExposureTable "EXPOSURE BY PERIL (EUR, single-event limits)" r.exposureByPeril
  IO.println ""
  IO.println "------------------------------------------------------------------"
  IO.println "STRUCTURAL LOOPHOLES"
  IO.println "------------------------------------------------------------------"
  printFindings r.findings
  IO.println ""
  IO.println "------------------------------------------------------------------"
  IO.println "SOLVENCY II STRESS"
  IO.println "------------------------------------------------------------------"
  printStress r.stress
  IO.println "=================================================================="
  IO.println ""

def auditFile (path : String) (asJson : Bool) : IO Unit := do
  let p ← loadPortfolio path
  if asJson then
    IO.println (auditReportJson p)
  else
    printAudit (auditPortfolio p)

/-! ## v0.1 Alpine Re report (unchanged behaviour) -/

def printAlpineReport : IO Unit := do
  IO.println "=================================================================="
  IO.println "   REINSURANCE LEAN COCKPIT v0.4 - FORMAL PORTFOLIO AUDITOR"
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
  IO.println ""

/-! ## Default mode -/

def defaultReport : IO Unit := do
  printAlpineReport
  IO.println "##################################################################"
  IO.println "#  PHASE 2: DATA-DRIVEN BOUND PORTFOLIO AUDIT                    #"
  IO.println "##################################################################"
  IO.println ""
  let brokenPath := "examples/continental_re_portfolio.json"
  let fixedPath := "examples/continental_re_fixed.json"

  let broken ← loadPortfolio brokenPath
  let fixed ← loadPortfolio fixedPath

  printAudit (auditPortfolio broken)
  printAudit (auditPortfolio fixed)

  let rb := auditPortfolio broken
  let rf := auditPortfolio fixed
  IO.println "------------------------------------------------------------------"
  IO.println "BEFORE / AFTER"
  IO.println "------------------------------------------------------------------"
  IO.println s!"  As bound:      {rb.totalFound} findings, ratio {rb.stress.solvencyRatioPct}%"
  IO.println s!"  Restructured:  {rf.totalFound} findings, ratio {rf.stress.solvencyRatioPct}%"
  IO.println "=================================================================="

def printSimulation (r : ScenarioSimulationReport) : IO Unit := do
  IO.println "=================================================================="
  IO.println s!"  MULTI-EVENT STRESS: {r.scenarioName}"
  IO.println s!"  Portfolio: {r.portfolioName}"
  let gate := if r.allContractsValid then "VALID" else "GATEKEEPER REJECTED"
  IO.println s!"  Contract gate: {gate}"
  for e in r.validationErrors do
    IO.println s!"    [!] {e}"
  IO.println "=================================================================="
  IO.println "  event                                gross       recovered     net"
  for e in r.events do
    IO.println s!"  {e.eventName}{String.ofList (List.replicate (37 - min 36 e.eventName.length) ' ')}{formatEurM e.inwardGrossEur}      {formatEurM e.outwardRecoveredEur}      {formatEurM e.netRetainedEur}"
  IO.println ""
  IO.println s!"  Annual inward gross:        {formatEurM r.annualInwardGrossEur}"
  IO.println s!"  Outward recovered:          {formatEurM r.annualOutwardRecoveredEur}"
  IO.println s!"  Net before stop loss:       {formatEurM r.annualNetBeforeStopLossEur}"
  IO.println s!"  Stop loss recovered:        {formatEurM r.stopLossRecoveredEur}"
  IO.println s!"  Final net loss:             {formatEurM r.annualFinalNetLossEur}"
  IO.println s!"  Reinstatement drag:         {formatEurM r.totalReinstFeeEur}"
  IO.println s!"  Season loss drain:          {formatEurM r.seasonLossDrainEur}"
  IO.println ""
  IO.println s!"  Pre-season own funds:       {formatEurM r.initialOwnFundsEur}"
  IO.println s!"  Post-season own funds:      {formatEurM r.postSeasonOwnFundsEur}  (after realised drain)"
  IO.println s!"  Post-season SCR:            {formatEurM r.postSeasonScrEur}"
  IO.println s!"  Counterparty default SCR:   {formatEurM r.counterpartyScrEur} (inside post-season SCR)"
  IO.println s!"  Other SCR:                  {formatEurM r.otherScrEur} (inside post-season SCR)"
  let status := if r.isSolvent then "SOLVENT (OK)" else "REGULATORY BREACH (<100%)"
  IO.println s!"  Pre-season ratio:           {r.preSeasonSolvencyRatioPct}%"
  IO.println s!"  Post-season ratio:          {r.solvencyRatioPct}% -> {status}"
  IO.println "=================================================================="

def simulateFile (portfolioPath scenarioPath : String) (asJson : Bool) : IO Unit := do
  let p ← loadPortfolio portfolioPath
  let sc ← loadScenario scenarioPath
  if asJson then
    IO.println (Json.compress (ToJson.toJson (runPortfolioScenario p sc)))
  else
    printSimulation (runPortfolioScenario p sc)

def informalizeFile (path : String) : IO Unit := do
  let text ← IO.FS.readFile path
  match Json.parse text with
  | .error e => throw (IO.userError s!"{path}: invalid JSON: {e}")
  | .ok j =>
      match (fromJson? j : Except String BoundContract) with
      | .error e => throw (IO.userError s!"{path}: invalid contract: {e}")
      | .ok c => IO.println (informalizeContract c)

def printFacAudit (a : FacPortfolioAudit) : IO Unit := do
  IO.println "=================================================================="
  IO.println s!"  US FACULTATIVE XoL CASH-CALL AUDIT: {a.deskName}"
  IO.println s!"  {a.results.length} cash calls | {a.disputeCount} disputed | Ruschlikon codes shown"
  IO.println "=================================================================="
  for r in a.results do
    IO.println s!"  {r.certId} / {r.claimId}  [{r.acordResponseCode}] {r.verdict}"
    IO.println s!"      billed {usd r.cedentBilledNowUsd} | cash payable {usd r.grossCashPayableNowUsd} | over {usd r.overbilledUsd} | net wire {usd r.netCashWireDueUsd}"
    IO.println s!"      paid {usd r.ourCumulativePaidUsd} + ending OSLR {usd r.verifiedEndingOslrUsd} = incurred {usd r.ourCumulativeIncurredUsd}; premium offset {usd r.premiumOffsetUsd}"
    IO.println s!"      Leg A: debit paid claims {usd r.voucher.debitPaidClaimsExpenseUsd} = credit offset {usd r.voucher.creditPremiumReceivableOffsetUsd} + wire {usd r.voucher.creditCashWirePayableUsd}"
    IO.println s!"      Leg B: reserve movement {usd r.voucher.reserveTotalDebitUsd} on each side"
    IO.println s!"      {r.explanation}"
  IO.println ""
  IO.println s!"  TOTAL BILLED:       {usd a.totalBilledUsd}"
  IO.println s!"  TOTAL CASH VERIFIED:{usd a.totalVerifiedUsd}"
  IO.println s!"  LEAKAGE PREVENTED:  {usd a.totalOverbilledUsd}"
  IO.println s!"  PREMIUM OFFSET:     {usd a.totalPremiumOffsetUsd}"
  IO.println s!"  NET WIRE:           {usd a.totalNetWireUsd}"
  IO.println s!"  ENDING OSLR:        {usd a.totalEndingOslrUsd}"
  IO.println "=================================================================="

def facAuditFile (path : String) (asJson : Bool) : IO Unit := do
  let bundle ← loadFacBundle path
  let report := auditFacBundle bundle
  if asJson then
    IO.println (Json.compress (ToJson.toJson report))
  else
    printFacAudit report

def toNatOr (s : String) (default : Nat) : Nat :=
  match s.toNat? with
  | some n => n
  | none => default

def printGroupView (v : GroupView) : IO Unit := do
  let r := v.rollup
  IO.println "=================================================================="
  IO.println "  GROUP EXECUTIVE BRIDGE (USD desk -> EUR group)"
  IO.println "=================================================================="
  IO.println s!"  Claims: {r.totalClaimsCount} | STP auto-agreed: {r.stpAutoAgreedCount} ({r.stpRatePct}%)"
  IO.println s!"  Cedent billed:      {usd r.totalCedentBilledUsd}"
  IO.println s!"  Cash verified:      {usd r.totalGrossCashVerifiedUsd}  ({usd r.totalGrossCashVerifiedEur} cents EUR)"
  IO.println s!"  Leakage prevented:  {usd r.totalLeakagePreventedUsd}  ({usd r.totalLeakagePreventedEur} cents EUR)"
  IO.println s!"  Premium offset:     {usd r.totalPremiumOffsetRecoveredUsd}"
  IO.println s!"  Net wire:           {usd r.totalNetWireUsd}"
  IO.println s!"  Ending OSLR:        {usd r.totalEndingOslrBookedUsd}"
  IO.println s!"  Incurred booked:    {usd r.totalIncurredBookedUsd}"
  IO.println s!"  Group ratio:        {v.ratioPct}% -> protected {v.protectedRatioPct}% (own funds {usd v.ownFundsEur} -> {usd v.protectedOwnFundsEur})"
  IO.println ""
  IO.println s!"  CLASH FINDINGS: {v.clashes.length}"
  for c in v.clashes do
    IO.println s!"    [{c.kind}] {c.key}: lines {c.lines}, certs {c.certIds}, incurred {usd c.combinedIncurredUsd} (threshold {usd c.thresholdUsd}) exceeds={c.exceedsThreshold}"
  IO.println "=================================================================="

def groupViewFile (path own scr fx threshold : String) (asJson : Bool) : IO Unit := do
  let b ← loadFacBundle path
  let v := groupView b (toNatOr fx 92) (toNatOr own 120000000) (toNatOr scr 58924000) (toNatOr threshold 300000)
  if asJson then IO.println (Json.compress (ToJson.toJson v)) else printGroupView v

def printTheorems (asJson : Bool) : IO Unit := do
  if asJson then
    IO.println verifiedTheoremsJson
  else
    IO.println s!"{theoremCount} kernel-checked theorems (no unproved goals):"
    for t in verifiedTheorems do
      IO.println s!"  [{t.module}] {t.name}"
      IO.println s!"      {t.statement}"

def usage : IO Unit := do
  IO.println "usage:"
  IO.println "  cockpit                              full report (v0.1 case + Continental Re audit)"
  IO.println "  cockpit audit <portfolio.json>       human-readable audit of any portfolio"
  IO.println "  cockpit audit <portfolio.json> --json  machine-readable verified audit report"
  IO.println "  cockpit simulate <portfolio.json> <scenario.json> [--json]"
  IO.println "  cockpit theorems [--json]            kernel proof registry"
  IO.println "  cockpit informalize <contract.json>  Lean-to-English back-translation"
  IO.println "  cockpit fac-audit <bundle.json> [--json]  US facultative cash-call audit"
  IO.println "  cockpit group-view <bundle> <ownFunds> <scr> <fxCents> <threshold> [--json]"

def main (args : List String) : IO Unit := do
  match args with
  | [] => defaultReport
  | ["audit", path] => auditFile path false
  | ["audit", path, "--json"] => auditFile path true
  | ["simulate", portfolioPath, scenarioPath] => simulateFile portfolioPath scenarioPath false
  | ["simulate", portfolioPath, scenarioPath, "--json"] =>
      simulateFile portfolioPath scenarioPath true
  | ["informalize", path] => informalizeFile path
  | ["fac-audit", path] => facAuditFile path false
  | ["fac-audit", path, "--json"] => facAuditFile path true
  | ["group-view", path, own, scr, fx, threshold] => groupViewFile path own scr fx threshold false
  | ["group-view", path, own, scr, fx, threshold, "--json"] =>
      groupViewFile path own scr fx threshold true
  | ["theorems"] => printTheorems false
  | ["theorems", "--json"] => printTheorems true
  | _ => usage
