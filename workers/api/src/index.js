/* euphemia-api — Cloudflare Worker serving the live forecast data plane.
 *
 * Reads zstd parquet objects from the R2 bucket `euphemia-web-data`
 * (written by bin/export_web_parquet.jl + bin/web_data_push.sh, seconds
 * after each pipeline DB write) and emits the exact JSON shapes web/app.js
 * consumes today:
 *
 *   GET /api/v1/zones/:zone   <- v1/zones/<zone>.parquet
 *   GET /api/v1/books/:zone/:date <- v1/books/<date>.parquet (filtered to zone)
 *   GET /api/v1/scoreboard    <- v1/scoreboard.parquet (+ manifest)
 *   GET /api/v1/map           <- v1/map.parquet        (+ manifest)
 *   GET /api/v1/units         <- v1/units.parquet (unit code -> name/fuel/firm)
 *   GET /api/v1/flows/:date   <- v1/flows/<date>.parquet (coupled trade wedge)
 *   GET /api/v1/manifest      <- v1/manifest.json (pass-through)
 *
 * Caching: edge Cache API keyed on the R2 object ETag — the parquet is
 * parsed at most once per object version per colo; clients get
 * ETag/If-None-Match 304s. CORS: energy.philokalia.ai + localhost dev.
 */

import { parquetReadObjects } from "hyparquet";
import { compressors } from "hyparquet-compressors";
import { shapeZone, shapeScoreboard, shapeMap, shapeBook, shapeInputsZone, shapeReservoir, shapeUnits, shapeFlows } from "./shape.js";

const ALLOWED_ORIGINS = [
  /^https:\/\/energy\.philokalia\.ai$/,
  /^https?:\/\/localhost(:\d+)?$/,
  /^https?:\/\/127\.0\.0\.1(:\d+)?$/,
];

function corsHeaders(request) {
  const origin = request.headers.get("Origin");
  const h = { "Vary": "Origin" };
  if (origin && ALLOWED_ORIGINS.some((re) => re.test(origin))) {
    h["Access-Control-Allow-Origin"] = origin;
    h["Access-Control-Allow-Methods"] = "GET, HEAD, OPTIONS";
    h["Access-Control-Allow-Headers"] = "If-None-Match, Content-Type";
    h["Access-Control-Max-Age"] = "86400";
  }
  return h;
}

function jsonResponse(body, status, extraHeaders) {
  return new Response(body, {
    status: status || 200,
    headers: Object.assign(
      { "Content-Type": "application/json; charset=utf-8" },
      extraHeaders || {}
    ),
  });
}

function errorResponse(request, status, message) {
  return jsonResponse(JSON.stringify({ error: message }), status, corsHeaders(request));
}

async function readParquet(r2obj) {
  const buf = await r2obj.arrayBuffer();
  return parquetReadObjects({ file: buf, compressors });
}

async function loadManifest(env) {
  const obj = await env.DATA.get("v1/manifest.json");
  if (!obj) return null;
  return JSON.parse(await obj.text());
}

/** Build the JSON payload for one route (cache-miss path). */
async function buildPayload(env, route, zone, date) {
  if (route === "manifest") {
    const obj = await env.DATA.get("v1/manifest.json");
    return obj ? await obj.text() : null;
  }
  if (route === "zone") {
    const obj = await env.DATA.get("v1/zones/" + zone + ".parquet");
    if (!obj) return null;
    return JSON.stringify(shapeZone(await readParquet(obj), zone));
  }
  if (route === "book") {
    // One per-day book parquet (all 39 zones) is synced into the web bucket
    // under v1/books/<date>.parquet by the daily web push (bin/daily_forecast.jl
    // writes data/web/v1/books/ -> bin/web_data_push.sh syncs it). Filter to
    // the requested zone and shape the ladder — no extra R2 binding needed.
    const obj = await env.DATA.get("v1/books/" + date + ".parquet");
    if (!obj) return null;
    return JSON.stringify(shapeBook(await readParquet(obj), zone, date));
  }
  if (route === "units") {
    // Static unit reference (code -> name/fuel/firm) for the Order-book view.
    // Pass-through parquet like the others; the SPA joins it client-side.
    const obj = await env.DATA.get("v1/units.parquet");
    if (!obj) return null;
    return JSON.stringify(shapeUnits(await readParquet(obj)));
  }
  if (route === "flows") {
    // Coupled cross-border flows for one market day (trade-wedge decomposition).
    // Only record/backfill days have a parquet; forecast days 404 (SPA falls
    // back to the anonymous net wedge).
    const obj = await env.DATA.get("v1/flows/" + date + ".parquet");
    if (!obj) return null;
    return JSON.stringify(shapeFlows(await readParquet(obj)));
  }
  if (route === "inputs_manifest") {
    // The Predictions-page data plane manifest (v1/inputs/manifest.json) —
    // pass-through, like v1/manifest.json (see bin/export_prediction_inputs.jl).
    const obj = await env.DATA.get("v1/inputs/manifest.json");
    return obj ? await obj.text() : null;
  }
  if (route === "inputs_reservoir") {
    const obj = await env.DATA.get("v1/inputs/reservoir.parquet");
    if (!obj) return null;
    return JSON.stringify(shapeReservoir(await readParquet(obj)));
  }
  if (route === "inputs_zone") {
    const obj = await env.DATA.get("v1/inputs/" + zone + ".parquet");
    if (!obj) return null;
    return JSON.stringify(shapeInputsZone(await readParquet(obj), zone));
  }
  const manifest = await loadManifest(env);
  if (!manifest) return null;
  if (route === "scoreboard") {
    const obj = await env.DATA.get("v1/scoreboard.parquet");
    if (!obj) return null;
    return JSON.stringify(shapeScoreboard(await readParquet(obj), manifest));
  }
  if (route === "map") {
    const obj = await env.DATA.get("v1/map.parquet");
    if (!obj) return null;
    return JSON.stringify(shapeMap(await readParquet(obj), manifest));
  }
  return null;
}

