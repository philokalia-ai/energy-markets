/* Self-contained shape test for the order-book ladder endpoint (shapeBook).
 *
 * Reads a per-day book parquet (all 39 zones) and asserts the per-zone-day
 * shape invariants the SPA relies on:
 *   • supply ladder ascending in price (the merit order), demand descending
 *   • owner indices resolve within the owners dictionary
 *   • payload stays < 1 MB even for the largest zones (FR/DE_LU)
 *   • the clearing price / actual are NOT embedded (overlaid by the frontend)
 *
 * Point it at a book parquet with BOOK_PARQUET=<path>; defaults to the repo's
 * local backfill books. Skips cleanly (exit 0) when no parquet is available.
 */
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { parquetReadObjects } from "hyparquet";
import { compressors } from "hyparquet-compressors";
import { shapeBook } from "../src/shape.js";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../../..");
const candidates = [
  process.env.BOOK_PARQUET,
  join(repo, "data/backfill_books_cv27/2023-01-15.parquet"),
  join(repo, "data/web/v1/books/2023-01-15.parquet"),
].filter(Boolean);
const path = candidates.find((p) => existsSync(p));

if (!path) {
  console.log("book: SKIP (no book parquet found; set BOOK_PARQUET=<path>)");
  process.exit(0);
}

let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; console.error("FAIL: " + msg); } }

const buf = readFileSync(path);
const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
const rows = await parquetReadObjects({ file: ab, compressors });
const date = "2023-01-15";

for (const zone of ["GR", "FR", "DE_LU"]) {
  const b = shapeBook(rows, zone, date);
  ok(b.zone === zone, zone + ": zone echoed");
  ok(b.hours.length > 0, zone + ": has hours");
  ok(b.supply.length === b.hours.length, zone + ": supply per hour");
  ok(b.demand.length === b.hours.length, zone + ": demand per hour");
  // merit order ascending; demand descending; owner + strategy idx in range
  let asc = true, desc = true, idxOk = true, sIdxOk = true, nOrders = 0;
  ok(Array.isArray(b.strategies), zone + ": strategies index table present");
  for (let h = 0; h < b.hours.length; h++) {
    for (let i = 1; i < b.supply[h].length; i++) {
      if (b.supply[h][i][0] < b.supply[h][i - 1][0]) asc = false;
    }
    for (let i = 1; i < b.demand[h].length; i++) {
      if (b.demand[h][i][0] > b.demand[h][i - 1][0]) desc = false;
    }
    for (const o of b.supply[h].concat(b.demand[h])) {
      if (o[2] < 0 || o[2] >= b.owners.length) idxOk = false;
      if (o[3] < 0 || o[3] >= b.strategies.length) sIdxOk = false;
      nOrders++;
    }
  }
  ok(asc, zone + ": supply ascending in price");
  ok(desc, zone + ": demand descending in price");
  ok(idxOk, zone + ": owner indices in range");
  ok(sIdxOk, zone + ": strategy indices in range");
  // When the parquet carries the strategy column every order must resolve to a
  // NON-empty label; when it does not, has_strategy is false and the SPA hides
  // the strategy columns (graceful degradation).
  if (b.has_strategy) {
    let allLabelled = true;
    for (let h = 0; h < b.hours.length; h++) {
      for (const o of b.supply[h].concat(b.demand[h])) {
        if (!b.strategies[o[3]]) allLabelled = false;
      }
    }
    ok(allLabelled, zone + ": every order has a strategy label (has_strategy)");
  }
  ok(!("clearing" in b) && !("sim" in b) && !("actual" in b),
     zone + ": no embedded clearing/actual (overlaid by frontend)");
  const bytes = Buffer.byteLength(JSON.stringify(b));
  ok(bytes < 1_000_000, zone + ": payload < 1MB (got " + Math.round(bytes / 1024) + " KB)");
  console.log(
    zone + ": " + b.hours.length + " h · " + nOrders + " orders · " +
    b.owners.length + " owners · " + Math.round(bytes / 1024) + " KB");
}

if (failures) { console.error(failures + " failure(s)"); process.exit(1); }
console.log("BOOK SHAPE OK");
