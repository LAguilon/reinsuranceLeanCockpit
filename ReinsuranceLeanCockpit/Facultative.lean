import ReinsuranceLeanCockpit.Contracts
import ReinsuranceLeanCockpit.Validation

namespace ReinsuranceLeanCockpit

/-!
# US facultative excess-of-loss accounting desk

Four lines a US facultative casualty desk actually writes: Auto Liability,
General Liability, Workers' Compensation and Directors & Officers. Each
certificate is a 100% layer with a signed share; the desk's job is to check what
the cedent billed against what the contract says is payable.

Three modelling decisions matter:

* **ALAE sits in one of three places** and the difference is worth real money.
  `includedInLimit` means defence costs consume the layer and can therefore
  *reduce* the indemnity recovery. `proRataInAddition` means defence is paid on
  top, pro rata to the ceded indemnity — but it can never pierce the attachment
  on its own, because there is no ceded indemnity to prorate against.
  `excluded` means the cedent carries defence itself.
* **Prior paid is cumulative, not incremental.** A Q3 cash call states the
  cumulative layer position; the amount due now is the cumulative liability less
  everything already paid. Billing the cumulative figure again is the single
  most common real-world overbilling error, so it gets its own verdict logic.
* **The journal is double-entry.** Every approved dollar is split into indemnity
  and ALAE debits against a single cedent-payable credit, and the split is proved
  to balance. An accounting engine that cannot state `debits = credits` as a
  theorem is a calculator with a logo.
-/

/-! ## Vocabulary -/

inductive FacLine where
  | AutoLiability
  | GeneralLiability
  | WorkersComp
  | DirectorsOfficers
  deriving Repr, DecidableEq, BEq

def FacLine.toString : FacLine → String
  | .AutoLiability => "Auto Liability"
  | .GeneralLiability => "General Liability"
  | .WorkersComp => "Workers Compensation"
  | .DirectorsOfficers => "Directors & Officers"

def FacLine.code : FacLine → String
  | .AutoLiability => "AL"
  | .GeneralLiability => "GL"
  | .WorkersComp => "WCA"
  | .DirectorsOfficers => "DO"

instance : ToString FacLine := ⟨FacLine.toString⟩

inductive AlaeClause where
  | includedInLimit
  | proRataInAddition
  | excluded
  deriving Repr, DecidableEq, BEq

def AlaeClause.toString : AlaeClause → String
  | .includedInLimit => "ALAE Included Within Limits"
  | .proRataInAddition => "ALAE Pro-Rata in Addition"
  | .excluded => "ALAE Excluded"

instance : ToString AlaeClause := ⟨AlaeClause.toString⟩

/-- One bound facultative certificate. `occLimitUsd` is the **100% layer**
limit; the signed share is applied afterwards. -/
structure FacCertificate where
  certId : String
  insuredName : String
  cedentName : String
  line : FacLine
  attachmentUsd : Nat
  occLimitUsd : Nat
  signedShareBps : Nat
  alaeClause : AlaeClause
  deriving Repr, DecidableEq

def FacCertificate.isValid (c : FacCertificate) : Bool :=
  decide (0 < c.signedShareBps) && decide (c.signedShareBps ≤ 10000) &&
    decide (0 < c.occLimitUsd)

/-- Our maximum liability on the certificate: the 100% limit times the signed
share. This is the number that caps D&O defence-inside-limits exposures. -/
def FacCertificate.ourMaxLimitUsd (c : FacCertificate) : Nat :=
  c.occLimitUsd * c.signedShareBps / 10000

/-! ## Layer mechanics -/

/-- Ceded indemnity on the 100% layer, before applying the signed share. -/
def layerInd100 (c : FacCertificate) (indemnityUsd : Nat) : Nat :=
  min (indemnityUsd - c.attachmentUsd) c.occLimitUsd

/-- Total 100% layer loss when ALAE shares the limit with indemnity. -/
def layerTotal100 (c : FacCertificate) (indemnityUsd alaeUsd : Nat) : Nat :=
  min (indemnityUsd + alaeUsd - c.attachmentUsd) c.occLimitUsd

