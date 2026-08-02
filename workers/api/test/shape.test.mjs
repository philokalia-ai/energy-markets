/* Shape-equality test: run the Worker's shapers against the parquet staging
 * dir (bin/export_web_parquet.jl output) and assert the result equals the
 * JSON exported by bin/export_forecast_json.jl for the same DB state.
 *
 *   STAGING=../../data/web/v1  (parquet, default)
 *   REF=../../web/data         (reference JSON, default)
 *
 * Both exporters must have run back-to-back against the same DB. Comparison
 * is numeric (5 == 5.0) and order-insensitive where the contract does not
 * fix an order (scoreboard.scores). generated_utc is exempt: the JSON
 * exporter stamps its own export instant, the API stamps the data plane's
 * manifest.updated_at.
 */
import { readFileSync, readdirSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { parquetReadObjects } from "hyparquet";
import { compressors } from "hyparquet-compressors";
import { shapeZone, shapeScoreboard, shapeMap } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const STAGING = process.env.STAGING || join(here, "../../../data/web/v1");
const REF = process.env.REF || join(here, "../../../web/data");

// Data-dependent (like book/flows/units): both exporters must have run against
// the same DB (data/ is git-ignored). Skip cleanly when the staging/ref output
// is absent instead of throwing, so the suite is green in a fresh checkout.
if (!existsSync(join(STAGING, "manifest.json")) || !existsSync(join(REF, "zones"))) {
  console.log("shape: SKIP (no export output; run bin/export_web_parquet.jl + " +
    "bin/export_forecast_json.jl, or set STAGING=/REF=)");
  process.exit(0);
}

let failures = 0;
function fail(msg) {
  failures++;
  console.error("FAIL: " + msg);
}

async function readParquet(path) {
  const buf = readFileSync(path);
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  return parquetReadObjects({ file: ab, compressors });
}

/** Deep numeric-aware equality; returns first difference path or null. */
function diff(a, b, path) {
  path = path || "$";
  if (a === null || a === undefined) {
    return b === null || b === undefined ? null : path + ": " + a + " != " + b;
  }
  if (typeof a === "number" || typeof b === "number") {
    return Number(a) === Number(b) ||
      (Number.isNaN(Number(a)) && Number.isNaN(Number(b)))
      ? null : path + ": " + a + " != " + b;
  }
  if (Array.isArray(a)) {
    if (!Array.isArray(b)) return path + ": array vs " + typeof b;
    if (a.length !== b.length) return path + ": length " + a.length + " != " + b.length;
    for (let i = 0; i < a.length; i++) {
      const d = diff(a[i], b[i], path + "[" + i + "]");
      if (d) return d;
    }
    return null;
  }
  if (typeof a === "object") {
    if (typeof b !== "object" || b === null) return path + ": object vs " + b;
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of keys) {
      const d = diff(a[k], b[k], path + "." + k);
      if (d) return d;
    }
    return null;
  }
  return a === b ? null : path + ": " + JSON.stringify(a) + " != " + JSON.stringify(b);
}

const manifest = JSON.parse(readFileSync(join(STAGING, "manifest.json"), "utf8"));

// ---- zones ----------------------------------------------------------------
const zoneFiles = readdirSync(join(REF, "zones")).filter((f) => f.endsWith(".json"));
let zonesOk = 0;
for (const f of zoneFiles) {
  const zone = f.replace(/\.json$/, "");
  const refJson = JSON.parse(readFileSync(join(REF, "zones", f), "utf8"));
  const pqPath = join(STAGING, "zones", zone + ".parquet");
  if (!existsSync(pqPath)) {
    fail("zones/" + zone + ": parquet missing");
    continue;
  }
  const got = shapeZone(await readParquet(pqPath), zone);
  const d = diff(refJson, got);
  if (d) fail("zones/" + zone + ": " + d);
  else zonesOk++;
}
console.log("zones: " + zonesOk + "/" + zoneFiles.length + " equal");

// ---- scoreboard -------------------------------------------------------------
{
  const refJson = JSON.parse(readFileSync(join(REF, "scoreboard.json"), "utf8"));
  const got = shapeScoreboard(await readParquet(join(STAGING, "scoreboard.parquet")), manifest);
  if (!got.generated_utc) fail("scoreboard: generated_utc missing");
  const key = (s) => [s.zone, s.lead_days, s.input_mode, s.window].join("|");
  const sortScores = (list) => list.slice().sort((x, y) => key(x) < key(y) ? -1 : 1);
  const canon = (j) => ({
    code_version: j.code_version,
    market_day_tz: j.market_day_tz,
    zones: j.zones,
    scores: sortScores(j.scores),
  });
  const d = diff(canon(refJson), canon(got));
  if (d) fail("scoreboard: " + d);
  else console.log("scoreboard: equal (" + got.scores.length + " score entries)");
}

// ---- map --------------------------------------------------------------------
{
  const refJson = JSON.parse(readFileSync(join(REF, "map.json"), "utf8"));
  const got = shapeMap(await readParquet(join(STAGING, "map.parquet")), manifest);
  if (!got.generated_utc) fail("map: generated_utc missing");
  const canon = (j) => ({
    code_version: j.code_version,
    market_day_tz: j.market_day_tz,
    days: j.days,
  });
  const d = diff(canon(refJson), canon(got));
  if (d) fail("map: " + d);
  else console.log("map: equal (" + got.days.length + " days)");
}

if (failures) {
  console.error(failures + " failure(s)");
  process.exit(1);
}
console.log("ALL SHAPES EQUAL");
