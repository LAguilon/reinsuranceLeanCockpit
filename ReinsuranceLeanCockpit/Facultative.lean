import ReinsuranceLeanCockpit.Contracts
import ReinsuranceLeanCockpit.Validation

namespace ReinsuranceLeanCockpit

/-!
# US facultative excess-of-loss accounting desk (v0.6)

A facultative certificate is a single-risk layer: attachment, 100% limit, signed
share, and — the part that decides most disputes — where ALAE sits.

v0.6 adds the two things a real US casualty desk books that a pure paid-loss
model cannot express:

* **Paid versus incurred.** A claim has cash paid *and* an outstanding case
  reserve (OSLR, IFRS 17 LIC). The layer responds to incurred, but only paid
  losses can be wired. Billing the reserve as cash is the classic premature
  cash call.
* **Premium offset.** Unpaid net premium (gross less brokerage, less what the
  cedent has already paid) is netted against an approved cash call, so the wire
  is smaller than the claim.

Three modelling decisions matter:

* **ALAE sits in one of three places** and the difference is worth real money.
  `includedInLimit` means defence costs consume the layer and can reduce the
  indemnity recovery. `proRataInAddition` pays defence on top, pro rata to the
  ceded indemnity — but it cannot pierce an attachment on its own, because there
  is no ceded indemnity to prorate against. `excluded` means the cedent carries
  defence itself.
* **Prior paid is cumulative, not incremental.** A Q3 cash call states the
  cumulative layer position; the amount due now is cumulative paid less
  everything already settled.
* **Incurred is floored at paid.** Pro-rata ALAE is computed against the
  ground-up indemnity ratio; when indemnity is far above the layer, that ratio
  can make incurred *smaller* than paid. Taking `max` keeps the ending reserve
  non-negative and the balance sheet honest.
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
limit; the signed share is applied afterwards. Premium terms are carried so the
desk can offset unpaid net premium against an approved wire. -/
structure FacCertificate where
  certId : String
  insuredName : String
  cedentName : String
  line : FacLine
  attachmentUsd : Nat
  occLimitUsd : Nat
  signedShareBps : Nat
  alaeClause : AlaeClause
  grossPremiumUsd : Nat
  brokerageBps : Nat
  paidPremiumToDateUsd : Nat
  insuredGroup : String
  deriving Repr, DecidableEq

def FacCertificate.isValid (c : FacCertificate) : Bool :=
  decide (0 < c.signedShareBps ∧ c.signedShareBps ≤ 10000 ∧ 0 < c.occLimitUsd ∧
    c.brokerageBps ≤ 10000)

/-- Our maximum liability on the certificate: the 100% limit times the signed
share. This is the number that caps D&O defence-inside-limits exposures. -/
def FacCertificate.ourMaxLimitUsd (c : FacCertificate) : Nat :=
  c.occLimitUsd * c.signedShareBps / 10000

/-- Net premium after US brokerage, before any cash received. -/
def FacCertificate.netPremiumDueUsd (c : FacCertificate) : Nat :=
  c.grossPremiumUsd - (c.grossPremiumUsd * c.brokerageBps) / 10000

/-- Unpaid net premium available to offset an approved claim wire. -/
def FacCertificate.unpaidNetPremiumUsd (c : FacCertificate) : Nat :=
  c.netPremiumDueUsd - c.paidPremiumToDateUsd

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

/-! ## Cash-call submission: paid and incurred -/

structure FacClaimSubmission where
  claimId : String
  certId : String
  lossDesc : String
  /-- Cash indemnity paid by the cedent to date. -/
  paidIndemnityUsd : Nat
  /-- Cash ALAE paid by the cedent to date. -/
  paidAlaeUsd : Nat
  /-- Outstanding case reserve, indemnity (IFRS 17 LIC). -/
  oslrIndemnityUsd : Nat
  /-- Outstanding case reserve, ALAE. -/
  oslrAlaeUsd : Nat
  /-- Cash already paid by the reinsurer in prior quarters. -/
  priorPaidUsd : Nat
  /-- Case reserve already booked on the reinsurer's ledger. -/
  priorOslrBookedUsd : Nat
  /-- Cash the cedent is demanding now. -/
  cedentBilledNowUsd : Nat
  /-- Whether to net unpaid net premium against the approved wire. -/
  applyPremiumOffset : Bool
  /-- Optional catastrophe / occurrence tag used for clash detection. -/
  clashEventTag : String
  deriving Repr, DecidableEq

