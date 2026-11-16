import ReinsuranceLeanCockpit.Simulation

namespace ReinsuranceLeanCockpit

/-!
# Monotonicity and antitonicity, proved for all losses

The UI bug report said the solvency ratio *rose* when a ground-up loss was
raised. Whether or not that particular reproduction was exact, it exposed a real
gap: nothing in the kernel said the simulator had to behave. This module closes
it.

Three layers of argument:

1. **Every contract form is monotone in the loss**, for both the payout and the
   net retained (loss minus payout). Payout slope is at most one, so net never
   decreases — this is the property that stops a bigger loss from being good
   news.
2. **The inuring tower preserves it**, by induction on the contract list:
   chaining non-decreasing functions is non-decreasing.
3. **Post-season capital and ratio are antitone in the drain**: more loss means
   less own funds and therefore a lower ratio, for a fixed requirement.

Nothing here is admitted or axiom-backed, and none of it assumes a particular portfolio.
-/

/-! ## 1. Per-contract monotonicity -/

theorem xolPayout_mono {l₁ l₂ : Nat} (h : l₁ ≤ l₂) (att occ rem : Nat) :
    xolPayout l₁ att occ rem ≤ xolPayout l₂ att occ rem := by
  unfold xolPayout
  omega

theorem netAfterXoL_mono {l₁ l₂ : Nat} (h : l₁ ≤ l₂) (att occ rem : Nat) :
    netAfterXoL l₁ att occ rem ≤ netAfterXoL l₂ att occ rem := by
  unfold netAfterXoL xolPayout
  omega

theorem applyStopLoss_mono {l₁ l₂ : Nat} (h : l₁ ≤ l₂) (att lim : Nat) :
    applyStopLoss l₁ att lim ≤ applyStopLoss l₂ att lim := by
  unfold applyStopLoss
  omega

theorem netAfterStopLoss_mono {l₁ l₂ : Nat} (h : l₁ ≤ l₂) (att lim : Nat) :
    netAfterStopLoss l₁ att lim ≤ netAfterStopLoss l₂ att lim := by
  unfold netAfterStopLoss applyStopLoss
  omega

theorem qsPayout_mono {l₁ l₂ : Nat} (h : l₁ ≤ l₂) (shareBps cap : Nat) :
    qsPayout l₁ shareBps cap ≤ qsPayout l₂ shareBps cap := by
  unfold qsPayout
  have hm : l₁ * shareBps ≤ l₂ * shareBps := Nat.mul_le_mul_right shareBps h
  have hd : l₁ * shareBps / 10000 ≤ l₂ * shareBps / 10000 :=
    Nat.div_le_div_right hm
  omega

/-- A quota share cannot make a bigger loss smaller after cession. The proof
needs the share bound: without `shareBps ≤ 10000` the retained loss would be
allowed to fall as the loss rises. -/
theorem netAfterQS_mono {l₁ l₂ : Nat} (h : l₁ ≤ l₂) (shareBps cap : Nat)
    (hShare : shareBps ≤ 10000) :
    l₁ - qsPayout l₁ shareBps cap ≤ l₂ - qsPayout l₂ shareBps cap := by
  unfold qsPayout
  have hMul : l₁ * shareBps ≤ l₂ * shareBps := Nat.mul_le_mul_right shareBps h
  have hSub : l₂ * shareBps - l₁ * shareBps ≤ (l₂ - l₁) * 10000 := by
    rw [← Nat.sub_mul]
    exact Nat.mul_le_mul_left (l₂ - l₁) hShare
  have hB1 : l₁ * shareBps ≤ l₁ * 10000 := Nat.mul_le_mul_left l₁ hShare
  have hB2 : l₂ * shareBps ≤ l₂ * 10000 := Nat.mul_le_mul_left l₂ hShare
  omega

theorem netAfterSurplus_mono {l₁ l₂ : Nat} (h : l₁ ≤ l₂) (retentionLine numLines eventCap : Nat) :
    l₁ - surplusPayout retentionLine numLines eventCap l₁ ≤
      l₂ - surplusPayout retentionLine numLines eventCap l₂ := by
  unfold surplusPayout
  omega

/-! ## 2. Contract-level, over all four forms -/

theorem evalContractPayout_mono (c : BoundContract) (rem : Nat) {l₁ l₂ : Nat}
    (h : l₁ ≤ l₂) (_hc : c.isValid = true) :
    evalContractPayout c rem l₁ ≤ evalContractPayout c rem l₂ := by
  unfold evalContractPayout
  cases hk : c.kind with
  | xol att occ agg rate prem =>
      simp only [ContractKind.payout]
      exact xolPayout_mono h att occ (min rem agg)
  | quotaShare shareBps eventCap commissionBps =>
      simp only [ContractKind.payout]
      exact qsPayout_mono h shareBps eventCap
  | surplusShare retentionLine numLines eventCap =>
      simp only [ContractKind.payout]
      exact surplusPayout_mono retentionLine numLines eventCap l₁ l₂ h
  | aggregateStopLoss aggAttachment aggLimit =>
      simp only [ContractKind.payout]
      unfold stopLossPayout
      omega

