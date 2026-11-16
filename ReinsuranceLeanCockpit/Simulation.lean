import ReinsuranceLeanCockpit.Validation
import ReinsuranceLeanCockpit.Diagnostics

namespace ReinsuranceLeanCockpit

/-!
# Multi-event catastrophe simulator (v0.4)

v0.3 priced each event against fresh, un-eroded aggregate limits and reported a
solvency ratio built on **pre-season** own funds. Both are wrong in the same
direction: a season with more loss looked no worse than a season with less,
because capital never moved.

v0.4 fixes the physics:

* **Aggregate limits erode across the season.** Each contract carries a
  remaining aggregate, initialised from its limit and reduced by every payout it
  makes. The second event of the year sees what the first one left.
* **Reinstatement premium is charged on what the layer actually pays.** Not on
  the event's gross loss, which over-charged towers with layers beneath.
* **Own funds erode.** After the season, capital is
  `initial − (net retained + reinstatement premium)`, truncated at zero, and the
  denominator is a *forward* capital requirement rather than the loss itself.

That last change is what makes the solvency curve behave: as loss rises, the
numerator falls and the denominator is at least flat, so the ratio can only fall.
`Monotonicity.lean` proves it.
-/

/-! ## Scenario vocabulary -/

structure ScenarioEvent where
  eventName : String
  peril : Peril
  currency : Currency
  /-- Ground-up market loss, in `currency`, at the portfolio's amount scale. -/
  groundUpLoss : Nat
  deriving Repr

structure StressScenario where
  scenarioName : String
  /-- Overrides the portfolio FX table where a currency is listed. -/
  fxOverridesToEurCents : List (Currency × Nat)
  events : List ScenarioEvent
  deriving Repr

/-! ## Stop loss arithmetic -/

/-- `aggLimit xs aggAttachment` on the annual net loss. -/
def applyStopLoss (annualNetLoss aggAttachment aggLimit : Nat) : Nat :=
  min (annualNetLoss - aggAttachment) aggLimit

def netAfterStopLoss (annualNetLoss aggAttachment aggLimit : Nat) : Nat :=
  annualNetLoss - applyStopLoss annualNetLoss aggAttachment aggLimit

theorem applyStopLoss_le_loss (annualNetLoss aggAttachment aggLimit : Nat) :
    applyStopLoss annualNetLoss aggAttachment aggLimit ≤ annualNetLoss := by
  unfold applyStopLoss
  omega

theorem applyStopLoss_bounded (annualNetLoss aggAttachment aggLimit : Nat) :
    applyStopLoss annualNetLoss aggAttachment aggLimit ≤ aggLimit := by
  unfold applyStopLoss
  omega

/-- The stop loss moves money, it does not make it. -/
theorem netAfterStopLoss_conservation (annualNetLoss aggAttachment aggLimit : Nat) :
    netAfterStopLoss annualNetLoss aggAttachment aggLimit +
      applyStopLoss annualNetLoss aggAttachment aggLimit = annualNetLoss := by
  unfold netAfterStopLoss applyStopLoss
  omega

/-! ## FX resolution -/

/-- Scenario override first, portfolio quote second. -/
def resolveFx (p : BoundPortfolio) (s : StressScenario) (c : Currency) : Nat :=
  (s.fxOverridesToEurCents.lookup c).getD (fxRate p c)

def toEurAt (p : BoundPortfolio) (s : StressScenario) (amount : Nat) (c : Currency) : Nat :=
  amount * resolveFx p s c / 100

/-- Convert between two contract currencies through EUR at the scenario's rates.
Same-currency conversion is the identity, so no rate is quoted to itself. -/
def convertAt (p : BoundPortfolio) (s : StressScenario)
    (src dst : Currency) (amount : Nat) : Nat :=
  if src == dst then amount
  else
    let eur := toEurAt p s amount src
    let rate := resolveFx p s dst
    if rate == 0 then 0 else eur * 100 / rate

/-! ## EUR view of a contract -/

/-- Re-express a contract's limits in EUR at the scenario's rates. The share in
basis points and the number of surplus lines are dimensionless and unchanged. -/
def eurKind (p : BoundPortfolio) (s : StressScenario)
    (k : ContractKind) (c : Currency) : ContractKind :=
  match k with
  | .xol att occ agg rate prem =>
      .xol (toEurAt p s att c) (toEurAt p s occ c) (toEurAt p s agg c) rate (toEurAt p s prem c)
  | .quotaShare shareBps eventCap comm =>
      .quotaShare shareBps (toEurAt p s eventCap c) comm
  | .surplusShare ret lines cap =>
      .surplusShare (toEurAt p s ret c) lines (toEurAt p s cap c)
  | .aggregateStopLoss att lim =>
      .aggregateStopLoss (toEurAt p s att c) (toEurAt p s lim c)