/-! ## Ruschlikon / ACORD status -/

/-- ACORD GRLC / Ruschlikon settlement status. -/
inductive RuschlikonStatus where
  | STP_AUTO_AGREED
  | STP_OFFSET_APPLIED
  | RUSCHLIKON_QUERIED
  | GATEKEEPER_REJECTED
  deriving Repr, DecidableEq, BEq

def RuschlikonStatus.toString : RuschlikonStatus → String
  | .STP_AUTO_AGREED => "STP_AUTO_AGREED"
  | .STP_OFFSET_APPLIED => "STP_OFFSET_APPLIED"
  | .RUSCHLIKON_QUERIED => "RUSCHLIKON_QUERIED"
  | .GATEKEEPER_REJECTED => "GATEKEEPER_REJECTED"

instance : ToString RuschlikonStatus := ⟨RuschlikonStatus.toString⟩

/-- ACORD response code carried on the outbound `ClaimMovementResponse`. -/
def RuschlikonStatus.acordCode : RuschlikonStatus → String
  | .STP_AUTO_AGREED => "AGD"
  | .STP_OFFSET_APPLIED => "AGD_OFFSET"
  | .RUSCHLIKON_QUERIED => "QRY"
  | .GATEKEEPER_REJECTED => "REJ"

/-- Deterministic settlement classification. Defined on plain values so that the
audit result and the ACORD adapter cannot disagree about it. -/
def classifyStp (valid : Bool) (overbilled underbilled premiumOffset : Nat) : RuschlikonStatus :=
  if !valid then .GATEKEEPER_REJECTED
  else if overbilled > 0 || underbilled > 0 then .RUSCHLIKON_QUERIED
  else if premiumOffset > 0 then .STP_OFFSET_APPLIED
  else .STP_AUTO_AGREED

/-! ## The multi-leg voucher -/

/-- Leg A settles cash: paid claims expense against the premium receivable
offset and the wire. Leg B moves the case reserve: expense against liability, or
liability release against expense release. -/
structure FacFullAccountingVoucher where
  debitPaidClaimsExpenseUsd : Nat
  creditPremiumReceivableOffsetUsd : Nat
  creditCashWirePayableUsd : Nat
  cashTotalDebitUsd : Nat
  cashTotalCreditUsd : Nat
  debitOslrExpenseUsd : Nat
  creditOslrLiabilityUsd : Nat
  debitOslrLiabilityReleaseUsd : Nat
  creditOslrExpenseReleaseUsd : Nat
  reserveTotalDebitUsd : Nat
  reserveTotalCreditUsd : Nat
  grandTotalDebitUsd : Nat
  grandTotalCreditUsd : Nat
  deriving Repr, DecidableEq

structure FacAuditResult where
  certId : String
  claimId : String
  insuredName : String
  line : String
  verdict : String
  explanation : String
  /-- Paid-leg ceded indemnity. -/
  ourIndemnityUsd : Nat
  /-- Paid-leg ceded ALAE. -/
  ourAlaeUsd : Nat
  /-- Paid-leg cumulative payable (kept under the v0.5 name). -/
  ourCumulativePayableUsd : Nat
  ourCumulativePaidUsd : Nat
  ourCumulativeIncurredUsd : Nat
  verifiedEndingOslrUsd : Nat
  priorPaidUsd : Nat
  priorOslrBookedUsd : Nat
  grossCashPayableNowUsd : Nat
  premiumOffsetUsd : Nat
  netCashWireDueUsd : Nat
  cedentBilledNowUsd : Nat
  overbilledUsd : Nat
  underbilledUsd : Nat
  ruschlikonStatus : RuschlikonStatus
  acordResponseCode : String
  voucher : FacFullAccountingVoucher
  leanSpecCode : String
  backTranslation : String
  brokerMemo : String
  deriving Repr

/-! ## Formatting -/

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

/-! ## Back-translation and generated Lean -/

/-- What the certificate actually does, in the words an actuary would use. -/
def informalizeFacCertificate (c : FacCertificate) : String :=
  let prem :=
    if c.grossPremiumUsd == 0 then "no premium recorded"
    else s!"gross premium {usd c.grossPremiumUsd} with {c.brokerageBps} bps brokerage and {usd c.paidPremiumToDateUsd} received to date"
  s!"{c.line} certificate {c.certId} for {c.insuredName} ({c.insuredGroup}): {usd c.occLimitUsd} xs {usd c.attachmentUsd} at {c.signedShareBps} bps signed share, {c.alaeClause}, {prem}."

