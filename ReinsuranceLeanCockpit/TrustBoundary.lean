import ReinsuranceLeanCockpit.Core
import ReinsuranceLeanCockpit.Contracts
import ReinsuranceLeanCockpit.Validation
import ReinsuranceLeanCockpit.Simulation
import ReinsuranceLeanCockpit.AlpineShowcase

/-!
# Trust boundary: the eight statements a human should audit

This file is the answer to "what, exactly, did you prove?". It contains **no
proofs at all** — only named `Prop` specifications in plain mathematics, each
with a docstring an actuary can check without reading Lean. `TrustProofs.lean`
discharges every one of them against the implementation.

If a statement here is wrong, the proofs below are irrelevant: they prove the
wrong theorem. That is the point of separating the two files. Read this one.

AlpineShowcase is imported because specification 7 is about the FX case study;
it contributes definitions only, no proof obligations.
-/

namespace ReinsuranceLeanCockpit

/-- **1. No over-recovery.** No valid contract of any form can pay more than the
loss it is applied to. This is the no-arbitrage floor: a portfolio of valid
contracts cannot manufacture a recovery larger than the loss. -/
def Spec_NoOverRecovery : Prop :=
  ∀ (c : BoundContract) (rem loss : Nat), c.isValid = true →
    evalContractPayout c rem loss ≤ loss

/-- **2. Conservation across a tower.** For any list of valid contracts, in any
order and of any depth: net retained plus total recovered equals the gross loss,
and total recovered does not exceed it. Nothing is created or destroyed when a
loss passes through retrocession. -/
def Spec_TowerMoneyConservation : Prop :=
  ∀ (contracts : List (BoundContract × Nat)) (gross : Nat),
    (∀ x ∈ contracts, x.1.isValid = true) →
      (applyInuringTower contracts gross).1 + (applyInuringTower contracts gross).2 = gross ∧
      (applyInuringTower contracts gross).2 ≤ gross

/-- **3. Payout monotonicity.** For every valid contract, a larger loss never
produces a smaller recovery. This is the property whose absence produced the
v0.3 simulator symptom. -/
def Spec_ContractPayoutMonotone : Prop :=
  ∀ (c : BoundContract) (rem l₁ l₂ : Nat), c.isValid = true → l₁ ≤ l₂ →
    evalContractPayout c rem l₁ ≤ evalContractPayout c rem l₂

/-- **4. Tower monotonicity.** For any valid tower, a larger gross loss leaves a
larger (or equal) net retained loss after every contract has responded. -/
def Spec_TowerNetLossMonotone : Prop :=
  ∀ (contracts : List (BoundContract × Nat)) (g₁ g₂ : Nat),
    (∀ x ∈ contracts, x.1.isValid = true) → g₁ ≤ g₂ →
      (applyInuringTower contracts g₁).1 ≤ (applyInuringTower contracts g₂).1

/-- **5. Post-season solvency antitonicity.** More loss cannot improve solvency:
a larger capital drain lowers the ratio, and a larger requirement lowers it
further. Stated jointly because a real season moves both. -/
def Spec_PostSeasonSolvencyAntitone : Prop :=
  ∀ (own scr₁ scr₂ d₁ d₂ : Nat), d₁ ≤ d₂ → scr₁ ≤ scr₂ → 0 < scr₁ →
    postSeasonRatio own scr₂ d₂ ≤ postSeasonRatio own scr₁ d₁

/-- **6. Gatekeeper exactness.** Ingestion admits a contract precisely when it
satisfies the `isValid` hypothesis that specifications 1–4 consume. Parsing and
proving cannot drift apart. -/
def Spec_GatekeeperExactness : Prop :=
  ∀ (c : BoundContract), (validateContract c).isEmpty = c.isValid

/-- **7. Universal FX fix.** The restructured Alpine Re portfolio stays under
25,000,000 EUR for every loss and every FX rate at or below parity. -/
def Spec_AlpineUniversalFxFix : Prop :=
  ∀ (lossUsd fx : Nat), fx ≤ 100 → alpineNetLossFixedEur lossUsd fx ≤ 25_000_000

/-- **8. Non-vacuity witness.** There exists at least one valid contract that
actually pays something. Without this, every specification above would be
satisfied by a predicate that is never true — Buzzard's vacuity trap. -/
def Spec_NonVacuityWitness : Prop :=
  ∃ (c : BoundContract), c.isValid = true ∧ evalContractPayout c 50_000_000 40_000_000 > 0

end ReinsuranceLeanCockpit