def eurView (p : BoundPortfolio) (s : StressScenario) (c : BoundContract) : BoundContract :=
  { c with currency := .EUR, kind := eurKind p s c.kind c.currency }

def isStopLoss (c : BoundContract) : Bool :=
  match c.kind with
  | .aggregateStopLoss _ _ => true
  | _ => false

def isXol (c : BoundContract) : Bool :=
  match c.kind with
  | .xol _ _ _ _ _ => true
  | _ => false

/-! ## Ordering -/

def insertSorted (le : α → α → Bool) (x : α) : List α → List α
  | [] => [x]
  | y :: ys => if le x y then x :: y :: ys else y :: insertSorted le x ys

def insertionSort (le : α → α → Bool) : List α → List α
  | [] => []
  | x :: xs => insertSorted le x (insertionSort le xs)

/-! ## Season state: remaining aggregate capacity -/

/-- Remaining aggregate capacity, keyed by contract id. Inward entries are in
the contract's own currency; outward entries are in EUR, because the outward
tower runs in the EUR view. The key spaces are disjoint, so one list serves
both. -/
abbrev AggState := List (String × Nat)

def initAggState (p : BoundPortfolio) (s : StressScenario) : AggState :=
  p.contracts.map fun c =>
    if c.direction == .outward then
      ((eurView p s c).id, (eurView p s c).kind.aggregateCapacity)
    else
      (c.id, c.kind.aggregateCapacity)

/-- Remaining capacity for a contract. A missing key reads as zero: an
uninitialised layer pays nothing, which fails closed rather than open. -/
def remainingFor (st : AggState) (id : String) : Nat :=
  (st.lookup id).getD 0

/-- Consume capacity. Aggregate limits only ever go down. -/
def erode (st : AggState) (id : String) (paid : Nat) : AggState :=
  st.map fun entry => if entry.1 == id then (entry.1, entry.2 - paid) else entry

/-! ## Event processing -/

/-- Inward gross assumed loss for one event, eroding each inward contract's
remaining aggregate as it pays. -/
def processInward (p : BoundPortfolio) (s : StressScenario)
    (e : ScenarioEvent) (st : AggState) : Nat × AggState :=
  (p.contracts.filter (fun c =>
      c.direction == .inward && c.isValid && c.perils.contains e.peril)).foldl
    (fun (acc : Nat × AggState) c =>
      let lossInCcy := convertAt p s e.currency c.currency e.groundUpLoss
      let rem := remainingFor acc.2 c.id
      let paid := evalContractPayout c rem lossInCcy
      (acc.1 + toEurAt p s paid c.currency, erode acc.2 c.id paid))
    (0, st)

/-- Outward non-stop-loss contracts covering the event, in EUR, in inuring order. -/
def outwardLayers (p : BoundPortfolio) (s : StressScenario) (e : ScenarioEvent) :
    List BoundContract :=
  insertionSort (fun a b => decide (a.inuringPriority ≤ b.inuringPriority))
    ((p.contracts.filter (fun c =>
        c.direction == .outward && c.perils.contains e.peril && !isStopLoss c)).map
      (fun c => eurView p s c))

/-- Reinstatement premium for a layer, charged **pro rata as to amount on what
the layer actually pays**: `paid / occLimit × basePremium × rate`. Charging it
on the pre-tower gross, as v0.3 did, over-charged every layer that had other
layers beneath it. -/
def feeFor (c : BoundContract) (paid : Nat) : Nat :=
  match c.kind with
  | .xol _ occ _ rate prem =>
      if occ == 0 || rate == 0 then 0 else paid * prem * rate / (occ * 10000)
  | _ => 0

structure TowerAcc where
  net : Nat
  paid : Nat
  fee : Nat
  state : AggState

