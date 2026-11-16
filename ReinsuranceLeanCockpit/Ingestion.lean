import ReinsuranceLeanCockpit.Simulation
import Lean.Data.Json

namespace ReinsuranceLeanCockpit

open Lean

/-!
# JSON ingestion and emission

`Lean.Data.Json` only: no parser library, no schema library. The encoding is
deliberately explicit — a contract kind is a tagged object, an FX table is a
list of `{currency, cents}` pairs — so a malformed file fails with a field name
rather than a positional mismatch.

Money and rates are plain JSON numbers. They are `Nat` all the way through, so
nothing is lost in the round trip.
-/

/-! ## Enum codecs -/

def currencyOfString? : String → Option Currency
  | "EUR" => some .EUR
  | "USD" => some .USD
  | "GBP" => some .GBP
  | "JPY" => some .JPY
  | _ => none

def perilOfString? : String → Option Peril
  | "Windstorm" => some .Windstorm
  | "Earthquake" => some .Earthquake
  | "Flood" => some .Flood
  | "Cyber" => some .Cyber
  | _ => none

def ratingOfString? : String → Option CreditRating
  | "AAA" => some .AAA
  | "AA" => some .AA
  | "A" => some .A
  | "BBB" => some .BBB
  | "Unrated" => some .Unrated
  | _ => none

def directionOfString? : String → Option Direction
  | "inward" => some .inward
  | "outward" => some .outward
  | _ => none

def severityOfString? : String → Option Severity
  | "CRITICAL" => some .CRITICAL
  | "WARNING" => some .WARNING
  | "INFO" => some .INFO
  | _ => none

instance : ToJson Currency := ⟨fun c => Json.str c.toString⟩
instance : ToJson Peril := ⟨fun p => Json.str p.toString⟩
instance : ToJson CreditRating := ⟨fun r => Json.str r.toString⟩
instance : ToJson Direction := ⟨fun d => Json.str d.toString⟩
instance : ToJson Severity := ⟨fun s => Json.str s.toString⟩

instance : FromJson Currency where
  fromJson? j := do
    let s ← j.getStr?
    match currencyOfString? s with
    | some c => pure c
    | none => throw s!"unknown currency: {s}"

instance : FromJson Peril where
  fromJson? j := do
    let s ← j.getStr?
    match perilOfString? s with
    | some p => pure p
    | none => throw s!"unknown peril: {s}"

instance : FromJson CreditRating where
  fromJson? j := do
    let s ← j.getStr?
    match ratingOfString? s with
    | some r => pure r
    | none => throw s!"unknown credit rating: {s}"

instance : FromJson Direction where
  fromJson? j := do
    let s ← j.getStr?
    match directionOfString? s with
    | some d => pure d
    | none => throw s!"unknown direction: {s}"

instance : FromJson Severity where
  fromJson? j := do
    let s ← j.getStr?
    match severityOfString? s with
    | some v => pure v
    | none => throw s!"unknown severity: {s}"

/-! ## Contract kind -/

def ContractKind.toJson : ContractKind → Json
  | .xol attachment occLimit aggLimit reinstRateBps basePremium =>
      Json.mkObj
        [ ("type", Json.str "xol")
        , ("attachment", ToJson.toJson attachment)
        , ("occLimit", ToJson.toJson occLimit)
        , ("aggLimit", ToJson.toJson aggLimit)
        , ("reinstRateBps", ToJson.toJson reinstRateBps)
        , ("basePremium", ToJson.toJson basePremium) ]
  | .quotaShare shareBps eventCap commissionBps =>
      Json.mkObj
        [ ("type", Json.str "quotaShare")
        , ("shareBps", ToJson.toJson shareBps)
        , ("eventCap", ToJson.toJson eventCap)
        , ("commissionBps", ToJson.toJson commissionBps) ]
  | .surplusShare retentionLine numLines eventCap =>
      Json.mkObj
        [ ("type", Json.str "surplusShare")
        , ("retentionLine", ToJson.toJson retentionLine)
        , ("numLines", ToJson.toJson numLines)
        , ("eventCap", ToJson.toJson eventCap) ]
  | .aggregateStopLoss aggAttachment aggLimit =>
      Json.mkObj
        [ ("type", Json.str "aggregateStopLoss")
        , ("aggAttachment", ToJson.toJson aggAttachment)
        , ("aggLimit", ToJson.toJson aggLimit) ]

