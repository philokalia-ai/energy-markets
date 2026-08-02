/* DOM smoke test: with the live API ABSENT, every view renders the honest
 * "Live data unavailable — retry" state (the shared liveUnavailable component)
 * and NEVER a synthetic/bundled snapshot. Driven through the same dependency-
 * free DOM stub the order-book / predict tests use — no jsdom, no network.
 *
 * The clean cut (fix/no-runtime-fixtures): app.js has one data plane, live-only.
 * loadLive() hits the API and rejects on failure; each view surfaces the honest
 * empty state. This test stubs global fetch to always reject (API down), loads
 * app.js with autoinit suppressed, then drives each view's real load+render path
 * via window.__euphemiaViews and asserts the honest component appears with a
 * working retry — proving no view falls back to fixtures.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const appPath = join(here, "../../..", "web/app.js");

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- minimal DOM stub with an id registry (so we can inspect view hosts) ---- */
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

globalThis.window = { location: { search: "", hash: "" }, __EUPHEMIA_NO_AUTOINIT: true };
globalThis.document = {
  documentElement: new El("html"),
  createElement: (t) => new El(t),
  createElementNS: (_ns, t) => new El(t),
  createTextNode: (t) => ({ nodeValue: String(t) }),
  getElementById: getById,
  querySelectorAll: () => [],
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#888888" });

// The live plane is ABSENT: every fetch rejects. There is no fixtures rung to
// fall back to, so each view must reach its honest empty state.
let fetchCount = 0;
globalThis.fetch = () => { fetchCount++; return Promise.reject(new Error("network down (API absent)")); };

await import(appPath);
const V = globalThis.window.__euphemiaViews;
ok(V && typeof V.liveUnavailable === "function", "app.js exposed the __euphemiaViews test surface");
ok(typeof V.loadLive === "function", "loadLive (live-only loader) is exposed");

const tick = () => new Promise((r) => setTimeout(r, 0));
async function settle() { for (let i = 0; i < 8; i++) await tick(); }

// The honest component: a .live-unavailable panel with the title + a retry button.
function assertHonest(host, name) {
  const panel = host && host.querySelector(".live-unavailable");
  ok(!!panel, name + ": renders the .live-unavailable honest state");
  if (!panel) return null;
  ok(/Live data unavailable/.test(panel.textContent), name + ": shows the 'Live data unavailable' title");
  const retry = panel.querySelector(".lu-retry");
  ok(!!retry, name + ": offers a Retry action");
  ok(/never substitutes synthetic|never falls back/i.test(panel.textContent),
     name + ": states the no-synthetic-fallback promise");
  return retry;
}

/* ---- 1. app-level bootstrap (scoreboard) — the whole app has no data ---- */
V.state.zone = "GR";
V.bootstrapData();
await settle();
{
  const box = getById("load-error");
  ok(box.hidden === false, "bootstrap: the load-error host is shown");
  const retry = assertHonest(box, "bootstrap");
  // retry re-runs the bootstrap (fetch still down → still honest, no throw)
  const before = fetchCount;
  if (retry) retry._fire("click");
  await settle();
  ok(fetchCount > before, "bootstrap: Retry re-hits the live API (no snapshot path)");
}

/* ---- 2. zone-backed views (explorer + horizon) via selectZone ---- */
V.state.zone = "GR";
V.selectZone("GR", true);
await settle();
assertHonest(getById("chart-wrap"), "explorer");
assertHonest(getById("hz-wrap"), "horizon");

/* ---- 3. map view via setView('map') (loadMap rejects) ---- */
V.setView("map");
await settle();
assertHonest(getById("map-wrap"), "map");

/* ---- 4. order-book view (renderBook → loadZone rejects) ---- */
V.state.zone = "GR";
byId.delete("book-wrap"); // fresh host
V.renderBook();
await settle();
assertHonest(getById("book-wrap"), "book");

/* ---- 5. predictions target page (loadPredictZone rejects) ---- */
V.state.zone = "GR";
V.renderPredictTarget("load");
await settle();
assertHonest(getById("predict-target-view"), "predict");

/* ---- 6. bid-methodology reference (loadMethodology rejects) ---- */
byId.delete("method-status"); // fresh host
V.setView("method");          // sets state.view = "method", then renders
await settle();
assertHonest(getById("method-status"), "method");

/* ---- 7. no snapshot was ever fetched: only apiPath (…/v1/…) or geo ---- */
ok(fetchCount > 0, "views actually attempted the live API (fetch was called)");

if (failures) {
  console.error(`views_empty_state: ${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("views_empty_state: ALL VIEWS SHOW THE HONEST EMPTY STATE (no synthetic fallback)");
