/* DOM smoke test for pillar 5 — the #view=method reference AND the Component-A
 * "explain this block" popover reconciliation — driven through a dependency-free
 * DOM stub (no jsdom), the same technique as book_table.test.mjs.
 *
 * Feeds app.js the committed methodology + zone-strategy FIXTURES (the exact JSON
 * the SPA renders), then:
 *   1. renders the method view and asserts B1..B6 populate with GENERATED numbers;
 *   2. drives buildBlockExplain for a gas srmc_base block and asserts the SRMC
 *      waterfall reconciles to the block's own offered price (✓), flags a mismatch
 *      (⚠), and — on the GR-fixture live=null path — never fabricates a number.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../../web/app.js");
const methodology = JSON.parse(readFileSync(join(here, "fixtures/book_methodology.json"), "utf8"));
const zoneStrategies = JSON.parse(readFileSync(join(here, "fixtures/zone_strategies.json"), "utf8"));

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- minimal DOM stub (superset of the book_table stub: id registry) ---- */
class El {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this._text = null;
    this.attrs = {}; this.hidden = false; this._handlers = {}; this.style = {};
    const self = this;
    this.classList = {
      add(c) { if (!self._classes().includes(c)) self.className = (self.className + " " + c).trim(); },
      remove(c) { self.className = self._classes().filter((x) => x !== c).join(" "); },
      toggle(c, on) { on ? this.add(c) : this.remove(c); },
      contains(c) { return self._classes().includes(c); },
    };
  }
  _classes() { return this.className.split(/\s+/).filter(Boolean); }
  appendChild(c) { this.children.push(c); if (c instanceof El) c.parentNode = this; return c; }
  removeChild(c) { this.children = this.children.filter((x) => x !== c); return c; }
  contains(n) { if (n === this) return true; for (const c of this.children) if (c instanceof El && c.contains(n)) return true; return false; }
  setAttribute(k, v) { this.attrs[k] = String(v); if (k === "class") this.className = String(v); }
  getAttribute(k) { return this.attrs[k] === undefined ? null : this.attrs[k]; }
  addEventListener(t, fn) { (this._handlers[t] || (this._handlers[t] = [])).push(fn); }
  removeEventListener() {}
  _fire(t, ev) { (this._handlers[t] || []).forEach((fn) => fn(ev || { preventDefault() {}, stopPropagation() {} })); }
  getBoundingClientRect() { return { top: 0, bottom: 0, left: 0, right: 0 }; }
  scrollIntoView() {}
  set textContent(v) { this.children = []; this._text = v == null ? "" : String(v); }
  get textContent() {
    let s = this._text || "";
    for (const c of this.children) s += c instanceof El ? c.textContent : (c.nodeValue || "");
    return s;
  }
  _all(pred, out) { for (const c of this.children) if (c instanceof El) { if (pred(c)) out.push(c); c._all(pred, out); } return out; }
  _pred(sel) {
    if (sel[0] === ".") { const cls = sel.slice(1); return (e) => e._classes().includes(cls); }
    const tag = sel.toLowerCase(); return (e) => e.tagName && e.tagName.toLowerCase() === tag;
  }
  querySelector(sel) { const r = this._all(this._pred(sel), []); return r[0] || null; }
  querySelectorAll(sel) { const r = this._all(this._pred(sel), []); r.forEach = Array.prototype.forEach.bind(r); return r; }
}
const registry = {};
function byId(id) { return registry[id] || (registry[id] = new El("div")); }
const body = new El("body");
globalThis.window = {
  location: { search: "", hash: "" }, __EUPHEMIA_NO_AUTOINIT: true,
  scrollX: 0, scrollY: 0, innerWidth: 1200, addEventListener() {}, setTimeout: setTimeout,
};
globalThis.document = {
  documentElement: new El("html"), body: body,
  createElement: (t) => new El(t), createElementNS: (_ns, t) => new El(t),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  getElementById: byId,
  querySelectorAll: () => { const a = []; a.forEach = Array.prototype.forEach.bind(a); return a; },
  addEventListener() {}, removeEventListener() {},
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#888888" });

await import(appPath);
const api = globalThis.window.__euphemiaBook;
ok(api && typeof api.renderMethod === "function", "app.js exposed the method test surface");

/* ---- 1. render the method view from the fixtures ---- */
api.setMethodology(methodology);
api.setZoneStrategies(zoneStrategies);
api.state.view = "method";
api.state.methodZone = "FR";
await api.renderMethod();

ok(byId("b4-glossary").querySelectorAll(".method-gloss-card").length > 5,
   "B4: strategy glossary cards rendered from the generated glossary");
ok(/base tranche at short-run marginal cost/.test(byId("b4-glossary").textContent),
   "B4: srmc_base description is the generated text (not a hand-copy)");
ok(/TRANCHES/.test(byId("b3-table").textContent) && /MUST_RUN_PRICE_FACTOR/.test(byId("b3-table").textContent),
   "B3: parameter table lists the form constants");
ok(byId("b3-table").querySelectorAll(".prov-badge").length > 3,
   "B3: provenance badges present (observed/declared wall)");
ok(/SRMC/.test(byId("b1-waterfall").textContent) && byId("b1-waterfall").querySelectorAll(".method-wf-seg").length >= 2,
   "B1: SRMC waterfall renders with stacked segments");
ok(/MUST_RUN_SRMC_THRESHOLD/.test(byId("b2-schematic").textContent) &&
   byId("b2-schematic").querySelectorAll(".method-tranche").length >= 4,
   "B2: tranche schematic + must-run economics rendered");
ok(/FR/.test(byId("b5-zone").textContent) && byId("b5-controls").querySelectorAll(".method-chip").length > 10,
   "B5: per-zone explorer shows FR + a zone picker");
ok(/no_ship|NO-SHIP/.test(byId("b6-ledger").textContent) && /cv31/.test(byId("b6-ledger").textContent),
   "B6: cv-ledger timeline shows shipped + NO-SHIP rows at equal prominence");
ok(byId("b6-census").querySelectorAll(".method-census-col").length === 2,
   "B6: observed/declared census has both columns");

/* ---- 2. Component A — the "explain this block" reconciliation self-check ---- */
const gas = methodology.cost_model.gas;
function gasSRMC(ttf, eua) { return ttf / gas.efficiency + eua * gas.emission_factor_th / gas.efficiency + gas.vom; }
const t1 = methodology.form_constants.values.TRANCHES[0][1];   // tranche-1 multiplier (0.95)

// (a) inject live closes so the waterfall CAN reconcile, and build a block whose
// offered price = SRMC × tranche-1 multiplier — the ✓ path.
const live = { ttf_eur_mwh_th: 35, eua_eur_t: 75 };
const methLive = JSON.parse(JSON.stringify(methodology));
methLive.cost_model.live = { ...methLive.cost_model.live, ...live };
api.setMethodology(methLive);
const srmc = gasSRMC(live.ttf_eur_mwh_th, live.eua_eur_t);
const good = api.buildBlockExplain({ price: srmc * t1, mw: 300, owner: "AGG-GR-Fossil_Gas", strat: "srmc_base" });
ok(/✓/.test(good.textContent) && /reconciles/.test(good.textContent),
   "A: gas srmc_base at SRMC×mult reconciles (✓) with the offered price");
ok(/TTF/.test(good.textContent) && /O&M/.test(good.textContent),
   "A: the three SRMC addends are shown (TTF/η, carbon, O&M)");

// (b) a block whose price does NOT match must flag ⚠ — never a fake reconciliation.
const bad = api.buildBlockExplain({ price: srmc * t1 * 2.0, mw: 300, owner: "AGG-GR-Fossil_Gas", strat: "srmc_base" });
ok(/⚠/.test(bad.textContent) && /does not fully explain/.test(bad.textContent),
   "A: a mismatched price shows ⚠ (honesty over a fake reconciliation)");

// (c) GR-fixture path: live = null -> no numeric waterfall is fabricated.
api.setMethodology(methodology);   // fixture: cost_model.live.* is null offline
const noLive = api.buildBlockExplain({ price: 139.29, mw: 400, owner: "AGG-GR-Fossil_Gas", strat: "srmc_base" });
ok(!/✓ reconciles/.test(noLive.textContent) && /no live close/.test(noLive.textContent),
   "A: with no live close the popover states so and does not invent a reconciliation");

// (d) a non-gas / must-run block names its rule + constant, never a fake number.
const mr = api.buildBlockExplain({ price: 7.33, mw: 91, owner: "29WGU-KORITHPWR3", strat: "must_run_deep" });
ok(/MUST_RUN_PRICE_FACTOR/.test(mr.textContent),
   "A: must_run_deep popover names MUST_RUN_PRICE_FACTOR (rule, not fabricated number)");

if (failures) { console.error("\n" + failures + " assertion(s) failed"); process.exit(1); }
console.log("\nMETHOD VIEW + POPOVER DOM OK");
