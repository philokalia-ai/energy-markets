/* DOM test: the GLOBAL TRACK SWITCH (Predicted | As-announced).
 *
 * Drives app.js's real track-switch path through the same dependency-free DOM
 * stub the other web tests use (no jsdom, no network). Asserts that flipping the
 * switch (a) re-renders the series + labels off the OTHER track, (b) updates the
 * URL (track= in the hash), (c) toggles the segmented control's active state, and
 * (d) surfaces the client-side track-gap chip where both tracks scored a day.
 *
 * The two tracks are input_mode buckets: "weather*" -> predicted, everything
 * else (entsoe*) -> announced. Every zone file carries BOTH; the switch filters
 * client-side, so this test injects a zone with both tracks and never fetches.
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
ok(T && typeof T.setTrack === "function", "app.js exposed the __euphemiaTrack test surface");

/* ---- track bucketing ---- */
ok(T.trackOfMode("weather") === "predicted", "weather -> predicted track");
ok(T.trackOfMode("weather+loadfill") === "predicted", "weather+loadfill -> predicted track");
ok(T.trackOfMode("entsoe") === "announced", "entsoe -> announced track");
ok(T.trackOfMode("entsoe+loadfill+resfill") === "announced", "entsoe+... -> announced track");

/* ---- inject a zone that carries BOTH tracks for the same delivery day ---- */
const DATE = "2026-07-09";
const HOURS = ["2026-07-09T21:00:00Z", "2026-07-09T22:00:00Z"];
function mkDay(mode, sim, mae) {
  return {
    date: DATE, lead_days: 1, input_mode: mode,
    prediction_made_utc: "2026-07-08T06:00:00Z",
    hours: HOURS.slice(), sim: sim.slice(), actual: [12, 19],
    mae: mae, bias: 0, corr: 0.9,
  };
}
const zoneData = { zone: "GR", market_day_tz: "Europe/Athens", days: [
  mkDay("weather", [10, 20], 2.0),   // predicted
  mkDay("entsoe", [11, 21], 1.0),    // announced
] };
T.state.zone = "GR";
T.state.zoneCache["GR"] = zoneData;
T.state.day = DATE;
T.state.view = "explorer";

/* ---- trackDays filters by the current track ---- */
T.state.track = "predicted";
ok(T.trackDays(zoneData).length === 1 && T.trackDays(zoneData)[0].input_mode === "weather",
   "trackDays returns only the predicted (weather) day when track=predicted");
T.state.track = "announced";
ok(T.trackDays(zoneData).length === 1 && T.trackDays(zoneData)[0].input_mode === "entsoe",
   "trackDays returns only the announced (entsoe) day when track=announced");

/* ---- render the switch: two buttons, correct active state ---- */
T.state.track = "predicted";
T.renderTrackSwitch();
{
  const host = getById("track-switch");
  const btns = host.querySelectorAll(".seg-btn");
  ok(btns.length === 2, "track switch renders two segmented buttons");
  const active = btns.filter((b) => b._classes().includes("active"));
  ok(active.length === 1 && active[0].dataset.track === "predicted",
     "predicted is the active button by default");
  ok(/Predicted/.test(getById("track-explainer").textContent),
     "explainer names the selected track (Predicted)");
  ok(/measured cost of our inputs/.test(getById("track-explainer").textContent),
     "explainer states the gap = cost-of-inputs framing");
  ok(/not a strictly pre-gate/.test(getById("track-explainer").textContent),
     "explainer carries the 'as announced != strictly pre-gate' honesty note");
}

/* ---- render explorer on the predicted track ---- */
T.renderExplorer();
const subPredicted = getById("chart-sub").textContent;
const tablePredicted = getById("hour-table").textContent;
ok(/predicted inputs/.test(subPredicted), "explorer sub reads the predicted-track series label");
ok(/10\.00/.test(tablePredicted) && /20\.00/.test(tablePredicted),
   "explorer hour table shows the PREDICTED sim series (10, 20)");
ok(getById("day-stats").querySelector(".track-gap-chip") != null,
   "track-gap chip is shown (both tracks scored this day)");
{
  const chip = getById("day-stats").querySelector(".track-gap-chip");
  ok(/input cost \+1\.0/.test(chip.textContent),
     "gap chip computes input cost = predicted MAE (2.0) - announced MAE (1.0) = +1.0");
}

/* ---- FLIP the switch to As-announced ---- */
T.setTrack("announced");

ok(T.state.track === "announced", "setTrack('announced') updates state.track");
ok(/track=announced/.test(globalThis.window.location.hash),
   "the URL hash gains track=announced on flip");
ok(store["euphemia.track"] === "announced", "the preference is persisted to localStorage");
{
  const btns = getById("track-switch").querySelectorAll(".seg-btn");
  const active = btns.filter((b) => b._classes().includes("active"));
  ok(active.length === 1 && active[0].dataset.track === "announced",
     "the announced button becomes active after the flip");
  ok(/As announced/.test(getById("track-explainer").textContent),
     "explainer now names the As-announced track");
}
const subAnnounced = getById("chart-sub").textContent;
const tableAnnounced = getById("hour-table").textContent;
ok(subAnnounced !== subPredicted, "the explorer sub LABEL changed on the flip");
ok(/announced D-1 inputs/.test(subAnnounced), "explorer sub reads the announced-track series label");
ok(/11\.00/.test(tableAnnounced) && /21\.00/.test(tableAnnounced),
   "explorer hour table now shows the ANNOUNCED sim series (11, 21) — the series changed");
ok(!/10\.00/.test(tableAnnounced), "the predicted series (10) is no longer shown");

/* ---- FLIP back: the default track drops out of the URL (clean links) ---- */
T.setTrack("predicted");
ok(T.state.track === "predicted", "setTrack('predicted') restores the default");
ok(!/track=/.test(globalThis.window.location.hash),
   "the default track is omitted from the URL hash (clean links)");
ok(/10\.00/.test(getById("hour-table").textContent),
   "the predicted series is restored after flipping back");

if (failures) {
  console.error("track_switch: " + failures + " FAILURE(S)");
  process.exit(1);
}
console.log("track_switch: THE GLOBAL SWITCH FLIPS EVERY SERIES SURFACE + THE URL");
