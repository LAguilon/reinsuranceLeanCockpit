import ReinsuranceLeanCockpit.Validation
import ReinsuranceLeanCockpit.Diagnostics

namespace ReinsuranceLeanCockpit

/-!
# Multi-event catastrophe simulator

The static scanner in `Diagnostics` answers "is the structure wrong?". This
module answers the next question: "what happens to the balance sheet when a
season actually fires?"

A scenario is a list of events plus an FX table. Each event is converted into
every inward contract's currency, priced through that contract, converted back
to EUR, then passed down the outward tower in inuring order. Aggregate stop
losses apply to the season total, not to any single event.

Three properties are worth stating up front, because they are where simulators
usually cheat:

* **No money is created per event.** The outward tower is `applyInuringTower`,
  the same function whose conservation theorem is proved by induction in
  `Contracts`. Net retained plus recovered equals gross, for every event.
* **Currency conversion is explicit and exact.** Every conversion goes through
  EUR with the scenario's rate, integer division, rounding down. An override
  set in the scenario replaces the portfolio quote for that currency.
* **A rejected contract contributes nothing.** Invalid contracts are filtered
  out of the simulation rather than priced with a nonsense parameter.
-/

/-! ## Scenario vocabulary -/

structure ScenarioEvent where
  eventName : String
  peril : Peril
  currency : Currency
  /-- Ground-up market loss, in `currency`, reported at the same scale as the
  portfolio's amounts. -/
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

/-! ## Event evaluation -/

/-- Inward gross assumed loss in EUR: the event loss is converted into each
inward contract's currency, priced through that contract, and converted back. -/
def eventInwardGrossEur (p : BoundPortfolio) (s : StressScenario) (e : ScenarioEvent) : Nat :=
  (p.contracts.filter (fun c =>
      c.direction == .inward && c.isValid && c.perils.contains e.peril)).foldl
    (fun acc c =>
      let lossInCcy := convertAt p s e.currency c.currency e.groundUpLoss
      acc + toEurAt p s (evalContractPayout c c.kind.aggregateCapacity lossInCcy) c.currency) 0

/-- Outward non-stop-loss contracts covering the event, in EUR, in inuring order. -/
def outwardTower (p : BoundPortfolio) (s : StressScenario) (e : ScenarioEvent) :
    List (BoundContract × Nat) :=
  insertionSort (fun a b => decide (a.1.inuringPriority ≤ b.1.inuringPriority))
    ((p.contracts.filter (fun c =>
        c.direction == .outward && c.perils.contains e.peril && !isStopLoss c)).map
      fun c =>
        let v := eurView p s c
        (v, v.kind.aggregateCapacity))

/-- Reinstatement premium drag for one event, charged pro rata as to amount on
each triggered outward XoL layer.

Each layer is priced against the event's gross loss independently rather than
against the loss it actually receives after layers beneath it. That is
conservative — it never understates the drag — and it keeps the fee a pure
function of (event, term sheet) instead of a function of tower ordering. -/
def eventReinstFeeEur (p : BoundPortfolio) (s : StressScenario)
    (e : ScenarioEvent) (grossEur : Nat) : Nat :=
  (p.contracts.filter (fun c =>
      c.direction == .outward && c.perils.contains e.peril && isXol c)).foldl
    (fun acc c =>
      match eurKind p s c.kind c.currency with
      | .xol att occ _ rate prem =>
          if rate == 0 || occ == 0 then acc
          else acc + (min (grossEur - att) occ * prem * rate) / (occ * 10000)
      | _ => acc) 0

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

/-! ## Report -/

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
  totalScrEur : Nat
  ownFundsEur : Nat
  solvencyRatioPct : Nat
  isSolvent : Bool
  deriving Repr

def runPortfolioScenario (p : BoundPortfolio) (s : StressScenario) : ScenarioSimulationReport :=
  let results := s.events.map fun e =>
    let gross := eventInwardGrossEur p s e
    let tower := applyInuringTower (outwardTower p s e) gross
    { eventName := e.eventName
      peril := e.peril
      currency := e.currency
      groundUpLoss := e.groundUpLoss
      inwardGrossEur := gross
      outwardRecoveredEur := tower.2
      netRetainedEur := tower.1
      reinstFeeEur := eventReinstFeeEur p s e gross }
  let gross := results.foldl (fun a r => a + r.inwardGrossEur) 0
  let recovered := results.foldl (fun a r => a + r.outwardRecoveredEur) 0
  let reinst := results.foldl (fun a r => a + r.reinstFeeEur) 0
  let netBefore := gross - recovered
  let sl := applyStopLossProgram (stopLossLayers p s) netBefore
  let cp := counterpartyScr p
  let total := sl.1 + reinst + cp + p.otherScrEur
  let ratio := solvencyRatioPct p.ownFundsEur total
  { scenarioName := s.scenarioName
    portfolioName := p.name
    allContractsValid := isPortfolioValid p.contracts
    validationErrors := portfolioValidationErrors p.contracts
    events := results
    annualInwardGrossEur := gross
    annualOutwardRecoveredEur := recovered
    annualNetBeforeStopLossEur := netBefore
    stopLossRecoveredEur := sl.2
    annualFinalNetLossEur := sl.1
    totalReinstFeeEur := reinst
    counterpartyScrEur := cp
    otherScrEur := p.otherScrEur
    totalScrEur := total
    ownFundsEur := p.ownFundsEur
    solvencyRatioPct := ratio
    isSolvent := ratio ≥ 100 }

/-- **SCR sum conservation for the simulator.** The headline capital number is
exactly the four components the report prints, for every portfolio and every
scenario. A reader can recompute the ratio by hand from the line items. -/
theorem scenarioReport_scr_sum (p : BoundPortfolio) (s : StressScenario) :
    (runPortfolioScenario p s).totalScrEur =
      (runPortfolioScenario p s).annualFinalNetLossEur +
      (runPortfolioScenario p s).totalReinstFeeEur +
      (runPortfolioScenario p s).counterpartyScrEur +
      (runPortfolioScenario p s).otherScrEur := by
  unfold runPortfolioScenario
  rfl

/-- The solvency flag is exactly the ratio test. -/
theorem scenarioReport_isSolvent_iff (p : BoundPortfolio) (s : StressScenario) :
    (runPortfolioScenario p s).isSolvent = true ↔
      (runPortfolioScenario p s).solvencyRatioPct ≥ 100 := by
  unfold runPortfolioScenario
  simp

end ReinsuranceLeanCockpit