/-- Ceded ALAE on the 100% layer. The three clauses are genuinely different
functions, not presentation choices. -/
def layerAlae100 (c : FacCertificate) (indemnityUsd alaeUsd : Nat) : Nat :=
  match c.alaeClause with
  | .includedInLimit => layerTotal100 c indemnityUsd alaeUsd - layerInd100 c indemnityUsd
  | .proRataInAddition => alaeUsd * layerInd100 c indemnityUsd / indemnityUsd
  | .excluded => 0

def ourIndemnityUsd (c : FacCertificate) (indemnityUsd _alaeUsd : Nat) : Nat :=
  layerInd100 c indemnityUsd * c.signedShareBps / 10000

def ourAlaeUsd (c : FacCertificate) (indemnityUsd alaeUsd : Nat) : Nat :=
  layerAlae100 c indemnityUsd alaeUsd * c.signedShareBps / 10000

def ourCumulativePayableUsd (c : FacCertificate) (indemnityUsd alaeUsd : Nat) : Nat :=
  ourIndemnityUsd c indemnityUsd alaeUsd + ourAlaeUsd c indemnityUsd alaeUsd

/-! ## Cash-call submission and audit result -/

structure FacClaimSubmission where
  claimId : String
  certId : String
  lossDesc : String
  groundUpIndemnityUsd : Nat
  groundUpAlaeUsd : Nat
  priorPaidUsd : Nat
  cedentBilledNowUsd : Nat
  deriving Repr, DecidableEq

/-- The technical accounting voucher: indemnity and ALAE debits against the
cedent payable credit. -/
structure FacJournalVoucher where
  debitIndemnityIncrementalUsd : Nat
  debitAlaeIncrementalUsd : Nat
  creditCedantPayableUsd : Nat
  totalDebitUsd : Nat
  totalCreditUsd : Nat
  deriving Repr, DecidableEq

structure FacAuditResult where
  certId : String
  claimId : String
  insuredName : String
  line : String
  verdict : String
  explanation : String
  ourIndemnityUsd : Nat
  ourAlaeUsd : Nat
  ourCumulativePayableUsd : Nat
  priorPaidUsd : Nat
  verifiedIncrementalDueUsd : Nat
  cedentBilledNowUsd : Nat
  overbilledUsd : Nat
  underbilledUsd : Nat
  journal : FacJournalVoucher
  brokerMemo : String
  deriving Repr

/-! ## Formatting -/

/-- Thousands-separated decimal. Fuel-bounded so no termination proof is needed:
nine groups covers every realistic claim amount. -/
def commasGo : Nat → Nat → String → String
  | 0, n, acc => toString n ++ acc
  | fuel + 1, n, acc =>
      if n < 1000 then toString n ++ acc
      else
        let r := n % 1000
        let pad := if r < 10 then "00" else if r < 100 then "0" else ""
        commasGo fuel (n / 1000) ("," ++ pad ++ toString r ++ acc)

def commas (n : Nat) : String := commasGo 9 n ""

def usd (n : Nat) : String := "$" ++ commas n

/-! ## The audit -/

