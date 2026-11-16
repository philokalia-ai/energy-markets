/* DOM test (#431 R1): the "backfilled" scoreboard window (the cv44 reconstruction).
 *  - offered after "All days" and "since freeze", before the months, with the owner's label;
 *  - the note names the reconstruction date, the day count and the in-sample caveat;
 *  - numbers render normally (no insufficient-data rule), naive columns work;
 *  - old JSON (no backfilled entries) offers no such window;
 *  - the worker passes reconstructed_utc through on those rows only.
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


const S = (zone, win, n, mae, extra) => Object.assign({ zone: zone, lead_days: 1, window: win, input_mode: "weather",
  n_days: n, mae: mae, bias: -1, corr: 0.8, code_version: 44 }, extra || {});
const table = () => getById("scoreboard-table");
const rowOf = (zone) => table().querySelectorAll("tr").filter((r) => r.textContent.startsWith(zone))[0];
Object.defineProperty(getById("window-select"), "options", { get() { return this.children; } });
const optLabels = () => { T.renderWindowSelect(); return getById("window-select").children.map((o) => o.value + "=" + o.textContent); };
T.state.track = "predicted"; T.state.res = "h60"; T.state.naive = "auto"; T.state.sort = { lead: null, metric: "mae", dir: 1 };

// old JSON
T.state.scoreboard = { zones: ["GR", "DE_LU"], scores: [S("GR", "all", 60, 70), S("GR", "2026-10", 31, 72), S("DE_LU", "all", 60, 58)] };
T.state.window = "all";
ok(!optLabels().some((o) => /backfilled/.test(o)), "old JSON: no backfilled window offered");

// new JSON
const nv = { n_naive: 1488, mae_paired: 64.3, mae_naive_d1: 24.4, mae_naive_d7: 57.6, mae_naive_epf: 34.7,
  rmae_d1: 2.64, rmae_d7: 1.12, rmae_epf: 1.85 };
T.state.scoreboard.scores.push(S("GR", "since_freeze", 2, 40),
  S("GR", "backfilled", 62, 64.3, Object.assign({ reconstructed_utc: "2026-11-18" }, nv)),
  S("DE_LU", "backfilled", 62, 51.0, Object.assign({ reconstructed_utc: "2026-11-18" }, nv, { rmae_epf: 0.82 })));
const o = optLabels();
ok(o[0] === "all=All days" && /^since_freeze=/.test(o[1]) &&
   o[2] === "backfilled=backfilled (reconstructed, cv44; in-sample — calibration overlaps)" && /^2026-10=/.test(o[3]),
  "options: All days, since freeze, backfilled (labelled), months — " + o.join(" | "));
T.state.window = "backfilled"; T.renderScoreboard();
const note = getById("window-note");
ok(note.hidden === false && /reconstructed on 2026-11-18/.test(note.textContent) && /62 market days/.test(note.textContent) &&
   /In-sample/.test(note.textContent) && /never mixed into the live record/.test(note.textContent),
  "note: reconstruction date, day count, in-sample caveat");
const gr = rowOf("GR").querySelectorAll("td"), de = rowOf("DE_LU").querySelectorAll("td");
ok(/^64\.3/.test(gr[2].textContent), "GR backfilled MAE shown (" + gr[2].textContent + ")");
ok(/^1\.85 loses$/.test(gr[5].textContent) && /^0\.82 beats$/.test(de[5].textContent), "naive rMAE columns work in the window");
T.state.window = "all"; T.renderScoreboard();
ok(note.hidden === true && /70\.0/.test(rowOf("GR").textContent), "All days: live numbers, note hidden");

// worker passthrough
const man = { updated_at: "x", code_version: 44, zones: ["GR"] };
const base = { zone: "GR", lead_days: 1n, input_mode: "weather", n_days: 60n, mae: 1, bias: 0, corr: 0.5, code_version: 44n };
const sh = shapeScoreboard([Object.assign({ window: "all", reconstructed_utc: null }, base),
  Object.assign({ window: "backfilled", reconstructed_utc: "2026-11-18" }, base)], man).scores;
ok(!("reconstructed_utc" in sh[0]) && sh[1].reconstructed_utc === "2026-11-18", "worker: reconstructed_utc on backfilled rows only");
ok(!("reconstructed_utc" in shapeScoreboard([Object.assign({ window: "all" }, base)], man).scores[0]), "worker: old parquet unchanged");

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("backfill_window: all assertions passed");
