/* ReinsuranceLean Cockpit v0.3 — vanilla JS, no framework, no build step. */

const state = {
  presets: null,
  portfolio: null,
  audit: null,
  activePeril: "Windstorm",
  scenario: null,
  undoStack: [],
  theoremCount: 0,
};

const $ = (sel) => document.querySelector(sel);
const PERILS = ["Windstorm", "Earthquake", "Flood", "Cyber"];
const CURRENCIES = ["EUR", "USD", "GBP", "JPY"];

/* ---------- formatting ---------- */
const fmtM = (units) => `€${(units / 1e6).toFixed(1)}M`;
const fmtPct = (pct) => `${pct}%`;

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const body = await res.json();
  if (!res.ok || body.error) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

/* ---------- header ---------- */
function setTheoremCount(n) {
  state.theoremCount = n;
  $("#theoremPill").textContent = `✓ ${n} kernel-checked theorems`;
  $("#theoremCount").textContent = `(${n})`;
}

function setLatency(ms) {
  $("#latencyPill").textContent =
    ms === null || ms === undefined ? "verified in — ms" : `verified in ${ms} ms`;
}

/* ---------- gauge ---------- */
function renderGauge(pct) {
  const svg = $("#gauge");
  const cx = 160, cy = 150, r = 118;
  const capped = Math.min(pct, 200);
  const frac = capped / 200;                    // 0..1 across the semicircle
  const color = pct < 100 ? "#ef4444" : pct < 150 ? "#f59e0b" : "#10b981";

  const polar = (t) => {
    const angle = Math.PI * (1 - t);
    return [cx + r * Math.cos(angle), cy - r * Math.sin(angle)];
  };
  const arcPath = (t0, t1) => {
    const [x0, y0] = polar(t0);
    const [x1, y1] = polar(t1);
    return `M ${x0} ${y0} A ${r} ${r} 0 0 1 ${x1} ${y1}`;
  };

  const ticks = [0, 50, 100, 150, 200]
    .map((v) => {
      const [x, y] = polar(v / 200);
      return `<text x="${x}" y="${y - 6}" fill="#64748b" font-size="9" text-anchor="middle">${v}%</text>`;
    })
    .join("");

  svg.innerHTML = `
    <path d="${arcPath(0, 1)}" stroke="#1f2a44" stroke-width="18" fill="none" stroke-linecap="round"/>
    <path d="${arcPath(0, Math.max(frac, 0.001))}" stroke="${color}" stroke-width="18" fill="none" stroke-linecap="round"/>
    ${ticks}
    <text x="${cx}" y="${cy - 34}" fill="${color}" font-size="40" font-family="ui-monospace, monospace"
          text-anchor="middle" font-weight="700">${pct}%</text>
    <text x="${cx}" y="${cy - 8}" fill="#93a0b8" font-size="11" text-anchor="middle">SOLVENCY II RATIO</text>
  `;
}

/* ---------- SCR bar ---------- */
function renderScr(s) {
  const parts = [
    ["Net cat loss", s.netCatLossEur, "#ef4444"],
    ["Reinstatement fee", s.reinstCostEur, "#f59e0b"],
    ["Counterparty default", s.counterpartyScrEur, "#a78bfa"],
    ["Other SCR", s.otherScrEur, "#60a5fa"],
  ];
  const denom = Math.max(s.totalScrEur, s.ownFundsEur, 1);

  $("#scrBar").innerHTML = parts
    .map(
      ([, v, c]) =>
        `<div class="scr-seg" style="width:${(v / denom) * 100}%;background:${c}"></div>`
    )
    .join("");

  $("#scrLegend").innerHTML = parts
    .map(
      ([name, v, c]) =>
        `<li><span class="sw" style="background:${c}"></span>${name}<span class="amt">${fmtM(v)}</span></li>`
    )
    .join("");

  $("#scrTotal").textContent = `Total SCR ${fmtM(s.totalScrEur)}`;
  $("#ownFunds").textContent = fmtM(s.ownFundsEur);
}

/* ---------- KPIs ---------- */
function renderKpis(a) {
  const stress = a.stress;
  const valid = a.allContractsValid;
  $("#kpiContracts").textContent = a.contractCount;
  const gate = $("#kpiGate");
  gate.textContent = valid ? "gatekeeper: VALID" : "gatekeeper: REJECTED";
  gate.className = valid ? "ok" : "danger";

  $("#kpiCritical").textContent = a.criticalCount;
  $("#kpiCritical").className = a.criticalCount > 0 ? "danger" : "ok";
  $("#kpiWarnings").textContent = `${a.warningCount} warnings · ${a.infoCount} info`;

  const peak = Math.max(...a.exposureByPeril.map((r) => r.netUnhedgedEur), 0);
  $("#kpiPeak").textContent = fmtM(peak);

  const badge = $("#gateBadge");
  badge.textContent = valid
    ? `✓ all ${a.contractCount} contracts admissible`
    : `✗ ${a.validationErrors.length} contract(s) rejected`;
  badge.className = `gate ${valid ? "ok" : "bad"}`;
}

