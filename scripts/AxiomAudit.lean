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