/-- Human explanation of the verdict, chosen from the contract terms and the
arithmetic — never from a template that could contradict the numbers. -/
def explainVerdict (cert : FacCertificate) (sub : FacClaimSubmission)
    (cum verified over under : Nat) : String :=
  if over > 0 then
    if cert.alaeClause == .proRataInAddition && sub.groundUpIndemnityUsd ≤ cert.attachmentUsd then
      s!"ALAE Pro-Rata in Addition: ground-up indemnity ({usd sub.groundUpIndemnityUsd}) is below the {usd cert.attachmentUsd} attachment, so no ceded indemnity exists and ALAE cannot be added to pierce the attachment. Verified due is {usd verified}."
    else if sub.priorPaidUsd > 0 && sub.cedentBilledNowUsd ≥ cum then
      s!"Prior paid ({usd sub.priorPaidUsd}) was not deducted from the cumulative {usd cum} liability. The incremental amount due is {usd verified}, not {usd sub.cedentBilledNowUsd}."
    else if cum == cert.ourMaxLimitUsd then
      s!"ALAE Included Within Limits plus a {cert.signedShareBps} bps signed share caps total liability at {usd cert.ourMaxLimitUsd}; the bill of {usd sub.cedentBilledNowUsd} exceeds that cap by {usd over}."
    else
      s!"Billed {usd sub.cedentBilledNowUsd} against {usd verified} verified as due; overbilled by {usd over}."
  else if under > 0 then
    s!"Cedent billed {usd sub.cedentBilledNowUsd} but {usd verified} is payable under the certificate; {usd under} remains unbilled and should be reviewed."
  else
    s!"Billed amount agrees exactly with the certificate arithmetic: {usd verified} payable, consisting of {usd (ourIndemnityUsd cert sub.groundUpIndemnityUsd sub.groundUpAlaeUsd)} indemnity and {usd (ourAlaeUsd cert sub.groundUpIndemnityUsd sub.groundUpAlaeUsd)} ALAE."

/-- Professional settlement or dispute memo, ready to send. -/
def brokerMemo (cert : FacCertificate) (sub : FacClaimSubmission) (r : FacAuditResult) : String :=
  let head := s!"RE: {cert.certId} / {sub.claimId} - facultative cash-call review\n\n"
  let body :=
    s!"Insured: {cert.insuredName}\nLine: {cert.line}\nCertificate: {usd cert.occLimitUsd} xs {usd cert.attachmentUsd}, {cert.signedShareBps} bps signed share, {cert.alaeClause}.\n\n" ++
    s!"Cumulative payable per certificate: {usd r.ourCumulativePayableUsd}\nLess prior paid: {usd sub.priorPaidUsd}\nVerified incremental due now: {usd r.verifiedIncrementalDueUsd}\nCedent billed: {usd sub.cedentBilledNowUsd}\n"
  let tail :=
    if r.overbilledUsd > 0 then
      s!"\nDiscrepancy: {usd r.overbilledUsd} overbilled. {r.explanation}\n\nPlease issue a corrected cash call for {usd r.verifiedIncrementalDueUsd}. The accompanying journal voucher debits indemnity {usd r.journal.debitIndemnityIncrementalUsd} and ALAE {usd r.journal.debitAlaeIncrementalUsd} against cedent payable {usd r.journal.creditCedantPayableUsd}.\n"
    else if r.underbilledUsd > 0 then
      s!"\nThe cash call is {usd r.underbilledUsd} below the certificate amount. {r.explanation}\n"
    else
      s!"\nThe cash call agrees with the certificate. Approved for payment of {usd r.verifiedIncrementalDueUsd}.\n"
  head ++ body ++ tail

def auditFacClaim (cert : FacCertificate) (sub : FacClaimSubmission) : FacAuditResult :=
  let ourInd := ourIndemnityUsd cert sub.groundUpIndemnityUsd sub.groundUpAlaeUsd
  let ourAlae := ourAlaeUsd cert sub.groundUpIndemnityUsd sub.groundUpAlaeUsd
  let cum := ourInd + ourAlae
  let verified := cum - sub.priorPaidUsd
  let over := sub.cedentBilledNowUsd - verified
  let under := verified - sub.cedentBilledNowUsd
  let verdict :=
    if over > 0 then "DISPUTE_OVERBILLED"
    else if under > 0 then "REVIEW_UNDERBILLED"
    else "APPROVED_EXACT"
  let debitInd := min ourInd verified
  let debitAlae := verified - debitInd
  let base : FacAuditResult :=
    { certId := cert.certId
      claimId := sub.claimId
      insuredName := cert.insuredName
      line := cert.line.toString
      verdict := verdict
      explanation := explainVerdict cert sub cum verified over under
      ourIndemnityUsd := ourInd
      ourAlaeUsd := ourAlae
      ourCumulativePayableUsd := cum
      priorPaidUsd := sub.priorPaidUsd
      verifiedIncrementalDueUsd := verified
      cedentBilledNowUsd := sub.cedentBilledNowUsd
      overbilledUsd := over
      underbilledUsd := under
      journal :=
        { debitIndemnityIncrementalUsd := debitInd
          debitAlaeIncrementalUsd := debitAlae
          creditCedantPayableUsd := verified
          totalDebitUsd := debitInd + debitAlae
          totalCreditUsd := verified }
      brokerMemo := "" }
  { base with brokerMemo := brokerMemo cert sub base }

