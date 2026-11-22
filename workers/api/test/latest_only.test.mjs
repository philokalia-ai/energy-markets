/* DOM test: the site shows the latest and best only (web/CLAUDE.md), and the "since freeze" window.
 *  - zone explorer: Timestral + physics is the headline series, the physics clear is labelled
 *    with its code_version, no GBM line is drawn even when the payload carries gbm/stats, and a
 *    06:30 prices-only Timestral issue is labelled and dashed as such;
 *  - recent-days chart: same series; a cleared day with no published actual reads "no actual";
 *  - scoreboard: the since_freeze window is offered right after "All days" with its label,
 *    cohorts under 14 scored days show "insufficient data", the note shows the day count;
 *    old JSON (no since_freeze entries) offers no such window and hides the note.
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


/* ---------- 1. zone explorer: Timestral + physics headline, no GBM lines ---------- */
const HOURS = ["2026-11-14T22:00:00Z", "2026-11-14T23:00:00Z", "2026-11-15T00:00:00Z"];
const mkDay = (date, actual, mode) => ({ date: date, lead_days: 1, input_mode: "weather", code_version: 45,
  prediction_made_utc: "2026-11-14T09:00:00Z", hours: HOURS.slice(), sim: [100, 110, 120],
  actual: actual, gbm: [90, 95, 99], stats: [105, 108, 111],
  tsfm: [101, 109, 119], tsfm_q10: [90, 100, 110], tsfm_q90: [110, 120, 130],
  tsfm_input_mode: mode || "postsim", tsfm_issue_utc: "2026-11-14T09:00:00Z", tsfm_arm: "timestral-209m",
  mae: actual[0] === null ? null : 5, bias: actual[0] === null ? null : 1, corr: actual[0] === null ? null : 0.9 });
const NA = [null, null, null], SET = [98, 107, 118];
T.state.zone = "GR"; T.state.track = "predicted"; T.state.view = "explorer";
T.state.zoneCache["GR"] = { zone: "GR", market_day_tz: "Europe/Athens",
  days: [mkDay("2026-11-18", NA), mkDay("2026-11-17", SET), mkDay("2026-11-16", NA, "pregate0630"),
         mkDay("2026-11-15", SET)] };
T.state.day = "2026-11-17";
T.renderExplorer();
const chipTexts = (id) => getById(id).children.filter((c) => c.tagName === "span").map((c) => c.textContent);
const exChips = chipTexts("chart-legend");
ok(/^Timestral \+ physics/.test(exChips[0]), "explorer: Timestral + physics is the first (headline) series — " + exChips[0]);
ok(exChips.some((t) => /^Physics \(cv45\)/.test(t)), "explorer: the physics series is labelled with its code_version");
ok(!exChips.some((t) => /GBM/.test(t)), "explorer: no GBM series in the legend");
const exPaths = () => getById("chart-wrap")._all((e) => e.tagName === "path", []);
ok(exPaths().length === 4, "explorer: band + Timestral + physics + actual paths, nothing else (" + exPaths().length + ")");
ok(!exPaths().some((e) => e.attrs["stroke-dasharray"]), "explorer: the combined Timestral line is solid");
ok(/^Timestral \+ physics €\/MWh/.test(getById("hour-table").querySelectorAll("th")[1].textContent),
  "explorer: the hour table carries the Timestral + physics column");
T.state.day = "2026-11-16"; T.renderExplorer();
ok(/^Timestral \(prices only\)/.test(chipTexts("chart-legend")[0]), "explorer: a 06:30 prices-only issue is never labelled as the combined model");
ok(exPaths().some((e) => e.attrs["stroke-dasharray"] === "5 4"), "explorer: the prices-only issue is drawn dashed");
const dayPills = getById("day-list")._all((e) => e._classes().includes("pill"), []).map((e) => e.textContent);
ok(dayPills.indexOf("no actual") !== -1 && dayPills.indexOf("forecast") !== -1,
  "explorer day list: a cleared day without an actual reads 'no actual', the next day 'forecast'");

/* ---------- 2. recent-days chart ---------- */
T.renderHorizon();
const hzChips = chipTexts("hz-legend");
ok(/^Timestral \+ physics \(prices only where marked\)/.test(hzChips[0]), "recent days: mixed issues are labelled — " + hzChips[0]);
ok(hzChips.length === 3 && !hzChips.some((t) => /GBM/.test(t)), "recent days: three series, no GBM");
const texts = getById("hz-wrap")._all((e) => e.tagName === "text", []).map((e) => e.textContent);
ok(texts.indexOf("no actual") !== -1, "recent days: the cleared day without an actual reads 'no actual' (not 'forecast')");
ok(texts.filter((t) => t === "forecast").length === 1, "recent days: only the not-yet-cleared day reads 'forecast'");
ok(texts.some((t) => /^MAE 5 · \+1Physics MAE/.test(t)), "recent days: settled days carry a short MAE · bias caption — " + texts.filter((t) => /MAE/.test(t)).join(" | "));

