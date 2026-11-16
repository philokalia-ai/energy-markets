/* DOM test: naive baselines + rMAE on the scoreboard (#431).
 * Drives app.js's real renderScoreboard through the dependency-free DOM stub:
 *  - scores WITHOUT the naive fields (old JSON / EXPORT_NAIVE=0) render exactly the old
 *    3-metric board and the Naive selector stays hidden;
 *  - with the fields: lead D-1 shows the weekday-rule naive, leads D-2..D-7 the D-7 naive,
 *    rMAE with a plain beats/loses marker (rMAE < 1), null rMAE renders "—";
 *  - the D-1 choice is unavailable at lead D-2 ("—" + why), "Hide" removes the columns,
 *    the 15-min board never shows naive columns, and rMAE sorts ascending.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

import { shapeScoreboard } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../..", "web/app.js");

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- minimal DOM stub (same shape as views_empty_state.test.mjs) ---- */
class El {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this._text = null;
    this.attrs = {}; this.hidden = false; this._handlers = {}; this.dataset = {};
    this.style = {}; this.value = "";
    const self = this;
    this.classList = {
      add(c) { if (!self._classes().includes(c)) self.className = (self.className + " " + c).trim(); },
      remove(c) { self.className = self._classes().filter((x) => x !== c).join(" "); },
      contains(c) { return self._classes().includes(c); },
      toggle(c, force) {
        const has = self._classes().includes(c);
        const on = force === undefined ? !has : !!force;
        if (on) this.add(c); else this.remove(c);
        return on;
      },
    };
  }
  _classes() { return this.className.split(/\s+/).filter(Boolean); }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); if (k === "class") this.className = String(v); }
  getAttribute(k) { return this.attrs[k]; }
  addEventListener(t, fn) { (this._handlers[t] || (this._handlers[t] = [])).push(fn); }
  _fire(t, ev) { (this._handlers[t] || []).forEach((fn) => fn(ev || { preventDefault() {} })); }
  set textContent(v) { this.children = []; this._text = v == null ? "" : String(v); }
  get textContent() {
    let s = this._text || "";
    for (const c of this.children) s += c instanceof El ? c.textContent : (c.nodeValue || "");
    return s;
  }
  _all(pred, out) {
    for (const c of this.children) if (c instanceof El) { if (pred(c)) out.push(c); c._all(pred, out); }
    return out;
  }
  _pred(sel) {
    if (sel[0] === ".") { const cls = sel.slice(1); return (e) => e._classes().includes(cls); }
    const tag = sel.toLowerCase(); return (e) => e.tagName && e.tagName.toLowerCase() === tag;
  }
  querySelector(sel) { const r = this._all(this._pred(sel), []); return r[0] || null; }
  querySelectorAll(sel) { return this._all(this._pred(sel), []); }
}

const byId = new Map();
function getById(id) {
  if (!byId.has(id)) byId.set(id, new El("div"));
  return byId.get(id);
}