/* ---------- exposure tables ---------- */
function renderExposure(a) {
  const head = `<thead><tr><th>Segment</th><th>Inward</th><th>Outward</th><th>Net unhedged</th></tr></thead>`;
  const rows = (list) =>
    list
      .map(
        (r) =>
          `<tr><td>${r.label}</td><td class="num">${fmtM(r.inwardsEur)}</td>` +
          `<td class="num">${fmtM(r.outwardsEur)}</td><td class="num ${r.netUnhedgedEur > 0 ? "danger" : ""}">${fmtM(r.netUnhedgedEur)}</td></tr>`
      )
      .join("");
  $("#currencyTable").innerHTML = `<caption>Exposure by currency</caption>${head}<tbody>${rows(a.exposureByCurrency)}</tbody>`;
  $("#perilTable").innerHTML = `<caption>Exposure by peril</caption>${head}<tbody>${rows(a.exposureByPeril)}</tbody>`;
}

/* ---------- tower ---------- */
function towerLayers(portfolio, peril, direction) {
  return portfolio.contracts
    .filter((c) => c.direction === direction && (c.perils || []).includes(peril))
    .map((c) => {
      const k = c.kind;
      if (k.type === "xol") return { c, att: k.attachment, top: k.attachment + k.occLimit };
      if (k.type === "surplusShare") {
        const cap = Math.min(k.numLines * k.retentionLine, k.eventCap);
        return { c, att: k.retentionLine, top: k.retentionLine + cap };
      }
      return { c, att: 0, top: k.eventCap || k.aggLimit || 0 };
    })
    .filter((l) => l.top > 0);
}

function renderTower() {
  const svg = $("#tower");
  const p = state.portfolio;
  if (!p) return;
  const peril = state.activePeril;

  const inward = towerLayers(p, peril, "inward").sort((a, b) => a.att - b.att);
  const outwardAll = p.contracts.filter(
    (c) => c.direction === "outward" && (c.perils || []).includes(peril) && c.kind.type === "xol"
  );
  const outward = outwardAll
    .map((c) => ({ c, att: c.kind.attachment, top: c.kind.attachment + c.kind.occLimit, prio: c.inuringPriority }))
    .filter((l) => l.top > 0)
    .sort((a, b) => a.att - b.att);

  const maxVal = Math.max(...inward.map((l) => l.top), ...outward.map((l) => l.top), 1);
  const H = 300, baseY = 330, topY = 30;
  const y = (v) => baseY - (v / maxVal) * (baseY - topY);

  const grid = [0, 0.25, 0.5, 0.75, 1]
    .map((f) => {
      const val = maxVal * f;
      return `<line x1="20" y1="${y(val)}" x2="540" y2="${y(val)}" stroke="#1a2438" stroke-width="1"/>
              <text x="14" y="${y(val) + 3}" fill="#3f4c66" font-size="8" text-anchor="end">${(val / 1e6).toFixed(0)}</text>`;
    })
    .join("");

  const bar = (l, x, w, fill, label, badge) => {
    const yTop = y(l.top);
    const h = Math.max(y(l.att) - yTop, 2);
    const short = h < 16;
    return `<g>
      <rect x="${x}" y="${yTop}" width="${w}" height="${h}" rx="3" fill="${fill}" stroke="rgba(255,255,255,.12)"/>
      <text x="${x + 6}" y="${short ? yTop + h + 10 : yTop + 13}" fill="#dbe4f3" font-size="10" font-family="ui-monospace, monospace">${label}</text>
      ${badge ? `<text x="${x + w - 6}" y="${yTop + 12}" fill="#fca5a5" font-size="8.5" text-anchor="end" font-family="ui-monospace, monospace">${badge}</text>` : ""}
    </g>`;
  };

  const inwardSvg = inward
    .map((l) => bar(l, 40, 170, "rgba(96,165,250,.45)", `${l.c.id} ${fmtM(l.att)}–${fmtM(l.top)}`))
    .join("");

  // gaps between adjacent outward layers
  const gaps = [];
  for (let i = 0; i < outward.length - 1; i++) {
    const lower = outward[i], upper = outward[i + 1];
    if (lower.top < upper.att) gaps.push({ from: lower.top, to: upper.att, lower: lower.c.id, upper: upper.c.id });
  }
  const gapSvg = gaps
    .map((g) => {
      const yTop = y(g.to), h = Math.max(y(g.from) - yTop, 3);
      return `<rect x="330" y="${yTop}" width="190" height="${h}" fill="url(#gapHatch)" stroke="#ef4444" stroke-dasharray="4 3"/>
              <text x="425" y="${yTop + h / 2 + 3}" fill="#fecaca" font-size="9" text-anchor="middle" font-family="ui-monospace, monospace">UNHEDGED GAP ${fmtM(g.to - g.from)}</text>`;
    })
    .join("");

  const outwardSvg = outward
    .map((l) => {
      const bad = l.c.rating === "Unrated" || l.c.rating === "BBB";
      return bar(l, 330, 190, "rgba(16,185,129,.4)", `${l.c.id} ${fmtM(l.att)}–${fmtM(l.top)}`, bad ? l.c.rating.toUpperCase() : "");
    })
    .join("");

  const currenciesIn = [...new Set(inward.map((l) => l.c.currency))];
  const currenciesOut = [...new Set(outward.map((l) => l.c.currency))];
  const mismatch = currenciesIn.length && currenciesOut.length &&
    !currenciesIn.every((c) => currenciesOut.includes(c));

  const note = mismatch
    ? `<text x="280" y="16" fill="#fca5a5" font-size="10" text-anchor="middle" font-family="ui-monospace, monospace">CURRENCY MISMATCH · inward ${currenciesIn.join("/")} vs outward ${currenciesOut.join("/")}</text>`
    : `<text x="280" y="16" fill="#93a0b8" font-size="10" text-anchor="middle">${peril} · inward ${currenciesIn.join("/") || "none"} → outward ${currenciesOut.join("/") || "none"}</text>`;

  svg.innerHTML = `
    <defs>
      <pattern id="gapHatch" width="8" height="8" patternTransform="rotate(45)" patternUnits="userSpaceOnUse">
        <rect width="8" height="8" fill="rgba(239,68,68,.12)"/>
        <line x1="0" y1="0" x2="0" y2="8" stroke="#ef4444" stroke-width="3"/>
      </pattern>
    </defs>
    ${note}
    ${grid}
    <text x="125" y="24" fill="#93a0b8" font-size="10" text-anchor="middle">INWARD ASSUMED</text>
    <text x="425" y="24" fill="#93a0b8" font-size="10" text-anchor="middle">OUTWARD RETROCESSION</text>
    ${inwardSvg}
    ${outwardSvg}
    ${gapSvg}
  `;

  renderFindings(state.audit.findings);
}