/* ---------- 3. scoreboard: since_freeze window ---------- */
const S = (zone, lead, win, n, mae) => ({ zone: zone, lead_days: lead, window: win, input_mode: "weather",
  n_days: n, mae: mae, bias: -1, corr: 0.8, code_version: 44 });
const table = () => getById("scoreboard-table");
const rowOf = (zone) => table().querySelectorAll("tr").filter((r) => r.textContent.startsWith(zone))[0];
T.state.res = "h60"; T.state.naive = "auto"; T.state.sort = { lead: null, metric: "mae", dir: 1 };
// old JSON: all + months only
T.state.scoreboard = { zones: ["GR", "DE_LU"], scores: [S("GR", 1, "all", 60, 70), S("GR", 1, "2026-10", 31, 72),
  S("DE_LU", 1, "all", 60, 58)] };
T.state.window = "all";
Object.defineProperty(getById("window-select"), "options", { get() { return this.children; } });
const optLabels = () => { T.renderWindowSelect(); return getById("window-select").children.map((o) => o.value + "=" + o.textContent); };
ok(!optLabels().some((o) => /since_freeze/.test(o)), "old JSON: no since-freeze window offered");
T.renderScoreboard();
ok(getById("window-note").hidden === true, "old JSON: no since-freeze note");
// new JSON: since_freeze with GR 2 days (insufficient) and DE_LU 20 days
T.state.scoreboard.scores.push(S("GR", 1, "since_freeze", 2, 40), S("DE_LU", 1, "since_freeze", 20, 30));
const opts = optLabels();
ok(opts[0] === "all=All days" &&
   opts[1] === "since_freeze=since freeze (cv45, 2026-11-21) — the only out-of-sample physics record" &&
   opts[2].startsWith("2026-10="), "window options: All days, since freeze (labelled), then months");
T.state.window = "since_freeze";
T.renderScoreboard();
const note = getById("window-note");
ok(note.hidden === false && /20 scored market days/.test(note.textContent) &&
   /only out-of-sample physics record/.test(note.textContent) && /43 characteristics \(40 price-informed\)/.test(note.textContent), "note shows the day count and the claim");
const gr = rowOf("GR").querySelectorAll("td"), de = rowOf("DE_LU").querySelectorAll("td");
ok(gr[2].textContent === "insufficient data" && gr[1].textContent === "—" && /2 scored days/.test(gr[2].title),
  "GR (2 days < 14): insufficient data");
ok(/^30\.0/.test(de[2].textContent), "DE_LU (20 days): MAE shown (" + de[2].textContent + ")");
ok(table().querySelectorAll("tr").filter((r) => /^(GR|DE_LU)/.test(r.textContent))[0].textContent.startsWith("GR"),
  "GR still pinned first");
T.state.scoreboard.scores = T.state.scoreboard.scores.filter((s) => s.zone !== "DE_LU" || s.window !== "since_freeze");
T.renderScoreboard();
ok(/2 scored market days/.test(note.textContent) && /Insufficient data/.test(note.textContent),
  "under 14 days everywhere: the note says insufficient data");
T.state.window = "all"; T.renderScoreboard();
ok(note.hidden === true && /70\.0/.test(rowOf("GR").textContent), "back to All days: note hidden, numbers back");

// URL: a shared #window=since_freeze link selects the window; Back to a plain board
// URL (no window=) returns to All days (writeHash writes non-default windows only).
globalThis.window.location.hash = "#view=board&zone=GR&window=since_freeze";
T.readHash(); T.renderScoreboard();
ok(T.state.window === "since_freeze" && note.hidden === false, "#window=since_freeze selects the window");
T.state.view = "board"; T.writeHash();
ok(/window=since_freeze/.test(globalThis.window.location.hash), "writeHash keeps window=since_freeze");
globalThis.window.location.hash = "#view=board&zone=GR";
T.readHash(); T.renderScoreboard();
ok(T.state.window === "all" && note.hidden === true, "Back to a URL without window= -> All days, note hidden");

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("latest_only: all assertions passed");
