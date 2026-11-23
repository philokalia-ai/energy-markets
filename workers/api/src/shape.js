/* Pure shapers: parquet row objects (hyparquet output) -> the exact JSON
 * shapes web/app.js consumes today (web/data/zones/<Z>.json, scoreboard.json,
 * map.json — see bin/export_forecast_json.jl for the authoritative contract).
 *
 * Runs in the Cloudflare Worker AND in node (test/shape.test.mjs), so no
 * Worker APIs here.
 */

const MARKET_DAY_TZ = "Europe/Athens";
// The two tracks of the global Predicted / As-announced lens (input_mode buckets:
// "weather*" -> predicted, everything else -> announced).
const TRACK_KEYS = ["predicted", "announced"];
export function trackOfInputMode(m) {
  return /^weather/.test(m || "") ? "predicted" : "announced";
}

/** BigInt/number -> number; null/undefined stay null. */
function num(v) {
  if (v === null || v === undefined) return null;
  return typeof v === "bigint" ? Number(v) : v;
}

/** Date | epoch-ms -> "YYYY-MM-DDTHH:MM:SSZ" (no milliseconds, like the Julia exporter). */
function iso(v) {
  if (v === null || v === undefined) return null;
  const d = v instanceof Date ? v : new Date(Number(v));
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Date (UTC midnight) | string -> "YYYY-MM-DD". */
function dateStr(v) {
  if (typeof v === "string") return v.slice(0, 10);
  const d = v instanceof Date ? v : new Date(Number(v));
  return d.toISOString().slice(0, 10);
}

/**
 * zones/<Z>.parquet rows -> {zone, market_day_tz, days:[...]}.
 * Rows are exported grouped by (market_date desc, lead asc, entsoe-first)
 * with hours ascending inside each group; grouping by first appearance
 * reproduces the JSON exporter's day order exactly.
 */
// TSFM overlay (bin/emit_tsfm_overlay.py → the additive zone-parquet columns):
// hourly series and per-zone-day scalars. Passed through only when the parquet
// carries the columns, so a parquet exported before the overlay existed yields
// exactly the old shape (backwards compatible: new optional fields only).
const TSFM_HOURLY = ["tsfm", "tsfm_q10", "tsfm_q90", "p_le0"];
const TSFM_DAY = ["p_any_le0", "tsfm_input_mode", "tsfm_issue_utc", "tsfm_arm"];
// Native 15-minute day scores (bin/score_forecasts.jl → additive zone-parquet /
// scoreboard columns): passed through only when the parquet carries them, so an
// older parquet yields exactly the old shape. Null for zone-days without native
// PT15M actuals — never a copy of the hourly score.
const Q15_DAY = ["n_q15", "mae_q15", "bias_q15", "corr_q15", "shape_floor_q15"];
// Per-day slot length (cv46 quarter-hour days): "resolution" 'PT60M' | 'PT15M' — `hours` holds the day's
// slot starts at that resolution (96 on a quarter-hour day) — and "actual_resolution" (native quarter
// actuals 'PT15M', or hourly 'PT60M', replicated onto the quarters when a quarter day has no native ones).
// Day-level values repeated on every row of the zone-day; passed through when the parquet carries them.
const RES_DAY = ["resolution", "actual_resolution"];
const Q15_BOARD = ["n_days_q15", "mae_q15", "bias_q15", "corr_q15", "shape_floor_q15"];
// Naive baselines + rMAE (#431, bin/naive_baselines.jl → additive scoreboard
// columns): passed through only when the parquet carries them. d1 / epf need
// D-1 prices, which exist at issue only for lead <= 1: at leads >= 2 those keys
// are ABSENT (as in the JSON exporter), not null.
const NAIVE_BOARD = ["n_naive", "mae_paired", "mae_naive_d7", "rmae_d7"];
const NAIVE_BOARD_LEAD1 = ["mae_naive_d1", "mae_naive_epf", "rmae_d1", "rmae_epf"];
// Timestral board fields (live lead-1 weather rows + the "backfilled" window, bin/tsfm_backfill_scores.jl
// TSFM_BACKFILL_BOARD_COLS). Passed through on the rows that carry them only.
const TSFM_BACKFILL_NUM = ["tsfm_n_days", "tsfm_n", "tsfm_mae", "tsfm_mae_naive_d1", "tsfm_mae_naive_d7",
  "tsfm_mae_naive_epf", "tsfm_rmae_d1", "tsfm_rmae_d7", "tsfm_rmae_epf", "tsfm_n_days_postsim"];
const has = (rows, k) => rows.length > 0 && Object.prototype.hasOwnProperty.call(rows[0], k);

export function shapeZone(rows, zone) {
  const days = [];
  const byKey = new Map();
  const hasTsfm = rows.length > 0 && Object.prototype.hasOwnProperty.call(rows[0], "tsfm");
  const hasQ15 = has(rows, "mae_q15");
  const hasRes = has(rows, "resolution");
  for (const r of rows) {
    const date = dateStr(r.market_date);
    const lead = num(r.lead_days);
    const mode = r.input_mode;
    const key = date + "|" + lead + "|" + mode;
    let day = byKey.get(key);
    if (!day) {
      day = {
        date: date,
        lead_days: lead,
        input_mode: mode,
        code_version: num(r.code_version),   // per-slice provenance — the same-cv pairing guard
        prediction_made_utc: iso(r.prediction_made_utc),
        hours: [],
        sim: [],
        actual: [],
        gbm: [],     // physics + ex-ante GBM overlay (null where absent)
        stats: [],   // pure-stats GBM overlay (null where absent)
        mae: num(r.mae),
        bias: num(r.bias),
        corr: num(r.corr),
      };
      if (hasTsfm) {
        for (const k of TSFM_HOURLY) day[k] = [];
        for (const k of TSFM_DAY) day[k] = null;
      }
      if (hasQ15) for (const k of Q15_DAY) day[k] = num(r[k]);
      if (hasRes) for (const k of RES_DAY) day[k] = r[k] ?? null;
      byKey.set(key, day);
      days.push(day);
    }
    day.hours.push(iso(r.date_time_utc));
    day.sim.push(num(r.sim));
    day.actual.push(num(r.actual));
    day.gbm.push(num(r.gbm));
    day.stats.push(num(r.stats));
    if (hasTsfm) {
      for (const k of TSFM_HOURLY) day[k].push(num(r[k]));
      // day-level scalars repeat on every row of the zone-day; first non-null wins
      if (day.p_any_le0 === null && r.p_any_le0 !== null && r.p_any_le0 !== undefined) {
        day.p_any_le0 = num(r.p_any_le0);
        day.tsfm_input_mode = r.tsfm_input_mode ?? null;
        day.tsfm_issue_utc = iso(r.tsfm_issue_utc);
        day.tsfm_arm = r.tsfm_arm ?? null;
      }
    }
  }
  // Defensive re-sort (same comparator as the exporter): newest date first,
  // then increasing lead, 'entsoe' before 'weather' within a lead.
  days.sort(function (a, b) {
    if (a.date !== b.date) return a.date < b.date ? 1 : -1;
    if (a.lead_days !== b.lead_days) return a.lead_days - b.lead_days;
    const ra = a.input_mode === "entsoe" ? 1 : 0;
    const rb = b.input_mode === "entsoe" ? 1 : 0;
    return rb - ra;
  });
  return { zone: zone, market_day_tz: MARKET_DAY_TZ, days: days };
}

/**
 * scoreboard.parquet rows + manifest -> scoreboard.json shape.
 * generated_utc is the data-plane freshness stamp (manifest.updated_at).
 */
export function shapeScoreboard(rows, manifest) {
  const hasQ15 = has(rows, "mae_q15");
  const hasNaive = has(rows, "n_naive");
  return {
    generated_utc: manifest.updated_at,
    code_version: manifest.code_version,
    market_day_tz: MARKET_DAY_TZ,
    zones: manifest.zones,
    scores: rows.map(function (r) {
      const out = {
        zone: r.zone,
        lead_days: num(r.lead_days),
        window: r.window,
        input_mode: r.input_mode,
        n_days: num(r.n_days),
        mae: num(r.mae),
        bias: num(r.bias),
        corr: num(r.corr),
        code_version: num(r.code_version),   // single-cv guard for the track-gap chip
      };
      if (hasQ15) for (const k of Q15_BOARD) out[k] = num(r[k]);
      // backfilled window (#431 R1): the reconstruction date, on those rows only
      if (r.reconstructed_utc !== undefined && r.reconstructed_utc !== null) out.reconstructed_utc = String(r.reconstructed_utc);
      // Timestral backfill fields (#431 R2): only where the row has them (other rows unchanged)
      if (r.tsfm_mae !== undefined && r.tsfm_mae !== null) {
        for (const k of TSFM_BACKFILL_NUM) out[k] = num(r[k]);
        if (r.tsfm_arm !== undefined && r.tsfm_arm !== null) out.tsfm_arm = String(r.tsfm_arm);
      }
      if (hasNaive) {
        for (const k of NAIVE_BOARD) out[k] = num(r[k]);
        if (out.lead_days <= 1) for (const k of NAIVE_BOARD_LEAD1) out[k] = num(r[k]);
      }
      return out;
    }),
  };
}

/**
 * books/<date>.parquet rows (ALL zones for one market day) + zone + date ->
 * the compact per-zone-day order-book ladder shape web/app.js renders.
 *
 * Each row is one tagged order: {market_date, zone, ts, side, price, mw,
 * owner, strategy?, code_version}. We keep only the requested zone, group by
 * delivery slot (ts: the hour, or the quarter on cv46 quarter-hour days), and emit the supply ladder ascending in price (the merit
 * order) and the demand ladder descending in price. Owners AND strategies are
 * de-duplicated into index tables so the long ENTSO-E unit codes / repeated
 * strategy labels are not repeated on every order (keeps the biggest zones —
 * FR/DE_LU — comfortably under 1 MB).
 *
 *   { zone, date, market_day_tz, code_version, has_strategy,
 *     owners:     ["RES", "IMPORT", "<unit>", …],
 *     strategies: ["res_forecast", "srmc_base", …],       // index table (see below)
 *     hours:  ["2023-01-01T00:00:00Z", …],                   // one ts per delivery slot (hour, or quarter on cv46 days)
 *     supply: [ [ [price, mw, ownerIdx, stratIdx], … ], … ], // per slot, price ascending
 *     demand: [ [ [price, mw, ownerIdx, stratIdx], … ], … ] }// per slot, price descending
 *
 * STRATEGY is the honest source-side "WHY" of each block, written by the Julia
 * book builder (STRATEGY_DESCRIPTIONS in src/merit_order/book_build.jl) into an
 * additive `strategy` parquet column. GRACEFUL DEGRADATION: parquets captured
 * BEFORE the column existed have no `r.strategy` — every order then maps to the
 * empty label and `has_strategy` is false, so the SPA hides the strategy/
 * explanation columns and shows a small note. The 4th tuple element is additive:
 * older SPA builds that read only o[0..2] are unaffected.
 *
 * The CLEARING price ("πού έκατσε η μπίλια") and the settled actual are NOT in
 * the book — the frontend overlays them from the zone forecast series
 * (zones/<Z>) by DELIVERY TIMESTAMP (hours here are UTC-day keyed while the
 * zone series is Athens-market-day keyed, so the same index is a different
 * hour), so this endpoint stays purely structural.
 */
export function shapeBook(rows, zone, date) {
  const owners = [];
  const ownerIdx = new Map();
  function oidx(o) {
    const key = o == null ? "" : o;
    let i = ownerIdx.get(key);
    if (i === undefined) { i = owners.length; owners.push(key); ownerIdx.set(key, i); }
    return i;
  }
  const strategies = [];
  const stratIdx = new Map();
  function sidx(s) {
    const key = s == null ? "" : String(s);
    let i = stratIdx.get(key);
    if (i === undefined) { i = strategies.length; strategies.push(key); stratIdx.set(key, i); }
    return i;
  }
  // Group by hour timestamp, preserving first-seen order (parquet is written
  // ORDER BY zone, ts, side, price so hours already arrive ascending).
  const byTs = new Map();
  let cv = null, hasStrategy = false;
  for (const r of rows) {
    if (r.zone !== zone) continue;
    if (cv === null) cv = num(r.code_version);
    if (r.strategy != null && r.strategy !== "") hasStrategy = true;
    const ts = iso(r.ts);
    let h = byTs.get(ts);
    if (!h) { h = { supply: [], demand: [] }; byTs.set(ts, h); }
    const order = [num(r.price), num(r.mw), oidx(r.owner), sidx(r.strategy)];
    (r.side === "supply" ? h.supply : h.demand).push(order);
  }
  const hours = Array.from(byTs.keys()).sort();
  // Deterministic order at EQUAL price: the parquet's ORDER BY (zone, ts,
  // side, price) leaves the tie order unspecified, so the €1 price-taking
  // IMPORT injection sometimes landed ABOVE the country's €1 RES block on the
  // supply ladder (and the cap-priced IMPORT export-demand above the
  // country's firm demand). Rank the domestic RES / DEMAND blocks first,
  // IMPORT after, everything else in between (the stable sort preserves
  // parquet order within a rank). Pure presentation — prices and quantities
  // are untouched, and equal-price order is economically meaningless.
  const TIE_RANK = { RES: 0, DEMAND: 0, IMPORT: 1 };
  function tieRank(o) {
    const r = TIE_RANK[owners[o[2]]];
    return r === undefined ? 0.5 : r;
  }
  const supply = [], demand = [];
  for (const ts of hours) {
    const h = byTs.get(ts);
    h.supply.sort(function (a, b) { return (a[0] - b[0]) || (tieRank(a) - tieRank(b)); });   // merit order
    h.demand.sort(function (a, b) { return (b[0] - a[0]) || (tieRank(a) - tieRank(b)); });   // willingness to pay
    supply.push(h.supply);
    demand.push(h.demand);
  }
  return {
    zone: zone, date: date, market_day_tz: MARKET_DAY_TZ, code_version: cv,
    has_strategy: hasStrategy, owners: owners, strategies: strategies,
    hours: hours, supply: supply, demand: demand,
  };
}

/**
 * inputs/<Z>.parquet rows -> the per-zone driver + prediction panel the
 * Predictions view renders (bin/export_prediction_inputs.jl is the contract).
 * Emits columnar series (hours ascending) so the SPA can draw small-multiple
 * driver charts aligned with the prediction and the settled actual:
 *
 *   { zone, market_day_tz, src:{solar,wind,load},
 *     hours: ["…Z", …],
 *     series: { vintage_lag, temp_c, ghi_wm2, cloud_pct, pressure_hpa,
 *               wind100_ms, pred_solar_mw, pred_wind_mw, pred_res_mw,
 *               pred_load_mw, ref_solar_mw, ref_wind_mw, ref_load_mw,
 *               act_solar_mw, act_wind_mw, act_load_mw } }
 */
const INPUT_SERIES_COLS = [
  "vintage_lag", "temp_c", "ghi_wm2", "cloud_pct", "pressure_hpa", "wind100_ms",
  "pred_solar_mw", "pred_wind_mw", "pred_res_mw", "pred_load_mw",
  "ref_solar_mw", "ref_wind_mw", "ref_load_mw",
  "act_solar_mw", "act_wind_mw", "act_load_mw",
];
export function shapeInputsZone(rows, zone) {
  const sorted = rows
    .filter(function (r) { return r.zone === zone; })
    .sort(function (a, b) { return Number(a.date_time_utc) - Number(b.date_time_utc); });
  const hours = [];
  const series = {};
  INPUT_SERIES_COLS.forEach(function (c) { series[c] = []; });
  for (const r of sorted) {
    hours.push(iso(r.date_time_utc));
    INPUT_SERIES_COLS.forEach(function (c) { series[c].push(num(r[c])); });
  }
  const src = sorted.length
    ? { solar: sorted[0].src_solar, wind: sorted[0].src_wind, load: sorted[0].src_load }
    : { solar: null, wind: null, load: null };
  return { zone: zone, market_day_tz: MARKET_DAY_TZ, src: src, hours: hours, series: series };
}

/**
 * inputs/reservoir.parquet rows -> { zones: { <Z>: [ {week_start, iso_year,
 * iso_week, stored_energy_mwh, fill_ratio, dryness}, … ] } }, weeks ascending.
 */
export function shapeReservoir(rows) {
  const zones = {};
  for (const r of rows) {
    const z = r.zone;
    if (!zones[z]) zones[z] = [];
    zones[z].push({
      week_start: dateStr(r.week_start),
      iso_year: num(r.iso_year),
      iso_week: num(r.iso_week),
      stored_energy_mwh: num(r.stored_energy_mwh),
      fill_ratio: num(r.fill_ratio),
      dryness: num(r.dryness),
    });
  }
  Object.keys(zones).forEach(function (z) {
    zones[z].sort(function (a, b) { return a.week_start < b.week_start ? -1 : a.week_start > b.week_start ? 1 : 0; });
  });
  return { market_day_tz: MARKET_DAY_TZ, zones: zones };
}

/**
 * units.parquet rows -> the static unit reference the Order-book view joins
 * client-side (bin/export_units_parquet.jl is the contract). One row per
 * (zone, code): {code, display_name, fuel, firm, zone}. Emitted as an object
 * keyed by unit code — the book's `owner` tag for a unit order — so the SPA
 * does an O(1) lookup per slice:
 *
 *   { market_day_tz, units: { "<code>": {name, fuel, firm, zone}, … } }
 *
 * `fuel` is the canonical ENTSO-E type string (post name-inference); the icon +
 * colour taxonomy lives in the SPA. `firm` is null when unknown/absent. If a
 * code somehow appears in two zones, the last row wins (codes are globally
 * unique EICs in practice, and the book is queried per zone anyway).
 */
export function shapeUnits(rows) {
  const units = {};
  for (const r of rows) {
    if (r.code == null) continue;
    units[r.code] = {
      name: r.display_name == null ? null : r.display_name,
      fuel: r.fuel == null ? null : r.fuel,
      firm: r.firm == null ? null : r.firm,
      zone: r.zone == null ? null : r.zone,
    };
  }
  return { market_day_tz: MARKET_DAY_TZ, units: units };
}

/**
 * flows/<date>.parquet rows -> the coupled cross-border flows the Order-book
 * TRADE WEDGE decomposes (bin/export_flows_parquet.jl is the contract). Each row
 * is one solved border-slot (an hour, or a quarter on cv46 quarter-hour days):
 * {date_time_utc, source_zone, sink_zone, flow_mw}. Grouped by delivery slot
 * (UTC ISO), each slot an array of compact [source, sink, mw] triples so the SPA
 * can, for a zone Z, sum the net flow per neighbour into Z at the shown slot:
 *
 *   { market_day_tz, flows: { "2026-07-27T16:00:00Z": [ ["BG","GR",1080.1], … ] } }
 *
 * ONLY record/backfill days persist transmission_flows (the daily forecast run
 * writes forecast_prices only), so this endpoint 404s on pure-forecast days and
 * the wedge falls back to its anonymous net brace — see the SPA.
 */
export function shapeFlows(rows) {
  const flows = {};
  for (const r of rows) {
    const ts = iso(r.date_time_utc);
    if (ts === null) continue;
    (flows[ts] || (flows[ts] = [])).push([r.source_zone, r.sink_zone, num(r.flow_mw)]);
  }
  return { market_day_tz: MARKET_DAY_TZ, flows: flows };
}

/**
 * map.parquet rows + manifest -> map.json shape (days sorted by date asc).
 *
 * Track-aware (the global Predicted / As-announced lens): each row carries a
 * `track` column ("predicted" | "announced"). Each day emits BOTH tracks under
 * `day.tracks = { predicted: {zone:{…}}, announced: {zone:{…}} }`, and keeps a
 * flat `day.zones` pointing at the PREDICTED track (default lens; the SPA repoints
 * it on a flip via applyMapTrack). Legacy single-track parquet (no `track` column)
 * degrades to the announced track only, exactly as before.
 */
export function shapeMap(rows, manifest) {
  const byDate = new Map();
  for (const r of rows) {
    const date = dateStr(r.market_date);
    const track = r.track === "predicted" ? "predicted" : "announced";
    let day = byDate.get(date);
    if (!day) {
      day = { date: date, zones: {}, tracks: { predicted: {}, announced: {} } };
      byDate.set(date, day);
    }
    day.tracks[track][r.zone] = {
      sim: num(r.sim),
      act: num(r.act),
      // load-weighted WAPE % (exporter-computed; null on parquets published
      // before the column existed — the SPA then shows its honest empty state)
      err_pct: num(r.err_pct),
      mae: num(r.mae),
      corr: num(r.corr),
      lead: num(r.lead),
      made: iso(r.made),
    };
  }
  const days = Array.from(byDate.values());
  // Flat day.zones = predicted where present, else announced (single-track/legacy).
  for (const day of days) {
    const hasPred = Object.keys(day.tracks.predicted).length > 0;
    day.zones = hasPred ? day.tracks.predicted : day.tracks.announced;
  }
  days.sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0; });
  return {
    generated_utc: manifest.updated_at,
    code_version: manifest.code_version,
    market_day_tz: MARKET_DAY_TZ,
    tracks: manifest.tracks || TRACK_KEYS,
    days: days,
  };
}