/* ---------- findings ---------- */
function renderFindings(findings) {
  const list = $("#findings");
  if (!findings.length) {
    list.innerHTML = `<li class="finding INFO"><div class="head"><span class="sev">CLEAN</span>
      <span>No structural findings.</span></div></li>`;
    return;
  }
  list.innerHTML = findings
    .map(
      (f) => `<li class="finding ${f.severity}">
        <div class="head">
          <span class="sev">${f.severity}</span>
          <b>${f.kind}</b>
          <span class="amt">${fmtM(f.amountEur)}</span>
        </div>
        <div class="msg">${f.message}</div>
      </li>`
    )
    .join("");
}

/* ---------- full render ---------- */
function renderAll() {
  const a = state.audit;
  if (!a) return;
  setLatency(a.leanExecMs);
  renderGauge(a.stress.solvencyRatioPct);
  renderScr(a.stress);
  renderKpis(a);
  renderExposure(a);
  renderTower();
}

/* ---------- actions ---------- */
async function auditCurrent() {
  const report = await api("/api/audit", {
    method: "POST",
    body: JSON.stringify({ portfolio: state.portfolio }),
  });
  state.audit = report;
  renderAll();
}

function deepCopy(obj) {
  return JSON.parse(JSON.stringify(obj));
}

async function selectPreset(id) {
  const entry = state.presets.portfolios.find((p) => p.id === id);
  if (!entry) return;
  state.portfolio = deepCopy(entry.portfolio);
  state.undoStack = [];
  $("#portfolioSelect").value = id;
  await auditCurrent();
}

function resetPortfolio() {
  selectPreset($("#portfolioSelect").value);
}

/* ---------- peril tabs ---------- */
function renderTabs() {
  $("#perilTabs").innerHTML = PERILS.map(
    (p) => `<button class="tab ${p === state.activePeril ? "active" : ""}" data-peril="${p}">${p}</button>`
  ).join("");
  document.querySelectorAll("#perilTabs .tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.activePeril = btn.dataset.peril;
      renderTabs();
      renderTower();
      renderFindings(state.audit.findings);
    });
  });
}

/* ---------- slip validator ---------- */
function slipStatus(text, cls) {
  const el = $("#slipStatus");
  el.textContent = text;
  el.className = `slip-status ${cls || ""}`;
}

function renderSlipResult(result) {
  $("#slipText").textContent = result.extractedText;
  $("#slipEnglish").textContent = result.leanBackTranslation || "—";
  const divergences = result.translationWarnings || [];
  const banner = $("#translationBanner");
  banner.hidden = divergences.length === 0;
  if (divergences.length) {
    banner.innerHTML =
      `<b>Translation divergence — ${divergences.length} clause(s) present in the paper but absent from the Lean AST</b>` +
      `<ul>${divergences.map((w) => `<li>${w}</li>`).join("")}</ul>`;
  }
  $("#slipJson").textContent = JSON.stringify(result.contract, null, 2);

  const after = result.auditAfterBind;
  if (!after) {
    slipStatus("Parsed. Attach a portfolio to have Lean accept or reject it.", "");
    $("#keepBtn").disabled = true;
    return;
  }

  const before = state.audit;
  const delta = after.totalFound - before.totalFound;
  const ratioDelta = after.stress.solvencyRatioPct - before.stress.solvencyRatioPct;

  if (!after.allContractsValid) {
    const errs = after.validationErrors.join("; ");
    slipStatus(
      `GATEKEEPER REJECTED — ${errs}. The contract violates evalContractPayout_le_loss / qsPayout_le_loss preconditions.`,
      "bad"
    );
    $("#keepBtn").disabled = true;
    return;
  }

  slipStatus(
    `ACCEPTED by Lean — findings ${before.totalFound} → ${after.totalFound} (${delta >= 0 ? "+" : ""}${delta}), ` +
      `ratio ${before.stress.solvencyRatioPct}% → ${after.stress.solvencyRatioPct}% (${ratioDelta >= 0 ? "+" : ""}${ratioDelta}).`,
    "ok"
  );
  state.pendingSlip = {
    contract: result.contract,
    before,
    beforePortfolio: deepCopy(state.portfolio),
  };
  $("#keepBtn").disabled = false;
  $("#undoBtn").disabled = true;
}