theorem evalContractNet_mono (c : BoundContract) (rem : Nat) {l₁ l₂ : Nat}
    (h : l₁ ≤ l₂) (hc : c.isValid = true) :
    l₁ - evalContractPayout c rem l₁ ≤ l₂ - evalContractPayout c rem l₂ := by
  unfold evalContractPayout
  cases hk : c.kind with
  | xol att occ agg rate prem =>
      simp only [ContractKind.payout]
      exact netAfterXoL_mono h att occ (min rem agg)
  | quotaShare shareBps eventCap commissionBps =>
      have hs : shareBps ≤ 10000 := isValid_quotaShare_shareBps hc hk
      simp only [ContractKind.payout]
      exact netAfterQS_mono h shareBps eventCap hs
  | surplusShare retentionLine numLines eventCap =>
      simp only [ContractKind.payout]
      exact netAfterSurplus_mono h retentionLine numLines eventCap
  | aggregateStopLoss aggAttachment aggLimit =>
      simp only [ContractKind.payout]
      exact netAfterStopLoss_mono h aggAttachment aggLimit

/-! ## 3. The inuring tower -/

/-- **Inductive tower monotonicity.** For any list of valid contracts, a bigger
gross loss leaves a bigger (or equal) net retained loss after the whole tower.

The step is composition, not slope arithmetic: each contract's net is
non-decreasing in its own input (`evalContractNet_mono`), and the tail of the
tower is non-decreasing by the induction hypothesis, so the chained function is
non-decreasing. -/
theorem applyInuringTower_net_mono :
    ∀ (contracts : List (BoundContract × Nat)) (g₁ g₂ : Nat),
      (∀ x ∈ contracts, x.1.isValid = true) → g₁ ≤ g₂ →
      (applyInuringTower contracts g₁).1 ≤ (applyInuringTower contracts g₂).1
  | [], g₁, g₂, _, h => by
      simpa [applyInuringTower] using h
  | (c, rem) :: rest, g₁, g₂, hv, h => by
      have hc : c.isValid = true := hv (c, rem) (by simp)
      have hrest : ∀ x ∈ rest, x.1.isValid = true := fun x hx => hv x (by simp [hx])
      have hstep : g₁ - evalContractPayout c rem g₁ ≤ g₂ - evalContractPayout c rem g₂ :=
        evalContractNet_mono c rem h hc
      simpa only [applyInuringTower] using
        applyInuringTower_net_mono rest
          (g₁ - evalContractPayout c rem g₁)
          (g₂ - evalContractPayout c rem g₂) hrest hstep

/-! ## 4. Post-season capital and solvency -/

/-- More drain, less capital. Truncated subtraction reverses the order. -/
theorem postSeasonOwnFunds_antitone {d₁ d₂ : Nat} (initialOwnFunds : Nat) (h : d₁ ≤ d₂) :
    postSeasonOwnFunds initialOwnFunds d₂ ≤ postSeasonOwnFunds initialOwnFunds d₁ := by
  unfold postSeasonOwnFunds
  omega

/-- For a fixed requirement, fewer own funds means a lower ratio. -/
theorem postSeasonRatio_antitone_num {f₁ f₂ scr : Nat} (h : f₂ ≤ f₁) :
    (if scr == 0 then 999 else f₂ * 100 / scr) ≤
      (if scr == 0 then 999 else f₁ * 100 / scr) := by
  by_cases hz : scr = 0
  · subst hz
    simp
  · have hz' : ¬ ((scr == 0) = true) := by
      intro hcon
      exact hz (by simpa using hcon)
    rw [ite_eq_right hz', ite_eq_right hz']
    exact Nat.div_le_div_right (Nat.mul_le_mul_right 100 h)

/-- A larger season drain lowers the ratio when the requirement is fixed. -/
theorem postSeasonRatio_antitone_fixedScr {initialOwnFunds scr d₁ d₂ : Nat} (h : d₁ ≤ d₂) :
    postSeasonRatio initialOwnFunds scr d₂ ≤ postSeasonRatio initialOwnFunds scr d₁ := by
  unfold postSeasonRatio
  exact postSeasonRatio_antitone_num (postSeasonOwnFunds_antitone initialOwnFunds h)

/-- **The headline invariant, in both directions.** A larger drain cannot raise
the ratio, and a larger capital requirement cannot lower it. Stated jointly
because a real book moves both: a season that consumes capital may also raise
the forward requirement, and the ratio must fall either way.

This is the statement the v0.3 UI contradicted. It now holds for every
portfolio, every scenario, every drain and every positive requirement. -/
theorem postSeasonRatio_antitone {initialOwnFunds scr₁ scr₂ d₁ d₂ : Nat}
    (hd : d₁ ≤ d₂) (hs : scr₁ ≤ scr₂) (hpos : 0 < scr₁) :
    postSeasonRatio initialOwnFunds scr₂ d₂ ≤ postSeasonRatio initialOwnFunds scr₁ d₁ := by
  unfold postSeasonRatio
  have hne₁ : ¬ ((scr₁ == 0) = true) := by
    intro h
    exact Nat.ne_of_gt hpos (by simpa using h)
  have hpos₂ : 0 < scr₂ := Nat.lt_of_lt_of_le hpos hs
  have hne₂ : ¬ ((scr₂ == 0) = true) := by
    intro h
    exact Nat.ne_of_gt hpos₂ (by simpa using h)
  rw [ite_eq_right hne₂, ite_eq_right hne₁]
  have hnum : (initialOwnFunds - d₂) * 100 ≤ (initialOwnFunds - d₁) * 100 :=
    Nat.mul_le_mul_right 100 (by omega)
  calc (initialOwnFunds - d₂) * 100 / scr₂
      ≤ (initialOwnFunds - d₁) * 100 / scr₂ := Nat.div_le_div_right hnum
    _ ≤ (initialOwnFunds - d₁) * 100 / scr₁ := Nat.div_le_div_left hs hpos

end ReinsuranceLeanCockpit
