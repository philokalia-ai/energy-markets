/* DOM assertions for renderBookLadder's hour ALIGNMENT and the at-the-money
 * marginal-block split (web/app.js), driven through a tiny dependency-free DOM
 * stub — no jsdom, no fixtures served to the site (test-only data).
 *
 * The two defects this file guards (owner report, GR 2026-08-09 bhr=12):
 *   1. Books are keyed by UTC delivery hour while fday.hours is the Athens
 *      market day (21:00Z D-1 … 20:00Z D): the same INDEX is a different hour
 *      (+3h; 48-hour first-of-run files a whole day). renderBookLadder must
 *      align by TIMESTAMP, fall back to the previous day's cached book for the
 *      first Athens hours, and show an honest note when the hour is absent.
 *   2. A supply block AT the clearing price (the €1 RES block in solar-collapse
 *      hours) was counted wholly UNCLEARED (price >= clearing), collapsing
 *      clearMW to 0 and painting a phantom multi-GW "(coupling) net imports"
 *      row ABOVE the RES block. The at-the-money block must split at the local
 *      balance instead (no phantom wedge).
 */
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { shapeBook } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../../web/app.js");

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- minimal DOM stub (adds .style over the book_table stub; stable ids) ---- */
class El {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this._text = null;
    this.attrs = {}; this.hidden = false; this._handlers = {}; this.style = {};
    const self = this;
    this.classList = {
      add(c) { if (!self._classes().includes(c)) self.className = (self.className + " " + c).trim(); },
      contains(c) { return self._classes().includes(c); },
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
  _pred(sel) {
    if (sel[0] === ".") { const cls = sel.slice(1); return (e) => e._classes().includes(cls); }
    const tag = sel.toLowerCase(); return (e) => e.tagName && e.tagName.toLowerCase() === tag;
  }
  querySelector(sel) { const r = this._all(this._pred(sel), []); return r[0] || null; }
  querySelectorAll(sel) { return this._all(this._pred(sel), []); }
}
const byId = new Map();
function idEl(id) { if (!byId.has(id)) byId.set(id, new El("div")); return byId.get(id); }
globalThis.window = { location: { search: "" }, __EUPHEMIA_NO_AUTOINIT: true };
globalThis.document = {
  documentElement: new El("html"),
  createElement: (t) => new El(t),
  createElementNS: (_ns, t) => new El(t),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  getElementById: (id) => idEl(id),
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#888888" });

await import(appPath);
const api = globalThis.window.__euphemiaBook;
ok(api && typeof api.renderBookLadder === "function", "app.js exposed renderBookLadder test surface");

/* ---- fixtures: an Athens market day + UTC-day books shaped by shapeBook ----
 * Athens 2026-08-09 (EEST, UTC+3): fday.hours = 2026-08-08T21:00Z … 2026-08-09T20:00Z.
 * The day's book parquet covers UTC day 2026-08-09 (00Z…23Z); the previous
 * day's parquet carries 2026-08-08 (00Z…23Z) incl. the 21–23Z Athens hours.
 */
function athensHours(prevDayIso, dayIso) {
  const hrs = [];
  for (let h = 21; h < 24; h++) hrs.push(prevDayIso + "T" + String(h).padStart(2, "0") + ":00:00Z");
  for (let h = 0; h < 21; h++) hrs.push(dayIso + "T" + String(h).padStart(2, "0") + ":00:00Z");
  return hrs;
}
function utcDayRows(dayIso, resMwOf) {
  const rows = [];
  for (let h = 0; h < 24; h++) {
    const ts = new Date(dayIso + "T" + String(h).padStart(2, "0") + ":00:00Z");
    rows.push({ zone: "GR", ts, side: "supply", price: 1.0, mw: resMwOf(h), owner: "RES", strategy: "res_forecast", code_version: 31 });
    rows.push({ zone: "GR", ts, side: "supply", price: 68.5, mw: 500, owner: "29WGU-TESTUNIT-1", strategy: "srmc_base", code_version: 31 });
    rows.push({ zone: "GR", ts, side: "demand", price: 3000, mw: 7000, owner: "DEMAND", strategy: "demand_firm", code_version: 31 });
    rows.push({ zone: "GR", ts, side: "demand", price: 3000, mw: 400, owner: "IMPORT", strategy: "export_demand", code_version: 31 });
  }
  return rows;
}
// distinctive RES MW per UTC hour so a misaligned index is detectable:
// UTC hour h carries 8000 + h MW on day D, 6000 + h on day D-1.
const bookD = shapeBook(utcDayRows("2026-08-09", (h) => 8000 + h), "GR", "2026-08-09");
const bookP = shapeBook(utcDayRows("2026-08-08", (h) => 6000 + h), "GR", "2026-08-08");
const fday = {
  date: "2026-08-09",
  hours: athensHours("2026-08-08", "2026-08-09"),
  sim: new Array(24).fill(1),      // solar-collapse: coupled price == the €1 RES price
  actual: new Array(24).fill(null),
};

api.state.zone = "GR";
api.state.bookDay = "2026-08-09";
api.state.bookCache["GR|2026-08-09"] = bookD;
api.state.bookCache["GR|2026-08-08"] = bookP;

const wrap = idEl("book-wrap");
const table = idEl("book-table");

/* ---- 1. timestamp alignment: Athens hour 12 = 09:00Z (NOT book index 12) ---- */
wrap.textContent = ""; table.textContent = "";
api.renderBookLadder(bookD, fday, 12);
let T = table.textContent;
ok(idEl("book-hour-label").textContent.indexOf("12:00–13:00 Athens") === 0,
   "h12 label is 12:00–13:00 Athens (got " + idEl("book-hour-label").textContent + ")");
ok(/8,009/.test(T), "h12 ladder is the 09:00Z book hour (RES 8,009 MW)");
ok(!/8,012/.test(T), "h12 ladder is NOT book index 12 (12:00Z would be RES 8,012 MW)");

/* ---- 2. at-the-money marginal block: no phantom coupling, local-balance split ---- */
ok(table.querySelectorAll(".bt-coupling").length === 0,
   "clearing == RES price: NO phantom '(coupling) net imports' row");
ok(/clears at €1\.00 · 7,400 MW/.test(T),
   "clearMW = local balance inside the RES block (7,400 MW), not 0 (got divider: " +
   (T.match(/clears at [^—]*/) || ["?"])[0] + ")");
ok(table.querySelectorAll(".is-marginal").length > 0, "the split RES block is marked marginal");
// the country's RES block leads the ladder — the first supply row is RES
const firstRow = table.querySelector(".book-trow");
ok(firstRow && /Renewables|RES/.test(firstRow.textContent), "first supply row is the RES block");

/* ---- 3. first Athens hours resolve from the PREVIOUS day's cached book ---- */
wrap.textContent = ""; table.textContent = "";
api.renderBookLadder(bookD, fday, 0);   // 00:00 Athens = 2026-08-08T21:00Z
T = table.textContent;
ok(/6,021/.test(T), "Athens hour 0 renders the 21:00Z hour of the PREVIOUS day's book (RES 6,021 MW)");

/* ---- 4. missing hour → honest note, never a mismatched ladder ---- */
delete api.state.bookCache["GR|2026-08-08"];
wrap.textContent = ""; table.textContent = "";
api.renderBookLadder(bookD, fday, 0);
ok(/No captured ladder/.test(wrap.textContent),
   "prev-day book absent: honest 'No captured ladder' note (never a mismatched hour)");
ok(table.querySelectorAll(".book-trow").length === 0, "no stale/mismatched table rows");

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("BOOK LADDER ALIGNMENT + ATM SPLIT OK");
