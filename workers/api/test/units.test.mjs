/* Self-contained shape test for the unit-reference endpoint (shapeUnits).
 *
 * Reads v1/units.parquet and asserts the shape invariants the Order-book view
 * relies on:
 *   • { market_day_tz, units: { <code>: {name, fuel, firm, zone} } }
 *   • every row keyed by its code; firm is null or a non-empty string
 *   • the GR case units (POLYFYTO / LAVRIO IV) resolve to the right fuel+firm
 *
 * Point it at a parquet with UNITS_PARQUET=<path>; defaults to the staged file.
 * Skips cleanly (exit 0) when no parquet is available.
 */
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { parquetReadObjects } from "hyparquet";
import { compressors } from "hyparquet-compressors";
import { shapeUnits } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../../..");
const candidates = [
  process.env.UNITS_PARQUET,
  join(repo, "data/web/v1/units.parquet"),
].filter(Boolean);
const path = candidates.find((p) => existsSync(p));

if (!path) {
  console.log("units: SKIP (no units parquet found; set UNITS_PARQUET=<path>)");
  process.exit(0);
}

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } }

const buf = readFileSync(path);
const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
const rows = await parquetReadObjects({ file: ab, compressors });

const shaped = shapeUnits(rows);
ok(shaped.market_day_tz === "Europe/Athens", "market_day_tz set");
ok(shaped.units && typeof shaped.units === "object", "units is an object");

const codes = Object.keys(shaped.units);
ok(codes.length > 0, "has units");
ok(codes.length === new Set(rows.map((r) => r.code)).size, "one entry per distinct code");

let badFirm = 0, badShape = 0;
for (const c of codes) {
  const u = shaped.units[c];
  if (!("name" in u) || !("fuel" in u) || !("firm" in u) || !("zone" in u)) badShape++;
  if (u.firm !== null && (typeof u.firm !== "string" || u.firm.length === 0)) badFirm++;
}
ok(badShape === 0, "every unit has name/fuel/firm/zone keys");
ok(badFirm === 0, "firm is null or a non-empty string");

// GR reference case (owner's screenshot hour): POLYFYTO is PPC hydro, LAVRIO IV
// is PPC gas. Present only when the staged parquet includes GR.
const poly = shaped.units["29WGU-POLYFYTO-Q"];
if (poly) {
  ok(poly.fuel === "Hydro Water Reservoir", "POLYFYTO fuel = Hydro Water Reservoir");
  ok(poly.firm === "PPC", "POLYFYTO firm = PPC");
  ok(poly.zone === "GR", "POLYFYTO zone = GR");
}
const lavrio = shaped.units["29WGU-LAVRIO-IV8"];
if (lavrio) {
  ok(lavrio.fuel === "Fossil Gas", "LAVRIO IV fuel = Fossil Gas");
  ok(lavrio.firm === "PPC", "LAVRIO IV firm = PPC");
}

if (failures) {
  console.error(`units: ${failures} FAILURE(S)`);
  process.exit(1);
}
console.log(`units: OK (${codes.length} units, ${codes.filter((c) => shaped.units[c].firm).length} with a firm)`);
