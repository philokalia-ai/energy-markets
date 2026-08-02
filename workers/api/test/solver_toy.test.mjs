/* Solver view (pillar 1) — unit + DOM smoke test, no jsdom, no network, no web/ fixtures.
 *
 * Part A: the PURE closed-form two-zone clear (clearTwoZone in web/app.js) —
 *   walks the three regimes the ATC slider teaches (islanded → congested →
 *   coupled) and asserts the exact prices, gap, flow and congestion rent, incl.
 *   the load-bearing claim that the rent appears exactly when flow = ATC and the
 *   gap closes to €0 at full coupling.
 *
 * Part B: a DOM smoke of the Solver view. The S4 congestion exemplars load ONLY
 *   from the live record API (/api/v1/flows + /zones) — there is NO fixture/
 *   synthetic fallback in the shipped view. This test supplies the record data
 *   through a fetch stub whose sample lives INSIDE this test file (fixtures may
 *   exist only in test files, never in the shipped web/ payload); it also proves
 *   the honest empty state when the record can't serve a border-hour, and that
 *   the synthetic toy carries its "not model data" label + neutral Zone A/Zone B
 *   names on the widget itself.
 */
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../..", "web/app.js");

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }
function near(a, b, tol, msg) { ok(Math.abs(a - b) <= (tol || 1e-6), msg + " (got " + a + ", want " + b + ")"); }

/* ---- minimal DOM stub (only what the solver render fns touch) ---- */
class El {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this._text = null;
    this.attrs = {}; this.hidden = false; this.type = ""; this.value = ""; this._handlers = {};
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
const byId = {};
function getEl(id) { return (byId[id] || (byId[id] = new El("div"))); }

// Default (?live default) → the app uses the live record API rung; the stub
// below is the ONLY data plane. No web/fixtures are read anywhere in this test.
globalThis.window = { location: { search: "" }, __EUPHEMIA_NO_AUTOINIT: true };
globalThis.document = {
  documentElement: new El("html"),
  createElement: (t) => new El(t),
  createElementNS: (_ns, t) => new El(t),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  getElementById: (id) => getEl(id),
  querySelectorAll: () => [],
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#4477aa" });

/* ---- SAMPLE RECORD DATA (test-only; lives here, never in web/) ------------
 * A single FR·IT-NORTH day: 18:00 UTC is a congested separation (FR €95,
 * IT-NORTH €150, flow 2,100 MW FR→IT); 03:00 UTC the border is slack and the
 * two prices sit together (both €38, small flow). */
const HOURS = Array.from({ length: 24 }, (_, h) => `2025-01-22T${String(h).padStart(2, "0")}:00:00Z`);
function zoneDay(zone, sim) {
  return { zone, days: [{ date: "2025-01-22", lead_days: 1, hours: HOURS, sim,
    actual: HOURS.map(() => null) }] };
}
const FR_SIM = HOURS.map((_, h) => (h === 18 ? 95.0 : h === 3 ? 38.0 : 55.0));
const ITN_SIM = HOURS.map((_, h) => (h === 18 ? 150.0 : h === 3 ? 38.0 : 60.0));
const FLOWS_20250122 = { market_day_tz: "Europe/Athens", flows: {
  "2025-01-22T18:00:00Z": [["FR", "IT-NORTH", 2100]],
  "2025-01-22T03:00:00Z": [["FR", "IT-NORTH", 180]],
} };
const RECORD = {
  "/v1/flows/2025-01-22": FLOWS_20250122,
  "/v1/zones/FR": zoneDay("FR", FR_SIM),
  "/v1/zones/IT-NORTH": zoneDay("IT-NORTH", ITN_SIM),
  // NOTE: 2025-06-15 (DE_LU·FR) and other exemplar dates are deliberately absent
  // → the view must degrade to the honest "record flows unavailable" empty state.
};
let recordHits = 0;
globalThis.fetch = (url) => {
  const u = String(url);
  const key = Object.keys(RECORD).find((k) => u.includes(k));
  if (key) { recordHits++; return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(RECORD[key]) }); }
  return Promise.resolve({ ok: false, status: 404, json: () => Promise.reject(new Error("404")) });
};

