/* DOM test: the site reads each market day at its own resolution.
 *
 * The record keeps hourly days (24 slots; 23/25 on DST days) next to quarter-hour days
 * (96; 92/100) for good, so every reader decides per day: the zones API's `resolution`
 * ("PT60M" | "PT15M"), else the spacing of the day's stamps. Hourly days render exactly as
 * before. On a quarter-hour day: slot-end labels, ticks every 3 hours, Timestral (hourly)
 * as a step scored against the hourly mean of the settled quarters, a 15-min table
 * grouped by hour, and the "recent days" ribbon keeps equal day widths across the switch.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../..", "web/app.js");

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- minimal DOM stub (same shape as one_track.test.mjs) ---- */
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
  querySelector() { return null; }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { left: 0, top: 0, width: 900, height: 380 }; }
}
const byId = new Map();
function getById(id) {
  if (!byId.has(id)) byId.set(id, new El("div"));
  return byId.get(id);
}
globalThis.window = { location: { search: "", hash: "" }, __EUPHEMIA_NO_AUTOINIT: true,
  localStorage: { getItem: () => null, setItem: () => {} } };
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
const S = globalThis.window.__euphemiaSlots;
ok(S && typeof S.slotMinutes === "function", "app.js exposed the __euphemiaSlots test surface");

/* ---- fixtures: Athens market days as UTC slot starts ---- */
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
function stamps(startIso, n, minutes) {
  const t0 = Date.parse(startIso);
  return Array.from({ length: n }, (_, i) => iso(t0 + i * minutes * 60000));
}
function mkDay(date, startIso, n, minutes, extra) {
  const hours = stamps(startIso, n, minutes);
  const per = 60 / minutes;
  const sim = hours.map((_, i) => 100 + 10 * Math.sin(i / per));
  const actual = hours.map((_, i) => 104 + 12 * Math.sin(i / per + 0.3));
  const tsfm = hours.map((_, i) => 101 + Math.floor(i / per));   // hourly: repeats on the hour's slots
  return Object.assign({ date, lead_days: 1, input_mode: "weather", code_version: 45,
    prediction_made_utc: "2026-11-21T10:00:00Z", hours, sim, actual, gbm: hours.map(() => null),
    stats: hours.map(() => null), mae: 5, bias: -1, corr: 0.9, tsfm,
    tsfm_q10: tsfm.map((v) => v - 10), tsfm_q90: tsfm.map((v) => v + 10), p_le0: tsfm.map(() => 0.02),
    p_any_le0: 0.02, tsfm_input_mode: "postsim", tsfm_issue_utc: null, tsfm_arm: null }, extra || {});
}
const H = mkDay("2026-11-21", "2026-11-20T22:00:00Z", 24, 60);                       // today's hourly payload
const Hn = mkDay("2026-11-21", "2026-11-20T22:00:00Z", 24, 60, { resolution: "PT60M", actual_resolution: "PT60M" });
const Q = mkDay("2026-11-22", "2026-11-21T22:00:00Z", 96, 15, { resolution: "PT15M", actual_resolution: "PT15M", code_version: 46 });
const Qbare = mkDay("2026-11-22", "2026-11-21T22:00:00Z", 96, 15);                   // no field: spacing decides
const QDST = mkDay("2026-10-25", "2026-10-24T21:00:00Z", 100, 15, { resolution: "PT15M", actual_resolution: "PT15M" });

/* ---- resolution per day ---- */
ok(S.slotMinutes(H) === 60 && S.slotMinutes(Hn) === 60 && !S.isQuarterDay(H), "hourly day: 60-min slots (with or without the field)");
ok(S.slotMinutes(Q) === 15 && S.slotMinutes(Qbare) === 15 && S.isQuarterDay(Q), "quarter day: 15-min slots (field, or stamp spacing)");
ok(S.slotMinutes({ hours: ["2026-11-21T10:00:00Z"] }) === 60, "a single stamp defaults to hourly");

/* ---- slot-end labels ---- */
ok(S.slotEndLabel(Q.hours[1], Q) === "00:30", "quarter slot 00:15 ends 00:30 (Athens)");
ok(S.slotEndLabel(H.hours[0], H) === S.hourEndLabel(H.hours[0]) && S.slotEndLabel(H.hours[0], H) === "01:00",
   "hourly slot end unchanged");

/* ---- hour groups ---- */
const gq = S.hourGroups(Q), gh = S.hourGroups(H), gd = S.hourGroups(QDST);
ok(gq.length === 24 && gq.every((g) => g[1] - g[0] === 3), "96 quarters -> 24 hours of 4");
ok(gh.length === 24 && gh.every((g) => g[0] === g[1]), "24 hours -> 24 single-slot groups");
ok(gd.length === 25 && gd.every((g) => g[1] - g[0] === 3), "DST day: 100 quarters -> 25 hours");

/* ---- Timestral's MAE: hourly, against the hourly mean of the settled quarters ---- */
function oldMae(day) {   // the formula before D4 (index-aligned), for hourly days
  let sum = 0, n = 0;
  day.tsfm.forEach((v, i) => { const a = day.actual[i]; if (v == null || a == null) return; sum += Math.abs(v - a); n++; });
  return n ? { mae: sum / n, n } : null;
}
const mh = S.tsfmDayMae(H), mo = oldMae(H);
ok(mh.mae === mo.mae && mh.n === mo.n, "hourly day: Timestral MAE bit-identical to the old formula");
let ref = 0;
gq.forEach((g) => { let s = 0; for (let i = g[0]; i <= g[1]; i++) s += Q.actual[i]; ref += Math.abs(Q.tsfm[g[0]] - s / 4); });
const mq = S.tsfmDayMae(Q);
ok(mq.n === 24 && Math.abs(mq.mae - ref / 24) < 1e-12, "quarter day: MAE over 24 hours vs the hourly mean of the quarters");
const Qgap = Object.assign({}, Q, { actual: Q.actual.slice() }); Qgap.actual[5] = null;
ok(S.tsfmDayMae(Qgap).n === 23, "an hour with an unsettled quarter is not scored");