/-- The exact compilable Lean 4 definitions for this certificate and claim.
Numbers only: this is the same data the kernel just audited. -/
def renderLeanFacSpec (c : FacCertificate) (s : FacClaimSubmission) : String :=
  "def certificate : FacCertificate := { certId := \"" ++ c.certId ++ "\", insuredName := \"" ++
  c.insuredName ++ "\", cedentName := \"" ++ c.cedentName ++ "\", line := ." ++
  (match c.line with
   | .AutoLiability => "AutoLiability"
   | .GeneralLiability => "GeneralLiability"
   | .WorkersComp => "WorkersComp"
   | .DirectorsOfficers => "DirectorsOfficers") ++
  ", attachmentUsd := " ++ toString c.attachmentUsd ++ ", occLimitUsd := " ++ toString c.occLimitUsd ++
  ", signedShareBps := " ++ toString c.signedShareBps ++ ", alaeClause := ." ++
  (match c.alaeClause with
   | .includedInLimit => "includedInLimit"
   | .proRataInAddition => "proRataInAddition"
   | .excluded => "excluded") ++
  ", grossPremiumUsd := " ++ toString c.grossPremiumUsd ++ ", brokerageBps := " ++
  toString c.brokerageBps ++ ", paidPremiumToDateUsd := " ++ toString c.paidPremiumToDateUsd ++
  ", insuredGroup := \"" ++ c.insuredGroup ++ "\" }\n\n" ++
  "def claim : FacClaimSubmission := { claimId := \"" ++ s.claimId ++ "\", certId := \"" ++
  s.certId ++ "\", lossDesc := \"" ++ s.lossDesc ++ "\", paidIndemnityUsd := " ++
  toString s.paidIndemnityUsd ++ ", paidAlaeUsd := " ++ toString s.paidAlaeUsd ++
  ", oslrIndemnityUsd := " ++ toString s.oslrIndemnityUsd ++ ", oslrAlaeUsd := " ++
  toString s.oslrAlaeUsd ++ ", priorPaidUsd := " ++ toString s.priorPaidUsd ++
  ", priorOslrBookedUsd := " ++ toString s.priorOslrBookedUsd ++ ", cedentBilledNowUsd := " ++
  toString s.cedentBilledNowUsd ++ ", applyPremiumOffset := " ++
  (if s.applyPremiumOffset then "true" else "false") ++ ", clashEventTag := \"" ++
  s.clashEventTag ++ "\" }\n\n" ++
  "#eval (auditFacClaim certificate claim).verdict"

/-! ## The audit -/

/-- Human explanation of the verdict, chosen from the contract terms and the
arithmetic — never from a template that could contradict the numbers. -/
def explainVerdict (cert : FacCertificate) (sub : FacClaimSubmission)
    (ourPaid incurred oslr grossCash verified over under : Nat) : String :=
  if over > 0 then
    if sub.oslrIndemnityUsd > 0 && ourPaid ≤ cert.attachmentUsd then
      s!"Premature OSLR cash call: paid indemnity ({usd sub.paidIndemnityUsd}) is still below the {usd cert.attachmentUsd} attachment, so no cash is payable; the {usd oslr} case reserve is booked as a liability, not wired. Cedent billed {usd sub.cedentBilledNowUsd} against {usd grossCash} cash payable — overbilled by {usd over}."
    else if cert.alaeClause == .proRataInAddition && sub.paidIndemnityUsd ≤ cert.attachmentUsd then
      s!"ALAE Pro-Rata in Addition: ground-up indemnity ({usd sub.paidIndemnityUsd}) is below the {usd cert.attachmentUsd} attachment, so no ceded indemnity exists and ALAE cannot be added to pierce the attachment. Verified due is {usd verified}."
    else if sub.priorPaidUsd > 0 && sub.cedentBilledNowUsd ≥ ourPaid then
      s!"Prior paid ({usd sub.priorPaidUsd}) was not deducted from the cumulative {usd ourPaid} paid liability. The incremental amount due is {usd verified}, not {usd sub.cedentBilledNowUsd}."
    else if ourPaid == cert.ourMaxLimitUsd then
      s!"ALAE Included Within Limits plus a {cert.signedShareBps} bps signed share caps total liability at {usd cert.ourMaxLimitUsd}; the bill of {usd sub.cedentBilledNowUsd} exceeds that cap by {usd over}."
    else
      s!"Billed {usd sub.cedentBilledNowUsd} against {usd grossCash} verified cash payable; overbilled by {usd over}. Incurred to date is {usd incurred} with an ending case reserve of {usd oslr}."
  else if under > 0 then
    s!"Cedent billed {usd sub.cedentBilledNowUsd} but {usd grossCash} is payable in cash under the certificate; {usd under} remains unbilled and should be reviewed."
  else
    s!"Billed amount agrees exactly with the certificate arithmetic: {usd grossCash} cash payable (plus an ending case reserve of {usd oslr}), consisting of {usd (ourIndemnityUsd cert sub.paidIndemnityUsd sub.paidAlaeUsd)} indemnity and {usd (ourAlaeUsd cert sub.paidIndemnityUsd sub.paidAlaeUsd)} ALAE."