async function bindSample(name) {
  slipStatus("Parsing slip and running the Lean gatekeeper…", "");
  try {
    const result = await api("/api/parse-slip", {
      method: "POST",
      body: JSON.stringify({ sampleSlipName: name, portfolio: state.portfolio }),
    });
    renderSlipResult(result);
  } catch (err) {
    slipStatus(`Parse failed: ${err.message}`, "bad");
  }
}

async function bindUpload(file) {
  slipStatus(`Reading ${file.name}…`, "");
  const reader = new FileReader();
  reader.onload = async () => {
    const base64 = String(reader.result).split(",")[1] || "";
    try {
      const result = await api("/api/parse-slip", {
        method: "POST",
        body: JSON.stringify({
          filename: file.name,
          contentBase64: base64,
          portfolio: state.portfolio,
        }),
      });
      renderSlipResult(result);
    } catch (err) {
      slipStatus(`Parse failed: ${err.message}`, "bad");
    }
  };
  reader.readAsDataURL(file);
}

async function keepPendingSlip() {
  if (!state.pendingSlip) return;
  state.undoStack.push(deepCopy(state.pendingSlip.beforePortfolio));
  state.portfolio.contracts.push(deepCopy(state.pendingSlip.contract));
  state.pendingSlip = null;
  $("#keepBtn").disabled = true;
  $("#undoBtn").disabled = state.undoStack.length === 0;
  await auditCurrent();
  slipStatus("Contract bound into the working portfolio and re-audited by Lean.", "ok");
}

async function undoBind() {
  const previous = state.undoStack.pop();
  if (!previous) return;
  state.portfolio = previous;
  $("#undoBtn").disabled = state.undoStack.length === 0;
  await auditCurrent();
  slipStatus("Last binding undone; portfolio restored and re-audited.", "");
}

function setupSlipUI() {
  const zone = $("#dropzone");
  const input = $("#fileInput");
  zone.addEventListener("click", () => input.click());
  input.addEventListener("change", () => input.files[0] && bindUpload(input.files[0]));
  ["dragover", "dragenter"].forEach((evt) =>
    zone.addEventListener(evt, (e) => {
      e.preventDefault();
      zone.classList.add("over");
    })
  );
  ["dragleave", "drop"].forEach((evt) =>
    zone.addEventListener(evt, (e) => {
      e.preventDefault();
      zone.classList.remove("over");
    })
  );
  zone.addEventListener("drop", (e) => {
    const file = e.dataTransfer.files[0];
    if (file) bindUpload(file);
  });

  $("#keepBtn").addEventListener("click", keepPendingSlip);
  $("#undoBtn").addEventListener("click", undoBind);

  const buttons = state.presets.slips || [];
  $("#demoButtons").innerHTML = buttons
    .map(
      (s, i) => `<button class="btn demo-btn" data-slip="${s.name}">
        <span>+ Bind PDF #${i + 1}: ${s.label}</span>
        <a class="pdf-link" href="${s.url}" target="_blank" rel="noopener">View PDF</a>
      </button>`
    )
    .join("");
  document.querySelectorAll(".demo-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      if (e.target.classList.contains("pdf-link")) return;
      bindSample(btn.dataset.slip);
    });
  });
}

/* ---------- simulator ---------- */
function eventRow(evt, index) {
  return `<tr data-index="${index}">
    <td><input data-field="eventName" value="${evt.eventName}" /></td>
    <td><select data-field="peril">${PERILS.map(
      (p) => `<option ${p === evt.peril ? "selected" : ""}>${p}</option>`
    ).join("")}</select></td>
    <td><select data-field="currency">${CURRENCIES.map(
      (c) => `<option ${c === evt.currency ? "selected" : ""}>${c}</option>`
    ).join("")}</select></td>
    <td><input data-field="groundUpLoss" type="number" value="${evt.groundUpLoss}" /></td>
    <td><button class="btn btn-ghost remove-event" data-index="${index}">×</button></td>
  </tr>`;
}

function renderEvents(events) {
  $("#eventRows").innerHTML = events.map(eventRow).join("");
  document.querySelectorAll(".remove-event").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.scenario.events.splice(Number(btn.dataset.index), 1);
      renderEvents(state.scenario.events);
    });
  });
}