/-- Run the outward tower on one event, threading eroded aggregate capacity and
accumulating each layer's own reinstatement fee. -/
def applyTowerStateful (cs : List BoundContract) (st : AggState) (gross : Nat) : TowerAcc :=
  cs.foldl
    (fun (acc : TowerAcc) c =>
      let rem := remainingFor acc.state c.id
      let p := evalContractPayout c rem acc.net
      { net := acc.net - p
        paid := acc.paid + p
        fee := acc.fee + feeFor c p
        state := erode acc.state c.id p })
    { net := gross, paid := 0, fee := 0, state := st }

structure EventSimulationResult where
  eventName : String
  peril : Peril
  currency : Currency
  groundUpLoss : Nat
  inwardGrossEur : Nat
  outwardRecoveredEur : Nat
  netRetainedEur : Nat
  reinstFeeEur : Nat
  deriving Repr

structure EventOutcome where
  result : EventSimulationResult
  state : AggState

def processEvent (p : BoundPortfolio) (s : StressScenario)
    (e : ScenarioEvent) (st : AggState) : EventOutcome :=
  let inw := processInward p s e st
  let tow := applyTowerStateful (outwardLayers p s e) inw.2 inw.1
  { result :=
      { eventName := e.eventName
        peril := e.peril
        currency := e.currency
        groundUpLoss := e.groundUpLoss
        inwardGrossEur := inw.1
        outwardRecoveredEur := tow.paid
        netRetainedEur := tow.net
        reinstFeeEur := tow.fee }
    state := tow.state }

/-- Process the season in event order, carrying aggregate capacity forward. -/
def runSeason (p : BoundPortfolio) (s : StressScenario) :
    List EventSimulationResult × AggState :=
  s.events.foldl
    (fun (acc : List EventSimulationResult × AggState) e =>
      let outcome := processEvent p s e acc.2
      (acc.1 ++ [outcome.result], outcome.state))
    ([], initAggState p s)

/-- Stop loss layers as (priority, attachment, limit), in inuring order. -/
def stopLossLayers (p : BoundPortfolio) (s : StressScenario) : List (Nat × Nat × Nat) :=
  insertionSort (fun a b => decide (a.1 ≤ b.1))
    ((p.contracts.filter (fun c => c.direction == .outward && isStopLoss c)).filterMap
      fun c =>
        match eurKind p s c.kind c.currency with
        | .aggregateStopLoss att lim => some (c.inuringPriority, att, lim)
        | _ => none)

def applyStopLossProgram (layers : List (Nat × Nat × Nat)) (netEur : Nat) : Nat × Nat :=
  layers.foldl
    (fun (n, rec) layer =>
      let r := applyStopLoss n layer.2.1 layer.2.2
      (n - r, rec + r))
    (netEur, 0)

/-! ## Post-season balance sheet -/

/-- Capital after the season: initial own funds less the realised drain. Exact
`Nat` subtraction, so an insolvent result clamps at zero rather than wrapping. -/
def postSeasonOwnFunds (initialOwnFundsEur drainEur : Nat) : Nat :=
  initialOwnFundsEur - drainEur

/-- Forward capital requirement after the season: ongoing risk + counterparty
default on recoverables + a stressed single-event buffer. It does not depend on
the loss that has already been realised — that loss belongs in the numerator. -/
def postSeasonScr (otherScrEur counterpartyScrEur maxSingleEventAppetiteEur : Nat) : Nat :=
  otherScrEur + counterpartyScrEur + maxSingleEventAppetiteEur

/-- Post-season ratio. The `999` sentinel survives from v0.1 for a zero SCR. -/
def postSeasonRatio (initialOwnFundsEur scrEur drainEur : Nat) : Nat :=
  if scrEur == 0 then 999
  else postSeasonOwnFunds initialOwnFundsEur drainEur * 100 / scrEur

/-! ## Report -/

structure ScenarioSimulationReport where
  scenarioName : String
  portfolioName : String
  allContractsValid : Bool
  validationErrors : List String
  events : List EventSimulationResult
  annualInwardGrossEur : Nat
  annualOutwardRecoveredEur : Nat
  annualNetBeforeStopLossEur : Nat
  stopLossRecoveredEur : Nat
  annualFinalNetLossEur : Nat
  totalReinstFeeEur : Nat
  counterpartyScrEur : Nat
  otherScrEur : Nat
  /-- Pre-season risk build-up, retained for the v0.2 identity. -/
  totalScrEur : Nat
  /-- Initial own funds before the season. -/
  initialOwnFundsEur : Nat
  /-- Backward-compatible alias for `initialOwnFundsEur`. -/
  ownFundsEur : Nat
  /-- `annualFinalNetLossEur + totalReinstFeeEur`. -/
  seasonLossDrainEur : Nat
  /-- `initial − drain`, truncated at zero. -/
  postSeasonOwnFundsEur : Nat
  /-- Forward requirement after the season. -/
  postSeasonScrEur : Nat
  /-- The pre-v0.4 ratio, kept for comparison. -/
  preSeasonSolvencyRatioPct : Nat
  /-- Headline: post-season capital over post-season requirement. -/
  solvencyRatioPct : Nat
  isSolvent : Bool
  deriving Repr

