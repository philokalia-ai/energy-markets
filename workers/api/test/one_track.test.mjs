/* DOM test: the site shows ONE track — the physics on our own weather inputs.
 *
 * Zone and scoreboard payloads carry both input-mode buckets ("weather*" and the
 * announced "entsoe*"); the SPA keeps the weather rows only. There is no switch,
 * and a legacy #track=announced link is ignored (web/CLAUDE.md: latest and best only).
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
ok(T && typeof T.trackDays === "function", "app.js exposed the __euphemiaTrack test surface");
ok(!("setTrack" in T) && !("renderTrackSwitch" in T), "no track switch API any more");

/* ---- bucketing ---- */
ok(T.trackOfMode("weather") === "predicted" && T.trackOfMode("weather+loadfill") === "predicted",
   "weather* -> the shown track");
ok(T.trackOfMode("entsoe") === "announced" && T.trackOfMode("entsoe+loadfill+resfill") === "announced",
   "entsoe* -> filtered out");

/* ---- a zone carrying both buckets for the same delivery day ---- */
const DATE = "2026-07-09";
const HOURS = ["2026-07-09T21:00:00Z", "2026-07-09T22:00:00Z"];
const mkDay = (mode, sim) => ({ date: DATE, lead_days: 1, input_mode: mode, code_version: 45,
  prediction_made_utc: "2026-07-08T06:00:00Z", hours: HOURS.slice(), sim: sim.slice(),
  actual: [12, 19], mae: 2, bias: 0, corr: 0.9 });
const zoneData = { zone: "GR", market_day_tz: "Europe/Athens",
  days: [mkDay("weather", [10, 20]), mkDay("entsoe", [11, 21])] };
T.state.zone = "GR"; T.state.zoneCache["GR"] = zoneData; T.state.day = DATE; T.state.view = "explorer";
ok(T.trackDays(zoneData).length === 1 && T.trackDays(zoneData)[0].input_mode === "weather",
   "trackDays keeps only the weather day");
T.renderExplorer();
const table = getById("hour-table").textContent;
ok(/10\.00/.test(table) && /20\.00/.test(table) && !/11\.00/.test(table) && !/21\.00/.test(table),
   "explorer shows the weather physics only");
ok(getById("track-switch").children.length === 0, "no switch is rendered");
ok(!/track gap/i.test(getById("day-stats").textContent), "no predicted/announced gap chip");

/* ---- a legacy #track=announced link is ignored and never written back ---- */
globalThis.window.location.hash = "#view=explorer&zone=GR&track=announced";
T.readHash();
ok(T.state.track === "predicted", "#track=announced is ignored");
T.writeHash();
ok(!/track=/.test(globalThis.window.location.hash), "writeHash never emits track=");

/* ---- scoreboard: weather rows only, full lead ladder ---- */
T.state.scoreboard = { zones: ["GR"], scores: [
  { zone: "GR", lead_days: 1, window: "all", input_mode: "weather", n_days: 5, mae: 12, bias: 0, corr: 0.9, code_version: 45 },
  { zone: "GR", lead_days: 2, window: "all", input_mode: "weather", n_days: 5, mae: 13, bias: 0, corr: 0.88, code_version: 45 },
  { zone: "GR", lead_days: 3, window: "all", input_mode: "weather", n_days: 5, mae: 14, bias: 0, corr: 0.86, code_version: 45 },
  { zone: "GR", lead_days: 1, window: "all", input_mode: "entsoe", n_days: 5, mae: 10, bias: 0, corr: 0.92, code_version: 45 },
] };
ok(T.trackScores().every((s) => s.input_mode === "weather") && T.trackScores().length === 3,
   "trackScores keeps the weather rows only");
const leads = T.scoreboardLeads();
ok(leads.length === 3 && leads[0] === 1 && leads[2] === 3, "scoreboard keeps the D-1..D-3 ladder");

if (failures) {
  console.error("one_track: " + failures + " FAILURE(S)");
  process.exit(1);
}
console.log("one_track: weather track only, no switch");
