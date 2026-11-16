import ReinsuranceLeanCockpit.TrustBoundary
import ReinsuranceLeanCockpit.Monotonicity

namespace ReinsuranceLeanCockpit

/-!
# Discharging the trust boundary

Every theorem here has the **exact type** of the corresponding `Spec_*` in
`TrustBoundary.lean`. No statement is restated, weakened or generalised: if a
`Spec_*` changes, these proofs stop compiling, which is precisely the alarm we
want.

The concrete witness for specification 8 is deliberately small and is checked by
`decide`, i.e. by the kernel evaluating the actual payout function on actual
numbers. That is what rules out the vacuity trap.
-/

/-- A concrete, valid outward excess-of-loss layer used to witness non-vacuity:
40,000,000 xs 10,000,000, aggregate 80,000,000, rated AA. -/
def witnessContract : BoundContract :=
  { id := "WITNESS-XOL"
    name := "Witness XoL"
    counterparty := "Witness Re"
    rating := .AA
    direction := .outward
    currency := .USD
    perils := [.Windstorm]
    inuringPriority := 0
    kind := .xol 10000000 40000000 80000000 0 1000000 }

theorem verified_NoOverRecovery : Spec_NoOverRecovery :=
  fun c rem loss h => evalContractPayout_le_loss c rem loss h

theorem verified_TowerMoneyConservation : Spec_TowerMoneyConservation :=
  fun contracts gross h =>
    ⟨applyInuringTower_conservation contracts gross h,
     applyInuringTower_recovered_le contracts gross h⟩

theorem verified_ContractPayoutMonotone : Spec_ContractPayoutMonotone :=
  fun c rem _ _ hc h => evalContractPayout_mono c rem h hc

theorem verified_TowerNetLossMonotone : Spec_TowerNetLossMonotone :=
  fun contracts _ _ h hle => applyInuringTower_net_mono contracts _ _ h hle

theorem verified_PostSeasonSolvencyAntitone : Spec_PostSeasonSolvencyAntitone :=
  fun _ _ _ _ _ hd hs hpos => postSeasonRatio_antitone hd hs hpos

theorem verified_GatekeeperExactness : Spec_GatekeeperExactness :=
  fun c => validateContract_isEmpty_iff c

theorem verified_AlpineUniversalFxFix : Spec_AlpineUniversalFxFix :=
  fun lossUsd fx hfx => alpine_fixed_fx_safe lossUsd fx hfx

/-- The witness pays 30,000,000 on a 40,000,000 loss, and the kernel can compute
that. `decide` here evaluates the real function, not a restatement of it. -/
theorem verified_NonVacuityWitness : Spec_NonVacuityWitness :=
  ⟨witnessContract, by decide, by decide⟩

theorem verified_FacNoOverRecovery : Spec_FacNoOverRecovery :=
  fun c ind alae h => fac_no_overrecovery c ind alae h

theorem verified_FacJournalBalanced : Spec_FacJournalBalanced :=
  fun c s => facJournal_balanced c s

theorem verified_PaidOslrConservation : Spec_PaidOslrConservation :=
  fun c s => paid_plus_endingOslr_eq_incurred c s

theorem verified_FacFullVoucherBalanced : Spec_FacFullVoucherBalanced :=
  fun c s => fullFacVoucher_balanced c s

end ReinsuranceLeanCockpit