def runPortfolioScenario (p : BoundPortfolio) (s : StressScenario) : ScenarioSimulationReport :=
  let season := runSeason p s
  let results := season.1
  let gross := results.foldl (fun a r => a + r.inwardGrossEur) 0
  let recovered := results.foldl (fun a r => a + r.outwardRecoveredEur) 0
  let reinst := results.foldl (fun a r => a + r.reinstFeeEur) 0
  let netBefore := gross - recovered
  let sl := applyStopLossProgram (stopLossLayers p s) netBefore
  let finalNet := sl.1
  let cp := counterpartyScr p
  let drain := finalNet + reinst
  let postFunds := postSeasonOwnFunds p.ownFundsEur drain
  let postScr := postSeasonScr p.otherScrEur cp p.maxSingleEventAppetiteEur
  let ratio := postSeasonRatio p.ownFundsEur postScr drain
  let preScr := finalNet + reinst + cp + p.otherScrEur
  let preRatio := solvencyRatioPct p.ownFundsEur preScr
  { scenarioName := s.scenarioName
    portfolioName := p.name
    allContractsValid := isPortfolioValid p.contracts
    validationErrors := portfolioValidationErrors p.contracts
    events := results
    annualInwardGrossEur := gross
    annualOutwardRecoveredEur := recovered
    annualNetBeforeStopLossEur := netBefore
    stopLossRecoveredEur := sl.2
    annualFinalNetLossEur := finalNet
    totalReinstFeeEur := reinst
    counterpartyScrEur := cp
    otherScrEur := p.otherScrEur
    totalScrEur := preScr
    initialOwnFundsEur := p.ownFundsEur
    ownFundsEur := p.ownFundsEur
    seasonLossDrainEur := drain
    postSeasonOwnFundsEur := postFunds
    postSeasonScrEur := postScr
    preSeasonSolvencyRatioPct := preRatio
    solvencyRatioPct := ratio
    isSolvent := ratio ≥ 100 }

/-- **Pre-season SCR identity, preserved from v0.2.** The build-up total is
still exactly its four components. -/
theorem scenarioReport_scr_sum (p : BoundPortfolio) (s : StressScenario) :
    (runPortfolioScenario p s).totalScrEur =
      (runPortfolioScenario p s).annualFinalNetLossEur +
      (runPortfolioScenario p s).totalReinstFeeEur +
      (runPortfolioScenario p s).counterpartyScrEur +
      (runPortfolioScenario p s).otherScrEur := by
  unfold runPortfolioScenario
  rfl

/-- **Season drain identity.** The capital that leaves the balance sheet is the
net retained loss plus the reinstatement premium paid for it. -/
theorem scenarioReport_drain_eq (p : BoundPortfolio) (s : StressScenario) :
    (runPortfolioScenario p s).seasonLossDrainEur =
      (runPortfolioScenario p s).annualFinalNetLossEur +
        (runPortfolioScenario p s).totalReinstFeeEur := by
  unfold runPortfolioScenario
  rfl

/-- **Post-season capital identity.** Own funds after the season are initial
funds less the drain. -/
theorem scenarioReport_postFunds_eq (p : BoundPortfolio) (s : StressScenario) :
    (runPortfolioScenario p s).postSeasonOwnFundsEur =
      (runPortfolioScenario p s).initialOwnFundsEur -
        (runPortfolioScenario p s).seasonLossDrainEur := by
  unfold runPortfolioScenario postSeasonOwnFunds
  rfl

/-- The solvency flag is exactly the ratio test. -/
theorem scenarioReport_isSolvent_iff (p : BoundPortfolio) (s : StressScenario) :
    (runPortfolioScenario p s).isSolvent = true ↔
      (runPortfolioScenario p s).solvencyRatioPct ≥ 100 := by
  unfold runPortfolioScenario
  simp

end ReinsuranceLeanCockpit
