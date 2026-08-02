/* Route + shape test for the two additive Predictions-page JSON endpoints
 * (pillars 2-4): GET /api/v1/inputs/scorecard and /api/v1/inputs/skill.
 *
 * Both are JSON pass-throughs (no parquet, no shape.js), so this drives the
 * Worker's default fetch handler end-to-end against a mock R2 backed by the
 * test-local fixtures (test/fixtures/inputs/{scorecard,skill}.json) and asserts:
 *   • the router matches the literal /inputs/scorecard and /inputs/skill BEFORE
 *     the generic /inputs/:zone regex (a zone named "scorecard" must not shadow),
 *   • a present object → 200 with the exact fixture bytes + an ETag,
 *   • an absent object → 404,
 *   • the payload SHAPE the model card / skill strip rely on, incl. the
 *     corr-guard reconciliation (NL_solar ships the PACK) and the warming-up skill.
 *
 * Self-contained: polyfills caches (Node has no global Cache API) + a mock env.
 */
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
// Test-local fixtures (the site ships no runtime fixtures — they were removed
// so synthetic data can never render as model output; tests keep their own).
const fxDir = join(here, "fixtures/inputs");
const scorecard = readFileSync(join(fxDir, "scorecard.json"), "utf8");
const skill = readFileSync(join(fxDir, "skill.json"), "utf8");

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } else { console.log("ok - " + msg); } }

// Node has no Cache API; the Worker uses caches.default. A no-op cache forces
// the origin (buildPayload) path, which is what we want to exercise.
globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };

// Mock R2: a flat key -> string store. head() versions the cache entry; get()
// serves the bytes. Only the JSON routes (text()) are exercised here.
function makeEnv(store) {
  return {
    DATA: {
      async head(key) { return key in store ? { httpEtag: "etag-" + key } : null; },
      async get(key) {
        if (!(key in store)) return null;
        const body = store[key];
        return { text: async () => body, arrayBuffer: async () => new TextEncoder().encode(body).buffer };
      },
    },
  };
}

const worker = (await import("../src/index.js")).default;
const ctx = { waitUntil() {} };
const req = (path) => new Request("https://api.philokalia.ai" + path, { method: "GET" });

const store = {
  "v1/inputs/scorecard.json": scorecard,
  "v1/inputs/skill.json": skill,
};
const env = makeEnv(store);

// ---- scorecard route ----
{
  const res = await worker.fetch(req("/api/v1/inputs/scorecard"), env, ctx);
  ok(res.status === 200, "GET /inputs/scorecard -> 200 (got " + res.status + ")");
  ok(res.headers.get("ETag") != null, "scorecard carries an ETag");
  const body = await res.json();
  ok(body.schema === "v1", "scorecard schema v1");
  ok(Array.isArray(body.scores) && body.scores.length === 117, "scorecard has 117 zone-targets (got " + (body.scores || []).length + ")");
  ok(body.winner_counts && body.winner_counts.ml === 72, "winner_counts.ml === 72 (corr-guard truth; got " + (body.winner_counts || {}).ml + ")");
  ok(body.valid_window && body.valid_window.first === "2026-05-01", "valid_window.first set");
  ok(body.collapse_status === "pending", "collapse_status pending (honest, no fabricated numbers)");
  const find = (z, t) => body.scores.find((s) => s.zone === z && s.target === t);
  const nlSolar = find("NL", "solar");
  ok(nlSolar && nlSolar.winner === "pack", "NL_solar ships the PACK (corr-guard demotion)");
  ok(nlSolar && nlSolar.mae_new < nlSolar.mae_base && nlSolar.corr_new < nlSolar.corr_base,
     "NL_solar: ML better MAE but LOST on corr (the demotion story)");
  ok(find("NL", "solar").collapse === null, "solar rows carry a collapse field (null pending)");
  const no1solar = find("NO1", "solar");
  ok(no1solar && no1solar.winner === "skip", "NO1_solar winner=skip (no resource)");
  // every entry carries the model-card keys
  const bad = body.scores.filter((s) => !("zone" in s && "target" in s && "winner" in s &&
    "mae_new" in s && "mae_base" in s && "corr_new" in s && "corr_base" in s && "bias_new" in s));
  ok(bad.length === 0, "every score row has the model-card keys");
}

// ---- skill route ----
{
  const res = await worker.fetch(req("/api/v1/inputs/skill"), env, ctx);
  ok(res.status === 200, "GET /inputs/skill -> 200 (got " + res.status + ")");
  const body = await res.json();
  ok(body.schema === "v1", "skill schema v1");
  ok(body.status === "warming_up", "skill status warming_up (archive still accumulating)");
  ok(Array.isArray(body.skill) && body.skill.length === 0, "skill[] empty — no fabricated deep-lead rows");
  ok(Array.isArray(body.leads) && body.leads.length === 7, "skill declares leads D-1..D-7");
  ok(typeof body.note === "string" && body.note.length > 0, "skill carries an explanatory note");
}

// ---- literal routes are NOT shadowed by /inputs/:zone ----
{
  // A zone endpoint with no object 404s; the literals above succeeded, proving
  // the router matched them before the generic zone regex.
  const res = await worker.fetch(req("/api/v1/inputs/scorecard"), makeEnv({}), ctx);
  ok(res.status === 404, "absent scorecard object -> 404");
  // The generic /inputs/:zone route still matches (a zone with no object 404s at
  // head() — proving it is reachable and distinct from the literals above).
  const zoneRes = await worker.fetch(req("/api/v1/inputs/GR"), makeEnv({}), ctx);
  ok(zoneRes.status === 404, "generic /inputs/:zone route reachable (empty -> 404)");
}

if (failures) {
  console.error(`inputs_routes: ${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("inputs_routes: OK");
