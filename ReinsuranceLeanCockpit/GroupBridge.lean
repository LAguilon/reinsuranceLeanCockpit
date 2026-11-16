import ReinsuranceLeanCockpit.Facultative
import ReinsuranceLeanCockpit.Solvency

namespace ReinsuranceLeanCockpit

/-!
# "One Hannover" executive bridge

The US desk works in dollars, certificate by certificate. Group management works
in euros, line by line, and asks two questions the desk cannot answer alone:

* **Clash.** Two lines can respond to the same occurrence — a workplace explosion
  that is both a Workers' Comp injury and a General Liability claim. Booked
  separately, each looks small. Booked together, they can breach a clash
  threshold that nobody was watching.
* **Roll-up.** What did the desk actually protect, in group currency, after
  premium offsets and case reserves?

Both answers are computed from the same `FacAuditResult` values the desk already
produced, so the executive view cannot disagree with the technical one.
-/

/-- A certificate and its claim. The audit result is a *function* of these two,
so the batch theorems can rewrite it and stay in sync with `auditFacClaim`. -/
structure FacAuditItem where
  cert : FacCertificate
  claim : FacClaimSubmission
  deriving Repr

def itemResult (i : FacAuditItem) : FacAuditResult := auditFacClaim i.cert i.claim

structure ClashFinding where
  /-- The shared occurrence tag, or the shared insured group. -/
  key : String
  kind : String
  lines : List String
  certIds : List String
  combinedIncurredUsd : Nat
  thresholdUsd : Nat
  exceedsThreshold : Bool
  deriving Repr

structure GroupRollup where
  totalClaimsCount : Nat
  stpAutoAgreedCount : Nat
  stpRatePct : Nat
  totalCedentBilledUsd : Nat
  totalGrossCashVerifiedUsd : Nat
  totalLeakagePreventedUsd : Nat
  totalPremiumOffsetRecoveredUsd : Nat
  totalNetWireUsd : Nat
  totalEndingOslrBookedUsd : Nat
  totalIncurredBookedUsd : Nat
  eurCentsPerUsd : Nat
  totalGrossCashVerifiedEur : Nat
  totalLeakagePreventedEur : Nat
  totalEndingOslrBookedEur : Nat
  deriving Repr

/-! ## Structural sums (recursive, so the theorems are inductions) -/

def totalBilled : List FacAuditItem → Nat
  | [] => 0
  | i :: rest => (itemResult i).cedentBilledNowUsd + totalBilled rest

def totalGrossCash : List FacAuditItem → Nat
  | [] => 0
  | i :: rest => (itemResult i).grossCashPayableNowUsd + totalGrossCash rest

def totalOffset : List FacAuditItem → Nat
  | [] => 0
  | i :: rest => (itemResult i).premiumOffsetUsd + totalOffset rest

def totalNetWire : List FacAuditItem → Nat
  | [] => 0
  | i :: rest => (itemResult i).netCashWireDueUsd + totalNetWire rest

def totalLeakage : List FacAuditItem → Nat
  | [] => 0
  | i :: rest => (itemResult i).overbilledUsd + totalLeakage rest

def totalEndingOslr : List FacAuditItem → Nat
  | [] => 0
  | i :: rest => (itemResult i).verifiedEndingOslrUsd + totalEndingOslr rest

def totalIncurred : List FacAuditItem → Nat
  | [] => 0
  | i :: rest => (itemResult i).ourCumulativeIncurredUsd + totalIncurred rest

def stpAutoAgreedCount : List FacAuditItem → Nat
  | [] => 0
  | i :: rest =>
      (if (itemResult i).ruschlikonStatus == .STP_AUTO_AGREED then 1 else 0) + stpAutoAgreedCount rest

def stpRatePct (items : List FacAuditItem) : Nat :=
  if items.length == 0 then 0 else stpAutoAgreedCount items * 100 / items.length

/-! ## Clash detection -/

def itemsWithTag (items : List FacAuditItem) (tag : String) : List FacAuditItem :=
  items.filter fun i => i.claim.clashEventTag == tag

def itemsWithGroup (items : List FacAuditItem) (group : String) : List FacAuditItem :=
  items.filter fun i => i.cert.insuredGroup == group

def clashTags (items : List FacAuditItem) : List String :=
  (items.filterMap fun i =>
    if i.claim.clashEventTag == "" then none else some i.claim.clashEventTag).eraseDups

def insuredGroups (items : List FacAuditItem) : List String :=
  (items.map fun i => i.cert.insuredGroup).eraseDups

def linesOf (items : List FacAuditItem) : List String :=
  (items.map fun i => i.cert.line.toString).eraseDups

def certIdsOf (items : List FacAuditItem) : List String :=
  items.map fun i => i.cert.certId

def findingFor (key kind : String) (items : List FacAuditItem) (thresholdUsd : Nat) : ClashFinding :=
  let incurred := totalIncurred items
  { key := key
    kind := kind
    lines := linesOf items
    certIds := certIdsOf items
    combinedIncurredUsd := incurred
    thresholdUsd := thresholdUsd
    exceedsThreshold := decide (thresholdUsd < incurred) }