function collectScenario() {
  const rows = [...document.querySelectorAll("#eventRows tr")];
  const events = rows.map((row) => {
    const get = (f) => row.querySelector(`[data-field="${f}"]`).value;
    return {
      eventName: get("eventName"),
      peril: get("peril"),
      currency: get("currency"),
      groundUpLoss: Number(get("groundUpLoss")),
    };
  });
  return {
    scenarioName: state.scenario.scenarioName,
    fxOverridesToEurCents: [
      { currency: "EUR", cents: 100 },
      { currency: "USD", cents: Number($("#fxUSD").value) },
      { currency: "JPY", cents: Number($("#fxJPY").value) },
    ],
    events,
  };
}

function renderSimulation(r) {
  const cell = (label, value, cls = "") =>
    `<div class="sim-cell"><div class="lab">${label}</div><div class="val ${cls}">${value}</div></div>`;
  const cls = r.isSolvent ? "ok" : "danger";

  const bridge = `
    <div class="ratio-bridge ${cls}">
      <div class="step"><span class="lab">Pre-season own funds</span><span class="num">${fmtM(r.initialOwnFundsEur)}</span></div>
      <div class="arrow">−</div>
      <div class="step"><span class="lab">Season loss drain</span><span class="num">${fmtM(r.seasonLossDrainEur)}</span></div>
      <div class="arrow">=</div>
      <div class="step"><span class="lab">Post-season own funds</span><span class="num">${fmtM(r.postSeasonOwnFundsEur)}</span></div>
      <div class="arrow">→</div>
      <div class="step"><span class="lab">Post-season ratio</span><span class="num ${cls}">${r.solvencyRatioPct}% ${r.isSolvent ? "SOLVENT" : "BREACH"}</span></div>
    </div>`;

  $("#simResults").innerHTML = `
    <div class="sim-strip">
      ${cell("Gross inward", fmtM(r.annualInwardGrossEur))}
      ${cell("Retro recovered", fmtM(r.annualOutwardRecoveredEur))}
      ${cell("Net before SL", fmtM(r.annualNetBeforeStopLossEur))}
      ${cell("Stop loss", fmtM(r.stopLossRecoveredEur))}
      ${cell("Final net loss", fmtM(r.annualFinalNetLossEur))}
    </div>
    <div class="sim-strip">
      ${cell("Reinstatement drag", fmtM(r.totalReinstFeeEur))}
      ${cell("Counterparty SCR", fmtM(r.counterpartyScrEur))}
      ${cell("Other SCR", fmtM(r.otherScrEur))}
      ${cell("Post-season SCR", fmtM(r.postSeasonScrEur))}
      ${cell("Pre-season ratio", `${r.preSeasonSolvencyRatioPct}%`, "muted-val")}
    </div>
    ${bridge}
    <table class="data-table">
      <thead><tr><th>Event</th><th>Gross</th><th>Recovered</th><th>Net</th><th>Reinst. fee</th></tr></thead>
      <tbody>${r.events
        .map(
          (e) =>
            `<tr><td>${e.eventName}</td><td class="num">${fmtM(e.inwardGrossEur)}</td>` +
            `<td class="num">${fmtM(e.outwardRecoveredEur)}</td><td class="num">${fmtM(e.netRetainedEur)}</td>` +
            `<td class="num">${fmtM(e.reinstFeeEur)}</td></tr>`
        )
        .join("")}</tbody>
    </table>
    <div class="split"><span class="k">Lean execution</span><span class="v">${r.leanExecMs} ms</span></div>
    ${r.allContractsValid ? "" : `<div class="split"><span class="k danger">Gatekeeper</span><span class="v danger">${r.validationErrors.join("; ")}</span></div>`}
  `;
}

async function runSimulation() {
  const btn = $("#runSimBtn");
  btn.disabled = true;
  try {
    const scenario = collectScenario();
    const report = await api("/api/simulate", {
      method: "POST",
      body: JSON.stringify({ portfolio: state.portfolio, scenario }),
    });
    renderSimulation(report);
  } catch (err) {
    $("#simResults").innerHTML = `<div class="slip-status bad">${err.message}</div>`;
  } finally {
    btn.disabled = false;
  }
}

/* ---------- theorems ---------- */
async function loadTheorems() {
  const data = await api("/api/theorems");
  setTheoremCount(data.count);
  const tbody = $("#theoremTable tbody");
  tbody.innerHTML = data.theorems
    .map(
      (t) => `<tr><td class="mono">${t.name}</td><td>${t.module}</td><td class="muted">${t.statement}</td></tr>`
    )
    .join("");
}