await import(appPath);
const S = globalThis.window.__euphemiaSolver;
ok(S && typeof S.clearTwoZone === "function", "app.js exposed the solver test surface");

/* ========================= Part A — pure clear ========================= */
const clear = S.clearTwoZone;

const r0 = clear(0);
ok(r0.congested === true, "ATC 0: islanded → congested (no line)");
near(r0.flow, 0, 1e-6, "ATC 0: flow 0");
near(r0.pN, 20, 1e-6, "ATC 0: Zone A prices its cheap block");
near(r0.pS, 95, 1e-6, "ATC 0: Zone B prices its dear block");
near(r0.gap, 75, 1e-6, "ATC 0: gap €75");
near(r0.rent, 0, 1e-6, "ATC 0: no flow → no congestion rent");

const r8 = clear(800);
ok(r8.congested === true, "ATC 800: congested (flow at bound)");
near(r8.flow, 800, 1e-6, "ATC 800: flow = ATC (line full)");
near(r8.pN, 70, 1e-6, "ATC 800: Zone A now on its dear block");
near(r8.pS, 95, 1e-6, "ATC 800: Zone B still dear");
near(r8.gap, 25, 1e-6, "ATC 800: gap €25");
near(r8.rent, 25 * 800, 1e-6, "ATC 800: rent = gap × flow = €20,000/h");

const r20 = clear(2000);
ok(r20.coupled === true, "ATC 2000: coupled (line has room at the efficient flow)");
near(r20.flow, 2000, 1e-6, "ATC 2000: efficient flow 2000 MW");
near(r20.gap, 0, 1e-6, "ATC 2000: ONE price — gap €0");
near(r20.pN, r20.pS, 1e-9, "ATC 2000: both zones price the same marginal unit");
near(r20.pN, 70, 1e-6, "ATC 2000: coupled price €70 (global marginal)");
near(r20.rent, 0, 1e-6, "ATC 2000: coupled ⇒ zero congestion rent");

const r25 = clear(2500);
ok(r25.coupled === true, "ATC 2500: still coupled");
near(r25.flow, 2000, 1e-6, "ATC 2500: flow stays at the efficient 2000 (< ATC ⇒ slack)");
ok(r25.flow < r25.atc, "ATC 2500: flow strictly below ATC (the line is slack)");
near(r25.rent, 0, 1e-6, "ATC 2500: slack line ⇒ no rent");

let invariantOK = true, couplingSeen = false;
for (let atc = 0; atc <= 2500; atc += 50) {
  const r = clear(atc);
  if (r.congested) { if (Math.abs(r.flow - atc) > 1e-6) invariantOK = false; }
  else { couplingSeen = true; if (r.rent !== 0 || Math.abs(r.gap) > 1e-6) invariantOK = false; }
  if (r.rent > 0 && !(r.congested && Math.abs(r.flow - atc) < 1e-6)) invariantOK = false;
}
ok(invariantOK, "invariant: congestion rent appears iff flow = ATC; coupled ⇒ gap €0, rent €0");
ok(couplingSeen, "the coupled regime is reached within the slider range");

near(S.solverMarginalPrice([{ mw: 3000, price: 20 }, { mw: 2000, price: 70 }], 2500), 20, 1e-6, "marginalPrice: within cheap block");
near(S.solverMarginalPrice([{ mw: 3000, price: 20 }, { mw: 2000, price: 70 }], 3300, 1e-6), 70, 1e-6, "marginalPrice: into dear block");
ok(!isFinite(S.solverMarginalPrice([{ mw: 100, price: 5 }], 200)), "marginalPrice: beyond capacity → scarcity (Infinity)");

