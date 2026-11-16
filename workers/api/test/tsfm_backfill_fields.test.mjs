/* End-to-end test (#431 R2, #450 review): the Timestral fields of the "backfilled" window.
 *  exporter row (test/fixtures/tsfm_backfilled_row.json — the row bin/tsfm_backfill_scores.jl builds,
 *  checked by test/test_tsfm_backfill_scores.jl) typed as the parquet reader returns it (BigInt INT64)
 *  -> shapeScoreboard (the Worker) -> web/app.js renderScoreboard (the UI).
 *  - the Worker passes every tsfm_* field through on the rows that carry them, and only there;
 *  - the UI shows "Timestral MAE" / "Timestral rMAE" in the backfilled window (hourly board) only.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { shapeScoreboard } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../..", "web/app.js");
const fx = JSON.parse(readFileSync(join(here, "../../..", "test/fixtures/tsfm_backfilled_row.json"), "utf8"));

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



const TS = ["tsfm_arm", "tsfm_n_days", "tsfm_n", "tsfm_mae", "tsfm_mae_naive_d1", "tsfm_mae_naive_d7",
  "tsfm_mae_naive_epf", "tsfm_rmae_d1", "tsfm_rmae_d7", "tsfm_rmae_epf"];
const INT = ["lead_days", "n_days", "code_version", "tsfm_n_days", "tsfm_n"];
const asParquet = (o) => { const r = {}; for (const [k, v] of Object.entries(o)) if (k[0] !== "_")
  r[k] = INT.includes(k) && v !== null ? BigInt(v) : v; return r; };
const bf = asParquet(fx);
const live = asParquet({ zone: "GR", lead_days: 1, window: "all", input_mode: "weather", n_days: 60, mae: 70,
  bias: -2, corr: 0.7, code_version: 44, reconstructed_utc: null });
for (const k of TS) live[k] = null;                       // parquet: the columns exist, null on live rows
const man = { updated_at: "x", code_version: 44, zones: ["GR"] };

// ---- Worker ----
const sh = shapeScoreboard([live, bf], man).scores;
ok(TS.every((k) => !(k in sh[0])), "worker: live row carries no tsfm_* fields");
ok(TS.every((k) => k in sh[1]), "worker: backfilled row carries every tsfm_* field");
ok(TS.filter((k) => k !== "tsfm_arm").every((k) => typeof sh[1][k] === "number") && sh[1].tsfm_arm === fx.tsfm_arm,
  "worker: numbers are plain numbers (no BigInt), arm is a string");
ok(Math.abs(sh[1].tsfm_mae - fx.tsfm_mae) < 1e-12 && sh[1].tsfm_n === 36 && sh[1].reconstructed_utc === "2026-11-18",
  "worker: values and the reconstruction date survive");
const old = shapeScoreboard([asParquet({ zone: "GR", lead_days: 1, window: "all", input_mode: "weather", n_days: 60,
  mae: 70, bias: -2, corr: 0.7, code_version: 44 })], man).scores[0];
ok(TS.every((k) => !(k in old)), "worker: an old parquet (no tsfm columns) is unchanged");

// ---- UI (app.js imported by the stub above) ----
const table = () => getById("scoreboard-table");
const header = () => table().querySelectorAll("th").map((t) => t.textContent).join(" | ");
const rowOf = (zone) => table().querySelectorAll("tr").filter((r) => r.textContent.startsWith(zone))[0];
T.state.track = "predicted"; T.state.res = "h60"; T.state.naive = "auto"; T.state.sort = { lead: null, metric: "mae", dir: 1 };
T.state.scoreboard = { zones: ["GR"], scores: sh };
T.state.window = "backfilled"; T.renderScoreboard();
ok(/Timestral MAE/.test(header()) && /Timestral rMAE/.test(header()), "UI: backfilled window shows the Timestral columns (" + header() + ")");
const cells = rowOf("GR").querySelectorAll("td").map((td) => td.textContent);
ok(cells.some((c) => c === "3.3") && cells.some((c) => /^0\.33 beats$/.test(c)),
  "UI: Timestral MAE 3.3 and rMAE vs the epf naive 0.33 (" + cells.join(" | ") + ")");
T.state.naive = "d7"; T.renderScoreboard();
ok(rowOf("GR").querySelectorAll("td").some((td) => /^0\.05 beats$/.test(td.textContent)), "UI: rMAE follows the naive selector (d7)");
T.state.naive = "auto";
T.state.window = "all"; T.renderScoreboard();
ok(!/Timestral/.test(header()), "UI: no Timestral columns in the live windows");
T.state.window = "backfilled"; T.state.res = "q15";
T.state.scoreboard.scores.forEach((s) => Object.assign(s, { n_days_q15: 2, mae_q15: 62, bias_q15: -1, corr_q15: 0.8, shape_floor_q15: 7 }));
T.renderScoreboard();
ok(!/Timestral/.test(header()), "UI: no Timestral columns on the 15-min board");

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("tsfm_backfill_fields: all assertions passed");