/* ---- settled state counts slots ---- */
const lone = Object.assign({}, Q, { actual: Q.actual.map((a, i) => (i < 4 ? a : null)) });
ok(S.settleState(Q, "2026-11-30") === "settled", "all 96 quarters settled -> settled");
ok(S.settleState(lone, "2026-11-30") === "missing", "only the first hour's 4 quarters -> missing (the CET day's last hour)");
ok(S.lastSettledDate([H, Q, Object.assign({}, Q, { date: "2026-11-23", actual: Q.actual.map(() => null) })]) === "2026-11-22",
   "lastSettledDate across hourly and quarter days");

/* ---- legends ---- */
ok(S.actualLegend(H) === "Actual (settled)", "hourly actual legend unchanged");
ok(S.actualLegend(Q) === "Actual (settled, 15-min)", "quarter actual legend");
ok(S.actualLegend(Object.assign({}, Q, { actual_resolution: "PT60M" })) === "Actual (settled, hourly)",
   "quarter day without native quarter actuals: hourly actual named as such");
ok(S.physicsLegend([H]) === "Physics (cv45)" && S.physicsLegend([Q]) === "Physics (cv46) · 15-min" &&
   S.physicsLegend([H, Q]) === "Physics (cv45–46) · hourly, then 15-min", "physics legend per resolution");
ok(S.tsfmLegend([H]) === "Timestral + physics · median, q10–q90" && /hourly median/.test(S.tsfmLegend([Q])),
   "Timestral legend says hourly over quarter days only");

/* ---- the step: one flat segment per hour ---- */
const X = (i) => i * 10, Y = (v) => v;
const step = S.hourStepPath(Q, Q.tsfm, X, Y);
const segs = step.split(/ (?=[ML])/);
ok(segs.length === 48, "hourStepPath: 24 hours -> 48 points (start + end of each hour)");
ok(/^M0\.00 101\.00 L40\.00 101\.00 L40\.00 102\.00 L80\.00 102\.00/.test(step), "flat over each hour, vertical at the hour boundary");
ok(step.endsWith("L950.00 124.00"), "the last hour ends at the day's last slot");
ok(S.hourStepBands(Q, X, Y).length === 1, "one band path for a gap-free day");

/* ---- explorer: quarter day vs hourly day ---- */
function rows() { return getById("hour-table")._all((e) => e.tagName === "tr", []); }
function cells(pred) { return getById("hour-table")._all((e) => e.tagName === "td" && pred(e), []); }
const zone = { zone: "GR", market_day_tz: "Europe/Athens", days: [Q, H] };
S.state.zone = "GR"; S.state.zoneCache.GR = zone; S.state.view = "explorer";
Q.actual[37] = Q.sim[37] + 50;   // a large miss at 09:15 Athens for the day comment
S.state.day = "2026-11-22"; S.renderExplorer();
ok(rows().length === 97, "quarter day table: header + 96 slot rows");
ok(cells((e) => e.attrs.rowspan === "4").length === 24, "Timestral cell spans its hour's 4 quarters (24 cells)");
ok(getById("hour-table-summary").textContent === "15-min values (table)", "table summary names 15-min");
ok(/15-minute periods/.test(getById("chart-sub").textContent), "subtitle names 15-minute periods");
ok(/Largest miss: 09:15–09:30 Athens/.test(getById("day-comment").textContent), "day comment labels the quarter-hour slot");
S.state.day = "2026-11-21"; S.renderExplorer();
ok(rows().length === 25 && cells((e) => e.attrs.rowspan).length === 0, "hourly day table: header + 24 rows, no spans");
ok(getById("hour-table-summary").textContent === "Hourly values (table)", "hourly summary unchanged");
ok(/hours shown in Europe\/Athens/.test(getById("chart-sub").textContent), "hourly subtitle unchanged");

/* ---- ribbon: equal day widths across the hourly -> 15-min switch ---- */
const days = [Object.assign({}, H, { date: "2026-11-19", hours: stamps("2026-11-18T22:00:00Z", 24, 60) }),
  Object.assign({}, H, { date: "2026-11-20", hours: stamps("2026-11-19T22:00:00Z", 24, 60) }),
  Object.assign({}, Q, { date: "2026-11-21", hours: stamps("2026-11-20T22:00:00Z", 96, 15) }),
  Object.assign({}, Q, { date: "2026-11-22", hours: stamps("2026-11-21T22:00:00Z", 96, 15) })];
S.state.zoneCache.DE_LU = { zone: "DE_LU", market_day_tz: "Europe/Athens", days: days.slice().reverse() };
S.state.zone = "DE_LU"; S.state.view = "horizon"; S.renderHorizon();
const seps = getById("hz-wrap")._all((e) => e.tagName === "line" && e.attrs["stroke-dasharray"] === "3 4", [])
  .map((e) => +e.attrs.x1);
const gaps = seps.slice(1).map((x, i) => x - seps[i]);
ok(seps.length === 3 && gaps.every((g) => Math.abs(g - gaps[0]) < 1e-9), "day separators equally spaced across mixed days");

if (failures) {
  console.error("q15_site: " + failures + " FAILURE(S)");
  process.exit(1);
}
console.log("q15_site: per-day resolution, hourly unchanged");
