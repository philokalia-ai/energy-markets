/* Quarter-hour days (cv46) in the zone shape (DB-free, in-memory rows):
 *  - a PT15M zone-day (96 parquet rows) -> one day with 96 slot stamps, per-slot sim/actual, the hourly
 *    overlays replicated onto the quarters of their hour, resolution/actual_resolution passed through;
 *  - a PT60M zone-day next to it (mixed history) -> 24 hourly stamps, resolution 'PT60M', values as before;
 *  - a quarter day without native quarter actuals -> actual_resolution 'PT60M' (hourly replicated);
 *  - parquets WITHOUT the columns -> exactly the old shape (no new keys).
 */
import assert from "node:assert/strict";
import { shapeZone } from "../src/shape.js";

const START = Date.UTC(2026, 11, 13, 23);   // market day 2026-12-14 (Athens, winter): 23:00 UTC on 12-13
const row = (date, i, stepMin, res, actRes, extra) => {
  const t = new Date(START + i * stepMin * 60000);
  const hourIdx = Math.floor((i * stepMin) / 60);
  return Object.assign({
    market_date: date, lead_days: 1n, input_mode: "weather", code_version: 46n,
    prediction_made_utc: new Date("2026-12-13T09:05:00Z"), date_time_utc: t,
    sim: 100 + i * 0.25, actual: 90 + i * 0.25,
    gbm: 200 + hourIdx, stats: 300 + hourIdx,          // hourly overlays: same value on the hour's quarters
    tsfm: 400 + hourIdx, tsfm_q10: 390 + hourIdx, tsfm_q90: 410 + hourIdx, p_le0: 0.01 * hourIdx,
    p_any_le0: 0.2, tsfm_input_mode: "weather", tsfm_issue_utc: new Date("2026-12-13T06:30:00Z"),
    tsfm_arm: "timestral-209m",
    mae: 10, bias: 1, corr: 0.9, n_q15: 96n, mae_q15: 11, bias_q15: 1, corr_q15: 0.88, shape_floor_q15: 3,
    resolution: res, actual_resolution: actRes,
  }, extra);
};

// mixed history: quarter day 12-14 (96 rows) + hourly day 12-13 (24 rows), exporter order (newest first)
const quarter = Array.from({ length: 96 }, (_, i) => row("2026-12-14", i, 15, "PT15M", "PT15M"));
const hourly = Array.from({ length: 24 }, (_, i) => Object.assign(row("2026-12-13", i, 60, "PT60M", "PT60M"),
  { date_time_utc: new Date(START - 86400000 + i * 3600000), code_version: 45n, n_q15: 96n }));
const z = shapeZone([...quarter, ...hourly], "DE_LU");
assert.equal(z.days.length, 2);
const [q, h] = z.days;

assert.equal(q.date, "2026-12-14");
assert.equal(q.resolution, "PT15M");
assert.equal(q.actual_resolution, "PT15M");
assert.equal(q.hours.length, 96);
assert.equal(q.hours[0], "2026-12-13T23:00:00Z");
assert.equal(q.hours[1], "2026-12-13T23:15:00Z");
assert.equal(q.hours[95], "2026-12-14T22:45:00Z");
for (const k of ["sim", "actual", "gbm", "stats", "tsfm", "tsfm_q10", "tsfm_q90", "p_le0"]) {
  assert.equal(q[k].length, 96, k);
}
assert.equal(q.sim[1], 100.25);                       // per slot
assert.equal(q.actual[95], 90 + 95 * 0.25);
for (let i = 0; i < 96; i++) {                         // overlays: a step over each hour's 4 quarters
  assert.equal(q.gbm[i], 200 + Math.floor(i / 4));
  assert.equal(q.tsfm[i], 400 + Math.floor(i / 4));
}
assert.equal(q.p_any_le0, 0.2);
assert.equal(q.mae, 10);
assert.equal(q.n_q15, 96);

assert.equal(h.date, "2026-12-13");
assert.equal(h.resolution, "PT60M");
assert.equal(h.actual_resolution, "PT60M");
assert.equal(h.hours.length, 24);
assert.equal(h.hours[0], "2026-12-12T23:00:00Z");
assert.equal(new Date(h.hours[1]) - new Date(h.hours[0]), 3600000);
assert.equal(h.code_version, 45);

// quarter day without native quarter actuals: hourly actual replicated, flagged
const repl = shapeZone(Array.from({ length: 96 }, (_, i) =>
  row("2026-12-14", i, 15, "PT15M", "PT60M", { actual: 90 + Math.floor(i / 4) })), "CH").days[0];
assert.equal(repl.actual_resolution, "PT60M");
assert.equal(repl.actual[0], repl.actual[3]);
assert.notEqual(repl.actual[3], repl.actual[4]);

// a parquet exported before the columns existed: the old shape, no new keys
const legacy = shapeZone(hourly.map((r) => {
  const o = Object.assign({}, r); delete o.resolution; delete o.actual_resolution; return o;
}), "DE_LU").days[0];
for (const k of ["resolution", "actual_resolution"]) {
  assert.equal(Object.prototype.hasOwnProperty.call(legacy, k), false, k);
}
console.log("quarter_days: OK");
