import ReinsuranceLeanCockpit.Facultative
import ReinsuranceLeanCockpit.Acord

namespace ReinsuranceLeanCockpit

/-!
# Typed subjectivity and the four-eyes settlement gate

Arithmetic can decide an ALAE allocation. It cannot decide whether a hammer
clause was triggered, whether a declaratory-judgment fee is covered, or whether a
loss falls inside the policy period. Those are **subjective**: they require two
named humans from different functions — a claims examiner and a technical
accountant — to sign the same requirement before cash leaves the building. In
German insurance practice this is the `Vier-Augen-Prinzip`; in controls language
it is segregation of duties.

The model is deliberately small and total:

* a requirement is an inductive value carrying the claim it belongs to;
* an attestation is valid only if it is approved, both names are present, and
  the two names differ;
* a claim is cleared only if every requirement has a valid attestation;
* the settlement gate blocks disputed or invalid claims outright, releases only
  when everything is attested, and otherwise holds.

The four theorems in this module are the control itself: self-approval can never
count, an unattested requirement always holds the wire, a disputed claim is never
authorized, and a clean claim with no subjectivity is released.
-/

/-- A subjective requirement attached to a claim. -/
inductive FacSubjectivity where
  | declaratoryJudgmentFee (claimId : String)
  | hammerConsentToSettle (claimId : String)
  | punitiveDamagesReview (claimId : String)
  | policyPeriodCertification (claimId : String)
  deriving Repr, DecidableEq, BEq

/-- Two named humans, two functions, one decision. -/
structure FourEyesAttestation where
  subjectivity : FacSubjectivity
  claimsExaminer : String
  technicalAccountant : String
  approved : Bool
  deriving Repr, DecidableEq, BEq

/-- A valid attestation is approved, has both names, and they are different
people. Empty names are treated as missing: an unattributed sign-off is not a
sign-off. -/
def FourEyesAttestation.isValidSegregation (a : FourEyesAttestation) : Bool :=
  a.approved && (a.claimsExaminer != "") && (a.technicalAccountant != "") &&
    (a.claimsExaminer != a.technicalAccountant)

/-- A requirement is cleared when some attestation for it is valid. -/
def isSubjectivityCleared (s : FacSubjectivity) (atts : List FourEyesAttestation) : Bool :=
  atts.any (fun a => (a.subjectivity == s) && a.isValidSegregation)

/-- Every requirement must be cleared. An empty requirement list is trivially
cleared. -/
def allSubjectivitiesCleared (reqs : List FacSubjectivity)
    (atts : List FourEyesAttestation) : Bool :=
  reqs.all (fun s => isSubjectivityCleared s atts)

/-- What the desk is allowed to do with the claim. -/
inductive SettlementGate where
  | RELEASE_WIRE_AUTHORIZED
  | HOLD_FOUR_EYES_REQUIRED
  | BLOCKED_BY_DISPUTE_OR_INVALID
  deriving Repr, DecidableEq, BEq

def SettlementGate.toString : SettlementGate → String
  | .RELEASE_WIRE_AUTHORIZED => "RELEASE_WIRE_AUTHORIZED"
  | .HOLD_FOUR_EYES_REQUIRED => "HOLD_FOUR_EYES_REQUIRED"
  | .BLOCKED_BY_DISPUTE_OR_INVALID => "BLOCKED_BY_DISPUTE_OR_INVALID"

instance : ToString SettlementGate := ⟨SettlementGate.toString⟩

def FacSubjectivity.kind : FacSubjectivity → String
  | .declaratoryJudgmentFee _ => "declaratoryJudgmentFee"
  | .hammerConsentToSettle _ => "hammerConsentToSettle"
  | .punitiveDamagesReview _ => "punitiveDamagesReview"
  | .policyPeriodCertification _ => "policyPeriodCertification"

def FacSubjectivity.toString (s : FacSubjectivity) : String := s.kind

instance : ToString FacSubjectivity := ⟨FacSubjectivity.toString⟩

/-- Dispute and invalidity dominate; otherwise four-eyes controls the release. -/
def evaluateSettlementGate (stp : RuschlikonStatus) (reqs : List FacSubjectivity)
    (atts : List FourEyesAttestation) : SettlementGate :=
  match stp with
  | .RUSCHLIKON_QUERIED | .GATEKEEPER_REJECTED => .BLOCKED_BY_DISPUTE_OR_INVALID
  | .STP_AUTO_AGREED | .STP_OFFSET_APPLIED =>
      if allSubjectivitiesCleared reqs atts then .RELEASE_WIRE_AUTHORIZED
      else .HOLD_FOUR_EYES_REQUIRED

/-! ## The control, proved -/

/-- **Self-approval is never valid.** If the same person occupies both roles,
the attestation is rejected regardless of the approval flag. -/
theorem selfApproval_rejected (subj : FacSubjectivity) (person : String) (app : Bool) :
    ({ subjectivity := subj, claimsExaminer := person, technicalAccountant := person,
       approved := app } : FourEyesAttestation).isValidSegregation = false := by
  simp [FourEyesAttestation.isValidSegregation]

/-- **An unattested requirement always holds the wire.** On a clean STP claim,
one requirement with no attestations is enough to stop the release. -/
theorem unattestedSubjectivity_holds_wire (stp : RuschlikonStatus) (s : FacSubjectivity)
    (rest : List FacSubjectivity)
    (hAgreed : stp = .STP_AUTO_AGREED ∨ stp = .STP_OFFSET_APPLIED) :
    evaluateSettlementGate stp (s :: rest) [] = .HOLD_FOUR_EYES_REQUIRED := by
  rcases hAgreed with rfl | rfl <;> rfl

/-- **A disputed or invalid claim is never authorized**, whatever the
attestations say. -/
theorem disputedClaim_never_authorized (reqs : List FacSubjectivity)
    (atts : List FourEyesAttestation) :
    evaluateSettlementGate .RUSCHLIKON_QUERIED reqs atts = .BLOCKED_BY_DISPUTE_OR_INVALID ∧
      evaluateSettlementGate .GATEKEEPER_REJECTED reqs atts =
        .BLOCKED_BY_DISPUTE_OR_INVALID := by
  exact ⟨rfl, rfl⟩

/-- **A clean claim with no subjectivity is released.** The gate does not add
friction where none is required. -/
theorem noSubjectivity_cleanStp_authorized (atts : List FourEyesAttestation) :
    evaluateSettlementGate .STP_AUTO_AGREED [] atts = .RELEASE_WIRE_AUTHORIZED := by
  rfl

end ReinsuranceLeanCockpit
