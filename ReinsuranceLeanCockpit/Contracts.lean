import ReinsuranceLeanCockpit.Core

namespace ReinsuranceLeanCockpit

/-!
# General bound-contract schema and inductive tower proofs

v0.1 modelled two things: a stateful excess-of-loss treaty and a quota share.
v0.2 generalises both into a single `ContractKind` that a bound portfolio can
contain, adds the two forms that were missing (surplus share and aggregate stop
loss), and — the point of the module — proves the portfolio-level accounting
identity *by induction on the tower*, for a tower of arbitrary depth.

## Modelling decisions

* **All payouts are total.** `evalContractPayout` is defined for every contract
  and every loss; the validity predicate only gates the *theorems*, it does not
  create a partial function. That keeps `omega` able to reason about the
  composed tower.
* **Surplus share is modelled in amount terms.** A surplus share cedes the part
  of the loss above the retention line, up to `numLines` lines, i.e. the
  reinsurer takes the layer `numLines × retentionLine xs retentionLine`. This is
  the standard amount view of a surplus treaty and avoids a division that would
  make `≤ loss` depend on rounding. The proportional view `numLines/(numLines+1)`
  is what this layer converges to once the loss exhausts the capacity.
* **Reinstatements are inferred from the rate.** `ContractKind` carries
  `reinstRateBps` but no count; a zero rate means no reinstatement was
  purchased. The diagnostics module uses that reading.
-/

/-! ## Credit quality and direction -/

/-- Counterparty credit quality buckets, coarse enough to be defensible and
fine enough to distinguish a collateralised AAA panel from an unrated
collateral-free retrocessionaire. -/
inductive CreditRating where
  | AAA
  | AA
  | A
  | BBB
  | Unrated
  deriving Repr, DecidableEq, BEq

def CreditRating.toString : CreditRating → String
  | .AAA => "AAA"
  | .AA => "AA"
  | .A => "A"
  | .BBB => "BBB"
  | .Unrated => "Unrated"

instance : ToString CreditRating := ⟨CreditRating.toString⟩

/-- Solvency II-inspired deterministic counterparty default charge on expected
recoverables, in basis points of the recoverable amount. -/
def creditDefaultChargeBps : CreditRating → Nat
  | .AAA => 50
  | .AA => 150
  | .A => 300
  | .BBB => 800
  | .Unrated => 2500

/-- Is the counterparty in the categories that require an explicit capital
charge finding? `BBB` and `Unrated` are where a collateral clause stops being
a formality. -/
def CreditRating.isCliff : CreditRating → Bool
  | .BBB => true
  | .Unrated => true
  | _ => false

/-- `Inward` is business assumed; `Outward` is business ceded to a retrocessionaire. -/
inductive Direction where
  | inward
  | outward
  deriving Repr, DecidableEq, BEq

def Direction.toString : Direction → String
  | .inward => "inward"
  | .outward => "outward"

instance : ToString Direction := ⟨Direction.toString⟩

/-! ## Contract kinds -/

/-- The four composable bound-contract forms. -/
inductive ContractKind where
  /-- Excess of loss: `occLimit xs attachment`, aggregate capacity `aggLimit`,
      reinstatement premium at `reinstRateBps` of the base premium pro rata as
      to amount. -/
  | xol (attachment occLimit aggLimit reinstRateBps basePremium : Nat)
  /-- Quota share: `shareBps` of every loss, capped per event, with ceding
      commission at `commissionBps`. -/
  | quotaShare (shareBps eventCap commissionBps : Nat)
  /-- Surplus share: the layer `numLines × retentionLine xs retentionLine`,
      capped per event. -/
  | surplusShare (retentionLine numLines eventCap : Nat)
  /-- Aggregate stop loss: `aggLimit xs aggAttachment` on the annual net loss. -/
  | aggregateStopLoss (aggAttachment aggLimit : Nat)
  deriving Repr, DecidableEq, BEq

/-- Structural validity. Arithmetic validity (e.g. `shareBps ≤ 10000`) lives
here so that the meta-theorems can consume it as a hypothesis. -/
def ContractKind.isValid : ContractKind → Bool
  | .xol _ occLimit aggLimit _ _ => decide (occLimit ≤ aggLimit)
  | .quotaShare shareBps _ commissionBps =>
      decide (shareBps ≤ 10000) && decide (commissionBps ≤ 10000)
  | .surplusShare retentionLine numLines _ =>
      decide (0 < retentionLine) && decide (0 < numLines)
  | .aggregateStopLoss _ _ => true

/-- Largest amount payable by this contract on a single event, in contract
currency. An aggregate stop loss has no single-event limit — it responds to the
annual result — so it contributes zero here and is captured by
`aggregateCapacity` instead. Counting it in both places double-counts the same
cover in the exposure matrix. -/
def ContractKind.singleEventLimit : ContractKind → Nat
  | .xol _ occLimit _ _ _ => occLimit
  | .quotaShare _ eventCap _ => eventCap
  | .surplusShare retentionLine numLines eventCap =>
      min (numLines * retentionLine) eventCap
  | .aggregateStopLoss _ _ => 0