instance : ToJson ContractKind := ⟨ContractKind.toJson⟩

instance : FromJson ContractKind where
  fromJson? j := do
    let t ← j.getObjValAs? String "type"
    match t with
    | "xol" =>
        let attachment ← j.getObjValAs? Nat "attachment"
        let occLimit ← j.getObjValAs? Nat "occLimit"
        let aggLimit ← j.getObjValAs? Nat "aggLimit"
        let reinstRateBps ← j.getObjValAs? Nat "reinstRateBps"
        let basePremium ← j.getObjValAs? Nat "basePremium"
        pure (.xol attachment occLimit aggLimit reinstRateBps basePremium)
    | "quotaShare" =>
        let shareBps ← j.getObjValAs? Nat "shareBps"
        let eventCap ← j.getObjValAs? Nat "eventCap"
        let commissionBps ← j.getObjValAs? Nat "commissionBps"
        pure (.quotaShare shareBps eventCap commissionBps)
    | "surplusShare" =>
        let retentionLine ← j.getObjValAs? Nat "retentionLine"
        let numLines ← j.getObjValAs? Nat "numLines"
        let eventCap ← j.getObjValAs? Nat "eventCap"
        pure (.surplusShare retentionLine numLines eventCap)
    | "aggregateStopLoss" =>
        let aggAttachment ← j.getObjValAs? Nat "aggAttachment"
        let aggLimit ← j.getObjValAs? Nat "aggLimit"
        pure (.aggregateStopLoss aggAttachment aggLimit)
    | other => throw s!"unknown contract kind: {other}"

/-! ## Contracts and portfolios -/

instance : ToJson BoundContract where
  toJson c :=
    Json.mkObj
      [ ("id", Json.str c.id)
      , ("name", Json.str c.name)
      , ("counterparty", Json.str c.counterparty)
      , ("rating", ToJson.toJson c.rating)
      , ("direction", ToJson.toJson c.direction)
      , ("currency", ToJson.toJson c.currency)
      , ("perils", ToJson.toJson c.perils)
      , ("inuringPriority", ToJson.toJson c.inuringPriority)
      , ("kind", ToJson.toJson c.kind) ]

instance : FromJson BoundContract where
  fromJson? j := do
    let id ← j.getObjValAs? String "id"
    let name ← j.getObjValAs? String "name"
    let counterparty ← j.getObjValAs? String "counterparty"
    let rating ← j.getObjValAs? CreditRating "rating"
    let direction ← j.getObjValAs? Direction "direction"
    let currency ← j.getObjValAs? Currency "currency"
    let perils ← j.getObjValAs? (List Peril) "perils"
    let inuringPriority ← j.getObjValAs? Nat "inuringPriority"
    let kind ← j.getObjValAs? ContractKind "kind"
    pure { id := id, name := name, counterparty := counterparty, rating := rating,
           direction := direction, currency := currency, perils := perils,
           inuringPriority := inuringPriority, kind := kind }

def fxTableToJson (xs : List (Currency × Nat)) : Json :=
  Json.arr (xs.toArray.map fun (c, n) =>
    Json.mkObj [("currency", ToJson.toJson c), ("cents", ToJson.toJson n)])

def fxTableFromJson (j : Json) : Except String (List (Currency × Nat)) := do
  let arr ← j.getArr?
  arr.toList.mapM fun e => do
    let c ← e.getObjValAs? Currency "currency"
    let n ← e.getObjValAs? Nat "cents"
    pure (c, n)