/** R2 key whose ETag versions the route's cache entry. */
function routeKey(route, zone, date) {
  if (route === "manifest") return "v1/manifest.json";
  if (route === "units") return "v1/units.parquet";
  if (route === "flows") return "v1/flows/" + date + ".parquet";
  if (route === "zone") return "v1/zones/" + zone + ".parquet";
  if (route === "book") return "v1/books/" + date + ".parquet";
  if (route === "inputs_manifest") return "v1/inputs/manifest.json";
  if (route === "inputs_reservoir") return "v1/inputs/reservoir.parquet";
  if (route === "inputs_zone") return "v1/inputs/" + zone + ".parquet";
  return "v1/" + route + ".parquet";
}

export default {
  async fetch(request, env, ctx) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return errorResponse(request, 405, "method not allowed");
    }

    const url = new URL(request.url);
    let route = null, zone = null, date = null;
    let m;
    if ((m = url.pathname.match(/^\/api\/v1\/zones\/([A-Za-z0-9_-]+)$/))) {
      route = "zone";
      zone = m[1];
    } else if ((m = url.pathname.match(/^\/api\/v1\/books\/([A-Za-z0-9_-]+)\/(\d{4}-\d{2}-\d{2})$/))) {
      route = "book";
      zone = m[1];
      date = m[2];
    } else if ((m = url.pathname.match(/^\/api\/v1\/flows\/(\d{4}-\d{2}-\d{2})$/))) {
      route = "flows";
      date = m[1];
    } else if (url.pathname === "/api/v1/scoreboard") {
      route = "scoreboard";
    } else if (url.pathname === "/api/v1/map") {
      route = "map";
    } else if (url.pathname === "/api/v1/manifest") {
      route = "manifest";
    } else if (url.pathname === "/api/v1/units") {
      route = "units";
    } else if (url.pathname === "/api/v1/inputs/manifest") {
      route = "inputs_manifest";
    } else if (url.pathname === "/api/v1/inputs/reservoir") {
      route = "inputs_reservoir";
    } else if ((m = url.pathname.match(/^\/api\/v1\/inputs\/([A-Za-z0-9_-]+)$/))) {
      // Predictions-page per-zone driver + prediction panel. The literal
      // /inputs/manifest and /inputs/reservoir are matched first above.
      route = "inputs_zone";
      zone = m[1];
    }
    if (!route) return errorResponse(request, 404, "not found");

    // Version the edge-cache entry on the R2 object's ETag: origin work
    // (R2 get + parquet decode + shaping) happens once per object version.
    const head = await env.DATA.head(routeKey(route, zone, date));
    if (!head) return errorResponse(request, 404, "no data for " + url.pathname);
    const etag = '"' + head.httpEtag.replace(/"/g, "") + '"';

    // Client conditional request -> 304 without touching the cache/origin.
    const inm = request.headers.get("If-None-Match");
    if (inm && inm.replace(/^W\//, "") === etag) {
      return new Response(null, {
        status: 304,
        headers: Object.assign({ "ETag": etag }, corsHeaders(request)),
      });
    }

    const cache = caches.default;
    const cacheKey = new Request(
      url.origin + url.pathname + "?etag=" + encodeURIComponent(etag),
      { method: "GET" }
    );
    let response = await cache.match(cacheKey);
    if (!response) {
      const body = await buildPayload(env, route, zone, date);
      if (body === null) return errorResponse(request, 404, "no data for " + url.pathname);
      response = jsonResponse(body, 200, {
        "ETag": etag,
        // Edge cache holds each version indefinitely (key includes the ETag);
        // browsers revalidate after 60 s so freshness follows the pipeline.
        "Cache-Control": "public, max-age=60",
      });
      ctx.waitUntil(cache.put(cacheKey, response.clone()));
    }

    // CORS is per-origin — apply outside the cached representation.
    const out = new Response(request.method === "HEAD" ? null : response.body, response);
    const cors = corsHeaders(request);
    for (const k in cors) out.headers.set(k, cors[k]);
    return out;
  },
};
