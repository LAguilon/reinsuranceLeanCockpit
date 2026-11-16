import ReinsuranceLeanCockpit.Facultative

namespace ReinsuranceLeanCockpit

/-!
# ACORD GRLC / Ruschlikon straight-through processing

Ruschlikon STP is an agreement between cedents, brokers and reinsurers to settle
claims and technical accounts without re-keying. The value comes from *not*
touching a clean claim; the risk comes from auto-approving a dirty one.

The classifier is therefore a safety device, not a convenience. Its three
theorems say exactly what the guardrail guarantees:

* a claim can only reach `AGD` if the certificate is valid and nothing was
  over- or under-billed;
* an overbilled claim can never be auto-agreed, and can never be silently
  absorbed into an offset;
* an invalid certificate is rejected before any arithmetic is considered.

The settlement code itself lives in `Facultative.lean` next to the audit result
that carries it, so the classifier and the JSON cannot disagree. This module is
the ACORD-facing surface: code mapping, the alias the adapter calls, and the
proofs.
-/

/-- Ruschlikon classification for a certificate and its audit result. -/
abbrev classifyRuschlikonStp (cert : FacCertificate) (res : FacAuditResult) : RuschlikonStatus :=
  classifyStp cert.isValid res.overbilledUsd res.underbilledUsd res.premiumOffsetUsd

/-- **Formal STP safety guarantee.** Auto-agreement is only reachable when the
certificate is valid and the bill matches the certificate exactly. An overbilled
claim can never auto-approve through STP. -/
theorem stpAutoAgreed_implies_valid_and_zero_overbill
    (cert : FacCertificate) (res : FacAuditResult)
    (h : classifyRuschlikonStp cert res = .STP_AUTO_AGREED) :
    cert.isValid = true ∧ res.overbilledUsd = 0 ∧ res.underbilledUsd = 0 := by
  unfold classifyRuschlikonStp classifyStp at h
  by_cases hv : cert.isValid = true
  · by_cases ho : res.overbilledUsd > 0
    · simp [hv, ho] at h
    · by_cases hu : res.underbilledUsd > 0
      · simp [hv, ho, hu] at h
      · have ho0 : res.overbilledUsd = 0 := by omega
        have hu0 : res.underbilledUsd = 0 := by omega
        by_cases hp : res.premiumOffsetUsd > 0
        · simp [hv, ho, hu, hp] at h
        · exact ⟨hv, ho0, hu0⟩
  · simp [hv] at h

/-- **An overbilled claim is never auto-agreed and never silently offset.** It is
queried back to the broker or rejected outright. -/
theorem overbilled_always_queried_or_rejected
    (cert : FacCertificate) (res : FacAuditResult) (h : res.overbilledUsd > 0) :
    classifyRuschlikonStp cert res ≠ .STP_AUTO_AGREED ∧
      classifyRuschlikonStp cert res ≠ .STP_OFFSET_APPLIED := by
  unfold classifyRuschlikonStp classifyStp
  by_cases hv : cert.isValid = true
  · simp [hv, h]
  · simp [hv]

/-- **Invalid certificates never reach the settlement path.** -/
theorem invalidCert_always_rejected
    (cert : FacCertificate) (res : FacAuditResult) (h : cert.isValid = false) :
    classifyRuschlikonStp cert res = .GATEKEEPER_REJECTED := by
  unfold classifyRuschlikonStp classifyStp
  simp [h]

end ReinsuranceLeanCockpit
