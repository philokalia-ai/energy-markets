/* Self-contained shape test for the coupled-flows endpoint (shapeFlows).
 *
 * Reads a v1/flows/<date>.parquet and asserts the shape the trade wedge relies
 * on: { market_day_tz, flows: { "<tsIso>": [[source,sink,mw],…] } }, every hour
 * an array of [string,string,number] triples keyed by a UTC ISO timestamp.
 *
 * Point it at a parquet with FLOWS_PARQUET=<path>; defaults to the staged file.
 * Skips cleanly (exit 0) when no parquet is available (forecast-only checkout).
 */
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { parquetReadObjects } from "hyparquet";
import { compressors } from "hyparquet-compressors";
import { shapeFlows } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../../..");
const candidates = [
  process.env.FLOWS_PARQUET,
  join(repo, "data/web/v1/flows/2026-07-27.parquet"),
].filter(Boolean);
const path = candidates.find((p) => existsSync(p));

if (!path) {
  console.log("flows: SKIP (no flows parquet found; set FLOWS_PARQUET=<path>)");
  process.exit(0);
}

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } }

const buf = readFileSync(path);
const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
const rows = await parquetReadObjects({ file: ab, compressors });

const shaped = shapeFlows(rows);
ok(shaped.market_day_tz === "Europe/Athens", "market_day_tz set");
ok(shaped.flows && typeof shaped.flows === "object", "flows is an object");

const hours = Object.keys(shaped.flows);
ok(hours.length > 0, "has hours");
ok(hours.every((ts) => /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(ts)), "hours are UTC ISO");

let triples = 0, bad = 0;
for (const ts of hours) {
  for (const r of shaped.flows[ts]) {
    triples++;
    if (!Array.isArray(r) || r.length !== 3 ||
        typeof r[0] !== "string" || typeof r[1] !== "string" || typeof r[2] !== "number") bad++;
  }
}
ok(bad === 0, "every flow is [source, sink, mw]");
ok(triples === rows.length, "one triple per parquet row");

// GR net into GR at 16:00 UTC (h19): BG→GR present, GR a net exporter that hour.
const grHour = shaped.flows["2026-07-27T16:00:00Z"];
if (grHour) {
  const net = grHour.reduce((a, r) => a + (r[1] === "GR" ? r[2] : (r[0] === "GR" ? -r[2] : 0)), 0);
  ok(net < 0, "GR is a net exporter at 2026-07-27T16:00Z (net " + net.toFixed(0) + " MW)");
}

if (failures) { console.error(`flows: ${failures} FAILURE(S)`); process.exit(1); }
console.log(`flows: OK (${hours.length} hours, ${triples} border-hours)`);
