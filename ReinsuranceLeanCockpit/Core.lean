namespace ReinsuranceLeanCockpit

/-!
  Core primitives: currencies, perils, excess-of-loss and quota-share mechanics,
  and a stateful multi-event treaty with aggregate erosion and reinstatement
  premium.

  Every monetary quantity is an exact `Nat` in the contract's minor unit. Shares
  and rates are basis points (`10000` = 100%). No `Float` appears anywhere in
  the library, so every obligation below is decidable integer arithmetic that
  `omega` can discharge without Mathlib.
-/

/-! ## Currencies and perils -/

inductive Currency where
  | EUR | USD | GBP | JPY
  deriving Repr, DecidableEq, BEq

def Currency.toString : Currency → String
  | .EUR => "EUR"
  | .USD => "USD"
  | .GBP => "GBP"
  | .JPY => "JPY"

instance : ToString Currency := ⟨Currency.toString⟩

inductive Peril where
  | Windstorm | Earthquake | Flood | Cyber
  deriving Repr, DecidableEq, BEq

def Peril.toString : Peril → String
  | .Windstorm  => "Windstorm"
  | .Earthquake => "Earthquake"
  | .Flood      => "Flood"
  | .Cyber      => "Cyber"

instance : ToString Peril := ⟨Peril.toString⟩

/-- A single reported loss event, before any treaty application. -/
structure LossEvent where
  name          : String
  peril         : Peril
  currency      : Currency
  groundUpLoss  : Nat
  deriving Repr

/-! ## Stateless layer mechanics -/

/-- Excess of Loss (XoL) payout given loss, attachment, occurrence limit, and remaining aggregate limit.

The three-way `min` is deliberate: a layer is simultaneously capped by its own
occurrence limit and by whatever aggregate capacity is left in the treaty year. -/
def xolPayout (loss attachment occLimit remAggLimit : Nat) : Nat :=
  min (min (loss - attachment) occLimit) remAggLimit

/-- Net retained loss after ceding to an XoL layer. -/
def netAfterXoL (grossLoss attachment occLimit remAggLimit : Nat) : Nat :=
  grossLoss - xolPayout grossLoss attachment occLimit remAggLimit

/-- Quota Share payout given gross loss, share in basis points (0..10000), and event cap. -/
def qsPayout (loss shareBps eventCap : Nat) : Nat :=
  min ((loss * shareBps) / 10000) eventCap

/-- THEOREM 1 (No Over-Recovery on XoL): Payout never exceeds underlying loss. -/
theorem xolPayout_le_loss (loss attachment occLimit remAggLimit : Nat) :
    xolPayout loss attachment occLimit remAggLimit ≤ loss := by
  unfold xolPayout
  omega

/-- THEOREM 2 (Bounded Liability on XoL): Payout never exceeds occurrence or remaining aggregate limits. -/
theorem xolPayout_bounded (loss attachment occLimit remAggLimit : Nat) :
    xolPayout loss attachment occLimit remAggLimit ≤ occLimit ∧
    xolPayout loss attachment occLimit remAggLimit ≤ remAggLimit := by
  unfold xolPayout
  omega

/-- THEOREM 3 (Conservation of Money): Net Retained + Ceded Payout = Gross Loss.

This is the accounting identity that makes the cockpit reconcilable: the layer
cannot create or destroy currency, only move it between cedent and reinsurer. -/
theorem xol_loss_conservation (grossLoss attachment occLimit remAggLimit : Nat) :
    netAfterXoL grossLoss attachment occLimit remAggLimit +
    xolPayout grossLoss attachment occLimit remAggLimit = grossLoss := by
  unfold netAfterXoL xolPayout
  omega

/-- THEOREM 4 (No Over-Recovery on Quota Share when share ≤ 100%). -/
theorem qsPayout_le_loss (loss shareBps eventCap : Nat) (hShare : shareBps ≤ 10000) :
    qsPayout loss shareBps eventCap ≤ loss := by
  unfold qsPayout
  have hDiv : loss * shareBps / 10000 ≤ loss :=
    Nat.div_le_of_le_mul (by
      calc loss * shareBps ≤ loss * 10000 := Nat.mul_le_mul_left loss hShare
        _ = 10000 * loss := Nat.mul_comm _ _)
  omega

/-! ## Stateful multi-event treaty -/

/-- Stateful XoL Treaty supporting multi-event aggregate erosion and reinstatement premiums. -/
structure StatefulXoLTreaty where
  name          : String
  currency      : Currency
  attachment    : Nat
  occLimit      : Nat
  aggLimit      : Nat
  basePremium   : Nat
  reinstRateBps : Nat -- e.g., 10000 = 100% pro-rata as to amount
  perils        : List Peril
  deriving Repr

structure TreatyStepResult where
  payout               : Nat
  reinstatementPremium : Nat
  remainingAggLimit    : Nat
  deriving Repr

/-- Applies a single loss (already converted to treaty currency) to a stateful XoL treaty.

Reinstatement premium is charged pro rata as to amount:
`payout / occLimit × basePremium × reinstRateBps`. The `occLimit == 0` guard keeps
the division total; a zero-limit layer is a legal, if useless, contract. -/
def stepXoLTreaty (treaty : StatefulXoLTreaty) (remAgg : Nat) (peril : Peril) (lossInTreatyCcy : Nat) :
    TreatyStepResult :=
  if treaty.perils.contains peril then
    let payout := xolPayout lossInTreatyCcy treaty.attachment treaty.occLimit remAgg
    let remAgg' := remAgg - payout
    let reinstPrem :=
      if treaty.occLimit == 0 then 0
      else (payout * treaty.basePremium * treaty.reinstRateBps) / (treaty.occLimit * 10000)
    { payout := payout, reinstatementPremium := reinstPrem, remainingAggLimit := remAgg' }
  else
    { payout := 0, reinstatementPremium := 0, remainingAggLimit := remAgg }

/-- Runs a sequence of losses (in treaty currency) across a treaty year, tracking aggregate erosion. -/
def runXoLSeason (treaty : StatefulXoLTreaty) (events : List (Peril × Nat)) :
    Nat × Nat × Nat :=
  events.foldl
    (fun (totalPayout, totalReinstPrem, remAgg) (peril, loss) =>
      let res := stepXoLTreaty treaty remAgg peril loss
      (totalPayout + res.payout, totalReinstPrem + res.reinstatementPremium, res.remainingAggLimit))
    (0, 0, treaty.aggLimit)

/-- THEOREM 5 (Single-Step Aggregate Erosion Invariant): Remaining aggregate never increases and payout ≤ remAgg.

Stated in the strong form: payout and the remaining aggregate *partition* the
aggregate capacity that was available at the start of the step. Nothing leaks. -/
theorem stepXoLTreaty_agg_safe (treaty : StatefulXoLTreaty) (remAgg : Nat) (peril : Peril) (loss : Nat) :
    (stepXoLTreaty treaty remAgg peril loss).payout +
    (stepXoLTreaty treaty remAgg peril loss).remainingAggLimit = remAgg := by
  unfold stepXoLTreaty xolPayout
  split <;> simp <;> omega

/-- THEOREM 6 (Aggregate Never Grows): a step can only consume capacity. -/
theorem stepXoLTreaty_remAgg_le (treaty : StatefulXoLTreaty) (remAgg : Nat) (peril : Peril) (loss : Nat) :
    (stepXoLTreaty treaty remAgg peril loss).remainingAggLimit ≤ remAgg := by
  unfold stepXoLTreaty xolPayout
  split <;> simp <;> omega

end ReinsuranceLeanCockpit
