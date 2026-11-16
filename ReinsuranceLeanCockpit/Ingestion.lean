import ReinsuranceLeanCockpit.Diagnostics
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

end ReinsuranceLeanCockpit