/-- Largest amount payable by this contract across the year, in contract currency. -/
def ContractKind.aggregateCapacity : ContractKind → Nat
  | .xol _ _ aggLimit _ _ => aggLimit
  | .quotaShare _ eventCap _ => eventCap
  | .surplusShare _ _ eventCap => eventCap
  | .aggregateStopLoss _ aggLimit => aggLimit

/-- Base premium under the contract, where the form has one explicitly. -/
def ContractKind.basePremium : ContractKind → Nat
  | .xol _ _ _ _ basePremium => basePremium
  | .quotaShare _ _ _ => 0
  | .surplusShare _ _ _ => 0
  | .aggregateStopLoss _ _ => 0

/-- Reinstatement premium rate in bps. Only excess-of-loss has one; the other
forms are annual agreements with no reinstatement mechanic. -/
def ContractKind.reinstRateBps : ContractKind → Nat
  | .xol _ _ _ rate _ => rate
  | _ => 0

/-! ## Bound contract -/

/-- A bound contract as it exists in a portfolio: identity, counterparty,
direction, currency, covered perils, inuring order and economics. -/
structure BoundContract where
  id : String
  name : String
  counterparty : String
  rating : CreditRating
  direction : Direction
  currency : Currency
  perils : List Peril
  inuringPriority : Nat
  kind : ContractKind
  deriving Repr

/-- A contract is valid when its economics are structurally sound. -/
def BoundContract.isValid (c : BoundContract) : Bool := c.kind.isValid

/-! ## Stateless payouts -/

/-- Surplus share payout: the layer `numLines × retentionLine xs retentionLine`,
per event.

For `loss ≤ retentionLine` nothing is ceded; above the retention the
reinsurer takes up to `numLines` lines, capped by the event limit. -/
def surplusPayout (retentionLine numLines eventCap loss : Nat) : Nat :=
  min (min (loss - retentionLine) (numLines * retentionLine)) eventCap

/-- Aggregate stop loss payout: `aggLimit xs aggAttachment` on the annual net loss. -/
def stopLossPayout (aggAttachment aggLimit annualNetLoss : Nat) : Nat :=
  min (annualNetLoss - aggAttachment) aggLimit

/-- Payout of one contract on one loss, given the aggregate capacity left. -/
def ContractKind.payout (k : ContractKind) (remAgg loss : Nat) : Nat :=
  match k with
  | .xol attachment occLimit aggLimit _ _ =>
      xolPayout loss attachment occLimit (min remAgg aggLimit)
  | .quotaShare shareBps eventCap _ => qsPayout loss shareBps eventCap
  | .surplusShare retentionLine numLines eventCap =>
      surplusPayout retentionLine numLines eventCap loss
  | .aggregateStopLoss aggAttachment aggLimit =>
      stopLossPayout aggAttachment aggLimit loss

def evalContractPayout (c : BoundContract) (remAgg loss : Nat) : Nat :=
  c.kind.payout remAgg loss

/-! ## Per-form bounds -/

/-- A surplus share never pays more than the loss. -/
theorem surplusPayout_le_loss (retentionLine numLines eventCap loss : Nat) :
    surplusPayout retentionLine numLines eventCap loss ≤ loss := by
  unfold surplusPayout
  omega

/-- An aggregate stop loss never pays more than the annual loss. -/
theorem stopLossPayout_le_loss (aggAttachment aggLimit annualNetLoss : Nat) :
    stopLossPayout aggAttachment aggLimit annualNetLoss ≤ annualNetLoss := by
  unfold stopLossPayout
  omega

/-- A surplus share is monotone in the loss. -/
theorem surplusPayout_mono (retentionLine numLines eventCap a b : Nat) (h : a ≤ b) :
    surplusPayout retentionLine numLines eventCap a ≤
      surplusPayout retentionLine numLines eventCap b := by
  unfold surplusPayout
  omega

/-- A surplus share is zero below the retention line. -/
theorem surplusPayout_zero_below (retentionLine numLines eventCap loss : Nat)
    (h : loss ≤ retentionLine) : surplusPayout retentionLine numLines eventCap loss = 0 := by
  unfold surplusPayout
  rw [Nat.sub_eq_zero_of_le h]
  omega

/-- An aggregate stop loss is zero below its attachment. -/
theorem stopLossPayout_zero_below (aggAttachment aggLimit annualNetLoss : Nat)
    (h : annualNetLoss ≤ aggAttachment) :
    stopLossPayout aggAttachment aggLimit annualNetLoss = 0 := by
  unfold stopLossPayout
  rw [Nat.sub_eq_zero_of_le h]
  omega

/-- Validity exposes the quota-share rate bound. -/
theorem isValid_quotaShare_shareBps {c : BoundContract} {shareBps eventCap commissionBps : Nat}
    (h : c.isValid = true) (hk : c.kind = .quotaShare shareBps eventCap commissionBps) :
    shareBps ≤ 10000 := by
  unfold BoundContract.isValid at h
  rw [hk] at h
  simp [ContractKind.isValid] at h
  exact h.1

