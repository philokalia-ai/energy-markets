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
export function shapeZone(rows, zone) {
  const days = [];
  const byKey = new Map();
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
        prediction_made_utc: iso(r.prediction_made_utc),
        hours: [],
        sim: [],
        actual: [],
        mae: num(r.mae),
        bias: num(r.bias),
        corr: num(r.corr),
      };
      byKey.set(key, day);
      days.push(day);
    }
    day.hours.push(iso(r.date_time_utc));
    day.sim.push(num(r.sim));
    day.actual.push(num(r.actual));
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
  return {
    generated_utc: manifest.updated_at,
    code_version: manifest.code_version,
    market_day_tz: MARKET_DAY_TZ,
    zones: manifest.zones,
    scores: rows.map(function (r) {
      return {
        zone: r.zone,
        lead_days: num(r.lead_days),
        window: r.window,
        input_mode: r.input_mode,
        n_days: num(r.n_days),
        mae: num(r.mae),
        bias: num(r.bias),
        corr: num(r.corr),
      };
    }),
  };
}

/**
 * books/<date>.parquet rows (ALL zones for one market day) + zone + date ->
 * the compact per-zone-day order-book ladder shape web/app.js renders.
 *
 * Each row is one tagged order: {market_date, zone, ts, side, price, mw,
 * owner, strategy?, code_version}. We keep only the requested zone, group by
 * delivery hour (ts), and emit the supply ladder ascending in price (the merit
 * order) and the demand ladder descending in price. Owners AND strategies are
 * de-duplicated into index tables so the long ENTSO-E unit codes / repeated
 * strategy labels are not repeated on every order (keeps the biggest zones —
 * FR/DE_LU — comfortably under 1 MB).
 *
 *   { zone, date, market_day_tz, code_version, has_strategy,
 *     owners:     ["RES", "IMPORT", "<unit>", …],
 *     strategies: ["res_forecast", "srmc_base", …],       // index table (see below)
 *     hours:  ["2023-01-01T00:00:00Z", …],                   // one ts per delivery hour
 *     supply: [ [ [price, mw, ownerIdx, stratIdx], … ], … ], // per hour, price ascending
 *     demand: [ [ [price, mw, ownerIdx, stratIdx], … ], … ] }// per hour, price descending
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
 * (zones/<Z>) by aligning hour index, so this endpoint stays purely structural.
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
  const supply = [], demand = [];
  for (const ts of hours) {
    const h = byTs.get(ts);
    h.supply.sort(function (a, b) { return a[0] - b[0]; });   // merit order
    h.demand.sort(function (a, b) { return b[0] - a[0]; });   // willingness to pay
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
 * is one solved border-hour: {date_time_utc, source_zone, sink_zone, flow_mw}.
 * Grouped by delivery hour (UTC ISO), each hour an array of compact
 * [source, sink, mw] triples so the SPA can, for a zone Z, sum the net flow per
 * neighbour into Z at the shown hour:
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