instance : ToJson BoundPortfolio where
  toJson p :=
    Json.mkObj
      [ ("name", Json.str p.name)
      , ("ownFundsEur", ToJson.toJson p.ownFundsEur)
      , ("otherScrEur", ToJson.toJson p.otherScrEur)
      , ("maxSingleEventAppetiteEur", ToJson.toJson p.maxSingleEventAppetiteEur)
      , ("fxRatesToEurCents", fxTableToJson p.fxRatesToEurCents)
      , ("contracts", ToJson.toJson p.contracts) ]

instance : FromJson BoundPortfolio where
  fromJson? j := do
    let name ← j.getObjValAs? String "name"
    let ownFundsEur ← j.getObjValAs? Nat "ownFundsEur"
    let otherScrEur ← j.getObjValAs? Nat "otherScrEur"
    let appetite ← j.getObjValAs? Nat "maxSingleEventAppetiteEur"
    let fxJson ← j.getObjVal? "fxRatesToEurCents"
    let fx ← fxTableFromJson fxJson
    let contracts ← j.getObjValAs? (List BoundContract) "contracts"
    pure { name := name, ownFundsEur := ownFundsEur, otherScrEur := otherScrEur
           maxSingleEventAppetiteEur := appetite, fxRatesToEurCents := fx
           contracts := contracts }

/-! ## Report codecs -/

instance : ToJson LoopholeFinding where
  toJson f :=
    Json.mkObj
      [ ("severity", ToJson.toJson f.severity)
      , ("kind", Json.str f.kind)
      , ("message", Json.str f.message)
      , ("amountEur", ToJson.toJson f.amountEur) ]

instance : ToJson ExposureRow where
  toJson r :=
    Json.mkObj
      [ ("label", Json.str r.label)
      , ("inwardsEur", ToJson.toJson r.inwardsEur)
      , ("outwardsEur", ToJson.toJson r.outwardsEur)
      , ("netUnhedgedEur", ToJson.toJson r.netUnhedgedEur) ]

instance : ToJson PortfolioStress where
  toJson s :=
    Json.mkObj
      [ ("scenarioName", Json.str s.scenarioName)
      , ("netCatLossEur", ToJson.toJson s.netCatLossEur)
      , ("reinstCostEur", ToJson.toJson s.reinstCostEur)
      , ("otherScrEur", ToJson.toJson s.otherScrEur)
      , ("counterpartyScrEur", ToJson.toJson s.counterpartyScrEur)
      , ("totalScrEur", ToJson.toJson s.totalScrEur)
      , ("ownFundsEur", ToJson.toJson s.ownFundsEur)
      , ("solvencyRatioPct", ToJson.toJson s.solvencyRatioPct)
      , ("isSolvent", ToJson.toJson s.isSolvent) ]

instance : ToJson PortfolioAuditReport where
  toJson r :=
    Json.mkObj
      [ ("portfolio", Json.str r.portfolio)
      , ("contractCount", ToJson.toJson r.contractCount)
      , ("allContractsValid", ToJson.toJson r.allContractsValid)
      , ("validationErrors", ToJson.toJson r.validationErrors)
      , ("exposureByCurrency", ToJson.toJson r.exposureByCurrency)
      , ("exposureByPeril", ToJson.toJson r.exposureByPeril)
      , ("findings", ToJson.toJson r.findings)
      , ("stress", ToJson.toJson r.stress)
      , ("criticalCount", ToJson.toJson r.criticalCount)
      , ("warningCount", ToJson.toJson r.warningCount)
      , ("infoCount", ToJson.toJson r.infoCount)
      , ("totalFound", ToJson.toJson r.totalFound) ]

/-! ## File IO -/

