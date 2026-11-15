/* TSFM overlay passthrough in shapeZone (DB-free, in-memory rows):
 *  - new parquet columns -> tsfm/tsfm_q10/tsfm_q90/p_le0 hourly arrays + day scalars;
 *  - a parquet WITHOUT the columns -> exactly the old shape (no new keys).
 */
import assert from "node:assert/strict";
import { shapeZone } from "../src/shape.js";

const base = (h, extra) => Object.assign({
  market_date: "2026-11-15", lead_days: 1n, input_mode: "weather", code_version: 43n,
  prediction_made_utc: new Date("2026-11-14T09:13:05Z"),
  date_time_utc: new Date(Date.UTC(2026, 10, 14, 22 + h)), sim: 100 + h, actual: null,
  gbm: null, stats: null, mae: null, bias: null, corr: null,
}, extra);

// with overlay columns; the day scalars are null on the first row (first non-null wins)
const rows = [0, 1, 2].map((h) => base(h, {
  tsfm: 90 + h, tsfm_q10: 70 + h, tsfm_q90: 110 + h, p_le0: h === 2 ? null : 0.1 * h,
  p_any_le0: h === 0 ? null : 0.42, tsfm_input_mode: h === 0 ? null : "pregate0630",
  tsfm_issue_utc: h === 0 ? null : new Date("2026-11-14T06:30:00Z"), tsfm_arm: h === 0 ? null : "timestral-209m",
}));
const day = shapeZone(rows, "GR").days[0];
assert.deepEqual(day.tsfm, [90, 91, 92]);
assert.deepEqual(day.tsfm_q10, [70, 71, 72]);
assert.deepEqual(day.tsfm_q90, [110, 111, 112]);
assert.deepEqual(day.p_le0, [0, 0.1, null]);
assert.equal(day.p_any_le0, 0.42);
assert.equal(day.tsfm_input_mode, "pregate0630");
assert.equal(day.tsfm_issue_utc, "2026-11-14T06:30:00Z");
assert.equal(day.tsfm_arm, "timestral-209m");
assert.deepEqual(day.sim, [100, 101, 102]);              // existing fields untouched

// overlay columns present but all null (a day without an overlay) -> nulls, keys present
const empty = shapeZone([0, 1].map((h) => base(h, { tsfm: null, tsfm_q10: null, tsfm_q90: null, p_le0: null,
  p_any_le0: null, tsfm_input_mode: null, tsfm_issue_utc: null, tsfm_arm: null })), "GR").days[0];
assert.deepEqual(empty.tsfm, [null, null]);
assert.equal(empty.p_any_le0, null);

// legacy parquet (no overlay columns) -> exactly the old keys
const legacy = shapeZone([0, 1].map((h) => base(h)), "GR").days[0];
for (const k of ["tsfm", "tsfm_q10", "tsfm_q90", "p_le0", "p_any_le0", "tsfm_input_mode", "tsfm_issue_utc", "tsfm_arm"]) {
  assert.ok(!(k in legacy), "legacy shape must not grow " + k);
}
console.log("tsfm_overlay: OK");
