/* Native 15-minute score passthrough (DB-free, in-memory rows):
 *  - zone parquet with the q15 columns -> day-level n_q15/mae_q15/bias_q15/corr_q15/shape_floor_q15;
 *    a PT60M zone-day keeps them null (never a copy of the hourly score);
 *  - scoreboard rows with the q15 columns -> per-score n_days_q15/mae_q15/...;
 *  - parquets WITHOUT the columns -> exactly the old shapes (no new keys).
 */
import assert from "node:assert/strict";
import { shapeZone, shapeScoreboard } from "../src/shape.js";

const base = (h, extra) => Object.assign({
  market_date: "2026-11-13", lead_days: 1n, input_mode: "weather", code_version: 44n,
  prediction_made_utc: new Date("2026-11-12T09:07:22Z"),
  date_time_utc: new Date(Date.UTC(2026, 10, 12, 22 + h)), sim: 100 + h, actual: 90 + h,
  gbm: null, stats: null, mae: 10, bias: 10, corr: 0.9,
}, extra);

const q = { n_q15: 96n, mae_q15: 11.5, bias_q15: 10, corr_q15: 0.85, shape_floor_q15: 3.2 };
const day = shapeZone([0, 1].map((h) => base(h, q)), "GR").days[0];
assert.equal(day.n_q15, 96);
assert.equal(day.mae_q15, 11.5);
assert.equal(day.shape_floor_q15, 3.2);
assert.equal(day.mae, 10);                                   // hourly score untouched

const pt60 = shapeZone([0, 1].map((h) => base(h, { n_q15: 0n, mae_q15: null, bias_q15: null,
  corr_q15: null, shape_floor_q15: null })), "CH").days[0];
assert.equal(pt60.n_q15, 0);
assert.equal(pt60.mae_q15, null);
assert.equal(pt60.mae, 10);

const legacy = shapeZone([0, 1].map((h) => base(h)), "GR").days[0];
for (const k of ["n_q15", "mae_q15", "bias_q15", "corr_q15", "shape_floor_q15"]) {
  assert.equal(Object.prototype.hasOwnProperty.call(legacy, k), false, k);
}

const manifest = { updated_at: "2026-11-15T07:00:00Z", code_version: 44, zones: ["GR", "CH"] };
const sbRow = { zone: "GR", lead_days: 1n, window: "all", input_mode: "weather", n_days: 60n,
  mae: 50, bias: -20, corr: 0.7, code_version: 44n };
const sb = shapeScoreboard([Object.assign({}, sbRow, { n_days_q15: 58n, mae_q15: 51, bias_q15: -20,
  corr_q15: 0.68, shape_floor_q15: 7.9 })], manifest).scores[0];
assert.equal(sb.n_days_q15, 58);
assert.equal(sb.mae_q15, 51);
assert.equal(sb.mae, 50);
const sbLegacy = shapeScoreboard([sbRow], manifest).scores[0];
assert.deepEqual(Object.keys(sbLegacy).sort(),
  ["bias", "code_version", "corr", "input_mode", "lead_days", "mae", "n_days", "window", "zone"]);
console.log("q15_scores: all assertions passed");