/* ---------- trust boundary ---------- */
const TRUST_SPECS = [
  ["Spec_NoOverRecovery", "No valid contract of any form pays more than the loss it is applied to.", "evalContractPayout_le_loss"],
  ["Spec_TowerMoneyConservation", "Net retained plus recovered equals gross, and recovered never exceeds gross.", "applyInuringTower_conservation"],
  ["Spec_ContractPayoutMonotone", "A larger loss never produces a smaller recovery.", "evalContractPayout_mono"],
  ["Spec_TowerNetLossMonotone", "A larger gross loss leaves a larger net retained loss after any valid tower.", "applyInuringTower_net_mono"],
  ["Spec_PostSeasonSolvencyAntitone", "A larger drain or requirement can only lower the post-season ratio.", "postSeasonRatio_antitone"],
  ["Spec_GatekeeperExactness", "Ingestion admits a contract exactly when the theorems' isValid hypothesis holds.", "validateContract_isEmpty_iff"],
  ["Spec_AlpineUniversalFxFix", "The restructured Alpine book stays under 25M EUR for every loss and FX ≤ parity.", "alpine_fixed_fx_safe"],
  ["Spec_NonVacuityWitness", "At least one valid contract actually pays something — the specs are not vacuous.", "verified_NonVacuityWitness"],
];

function renderTrust() {
  $("#trustTable tbody").innerHTML = TRUST_SPECS.map(
    ([name, claim, theorem]) =>
      `<tr><td class="mono">${name}</td><td>${claim}</td><td class="mono muted">${theorem}</td></tr>`
  ).join("");
}

/* ---------- bootstrap ---------- */
async function init() {
  try {
    const health = await api("/api/health");
    if (!health.leanBinaryExists) {
      slipStatus("Lean binary not found — run `lake build` first.", "bad");
    }
    state.presets = await api("/api/presets");

    $("#portfolioSelect").innerHTML = state.presets.portfolios
      .map((p) => `<option value="${p.id}">${p.label}</option>`)
      .join("");

    state.scenario = state.presets.scenario || {
      scenarioName: "Ad-hoc stress",
      events: [],
    };
    $("#fxUSD").value = 100;
    $("#fxJPY").value = 60;
    renderEvents(state.scenario.events);

    renderTabs();
    setupSlipUI();
    setupFacUI();

    $("#portfolioSelect").addEventListener("change", (e) => selectPreset(e.target.value));
    $("#resetBtn").addEventListener("click", resetPortfolio);
    $("#runSimBtn").addEventListener("click", runSimulation);
    $("#addEventBtn").addEventListener("click", () => {
      state.scenario.events.push({
        eventName: "New event",
        peril: "Windstorm",
        currency: "USD",
        groundUpLoss: 10000000,
      });
      renderEvents(state.scenario.events);
    });

    renderTrust();
    await loadTheorems();
    await selectPreset(state.presets.portfolios[0].id);
    await loadFac();
    showView("fac");
  } catch (err) {
    document.body.insertAdjacentHTML(
      "afterbegin",
      `<div class="panel" style="margin:20px;border-color:#ef4444">Startup failed: ${err.message}</div>`
    );
  }
}

document.addEventListener("DOMContentLoaded", init);

/* ==================== US Facultative Accounting Desk ==================== */

state.fac = { loaded: false, presets: null, bundle: null, cases: [], selected: null };

const usd = (n) => "$" + Number(n || 0).toLocaleString("en-US");

function showView(name) {
  document.querySelectorAll(".wtab").forEach((b) => b.classList.toggle("active", b.dataset.view === name));
  document.querySelectorAll(".view").forEach((v) => {
    v.hidden = v.id !== `view-${name}`;
  });
  if (name === "fac" && !state.fac.loaded) loadFac();
}

function renderFacSummary(report) {
  $("#facBilledTotal").textContent = usd(report.totalBilledUsd);
  $("#facVerifiedTotal").textContent = usd(report.totalVerifiedUsd);
  $("#facOverTotal").textContent = usd(report.totalOverbilledUsd);
  $("#facDisputeTotal").textContent = `${report.disputeCount} of ${report.results.length}`;
}

function renderFacCases(cases, bundle) {
  $("#facCases").innerHTML = cases
    .map((c) => {
      const pdf = c.pdfUrl
        ? `<a class="pdf-link" href="${c.pdfUrl}" target="_blank" rel="noopener">View Cash-Call PDF</a>`
        : "";
      return `<button class="case-chip" data-cert="${c.certId}">
        <span class="case-line">${c.line}</span>
        <span class="case-limit">${c.limitLabel}</span>
        <span class="case-insured">${c.insured}</span>
        <span class="case-clause">${c.alaeLabel}</span>
        ${pdf}
      </button>`;
    })
    .join("");
  document.querySelectorAll(".case-chip").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      if (e.target.classList.contains("pdf-link")) return;
      selectFacCase(btn.dataset.cert);
    });
  });
}

function findFacCase(certId) {
  const bundle = state.fac.bundle;
  const cert = bundle.certificates.find((c) => c.certId === certId);
  const claim = bundle.claims.find((c) => c.certId === certId);
  return { cert, claim };
}

function selectFacCase(certId) {
  const { cert, claim } = findFacCase(certId);
  if (!cert || !claim) return;
  state.fac.selected = certId;
  document.querySelectorAll(".case-chip").forEach((b) => b.classList.toggle("active", b.dataset.cert === certId));
  $("#facSelectedLabel").textContent = `${cert.certId} · ${cert.insuredName}`;
  $("#facInd").value = claim.groundUpIndemnityUsd;
  $("#facAlae").value = claim.groundUpAlaeUsd;
  $("#facPrior").value = claim.priorPaidUsd;
  $("#facBilledInput").value = claim.cedentBilledNowUsd;
  $("#facShare").value = cert.signedShareBps;
  $("#facAtt").value = cert.attachmentUsd;
  $("#facLimit").value = cert.occLimitUsd;
  $("#facClause").value = cert.alaeClause;
  runFacAudit();
}