/-- Clashes by shared occurrence tag, plus shared insured group across lines.
A tag is the stronger signal (an explicit catastrophe code); the group check
catches the same insured hit on two lines without a tag. -/
def detectFacClashes (items : List FacAuditItem) (thresholdUsd : Nat) : List ClashFinding :=
  let tagFindings :=
    (clashTags items).filterMap fun tag =>
      let group := itemsWithTag items tag
      if 2 ≤ group.length then some (findingFor tag "OCCURRENCE_TAG" group thresholdUsd) else none
  let groupFindings :=
    (insuredGroups items).filterMap fun g =>
      let group := itemsWithGroup items g
      if 2 ≤ group.length && 2 ≤ (linesOf group).length then
        some (findingFor g "INSURED_GROUP_MULTI_LINE" group thresholdUsd)
      else none
  tagFindings ++ groupFindings

/-! ## Executive roll-up -/

def computeExecutiveRollup (items : List FacAuditItem) (eurCentsPerUsd : Nat) : GroupRollup :=
  { totalClaimsCount := items.length
    stpAutoAgreedCount := stpAutoAgreedCount items
    stpRatePct := stpRatePct items
    totalCedentBilledUsd := totalBilled items
    totalGrossCashVerifiedUsd := totalGrossCash items
    totalLeakagePreventedUsd := totalLeakage items
    totalPremiumOffsetRecoveredUsd := totalOffset items
    totalNetWireUsd := totalNetWire items
    totalEndingOslrBookedUsd := totalEndingOslr items
    totalIncurredBookedUsd := totalIncurred items
    eurCentsPerUsd := eurCentsPerUsd
    totalGrossCashVerifiedEur := usdToEur (totalGrossCash items) eurCentsPerUsd
    totalLeakagePreventedEur := usdToEur (totalLeakage items) eurCentsPerUsd
    totalEndingOslrBookedEur := usdToEur (totalEndingOslr items) eurCentsPerUsd }

/-- Pair every claim in a bundle with its certificate and audit result. -/
def bundleItems (b : FacBundle) : List FacAuditItem :=
  b.claims.map fun s => { cert := lookupCert b.certificates s.certId, claim := s }

/-! ## Proofs -/

/-- STP cannot agree more claims than exist. -/
theorem stpCount_le_total (items : List FacAuditItem) :
    stpAutoAgreedCount items ≤ items.length := by
  induction items with
  | nil => simp [stpAutoAgreedCount]
  | cons i rest ih =>
      simp only [stpAutoAgreedCount, List.length_cons]
      split <;> omega

/-- The STP rate is a percentage: it cannot exceed 100. -/
theorem stpRatePct_le_100 (items : List FacAuditItem) (h : 0 < items.length) :
    stpRatePct items ≤ 100 := by
  have hz : ¬ ((items.length == 0) = true) := by
    intro hc
    exact Nat.ne_of_gt h (by simpa using hc)
  simp only [stpRatePct]
  rw [ite_eq_right hz]
  exact Nat.div_le_of_le_mul (Nat.mul_le_mul_right 100 (stpCount_le_total items))

/-- **Batch cash conservation.** Across any number of claims, the premium offset
plus the net wire equals the verified cash: the offset moves money between two
credits, it never creates or destroys a dollar. -/
theorem rollup_wire_plus_offset_le_verified (items : List FacAuditItem) :
    totalOffset items + totalNetWire items = totalGrossCash items := by
  induction items with
  | nil => rfl
  | cons i rest ih =>
      have hleg := cashSettlement_balanced i.cert i.claim
      simp only [totalOffset, totalNetWire, totalGrossCash, itemResult]
      omega

/-- The group view: the desk roll-up, its clashes, and the effect of the leak
prevented on group own funds. -/
structure GroupView where
  rollup : GroupRollup
  clashes : List ClashFinding
  ownFundsEur : Nat
  scrEur : Nat
  ratioPct : Nat
  protectedOwnFundsEur : Nat
  protectedRatioPct : Nat
  deriving Repr

def groupView (b : FacBundle) (eurCentsPerUsd ownFundsEur scrEur thresholdUsd : Nat) : GroupView :=
  let items := bundleItems b
  let rollup := computeExecutiveRollup items eurCentsPerUsd
  let protectedFunds := ownFundsEur + rollup.totalLeakagePreventedEur
  { rollup := rollup
    clashes := detectFacClashes items thresholdUsd
    ownFundsEur := ownFundsEur
    scrEur := scrEur
    ratioPct := solvencyRatioPct ownFundsEur scrEur
    protectedOwnFundsEur := protectedFunds
    protectedRatioPct := solvencyRatioPct protectedFunds scrEur }

/-- The protected capital is exactly initial own funds plus the leakage the desk
refused to pay. -/
theorem groupView_protected_eq (b : FacBundle) (fx own scr threshold : Nat) :
    (groupView b fx own scr threshold).protectedOwnFundsEur =
      own + (groupView b fx own scr threshold).rollup.totalLeakagePreventedEur := rfl

/-- **Leakage prevention cannot lower the group ratio.** Protecting capital can
only help solvency, never hurt it. -/
theorem groupView_protectedRatio_ge (b : FacBundle) (fx own scr threshold : Nat) :
    (groupView b fx own scr threshold).ratioPct ≤
      (groupView b fx own scr threshold).protectedRatioPct :=
  solvencyRatioPct_mono_ownFunds (Nat.le_add_right own _)

end ReinsuranceLeanCockpit