/-- **Meta-theorem: every valid contract is bounded by the loss it is applied to.**

This is the single statement that makes a portfolio auditable: whatever the
contract form, the cedent cannot recover more than it lost, so no arrangement of
valid contracts can manufacture money. -/
theorem evalContractPayout_le_loss (c : BoundContract) (remAgg loss : Nat)
    (h : c.isValid = true) : evalContractPayout c remAgg loss ≤ loss := by
  unfold evalContractPayout
  cases hk : c.kind with
  | xol attachment occLimit aggLimit rate premium =>
      simp only [ContractKind.payout]
      exact xolPayout_le_loss loss attachment occLimit (min remAgg aggLimit)
  | quotaShare shareBps eventCap commissionBps =>
      have hs : shareBps ≤ 10000 := isValid_quotaShare_shareBps h hk
      simp only [ContractKind.payout]
      exact qsPayout_le_loss loss shareBps eventCap hs
  | surplusShare retentionLine numLines eventCap =>
      simp only [ContractKind.payout]
      exact surplusPayout_le_loss retentionLine numLines eventCap loss
  | aggregateStopLoss aggAttachment aggLimit =>
      simp only [ContractKind.payout]
      exact stopLossPayout_le_loss aggAttachment aggLimit loss

/-! ## The inuring tower -/

/-- Apply a list of contracts, in inuring order, to a gross loss.

Each contract sees the retained loss left by the ones before it — that is what
"inuring priority" means — and returns the pair `(netRetained, totalRecovered)`.

Defined by structural recursion rather than `foldl` so that the portfolio
theorem below is a genuine induction on the contract list. -/
def applyInuringTower : List (BoundContract × Nat) → Nat → Nat × Nat
  | [], grossLoss => (grossLoss, 0)
  | (c, remAgg) :: rest, grossLoss =>
      let paid := evalContractPayout c remAgg grossLoss
      let tail := applyInuringTower rest (grossLoss - paid)
      (tail.1, tail.2 + paid)

/-- **Inductive portfolio theorem: conservation of money across the tower.**

For any list of valid contracts — any depth, any mix of forms, any ordering —
net retained plus total recovered equals the gross loss exactly. Nothing is
created and nothing evaporates when a loss passes through a retrocession tower. -/
theorem applyInuringTower_conservation :
    ∀ (contracts : List (BoundContract × Nat)) (grossLoss : Nat),
      (∀ x ∈ contracts, x.1.isValid = true) →
      (applyInuringTower contracts grossLoss).1 +
        (applyInuringTower contracts grossLoss).2 = grossLoss
  | [], grossLoss, _ => by
      simp [applyInuringTower]
  | (c, remAgg) :: rest, grossLoss, h => by
      have hc : c.isValid = true := h (c, remAgg) (by simp)
      have hrest : ∀ x ∈ rest, x.1.isValid = true := fun x hx => h x (by simp [hx])
      have hb : evalContractPayout c remAgg grossLoss ≤ grossLoss :=
        evalContractPayout_le_loss c remAgg grossLoss hc
      have ih := applyInuringTower_conservation rest
        (grossLoss - evalContractPayout c remAgg grossLoss) hrest
      simp only [applyInuringTower]
      omega

/-- **Inductive portfolio theorem: no over-recovery.**

However deep the tower, total recoveries never exceed the gross loss. This is
the no-arbitrage statement a reinsurance programme has to satisfy. -/
theorem applyInuringTower_recovered_le :
    ∀ (contracts : List (BoundContract × Nat)) (grossLoss : Nat),
      (∀ x ∈ contracts, x.1.isValid = true) →
      (applyInuringTower contracts grossLoss).2 ≤ grossLoss
  | [], grossLoss, _ => by
      simp [applyInuringTower]
  | (c, remAgg) :: rest, grossLoss, h => by
      have hc : c.isValid = true := h (c, remAgg) (by simp)
      have hrest : ∀ x ∈ rest, x.1.isValid = true := fun x hx => h x (by simp [hx])
      have hb : evalContractPayout c remAgg grossLoss ≤ grossLoss :=
        evalContractPayout_le_loss c remAgg grossLoss hc
      have ih := applyInuringTower_recovered_le rest
        (grossLoss - evalContractPayout c remAgg grossLoss) hrest
      simp only [applyInuringTower]
      omega

/-- Net retained is itself bounded by the gross loss: a corollary that the
cockpit prints, and that follows from conservation plus no over-recovery. -/
theorem applyInuringTower_net_le (contracts : List (BoundContract × Nat)) (grossLoss : Nat)
    (h : ∀ x ∈ contracts, x.1.isValid = true) :
    (applyInuringTower contracts grossLoss).1 ≤ grossLoss := by
  have hcons := applyInuringTower_conservation contracts grossLoss h
  omega

end ReinsuranceLeanCockpit