function facBundleFromForm() {
  const base = findFacCase(state.fac.selected);
  const cert = {
    ...base.cert,
    signedShareBps: Number($("#facShare").value),
    attachmentUsd: Number($("#facAtt").value),
    occLimitUsd: Number($("#facLimit").value),
    alaeClause: $("#facClause").value,
  };
  const claim = {
    ...base.claim,
    groundUpIndemnityUsd: Number($("#facInd").value),
    groundUpAlaeUsd: Number($("#facAlae").value),
    priorPaidUsd: Number($("#facPrior").value),
    cedentBilledNowUsd: Number($("#facBilledInput").value),
  };
  return {
    deskName: state.fac.bundle.deskName,
    certificates: [cert],
    claims: [claim],
  };
}

function renderFacSteps(r, trace) {
  const steps = [
    {
      n: 1,
      name: "Cash-Call & Certificate Reader",
      detail: `${r.line} · ${r.insuredName} · certificate ${r.certId} · claim ${r.claimId}`,
      tag: "PARSED",
      cls: "",
    },
    {
      n: 2,
      name: "Lean 4 Kernel Verifier",
      detail: r.explanation,
      tag: r.verdict,
      cls: r.verdict === "APPROVED_EXACT" ? "ok" : "bad",
    },
    {
      n: 3,
      name: "Technical Accounting Ledger",
      detail: `Debits ${usd(r.journal.totalDebitUsd)} = credits ${usd(r.journal.totalCreditUsd)} · theorem facJournal_balanced`,
      tag: "BALANCED",
      cls: "ok",
    },
    {
      n: 4,
      name: "Broker Settlement / Dispute Memo",
      detail:
        r.overbilledUsd > 0
          ? `Dispute drafted for ${usd(r.overbilledUsd)}; settlement figure ${usd(r.verifiedIncrementalDueUsd)}.`
          : `Approval drafted for ${usd(r.verifiedIncrementalDueUsd)}.`,
      tag: "MEMO",
      cls: "",
    },
  ];
  $("#facSteps").innerHTML = steps
    .map(
      (s) => `<div class="step">
        <div class="step-badge">${s.n}</div>
        <div class="step-body">
          <div class="step-head"><b>${s.name}</b><span class="step-tag ${s.cls}">${s.tag}</span></div>
          <p>${s.detail}</p>
        </div>
      </div>`
    )
    .join("");

  const v = r.voucher;
  $("#facJournal tbody").innerHTML = `
    <tr class="leg-head"><td colspan="3">Leg A · cash settlement</td></tr>
    <tr><td>Debit · Paid claims expense</td><td class="num">${usd(v.debitPaidClaimsExpenseUsd)}</td><td class="num">—</td></tr>
    <tr><td>Credit · Premium receivable offset</td><td class="num">—</td><td class="num">${usd(v.creditPremiumReceivableOffsetUsd)}</td></tr>
    <tr><td>Credit · Cash wire payable</td><td class="num">—</td><td class="num">${usd(v.creditCashWirePayableUsd)}</td></tr>
    <tr class="leg-head"><td colspan="3">Leg B · case reserve (OSLR / LIC) movement</td></tr>
    <tr><td>Debit · OSLR expense</td><td class="num">${usd(v.debitOslrExpenseUsd)}</td><td class="num">—</td></tr>
    <tr><td>Credit · OSLR liability</td><td class="num">—</td><td class="num">${usd(v.creditOslrLiabilityUsd)}</td></tr>
    <tr><td>Debit · OSLR liability release</td><td class="num">${usd(v.debitOslrLiabilityReleaseUsd)}</td><td class="num">—</td></tr>
    <tr><td>Credit · OSLR expense release</td><td class="num">—</td><td class="num">${usd(v.creditOslrExpenseReleaseUsd)}</td></tr>`;
  const balanced = v.grandTotalDebitUsd === v.grandTotalCreditUsd;
  $("#facJournal tfoot").innerHTML = `
    <tr class="total-row"><td>Grand total ${balanced ? "· BALANCED" : "· OUT OF BALANCE"}</td>
      <td class="num ${balanced ? "ok" : "danger"}">${usd(v.grandTotalDebitUsd)}</td>
      <td class="num ${balanced ? "ok" : "danger"}">${usd(v.grandTotalCreditUsd)}</td></tr>`;

  $("#facMemo").textContent = r.brokerMemo;
  $("#facLatency").textContent = trace ? `verified in ${trace} ms` : "";
}

async function runFacAudit() {
  const btn = $("#facRun");
  btn.disabled = true;
  try {
    const payload = { bundle: facBundleFromForm() };
    const report = await api("/api/fac-audit", { method: "POST", body: JSON.stringify(payload) });
    state.fac.report = report;
    renderFacSteps(report.results[0], report.leanExecMs);
  } catch (err) {
    $("#facSteps").innerHTML = `<div class="slip-status bad">${err.message}</div>`;
  } finally {
    btn.disabled = false;
  }
}