/-- Parse a portfolio from a file. Errors name the field that failed. -/
def loadPortfolio (path : System.FilePath) : IO BoundPortfolio := do
  let text ← IO.FS.readFile path
  match Json.parse text with
  | .error e => throw (IO.userError s!"{path}: invalid JSON: {e}")
  | .ok j =>
      match fromJson? j with
      | .error e => throw (IO.userError s!"{path}: invalid portfolio: {e}")
      | .ok p => pure p

/-- Compact single-line JSON of the verified audit report, for downstream
web/PDF pipelines. -/
def auditReportJson (p : BoundPortfolio) : String :=
  Json.compress (ToJson.toJson (auditPortfolio p))

/-! ## Scenario codecs -/

instance : ToJson ScenarioEvent where
  toJson e :=
    Json.mkObj
      [ ("eventName", Json.str e.eventName)
      , ("peril", ToJson.toJson e.peril)
      , ("currency", ToJson.toJson e.currency)
      , ("groundUpLoss", ToJson.toJson e.groundUpLoss) ]

instance : FromJson ScenarioEvent where
  fromJson? j := do
    let eventName ← j.getObjValAs? String "eventName"
    let peril ← j.getObjValAs? Peril "peril"
    let currency ← j.getObjValAs? Currency "currency"
    let groundUpLoss ← j.getObjValAs? Nat "groundUpLoss"
    pure { eventName := eventName, peril := peril, currency := currency
           groundUpLoss := groundUpLoss }

instance : ToJson StressScenario where
  toJson s :=
    Json.mkObj
      [ ("scenarioName", Json.str s.scenarioName)
      , ("fxOverridesToEurCents", fxTableToJson s.fxOverridesToEurCents)
      , ("events", ToJson.toJson s.events) ]

instance : FromJson StressScenario where
  fromJson? j := do
    let scenarioName ← j.getObjValAs? String "scenarioName"
    let fxJson ← j.getObjVal? "fxOverridesToEurCents"
    let fx ← fxTableFromJson fxJson
    let events ← j.getObjValAs? (List ScenarioEvent) "events"
    pure { scenarioName := scenarioName, fxOverridesToEurCents := fx, events := events }

instance : ToJson EventSimulationResult where
  toJson r :=
    Json.mkObj
      [ ("eventName", Json.str r.eventName)
      , ("peril", ToJson.toJson r.peril)
      , ("currency", ToJson.toJson r.currency)
      , ("groundUpLoss", ToJson.toJson r.groundUpLoss)
      , ("inwardGrossEur", ToJson.toJson r.inwardGrossEur)
      , ("outwardRecoveredEur", ToJson.toJson r.outwardRecoveredEur)
      , ("netRetainedEur", ToJson.toJson r.netRetainedEur)
      , ("reinstFeeEur", ToJson.toJson r.reinstFeeEur) ]

instance : ToJson ScenarioSimulationReport where
  toJson r :=
    Json.mkObj
      [ ("scenarioName", Json.str r.scenarioName)
      , ("portfolioName", Json.str r.portfolioName)
      , ("allContractsValid", ToJson.toJson r.allContractsValid)
      , ("validationErrors", ToJson.toJson r.validationErrors)
      , ("events", ToJson.toJson r.events)
      , ("annualInwardGrossEur", ToJson.toJson r.annualInwardGrossEur)
      , ("annualOutwardRecoveredEur", ToJson.toJson r.annualOutwardRecoveredEur)
      , ("annualNetBeforeStopLossEur", ToJson.toJson r.annualNetBeforeStopLossEur)
      , ("stopLossRecoveredEur", ToJson.toJson r.stopLossRecoveredEur)
      , ("annualFinalNetLossEur", ToJson.toJson r.annualFinalNetLossEur)
      , ("totalReinstFeeEur", ToJson.toJson r.totalReinstFeeEur)
      , ("counterpartyScrEur", ToJson.toJson r.counterpartyScrEur)
      , ("otherScrEur", ToJson.toJson r.otherScrEur)
      , ("totalScrEur", ToJson.toJson r.totalScrEur)
      , ("initialOwnFundsEur", ToJson.toJson r.initialOwnFundsEur)
      , ("ownFundsEur", ToJson.toJson r.ownFundsEur)
      , ("seasonLossDrainEur", ToJson.toJson r.seasonLossDrainEur)
      , ("postSeasonOwnFundsEur", ToJson.toJson r.postSeasonOwnFundsEur)
      , ("postSeasonScrEur", ToJson.toJson r.postSeasonScrEur)
      , ("isEquityWipedOut", ToJson.toJson r.isEquityWipedOut)
      , ("postSeasonSolvencyRatioPct", ToJson.toJson r.postSeasonSolvencyRatioPct)
      , ("preSeasonSolvencyRatioPct", ToJson.toJson r.preSeasonSolvencyRatioPct)
      , ("solvencyRatioPct", ToJson.toJson r.solvencyRatioPct)
      , ("isSolvent", ToJson.toJson r.isSolvent) ]

