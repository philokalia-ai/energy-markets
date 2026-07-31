/* Pure shapers: parquet row objects (hyparquet output) -> the exact JSON
 * shapes web/app.js consumes today (web/data/zones/<Z>.json, scoreboard.json,
 * map.json — see bin/export_forecast_json.jl for the authoritative contract).
 *
 * Runs in the Cloudflare Worker AND in node (test/shape.test.mjs), so no
 * Worker APIs here.
 */

const MARKET_DAY_TZ = "Europe/Athens";

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
 * owner, code_version}. We keep only the requested zone, group by delivery
 * hour (ts), and emit the supply ladder ascending in price (the merit order)
 * and the demand ladder descending in price. Owners are de-duplicated into an
 * index table so the long ENTSO-E unit codes are not repeated on every order
 * (keeps the biggest zones — FR/DE_LU — comfortably under 1 MB).
 *
 *   { zone, date, market_day_tz, code_version,
 *     owners: ["RES", "IMPORT", "<unit>", …],
 *     hours:  ["2023-01-01T00:00:00Z", …],           // one ts per delivery hour
 *     supply: [ [ [price, mw, ownerIdx], … ], … ],    // per hour, price ascending
 *     demand: [ [ [price, mw, ownerIdx], … ], … ] }   // per hour, price descending
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
  // Group by hour timestamp, preserving first-seen order (parquet is written
  // ORDER BY zone, ts, side, price so hours already arrive ascending).
  const byTs = new Map();
  let cv = null;
  for (const r of rows) {
    if (r.zone !== zone) continue;
    if (cv === null) cv = num(r.code_version);
    const ts = iso(r.ts);
    let h = byTs.get(ts);
    if (!h) { h = { supply: [], demand: [] }; byTs.set(ts, h); }
    const order = [num(r.price), num(r.mw), oidx(r.owner)];
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
    owners: owners, hours: hours, supply: supply, demand: demand,
  };
}

/** map.parquet rows + manifest -> map.json shape (days sorted by date asc). */
export function shapeMap(rows, manifest) {
  const byDate = new Map();
  for (const r of rows) {
    const date = dateStr(r.market_date);
    let day = byDate.get(date);
    if (!day) {
      day = { date: date, zones: {} };
      byDate.set(date, day);
    }
    day.zones[r.zone] = {
      sim: num(r.sim),
      act: num(r.act),
      mae: num(r.mae),
      corr: num(r.corr),
      lead: num(r.lead),
      made: iso(r.made),
    };
  }
  const days = Array.from(byDate.values());
  days.sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0; });
  return {
    generated_utc: manifest.updated_at,
    code_version: manifest.code_version,
    market_day_tz: MARKET_DAY_TZ,
    days: days,
  };
}