/-! ## Book-level audit -/

structure FacPortfolioAudit where
  deskName : String
  results : List FacAuditResult
  totalBilledUsd : Nat
  totalVerifiedUsd : Nat
  totalOverbilledUsd : Nat
  totalUnderbilledUsd : Nat
  disputeCount : Nat
  deriving Repr

structure FacBundle where
  deskName : String
  certificates : List FacCertificate
  claims : List FacClaimSubmission
  deriving Repr

/-- Pair each claim with its certificate. A claim whose certificate is missing
is audited against a zero certificate, which yields a zero verified amount and a
full dispute — failing closed rather than paying an unknown contract. -/
def lookupCert (certs : List FacCertificate) (id : String) : FacCertificate :=
  match certs.find? (fun c => c.certId == id) with
  | some c => c
  | none =>
      { certId := id, insuredName := "(unknown certificate)", cedentName := "",
        line := .GeneralLiability, attachmentUsd := 0, occLimitUsd := 0,
        signedShareBps := 0, alaeClause := .excluded }

def auditFacBundle (b : FacBundle) : FacPortfolioAudit :=
  let results := b.claims.map (fun sub => auditFacClaim (lookupCert b.certificates sub.certId) sub)
  { deskName := b.deskName
    results := results
    totalBilledUsd := results.foldl (fun a r => a + r.cedentBilledNowUsd) 0
    totalVerifiedUsd := results.foldl (fun a r => a + r.verifiedIncrementalDueUsd) 0
    totalOverbilledUsd := results.foldl (fun a r => a + r.overbilledUsd) 0
    totalUnderbilledUsd := results.foldl (fun a r => a + r.underbilledUsd) 0
    disputeCount := results.foldl (fun a r => if r.overbilledUsd > 0 then a + 1 else a) 0 }

/-! ## Proofs -/

/-- **Pro-rata ALAE can never exceed the ALAE it prorates.** The divisor is the
ground-up indemnity; when it is zero the ceded indemnity is zero too, so the
numerator is zero and Lean's total division returns zero without a side
condition. -/
theorem proRataAlae_le_alae (alae ind100 ind : Nat) (h : ind100 ≤ ind) :
    (alae * ind100) / ind ≤ alae := by
  cases Nat.eq_zero_or_pos ind with
  | inl h0 =>
      subst h0
      simp
  | inr hPos =>
      have h1 : alae * ind100 ≤ alae * ind := Nat.mul_le_mul_left alae h
      have h2 : (alae * ind100) / ind ≤ (alae * ind) / ind := Nat.div_le_div_right h1
      have h3 : (alae * ind) / ind = alae := Nat.mul_div_cancel alae hPos
      omega

/-- Floors are superadditive: splitting a numerator across a division loses at
most the remainder. This is what lets the two legs be added after scaling. -/
theorem div_add_div_le (a b d : Nat) : a / d + b / d ≤ (a + b) / d := by
  cases d with
  | zero => simp
  | succ k =>
      rw [Nat.le_div_iff_mul_le (Nat.succ_pos k)]
      calc (a / (k + 1) + b / (k + 1)) * (k + 1)
          = a / (k + 1) * (k + 1) + b / (k + 1) * (k + 1) := Nat.add_mul _ _ _
        _ ≤ a + b := Nat.add_le_add (Nat.div_mul_le_self a (k + 1))
                                   (Nat.div_mul_le_self b (k + 1))

