import ReinsuranceLeanCockpit.Contracts
import ReinsuranceLeanCockpit.Solvency

namespace ReinsuranceLeanCockpit

/-!
# Exposure aggregation, static loophole scanning, extended Solvency II

Two jobs live here.

1. **Exposure.** Turn a bound portfolio into numbers a board can read: gross
   inwards, outward retrocession and the unhedged peak, split by currency and
   by peril.

2. **The static scanner.** Five structural anomalies that no single-scenario
   spreadsheet reveals, each classified by severity, each with the euro amount
   at stake. The scanner is a pure function of the portfolio: same file in,
   same findings out.

All arithmetic is exact `Nat`. Conversions to EUR round down, the conservative
direction for a capital charge.
-/

/-! ## Portfolio -/

/-- A bound portfolio as it sits on the balance sheet. -/
structure BoundPortfolio where
  name : String
  ownFundsEur : Nat
  otherScrEur : Nat
  maxSingleEventAppetiteEur : Nat
  /-- EUR cents per 100 minor units of the currency. `EUR = 100` is identity. -/
  fxRatesToEurCents : List (Currency × Nat)
  contracts : List BoundContract
  deriving Repr

/-- FX lookup. Defaults to parity for EUR and to zero for an unquoted currency;
a zero rate makes the exposure visibly disappear rather than silently survive. -/
def fxRate (p : BoundPortfolio) (c : Currency) : Nat :=
  (p.fxRatesToEurCents.lookup c).getD (if c = .EUR then 100 else 0)

/-- Convert a contract-currency amount to EUR cents, rounding down. -/
def toEur (p : BoundPortfolio) (amount : Nat) (c : Currency) : Nat :=
  amount * fxRate p c / 100

/-! ## Exposure matrix -/

structure ExposureRow where
  label : String
  inwardsEur : Nat
  outwardsEur : Nat
  netUnhedgedEur : Nat
  deriving Repr

def sumOver (p : BoundPortfolio) (keep : BoundContract → Bool) (f : BoundContract → Nat) : Nat :=
  (p.contracts.filter keep).foldl (fun acc c => acc + f c) 0

def inwardsOf (p : BoundPortfolio) (keep : BoundContract → Bool) : Nat :=
  sumOver p (fun c => keep c && c.direction == .inward)
    (fun c => toEur p c.kind.singleEventLimit c.currency)

def outwardsOf (p : BoundPortfolio) (keep : BoundContract → Bool) : Nat :=
  sumOver p (fun c => keep c && c.direction == .outward)
    (fun c => toEur p c.kind.singleEventLimit c.currency)

def rowFor (p : BoundPortfolio) (label : String) (keep : BoundContract → Bool) : ExposureRow :=
  let i := inwardsOf p keep
  let o := outwardsOf p keep
  { label := label, inwardsEur := i, outwardsEur := o, netUnhedgedEur := i - o }

def exposuresByCurrency (p : BoundPortfolio) : List ExposureRow :=
  [.EUR, .USD, .GBP, .JPY].map fun c =>
    rowFor p c.toString (fun k => k.currency == c)

def exposuresByPeril (p : BoundPortfolio) : List ExposureRow :=
  [.Windstorm, .Earthquake, .Flood, .Cyber].map fun pr =>
    rowFor p pr.toString (fun k => k.perils.contains pr)

/-- Largest single-event unhedged exposure across perils. Used as the stress
loss for the Solvency II cockpit, so the scenario is derived from the portfolio
rather than typed in by hand. -/
def maxNetExposure (p : BoundPortfolio) : Nat :=
  (exposuresByPeril p).foldl (fun m r => max m r.netUnhedgedEur) 0

/-- Deterministic reinstatement drag: if every outward layer reinstates once at
its stated rate, this is the premium the cedent pays for it. -/
def outwardReinstDrag (p : BoundPortfolio) : Nat :=
  (p.contracts.filter (fun c => c.direction == .outward)).foldl
    (fun acc c => acc + toEur p (c.kind.basePremium * c.kind.reinstRateBps / 10000) c.currency) 0

/-! ## Findings -/

inductive Severity where
  | CRITICAL
  | WARNING
  | INFO
  deriving Repr, DecidableEq, BEq

def Severity.toString : Severity → String
  | .CRITICAL => "CRITICAL"
  | .WARNING => "WARNING"
  | .INFO => "INFO"

instance : ToString Severity := ⟨Severity.toString⟩

