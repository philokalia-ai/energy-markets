/* Route test for /api/v1/book_methodology — the pillar-5 bid-methodology JSON
 * pass-through added to the Worker (workers/api/src/index.js).
 *
 * Drives the Worker's default.fetch with an in-memory R2 stub (head/get) and a
 * caches.default stub, asserting: a published object is served 200 with the JSON
 * body intact; an absent object 404s (the SPA then shows the honest empty state —
 * there is NO snapshot fallback); and the committed TEST fixture is well-formed
 * (cost_model / form_constants / strategy_glossary / provenance / cv_ledger). The
 * fixture lives under workers/api/test/fixtures/ (never shipped to the site). No
 * network, no wrangler — pure routing.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import worker from "../src/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(here, "fixtures/book_methodology.json");
const fixtureText = readFileSync(fixturePath, "utf8");

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

/* ---- in-memory R2 + cache stubs (only what index.js touches) ---- */
function makeEnv(store) {
  return {
    DATA: {
      async head(key) { return key in store ? { httpEtag: '"etag-' + key + '"' } : null; },
      async get(key) {
        if (!(key in store)) return null;
        const text = store[key];
        return { text: async () => text, arrayBuffer: async () => new TextEncoder().encode(text).buffer };
      },
    },
  };
}
// Minimal Cache API stub: always a miss, put() is a no-op sink.
globalThis.caches = { default: { async match() { return undefined; }, async put() {} } };
const ctx = { waitUntil() {} };

function req(path) {
  return new Request("https://api.philokalia.ai" + path, {
    method: "GET",
    headers: { Origin: "https://energy.philokalia.ai" },
  });
}

/* ---- 1. published object is served 200 with the body intact ---- */
{
  const env = makeEnv({ "v1/book_methodology.json": fixtureText });
  const res = await worker.fetch(req("/api/v1/book_methodology"), env, ctx);
  ok(res.status === 200, "published book_methodology -> 200 (got " + res.status + ")");
  ok((res.headers.get("Content-Type") || "").includes("application/json"),
     "content-type is application/json");
  ok(res.headers.get("ETag") != null, "carries an ETag");
  ok(res.headers.get("Access-Control-Allow-Origin") === "https://energy.philokalia.ai",
     "CORS allows energy.philokalia.ai");
  const body = JSON.parse(await res.text());
  ok(body.cost_model && body.form_constants && body.strategy_glossary &&
     body.provenance && body.cv_ledger,
     "body has all five methodology sections");
  ok(body.cost_model.gas && body.cost_model.gas.efficiency > 0,
     "cost_model.gas.efficiency present and positive");
  ok(Array.isArray(body.cost_model.form_constants) === false &&
     body.form_constants.values && body.form_constants.descriptions,
     "form_constants carries values + descriptions");
  ok(Array.isArray(body.cv_ledger) && body.cv_ledger.length > 0, "cv_ledger is a non-empty array");
}

/* ---- 2. absent object 404s (SPA then shows the honest empty state, no snapshot) ---- */
{
  const env = makeEnv({});
  const res = await worker.fetch(req("/api/v1/book_methodology"), env, ctx);
  ok(res.status === 404, "unpublished book_methodology -> 404 (got " + res.status + ")");
}

/* ---- 3. the committed fixture is structurally complete ---- */
{
  const fx = JSON.parse(fixtureText);
  ok(fx.code_version != null, "fixture: code_version present");
  ok(fx.cost_model.fuels && Object.keys(fx.cost_model.fuels).length > 5,
     "fixture: cost model has the fuel table");
  ok(fx.form_constants.values.TRANCHES && fx.form_constants.values.MUST_RUN_PRICE_FACTOR != null,
     "fixture: TRANCHES + MUST_RUN_PRICE_FACTOR present");
  ok(fx.strategy_glossary.srmc_base && fx.strategy_glossary.must_run_deep,
     "fixture: strategy glossary has the core terms");
  ok(fx.provenance.TRANCHES && ["observed", "declared"].includes(fx.provenance.TRANCHES.kind),
     "fixture: provenance badge for TRANCHES");
}

if (failures) { console.error("\n" + failures + " assertion(s) failed"); process.exit(1); }
console.log("\nall book_methodology route assertions passed");