/-- The 100% layer indemnity plus the 100% layer ALAE is exactly the 100% layer
total when defence is inside the limit. -/
theorem included_split_exact (cert : FacCertificate) (ind alae : Nat)
    (hClause : cert.alaeClause = .includedInLimit) :
    layerInd100 cert ind + layerAlae100 cert ind alae = layerTotal100 cert ind alae := by
  unfold layerAlae100
  rw [hClause]
  simp only
  unfold layerInd100 layerTotal100
  omega

/-- Validity gives the share bound the payout theorems need. -/
theorem share_le_of_valid (cert : FacCertificate) (h : cert.isValid = true) :
    cert.signedShareBps ≤ 10000 := by
  unfold FacCertificate.isValid at h
  simp at h
  exact h.1.2

theorem share_pos_of_valid (cert : FacCertificate) (h : cert.isValid = true) :
    0 < cert.signedShareBps := by
  unfold FacCertificate.isValid at h
  simp at h
  exact h.1.1

/-- A share at or below 100% never scales an amount upwards. -/
theorem mul_div_self_le (a s : Nat) (h : s ≤ 10000) : a * s / 10000 ≤ a :=
  Nat.div_le_of_le_mul (by
    calc a * s ≤ a * 10000 := Nat.mul_le_mul_left a h
      _ = 10000 * a := Nat.mul_comm _ _)

/-- **Defence inside the limit cannot escape the signed share.** With ALAE
included in the limit, total payable is capped by the 100% limit times the
signed share, and therefore by the 100% limit itself. -/
theorem facIncluded_capped_by_share (cert : FacCertificate) (ind alae : Nat)
    (hValid : cert.isValid = true) (hClause : cert.alaeClause = .includedInLimit) :
    ourCumulativePayableUsd cert ind alae ≤ cert.ourMaxLimitUsd ∧
      ourCumulativePayableUsd cert ind alae ≤ cert.occLimitUsd := by
  have hs : cert.signedShareBps ≤ 10000 := share_le_of_valid cert hValid
  have hsplit : layerInd100 cert ind + layerAlae100 cert ind alae =
      layerTotal100 cert ind alae := included_split_exact cert ind alae hClause
  have htotal : layerTotal100 cert ind alae ≤ cert.occLimitUsd := by
    unfold layerTotal100
    omega
  have hle : ourCumulativePayableUsd cert ind alae ≤
      (layerTotal100 cert ind alae * cert.signedShareBps) / 10000 := by
    unfold ourCumulativePayableUsd ourIndemnityUsd ourAlaeUsd
    calc
      layerInd100 cert ind * cert.signedShareBps / 10000 +
          layerAlae100 cert ind alae * cert.signedShareBps / 10000
          ≤ (layerInd100 cert ind * cert.signedShareBps +
              layerAlae100 cert ind alae * cert.signedShareBps) / 10000 :=
            div_add_div_le _ _ _
      _ = ((layerInd100 cert ind + layerAlae100 cert ind alae) *
              cert.signedShareBps) / 10000 := by rw [Nat.add_mul]
      _ = (layerTotal100 cert ind alae * cert.signedShareBps) / 10000 := by rw [hsplit]
  have hmax : (layerTotal100 cert ind alae * cert.signedShareBps) / 10000 ≤
      cert.ourMaxLimitUsd := by
    unfold FacCertificate.ourMaxLimitUsd
    exact Nat.div_le_div_right (Nat.mul_le_mul_right _ htotal)
  refine ⟨Nat.le_trans hle hmax, ?_⟩
  unfold FacCertificate.ourMaxLimitUsd at hmax
  exact Nat.le_trans hle (Nat.le_trans hmax (mul_div_self_le _ _ hs))