function renderIntakeSamples(samples) {
  $("#facSamples").innerHTML = samples
    .map(
      (s, i) => `<button class="btn demo-btn" data-intake="${s.name}">
        <span>${i + 1} · ${s.label}</span>
        <span class="pdf-link">${s.format}</span>
      </button>`
    )
    .join("");
  document.querySelectorAll("[data-intake]").forEach((btn) => {
    btn.addEventListener("click", () => bindIntake(btn.dataset.intake));
  });
}

function renderIntake(result) {
  $("#intakeRaw").textContent = (result.extractedText || "").slice(0, 4000);
  const row = result.report.results[0];
  $("#intakeLean").textContent = row.leanSpecCode;
  $("#intakeEnglish").textContent = row.backTranslation;
  const warnings = [...(result.parseWarnings || []), ...(result.translationWarnings || [])];
  const banner = $("#intakeWarnings");
  banner.hidden = warnings.length === 0;
  if (warnings.length) {
    banner.innerHTML = `<b>${warnings.length} intake warning(s) — the paper says more than the model can</b>` +
      `<ul>${warnings.map((w) => `<li>${w}</li>`).join("")}</ul>`;
  }
  state.fac.intake = result;
  $("#intakeUse").disabled = false;
}

async function bindIntake(name) {
  try {
    const result = await api("/api/fac-intake", {
      method: "POST",
      body: JSON.stringify({ sampleName: name }),
    });
    renderIntake(result);
  } catch (err) {
    $("#intakeWarnings").hidden = false;
    $("#intakeWarnings").textContent = err.message;
  }
}

async function bindIntakeFile(file) {
  const reader = new FileReader();
  reader.onload = async () => {
    const base64 = String(reader.result).split(",")[1] || "";
    try {
      const result = await api("/api/fac-intake", {
        method: "POST",
        body: JSON.stringify({ filename: file.name, contentBase64: base64 }),
      });
      renderIntake(result);
    } catch (err) {
      $("#intakeWarnings").hidden = false;
      $("#intakeWarnings").textContent = err.message;
    }
  };
  reader.readAsDataURL(file);
}

function loadIntakeIntoCalculator() {
  const r = state.fac.intake;
  if (!r) return;
  const { certificate, claim } = r;
  state.fac.bundle.certificates.push(certificate);
  state.fac.bundle.claims.push(claim);
  state.fac.selected = certificate.certId;
  $("#facInd").value = claim.paidIndemnityUsd;
  $("#facAlae").value = claim.paidAlaeUsd;
  $("#facPrior").value = claim.priorPaidUsd;
  $("#facBilledInput").value = claim.cedentBilledNowUsd;
  $("#facShare").value = certificate.signedShareBps;
  $("#facAtt").value = certificate.attachmentUsd;
  $("#facLimit").value = certificate.occLimitUsd;
  $("#facClause").value = certificate.alaeClause;
  $("#facSelectedLabel").textContent = `${certificate.certId} · ${certificate.insuredName}`;
  runFacAudit();
}

async function loadFac() {
  try {
    const data = await api("/api/fac-presets");
    state.fac.presets = data;
    state.fac.bundle = data.bundle;
    state.fac.cases = data.cases;
    state.fac.loaded = true;
    renderFacSummary(data.report);
    renderFacCases(data.cases, data.bundle);
    renderIntakeSamples(data.intakeSamples || []);
    selectFacCase(data.cases[0].certId);
  } catch (err) {
    $("#facCases").innerHTML = `<div class="slip-status bad">${err.message}</div>`;
  }
}

function setupFacUI() {
  document.querySelectorAll(".wtab").forEach((btn) => {
    btn.addEventListener("click", () => showView(btn.dataset.view));
  });
  $("#facRun").addEventListener("click", runFacAudit);
  $("#intakeUse").addEventListener("click", loadIntakeIntoCalculator);
  const drop = $("#facDrop");
  const fileInput = $("#facFile");
  if (drop && fileInput) {
    drop.addEventListener("click", () => fileInput.click());
    fileInput.addEventListener("change", () => fileInput.files[0] && bindIntakeFile(fileInput.files[0]));
    ["dragover", "dragenter"].forEach((evt) =>
      drop.addEventListener(evt, (e) => { e.preventDefault(); drop.classList.add("over"); })
    );
    ["dragleave", "drop"].forEach((evt) =>
      drop.addEventListener(evt, (e) => { e.preventDefault(); drop.classList.remove("over"); })
    );
    drop.addEventListener("drop", (e) => {
      const f = e.dataTransfer.files[0];
      if (f) bindIntakeFile(f);
    });
  }
  $("#facCopy").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText($("#facMemo").textContent);
      $("#facCopy").textContent = "Copied";
      setTimeout(() => ($("#facCopy").textContent = "Copy memo"), 1200);
    } catch {
      $("#facCopy").textContent = "Select the text to copy";
    }
  });
}