/-- Professional settlement or dispute memo, ready to send. -/
def brokerMemo (cert : FacCertificate) (sub : FacClaimSubmission) (r : FacAuditResult) : String :=
  let head := s!"RE: {cert.certId} / {sub.claimId} - facultative cash-call review\n\n"
  let body :=
    s!"Insured: {cert.insuredName} ({cert.insuredGroup})\nLine: {cert.line}\nCertificate: {usd cert.occLimitUsd} xs {usd cert.attachmentUsd}, {cert.signedShareBps} bps signed share, {cert.alaeClause}.\n\n" ++
    s!"Paid to date (ceded): {usd r.ourCumulativePaidUsd}\nLess prior paid: {usd sub.priorPaidUsd}\nGross cash payable now: {usd r.grossCashPayableNowUsd}\nUnpaid net premium offset: {usd r.premiumOffsetUsd}\nNet wire authorized: {usd r.netCashWireDueUsd}\nEnding ceded case reserve (OSLR / LIC): {usd r.verifiedEndingOslrUsd}\nIncurred to date: {usd r.ourCumulativeIncurredUsd}\nCedent billed: {usd sub.cedentBilledNowUsd}\n"
  let tail :=
    if r.overbilledUsd > 0 then
      s!"\nDiscrepancy: {usd r.overbilledUsd} overbilled. {r.explanation}\n\nPlease issue a corrected cash call for {usd r.netCashWireDueUsd}. The accompanying voucher debits paid claims {usd r.voucher.debitPaidClaimsExpenseUsd}, credits premium receivable {usd r.voucher.creditPremiumReceivableOffsetUsd} and credits cash wire {usd r.voucher.creditCashWirePayableUsd}; the reserve movement is {usd r.voucher.reserveTotalDebitUsd} on each side.\n"
    else if r.underbilledUsd > 0 then
      s!"\nThe cash call is {usd r.underbilledUsd} below the certificate amount. {r.explanation}\n"
    else
      s!"\nThe cash call agrees with the certificate. Approved for net wire of {usd r.netCashWireDueUsd} with {usd r.premiumOffsetUsd} premium offset applied.\n"
  head ++ body ++ tail

