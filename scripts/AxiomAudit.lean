import ReinsuranceLeanCockpit

/-!
  Axiom audit. Every headline theorem must be kernel-checked from the core
  axioms alone. `#print axioms` reporting anything beyond `propext`,
  `Classical.choice` or `Quot.sound` means a proof leaned on something it
  should not have.

  Run with: `lake env lean scripts/AxiomAudit.lean`
-/

open ReinsuranceLeanCockpit

#print axioms xolPayout_le_loss
#print axioms xolPayout_bounded
#print axioms xol_loss_conservation
#print axioms qsPayout_le_loss
#print axioms stepXoLTreaty_agg_safe
#print axioms stepXoLTreaty_remAgg_le
#print axioms evaluateSolvency_totalScr
#print axioms evaluateSolvency_isSolvent_iff
#print axioms alpine_safe_at_inception_fx
#print axioms alpine_fixed_usd_bounded
#print axioms alpine_fixed_fx_safe

/-! ### v0.2 — general contracts, inductive towers, diagnostics -/

#print axioms surplusPayout_le_loss
#print axioms stopLossPayout_le_loss
#print axioms surplusPayout_mono
#print axioms surplusPayout_zero_below
#print axioms stopLossPayout_zero_below
#print axioms evalContractPayout_le_loss
#print axioms applyInuringTower_conservation
#print axioms applyInuringTower_recovered_le
#print axioms applyInuringTower_net_le
#print axioms portfolioStress_totalScr
#print axioms portfolioStress_isSolvent_iff
#print axioms counterpartyCharge_mono
#print axioms tally_sum
#print axioms auditPortfolio_totalFound
#print axioms auditPortfolio_counts_sum

/-! ### v0.3 — gatekeeper and simulator -/

#print axioms isPortfolioValid_nil
#print axioms isPortfolioValid_cons
#print axioms isPortfolioValid_forall
#print axioms validateContract_isEmpty_iff
#print axioms applyStopLoss_le_loss
#print axioms applyStopLoss_bounded
#print axioms netAfterStopLoss_conservation
#print axioms scenarioReport_scr_sum
#print axioms scenarioReport_isSolvent_iff

/-! ### v0.4 — monotonicity and post-season capital -/

#print axioms xolPayout_mono
#print axioms netAfterXoL_mono
#print axioms applyStopLoss_mono
#print axioms netAfterStopLoss_mono
#print axioms qsPayout_mono
#print axioms netAfterQS_mono
#print axioms netAfterSurplus_mono
#print axioms evalContractPayout_mono
#print axioms evalContractNet_mono
#print axioms applyInuringTower_net_mono
#print axioms postSeasonOwnFunds_antitone
#print axioms postSeasonRatio_antitone_num
#print axioms postSeasonRatio_antitone

/-! ### v0.4 trust boundary -/

#print axioms postSeasonRatio_antitone_fixedScr

#print axioms verified_NoOverRecovery
#print axioms verified_TowerMoneyConservation
#print axioms verified_ContractPayoutMonotone
#print axioms verified_TowerNetLossMonotone
#print axioms verified_PostSeasonSolvencyAntitone
#print axioms verified_GatekeeperExactness
#print axioms verified_AlpineUniversalFxFix
#print axioms verified_NonVacuityWitness

/-! ### completeness: every registry theorem is axiom-audited -/

#print axioms solvencyRatioPct_zero_scr
#print axioms solvencyRatioPct_pos
#print axioms solvencyRatioPct_mono_ownFunds
#print axioms evaluateSolvency_ratio_mono_ownFunds
#print axioms inward_agg_capacity_eq
#print axioms outward_agg_capacity_eq
#print axioms isValid_quotaShare_shareBps
#print axioms checkContractDetails_eq_nil_of_valid
#print axioms portfolioValidationErrors_nil

/-! ### v0.5 — US facultative desk -/

#print axioms proRataAlae_le_alae
#print axioms facIncluded_capped_by_share
#print axioms fac_no_overrecovery
#print axioms facIncremental_conservation
#print axioms facOverbill_reconciliation
#print axioms facJournal_balanced
#print axioms facVerified_le_cumulative
#print axioms facBilled_reconciles
#print axioms verified_FacNoOverRecovery
#print axioms verified_FacJournalBalanced

/-! ### v0.6 — paid vs OSLR, premium offset, multi-leg voucher -/

#print axioms netPremiumDue_le_gross
#print axioms paid_plus_endingOslr_eq_incurred
#print axioms cashSettlement_balanced
#print axioms oslrMovement_balanced
#print axioms fullFacVoucher_balanced
#print axioms verified_PaidOslrConservation
#print axioms verified_FacFullVoucherBalanced
