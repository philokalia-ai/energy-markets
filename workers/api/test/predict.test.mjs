/* DOM smoke test for the Predictions hub + Load/Solar/Wind target pages
 * (pillars 2-4), driven through the same dependency-free DOM stub the order-book
 * table test uses — no jsdom. It loads web/app.js with autoinit suppressed,
 * seeds predictState from the committed fixtures, and drives the exposed
 * window.__euphemiaPredict builders, asserting each composed surface renders the
 * elements the plan's acceptance criteria require:
 *   • every target page = the same skeleton (contract strip, model card, skill,
 *     knobs, output, physics) — a reviewer sees only the driver list + physics differ,
 *   • honesty is PER-ZONE: NL_solar shows the pack + the corr-guard demotion story,
 *     GR_wind ships the pack, a no-solar zone renders the skip state,
 *   • collapse lives on Solar (cliff + pending metrics), not Load/Wind,
 *   • the skill strip renders the warming-up state (no fabricated deep-lead rows),
 *   • the hub family table + target cards render from the scorecard.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../../..");
const appPath = join(repo, "web/app.js");
const fx = (p) => JSON.parse(readFileSync(join(repo, "web/fixtures/inputs", p), "utf8"));

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- minimal DOM stub (only what the predict builders + driverMiniChart touch) ---- */
class El {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this._text = null;
    this.attrs = {}; this.hidden = false; this._handlers = {}; this.dataset = {}; this.style = {};
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
globalThis.window = { location: { search: "" }, __EUPHEMIA_NO_AUTOINIT: true };
globalThis.document = {
  documentElement: new El("html"),
  createElement: (t) => new El(t),
  createElementNS: (_ns, t) => new El(t),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  getElementById: () => new El("div"),
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#888888" });

await import(appPath);
const P = globalThis.window.__euphemiaPredict;
ok(P && typeof P.buildTargetView === "function", "app.js exposed the __euphemiaPredict test surface");

/* ---- seed predictState from committed fixtures ---- */
P.predictState.manifest = fx("manifest.json");
P.predictState.scorecard = fx("scorecard.json");
P.predictState.skill = fx("skill.json");
P.predictState.reservoir = fx("reservoir.json");
P.predictState.zoneData = { GR: fx("GR.json"), NL: fx("NL.json"), NO1: fx("NO1.json") };

/* ---- 1. skeleton parity: each target page is the same six-card skeleton ---- */
for (const [zone, target] of [["GR", "load"], ["GR", "solar"], ["GR", "wind"]]) {
  const v = P.buildTargetView(zone, target);
  const cards = v.querySelectorAll(".chart-card");
  ok(cards.length === 6, `${zone}/${target}: six-card skeleton (got ${cards.length})`);
  const txt = v.textContent;
  ok(/honest fitted-model contract/.test(txt), `${zone}/${target}: A. contract strip`);
  ok(/model card/.test(txt), `${zone}/${target}: B. model card`);
  ok(/Per-lead input skill/.test(txt), `${zone}/${target}: C. skill strip`);
  ok(/The knobs/.test(txt), `${zone}/${target}: D. knobs`);
  ok(/predicted vs ENTSO-E reference vs settled actual/.test(txt), `${zone}/${target}: E. output chart`);
  ok(v.querySelectorAll(".physics-panel").length === 1, `${zone}/${target}: F. physics panel`);
}

/* ---- 2. per-zone honesty (not a blanket "ML") ---- */
{
  // GR load — ML winner, temperature-response physics, Orthodox holiday callout.
  const load = P.buildTargetView("GR", "load");
  const lt = load.textContent;
  ok(/LightGBM ships/.test(lt), "GR load: ML verdict");
  ok(/Temperature-response curve/.test(lt), "GR load: temperature-response physics");
  ok(/Orthodox-Easter map/.test(lt), "GR load: Orthodox holiday callout");
  ok(/Autoregression/.test(lt), "GR load: AR readout");
  ok(!/Collapse classification/.test(lt), "GR load: NO collapse metrics (load doesn't collapse)");

  // GR solar — ML winner, collapse cliff + pending collapse metrics.
  const solar = P.buildTargetView("GR", "solar");
  const st = solar.textContent;
  ok(/collapse cliff/i.test(st), "GR solar: collapse cliff physics");
  ok(/Collapse classification/.test(st), "GR solar: collapse metrics block present");
  ok(/Pending/.test(st), "GR solar: collapse metrics render pending (not fabricated)");
  ok(/night-clamped/.test(st), "GR solar: night-clamp annotation");

  // NL solar — the corr-guard DEMOTION: pack ships though ML cut MAE.
  const nlSolar = P.buildTargetView("NL", "solar");
  const nt = nlSolar.textContent;
  ok(/linear pack ships|pack ships/.test(nt), "NL solar: pack ships");
  ok(/LOST on correlation|beaten by the pack on corr/.test(nt), "NL solar: the honest demotion story");

  // GR wind — pack ships (GR_wind lost to its pack); power curve + pack-vs-ML honesty.
  const wind = P.buildTargetView("GR", "wind");
  const wt = wind.textContent;
  ok(/Power curve/.test(wt), "GR wind: power-curve physics");
  ok(/physical PACK/.test(wt), "GR wind: pack-vs-ML honesty callout (pack wins here)");
  ok(!/Collapse classification/.test(wt), "GR wind: NO collapse metrics");

  // NO1 solar — a no-resource skip renders an explicit state, not a blank.
  const skip = P.buildTargetView("NO1", "solar");
  ok(/No solar regime|no meaningful solar/.test(skip.textContent), "NO1 solar: explicit skip state");
}

/* ---- 3. skill strip: warming-up state ---- */
{
  const s = P.buildSkill("GR", "load");
  ok(/Warming up/.test(s.textContent), "skill strip renders the warming-up state");
}

/* ---- 4. hub composites render from the scorecard ---- */
{
  const fam = P.buildFamilyTable();
  const ft = fam.textContent;
  ok(fam.querySelector(".data-table") != null, "hub: family table rendered");
  ok(fam.querySelectorAll("th").length === 4, "hub: family table has zone/load/solar/wind headers");
  ok(/ship the NEW LightGBM/.test(ft), "hub: family headline (winner breakdown)");
  ok(fam.querySelectorAll(".fam-badge").length > 0, "hub: per-zone winner badges rendered");

  const cards = P.buildTargetCards();
  const ct = cards.textContent;
  ok(/Load/.test(ct) && /Solar/.test(ct) && /Wind/.test(ct), "hub: three target cards");
  ok(/owns collapse/.test(ct), "hub: Solar card owns-collapse teaser");

  const contract = P.buildContractStrip(null, null);
  ok(/load \/ solar \/ wind/.test(contract.textContent), "hub: contract strip un-specialized (all three)");
}

if (failures) {
  console.error(`predict: ${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("predict: ALL PREDICTION SURFACES OK");