structure LoopholeFinding where
  severity : Severity
  kind : String
  message : String
  amountEur : Nat
  deriving Repr

/-! ## Extended Solvency II -/

/-- Counterparty default SCR on expected outward recoverables, per rating bucket. -/
def counterpartyScr (p : BoundPortfolio) : Nat :=
  (p.contracts.filter (fun c => c.direction == .outward)).foldl
    (fun acc c =>
      acc + toEur p c.kind.aggregateCapacity c.currency * creditDefaultChargeBps c.rating / 10000) 0

/-- A portfolio stress: the deterministic build-up plus counterparty default. -/
structure PortfolioStress where
  scenarioName : String
  netCatLossEur : Nat
  reinstCostEur : Nat
  otherScrEur : Nat
  counterpartyScrEur : Nat
  totalScrEur : Nat
  ownFundsEur : Nat
  solvencyRatioPct : Nat
  isSolvent : Bool
  deriving Repr

def portfolioStress (p : BoundPortfolio) (scenarioName : String)
    (netCatLossEur reinstCostEur : Nat) : PortfolioStress :=
  let cp := counterpartyScr p
  let total := netCatLossEur + reinstCostEur + p.otherScrEur + cp
  let ratio := solvencyRatioPct p.ownFundsEur total
  { scenarioName := scenarioName
    netCatLossEur := netCatLossEur
    reinstCostEur := reinstCostEur
    otherScrEur := p.otherScrEur
    counterpartyScrEur := cp
    totalScrEur := total
    ownFundsEur := p.ownFundsEur
    solvencyRatioPct := ratio
    isSolvent := ratio ≥ 100 }

/-- **SCR sum conservation.** The printed total is exactly the four components
the cockpit prints: cat, reinstatement drag, baseline non-cat, counterparty
default. The report cannot disagree with its own line items. -/
theorem portfolioStress_totalScr (p : BoundPortfolio) (name : String)
    (netCatLossEur reinstCostEur : Nat) :
    (portfolioStress p name netCatLossEur reinstCostEur).totalScrEur =
      netCatLossEur + reinstCostEur + p.otherScrEur + counterpartyScr p := rfl

/-- The solvency flag is exactly "ratio at or above 100%". -/
theorem portfolioStress_isSolvent_iff (p : BoundPortfolio) (name : String)
    (netCatLossEur reinstCostEur : Nat) :
    (portfolioStress p name netCatLossEur reinstCostEur).isSolvent = true ↔
      (portfolioStress p name netCatLossEur reinstCostEur).solvencyRatioPct ≥ 100 := by
  simp [portfolioStress]

/-- Counterparty charge is monotone in the recoverable amount: a bigger
retrocession programme never carries a smaller default charge. -/
theorem counterpartyCharge_mono (amount cap charge : Nat) (h : amount ≤ cap) :
    amount * charge / 10000 ≤ cap * charge / 10000 :=
  Nat.div_le_div_right (Nat.mul_le_mul_right charge h)

/-! ## Static loophole scanner -/

/-- An outward excess-of-loss layer flattened into the geometry the tower checks
need: attachment, occurrence limit and aggregate capacity. -/
structure LayerView where
  contract : BoundContract
  attachment : Nat
  occLimit : Nat
  aggLimit : Nat
  deriving Repr

def xolLayers (p : BoundPortfolio) (dir : Direction) : List LayerView :=
  (p.contracts.filter (fun c => c.direction == dir)).filterMap fun c =>
    match c.kind with
    | .xol att occ agg _ _ =>
        some { contract := c, attachment := att, occLimit := occ, aggLimit := agg }
    | _ => none

/-- Unordered pairs drawn from a list, in list order. -/
def crossPairs : List α → List (α × α)
  | [] => []
  | x :: xs => xs.map (fun y => (x, y)) ++ crossPairs xs

def sharesPeril (a b : BoundContract) : Bool :=
  a.perils.any (fun pr => b.perils.contains pr)

def currencyList (cs : List Currency) : String :=
  String.intercalate "/" (cs.map (fun c => c.toString))

/-- Is there any excess-of-loss capacity that would reinstate on this peril? -/
def hasReinstatement (c : BoundContract) : Bool := c.kind.reinstRateBps > 0

def aggregateIn (p : BoundPortfolio) (pr : Peril) (dir : Direction) : Nat :=
  (p.contracts.filter (fun c => c.direction == dir && c.perils.contains pr)).foldl
    (fun acc c => acc + toEur p c.kind.aggregateCapacity c.currency) 0