def auditFacClaim (cert : FacCertificate) (sub : FacClaimSubmission) : FacAuditResult :=
  let ourInd := ourIndemnityUsd cert sub.paidIndemnityUsd sub.paidAlaeUsd
  let ourAlae := ourAlaeUsd cert sub.paidIndemnityUsd sub.paidAlaeUsd
  let ourPaid := ourInd + ourAlae
  let rawIncurred := ourCumulativePayableUsd cert
    (sub.paidIndemnityUsd + sub.oslrIndemnityUsd) (sub.paidAlaeUsd + sub.oslrAlaeUsd)
  let incurred := max rawIncurred ourPaid
  let oslr := incurred - ourPaid
  let grossCash := ourPaid - sub.priorPaidUsd
  let offset := if sub.applyPremiumOffset then min grossCash cert.unpaidNetPremiumUsd else 0
  let netWire := grossCash - offset
  let over := sub.cedentBilledNowUsd - grossCash
  let under := grossCash - sub.cedentBilledNowUsd
  let verdict :=
    if over > 0 then
      if sub.oslrIndemnityUsd > 0 && ourPaid ≤ cert.attachmentUsd then
        "DISPUTE_PREMATURE_OSLR_CASHCALL"
      else "DISPUTE_OVERBILLED"
    else if under > 0 then "REVIEW_UNDERBILLED"
    else "APPROVED_EXACT"
  let priorOslr := sub.priorOslrBookedUsd
  -- Saturating subtraction makes the two directions mutually exclusive by
  -- construction: exactly one of them is non-zero, and no branch is needed.
  let reserveUp := oslr - priorOslr
  let reserveDown := priorOslr - oslr
  let status := classifyStp cert.isValid over under offset
  let voucher : FacFullAccountingVoucher :=
    { debitPaidClaimsExpenseUsd := grossCash
      creditPremiumReceivableOffsetUsd := offset
      creditCashWirePayableUsd := netWire
      cashTotalDebitUsd := grossCash
      cashTotalCreditUsd := offset + netWire
      debitOslrExpenseUsd := reserveUp
      creditOslrLiabilityUsd := reserveUp
      debitOslrLiabilityReleaseUsd := reserveDown
      creditOslrExpenseReleaseUsd := reserveDown
      reserveTotalDebitUsd := reserveUp + reserveDown
      reserveTotalCreditUsd := reserveUp + reserveDown
      grandTotalDebitUsd := grossCash + (reserveUp + reserveDown)
      grandTotalCreditUsd := (offset + netWire) + (reserveUp + reserveDown) }
  let base : FacAuditResult :=
    { certId := cert.certId
      claimId := sub.claimId
      insuredName := cert.insuredName
      line := cert.line.toString
      verdict := verdict
      explanation := explainVerdict cert sub ourPaid incurred oslr grossCash (ourPaid - sub.priorPaidUsd) over under
      ourIndemnityUsd := ourInd
      ourAlaeUsd := ourAlae
      ourCumulativePayableUsd := ourPaid
      ourCumulativePaidUsd := ourPaid
      ourCumulativeIncurredUsd := incurred
      verifiedEndingOslrUsd := oslr
      priorPaidUsd := sub.priorPaidUsd
      priorOslrBookedUsd := priorOslr
      grossCashPayableNowUsd := grossCash
      premiumOffsetUsd := offset
      netCashWireDueUsd := netWire
      cedentBilledNowUsd := sub.cedentBilledNowUsd
      overbilledUsd := over
      underbilledUsd := under
      ruschlikonStatus := status
      acordResponseCode := status.acordCode
      voucher := voucher
      leanSpecCode := renderLeanFacSpec cert sub
      backTranslation := informalizeFacCertificate cert
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
  totalPremiumOffsetUsd : Nat
  totalNetWireUsd : Nat
  totalEndingOslrUsd : Nat
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
        signedShareBps := 0, alaeClause := .excluded, grossPremiumUsd := 0,
        brokerageBps := 0, paidPremiumToDateUsd := 0, insuredGroup := "" }

def auditFacBundle (b : FacBundle) : FacPortfolioAudit :=
  let results := b.claims.map (fun sub => auditFacClaim (lookupCert b.certificates sub.certId) sub)
  { deskName := b.deskName
    results := results
    totalBilledUsd := results.foldl (fun a r => a + r.cedentBilledNowUsd) 0
    totalVerifiedUsd := results.foldl (fun a r => a + r.grossCashPayableNowUsd) 0
    totalOverbilledUsd := results.foldl (fun a r => a + r.overbilledUsd) 0
    totalUnderbilledUsd := results.foldl (fun a r => a + r.underbilledUsd) 0
    totalPremiumOffsetUsd := results.foldl (fun a r => a + r.premiumOffsetUsd) 0
    totalNetWireUsd := results.foldl (fun a r => a + r.netCashWireDueUsd) 0
    totalEndingOslrUsd := results.foldl (fun a r => a + r.verifiedEndingOslrUsd) 0
    disputeCount := results.foldl (fun a r => if r.overbilledUsd > 0 then a + 1 else a) 0 }

/-! ## Proofs -/

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

theorem div_add_div_le (a b d : Nat) : a / d + b / d ≤ (a + b) / d := by
  cases d with
  | zero => simp
  | succ k =>
      rw [Nat.le_div_iff_mul_le (Nat.succ_pos k)]
      calc (a / (k + 1) + b / (k + 1)) * (k + 1)
          = a / (k + 1) * (k + 1) + b / (k + 1) * (k + 1) := Nat.add_mul _ _ _
        _ ≤ a + b := Nat.add_le_add (Nat.div_mul_le_self a (k + 1))
                                   (Nat.div_mul_le_self b (k + 1))

theorem included_split_exact (cert : FacCertificate) (ind alae : Nat)
    (hClause : cert.alaeClause = .includedInLimit) :
    layerInd100 cert ind + layerAlae100 cert ind alae = layerTotal100 cert ind alae := by
  unfold layerAlae100
  rw [hClause]
  simp only
  unfold layerInd100 layerTotal100
  omega