const store = {};
globalThis.window = {
  location: { search: "", hash: "" },
  __EUPHEMIA_NO_AUTOINIT: true,
  localStorage: {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
  },
};
globalThis.document = {
  documentElement: new El("html"),
  createElement: (t) => new El(t),
  createElementNS: (_ns, t) => new El(t),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  getElementById: getById,
  querySelectorAll: () => [],
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#888888" });
globalThis.fetch = () => Promise.reject(new Error("no network in this test"));

await import(appPath);
const T = globalThis.window.__euphemiaTrack;
ok(T && typeof T.readHash === "function", "app.js exposed readHash/renderScoreboard");

T.state.track = "predicted"; T.state.window = "all"; T.state.res = "h60";
const table = () => getById("scoreboard-table");
const rowOf = (zone) => table().querySelectorAll("tr").filter((r) => r.textContent.startsWith(zone))[0];
const subHeaders = () => table().querySelectorAll("tr")[1].querySelectorAll("th").map((th) => th.textContent);
const base = (zone, lead, mae, extra) => Object.assign({ zone: zone, lead_days: lead, window: "all",
  input_mode: "weather", n_days: 30, mae: mae, bias: -10, corr: 0.8, code_version: 44,
  n_days_q15: 30, mae_q15: mae + 1, bias_q15: -10, corr_q15: 0.75, shape_floor_q15: 8 }, extra || {});

// 1. old JSON: no naive fields -> the old board, selector hidden
T.state.scoreboard = { zones: ["GR", "DE_LU"], scores: [base("GR", 1, 80), base("DE_LU", 1, 58),
  base("GR", 2, 85), base("DE_LU", 2, 60)] };
T.renderScoreboard();
ok(JSON.stringify(subHeaders()) === JSON.stringify(["corr", "MAE ↓", "bias", "corr", "MAE", "bias"]),
  "legacy: 3 metrics per lead (" + subHeaders().join(",") + ")");
ok(!/naive|beats|loses/.test(table().textContent) && !subHeaders().includes("rMAE"), "legacy: no naive text anywhere");
ok(getById("naive-filter").hidden === true, "legacy: Naive selector hidden");

// 2. with the naive fields
const n1 = { n_naive: 700, mae_paired: 81, mae_naive_d1: 40, mae_naive_d7: 54, mae_naive_epf: 47,
  rmae_d1: 2.025, rmae_d7: 1.5, rmae_epf: 1.723 };
const n1de = { n_naive: 690, mae_paired: 57, mae_naive_d1: 55, mae_naive_d7: 74, mae_naive_epf: 62.6,
  rmae_d1: 1.036, rmae_d7: 0.77, rmae_epf: 0.91 };
const n2 = { n_naive: 680, mae_paired: 86, mae_naive_d7: 54.5, rmae_d7: 1.578 };
const n2de = { n_naive: 670, mae_paired: 59, mae_naive_d7: 0, rmae_d7: null };
T.state.scoreboard = { zones: ["GR", "DE_LU"], scores: [base("GR", 1, 80, n1), base("DE_LU", 1, 58, n1de),
  base("GR", 2, 85, n2), base("DE_LU", 2, 60, n2de)] };
T.state.naive = "auto"; T.state.sort = { lead: null, metric: "mae", dir: 1 };
T.renderScoreboard();
ok(getById("naive-filter").hidden === false, "naive: selector shown");
ok(subHeaders().length === 10 && subHeaders()[3] === "naive" && subHeaders()[4] === "rMAE",
  "naive: 5 metrics per lead (" + subHeaders().join(",") + ")");
let gr = rowOf("GR").querySelectorAll("td");
// td layout: zone, [corr, mae, bias, naive, rmae] x lead
ok(gr[4].textContent === "47.0", "lead D-1 auto = weekday-rule naive 47.0 (got " + gr[4].textContent + ")");
ok(/^1\.72 loses$/.test(gr[5].textContent), "lead D-1 rMAE 1.72 + 'loses' (got " + gr[5].textContent + ")");
ok(/weekday-rule/.test(gr[4].title) && /700 paired hours/.test(gr[4].title) && /81\.00/.test(gr[4].title),
  "naive tooltip names the naive, the paired hours and the paired model MAE");
ok(/Not a test of statistical significance/.test(gr[5].title), "rMAE tooltip: not a significance test");
ok(gr[9].textContent === "54.5" && /^1\.58 loses$/.test(gr[10].textContent), "lead D-2 auto = D-7 naive");
let de = rowOf("DE_LU").querySelectorAll("td");
ok(/^0\.91 beats$/.test(de[5].textContent), "DE_LU lead D-1 beats the naive (got " + de[5].textContent + ")");
ok(de[5].querySelector(".naive-beats") !== null, "beats marker carries the naive-beats class");
ok(de[10].textContent === "—" && /naive error is zero/.test(de[10].title), "null rMAE (zero naive error) -> —");

// 3. D-1 at lead D-2 is unavailable; D-7 everywhere; Hide
T.state.naive = "d1"; T.renderScoreboard();
gr = rowOf("GR").querySelectorAll("td");
ok(gr[4].textContent === "40.0" && /^2\.03 loses$/.test(gr[5].textContent), "D-1 naive at lead D-1");
ok(gr[9].textContent === "—" && /not available at lead D-2/.test(gr[9].title), "D-1 naive at lead D-2: — + why");
T.state.naive = "d7"; T.renderScoreboard();
gr = rowOf("GR").querySelectorAll("td");
ok(gr[4].textContent === "54.0" && /^1\.50 loses$/.test(gr[5].textContent), "D-7 naive at lead D-1");
// sort by rMAE at lead D-1: DE_LU (0.77) before GR (1.5), GR stays pinned first
T.state.sort = { lead: 1, metric: "rmae", dir: 1 }; T.renderScoreboard();
ok(/rMAE ↓/.test(subHeaders().join(",")), "rMAE column sortable");
T.state.naive = "off"; T.renderScoreboard();
ok(subHeaders().length === 6 && !/naive|beats|loses/.test(table().textContent) && !subHeaders().includes("rMAE"), "Hide: back to 3 metrics");
ok(T.state.sort.metric === "mae", "Hide resets a naive sort to MAE");

// 4. the 15-min board never shows naive columns
T.state.naive = "auto"; T.state.res = "q15"; T.renderScoreboard();
ok(subHeaders().length === 6 && !/naive|beats|loses/.test(table().textContent) && !subHeaders().includes("rMAE"), "15-min board: no naive columns");
ok(getById("naive-filter").hidden === true, "15-min board: Naive selector hidden");

// 5. worker passthrough (scoreboard.parquet -> scoreboard.json): d1/epf keys ABSENT at
//    leads >= 2 (as the JSON exporter writes them), nulls kept, old parquet -> old keys
const manifest = { updated_at: "2026-11-16T07:00:00Z", code_version: 44, zones: ["GR"] };
const pq = { zone: "GR", window: "all", input_mode: "weather", n_days: 60n, mae: 80, bias: -10,
  corr: 0.8, code_version: 44n };
const allNaive = { n_naive: 700n, mae_paired: 81, mae_naive_d1: 40, mae_naive_d7: 54,
  mae_naive_epf: 47, rmae_d1: 2.025, rmae_d7: 1.5, rmae_epf: null };
const sh = shapeScoreboard([Object.assign({ lead_days: 1n }, pq, allNaive),
  Object.assign({ lead_days: 2n }, pq, allNaive, { mae_naive_d1: null, mae_naive_epf: null,
    rmae_d1: null })], manifest).scores;
ok(sh[0].n_naive === 700 && sh[0].mae_naive_epf === 47 && sh[0].rmae_epf === null &&
   Object.prototype.hasOwnProperty.call(sh[0], "rmae_epf"), "worker: lead 1 carries d1/d7/epf (null kept)");
ok(sh[1].mae_naive_d7 === 54 && !("mae_naive_d1" in sh[1]) && !("mae_naive_epf" in sh[1]) &&
   !("rmae_d1" in sh[1]) && !("rmae_epf" in sh[1]), "worker: lead 2 has no d1/epf keys");
const legacyKeys = Object.keys(shapeScoreboard([Object.assign({ lead_days: 1n }, pq)], manifest).scores[0]);
ok(!legacyKeys.some((k) => /naive|rmae|paired/.test(k)), "worker: old parquet -> no naive keys");

// 6. the hidden attribute must actually hide the selector: `.filter { display:flex }`
//    overrides the UA [hidden] rule, so style.css needs a higher-specificity
//    `.filter[hidden] { display:none }` (#437 review P3; the browser check is
//    test/scripts/naive_filter_visibility.py).
const css = readFileSync(join(here, "../../..", "web/style.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
ok(/(^|[},\s])\.filter\[hidden\]\s*(,[^{]*)?\{[^}]*display\s*:\s*none/m.test(css),
  "style.css: .filter[hidden] { display: none } overrides .filter { display: flex }");

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("naive_board: all assertions passed");