def singleEventIn (p : BoundPortfolio) (pr : Peril) (dir : Direction) : Nat :=
  (p.contracts.filter (fun c => c.direction == dir && c.perils.contains pr)).foldl
    (fun acc c => acc + toEur p c.kind.singleEventLimit c.currency) 0

/-- Is there a third outward layer sandwiched between `lo` and `hi` in the same
tower? Only adjacent layers may be judged: reporting `L1 -> L3` as a gap when
`L2` fills the space between them is a false positive that would discredit every
finding the scanner makes. -/
def hasIntermediate (lo hi : LayerView) (layers : List LayerView) : Bool :=
  layers.any fun k =>
    k.contract.id != lo.contract.id && k.contract.id != hi.contract.id &&
    k.contract.currency == lo.contract.currency &&
    k.contract.inuringPriority == lo.contract.inuringPriority &&
    lo.attachment < k.attachment && k.attachment < hi.attachment

/-- **Vertical tower geometry.** Two *adjacent* outward XoL layers at the same
inuring priority, on a shared peril and currency: a gap between them leaves the
cedent carrying an unhedged slice; an overlap pays twice for the same limit. -/
def towerFindings (p : BoundPortfolio) : List LoopholeFinding :=
  let layers := xolLayers p .outward
  (crossPairs layers).filterMap fun (x, y) =>
    if x.contract.currency != y.contract.currency then none
    else if x.contract.inuringPriority != y.contract.inuringPriority then none
    else if !(sharesPeril x.contract y.contract) then none
    else if x.attachment == y.attachment then none
    else
      let lo := if x.attachment < y.attachment then x else y
      let hi := if x.attachment < y.attachment then y else x
      let top := lo.attachment + lo.occLimit
      if hasIntermediate lo hi layers then none
      else if top < hi.attachment then
        some { severity := .CRITICAL
               kind := "VerticalTowerGap"
               message := s!"{lo.contract.id} ends at {formatEurM top} but {hi.contract.id} attaches at {formatEurM hi.attachment}: unhedged vertical gap"
               amountEur := toEur p (hi.attachment - top) lo.contract.currency }
      else if hi.attachment < top then
        some { severity := .WARNING
               kind := "VerticalTowerOverlap"
               message := s!"{hi.contract.id} attaches at {formatEurM hi.attachment}, inside {lo.contract.id} which runs to {formatEurM top}: overlapping limit"
               amountEur := toEur p (top - hi.attachment) lo.contract.currency }
      else none

/-- **Currency basis mismatch.** A peril written inward in one currency and
retroceded in another. The exposure is not reduced, only translated. -/
def currencyFindings (p : BoundPortfolio) : List LoopholeFinding :=
  [.Windstorm, .Earthquake, .Flood, .Cyber].filterMap fun pr =>
    let inw := p.contracts.filter (fun c => c.direction == .inward && c.perils.contains pr)
    let out := p.contracts.filter (fun c => c.direction == .outward && c.perils.contains pr)
    if inw.isEmpty || out.isEmpty then none
    else
      let inCur := inw.map (fun c => c.currency)
      let outCur := out.map (fun c => c.currency)
      if inCur.all (fun c => outCur.contains c) then none
      else
        some { severity := .CRITICAL
               kind := "CurrencyBasisMismatch"
               message := s!"{pr} is written in {currencyList inCur} but retroceded in {currencyList outCur}; {formatEurM (singleEventIn p pr .inward)} of single-event inward cover is untranslated"
               amountEur := singleEventIn p pr .inward }

/-- **Aggregate exhaustion mismatch.** Inward aggregate capacity that the
outward programme cannot absorb, or an inward layer that reinstates onto an
outward layer that does not. -/
def aggregateFindings (p : BoundPortfolio) : List LoopholeFinding :=
  [.Windstorm, .Earthquake, .Flood, .Cyber].filterMap fun pr =>
    let inw := p.contracts.filter (fun c => c.direction == .inward && c.perils.contains pr)
    let out := p.contracts.filter (fun c => c.direction == .outward && c.perils.contains pr)
    if inw.isEmpty then none
    else
      let inAgg := aggregateIn p pr .inward
      let outAgg := aggregateIn p pr .outward
      let gap := inAgg - outAgg
      let reinstDeficit := inw.any hasReinstatement && !(out.any hasReinstatement)
      if gap > p.maxSingleEventAppetiteEur * 2 || reinstDeficit then
        let detail :=
          if reinstDeficit && gap == 0 then
            s!"{formatEurM inAgg} of inward aggregate sits on a layer with no reinstating outward cover"
          else
            s!"inward aggregate {formatEurM inAgg} vs outward {formatEurM outAgg}; uncovered {formatEurM gap}"
        some { severity := if reinstDeficit then .CRITICAL else .WARNING
               kind := "AggregateExhaustionMismatch"
               message := s!"{pr}: {detail} (appetite cap {formatEurM (p.maxSingleEventAppetiteEur * 2)})"
               amountEur := if reinstDeficit && gap == 0 then inAgg else gap }
      else none

