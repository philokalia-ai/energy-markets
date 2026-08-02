/* Route test for /api/v1/boundaries — the pillar-6 boundary-zones JSON
 * pass-through added to the Worker (workers/api/src/index.js).
 *
 * Drives the Worker's default.fetch with an in-memory R2 stub (head/get) and a
 * caches.default stub, asserting: a published object is served 200 with the JSON
 * body intact; an absent object 404s (the SPA then shows the honest empty state —
 * there is NO snapshot fallback); and the committed TEST fixture is well-formed
 * (elastic books with the GB two-carbon-leg detail + UA firm slice, the fixed
 * TR/AL/MK list with the "NOT a book" correction, the :v3 flow rule). The fixture
 * lives under workers/api/test/fixtures/ (never shipped to the site). No network,
 * no wrangler — pure routing.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import worker from "../src/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(here, "fixtures/boundaries.json");
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
  const env = makeEnv({ "v1/boundaries.json": fixtureText });
  const res = await worker.fetch(req("/api/v1/boundaries"), env, ctx);
  ok(res.status === 200, "published boundaries -> 200 (got " + res.status + ")");
  ok((res.headers.get("Content-Type") || "").includes("application/json"),
     "content-type is application/json");
  ok(res.headers.get("ETag") != null, "carries an ETag");
  ok(res.headers.get("Access-Control-Allow-Origin") === "https://energy.philokalia.ai",
     "CORS allows energy.philokalia.ai");
  const body = JSON.parse(await res.text());
  ok(Array.isArray(body.elastic) && Array.isArray(body.fixed) && body.flow_rule,
     "body has elastic + fixed + flow_rule sections");
  ok(body.n_named_neighbours >= 5, "n_named_neighbours computed (>=5)");
}

/* ---- 2. the .json alias is also routed ---- */
{
  const env = makeEnv({ "v1/boundaries.json": fixtureText });
  const res = await worker.fetch(req("/api/v1/boundaries.json"), env, ctx);
  ok(res.status === 200, "boundaries.json alias -> 200 (got " + res.status + ")");
}

/* ---- 3. absent object 404s (SPA then shows the honest empty state, no snapshot) ---- */
{
  const env = makeEnv({});
  const res = await worker.fetch(req("/api/v1/boundaries"), env, ctx);
  ok(res.status === 404, "unpublished boundaries -> 404 (got " + res.status + ")");
}

/* ---- 4. the committed fixture is structurally complete ---- */
{
  const fx = JSON.parse(fixtureText);
  ok(fx.code_version != null, "fixture: code_version present");
  ok(fx.flow_rule.footprint_default === "v3", "fixture: :v3 footprint flow default");
  ok(/caught our own lookahead/.test(fx.flow_rule.audit_note),
     "fixture: flow rule carries the cv25 lookahead-audit note");

  // GB is two independent books with different carbon legs.
  const gb = fx.elastic.filter((b) => b.counterparty === "GB");
  ok(gb.length === 2, "fixture: GB has two independent books");
  const carbons = gb.map((b) => b.carbon_source).sort();
  ok(carbons[0] === "eua" && carbons[1] === "uka",
     "fixture: GB books carry both carbon legs (eua + uka)");
  const frBook = gb.find((b) => b.borders.includes("FR"));
  ok(frBook && frBook.double_count_fix === true,
     "fixture: the FR↔GB book carries the double-count fix flag");

  // UA is a firm-slice buyer with the generic anchor.
  const ua = fx.elastic.filter((b) => b.counterparty === "UA");
  ok(ua.length >= 1 && ua.some((b) => b.firm_slice === true),
     "fixture: UA carries a firm slice");
  ok(ua.some((b) => b.anchor === "zone_gas_srmc"),
     "fixture: UA anchor is the generic zone_gas_srmc");

  // TR/AL/MK are fixed injections with blank anchors and the correction.
  const tr = fx.fixed.find((f) => f.counterparty === "TR");
  ok(tr && tr.book === null && tr.anchor === null,
     "fixture: TR is a fixed injection (book/anchor blank)");
  ok(tr && /It is neither/.test(tr.correction),
     "fixture: TR carries the 'NOT a book' correction verbatim");
  ok(Array.isArray(tr.roadmap) && tr.roadmap.length === 3,
     "fixture: TR carries the 3-step what-a-TR-book-would-need roadmap");
  ok(fx.fixed.some((f) => f.counterparty === "AL") && fx.fixed.some((f) => f.counterparty === "MK"),
     "fixture: AL + MK present as fixed neighbours");
}

if (failures) { console.error("\n" + failures + " assertion(s) failed"); process.exit(1); }
console.log("\nall boundaries route assertions passed");