/-- Load a stress scenario from a file. -/
def loadScenario (path : System.FilePath) : IO StressScenario := do
  let text ← IO.FS.readFile path
  match Json.parse text with
  | .error e => throw (IO.userError s!"{path}: invalid JSON: {e}")
  | .ok j =>
      match fromJson? j with
      | .error e => throw (IO.userError s!"{path}: invalid scenario: {e}")
      | .ok s => pure s

/-! ## Kernel Proof Certificate Registry -/

/-- One kernel-checked theorem, in the form the web cockpit displays. -/
structure TheoremRecord where
  name : String
  module : String
  statement : String
  deriving Repr

instance : ToJson TheoremRecord where
  toJson r :=
    Json.mkObj
      [ ("name", Json.str r.name)
      , ("module", Json.str r.module)
      , ("statement", Json.str r.statement) ]

def theoremRecord (name module statement : String) : TheoremRecord :=
  { name := name, module := module, statement := statement }

/-- Every theorem proved by the kernel in this repository, with the claim it
makes. The web cockpit renders this list directly, and `lake exe cockpit
theorems --json` is the canonical machine-readable form.

A theorem missing from this list is not "unproved" — it is simply not surfaced
in the UI. The axiom audit in `scripts/AxiomAudit.lean` is the authority on what
depends on what. -/
def verifiedTheorems : List TheoremRecord :=
  [ theoremRecord "xolPayout_le_loss" "Core"
      "XoL payout never exceeds the underlying loss."
  , theoremRecord "xolPayout_bounded" "Core"
      "XoL payout never exceeds the occurrence limit or the remaining aggregate limit."
  , theoremRecord "xol_loss_conservation" "Core"
      "Net retained plus XoL payout equals the gross loss."
  , theoremRecord "qsPayout_le_loss" "Core"
      "Quota-share payout never exceeds the loss when the share is at most 100%."
  , theoremRecord "stepXoLTreaty_agg_safe" "Core"
      "One treaty step partitions available aggregate capacity: payout plus remaining equals available."
  , theoremRecord "stepXoLTreaty_remAgg_le" "Core"
      "A treaty step can only consume aggregate capacity, never create it."
  , theoremRecord "evaluateSolvency_totalScr" "Solvency"
      "The reported total SCR equals the sum of its three components."
  , theoremRecord "evaluateSolvency_isSolvent_iff" "Solvency"
      "The solvency flag is exactly the ratio-at-least-100% test."
  , theoremRecord "solvencyRatioPct_zero_scr" "Solvency"
      "A zero SCR yields the 999 sentinel ratio."
  , theoremRecord "solvencyRatioPct_pos" "Solvency"
      "With positive SCR the ratio is the integer percentage, rounded down."
  , theoremRecord "solvencyRatioPct_mono_ownFunds" "Solvency"
      "Adding own funds never lowers the solvency ratio."
  , theoremRecord "evaluateSolvency_ratio_mono_ownFunds" "Solvency"
      "Adding own funds never makes a solvent company insolvent."
  , theoremRecord "alpine_safe_at_inception_fx" "AlpineShowcase"
      "The naive Alpine structure is safe at 0.80 EUR/USD for every hurricane size."
  , theoremRecord "alpine_fixed_usd_bounded" "AlpineShowcase"
      "The currency-matched structure retains at most 25M USD for every loss."
  , theoremRecord "alpine_fixed_fx_safe" "AlpineShowcase"
      "The currency-matched structure stays under 25M EUR for every loss and every FX at or below parity."
  , theoremRecord "inward_agg_capacity_eq" "AlpineShowcase"
      "The inward treaty's aggregate capacity is exactly twice its occurrence limit."
  , theoremRecord "outward_agg_capacity_eq" "AlpineShowcase"
      "The outward retro's aggregate capacity equals its occurrence limit, with no reinstatement."
  , theoremRecord "surplusPayout_le_loss" "Contracts"
      "A surplus share never pays more than the loss."
  , theoremRecord "stopLossPayout_le_loss" "Contracts"
      "An aggregate stop loss never pays more than the annual loss."
  , theoremRecord "surplusPayout_mono" "Contracts"
      "A surplus share is monotone in the loss."
  , theoremRecord "surplusPayout_zero_below" "Contracts"
      "A surplus share pays nothing below its retention line."
  , theoremRecord "stopLossPayout_zero_below" "Contracts"
      "An aggregate stop loss pays nothing below its attachment."
  , theoremRecord "isValid_quotaShare_shareBps" "Contracts"
      "Validity exposes the quota-share rate bound of at most 100%."
  , theoremRecord "evalContractPayout_le_loss" "Contracts"
      "Every valid contract, of any of the four forms, pays at most the loss."
  , theoremRecord "applyInuringTower_conservation" "Contracts"
      "For any tower of valid contracts, net retained plus total recovered equals the gross loss."
  , theoremRecord "applyInuringTower_recovered_le" "Contracts"
      "For any tower of valid contracts, total recoveries never exceed the gross loss."
  , theoremRecord "applyInuringTower_net_le" "Contracts"
      "For any tower of valid contracts, net retained never exceeds the gross loss."
  , theoremRecord "portfolioStress_totalScr" "Diagnostics"
      "The portfolio SCR total equals its four printed components."
  , theoremRecord "portfolioStress_isSolvent_iff" "Diagnostics"
      "The portfolio solvency flag is exactly the ratio-at-least-100% test."
  , theoremRecord "counterpartyCharge_mono" "Diagnostics"
      "The counterparty default charge is monotone in the recoverable amount."
  , theoremRecord "tally_sum" "Diagnostics"
      "The three severity counts partition the list of findings."
  , theoremRecord "auditPortfolio_totalFound" "Diagnostics"
      "The audit report's finding count equals the length of its finding list."
  , theoremRecord "auditPortfolio_counts_sum" "Diagnostics"
      "The audit report's severity counts add up to its finding total."
  , theoremRecord "isPortfolioValid_nil" "Validation"
      "The empty portfolio is admissible."
  , theoremRecord "isPortfolioValid_cons" "Validation"
      "Portfolio validity unfolds through a conjunction over the head contract and the tail."
  , theoremRecord "isPortfolioValid_forall" "Validation"
      "If a portfolio passes the gate, every contract in it satisfies isValid = true."
  , theoremRecord "validateContract_isEmpty_iff" "Validation"
      "The gatekeeper's blocking-error list is empty exactly when the contract is valid."
  , theoremRecord "checkContractDetails_eq_nil_of_valid" "Validation"
      "A valid contract produces no blocking validation messages."
  , theoremRecord "portfolioValidationErrors_nil" "Validation"
      "The empty portfolio has no validation errors."
  , theoremRecord "applyStopLoss_le_loss" "Simulation"
      "A stop-loss recovery never exceeds the annual net loss."
  , theoremRecord "applyStopLoss_bounded" "Simulation"
      "A stop-loss recovery never exceeds its limit."
  , theoremRecord "netAfterStopLoss_conservation" "Simulation"
      "Net after stop loss plus stop-loss recovery equals the annual net loss."
  , theoremRecord "scenarioReport_scr_sum" "Simulation"
      "The simulation's reported SCR total equals its four printed components."
  , theoremRecord "scenarioReport_isSolvent_iff" "Simulation"
      "The simulation's solvency flag is exactly the ratio-at-least-100% test."
  , theoremRecord "xolPayout_mono" "Monotonicity"
      "XoL payout is monotone in the loss."
  , theoremRecord "netAfterXoL_mono" "Monotonicity"
      "Net retained after XoL is monotone in the loss."
  , theoremRecord "applyStopLoss_mono" "Monotonicity"
      "Stop-loss recovery is monotone in the annual loss."
  , theoremRecord "netAfterStopLoss_mono" "Monotonicity"
      "Net retained after stop loss is monotone in the loss."
  , theoremRecord "qsPayout_mono" "Monotonicity"
      "Quota-share payout is monotone in the loss."
  , theoremRecord "netAfterQS_mono" "Monotonicity"
      "Quota-share net retention is monotone when the share is at most 100%."
  , theoremRecord "netAfterSurplus_mono" "Monotonicity"
      "Surplus-share net retention is monotone in the loss."
  , theoremRecord "evalContractPayout_mono" "Monotonicity"
      "Every valid contract's payout is monotone in the loss."
  , theoremRecord "evalContractNet_mono" "Monotonicity"
      "Every valid contract's net retention is monotone in the loss."
  , theoremRecord "applyInuringTower_net_mono" "Monotonicity"
      "By induction: a larger gross loss leaves a larger net retained loss after any valid tower."
  , theoremRecord "postSeasonOwnFunds_antitone" "Monotonicity"
      "A larger season drain leaves less post-season capital."
  , theoremRecord "postSeasonRatio_antitone_num" "Monotonicity"
      "For a fixed capital requirement, less capital means a lower ratio."
  , theoremRecord "postSeasonRatio_antitone" "Monotonicity"
      "A larger drain or a larger requirement can only lower the post-season solvency ratio."
  , theoremRecord "postSeasonRatio_antitone_fixedScr" "Monotonicity"
      "With a fixed requirement, a larger drain lowers the post-season ratio."
  , theoremRecord "verified_NoOverRecovery" "TrustProofs"
      "Discharges Spec_NoOverRecovery: no valid contract pays more than the loss."
  , theoremRecord "verified_TowerMoneyConservation" "TrustProofs"
      "Discharges Spec_TowerMoneyConservation: tower net plus recovered equals gross."
  , theoremRecord "verified_ContractPayoutMonotone" "TrustProofs"
      "Discharges Spec_ContractPayoutMonotone: payout is monotone in the loss."
  , theoremRecord "verified_TowerNetLossMonotone" "TrustProofs"
      "Discharges Spec_TowerNetLossMonotone: tower net is monotone in the gross loss."
  , theoremRecord "verified_PostSeasonSolvencyAntitone" "TrustProofs"
      "Discharges Spec_PostSeasonSolvencyAntitone: more drain never raises the ratio."
  , theoremRecord "verified_GatekeeperExactness" "TrustProofs"
      "Discharges Spec_GatekeeperExactness: the gate is exactly the isValid predicate."
  , theoremRecord "verified_AlpineUniversalFxFix" "TrustProofs"
      "Discharges Spec_AlpineUniversalFxFix: the FX fix holds for every loss and rate."
  , theoremRecord "verified_NonVacuityWitness" "TrustProofs"
      "Discharges Spec_NonVacuityWitness: a concrete valid contract really pays." ]

def verifiedTheoremsJson : String :=
  Json.compress (ToJson.toJson verifiedTheorems)

def theoremCount : Nat := verifiedTheorems.length

end ReinsuranceLeanCockpit
