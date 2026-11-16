import ReinsuranceLeanCockpit.Contracts

namespace ReinsuranceLeanCockpit

/-!
# The formal gatekeeper

Everything that enters the cockpit — a JSON file, a PDF slip, an API request —
has to pass through here before it is allowed to influence a number.

The reason is not bookkeeping. Every headline bound in this library is stated
with an `isValid = true` hypothesis:

  `evalContractPayout_le_loss (c) (…) (h : c.isValid = true) : payout ≤ loss`

A contract with `shareBps = 11500` does not merely produce a silly number; it
falls outside the theorem, and a silent fallback to "just compute anyway" would
turn a proof into a decoration. So ingestion is two-phase: parse, then admit.
`validateContract` is the admission decision, and it is proved to agree exactly
with the `isValid` predicate the theorems consume.
-/

/-! ## Errors -/

/-- Why a slip was rejected. Each constructor names the contract and the
offending numbers, so the message can quote them without re-reading the file. -/
inductive ContractValidationError where
  | shareExceeds100Pct (contractId : String) (shareBps : Nat)
  | commissionExceeds100Pct (contractId : String) (commissionBps : Nat)
  | occExceedsAggLimit (contractId : String) (occLimit aggLimit : Nat)
  /-- Reserved for reinstatement rates above 200% of premium. That is
  commercially unusual, not structurally invalid, so it is raised by
  `advisoryNotices` and deliberately excluded from the gate. -/
  | reinstRateExcessive (contractId : String)
  /-- Fallback for a contract that is invalid for a reason without its own
  constructor (currently: a surplus share with a zero retention line or zero
  lines). Guarantees `validateContract` is empty exactly when the contract is
  valid. -/
  | invalidContractTerms (contractId : String)
  deriving Repr, DecidableEq, BEq

def ContractValidationError.toString : ContractValidationError → String
  | .shareExceeds100Pct id bps =>
      s!"{id}: quota share {bps} bps exceeds 100% (10000 bps)"
  | .commissionExceeds100Pct id bps =>
      s!"{id}: ceding commission {bps} bps exceeds 100% (10000 bps)"
  | .occExceedsAggLimit id occ agg =>
      s!"{id}: occurrence limit {occ} exceeds aggregate limit {agg}"
  | .reinstRateExcessive id =>
      s!"{id}: reinstatement rate exceeds 200% of premium"
  | .invalidContractTerms id =>
      s!"{id}: contract terms fail structural validity"

instance : ToString ContractValidationError := ⟨ContractValidationError.toString⟩

open ContractValidationError

/-! ## The gate -/

/-- Blocking validation errors. Empty if and only if `c.isValid = true`;
that equivalence is `validateContract_isEmpty_iff` below, not an assertion. -/
def validateContract (c : BoundContract) : List ContractValidationError :=
  match c.kind with
  | .xol _ occLimit aggLimit _ _ =>
      if occLimit ≤ aggLimit then []
      else [occExceedsAggLimit c.id occLimit aggLimit]
  | .quotaShare shareBps _ commissionBps =>
      (if shareBps ≤ 10000 then [] else [shareExceeds100Pct c.id shareBps]) ++
      (if commissionBps ≤ 10000 then [] else [commissionExceeds100Pct c.id commissionBps])
  | .surplusShare retentionLine numLines _ =>
      if 0 < retentionLine && 0 < numLines then [] else [invalidContractTerms c.id]
  | .aggregateStopLoss _ _ => []

/-- Human-readable messages, one per blocking error. -/
def checkContractDetails (c : BoundContract) : List String :=
  (validateContract c).map (fun e => e.toString)

/-- Non-blocking commercial advisories. These do not make a contract invalid,
so they must never appear in `validateContract` — a gate that rejects
commercially unusual but legal terms is a gate people route around. -/
def advisoryNotices (c : BoundContract) : List ContractValidationError :=
  match c.kind with
  | .xol _ _ _ rate _ => if 20000 < rate then [reinstRateExcessive c.id] else []
  | _ => []

/-- A portfolio is admissible when every contract in it is. -/
def isPortfolioValid (contracts : List BoundContract) : Bool :=
  contracts.all (fun c => c.isValid)

/-- All blocking errors across a portfolio, tagged by contract. -/
def portfolioValidationErrors (contracts : List BoundContract) : List String :=
  contracts.foldl (fun acc c => acc ++ checkContractDetails c) []

/-! ## Proofs -/

@[simp] theorem isPortfolioValid_nil : isPortfolioValid [] = true := rfl

theorem isPortfolioValid_cons (c : BoundContract) (cs : List BoundContract) :
    isPortfolioValid (c :: cs) = (c.isValid && isPortfolioValid cs) := rfl

/-- **The gate is the same predicate the theorems use.** If a portfolio passes
validation, every contract in it satisfies the `isValid = true` hypothesis that
`evalContractPayout_le_loss` and `applyInuringTower_conservation` require. -/
theorem isPortfolioValid_forall (cs : List BoundContract) (h : isPortfolioValid cs = true) :
    ∀ c ∈ cs, c.isValid = true := by
  induction cs with
  | nil => intro c hc; simp at hc
  | cons head tail ih =>
      intro c hc
      simp only [isPortfolioValid, List.all_cons, Bool.and_eq_true] at h
      rcases List.mem_cons.mp hc with rfl | hmem
      · exact h.1
      · exact ih h.2 c hmem

/-- `validateContract` is empty exactly when the contract is valid. This is the
bridge between the gatekeeper and the theorem preconditions. -/
theorem validateContract_isEmpty_iff (c : BoundContract) :
    (validateContract c).isEmpty = c.isValid := by
  unfold validateContract BoundContract.isValid
  cases hk : c.kind with
  | xol att occ agg rate premium =>
      by_cases h : occ ≤ agg <;> simp [ContractKind.isValid, h]
  | quotaShare shareBps eventCap commissionBps =>
      by_cases h1 : shareBps ≤ 10000 <;> by_cases h2 : commissionBps ≤ 10000 <;>
        simp [ContractKind.isValid, h1, h2]
  | surplusShare retentionLine numLines eventCap =>
      by_cases h1 : 0 < retentionLine <;> by_cases h2 : 0 < numLines <;>
        simp [ContractKind.isValid, h1, h2]
  | aggregateStopLoss aggAttachment aggLimit =>
      simp [ContractKind.isValid]

/-- A valid contract produces no blocking messages. -/
theorem checkContractDetails_eq_nil_of_valid (c : BoundContract) (h : c.isValid = true) :
    checkContractDetails c = [] := by
  unfold checkContractDetails
  have hv : validateContract c = [] := by
    have e := validateContract_isEmpty_iff c
    rw [h] at e
    cases hc : validateContract c with
    | nil => rfl
    | cons x xs => rw [hc] at e; simp at e
  rw [hv]
  rfl

/-- A portfolio with no contracts has no validation errors. -/
theorem portfolioValidationErrors_nil : portfolioValidationErrors [] = [] := rfl

end ReinsuranceLeanCockpit