theorem share_le_of_valid (cert : FacCertificate) (h : cert.isValid = true) :
    cert.signedShareBps ≤ 10000 := by
  unfold FacCertificate.isValid at h
  simp at h
  exact h.2.1

theorem share_pos_of_valid (cert : FacCertificate) (h : cert.isValid = true) :
    0 < cert.signedShareBps := by
  unfold FacCertificate.isValid at h
  simp at h
  exact h.1

/-- A share at or below 100% never scales an amount upwards. -/
theorem mul_div_self_le (a s : Nat) (h : s ≤ 10000) : a * s / 10000 ≤ a :=
  Nat.div_le_of_le_mul (by
    calc a * s ≤ a * 10000 := Nat.mul_le_mul_left a h
      _ = 10000 * a := Nat.mul_comm _ _)

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

theorem facIncremental_conservation (cumPayable priorPaid : Nat) (h : priorPaid ≤ cumPayable) :
    priorPaid + (cumPayable - priorPaid) = cumPayable := by
  omega

theorem facOverbill_reconciliation (billed verified : Nat) (h : verified ≤ billed) :
    verified + (billed - verified) = billed := by
  omega

/-- **Net premium never exceeds gross premium.** Brokerage can only reduce it. -/
theorem netPremiumDue_le_gross (c : FacCertificate) :
    c.netPremiumDueUsd ≤ c.grossPremiumUsd := by
  unfold FacCertificate.netPremiumDueUsd
  omega

/-- **Paid plus ending reserve equals incurred.** The case reserve is exactly the
gap between what the layer has incurred and what it has paid. -/
theorem paid_plus_endingOslr_eq_incurred (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).ourCumulativePaidUsd +
      (auditFacClaim cert sub).verifiedEndingOslrUsd =
        (auditFacClaim cert sub).ourCumulativeIncurredUsd := by
  unfold auditFacClaim
  simp only
  omega

/-- **Leg A balances.** Cash paid-claims expense equals the premium offset plus
the wire: the wire is never larger than the cash liability. -/
theorem cashSettlement_balanced (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).grossCashPayableNowUsd =
      (auditFacClaim cert sub).premiumOffsetUsd +
        (auditFacClaim cert sub).netCashWireDueUsd := by
  unfold auditFacClaim
  simp only
  split <;> omega

/-- **Leg B balances.** Reserve increases debit expense and credit liability;
reserve releases debit the liability and credit the expense. Either way, the
two sides are equal. -/
theorem oslrMovement_balanced (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).voucher.reserveTotalDebitUsd =
      (auditFacClaim cert sub).voucher.reserveTotalCreditUsd := by
  unfold auditFacClaim
  rfl

/-- **The whole voucher balances.** Leg A plus Leg B: total debits equal total
credits for every certificate, claim, reserve position and premium offset. -/
theorem fullFacVoucher_balanced (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).voucher.grandTotalDebitUsd =
      (auditFacClaim cert sub).voucher.grandTotalCreditUsd := by
  unfold auditFacClaim
  simp only
  split <;> omega

/-- The cash leg is the v0.5 journal identity under a new name. -/
theorem facJournal_balanced (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).voucher.cashTotalDebitUsd =
      (auditFacClaim cert sub).voucher.cashTotalCreditUsd := by
  unfold auditFacClaim
  simp only
  split <;> omega

/-- The verified increment never exceeds cumulative liability. -/
theorem facVerified_le_cumulative (cert : FacCertificate) (sub : FacClaimSubmission) :
    (auditFacClaim cert sub).grossCashPayableNowUsd ≤
      (auditFacClaim cert sub).ourCumulativePaidUsd := by
  unfold auditFacClaim
  simp only
  omega

/-- Verified plus overbilled equals billed: the desk's reconciliation identity
at the level of the audit result. -/
theorem facBilled_reconciles (cert : FacCertificate) (sub : FacClaimSubmission)
    (h : (auditFacClaim cert sub).grossCashPayableNowUsd ≤ sub.cedentBilledNowUsd) :
    (auditFacClaim cert sub).grossCashPayableNowUsd +
      (auditFacClaim cert sub).overbilledUsd = sub.cedentBilledNowUsd := by
  unfold auditFacClaim
  simp only
  exact facOverbill_reconciliation _ _ h

end ReinsuranceLeanCockpit
