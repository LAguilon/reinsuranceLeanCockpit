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