/-- **No over-recovery, in any of the three ALAE modes.** Whatever the clause,
the desk never pays more than ground-up indemnity plus ground-up ALAE. Defence
paid in addition to limits is still bounded by the defence that was actually
spent. -/
theorem fac_no_overrecovery (cert : FacCertificate) (ind alae : Nat)
    (hValid : cert.isValid = true) :
    ourCumulativePayableUsd cert ind alae ≤ ind + alae := by
  have hs : cert.signedShareBps ≤ 10000 := share_le_of_valid cert hValid
  have hInd : ourIndemnityUsd cert ind alae ≤ layerInd100 cert ind := by
    unfold ourIndemnityUsd
    exact mul_div_self_le _ _ hs
  have hIndLe : layerInd100 cert ind ≤ ind := by
    unfold layerInd100
    omega
  cases hc : cert.alaeClause with
  | includedInLimit =>
      have hsplit : layerInd100 cert ind + layerAlae100 cert ind alae =
          layerTotal100 cert ind alae := included_split_exact cert ind alae hc
      have hAlae : ourAlaeUsd cert ind alae ≤ layerAlae100 cert ind alae := by
        unfold ourAlaeUsd
        exact mul_div_self_le _ _ hs
      have htot : layerTotal100 cert ind alae ≤ ind + alae := by
        unfold layerTotal100
        omega
      unfold ourCumulativePayableUsd
      omega
  | proRataInAddition =>
      have hInd100 : layerInd100 cert ind ≤ ind := by unfold layerInd100; omega
      have hProrata : layerAlae100 cert ind alae ≤ alae := by
        unfold layerAlae100
        rw [hc]
        simp only
        exact proRataAlae_le_alae alae (layerInd100 cert ind) ind hInd100
      have hAlae : ourAlaeUsd cert ind alae ≤ layerAlae100 cert ind alae := by
        unfold ourAlaeUsd
        exact mul_div_self_le _ _ hs
      unfold ourCumulativePayableUsd
      omega
  | excluded =>
      have hAlae0 : layerAlae100 cert ind alae = 0 := by
        simp [layerAlae100, hc]
      have hAlae : ourAlaeUsd cert ind alae = 0 := by
        unfold ourAlaeUsd
        rw [hAlae0]
        simp
      have h0 : ourAlaeUsd cert ind alae = 0 := hAlae
      unfold ourCumulativePayableUsd
      omega

/-- Incremental due is cumulative less prior paid, exactly. -/
theorem facIncremental_conservation (cumPayable priorPaid : Nat) (h : priorPaid ≤ cumPayable) :
    priorPaid + (cumPayable - priorPaid) = cumPayable := by
  omega

/-- An overbilling reconciles: the verified amount plus the overbilled amount is
what the cedent actually billed. -/
theorem facOverbill_reconciliation (billed verified : Nat) (h : verified ≤ billed) :
    verified + (billed - verified) = billed := by
  omega

/-- **The journal always balances.** Indemnity plus ALAE debits equal the cedent
payable credit, for every certificate and every claim, because the ALAE debit is
defined as the residual. -/
theorem facJournal_balanced (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).journal.totalDebitUsd =
      (auditFacClaim cert sub).journal.totalCreditUsd := by
  unfold auditFacClaim
  simp only
  omega

/-- The verified increment never exceeds cumulative liability. -/
theorem facVerified_le_cumulative (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).verifiedIncrementalDueUsd ≤
      (auditFacClaim cert sub).ourCumulativePayableUsd := by
  unfold auditFacClaim
  simp only
  omega

/-- Verified plus overbilled equals billed: the desk's reconciliation identity
at the level of the audit result. -/
theorem facBilled_reconciles (cert : FacCertificate) (sub : FacClaimSubmission)
    (h : (auditFacClaim cert sub).verifiedIncrementalDueUsd ≤ sub.cedentBilledNowUsd) :
    (auditFacClaim cert sub).verifiedIncrementalDueUsd +
      (auditFacClaim cert sub).overbilledUsd = sub.cedentBilledNowUsd := by
  unfold auditFacClaim
  simp only
  exact facOverbill_reconciliation _ _ h

end ReinsuranceLeanCockpit