/* ========================= Part B — DOM smoke ========================= */
// The toy books carry neutral, invented names — never a real zone.
ok(S.SOLVER_TOY_BOOKS.north.name === "Zone A" && S.SOLVER_TOY_BOOKS.south.name === "Zone B",
   "toy books are Zone A / Zone B (no real-zone dressing)");

// S3 toy: renders with the on-widget synthetic label + neutral names.
getEl("solver-atc").value = "800";
S.renderSolverToy();
let toy = getEl("solver-toy");
ok(toy.querySelector("svg") != null, "S3: toy renders an <svg>");
ok(/Illustrative synthetic market — not model data/.test(toy.textContent),
   "S3: the 'not model data' label is visible ON the widget (not a tooltip)");
ok(/Zone A/.test(toy.textContent) && /Zone B/.test(toy.textContent), "S3: toy shows Zone A / Zone B");
ok(/flow 800/.test(toy.textContent), "S3: toy shows flow 800 MW at ATC 800");
ok(/congestion rent/.test(toy.textContent) && /€20,000/.test(toy.textContent), "S3: toy shows the €20,000/h rent");
getEl("solver-atc").value = "2200";
S.renderSolverToy();
toy = getEl("solver-toy");
ok(/ONE price/.test(toy.textContent), "S3: at ATC 2200 the readout collapses to ONE price");
ok(/€0/.test(toy.textContent), "S3: coupled ⇒ congestion rent €0");

// S2 dual + S5 pass render SVGs (no data needed).
S.renderSolver();   // dual, toy, pass, exemplar steps, exemplar
ok(getEl("solver-dual").querySelector("svg") != null, "S2: dual sketch renders an <svg>");
ok(getEl("solver-pass").querySelector("svg") != null, "S5: two-pass step renders an <svg>");
ok(getEl("solver-exemplar-steps").querySelectorAll("button").length === S.SOLVER_EXEMPLARS.length,
   "S4: one stepper button per exemplar");

// S4 exemplar 0 (FR·IT-NORTH, 18:00) — congested, computed live from the RECORD stub.
await new Promise((r) => setTimeout(r, 40));
const ex = getEl("solver-exemplar");
ok(recordHits > 0, "S4: exemplar 0 fetched from the live record API (not a fixture)");
ok(ex.querySelector("svg") != null, "S4: exemplar 0 renders the two-tile SVG from the record");
ok(/price separation/.test(ex.textContent), "S4: exemplar 0 is a congested separation");
ok(/€55/.test(ex.textContent), "S4: separation €55 computed client-side (IT-NORTH €150 − FR €95)");
ok(/€115,500/.test(ex.textContent), "S4: congestion rent €115,500 = €55 × 2,100 MW, computed client-side");
ok(/FR → IT-NORTH/.test(ex.textContent), "S4: flow direction FR → IT-NORTH (cheap → dear)");

// S4 exemplar 1 (same border, 03:00) — uncongested contrast.
getEl("solver-exemplar-steps").children[1]._fire("click");
await new Promise((r) => setTimeout(r, 40));
ok(/prices equalised/.test(getEl("solver-exemplar").textContent),
   "S4: exemplar 1 (03:00) shows prices equalised — the border had room");

// S4 exemplar with no record (DE_LU·FR 2025-06-15) — honest empty state, NO fixture.
getEl("solver-exemplar-steps").children[2]._fire("click");
await new Promise((r) => setTimeout(r, 40));
ok(/Record flows unavailable/.test(getEl("solver-exemplar").textContent),
   "S4: a record-absent exemplar degrades to the honest empty state (never synthetic)");
ok(/never substitutes synthetic data/.test(getEl("solver-exemplar").textContent),
   "S4: the empty state states the no-synthetic-fallback promise");

if (failures) { console.error(`solver_toy: ${failures} FAILURE(S)`); process.exit(1); }
console.log("solver_toy: OK");
