/* DOM assertions for the order-book per-block decision-trace TABLE (renderBookTable
 * in web/app.js), driven through a tiny dependency-free DOM stub — no jsdom.
 *
 * Reads a real NEW-schema book parquet (with the `strategy` column), shapes GR via
 * the worker's shapeBook (the exact data the SPA renders), then drives
 * renderBookTable for the reference hour and asserts the table DOM.
 *
 * Reference hour: GR 2026-07-27 UTC hour 10 — Korinthos Power (29WGU-KORITHPWR3)
 * reads must_run_deep €7.33 / 91 MW, must_run_rest €106.62, srmc_base €139.29,
 * and peak tranches. Point BOOK_PARQUET at the NEW parquet; OLD_PARQUET (no
 * strategy column) exercises graceful degradation. Skips cleanly if absent.
 */
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { parquetReadObjects } from "hyparquet";
import { compressors } from "hyparquet-compressors";
import { shapeBook } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../../web/app.js");
const newPq = process.env.BOOK_PARQUET;
const oldPq = process.env.OLD_PARQUET;

const havePq = !!(newPq && existsSync(newPq));
if (!havePq) {
  console.log("book_table: BOOK_PARQUET absent — running synthesized-ladder checks only " +
    "(set BOOK_PARQUET=<new-schema parquet> for the GR h10 reference section)");
}

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- minimal DOM stub (only what renderBookTable/el/ownerLabel touch) ---- */
class El {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this._text = null;
    this.attrs = {}; this.hidden = false; this._handlers = {};
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
const host = new El("div");
globalThis.window = { location: { search: "" }, __EUPHEMIA_NO_AUTOINIT: true };
globalThis.document = {
  documentElement: new El("html"),
  createElement: (t) => new El(t),
  createElementNS: (_ns, t) => new El(t),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  getElementById: (id) => (id === "book-table" ? host : new El("div")),
};
// theme colours are read via getComputedStyle(--vars); a dummy colour suffices.
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#888888" });

await import(appPath);
const api = globalThis.window.__euphemiaBook;
ok(api && typeof api.renderBookTable === "function", "app.js exposed renderBookTable test surface");

/* ---- shape the real book, reconstruct the hour-10 ladder like renderBookLadder ---- */
async function readRows(path) {
  const buf = readFileSync(path);
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  return parquetReadObjects({ file: ab, compressors });
}

if (havePq) {   // ---- GR 2026-07-27 h10 reference section (needs a strategy-column parquet) ----
const rows = await readRows(newPq);
const book = shapeBook(rows, "GR", "2026-07-27");
ok(book.has_strategy === true, "NEW parquet: has_strategy true");
const H = 10;
ok(book.hours[H] === "2026-07-27T10:00:00Z", "hour index 10 is 10:00 UTC (got " + book.hours[H] + ")");

function ladder(arr) {
  const L = arr.map((o) => ({ price: o[0], mw: o[1], owner: book.owners[o[2]], strat: book.strategies[o[3]] }));
  let cum = 0;
  L.forEach((o) => { o.cum0 = cum; cum += o.mw; o.cum1 = cum; });
  return { L, total: cum };
}
const s = ladder(book.supply[H]);
const d = ladder(book.demand[H]);
// choose a clearing price that leaves must-run cleared and srmc/peak uncleared
const clearing = 120.0;
let clearMW = s.total;
for (const o of s.L) { if (o.price >= clearing) { clearMW = o.cum0; break; } }

host.textContent = "";
api.renderBookTable(s.L, d.L, { clearMW: clearMW, clearing: clearing, actual: null,
  settledMW: null, totalMW: s.total, hasStrategy: true });

const table = host.querySelector(".book-table");
ok(table != null, "table rendered into #book-table");
const headers = host.querySelectorAll("th").map((t) => t.textContent);
ok(headers.includes("strategy") && headers.includes("why"),
   "NEW: strategy + why columns present (" + headers.join(",") + ")");
// new columns + units (owner refinements 1-3)
ok(headers.includes("type") && headers.includes("position"),
   "h10: type + position (waterfall) columns present");
ok(headers.includes("price €/MWh") && headers.includes("block MW"),
   "h10: price/MW headers carry units");
ok(host.querySelectorAll(".bt-waterfall").length > 0, "h10: waterfall cells rendered");
ok(host.querySelectorAll(".bt-wf-clear").length === host.querySelectorAll(".bt-wf").length &&
   host.querySelectorAll(".bt-wf").length > 0,
   "h10: every waterfall bar carries the clearing guide");
const fullText = host.textContent;

// Korinthos row: owner code appears (units ref not loaded → label falls back to
// the code tail "…KORITHPWR3"); its strategies + reference prices are present.
ok(/KORITHPWR3/.test(fullText), "Korinthos Power block present in the table");
ok(/must-run · deep block/.test(fullText), "must_run_deep label rendered");
ok(/must-run · remainder/.test(fullText), "must_run_rest label rendered");
ok(/SRMC base tranche/.test(fullText), "srmc_base label rendered");
ok(/peak tranche/.test(fullText), "peak tranche label rendered");
ok(/7\.33/.test(fullText), "reference price €7.33 (must_run_deep) present");
ok(/106\.62/.test(fullText), "reference price €106.62 (must_run_rest) present");
ok(/139\.29/.test(fullText), "reference price €139.29 (srmc_base) present");
// explanation column text
ok(/Technical-minimum block/.test(fullText), "must_run_deep explanation rendered");

// clearing split + cleared/uncleared classes + demand section
ok(host.querySelector(".bt-divider") != null && /clears at €120/.test(fullText),
   "clearing divider row present");
ok(host.querySelectorAll(".is-cleared").length > 0, "cleared rows styled distinctly");
ok(host.querySelectorAll(".is-uncleared").length > 0, "uncleared rows styled distinctly");
ok(host.querySelector(".bt-section") != null && /Demand \(willingness to pay\)/.test(fullText),
   "demand section header present");

// expander: a multi-tranche group row folds child tranche rows, hidden until toggled
const expandable = host.querySelectorAll(".is-expandable");
ok(expandable.length > 0, "multi-tranche groups fold into an expander");
if (expandable.length) {
  const g = expandable[0];
  const before = g.getAttribute("aria-expanded");
  g._fire("click");
  ok(g.getAttribute("aria-expanded") === "true" && before === "false",
     "expander toggles aria-expanded on click");
}

/* ---- graceful degradation on the OLD (no-strategy) parquet ---- */
if (oldPq && existsSync(oldPq)) {
  const orows = await readRows(oldPq);
  const obook = shapeBook(orows, "GR", "2026-07-27");
  ok(obook.has_strategy === false, "OLD parquet: has_strategy false");
  const os = ladder2(obook, obook.supply[H]);
  const od = ladder2(obook, obook.demand[H]);
  let ocm = os.total;
  for (const o of os.L) { if (o.price >= clearing) { ocm = o.cum0; break; } }
  host.textContent = "";
  api.renderBookTable(os.L, od.L, { clearMW: ocm, clearing: clearing, actual: null,
    settledMW: null, totalMW: os.total, hasStrategy: false });
  const oheaders = host.querySelectorAll("th").map((t) => t.textContent);
  ok(!oheaders.includes("strategy") && !oheaders.includes("why"),
     "OLD: strategy/why columns hidden");
  ok(/Strategy tags are available for books captured after/.test(host.textContent),
     "OLD: degradation note shown");
} else {
  console.log("book_table: OLD parquet not provided — graceful-degradation half skipped");
}
}   // ---- end havePq reference section ----
function ladder2(bk, arr) {
  const L = arr.map((o) => ({ price: o[0], mw: o[1], owner: bk.owners[o[2]],
    strat: bk.strategies && o[3] != null ? bk.strategies[o[3]] : null }));
  let cum = 0; L.forEach((o) => { o.cum0 = cum; cum += o.mw; o.cum1 = cum; });
  return { L, total: cum };
}

/* ---- synthesized ladder (no parquet): the waterfall / type / units / demand
   markers / import-fixed / coupling-row refinements, deterministically ---- */
console.log("-- synthesized-ladder refinements --");
function mk(arr) { let c = 0; arr.forEach((o) => { o.cum0 = c; c += o.mw; o.cum1 = c; }); return { L: arr, total: c }; }
const SS = mk([
  { price: 1,      mw: 800, owner: "IMPORT",                         strat: "import_fixed" },
  { price: 7.33,   mw: 91,  owner: "29WGU-KORITHPWR3",              strat: "must_run_deep" },
  { price: 90,     mw: 500, owner: "AGG-GR-Fossil_Gas",            strat: "srmc_base" },
  { price: 139.29, mw: 400, owner: "29WGU-LAVRIO-IV8",             strat: "srmc_base" },
  { price: 300,    mw: 300, owner: "AGG-GR-Hydro_Water_Reservoir", strat: "water_value_reservoir" },
]);
const DD = mk([
  { price: 3000, mw: 1400, owner: "DEMAND", strat: "demand_firm" },
  { price: 250,  mw: 150,  owner: "DEMAND", strat: "demand_elastic" },
]);
const clr = 139.29, tot = SS.total;
let cMW = tot; for (const o of SS.L) { if (o.price >= clr) { cMW = o.cum0; break; } }

// render 1: no coupling
host.textContent = "";
api.renderBookTable(SS.L, DD.L, { clearMW: cMW, clearing: clr, actual: null, settledMW: null, totalMW: tot, hasStrategy: true });
let T = host.textContent;
const H2 = host.querySelectorAll("th").map((t) => t.textContent);
ok(["position", "cumulative MW", "type", "owner", "price €/MWh", "block MW"].every((c) => H2.includes(c)),
   "synth: all new/unit headers present (" + H2.join(",") + ")");
// (2) type column — fuel family icon + name (from AGG codes; tags for IMPORT/DEMAND)
ok(/🔥 Gas/.test(T), "type col: 🔥 Gas (AGG gas)");
ok(/💧 Hydro/.test(T), "type col: 💧 Hydro (AGG hydro)");
ok(/🔌 Net imports/.test(T), "type col: 🔌 Net imports (IMPORT tag)");
ok(/📉 Demand/.test(T), "type col: 📉 Demand (DEMAND tag)");
// (5a) fixed net-import injection renders as a normal supply row w/ import_fixed
ok(/scheduled import/.test(T), "import_fixed row present as a supply block (scheduled import)");
// (3) waterfall bars + (4) demand markers overlaid on every bar
const nWf = host.querySelectorAll(".bt-wf").length;
ok(nWf > 0, "synth: waterfall bars rendered (" + nWf + ")");
ok(host.querySelectorAll(".bt-wf-clear").length === nWf, "clearing guide on every bar");
ok(host.querySelectorAll(".bt-wf-demand").length > 0, "demand-step guide(s) drawn");
ok(host.querySelector(".bt-legend") != null && /clearing quantity/.test(T) && /demand step/.test(T),
   "waterfall legend present (clearing + demand step)");

// render 2: coupling per-source (flows day + sign gate passed)
host.textContent = "";
api.renderBookTable(SS.L, DD.L, { clearMW: cMW, clearing: clr, actual: null, settledMW: null, totalMW: tot,
  hasStrategy: true, impliedNetImport: 1440,
  tradeSegs: [{ zone: "BG", mw: 1240, price: 95.1, fixed: false }, { zone: "(fixed)", mw: 200, fixed: true }] });
T = host.textContent;
ok(host.querySelectorAll(".bt-coupling").length >= 2, "coupling rows rendered (per-source + fixed)");
ok(/\(coupling\) BG/.test(T) && /95\.10/.test(T), "coupling row: (coupling) BG @ €95.10 at neighbour price");
ok(/coupled import/.test(T), "coupling strategy label 'coupled import'");
ok(/🔗 coupling/.test(T), "coupling type is 🔗 coupling");
ok(/\(coupling\) fixed imports/.test(T), "fixed out-of-footprint residual row present");
ok(/coupling import\/export/.test(T), "legend gains the coupling key");

// render 3: anonymous coupling (no flows / sign gate failed)
host.textContent = "";
api.renderBookTable(SS.L, DD.L, { clearMW: cMW, clearing: clr, actual: null, settledMW: null, totalMW: tot,
  hasStrategy: true, impliedNetImport: 900, tradeSegs: null });
T = host.textContent;
ok(/\(coupling\) net imports/.test(T) && host.querySelectorAll(".bt-coupling").length === 1,
   "anonymous coupling → single net-imports row at the clearing price");

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("BOOK TABLE DOM OK");