/-- **Counterparty credit cliff.** Outward recoverables sitting with a BBB or
unrated counterparty, with the Solvency II default charge quantified. -/
def counterpartyFindings (p : BoundPortfolio) : List LoopholeFinding :=
  (p.contracts.filter (fun c => c.direction == .outward)).filterMap fun c =>
    if c.rating.isCliff then
      let recov := toEur p c.kind.aggregateCapacity c.currency
      some { severity := if c.rating == .Unrated then .CRITICAL else .WARNING
             kind := "CounterpartyCreditCliff"
             message := s!"{c.id} placed with {c.counterparty} ({c.rating}); recoverable {formatEurM recov} carries a {creditDefaultChargeBps c.rating} bps default charge"
             amountEur := recov * creditDefaultChargeBps c.rating / 10000 }
    else none

/-- The full scan. Order is stable, so the report is reproducible. -/
def scanPortfolioLoopholes (p : BoundPortfolio) : List LoopholeFinding :=
  towerFindings p ++ currencyFindings p ++ aggregateFindings p ++ counterpartyFindings p

/-! ## Audit report -/

structure PortfolioAuditReport where
  portfolio : String
  contractCount : Nat
  exposureByCurrency : List ExposureRow
  exposureByPeril : List ExposureRow
  findings : List LoopholeFinding
  stress : PortfolioStress
  criticalCount : Nat
  warningCount : Nat
  infoCount : Nat
  totalFound : Nat
  deriving Repr

/-- One-pass severity tally. A single traversal, so the three counts and the
total cannot drift apart. -/
def tally : List LoopholeFinding → Nat × Nat × Nat
  | [] => (0, 0, 0)
  | f :: fs =>
      let t := tally fs
      match f.severity with
      | .CRITICAL => (t.1 + 1, t.2.1, t.2.2)
      | .WARNING => (t.1, t.2.1 + 1, t.2.2)
      | .INFO => (t.1, t.2.1, t.2.2 + 1)

/-- **Severity counts partition the findings.** Whatever the scan returns, the
three severity buckets add up to the number of findings reported. -/
theorem tally_sum (fs : List LoopholeFinding) :
    (tally fs).1 + (tally fs).2.1 + (tally fs).2.2 = fs.length := by
  induction fs with
  | nil => rfl
  | cons f rest ih =>
      simp only [tally, List.length_cons]
      split <;> simp <;> omega

/-- Audit a portfolio: exposure matrix, findings, and the stressed Solvency II
position. The stress loss is the portfolio's own maximum unhedged single-event
exposure, so the scenario cannot drift away from the book. -/
def auditPortfolio (p : BoundPortfolio) : PortfolioAuditReport :=
  let fs := scanPortfolioLoopholes p
  let t := tally fs
  { portfolio := p.name
    contractCount := p.contracts.length
    exposureByCurrency := exposuresByCurrency p
    exposureByPeril := exposuresByPeril p
    findings := fs
    stress := portfolioStress p
      "Static stress: max unhedged single-event exposure, full reinstatement drag"
      (maxNetExposure p) (outwardReinstDrag p)
    criticalCount := t.1
    warningCount := t.2.1
    infoCount := t.2.2
    totalFound := fs.length }

/-- The report's finding count is the length of its own finding list. -/
theorem auditPortfolio_totalFound (p : BoundPortfolio) :
    (auditPortfolio p).totalFound = (scanPortfolioLoopholes p).length := rfl

/-- The severity counts partition the finding list exactly. -/
theorem auditPortfolio_counts_sum (p : BoundPortfolio) :
    (auditPortfolio p).criticalCount + (auditPortfolio p).warningCount +
      (auditPortfolio p).infoCount = (auditPortfolio p).totalFound := by
  unfold auditPortfolio
  exact tally_sum (scanPortfolioLoopholes p)

end ReinsuranceLeanCockpit
