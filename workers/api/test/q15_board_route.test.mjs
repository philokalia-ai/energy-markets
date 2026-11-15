/* DOM test: scoreboard Resolution routing (#424 review P3).
 * Drives app.js's real hash router (readHash/writeHash) + renderScoreboard through the
 * dependency-free DOM stub: #res=q15 renders the 15-min board; navigating Back to a plain
 * board URL (no res=) returns to the HOURLY default; the shape tooltip carries no
 * "share of MAE" decomposition claim.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

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

T.state.scoreboard = { zones: ["GR", "CH"], scores: [
  { zone: "GR", lead_days: 1, window: "all", input_mode: "weather", n_days: 30, mae: 50, bias: -10,
    corr: 0.8, code_version: 44, n_days_q15: 30, mae_q15: 52, bias_q15: -10, corr_q15: 0.75, shape_floor_q15: 8 },
  { zone: "CH", lead_days: 1, window: "all", input_mode: "weather", n_days: 30, mae: 70, bias: -60,
    corr: 0.7, code_version: 44, n_days_q15: 0, mae_q15: null, bias_q15: null, corr_q15: null, shape_floor_q15: null },
] };
T.state.track = "predicted"; T.state.window = "all";
const table = () => getById("scoreboard-table");
const cellsOf = (zone) => table().querySelectorAll("tr").filter((r) => r.textContent.startsWith(zone))[0];

// 1. a shared #res=q15 link renders the 15-min board
globalThis.window.location.hash = "#view=board&zone=GR&res=q15";
T.readHash(); T.renderScoreboard();
ok(T.state.res === "q15", "#res=q15 -> state.res = q15");
ok(/15-min · Lead D-1/.test(table().textContent), "15-min board header shown");
ok(/52\.0/.test(cellsOf("GR").textContent) && !/50\.0/.test(cellsOf("GR").textContent), "GR shows the q15 MAE only");
ok(/—/.test(cellsOf("CH").textContent), "CH (no native PT15M) shows — on the 15-min board");
ok(getById("res-select").value === "q15", "the select follows the URL");
const tip = cellsOf("GR").querySelectorAll("td")[2].title;
ok(/Shape floor 8\.00/.test(tip), "MAE tooltip carries the shape-floor diagnostic");
ok(!/% of this MAE|level error/.test(tip), "no share-of-MAE / remainder-is-level-error claim");
T.state.view = "board"; T.writeHash();
ok(/res=q15/.test(globalThis.window.location.hash), "writeHash keeps res=q15 on the board");

// 2. browser Back to the plain board URL -> hourly default
globalThis.window.location.hash = "#view=board&zone=GR";
T.readHash(); T.renderScoreboard();
ok(T.state.res === "h60", "Back to a URL without res= -> hourly default");
ok(!/15-min/.test(table().textContent), "hourly board header (no 15-min label)");
ok(/50\.0/.test(cellsOf("GR").textContent), "GR shows the hourly MAE again");
ok(/70\.0/.test(cellsOf("CH").textContent), "CH is scored again on the hourly board");
ok(getById("res-select").value === "h60", "the select returns to Hourly");
T.writeHash();
ok(!/res=/.test(globalThis.window.location.hash), "hourly board URL stays clean (no res=)");

// 3. Forward again -> q15
globalThis.window.location.hash = "#view=board&zone=GR&res=q15";
T.readHash();
ok(T.state.res === "q15", "Forward to #res=q15 -> q15 again");

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("q15_board_route: all assertions passed");
