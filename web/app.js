/* Euphemia results browser — plain JS, no build step.
 * Data contract (two rungs, first that answers wins):
 *   1. live Worker API (issue #152): API_BASE/v1/{zones/<Z>,scoreboard,map}
 *      — R2-backed, fresh seconds after each pipeline run; ?live=0 disables,
 *      ?api=<base> overrides the origin. The SOLE live data plane (the
 *      committed ./data rung was retired July 2026 with the bot-commit path).
 *   2. ./fixtures/*.json (bundled snapshot — offline dev + last-resort).
 */
(function () {
  "use strict";

  var BASES = ["./fixtures"];
  var QUERY = new URLSearchParams(window.location.search);
  var API_BASE = QUERY.get("api") || "https://api.philokalia.ai/api";
  var LIVE = QUERY.get("live") !== "0";
  var SVGNS = "http://www.w3.org/2000/svg";

  var state = {
    scoreboard: null,
    source: null,          // "api" | "data" | "fixtures"
    manifest: null,        // /api/v1/manifest payload (freshness badge)
    fixture: false,
    zoneCache: {},         // zone -> zone file json
    bookCache: {},         // "zone|date" -> book ladder json
    units: null,           // code -> {name, fuel, firm, zone} (order-book join)
    flowsCache: {},        // date -> {tsIso: [[source,sink,mw],…]} | null (trade wedge)
    view: "horizon",       // "horizon" | "explorer" | "board" | "book"
    zone: "GR",
    day: null,             // "YYYY-MM-DD"
    revDay: null,          // "YYYY-MM-DD" selected in the revision panel
    bookDay: null,         // "YYYY-MM-DD" selected in the order-book view
    bookHour: 12,          // hour index selected in the order-book view
    window: "all",
    sort: { lead: null, metric: "mae", dir: 1 }, // dir 1 = best first
    hoverIdx: null,
  };

  // The site shows ONE forecast track: the ex-ante WEATHER track (all model
  // inputs, weather-based RES). The reference (entsoe) track is kept in the
  // data plane for research but hidden from the UI. Any input_mode starting
  // with "weather" (weather, weather+loadfill, …) is the ex-ante track.
  function isWeatherMode(m) { return /^weather/.test(m || ""); }

  // ---------- helpers ----------

  function $(id) { return document.getElementById(id); }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }

  function svgEl(tag, attrs) {
    var e = document.createElementNS(SVGNS, tag);
    if (attrs) for (var k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  }

  function fmt(v, digits) {
    if (v === null || v === undefined || isNaN(v)) return "—";
    return v.toLocaleString("en-GB", {
      minimumFractionDigits: digits, maximumFractionDigits: digits,
    });
  }

  function fetchJSON(path) {
    return fetch(path, { cache: "no-store" }).then(function (r) {
      if (!r.ok) throw new Error(path + " -> HTTP " + r.status);
      return r.json();
    });
  }

  // "zones/GR.json" -> API_BASE + "/v1/zones/GR" (endpoints carry no .json)
  function apiPath(rel) {
    return API_BASE + "/v1/" + rel.replace(/\.json$/, "");
  }

  // Fetch the freshness manifest once, after the first successful API load.
  var manifestRequested = false;
  function onApiSuccess() {
    if (manifestRequested) return;
    manifestRequested = true;
    fetchJSON(API_BASE + "/v1/manifest").then(function (m) {
      state.manifest = m;
      renderFooter();
    }, function () { /* badge is best-effort */ });
  }

  // Try the live Worker API first (unless ?live=0), then the bundled
  // ./fixtures snapshot — offline dev and last-resort when the API is down.
  function loadWithFallback(rel) {
    function staticChain() {
      return fetchJSON(BASES[0] + "/" + rel).then(function (j) {
        return { json: j, source: "fixtures" };
      });
    }
    if (!LIVE) return staticChain();
    return fetchJSON(apiPath(rel)).then(
      function (j) { onApiSuccess(); return { json: j, source: "api" }; },
      staticChain
    );
  }

  function dayLabel(dateStr) {
    var d = new Date(dateStr + "T00:00:00Z");
    var wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getUTCDay()];
    return wd + " " + dateStr;
  }

  // Hours are stored as UTC stamps of the Europe/Athens market-day window;
  // render them in Europe/Athens local time (00:00–23:00 across the day).
  var ATHENS_TIME = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Athens", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  });

  function hourLabel(iso) {
    // "2026-07-12T21:00:00Z" -> "00:00" (Athens local)
    return ATHENS_TIME.format(new Date(iso));
  }

  function hourEndLabel(iso) {
    // Athens-local label of the delivery hour's end (start + 1h).
    return ATHENS_TIME.format(new Date(new Date(iso).getTime() + 3600000));
  }

  function isPending(day) {
    return day.actual.every(function (a) { return a === null || a === undefined; });
  }

  function isPartial(day) {
    var n = day.actual.filter(function (a) { return a !== null && a !== undefined; }).length;
    return n > 0 && n < day.actual.length;
  }

  // ---------- hash routing ----------

  function readHash() {
    var h = window.location.hash.replace(/^#/, "");
    var params = {};
    h.split("&").forEach(function (kv) {
      var i = kv.indexOf("=");
      if (i > 0) params[decodeURIComponent(kv.slice(0, i))] = decodeURIComponent(kv.slice(i + 1));
    });
    if (["board", "explorer", "horizon", "map", "predict", "cases", "book"].indexOf(params.view) !== -1) state.view = params.view;
    if (params.zone) state.zone = params.zone;
    if (params.day && /^\d{4}-\d{2}-\d{2}$/.test(params.day)) state.day = params.day;
    if (params.rev && /^\d{4}-\d{2}-\d{2}$/.test(params.rev)) state.revDay = params.rev;
    if (params.bday && /^\d{4}-\d{2}-\d{2}$/.test(params.bday)) state.bookDay = params.bday;
    if (params.bhr && !isNaN(+params.bhr)) state.bookHour = +params.bhr;
    if (params.metric && ["sim", "act", "err"].indexOf(params.metric) !== -1) mapState.metric = params.metric;
    if (params.window) state.window = params.window;
  }

  var suppressHash = false;
  function writeHash() {
    var parts = ["view=" + state.view, "zone=" + encodeURIComponent(state.zone)];
    if (state.day) parts.push("day=" + state.day);
    if (state.revDay) parts.push("rev=" + state.revDay);
    if (state.view === "book") {
      if (state.bookDay) parts.push("bday=" + state.bookDay);
      parts.push("bhr=" + state.bookHour);
    }
    if (state.view === "map" && mapState.metric !== "sim") parts.push("metric=" + mapState.metric);
    if (state.window && state.window !== "all") parts.push("window=" + encodeURIComponent(state.window));
    suppressHash = true;
    window.location.hash = parts.join("&");
    // hashchange fires async; release the guard on next tick
    setTimeout(function () { suppressHash = false; }, 0);
  }

  // ---------- data access ----------

  function loadZone(zone) {
    if (state.zoneCache[zone]) return Promise.resolve(state.zoneCache[zone]);
    return loadWithFallback("zones/" + encodeURIComponent(zone) + ".json").then(function (res) {
      state.zoneCache[zone] = res.json;
      if (res.json && res.json.fixture) setFixtureBanner(true);
      return res.json;
    });
  }

  // Ex-ante weather-track entries only (the reference track is hidden from UI).
  function weatherDays(zoneData) {
    return zoneData.days.filter(function (d) { return isWeatherMode(dayInputMode(d)); });
  }

  // Collapse the lead/D-n dimension: the single freshest (lowest-lead) entry per
  // delivery date. Every forecast uses the latest admissible weather, so the
  // freshest lead is the best ex-ante estimate and deeper leads are noise.
  // Returns newest date first.
  function freshestByDate(days) {
    var byDate = {};
    days.forEach(function (d) {
      var cur = byDate[d.date];
      if (!cur || d.lead_days < cur.lead_days) byDate[d.date] = d;
    });
    return Object.keys(byDate).sort().reverse().map(function (k) { return byDate[k]; });
  }

  // ---------- fixture banner ----------

  function setFixtureBanner(on) {
    if (on) state.fixture = true;
    $("fixture-banner").hidden = !state.fixture;
  }

  // ---------- view switching ----------

  var VIEW_CRUMBS = {
    horizon: "recent days",
    map: "map",
    predict: "predicting RES & loads",
    explorer: "zone explorer",
    board: "scoreboard",
    book: "order book",
    cases: "case studies"
  };

  function setView(v) {
    state.view = v;
    $("view-explorer").hidden = v !== "explorer";
    $("view-board").hidden = v !== "board";
    $("view-horizon").hidden = v !== "horizon";
    $("view-map").hidden = v !== "map";
    $("view-predict").hidden = v !== "predict";
    $("view-book").hidden = v !== "book";
    $("view-cases").hidden = v !== "cases";
    var crumb = $("crumb-view");
    if (crumb) crumb.textContent = VIEW_CRUMBS[v] ? "/ " + VIEW_CRUMBS[v] : "";
    if (v === "map") loadMap().then(renderMap);
    if (v === "predict") loadPredict().then(renderPredict);
    if (v === "book") renderBook();
    document.querySelectorAll(".tab").forEach(function (t) {
      t.setAttribute("aria-selected", String(t.dataset.view === v));
    });
  }

  // ---------- explorer rendering ----------

  function renderZoneSelect() {
    var zones = state.scoreboard.zones.slice();
    // GR pinned first
    zones.sort(function (a, b) {
      if (a === "GR") return -1;
      if (b === "GR") return 1;
      return a < b ? -1 : a > b ? 1 : 0;
    });
    ["zone-select", "hzone-select", "bzone-select"].forEach(function (id) {
      var sel = $(id);
      if (!sel) return;
      sel.textContent = "";
      zones.forEach(function (z) {
        var o = el("option", null, z);
        o.value = z;
        sel.appendChild(o);
      });
      sel.value = state.zone;
    });
  }

  function dayInputMode(d) { return d.input_mode || "entsoe"; }

  function renderDayList(days) {
    var ul = $("day-list");
    ul.textContent = "";
    days.forEach(function (d) {
      var li = el("li");
      var b = el("button", "day-btn");
      b.type = "button";
      b.setAttribute("aria-pressed", String(d.date === state.day));
      b.appendChild(el("span", "d-date", dayLabel(d.date)));
      var badges = el("span", "d-badges");
      if (isPending(d)) {
        badges.appendChild(el("span", "pill pending", "pending"));
      } else {
        badges.appendChild(el("span", "pill", "MAE " + fmt(d.mae, 1)));
        badges.appendChild(el("span", "pill", "r " + fmt(d.corr, 2)));
      }
      b.appendChild(badges);
      b.addEventListener("click", function () {
        state.day = d.date;
        state.hoverIdx = null;
        renderExplorer();
        writeHash();
      });
      li.appendChild(b);
      ul.appendChild(li);
    });
  }

  function renderDayStats(day) {
    var row = $("day-stats");
    row.textContent = "";
    var defs = isPending(day)
      ? [["Status", "Pending", ""]]
      : [
          ["MAE", fmt(day.mae, 1), "€/MWh"],
          ["Bias (sim − actual)", (day.bias > 0 ? "+" : "") + fmt(day.bias, 1), "€/MWh"],
          ["Correlation", fmt(day.corr, 2), ""],
        ];
    defs.forEach(function (d) {
      var s = el("div", "stat");
      s.appendChild(el("span", "s-label", d[0]));
      var v = el("span", "s-value", d[1]);
      if (d[2]) v.appendChild(el("span", "s-unit", d[2]));
      s.appendChild(v);
      row.appendChild(s);
    });
  }

  function renderLegend(day) {
    var lg = $("chart-legend");
    lg.textContent = "";
    var items = [
      ["sim", "Simulated (ex-ante)"],
      ["act", isPending(day) ? "Actual (pending — not yet settled)" : "Actual (settled)"],
    ];
    var chips = {};
    items.forEach(function (it) {
      var span = el("span");
      var key = el("span", "key " + it[0]);
      key.setAttribute("aria-hidden", "true");
      span.appendChild(key);
      span.appendChild(document.createTextNode(it[1]));
      lg.appendChild(span);
      chips[it[0]] = span;
    });
    return chips;   // { sim, act } — wired to the chart series by renderExplorer
  }

  function renderHourTable(day) {
    var t = $("hour-table");
    t.textContent = "";
    var thead = el("thead");
    var tr = el("tr");
    ["Hour (Europe/Athens)", "Simulated €/MWh", "Actual €/MWh", "Error €/MWh"].forEach(function (h) {
      tr.appendChild(el("th", null, h));
    });
    thead.appendChild(tr);
    t.appendChild(thead);
    var tbody = el("tbody");
    day.hours.forEach(function (h, i) {
      var r = el("tr");
      r.appendChild(el("td", null, hourLabel(h)));
      r.appendChild(el("td", null, fmt(day.sim[i], 2)));
      var a = day.actual[i];
      var tdA = el("td", a === null || a === undefined ? "null" : null,
        a === null || a === undefined ? "pending" : fmt(a, 2));
      r.appendChild(tdA);
      var tdE = el("td", a === null || a === undefined ? "null" : null,
        a === null || a === undefined ? "—" : fmt(day.sim[i] - a, 2));
      r.appendChild(tdE);
      tbody.appendChild(r);
    });
    t.appendChild(tbody);
  }

  // ---------- SVG chart ----------

  function niceStep(range, maxTicks) {
    var raw = range / maxTicks;
    var pow = Math.pow(10, Math.floor(Math.log10(raw)));
    var steps = [1, 2, 2.5, 5, 10];
    for (var i = 0; i < steps.length; i++) {
      if (steps[i] * pow >= raw) return steps[i] * pow;
    }
    return 10 * pow;
  }

  function renderChart(day) {
    var wrap = $("chart-wrap");
    wrap.textContent = "";

    var VBW = 900, VBH = 380;
    var m = { t: 30, r: 16, b: 32, l: 54 };
    var pw = VBW - m.l - m.r, ph = VBH - m.t - m.b;

    var values = day.sim.slice();
    day.actual.forEach(function (a) { if (a !== null && a !== undefined) values.push(a); });
    var vMin = Math.min.apply(null, values), vMax = Math.max.apply(null, values);
    if (vMin > 0) vMin = 0;               // anchor at zero unless negative prices
    var pad = (vMax - vMin) * 0.06 || 10;
    vMax += pad;
    if (vMin < 0) vMin -= pad;
    var step = niceStep(vMax - vMin, 6);
    var y0 = Math.floor(vMin / step) * step;
    var y1 = Math.ceil(vMax / step) * step;

    var n = day.hours.length;
    function X(i) { return m.l + (n === 1 ? pw / 2 : (i / (n - 1)) * pw); }
    function Y(v) { return m.t + ph - ((v - y0) / (y1 - y0)) * ph; }

    var svg = svgEl("svg", {
      viewBox: "0 0 " + VBW + " " + VBH,
      role: "img",
      "aria-label": "Hourly simulated vs actual day-ahead prices for " + day.date,
    });

    // gridlines + y ticks (hairline, solid, recessive)
    var css = getComputedStyle(document.documentElement);
    var C = {
      grid: css.getPropertyValue("--grid").trim(),
      baseline: css.getPropertyValue("--baseline").trim(),
      muted: css.getPropertyValue("--text-muted").trim(),
      surface: css.getPropertyValue("--surface-1").trim(),
      sim: css.getPropertyValue("--series-sim").trim(),
      act: css.getPropertyValue("--series-act").trim(),
    };

    for (var v = y0; v <= y1 + 1e-9; v += step) {
      var yy = Y(v);
      var isZero = Math.abs(v) < 1e-9;
      svg.appendChild(svgEl("line", {
        x1: m.l, x2: m.l + pw, y1: yy, y2: yy,
        stroke: isZero ? C.baseline : C.grid, "stroke-width": 1,
        "shape-rendering": "crispEdges",
      }));
      var tick = svgEl("text", {
        x: m.l - 8, y: yy + 4, "text-anchor": "end",
        fill: C.muted, "font-size": 11.5,
        "font-variant-numeric": "tabular-nums",
      });
      tick.textContent = fmt(v, 0);
      svg.appendChild(tick);
    }
    // y-axis unit
    var unit = svgEl("text", {
      x: m.l - 8, y: m.t - 14, "text-anchor": "end", fill: C.muted, "font-size": 11,
    });
    unit.textContent = "€/MWh";
    svg.appendChild(unit);

    // x ticks every 3 hours
    for (var i = 0; i < n; i += 3) {
      var tx = svgEl("text", {
        x: X(i), y: m.t + ph + 20, "text-anchor": "middle",
        fill: C.muted, "font-size": 11.5,
        "font-variant-numeric": "tabular-nums",
      });
      tx.textContent = hourLabel(day.hours[i]);
      svg.appendChild(tx);
    }

    // series paths (2px, round join; actual path breaks at nulls)
    function pathFor(arr) {
      var dstr = "", pen = false;
      for (var i = 0; i < n; i++) {
        var v = arr[i];
        if (v === null || v === undefined) { pen = false; continue; }
        dstr += (pen ? " L" : " M") + X(i).toFixed(2) + " " + Y(v).toFixed(2);
        pen = true;
      }
      return dstr.trim();
    }
    var simEls = [], actEls = [];
    var simPath = svgEl("path", {
      d: pathFor(day.sim), fill: "none", stroke: C.sim,
      "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
    });
    svg.appendChild(simPath);
    simEls.push(simPath);
    var actD = pathFor(day.actual);
    if (actD) {
      var actPath = svgEl("path", {
        d: actD, fill: "none", stroke: C.act,
        "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
      });
      svg.appendChild(actPath);
      actEls.push(actPath);
      // lone realized points (no neighbors) would be invisible in a path
      for (var k = 0; k < n; k++) {
        var a = day.actual[k];
        if (a === null || a === undefined) continue;
        var prev = k > 0 ? day.actual[k - 1] : null;
        var next = k < n - 1 ? day.actual[k + 1] : null;
        if ((prev === null || prev === undefined) && (next === null || next === undefined)) {
          var loneDot = svgEl("circle", {
            cx: X(k), cy: Y(a), r: 4, fill: C.act, stroke: C.surface, "stroke-width": 2,
          });
          svg.appendChild(loneDot);
          actEls.push(loneDot);
        }
      }
    }

    // hover layer: crosshair + markers + tooltip
    var hoverLine = svgEl("line", {
      y1: m.t, y2: m.t + ph, stroke: C.baseline, "stroke-width": 1, visibility: "hidden",
    });
    svg.appendChild(hoverLine);
    var dotSim = svgEl("circle", { r: 4.5, fill: C.sim, stroke: C.surface, "stroke-width": 2, visibility: "hidden" });
    var dotAct = svgEl("circle", { r: 4.5, fill: C.act, stroke: C.surface, "stroke-width": 2, visibility: "hidden" });
    svg.appendChild(dotSim);
    svg.appendChild(dotAct);

    var overlay = svgEl("rect", {
      x: m.l, y: m.t, width: pw, height: ph, fill: "transparent",
      class: "hover-rect", tabindex: "0",
      "aria-label": "Chart values. Use left and right arrow keys to move between hours.",
    });
    svg.appendChild(overlay);

    var tooltip = el("div", "tooltip");
    tooltip.style.display = "none";
    wrap.appendChild(svg);
    wrap.appendChild(tooltip);

    function showIdx(idx) {
      idx = Math.max(0, Math.min(n - 1, idx));
      state.hoverIdx = idx;
      var x = X(idx);
      hoverLine.setAttribute("x1", x);
      hoverLine.setAttribute("x2", x);
      hoverLine.setAttribute("visibility", "visible");
      dotSim.setAttribute("cx", x);
      dotSim.setAttribute("cy", Y(day.sim[idx]));
      dotSim.setAttribute("visibility", "visible");
      var a = day.actual[idx];
      if (a !== null && a !== undefined) {
        dotAct.setAttribute("cx", x);
        dotAct.setAttribute("cy", Y(a));
        dotAct.setAttribute("visibility", "visible");
      } else {
        dotAct.setAttribute("visibility", "hidden");
      }

      // tooltip content (values lead, names follow; line keys; textContent only)
      tooltip.textContent = "";
      tooltip.appendChild(el("div", "tt-head",
        hourLabel(day.hours[idx]) + "–" + hourEndLabel(day.hours[idx]) + " Athens"));
      [
        [C.sim, day.sim[idx], "simulated"],
        [C.act, a, a === null || a === undefined ? "actual (pending)" : "actual"],
      ].forEach(function (rowDef) {
        var row = el("div", "tt-row");
        var key = el("span", "tt-key");
        key.style.borderTopColor = rowDef[0];
        row.appendChild(key);
        row.appendChild(el("span", "tt-val",
          rowDef[1] === null || rowDef[1] === undefined ? "—" : fmt(rowDef[1], 2)));
        row.appendChild(el("span", "tt-name", rowDef[2]));
        tooltip.appendChild(row);
      });

      // position: scale SVG coords to rendered px
      var rect = svg.getBoundingClientRect();
      var scale = rect.width / VBW;
      var px = x * scale;
      tooltip.style.display = "block";
      var tw = tooltip.offsetWidth;
      var left = px + 14;
      if (left + tw > rect.width - 4) left = px - tw - 14;
      tooltip.style.left = Math.max(0, left) + "px";
      tooltip.style.top = Math.max(0, Y(day.sim[idx]) * scale - 30) + "px";
    }

    function hideHover() {
      hoverLine.setAttribute("visibility", "hidden");
      dotSim.setAttribute("visibility", "hidden");
      dotAct.setAttribute("visibility", "hidden");
      tooltip.style.display = "none";
    }

    overlay.addEventListener("pointermove", function (ev) {
      var rect = svg.getBoundingClientRect();
      var xVB = (ev.clientX - rect.left) * (VBW / rect.width);
      var idx = Math.round(((xVB - m.l) / pw) * (n - 1));
      showIdx(idx);
    });
    overlay.addEventListener("pointerleave", hideHover);
    overlay.addEventListener("focus", function () {
      showIdx(state.hoverIdx === null ? 12 : state.hoverIdx);
    });
    overlay.addEventListener("blur", hideHover);
    overlay.addEventListener("keydown", function (ev) {
      if (ev.key === "ArrowLeft") { showIdx((state.hoverIdx === null ? 12 : state.hoverIdx) - 1); ev.preventDefault(); }
      if (ev.key === "ArrowRight") { showIdx((state.hoverIdx === null ? 12 : state.hoverIdx) + 1); ev.preventDefault(); }
    });

    if (isPending(day)) {
      wrap.appendChild(el("p", "pending-note",
        "Prediction only — actual prices for this day have not settled yet."));
    } else if (isPartial(day)) {
      wrap.appendChild(el("p", "pending-note",
        "Partially settled — remaining hours are still pending."));
    }
    return { sim: simEls, act: actEls };   // series refs for the focus wiring
  }

  function renderExplorer() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) return;

    // Leads collapsed to the freshest forecast per date; ex-ante weather track
    // only (directives 1 & 3). Newest day first.
    var days = freshestByDate(weatherDays(zoneData));
    if (!days.length) {
      $("day-list").textContent = "";
      $("chart-title").textContent = state.zone + " — ex-ante forecast pending";
      $("chart-sub").textContent = "";
      $("day-stats").textContent = "";
      $("day-comment").textContent = "";
      $("chart-legend").textContent = "";
      $("hour-table").textContent = "";
      var w = $("chart-wrap"); w.textContent = "";
      w.appendChild(el("p", "pending-note",
        "No ex-ante (weather-track) days for " + state.zone +
        " yet — the daily weather runs fill this in as they accumulate."));
      return;
    }
    var found = days.some(function (d) { return d.date === state.day; });
    if (!state.day || !found) { state.day = days[0].date; }

    renderDayList(days);
    var day = null;
    days.forEach(function (d) { if (!day && d.date === state.day) day = d; });

    $("chart-title").textContent = state.zone + " — " + dayLabel(day.date);
    var madeAt = day.prediction_made_utc
      ? " · prediction frozen " + day.prediction_made_utc.replace("T", " ").replace("Z", " UTC")
      : "";
    $("chart-sub").textContent =
      "Ex-ante (weather) forecast" +
      madeAt +
      " · hours shown in Europe/Athens (market day)";
    renderDayStats(day);
    renderDayComment(day);
    var legendChips = renderLegend(day);
    var chartEls = renderChart(day);
    // Shared series-focus: hover/click/isolate the sim & actual lines. The
    // actual series is only wired when it actually has drawn points.
    var explorerSeries = [{ key: "sim", chip: legendChips.sim, els: chartEls.sim, baseOpacity: 1 }];
    if (chartEls.act.length) {
      explorerSeries.push({ key: "act", chip: legendChips.act, els: chartEls.act, baseOpacity: 1 });
    }
    attachSeriesFocus($("chart-legend"), explorerSeries);
    renderHourTable(day);
  }

  // ---------- horizon (recent market days) + revision panel ----------

  function chartColors() {
    var css = getComputedStyle(document.documentElement);
    return {
      grid: css.getPropertyValue("--grid").trim(),
      baseline: css.getPropertyValue("--baseline").trim(),
      muted: css.getPropertyValue("--text-muted").trim(),
      surface: css.getPropertyValue("--surface-1").trim(),
      sim: css.getPropertyValue("--series-sim").trim(),
      act: css.getPropertyValue("--series-act").trim(),
    };
  }

  // Shared scaffold: gridlines, y ticks, unit label. Returns {svg, X, Y, m, pw, ph, n}.
  function chartScaffold(wrap, values, n, ariaLabel) {
    var VBW = 900, VBH = 380;
    var m = { t: 30, r: 16, b: 44, l: 54 };
    var pw = VBW - m.l - m.r, ph = VBH - m.t - m.b;
    var vMin = Math.min.apply(null, values), vMax = Math.max.apply(null, values);
    if (vMin > 0) vMin = 0;
    var pad = (vMax - vMin) * 0.06 || 10;
    vMax += pad;
    if (vMin < 0) vMin -= pad;
    var step = niceStep(vMax - vMin, 6);
    var y0 = Math.floor(vMin / step) * step;
    var y1 = Math.ceil(vMax / step) * step;
    function X(i) { return m.l + (n === 1 ? pw / 2 : (i / (n - 1)) * pw); }
    function Y(v) { return m.t + ph - ((v - y0) / (y1 - y0)) * ph; }
    var svg = svgEl("svg", { viewBox: "0 0 " + VBW + " " + VBH, role: "img", "aria-label": ariaLabel });
    var C = chartColors();
    for (var v = y0; v <= y1 + 1e-9; v += step) {
      var yy = Y(v);
      svg.appendChild(svgEl("line", {
        x1: m.l, x2: m.l + pw, y1: yy, y2: yy,
        stroke: Math.abs(v) < 1e-9 ? C.baseline : C.grid, "stroke-width": 1,
        "shape-rendering": "crispEdges",
      }));
      var tick = svgEl("text", {
        x: m.l - 8, y: yy + 4, "text-anchor": "end", fill: C.muted,
        "font-size": 11.5, "font-variant-numeric": "tabular-nums",
      });
      tick.textContent = fmt(v, 0);
      svg.appendChild(tick);
    }
    var unit = svgEl("text", { x: m.l - 8, y: m.t - 14, "text-anchor": "end", fill: C.muted, "font-size": 11 });
    unit.textContent = "€/MWh";
    svg.appendChild(unit);
    return { svg: svg, X: X, Y: Y, m: m, pw: pw, ph: ph, n: n, VBW: VBW, C: C };
  }

  function pathString(arr, X, Y) {
    var d = "", pen = false;
    for (var i = 0; i < arr.length; i++) {
      var v = arr[i];
      if (v === null || v === undefined) { pen = false; continue; }
      d += (pen ? " L" : " M") + X(i).toFixed(2) + " " + Y(v).toFixed(2);
      pen = true;
    }
    return d.trim();
  }

  // The recent-market-days window: the freshest ex-ante (weather-track)
  // forecast per delivery date, most recent N days (settled + upcoming), so the
  // view straddles today — D-2, D-1, D (today), D+1 — with actuals overlaid
  // where the day has settled. Leads collapsed (directive 1).
  var HORIZON_DAYS = 5;
  function horizonDays(zoneData) {
    var byDate = freshestByDate(weatherDays(zoneData));   // newest first
    return byDate.slice(0, HORIZON_DAYS).reverse();       // oldest -> newest for the timeline
  }

  function renderHorizon() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) return;
    var days = horizonDays(zoneData);
    $("hz-title").textContent = state.zone + " — the last " + (days.length || HORIZON_DAYS) + " market days";
    var wrap = $("hz-wrap");
    wrap.textContent = "";
    var lg = $("hz-legend");
    lg.textContent = "";

    if (!days.length) {
      $("hz-sub").textContent = "";
      wrap.appendChild(el("p", "pending-note",
        "No ex-ante (weather-track) forecast days for " + state.zone +
        " yet — this fills as the daily weather runs accumulate."));
      renderRevisions();
      return;
    }
    $("hz-sub").textContent =
      "Freshest ex-ante (weather) forecast per delivery day, with the settled " +
      "actual overlaid once the day clears · hours in Europe/Athens (market day)";

    // legend: forecast + actual
    var C = chartColors();
    [["sim", "Forecast (ex-ante)"], ["act", "Actual (settled)"]].forEach(function (it) {
      var span = el("span");
      var key = el("span", "key " + it[0]);
      key.setAttribute("aria-hidden", "true");
      span.appendChild(key);
      span.appendChild(document.createTextNode(it[1]));
      lg.appendChild(span);
    });

    // concatenated point list (forecast + actual per hour, per day)
    var pts = [];   // {iso, v, a, day}
    days.forEach(function (d) {
      d.hours.forEach(function (h, i) {
        pts.push({ iso: h, v: d.sim[i], a: d.actual[i], day: d });
      });
    });
    var n = pts.length;
    var vals = pts.map(function (p) { return p.v; });
    pts.forEach(function (p) { if (p.a !== null && p.a !== undefined) vals.push(p.a); });
    var sc = chartScaffold(wrap, vals, n,
      "Hourly ex-ante forecast vs actual for the last " + days.length + " market days, " + state.zone);
    var svg = sc.svg, X = sc.X, Y = sc.Y, m = sc.m;

    // day separators + weekday labels + per-day forecast & actual paths
    var idx0 = 0;
    days.forEach(function (d) {
      var idx1 = idx0 + d.hours.length - 1;
      if (idx0 > 0) {
        svg.appendChild(svgEl("line", {
          x1: X(idx0), x2: X(idx0), y1: m.t, y2: m.t + sc.ph,
          stroke: C.baseline, "stroke-width": 1, "stroke-dasharray": "3 4",
        }));
      }
      var lbl = svgEl("text", {
        x: (X(idx0) + X(idx1)) / 2, y: m.t + sc.ph + 18, "text-anchor": "middle",
        fill: C.muted, "font-size": 11.5,
      });
      lbl.textContent = dayLabel(d.date).slice(0, 3) + " " + d.date.slice(5);
      svg.appendChild(lbl);
      var status = svgEl("text", {
        x: (X(idx0) + X(idx1)) / 2, y: m.t + sc.ph + 32, "text-anchor": "middle",
        fill: C.muted, "font-size": 10,
        "font-style": isPending(d) ? "italic" : "normal",
      });
      status.textContent = isPending(d) ? "forecast" : "settled";
      svg.appendChild(status);

      var Xoff = function (i) { return X(idx0 + i); };
      // forecast line
      svg.appendChild(svgEl("path", {
        d: pathString(d.sim, Xoff, Y), fill: "none", stroke: C.sim,
        "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
      }));
      // actual line (breaks at nulls)
      var actD = pathString(d.actual, Xoff, Y);
      if (actD) {
        svg.appendChild(svgEl("path", {
          d: actD, fill: "none", stroke: C.act,
          "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
        }));
      }
      idx0 = idx1 + 1;
    });

    // hover
    var hoverLine = svgEl("line", { y1: m.t, y2: m.t + sc.ph, stroke: C.baseline, "stroke-width": 1, visibility: "hidden" });
    svg.appendChild(hoverLine);
    var dotS = svgEl("circle", { r: 4.5, fill: C.sim, stroke: C.surface, "stroke-width": 2, visibility: "hidden" });
    var dotA = svgEl("circle", { r: 4.5, fill: C.act, stroke: C.surface, "stroke-width": 2, visibility: "hidden" });
    svg.appendChild(dotS); svg.appendChild(dotA);
    var overlay = svgEl("rect", {
      x: m.l, y: m.t, width: sc.pw, height: sc.ph, fill: "transparent",
      class: "hover-rect", tabindex: "0", "aria-label": "Forecast and actual values across recent days.",
    });
    svg.appendChild(overlay);
    var tooltip = el("div", "tooltip");
    tooltip.style.display = "none";
    wrap.appendChild(svg);
    wrap.appendChild(tooltip);

    function show(i) {
      i = Math.max(0, Math.min(n - 1, i));
      var p = pts[i];
      var x = X(i);
      hoverLine.setAttribute("x1", x); hoverLine.setAttribute("x2", x);
      hoverLine.setAttribute("visibility", "visible");
      dotS.setAttribute("cx", x); dotS.setAttribute("cy", Y(p.v));
      dotS.setAttribute("visibility", "visible");
      if (p.a !== null && p.a !== undefined) {
        dotA.setAttribute("cx", x); dotA.setAttribute("cy", Y(p.a));
        dotA.setAttribute("visibility", "visible");
      } else {
        dotA.setAttribute("visibility", "hidden");
      }
      tooltip.textContent = "";
      tooltip.appendChild(el("div", "tt-head",
        dayLabel(p.day.date) + " · " + hourLabel(p.iso) + "–" + hourEndLabel(p.iso) + " Athens"));
      [[C.sim, p.v, "forecast"], [C.act, p.a, p.a === null || p.a === undefined ? "actual (pending)" : "actual"]]
        .forEach(function (rd) {
          var row = el("div", "tt-row");
          var key = el("span", "tt-key");
          key.style.borderTopColor = rd[0];
          row.appendChild(key);
          row.appendChild(el("span", "tt-val", rd[1] === null || rd[1] === undefined ? "—" : fmt(rd[1], 2)));
          row.appendChild(el("span", "tt-name", rd[2]));
          tooltip.appendChild(row);
        });
      var rect = svg.getBoundingClientRect();
      var scale = rect.width / sc.VBW;
      var px = x * scale;
      tooltip.style.display = "block";
      var tw = tooltip.offsetWidth;
      var left = px + 14;
      if (left + tw > rect.width - 4) left = px - tw - 14;
      tooltip.style.left = Math.max(0, left) + "px";
      tooltip.style.top = Math.max(0, Y(p.v) * scale - 30) + "px";
    }
    overlay.addEventListener("pointermove", function (ev) {
      var rect = svg.getBoundingClientRect();
      var xVB = (ev.clientX - rect.left) * (sc.VBW / rect.width);
      show(Math.round(((xVB - m.l) / sc.pw) * (n - 1)));
    });
    overlay.addEventListener("pointerleave", function () {
      hoverLine.setAttribute("visibility", "hidden");
      dotS.setAttribute("visibility", "hidden");
      dotA.setAttribute("visibility", "hidden");
      tooltip.style.display = "none";
    });

    renderRevisions();
  }

  // ---------- interactive series focus (shared component) ----------
  // Wire a chart's legend chips to their SVG series so the reader can:
  //   • hover a chip OR a line  -> highlight that series, dim the rest to 0.15
  //   • click a chip            -> toggle the series on/off (persists; greys chip)
  //   • double-click / ⌾ "only" -> isolate one series
  //   • "show all"              -> reset (appears once anything is hidden)
  // No deps, CSS transitions only. `series` = [{ key, chip, els:[svgEl…],
  // baseOpacity }]. Non-line charts (map) don't use it; multi-line charts do.
  var DIM_OPACITY = 0.15;
  function attachSeriesFocus(legendEl, series) {
    if (!series.length) return null;
    var off = {};        // key -> true when toggled off
    var hover = null;    // key currently hovered (via chip or line)

    var resetBtn = el("button", "series-reset", "show all");
    resetBtn.type = "button";
    resetBtn.hidden = true;
    resetBtn.addEventListener("click", function () { off = {}; hover = null; apply(); });
    legendEl.appendChild(resetBtn);

    function apply() {
      var anyOff = false;
      series.forEach(function (s) {
        var isOff = !!off[s.key];
        if (isOff) anyOff = true;
        var op = isOff ? 0
          : hover === null ? s.baseOpacity
          : hover === s.key ? 1
          : DIM_OPACITY;
        s.els.forEach(function (e) {
          e.style.transition = "opacity .16s ease";
          e.style.opacity = op;
          e.style.pointerEvents = isOff ? "none" : "";
        });
        if (s.chip) {
          s.chip.classList.toggle("series-off", isOff);
          s.chip.classList.toggle("series-hi", hover === s.key && !isOff);
        }
      });
      resetBtn.hidden = !anyOff;
    }
    function isolate(key) {
      series.forEach(function (s) { off[s.key] = s.key !== key; });
      hover = null; apply();
    }

    series.forEach(function (s) {
      if (s.chip) {
        s.chip.classList.add("series-chip");
        s.chip.setAttribute("role", "button");
        s.chip.setAttribute("tabindex", "0");
        s.chip.setAttribute("aria-pressed", "false");
        // "only" affordance (double-click also isolates)
        var only = el("span", "series-only", "⌾ only");
        s.chip.appendChild(only);
        only.addEventListener("click", function (ev) { ev.stopPropagation(); isolate(s.key); });

        var clickTimer = null;
        s.chip.addEventListener("mouseenter", function () { hover = s.key; apply(); });
        s.chip.addEventListener("mouseleave", function () { hover = null; apply(); });
        s.chip.addEventListener("click", function () {
          if (clickTimer) return;             // a dblclick is in progress
          clickTimer = setTimeout(function () {
            clickTimer = null;
            off[s.key] = !off[s.key];
            s.chip.setAttribute("aria-pressed", String(!!off[s.key]));
            apply();
          }, 180);
        });
        s.chip.addEventListener("dblclick", function () {
          if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
          isolate(s.key);
        });
        s.chip.addEventListener("keydown", function (ev) {
          if (ev.key === "Enter" || ev.key === " ") {
            ev.preventDefault(); off[s.key] = !off[s.key];
            s.chip.setAttribute("aria-pressed", String(!!off[s.key])); apply();
          } else if (ev.key === "o" || ev.key === "O") {
            ev.preventDefault(); isolate(s.key);
          }
        });
      }
      // hovering the line itself highlights the series (charts without a
      // full-plot overlay — e.g. the vintage chart — get this for free)
      s.els.forEach(function (e) {
        if (e.tagName && e.tagName.toLowerCase() === "path") {
          e.style.pointerEvents = "stroke";
          e.style.cursor = "pointer";
          e.addEventListener("pointerenter", function () { hover = s.key; apply(); });
          e.addEventListener("pointerleave", function () { hover = null; apply(); });
        }
      });
    });

    apply();
    return { showAll: function () { off = {}; hover = null; apply(); } };
  }

  // Count of settled (non-null) actual points in a day entry.
  function settledCount(d) {
    return d.actual.filter(function (a) { return a !== null && a !== undefined; }).length;
  }

  // "What we said, when" — the freshest ex-ante (weather) forecast we published
  // for one delivery day, plus the settled actual. Reduced (directive 2) from
  // the old multi-vintage overlay: every forecast uses the latest admissible
  // weather, so the freshest prediction is the one that matters.
  function renderRevisions() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) return;
    var byDate = {};
    freshestByDate(weatherDays(zoneData)).forEach(function (d) { byDate[d.date] = d; });
    // newest 14 delivery days that have an ex-ante forecast
    var dates = Object.keys(byDate).sort().slice(-14);
    var wrap = $("rev-wrap");
    var lg = $("rev-legend");
    var btns = $("rev-daybtns");
    wrap.textContent = ""; lg.textContent = ""; btns.textContent = "";
    if (!dates.length) {
      $("rev-title").textContent = "What we said, when";
      wrap.appendChild(el("p", "pending-note",
        "No ex-ante (weather-track) forecast days for " + state.zone + " yet."));
      return;
    }
    if (!state.revDay || dates.indexOf(state.revDay) === -1) {
      state.revDay = dates[dates.length - 1];
    }
    dates.forEach(function (dd) {
      var b = el("button", null, dd.slice(5));
      b.type = "button";
      b.title = dayLabel(dd);
      b.setAttribute("aria-pressed", String(dd === state.revDay));
      b.addEventListener("click", function () {
        state.revDay = dd;
        renderRevisions();
        writeHash();
      });
      btns.appendChild(b);
    });

    var d = byDate[state.revDay];
    var hasActual = settledCount(d) > 0;
    $("rev-title").textContent = "What we said, when — " + state.zone + " · " + dayLabel(state.revDay);

    var C = chartColors();
    var vals = d.sim.slice();
    if (hasActual) d.actual.forEach(function (a) { if (a !== null && a !== undefined) vals.push(a); });
    var n = d.hours.length;
    var sc = chartScaffold(wrap, vals, n, "Ex-ante forecast vs actual for " + state.revDay + ", " + state.zone);
    var svg = sc.svg, X = sc.X, Y = sc.Y;

    for (var i = 0; i < n; i += 3) {
      var tx = svgEl("text", {
        x: X(i), y: sc.m.t + sc.ph + 20, "text-anchor": "middle",
        fill: sc.C.muted, "font-size": 11.5, "font-variant-numeric": "tabular-nums",
      });
      tx.textContent = hourLabel(d.hours[i]);
      svg.appendChild(tx);
    }

    var focusSeries = [];
    // forecast line
    var simPath = svgEl("path", {
      d: pathString(d.sim, X, Y), fill: "none", stroke: sc.C.sim,
      "stroke-width": 2.4, "stroke-linejoin": "round", "stroke-linecap": "round",
    });
    svg.appendChild(simPath);
    var simChip = el("span");
    simChip.appendChild(el("span", "key sim"));
    simChip.appendChild(document.createTextNode("Forecast (ex-ante)"));
    simChip.title = "Ex-ante (weather) forecast · input_mode: " + dayInputMode(d) +
      (d.prediction_made_utc
        ? "  ·  frozen " + d.prediction_made_utc.replace("T", " ").replace("Z", " UTC")
        : "");
    lg.appendChild(simChip);
    focusSeries.push({ key: "sim", chip: simChip, els: [simPath], baseOpacity: 1 });

    if (hasActual) {
      var actPath = svgEl("path", {
        d: pathString(d.actual, X, Y), fill: "none", stroke: sc.C.act,
        "stroke-width": 2.4, "stroke-linejoin": "round", "stroke-linecap": "round",
      });
      svg.appendChild(actPath);
      var actEls = [actPath];
      for (var k = 0; k < n; k++) {
        var av = d.actual[k];
        if (av === null || av === undefined) continue;
        var pv = k > 0 ? d.actual[k - 1] : null;
        var nv = k < n - 1 ? d.actual[k + 1] : null;
        if ((pv === null || pv === undefined) && (nv === null || nv === undefined)) {
          svg.appendChild(svgEl("circle", {
            cx: X(k), cy: Y(av), r: 4, fill: sc.C.act, stroke: sc.C.surface, "stroke-width": 2,
          }));
        }
      }
      var actChip = el("span");
      actChip.appendChild(el("span", "key act"));
      var partial = settledCount(d) < n;
      actChip.appendChild(document.createTextNode(partial ? "Actual (settling)" : "Actual (settled)"));
      actChip.title = "Actual settled price" + (partial
        ? " (" + settledCount(d) + "/" + n + " hours settled so far)" : "");
      lg.appendChild(actChip);
      focusSeries.push({ key: "act", chip: actChip, els: actEls, baseOpacity: 1 });
    } else {
      wrap.appendChild(el("p", "pending-note",
        "This delivery day has not settled yet — the actual appears once it clears."));
    }

    wrap.appendChild(svg);
    attachSeriesFocus(lg, focusSeries);
  }

  // ---------- map view (bidding-zone polygons) ----------
  // Boundaries: web/geo/zones.geojson — adapted from the Electricity Maps
  // contrib project (AGPL-3.0), IT-Calabria split + simplification ours.

  var mapState = { data: null, geo: null, dayIdx: null, metric: "sim" };

  var MAP_METRICS = [
    ["sim", "Forecast"],
    ["act", "Actual (settled)"],
    ["err", "Error (fc − act)"],
  ];

  function loadMap() {
    var pData = mapState.data ? Promise.resolve(mapState.data) :
      loadWithFallback("map.json").then(function (res) {
        mapState.data = res.json;
        if (res.json && res.json.fixture) setFixtureBanner(true);
        return res.json;
      });
    var pGeo = mapState.geo ? Promise.resolve(mapState.geo) :
      fetchJSON("./geo/zones.geojson").then(function (g) {
        mapState.geo = g;
        return g;
      });
    return Promise.all([pData, pGeo]);
  }

  // color ramps (low -> high); diverging ramp for error
  var RAMP_SEQ = ["#2C6BA8", "#7FA8CB", "#EAE2CF", "#DA9A6B", "#C4643C", "#8E2F1C"];
  var RAMP_DIV = ["#16375F", "#2C6BA8", "#EAE2CF", "#C4643C", "#8E2F1C"];

  function hex2rgb(h) {
    return [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
  }
  function rampColor(ramp, t) {
    t = Math.max(0, Math.min(1, t));
    var seg = t * (ramp.length - 1);
    var i = Math.min(ramp.length - 2, Math.floor(seg));
    var f = seg - i;
    var a = hex2rgb(ramp[i]), b = hex2rgb(ramp[i + 1]);
    return "rgb(" + Math.round(a[0] + (b[0] - a[0]) * f) + "," +
      Math.round(a[1] + (b[1] - a[1]) * f) + "," + Math.round(a[2] + (b[2] - a[2]) * f) + ")";
  }
  function rampCss(ramp) {
    return "linear-gradient(90deg, " + ramp.join(", ") + ")";
  }
  function quantile(sorted, q) {
    if (!sorted.length) return 0;
    var pos = (sorted.length - 1) * q;
    var lo = Math.floor(pos), hi = Math.ceil(pos);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }

  function mapValue(z, metric) {
    if (!z) return null;
    if (metric === "sim") return z.sim;
    if (metric === "act") return z.act;
    if (z.act === null || z.act === undefined) return null;
    return z.sim - z.act;
  }

  function metricDomain(metric) {
    var vals = [];
    mapState.data.days.forEach(function (d) {
      Object.keys(d.zones).forEach(function (zn) {
        var v = mapValue(d.zones[zn], metric);
        if (v !== null && v !== undefined) vals.push(v);
      });
    });
    vals.sort(function (a, b) { return a - b; });
    if (metric === "err") {
      var m = Math.max(Math.abs(quantile(vals, 0.05)), Math.abs(quantile(vals, 0.95)), 5);
      return [-m, m];
    }
    return [Math.min(0, quantile(vals, 0.02)), Math.max(quantile(vals, 0.98), 10)];
  }

  function renderMapMetricButtons() {
    var box = $("map-metric");
    box.textContent = "";
    MAP_METRICS.forEach(function (m) {
      var b = el("button", null, m[1]);
      b.type = "button";
      b.setAttribute("aria-pressed", String(mapState.metric === m[0]));
      b.addEventListener("click", function () {
        mapState.metric = m[0];
        renderMap();
        writeHash();
      });
      box.appendChild(b);
    });
  }

  function buildMapComment(day) {
    var zones = Object.keys(day.zones);
    var scored = zones.filter(function (z) {
      return day.zones[z].corr !== null && day.zones[z].corr !== undefined;
    });
    if (!scored.length) {
      var bySim = zones.slice().sort(function (a, b) { return day.zones[b].sim - day.zones[a].sim; });
      var hi = bySim[0], lo = bySim[bySim.length - 1];
      return "Forecast day — actuals settle after delivery. The model sees the priciest power in " +
        hi + " (€" + fmt(day.zones[hi].sim, 0) + "/MWh on average) and the cheapest in " +
        lo + " (€" + fmt(day.zones[lo].sim, 0) + "), a spread of €" +
        fmt(day.zones[hi].sim - day.zones[lo].sim, 0) + " across the footprint.";
    }
    var corrs = scored.map(function (z) { return day.zones[z].corr; }).sort(function (a, b) { return a - b; });
    var med = quantile(corrs, 0.5);
    var best = scored.reduce(function (a, z) { return day.zones[z].corr > day.zones[a].corr ? z : a; });
    var worst = scored.reduce(function (a, z) { return day.zones[z].corr < day.zones[a].corr ? z : a; });
    var good = scored.filter(function (z) { return day.zones[z].corr >= 0.75; }).length;
    var errs = scored
      .filter(function (z) { return day.zones[z].act !== null && day.zones[z].act !== undefined; })
      .map(function (z) { return day.zones[z].sim - day.zones[z].act; });
    var meanErr = errs.length ? errs.reduce(function (a, b) { return a + b; }, 0) / errs.length : 0;
    var lvl = med >= 0.85 ? "a strong day for the model" :
              med >= 0.7 ? "a good day for the model" :
              med >= 0.5 ? "a mixed day" : "a hard day";
    var s = "Settled — " + lvl + ": median hourly correlation " + fmt(med, 2) +
      " across " + scored.length + " zones (" + good + " above 0.75). Best: " + best +
      " (" + fmt(day.zones[best].corr, 2) + "); hardest: " + worst +
      " (" + fmt(day.zones[worst].corr, 2) + ").";
    if (Math.abs(meanErr) >= 5) {
      s += " On price levels the model read €" + fmt(Math.abs(meanErr), 0) + "/MWh " +
        (meanErr > 0 ? "high" : "low") + " on average" +
        (meanErr < 0 ? " — for a competitive counterfactual, under-pricing is signal, not noise." : ".");
    }
    return s;
  }

  // Equirectangular projection over the footprint bounds, lon scaled by cos 52°.
  var MAP_B = { minLon: -10.2, maxLon: 32.2, minLat: 34.4, maxLat: 71.6 };
  var MAP_K = Math.cos(52 * Math.PI / 180);
  var MAP_VBW = 900;
  var MAP_S = MAP_VBW / ((MAP_B.maxLon - MAP_B.minLon) * MAP_K);
  var MAP_VBH = Math.round((MAP_B.maxLat - MAP_B.minLat) * MAP_S);
  function mapX(lon) { return (lon - MAP_B.minLon) * MAP_K * MAP_S; }
  function mapY(lat) { return (MAP_B.maxLat - lat) * MAP_S; }

  function geoPath(geom) {
    var d = "";
    function ring(r) {
      for (var i = 0; i < r.length; i++) {
        d += (i === 0 ? "M" : "L") + mapX(r[i][0]).toFixed(1) + " " + mapY(r[i][1]).toFixed(1);
      }
      d += "Z";
    }
    var polys = geom.type === "Polygon" ? [geom.coordinates] : geom.coordinates;
    polys.forEach(function (p) { p.forEach(ring); });
    return d;
  }

  function renderMap() {
    if (!mapState.data || !mapState.data.days || !mapState.data.days.length || !mapState.geo) {
      $("map-title").textContent = "No map data yet";
      $("map-comment").textContent = "Map data arrives with the next forecast run.";
      return;
    }
    var days = mapState.data.days;
    if (mapState.dayIdx === null || mapState.dayIdx >= days.length) mapState.dayIdx = days.length - 1;
    var day = days[mapState.dayIdx];
    var metric = mapState.metric;

    var slider = $("map-day-slider");
    slider.max = days.length - 1;
    slider.value = mapState.dayIdx;
    $("map-day-label").textContent = dayLabel(day.date);
    renderMapMetricButtons();

    var mDef = MAP_METRICS.filter(function (m) { return m[0] === metric; })[0];
    $("map-title").textContent = mDef[1] + " — " + dayLabel(day.date) + " (€/MWh, day average)";

    var dom = metricDomain(metric);
    var ramp = metric === "err" ? RAMP_DIV : RAMP_SEQ;
    $("map-legend-lo").textContent = "€" + fmt(dom[0], 0);
    $("map-legend-hi").textContent = "€" + fmt(dom[1], 0) + (metric === "err" ? "" : "+");
    $("map-legend-bar").style.backgroundImage = rampCss(ramp);

    var wrap = $("map-wrap");
    wrap.textContent = "";
    var svg = svgEl("svg", { viewBox: "0 0 " + MAP_VBW + " " + MAP_VBH, role: "img",
      "aria-label": "Map of day-ahead prices by bidding zone" });
    var css = getComputedStyle(document.documentElement);
    var C = { muted: css.getPropertyValue("--text-muted").trim(),
              page: css.getPropertyValue("--page").trim() };

    var tooltip = el("div", "tooltip");
    tooltip.style.display = "none";
    wrap.appendChild(svg);
    wrap.appendChild(tooltip);

    var labels = [];   // draw after all shapes so they sit on top
    mapState.geo.features.forEach(function (f) {
      var zn = f.properties.zone;
      var z = day.zones[zn];
      var v = mapValue(z, metric);
      var has = v !== null && v !== undefined;
      var t = has ? (v - dom[0]) / (dom[1] - dom[0]) : 0;

      var path = svgEl("path", {
        d: geoPath(f.geometry),
        class: "map-poly",
        fill: has ? rampColor(ramp, t) : "rgba(128,128,128,0.12)",
        stroke: C.page, "stroke-width": 1.1, "stroke-linejoin": "round",
        tabindex: "0", role: "button",
        "aria-label": zn + (has ? ": " + fmt(v, 1) + " €/MWh" : ": no data"),
      });

      var lx = mapX(f.properties.lx), ly = mapY(f.properties.ly);
      function showTip() {
        tooltip.textContent = "";
        tooltip.appendChild(el("div", "tt-head", zn + " · " + dayLabel(day.date) +
          (z && z.lead ? " · D-" + z.lead : "")));
        var rows = [];
        if (z) {
          rows.push(["forecast", z.sim]);
          rows.push(["actual", z.act]);
          if (z.act !== null && z.act !== undefined) rows.push(["error", z.sim - z.act]);
          if (z.mae !== null && z.mae !== undefined) rows.push(["MAE", z.mae]);
          if (z.corr !== null && z.corr !== undefined) rows.push(["corr", z.corr]);
        }
        rows.forEach(function (r) {
          var row = el("div", "tt-row");
          row.appendChild(el("span", "tt-val",
            r[1] === null || r[1] === undefined ? "—" : fmt(r[1], r[0] === "corr" ? 2 : 1)));
          row.appendChild(el("span", "tt-name", r[0]));
          tooltip.appendChild(row);
        });
        var rect = svg.getBoundingClientRect();
        var scale = rect.width / MAP_VBW;
        tooltip.style.display = "block";
        var left = (lx + 12) * scale;
        if (left + tooltip.offsetWidth > rect.width) left = lx * scale - tooltip.offsetWidth - 12;
        tooltip.style.left = Math.max(0, left) + "px";
        tooltip.style.top = Math.max(0, ly * scale - tooltip.offsetHeight - 10) + "px";
      }
      path.addEventListener("pointerenter", showTip);
      path.addEventListener("focus", showTip);
      path.addEventListener("pointerleave", function () { tooltip.style.display = "none"; });
      path.addEventListener("blur", function () { tooltip.style.display = "none"; });
      path.addEventListener("click", function () {
        state.zone = zn;
        state.day = day.date;
        setView("explorer");
        selectZone(zn, true);
        writeHash();
      });
      svg.appendChild(path);

      // labels: code for mid-size zones, code+value for large ones
      var area = f.properties.area || 0;
      if (area >= 1.2) {
        var dark = has && (t < 0.28 || t > 0.78);
        var fill = has ? (dark ? "#FBF8F1" : "#22303F") : C.muted;
        var short = zn.replace("IT-", "").replace("DE_LU", "DE/LU");
        labels.push({ x: lx, y: ly, text: short, size: area >= 6 ? 13 : 10, fill: fill, dy: area >= 6 ? -3 : 3 });
        if (has && area >= 6) {
          labels.push({ x: lx, y: ly, text: (metric === "err" && v > 0 ? "+" : "") + fmt(v, 0),
                        size: 12, fill: fill, dy: 13 });
        }
      }
    });
    labels.forEach(function (L) {
      var txt = svgEl("text", {
        x: L.x, y: L.y + L.dy, "text-anchor": "middle",
        "font-size": L.size, "font-weight": 600, fill: L.fill,
        "pointer-events": "none", "font-variant-numeric": "tabular-nums",
        "paint-order": "stroke", stroke: "rgba(251,248,241,0.45)", "stroke-width": 2,
      });
      txt.textContent = L.text;
      svg.appendChild(txt);
    });

    $("map-comment").textContent = buildMapComment(day);
  }

  // ---------- Predicting RES & loads (the open input model) ----------
  // Data plane: /api/v1/inputs/{manifest,reservoir,<zone>} (parquet under
  // v1/inputs/, bin/export_prediction_inputs.jl). The map centrepiece colours
  // every footprint zone by tomorrow's predicted midday RES coverage — the 5 ML
  // pilots from LightGBM, the other 34 from the linear weather packs (the src_*
  // provenance is badged on each zone panel); clicking a zone opens the driver
  // small-multiples ("the knobs") underneath.

  var predictState = { manifest: null, reservoir: null, geo: null, zone: null, zoneData: {} };

  // Coverage ramp: neutral (load-covered) -> deep green (RES ≥ load, collapse risk).
  var RAMP_COVER = ["#E7DFC9", "#B9CDA0", "#7FB077", "#3F9B6D", "#1F7A4A", "#0F5A34"];
  var COVER_DOMAIN = [0, 1.2];

  function loadPredict() {
    var pM = predictState.manifest ? Promise.resolve() :
      loadWithFallback("inputs/manifest.json").then(function (r) {
        predictState.manifest = r.json;
        if (r.json && r.json.fixture) setFixtureBanner(true);
      }, function () { predictState.manifest = { map: [], pilot_zones: [] }; });
    var pR = predictState.reservoir ? Promise.resolve() :
      loadWithFallback("inputs/reservoir.json").then(function (r) {
        predictState.reservoir = r.json;
      }, function () { predictState.reservoir = { zones: {} }; });
    var pG = predictState.geo ? Promise.resolve() :
      (mapState.geo ? (predictState.geo = mapState.geo, Promise.resolve()) :
        fetchJSON("./geo/zones.geojson").then(function (g) { predictState.geo = g; mapState.geo = mapState.geo || g; }));
    return Promise.all([pM, pR, pG]);
  }

  function coverMap() {
    var m = {};
    ((predictState.manifest && predictState.manifest.map) || []).forEach(function (r) { m[r.zone] = r; });
    return m;
  }

  function renderPredict() {
    var man = predictState.manifest;
    var wrap = $("pmap-wrap");
    wrap.textContent = "";
    $("pmap-legend-bar").style.backgroundImage = rampCss(RAMP_COVER);
    if (!man || !predictState.geo) {
      $("pmap-comment").textContent = "Prediction inputs arrive with the next forecast run.";
      return;
    }
    var cov = coverMap();
    var pilots = man.pilot_zones || Object.keys(cov);

    var svg = svgEl("svg", { viewBox: "0 0 " + MAP_VBW + " " + MAP_VBH, role: "img",
      "aria-label": "Map of predicted midday RES coverage across the footprint" });
    var css = getComputedStyle(document.documentElement);
    var pageC = css.getPropertyValue("--page").trim();
    var mutedC = css.getPropertyValue("--text-muted").trim();
    var tooltip = el("div", "tooltip"); tooltip.style.display = "none";
    wrap.appendChild(svg); wrap.appendChild(tooltip);

    var labels = [];
    predictState.geo.features.forEach(function (f) {
      var zn = f.properties.zone;
      var rec = cov[zn];
      // Every footprint zone is now in the open surface (ML pilot or linear pack);
      // a zone with a manifest map record is coloured + clickable regardless of
      // which model produced it. `pilot` only picks a stroke accent for the ML five.
      var inSurface = !!rec;
      var isPilot = pilots.indexOf(zn) !== -1;
      var has = rec && rec.coverage !== null && rec.coverage !== undefined;
      var t = has ? (rec.coverage - COVER_DOMAIN[0]) / (COVER_DOMAIN[1] - COVER_DOMAIN[0]) : 0;
      var fill = has ? rampColor(RAMP_COVER, t) : (inSurface ? "rgba(128,128,128,0.18)" : "rgba(128,128,128,0.07)");
      var attrs = {
        d: geoPath(f.geometry), class: "map-poly" + (isPilot ? " pilot" : "") + (inSurface ? " in-surface" : ""),
        fill: fill, stroke: (has && rec.collapse_risk) ? "#0F5A34" : pageC,
        "stroke-width": (has && rec.collapse_risk) ? 2.4 : 1.1, "stroke-linejoin": "round",
        "aria-label": zn + (has ? ": predicted RES coverage " + fmt(rec.coverage * 100, 0) + "%" +
          (rec.model ? " (" + (rec.model === "ml" ? "ML" : "pack") + ")" : "") :
          (inSurface ? ": no prediction yet" : ": not in the open model")),
      };
      if (inSurface) { attrs.tabindex = "0"; attrs.role = "button"; }
      var path = svgEl("path", attrs);
      if (inSurface) {
        var lx = mapX(f.properties.lx), ly = mapY(f.properties.ly);
        function showTip() {
          tooltip.textContent = "";
          tooltip.appendChild(el("div", "tt-head", zn + (rec ? " · " + rec.date : "") +
            (rec && rec.model ? "  ·  " + (rec.model === "ml" ? "ML" : "pack") : "")));
          if (has) {
            [["RES coverage", fmt(rec.coverage * 100, 0) + "%"],
             ["pred. RES", fmt(rec.midday_res_mw, 0) + " MW"],
             ["pred. load", fmt(rec.midday_load_mw, 0) + " MW"],
             ["collapse risk", rec.collapse_risk ? "yes" : "no"]].forEach(function (rw) {
              var row = el("div", "tt-row");
              row.appendChild(el("span", "tt-val", rw[1]));
              row.appendChild(el("span", "tt-name", rw[0]));
              tooltip.appendChild(row);
            });
          } else {
            tooltip.appendChild(el("div", "tt-row", "prediction pending"));
          }
          var rect = svg.getBoundingClientRect(); var scale = rect.width / MAP_VBW;
          tooltip.style.display = "block";
          var left = (lx + 12) * scale;
          if (left + tooltip.offsetWidth > rect.width) left = lx * scale - tooltip.offsetWidth - 12;
          tooltip.style.left = Math.max(0, left) + "px";
          tooltip.style.top = Math.max(0, ly * scale - tooltip.offsetHeight - 10) + "px";
        }
        path.addEventListener("pointerenter", showTip);
        path.addEventListener("focus", showTip);
        path.addEventListener("pointerleave", function () { tooltip.style.display = "none"; });
        path.addEventListener("blur", function () { tooltip.style.display = "none"; });
        path.addEventListener("click", function () { selectPredictZone(zn); });
        var short = zn.replace("IT-", "").replace("DE_LU", "DE/LU");
        labels.push({ x: lx, y: ly, text: short, has: has, t: t });
      }
      svg.appendChild(path);
    });
    labels.forEach(function (L) {
      var dark = L.has && L.t > 0.5;
      var txt = svgEl("text", { x: L.x, y: L.y + 4, "text-anchor": "middle",
        "font-size": 12, "font-weight": 700, fill: dark ? "#FBF8F1" : "#22303F",
        "pointer-events": "none", "paint-order": "stroke",
        stroke: "rgba(251,248,241,0.5)", "stroke-width": 2.4 });
      txt.textContent = L.text;
      svg.appendChild(txt);
    });

    // Comment: the highest-coverage / collapse-risk pilot today.
    var recs = ((man.map) || []).filter(function (r) { return r.coverage !== null && r.coverage !== undefined; });
    if (recs.length) {
      recs.sort(function (a, b) { return b.coverage - a.coverage; });
      var top = recs[0];
      var atRisk = recs.filter(function (r) { return r.collapse_risk; }).map(function (r) { return r.zone; });
      var s = "For " + top.date + ", the model sees the deepest midday RES coverage in " + top.zone +
        " (" + fmt(top.coverage * 100, 0) + "% of load from wind+solar). ";
      s += atRisk.length ?
        "Collapse-risk zones (RES approaching load at midday): " + atRisk.join(", ") + "." :
        "No zone reaches the collapse threshold at midday.";
      $("pmap-comment").textContent = s;
    } else {
      $("pmap-comment").textContent = "Predictions fill as the daily weather runs accumulate.";
    }

    if (predictState.zone) renderKnobs();
  }

  function loadPredictZone(zone) {
    if (predictState.zoneData[zone]) return Promise.resolve(predictState.zoneData[zone]);
    return loadWithFallback("inputs/" + encodeURIComponent(zone) + ".json").then(function (r) {
      predictState.zoneData[zone] = r.json;
      if (r.json && r.json.fixture) setFixtureBanner(true);
      return r.json;
    });
  }

  function selectPredictZone(zone) {
    predictState.zone = zone;
    loadPredictZone(zone).then(renderKnobs, function () {
      $("predict-knobs").hidden = false;
      $("pk-title").textContent = zone + " — no driver panel yet";
      $("pk-sub").textContent = "This zone's prediction inputs fill with the next forecast run.";
      $("pk-outputs").textContent = ""; $("pk-drivers").textContent = "";
      $("pk-reservoir").hidden = true;
    });
  }

  // element-wise sum of two nullable numeric arrays (RES = solar + wind).
  function sumSeries(a, b) {
    var out = [];
    for (var i = 0; i < a.length; i++) {
      var x = a[i], y = b[i];
      out.push((x === null || x === undefined) && (y === null || y === undefined) ? null :
        (x || 0) + (y || 0));
    }
    return out;
  }

  function srcBadge(label, which) {
    var b = el("span", "src-badge src-" + which, label + ": " + (which === "ml" ? "LightGBM" : "linear pack"));
    return b;
  }

  function renderKnobs() {
    var zd = predictState.zoneData[predictState.zone];
    if (!zd) return;
    var box = $("predict-knobs");
    box.hidden = false;
    var C = chartColors();
    var s = zd.series;
    var hours = zd.hours;
    var lastDate = hours.length ? hours[hours.length - 1].slice(0, 10) : "";
    $("pk-title").textContent = predictState.zone + " — drivers & prediction";
    var sub = $("pk-sub");
    sub.textContent = hours.length ?
      ("Every delivery hour from " + hours[0].slice(0, 10) + " to " + lastDate +
        " · ex-ante D-1 weather vintage · winners: ") : "";
    sub.appendChild(srcBadge("load", zd.src.load));
    sub.appendChild(document.createTextNode(" "));
    sub.appendChild(srcBadge("solar", zd.src.solar));
    sub.appendChild(document.createTextNode(" "));
    sub.appendChild(srcBadge("wind", zd.src.wind));

    // --- Predictions vs reference vs actual ---
    var outs = $("pk-outputs"); outs.textContent = "";
    var resRef = sumSeries(s.ref_solar_mw, s.ref_wind_mw);
    var resAct = sumSeries(s.act_solar_mw, s.act_wind_mw);
    driverMiniChart(outs, {
      title: "Renewables (wind + solar)", unit: "MW", hours: hours, big: true,
      series: [
        { label: "predicted", color: C.sim, values: s.pred_res_mw },
        { label: "ENTSO-E reference", color: "#B08A3E", values: resRef, dashed: true },
        { label: "actual", color: C.act, values: resAct },
      ],
    });
    driverMiniChart(outs, {
      title: "Load", unit: "MW", hours: hours, big: true,
      series: [
        { label: "predicted", color: C.sim, values: s.pred_load_mw },
        { label: "ENTSO-E reference", color: "#B08A3E", values: s.ref_load_mw, dashed: true },
        { label: "actual", color: C.act, values: s.act_load_mw },
      ],
    });

    // --- The knobs (drivers) ---
    var drv = $("pk-drivers"); drv.textContent = "";
    var accent = "#2C6BA8";
    [["temp_c", "Temperature", "°C"],
     ["ghi_wm2", "Solar radiation (GHI)", "W/m²"],
     ["cloud_pct", "Cloud cover", "%"],
     ["pressure_hpa", "Surface pressure", "hPa"],
     ["wind100_ms", "Wind speed (100 m)", "m/s"]].forEach(function (d) {
      driverMiniChart(drv, {
        title: d[1], unit: d[2], hours: hours,
        series: [{ label: d[1], color: accent, values: s[d[0]] }],
      });
    });

    // --- Reservoir (hydro zones) ---
    var resv = predictState.reservoir && predictState.reservoir.zones &&
      predictState.reservoir.zones[predictState.zone];
    var rbox = $("pk-reservoir");
    if (resv && resv.length) {
      rbox.hidden = false;
      var rc = $("pk-reservoir-charts"); rc.textContent = "";
      var wks = resv.map(function (w) { return w.week_start; });
      driverMiniChart(rc, { title: "Reservoir fill ratio", unit: "share of 52-wk max", hours: wks,
        series: [{ label: "fill ratio", color: "#2C6BA8", values: resv.map(function (w) { return w.fill_ratio; }) }] });
      driverMiniChart(rc, { title: "Reservoir dryness", unit: "vs prior-year median", hours: wks,
        series: [{ label: "dryness", color: "#C4643C", values: resv.map(function (w) { return w.dryness; }) }] });
    } else {
      rbox.hidden = true;
    }
  }

  // Compact multi-series line chart with its own y-scale + unit. `hours` is the
  // shared x axis (ISO stamps or dates); series = [{label,color,values,dashed}].
  function driverMiniChart(container, cfg) {
    var card = el("div", "mini-card" + (cfg.big ? " mini-big" : ""));
    var head = el("div", "mini-head");
    head.appendChild(el("span", "mini-title", cfg.title));
    head.appendChild(el("span", "mini-unit", cfg.unit));
    card.appendChild(head);

    var vals = [];
    cfg.series.forEach(function (se) {
      se.values.forEach(function (v) { if (v !== null && v !== undefined && isFinite(v)) vals.push(v); });
    });
    if (!vals.length) {
      card.appendChild(el("p", "mini-empty", "no data yet"));
      container.appendChild(card);
      return;
    }
    var VBW = 460, VBH = cfg.big ? 190 : 140;
    var m = { t: 8, r: 8, b: 16, l: 40 };
    var pw = VBW - m.l - m.r, ph = VBH - m.t - m.b;
    var n = cfg.hours.length;
    var vMin = Math.min.apply(null, vals), vMax = Math.max.apply(null, vals);
    if (vMin > 0 && vMin / (vMax || 1) > 0.4) { /* keep a non-zero baseline for tight ranges */ }
    else if (vMin > 0) vMin = 0;
    var pad = (vMax - vMin) * 0.08 || 1; vMax += pad; if (vMin < 0) vMin -= pad;
    var C = chartColors();
    function X(i) { return m.l + (n <= 1 ? pw / 2 : (i / (n - 1)) * pw); }
    function Y(v) { return m.t + ph - ((v - vMin) / (vMax - vMin || 1)) * ph; }
    var svg = svgEl("svg", { viewBox: "0 0 " + VBW + " " + VBH, class: "mini-svg",
      role: "img", "aria-label": cfg.title + " over the window" });
    // zero / min / max gridlines + ticks
    [vMin, (vMin + vMax) / 2, vMax].forEach(function (gv) {
      var yy = Y(gv);
      svg.appendChild(svgEl("line", { x1: m.l, x2: m.l + pw, y1: yy, y2: yy,
        stroke: C.grid, "stroke-width": 1, "shape-rendering": "crispEdges" }));
      var tk = svgEl("text", { x: m.l - 6, y: yy + 3, "text-anchor": "end",
        fill: C.muted, "font-size": 10, "font-variant-numeric": "tabular-nums" });
      tk.textContent = fmt(gv, Math.abs(vMax) < 3 ? 2 : 0);
      svg.appendChild(tk);
    });
    cfg.series.forEach(function (se) {
      var d = pathString(se.values, X, Y);
      if (!d) return;
      var pa = { d: d, fill: "none", stroke: se.color, "stroke-width": 1.8,
        "stroke-linejoin": "round", "stroke-linecap": "round" };
      if (se.dashed) pa["stroke-dasharray"] = "4 3";
      svg.appendChild(svgEl("path", pa));
    });
    card.appendChild(svg);
    if (cfg.series.length > 1) {
      var lg = el("div", "mini-legend");
      cfg.series.forEach(function (se) {
        var sp = el("span", "mini-key");
        var sw = el("span", "mini-swatch"); sw.style.background = se.color;
        if (se.dashed) sw.classList.add("dashed");
        sp.appendChild(sw); sp.appendChild(document.createTextNode(se.label));
        lg.appendChild(sp);
      });
      card.appendChild(lg);
    }
    container.appendChild(card);
  }

  // ---------- day commentary (explorer) ----------

  function renderDayComment(day) {
    var p = $("day-comment");
    if (isPending(day)) {
      p.textContent = "Prediction only — frozen " +
        (day.prediction_made_utc ? day.prediction_made_utc.replace("T", " ").replace("Z", " UTC") : "") +
        ", never revised. Commentary appears once the day settles.";
      return;
    }
    var tier = (day.corr >= 0.9 && day.mae < 15) ? "An excellent day for the model" :
               day.corr >= 0.75 ? "A good day for the model" :
               day.corr >= 0.5 ? "A mixed day" : "A hard day for the model";
    var s = tier + ": hourly correlation " + fmt(day.corr, 2) +
      " with a mean miss of €" + fmt(day.mae, 1) + "/MWh.";
    if (day.bias !== null && day.bias !== undefined && Math.abs(day.bias) >= 8) {
      s += " It ran €" + fmt(Math.abs(day.bias), 0) + " " + (day.bias > 0 ? "high" : "low") +
        " on average" + (day.bias < 0 ? " — under-pricing is what a competitive counterfactual should do where the real market prices above competition." : ".");
    }
    var wi = -1, wv = 0;
    day.hours.forEach(function (h, i) {
      var a = day.actual[i];
      if (a === null || a === undefined) return;
      var e = Math.abs(day.sim[i] - a);
      if (e > wv) { wv = e; wi = i; }
    });
    if (wi >= 0 && wv >= 15) {
      s += " Largest miss: " + hourLabel(day.hours[wi]) + "–" + hourEndLabel(day.hours[wi]) +
        " Athens (forecast €" + fmt(day.sim[wi], 0) + " vs actual €" + fmt(day.actual[wi], 0) + ").";
    }
    p.textContent = s;
  }

  // ---------- scoreboard ----------

  // The scoreboard reports ONLY the ex-ante weather track (directive 3); the
  // reference (entsoe) track is kept in the data plane but hidden from the UI.
  function trackScores() {
    return state.scoreboard.scores.filter(function (s) {
      return isWeatherMode(s.input_mode);
    });
  }

  function scoreboardWindows() {
    var seen = {};
    trackScores().forEach(function (s) { seen[s.window] = true; });
    var wins = Object.keys(seen);
    if (!wins.length) wins = ["all"];
    wins.sort(function (a, b) {
      if (a === "all") return -1;
      if (b === "all") return 1;
      return a < b ? 1 : -1; // months newest first
    });
    return wins;
  }

  function scoreboardLeads() {
    var seen = {};
    trackScores().forEach(function (s) { seen[s.lead_days] = true; });
    return Object.keys(seen).map(Number).sort(function (a, b) { return a - b; });
  }

  function renderWindowSelect() {
    var sel = $("window-select");
    sel.textContent = "";
    scoreboardWindows().forEach(function (w) {
      var o = el("option", null, w === "all" ? "All days" : w);
      o.value = w;
      sel.appendChild(o);
    });
    if (Array.prototype.some.call(sel.options, function (o) { return o.value === state.window; })) {
      sel.value = state.window;
    } else {
      state.window = sel.value;
    }
  }

  function corrClass(c) {
    if (c === null || c === undefined) return null;
    if (c >= 0.75) return "good";
    if (c < 0.4) return "weak";
    return "mid";
  }

  function renderScoreboard() {
    var table = $("scoreboard-table");
    table.textContent = "";
    var tracked = trackScores();
    if (!tracked.length) {
      // Friendly empty state (the weather track fills as its runs accumulate).
      var tbody0 = el("tbody");
      var tr0 = el("tr");
      var td0 = el("td", "null",
        "No scored days on the ex-ante (weather) track yet — this track freezes " +
        "before the 12:00 CET auction and starts accumulating scores once the " +
        "weather-based morning runs begin and their delivery days settle.");
      td0.colSpan = 1;
      tr0.appendChild(td0);
      tbody0.appendChild(tr0);
      table.appendChild(tbody0);
      return;
    }
    var leads = scoreboardLeads();
    var scores = tracked.filter(function (s) { return s.window === state.window; });
    var byKey = {};
    scores.forEach(function (s) { byKey[s.zone + "|" + s.lead_days] = s; });

    if (state.sort.lead === null || leads.indexOf(state.sort.lead) === -1) state.sort.lead = leads[0];

    var METRICS = [["corr", "corr"], ["mae", "MAE"], ["bias", "bias"]];

    // header
    var thead = el("thead");
    var tr1 = el("tr");
    var thZone = el("th", null, "Zone");
    thZone.rowSpan = 2;
    tr1.appendChild(thZone);
    leads.forEach(function (l) {
      var th = el("th", "group lead-sep", "Lead D-" + l);
      th.colSpan = METRICS.length;
      tr1.appendChild(th);
    });
    thead.appendChild(tr1);
    var tr2 = el("tr");
    leads.forEach(function (l) {
      METRICS.forEach(function (mdef, mi) {
        var isSorted = state.sort.lead === l && state.sort.metric === mdef[0];
        var th = el("th", "sortable" + (mi === 0 ? " lead-sep" : "") + (isSorted ? " sorted" : ""),
          mdef[1] + (isSorted ? (state.sort.dir === 1 ? " ↓" : " ↑") : ""));
        th.setAttribute("role", "button");
        th.title = "Sort by " + mdef[1] + " (lead D-" + l + ")";
        th.addEventListener("click", function () {
          if (state.sort.lead === l && state.sort.metric === mdef[0]) {
            state.sort.dir = -state.sort.dir;
          } else {
            state.sort = { lead: l, metric: mdef[0], dir: 1 };
          }
          renderScoreboard();
        });
        tr2.appendChild(th);
      });
    });
    thead.appendChild(tr2);
    table.appendChild(thead);

    // rows: sort zones, GR pinned first
    var zones = state.scoreboard.zones.slice();
    function sortVal(z) {
      var s = byKey[z + "|" + state.sort.lead];
      if (!s) return Infinity;
      var m = state.sort.metric;
      if (m === "corr") return s.corr === null ? Infinity : -s.corr; // higher corr = better
      if (m === "bias") return s.bias === null ? Infinity : Math.abs(s.bias); // closer to 0 = better
      return s.mae === null ? Infinity : s.mae; // lower MAE = better
    }
    zones.sort(function (a, b) {
      var va = sortVal(a), vb = sortVal(b);
      return (va - vb) * state.sort.dir || (a < b ? -1 : 1);
    });
    zones = zones.filter(function (z) { return z !== "GR"; });
    if (state.scoreboard.zones.indexOf("GR") !== -1) zones.unshift("GR");

    var tbody = el("tbody");
    zones.forEach(function (z) {
      var tr = el("tr", z === "GR" ? "pinned" : null);
      var tdz = el("td", "zone-cell", z);
      tr.appendChild(tdz);
      leads.forEach(function (l) {
        var s = byKey[z + "|" + l];
        METRICS.forEach(function (mdef, mi) {
          var td = el("td", mi === 0 ? "lead-sep" : null);
          if (!s) {
            td.textContent = "—";
            td.className = ((td.className || "") + " null").trim();
          } else if (mdef[0] === "corr") {
            var cls = corrClass(s.corr);
            if (cls) {
              var dot = el("span", "dot dot-" + cls);
              dot.setAttribute("aria-hidden", "true");
              td.appendChild(dot);
              td.title = "corr " + fmt(s.corr, 2) + " (" +
                (cls === "good" ? "good" : cls === "weak" ? "weak" : "moderate") +
                ") · n=" + s.n_days + " days";
            }
            td.appendChild(document.createTextNode(fmt(s.corr, 2)));
          } else if (mdef[0] === "mae") {
            td.textContent = fmt(s.mae, 1);
            td.title = "MAE " + fmt(s.mae, 2) + " €/MWh · n=" + s.n_days + " days";
          } else {
            td.textContent = (s.bias > 0 ? "+" : "") + fmt(s.bias, 1);
            td.title = "bias " + fmt(s.bias, 2) + " €/MWh · n=" + s.n_days + " days";
          }
          tr.appendChild(td);
        });
      });
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
  }

  // ---------- order book (merit-order ladder) ----------
  // Per zone × market day × hour: the supply ladder stacked left→right by
  // ascending price (x = cumulative MW, y = €/MWh), coloured by owner, with a
  // dashed marker at the clearing price (the model's simulated price for that
  // zone-hour — "πού έκατσε η μπίλια") and a second marker at the settled actual.

  var bookPlayTimer = null;

  function stopBookPlay() {
    if (bookPlayTimer) { clearInterval(bookPlayTimer); bookPlayTimer = null; }
    var b = $("book-play");
    if (b) b.textContent = "▶ Play day";
  }

  // ---- fuel taxonomy: ONE consistent palette + icon per fuel family --------
  // Slices are coloured by FUEL TYPE (not per-unit), so a gas plant reads the
  // same colour everywhere. The canonical ENTSO-E fuel STRING (from
  // v1/units.parquet, post name-inference) maps to a small family; the family
  // maps to a --fuel-<fam> CSS variable (theme-aware, defined in style.css) and
  // an emoji icon (owner's spec, extended consistently). One place: here.
  var FUEL_META = {
    "Fossil Gas":                     { fam: "gas",        icon: "🔥" },
    "Fossil Coal-derived gas":        { fam: "gas",        icon: "🔥" },
    "Fossil Oil":                     { fam: "oil",        icon: "⛽" },
    "Fossil Oil shale":               { fam: "oil",        icon: "⛽" },
    "Fossil Hard coal":               { fam: "coal",       icon: "🪨" },
    "Fossil Brown coal/Lignite":      { fam: "coal",       icon: "🪨" },
    "Fossil Peat":                    { fam: "coal",       icon: "🪨" },
    "Nuclear":                        { fam: "nuclear",    icon: "⚛️" },
    "Hydro Water Reservoir":          { fam: "hydro",      icon: "💧" },
    "Hydro Run-of-river and pondage": { fam: "hydro",      icon: "💧" },
    "Hydro Pumped Storage":           { fam: "hydro",      icon: "💧" },
    "Solar":                          { fam: "solar",      icon: "☀️" },
    "Wind Onshore":                   { fam: "wind",       icon: "🎐" },
    "Wind Offshore":                  { fam: "wind",       icon: "🎐" },
    "Energy storage":                 { fam: "storage",    icon: "🔋" },
    "Biomass":                        { fam: "biomass",    icon: "🌾" },
    "Waste":                          { fam: "biomass",    icon: "🌾" },
    "Other renewable":                { fam: "biomass",    icon: "🌱" },
    "Geothermal":                     { fam: "geothermal", icon: "♨️" },
    "Other":                          { fam: "other",      icon: "❓" },
  };
  var FUEL_FAM_LABEL = {
    gas: "Gas", oil: "Oil / diesel", coal: "Coal / lignite", nuclear: "Nuclear",
    hydro: "Hydro", solar: "Solar", wind: "Wind", storage: "Storage",
    biomass: "Biomass", geothermal: "Geothermal", other: "Other / unknown",
  };
  // Non-fuel book tags keep DISTINCT NEUTRAL styling (never a fuel colour).
  var TAG_META = {
    RES:        { icon: "🌱", label: "Renewables (forecast)", css: "--book-res" },
    IMPORT:     { icon: "🔌", label: "Net imports",           css: "--book-import" },
    DEMAND:     { icon: "📉", label: "Demand",                css: "--book-demand" },
    BACKSTOP:   { icon: "🛟", label: "Import backstop",       css: "--book-backstop" },
    EXTRA:      { icon: "➕", label: "Scenario order",        css: "--book-extra" },
    STRATEGIST: { icon: "➕", label: "Strategist order",      css: "--book-extra" },
  };

  function fuelMeta(fuel) { return (fuel && FUEL_META[fuel]) || FUEL_META["Other"]; }

  // Theme-aware colour lookups, read from CSS custom properties (same pattern as
  // chartColors) so light/dark follow the site toggle on the next render.
  function bookColors() {
    var css = getComputedStyle(document.documentElement);
    var fams = {}, k;
    for (k in FUEL_FAM_LABEL) fams[k] = css.getPropertyValue("--fuel-" + k).trim() || "#8892A0";
    var tags = {};
    for (k in TAG_META) tags[TAG_META[k].css] = css.getPropertyValue(TAG_META[k].css).trim();
    var trade = css.getPropertyValue("--book-trade").trim() || "#C51D74";
    return { fuel: fams, tag: tags, trade: trade };
  }

  // Resolve a book `owner` tag to display info: kind (unit|agg|tag), fuel family,
  // icon, firm (nullable), a human name, and its palette key. Degrades to the
  // raw code when the units reference has not loaded or lacks the unit.
  function ownerInfo(owner) {
    if (TAG_META[owner]) {
      var t = TAG_META[owner];
      return { kind: "tag", fam: null, icon: t.icon, firm: null, name: t.label,
               tagCss: t.css, fuel: null };
    }
    // Fleet-completion aggregate: "AGG-<zone>-<Fuel_with_underscores>".
    var fuel = null, name = null;
    var mAgg = /^AGG[-_].+?[-_](.+)$/.exec(owner);
    if (mAgg) { fuel = mAgg[1].replace(/_/g, " "); name = "Aggregate small units"; }
    var u = state.units && state.units[owner];
    if (u) {
      if (u.fuel) fuel = u.fuel;
      if (u.name) name = u.name;
    }
    var meta = fuelMeta(fuel);
    var firm = u && u.firm && u.firm !== "unknown" ? u.firm : null;
    if (!name) name = owner.length > 14 ? "…" + owner.slice(-10) : owner;
    return { kind: mAgg ? "agg" : "unit", fam: meta.fam, icon: meta.icon,
             firm: firm, name: name, fuel: fuel || "Other", tagCss: null };
  }

  // Colour for an owner given a resolved bookColors() map.
  function ownerColor(owner, BC) {
    var info = ownerInfo(owner);
    return info.kind === "tag" ? (BC.tag[info.tagCss] || "#8892A0")
                               : (BC.fuel[info.fam] || BC.fuel.other);
  }

  // "(firm) (icon) name" — the slice label/tooltip title.
  function ownerLabel(owner) {
    var info = ownerInfo(owner);
    var head = info.icon + " " + info.name;
    return info.firm ? info.firm + " · " + head : head;
  }

  // Static unit reference (code -> {name, fuel, firm}). Loaded once, cached;
  // failure degrades to {} (slices fall back to code labels + Other colour).
  var unitsPromise = null;
  function loadUnits() {
    if (state.units) return Promise.resolve(state.units);
    if (unitsPromise) return unitsPromise;
    unitsPromise = loadWithFallback("units").then(
      function (res) {
        state.units = (res.json && res.json.units) ? res.json.units : {};
        return state.units;
      },
      function () { state.units = {}; return state.units; }
    );
    return unitsPromise;
  }

  // ---- coupled cross-border flows (for the trade-wedge decomposition) ------
  // Per market day: v1/flows/<date>.parquet -> { "<tsIso>": [[source,sink,mw],…] }.
  // Only RECORD/backfill days persist transmission_flows (the daily FORECAST
  // path saves forecast_prices only, save_to_db=false) — so on forecast days the
  // flows fetch 404s and the wedge falls back to the anonymous net brace. Cached
  // per date; failure caches null (→ anonymous wedge, no repeated fetch).
  var flowsPromise = {};
  function loadFlows(date) {
    if (state.flowsCache[date] !== undefined) return Promise.resolve(state.flowsCache[date]);
    if (flowsPromise[date]) return flowsPromise[date];
    flowsPromise[date] = loadWithFallback("flows/" + date).then(
      function (res) { state.flowsCache[date] = (res.json && res.json.flows) || null; return state.flowsCache[date]; },
      function () { state.flowsCache[date] = null; return null; }
    );
    return flowsPromise[date];
  }

  // Best-effort neighbour clearing price at a UTC hour, from the neighbour's
  // (already cached) zone forecast for the shown market day. null if not loaded.
  function neighborPriceAt(zone, tsIso) {
    var zd = state.zoneCache[zone];
    if (!zd) return null;
    var days = freshestByDate(weatherDays(zd));
    var day = null;
    days.forEach(function (d) { if (!day && d.date === state.bookDay) day = d; });
    if (!day) return null;
    var i = day.hours.indexOf(tsIso);
    return i >= 0 ? day.sim[i] : null;
  }

  function fmtMWk(mw) {
    return mw >= 1000 ? (mw / 1000).toFixed(1) + "k" : String(Math.round(mw));
  }

  // Decompose a zone-hour's coupled net trade into import/export SOURCES from
  // the solved cross-border flows, ordered by the neighbour's price (cheapest
  // imports first), with the out-of-footprint fixed injection as the residual.
  // Returns null when no flows are loaded for the day (→ anonymous net wedge).
  function tradeSegments(zone, tsIso, netImport) {
    var byTs = state.flowsCache[state.bookDay];
    if (!byTs) return null;
    var rows = byTs[tsIso];
    if (!rows || !rows.length) return null;
    var isImport = netImport > 0;
    var perN = {}, flowNet = 0;
    rows.forEach(function (r) {
      var src = r[0], snk = r[1], mw = r[2], other = null, into = 0;
      if (snk === zone) { other = src; into = mw; }
      else if (src === zone) { other = snk; into = -mw; }
      else return;
      perN[other] = (perN[other] || 0) + into;
      flowNet += into;
    });
    // Only decompose when the SOLVED coupled flow agrees in DIRECTION with the
    // book-implied net (a local-ladder heuristic). When they diverge — the local
    // book's intersection is not the coupled dispatch — per-source attribution
    // would mislead, so we fall back to the anonymous net wedge (measured: this
    // happens on genuine hours, e.g. GR importing on the local ladder while the
    // footprint has it exporting).
    if ((isImport && flowNet <= 1) || (!isImport && flowNet >= -1)) return null;
    var segs = [];
    Object.keys(perN).forEach(function (n) {
      var v = perN[n];
      if (isImport ? v > 1 : v < -1) {
        segs.push({ zone: n, mw: Math.abs(v), price: neighborPriceAt(n, tsIso), fixed: false });
      }
    });
    segs.sort(function (a, b) {
      var pa = a.price == null ? 1e9 : a.price, pb = b.price == null ? 1e9 : b.price;
      return isImport ? pa - pb : pb - pa;
    });
    segs.forEach(function (s) {
      s.label = s.zone + " → " + fmtMWk(s.mw) + (s.price == null ? "" : " @ €" + fmt(s.price, 0));
    });
    // Out-of-footprint fixed injections (TR/AL/MK …) are NOT in the flow table;
    // show the reconciliation residual to the book-implied net as "(fixed)".
    var fixed = Math.abs(netImport) - segs.reduce(function (a, s) { return a + s.mw; }, 0);
    if (fixed > CLIFF.TRADE_MIN_MW) {
      segs.push({ zone: "(fixed)", mw: fixed, price: null, fixed: true, label: "(fixed) " + fmtMWk(fixed) });
    }
    return segs;
  }

  // After flows load, pre-load the zones of this zone-day's trading neighbours
  // (bounded) so a second paint can label segments with their prices.
  function preloadTradingNeighbors(zone, date, tsList) {
    var byTs = state.flowsCache[date];
    if (!byTs) return;
    var need = {};
    tsList.forEach(function (ts) {
      (byTs[ts] || []).forEach(function (r) {
        var other = r[1] === zone ? r[0] : (r[0] === zone ? r[1] : null);
        if (other && !state.zoneCache[other]) need[other] = true;
      });
    });
    var zones = Object.keys(need);
    if (!zones.length) return;
    Promise.all(zones.map(function (z) { return loadZone(z).catch(function () { return null; }); }))
      .then(function () {
        if (state.view === "book" && state.bookDay === date) {
          var zoneData = state.zoneCache[state.zone];
          var days = zoneData ? freshestByDate(weatherDays(zoneData)) : [];
          var fday = null;
          days.forEach(function (d) { if (!fday && d.date === date) fday = d; });
          var book = state.bookCache[state.zone + "|" + date];
          if (book && fday) renderBookLadder(book, fday, state.bookHour);
        }
      });
  }

  // ---- CLIFF metric: price fragility of the book at the clearing point ------
  // Display heuristics (NOT a scored product metric — a scored cliff-risk metric
  // would be its own prereg). Kept in ONE constants block; surfaced in the badge
  // tooltip. See the collapse-question family in .claude/STRATEGY.md.
  var CLIFF = {
    WINDOWS: [100, 200, 500],  // ±MW windows offered in the readout
    W_PRIMARY: 200,            // the band drawn on the chart + badge threshold
    SPAN_CLIFF: 50,            // €/MWh price span across ±W_PRIMARY: > this = "cliff"
    MERGE_PX: 10,              // model/settled MW markers merge when this close on-screen
    TRADE_MIN_MW: 50,          // hide the coupled trade wedge below this |net import|
  };

  function loadBook(zone, date) {
    var key = zone + "|" + date;
    if (state.bookCache[key] !== undefined) return Promise.resolve(state.bookCache[key]);
    return loadWithFallback("books/" + encodeURIComponent(zone) + "/" + date).then(
      function (res) { state.bookCache[key] = res.json; return res.json; },
      function () { state.bookCache[key] = null; return null; }   // no book for this day
    );
  }

  function renderBook() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) { loadZone(state.zone).then(renderBook); return; }
    if ($("bzone-select")) $("bzone-select").value = state.zone;

    // Day options: the freshest ex-ante (weather) days — the recent window that
    // also has captured books synced to the data plane.
    var days = freshestByDate(weatherDays(zoneData));
    var btns = $("book-daybtns");
    btns.textContent = "";
    if (!days.length) {
      $("book-title").textContent = state.zone + " — order book pending";
      $("book-legend").textContent = "";
      $("book-comment").textContent = "";
      var w0 = $("book-wrap"); w0.textContent = "";
      w0.appendChild(el("p", "pending-note",
        "No ex-ante (weather-track) days for " + state.zone + " yet — the order book " +
        "appears once the daily runs and their captured books accumulate."));
      return;
    }
    if (!state.bookDay || !days.some(function (d) { return d.date === state.bookDay; })) {
      state.bookDay = days[0].date;
    }
    days.slice(0, 14).forEach(function (d) {
      var b = el("button", null, d.date.slice(5));
      b.type = "button";
      b.title = dayLabel(d.date);
      b.setAttribute("aria-pressed", String(d.date === state.bookDay));
      b.addEventListener("click", function () {
        if (state.bookDay === d.date) return;
        stopBookPlay();
        state.bookDay = d.date;
        renderBook();
        writeHash();
      });
      btns.appendChild(b);
    });

    var fday = null;
    days.forEach(function (d) { if (!fday && d.date === state.bookDay) fday = d; });

    $("book-title").textContent = state.zone + " — order book · " + dayLabel(state.bookDay);
    var wrap = $("book-wrap");
    wrap.textContent = "";
    wrap.appendChild(el("p", "pending-note", "Loading order book…"));

    Promise.all([loadBook(state.zone, state.bookDay), loadUnits(),
                 loadFlows(state.bookDay)]).then(function (r) {
      var book = r[0];
      if (state.view !== "book" || state.bookDay !== fday.date) return;   // stale
      if (!book || !book.supply || !book.supply.length) {
        wrap.textContent = "";
        $("book-legend").textContent = "";
        $("book-comment").textContent = "";
        wrap.appendChild(el("p", "pending-note",
          "No captured order book for " + dayLabel(state.bookDay) + " in the data plane. " +
          "Books are published for recent forecast days and record backfills."));
        stopBookPlay();
        return;
      }
      var nH = Math.min(book.supply.length, fday.hours.length);
      var slider = $("book-hour-slider");
      slider.max = nH - 1;
      if (state.bookHour == null || state.bookHour < 0 || state.bookHour >= nH) state.bookHour = Math.min(12, nH - 1);
      slider.value = state.bookHour;
      renderBookLadder(book, fday, state.bookHour);
      // if flows exist for this day, warm up trading-neighbour prices (2nd paint)
      if (state.flowsCache[state.bookDay]) {
        preloadTradingNeighbors(state.zone, state.bookDay, fday.hours);
      }
    });
  }

  function renderBookLadder(book, fday, hourIdx) {
    var wrap = $("book-wrap");
    wrap.textContent = "";
    var supply = (book.supply[hourIdx] || []).map(function (o) {
      return { price: o[0], mw: o[1], owner: book.owners[o[2]] };
    });
    // Demand ladder (willingness-to-pay), descending in price from shapeBook.
    var demand = (book.demand[hourIdx] || []).map(function (o) {
      return { price: o[0], mw: o[1], owner: book.owners[o[2]] };
    });
    var clearing = fday.sim[hourIdx];
    var actual = fday.actual[hourIdx];
    $("book-hour-label").textContent =
      hourLabel(fday.hours[hourIdx]) + "–" + hourEndLabel(fday.hours[hourIdx]) + " Athens";

    if (!supply.length) {
      wrap.appendChild(el("p", "pending-note", "No supply orders for this hour."));
      return;
    }

    // cumulative MW + the "ball" (cumulative MW where the ladder reaches the
    // clearing price — the marginal block).
    var cum = 0, clearMW = null;
    supply.forEach(function (o) {
      o.cum0 = cum; cum += o.mw; o.cum1 = cum;
      if (clearMW === null && clearing !== null && clearing !== undefined && o.price >= clearing) clearMW = o.cum0;
    });
    var totalMW = cum;
    if (clearMW === null) clearMW = totalMW;   // clearing above the whole ladder

    // Cumulative demand (descending willingness-to-pay from the left).
    var dcum = 0;
    demand.forEach(function (o) { o.cum0 = dcum; dcum += o.mw; o.cum1 = dcum; });
    var totalDemand = dcum;

    // ---- coupled-market TRADE WEDGE --------------------------------------
    // The marker sits on the LOCAL supply curve at the COUPLED price P, not at
    // the local supply∩demand crossing: the gap is cross-border trade decided by
    // the 39-zone network (flow variables absent from this local ladder).
    // implied_net_import = (local demand willing at P) − (local supply cleared
    // at P) — >0 imports, <0 exports. Hidden when |·| is negligible.
    var demandAtClear = null, impliedNetImport = null;
    if (clearing !== null && clearing !== undefined && demand.length) {
      var dAt = 0;
      demand.forEach(function (o) { if (o.price >= clearing - 1e-9) dAt = o.cum1; });
      demandAtClear = dAt;
      impliedNetImport = demandAtClear - clearMW;   // >0 imports, <0 exports
    }

    // ---- CLIFF metric (client-side, from this ladder) --------------------
    // priceAtCum: the offer price of the supply block covering cumulative q —
    // the merit-order supply curve as a step function.
    function priceAtCum(q) {
      if (q <= 0) return supply[0].price;
      if (q >= totalMW) return supply[supply.length - 1].price;
      for (var i = 0; i < supply.length; i++) if (q < supply[i].cum1) return supply[i].price;
      return supply[supply.length - 1].price;
    }
    // MW-distance to settled: cumulative MW where the ladder first reaches the
    // SETTLED price minus where it reaches the MODEL clearing. "We were only ΔQ
    // MW off in energy" even when the €-error is large (the cliff signature).
    var settledMW = null;
    if (actual !== null && actual !== undefined) {
      settledMW = null;
      for (var si = 0; si < supply.length; si++) {
        if (supply[si].price >= actual) { settledMW = supply[si].cum0; break; }
      }
      if (settledMW === null) settledMW = totalMW;
    }
    var dQ = settledMW === null ? null : (clearMW - settledMW);   // signed (model − settled)
    // Cliff index: price span across ±W MW of the clearing quantity, per window.
    var cliffByW = {};
    CLIFF.WINDOWS.forEach(function (W) {
      var plo = priceAtCum(clearMW - W), phi = priceAtCum(clearMW + W);
      cliffByW[W] = { lo: plo, hi: phi, span: phi - plo };
    });
    var primarySpan = cliffByW[CLIFF.W_PRIMARY].span;
    var isCliff = primarySpan > CLIFF.SPAN_CLIFF;

    // x window: focus on the cleared region with context beyond the ball —
    // and always keep the ±W cliff band and the settled-MW marker on screen.
    var xMax = Math.max(clearMW * 1.5, clearMW + 500, clearMW + CLIFF.W_PRIMARY + 60,
                        settledMW === null ? 0 : settledMW + 60,
                        demandAtClear === null ? 0 : demandAtClear + 60, 100);
    xMax = Math.min(xMax, totalMW);
    // y window: keep the region around clearing readable; clip €3000 demand-cap
    // blocks. Base on clearing/actual and the supply price near the ball.
    var yRef = supply.filter(function (o) { return o.cum1 <= xMax; })
      .reduce(function (m, o) { return Math.max(m, o.price); }, 0);
    var yMax = Math.max(clearing || 0, actual || 0, yRef) * 1.18;
    if (!(yMax > 0)) yMax = 50;

    var VBW = 900, VBH = 486;
    var m = { t: 28, r: 16, b: 106, l: 56 };   // deep bottom margin: dual MW markers + ΔQ bracket
    var pw = VBW - m.l - m.r, ph = VBH - m.t - m.b;
    function X(v) { return m.l + Math.max(0, Math.min(1, v / xMax)) * pw; }
    function Y(v) { return m.t + ph - Math.max(0, Math.min(1, v / yMax)) * ph; }
    var C = chartColors();
    var BC = bookColors();

    var svg = svgEl("svg", {
      viewBox: "0 0 " + VBW + " " + VBH, role: "img",
      "aria-label": "Merit-order supply ladder for " + state.zone + " " + state.bookDay +
        " hour " + hourLabel(fday.hours[hourIdx]),
    });
    // diagonal hatch for the coupled trade wedge fill
    var defs = svgEl("defs");
    var pat = svgEl("pattern", { id: "wedgeHatch", width: 6, height: 6,
      patternUnits: "userSpaceOnUse", patternTransform: "rotate(45)" });
    pat.appendChild(svgEl("line", { x1: 0, y1: 0, x2: 0, y2: 6, stroke: BC.trade,
      "stroke-width": 1.4, "stroke-opacity": 0.35 }));
    defs.appendChild(pat);
    svg.appendChild(defs);

    // y gridlines + ticks
    var yStep = niceStep(yMax, 6);
    for (var gy = 0; gy <= yMax + 1e-9; gy += yStep) {
      var yy = Y(gy);
      svg.appendChild(svgEl("line", {
        x1: m.l, x2: m.l + pw, y1: yy, y2: yy, stroke: C.grid, "stroke-width": 1,
        "shape-rendering": "crispEdges",
      }));
      var tk = svgEl("text", { x: m.l - 8, y: yy + 4, "text-anchor": "end", fill: C.muted,
        "font-size": 11.5, "font-variant-numeric": "tabular-nums" });
      tk.textContent = fmt(gy, 0);
      svg.appendChild(tk);
    }
    var unit = svgEl("text", { x: m.l - 8, y: m.t - 12, "text-anchor": "end", fill: C.muted, "font-size": 11 });
    unit.textContent = "€/MWh";
    svg.appendChild(unit);

    // x ticks (MW)
    var xStep = niceStep(xMax, 6);
    for (var gx = 0; gx <= xMax + 1e-9; gx += xStep) {
      svg.appendChild(svgEl("line", {
        x1: X(gx), x2: X(gx), y1: m.t + ph, y2: m.t + ph + 4, stroke: C.muted, "stroke-width": 1,
      }));
      var xt = svgEl("text", { x: X(gx), y: m.t + ph + 18, "text-anchor": "middle", fill: C.muted,
        "font-size": 11.5, "font-variant-numeric": "tabular-nums" });
      xt.textContent = fmt(gx, 0);
      svg.appendChild(xt);
    }
    var xlab = svgEl("text", { x: m.l + pw, y: m.t + ph + 34, "text-anchor": "end", fill: C.muted, "font-size": 11 });
    xlab.textContent = "cumulative MW (ascending offer price)";
    svg.appendChild(xlab);

    // (The CLIFF band + the coupled TRADE WEDGE are painted in the TOP
    // annotation layer, AFTER the bars — see below — so their labels are never
    // hidden a layer behind the ladder.)

    // supply blocks (fuel-coloured bars from 0 to their offer price)
    var tooltip = el("div", "tooltip");
    tooltip.style.display = "none";
    supply.forEach(function (o) {
      if (o.cum0 > xMax) return;
      var x0 = X(o.cum0), x1 = X(o.cum1);
      var w = Math.max(0.6, x1 - x0);
      var yTop = Y(o.price);
      var rect = svgEl("rect", {
        x: x0, y: yTop, width: w, height: (m.t + ph) - yTop,
        fill: ownerColor(o.owner, BC), "fill-opacity": 0.82,
        stroke: C.surface, "stroke-width": w > 2 ? 0.5 : 0, class: "book-block",
      });
      rect.addEventListener("pointerenter", function (ev) {
        tooltip.textContent = "";
        tooltip.appendChild(el("div", "tt-head", ownerLabel(o.owner)));
        [["offer", fmt(o.price, 2) + " €/MWh"], ["block", fmt(o.mw, 1) + " MW"],
         ["cumulative", fmt(o.cum1, 0) + " MW"]].forEach(function (r) {
          var row = el("div", "tt-row");
          row.appendChild(el("span", "tt-val", r[1]));
          row.appendChild(el("span", "tt-name", r[0]));
          tooltip.appendChild(row);
        });
        var rct = svg.getBoundingClientRect();
        var sc = rct.width / VBW;
        tooltip.style.display = "block";
        var left = (x0 + w + 8) * sc;
        if (left + tooltip.offsetWidth > rct.width) left = x0 * sc - tooltip.offsetWidth - 8;
        tooltip.style.left = Math.max(0, left) + "px";
        tooltip.style.top = Math.max(0, yTop * sc - 10) + "px";
      });
      rect.addEventListener("pointerleave", function () { tooltip.style.display = "none"; });
      svg.appendChild(rect);
    });

    // DEMAND curve overlay — the descending willingness-to-pay step from the
    // right (dashed, subtle). The book hides it by default, but a hour can clear
    // where a DEMAND bid crosses a vertical supply gap (the price is demand-set,
    // not supply-set); showing the curve makes that correct outcome legible.
    if (demand.length) {
      var dClamp = function (p) { return Math.min(p, yMax); };
      var dPts = [];
      demand.forEach(function (o) {
        if (o.cum0 > xMax) return;
        var dx0 = X(o.cum0), dx1 = X(Math.min(o.cum1, xMax)), dy = Y(dClamp(o.price));
        dPts.push(dx0 + " " + dy, dx1 + " " + dy);   // horizontal tread; the join adds the risers
      });
      if (dPts.length) {
        svg.appendChild(svgEl("path", {
          d: "M " + dPts.join(" L "), fill: "none", stroke: C.muted, "stroke-width": 1.6,
          "stroke-dasharray": "5 4", "stroke-opacity": 0.85, class: "book-demand-line",
        }));
        var dlab = svgEl("text", { x: X(0) + 4, y: Y(dClamp(demand[0].price)) - 5,
          "text-anchor": "start", fill: C.muted, "font-size": 10.5, "font-weight": 600 });
        dlab.textContent = "demand";
        svg.appendChild(dlab);
        // per-tread hit-lines for tooltips (like the supply blocks)
        demand.forEach(function (o) {
          if (o.cum0 > xMax) return;
          var dx0 = X(o.cum0), dx1 = X(Math.min(o.cum1, xMax)), dy = Y(dClamp(o.price));
          var hit = svgEl("line", { x1: dx0, x2: dx1, y1: dy, y2: dy, stroke: "transparent",
            "stroke-width": 11, class: "book-demand-hit" });
          hit.addEventListener("pointerenter", function () {
            tooltip.textContent = "";
            tooltip.appendChild(el("div", "tt-head", "demand · " + ownerLabel(o.owner)));
            [["bid", fmt(o.price, 2) + " €/MWh"], ["block", fmt(o.mw, 1) + " MW"],
             ["cumulative", fmt(o.cum1, 0) + " MW"]].forEach(function (r) {
              var row = el("div", "tt-row");
              row.appendChild(el("span", "tt-val", r[1]));
              row.appendChild(el("span", "tt-name", r[0]));
              tooltip.appendChild(row);
            });
            var rct = svg.getBoundingClientRect(), sc = rct.width / VBW;
            tooltip.style.display = "block";
            var left = (dx1 + 8) * sc;
            if (left + tooltip.offsetWidth > rct.width) left = dx0 * sc - tooltip.offsetWidth - 8;
            tooltip.style.left = Math.max(0, left) + "px";
            tooltip.style.top = Math.max(0, dy * sc - 10) + "px";
          });
          hit.addEventListener("pointerleave", function () { tooltip.style.display = "none"; });
          svg.appendChild(hit);
        });
      }
    }

    // ======== TOP ANNOTATION LAYER (painted AFTER the bars) ==============
    // A haloed label: a surface-coloured stroke behind the fill so text stays
    // legible over bars / the shaded band (z-order fix — annotations sit ON TOP).
    function haloText(attrs, txt) {
      var t = svgEl("text", Object.assign({
        "paint-order": "stroke", stroke: C.surface, "stroke-width": 3,
        "stroke-linejoin": "round",
      }, attrs));
      t.textContent = txt;
      svg.appendChild(t);
      return t;
    }

    // CLIFF band — now a TOP-LAYER annotation (was a layer behind the bars):
    // the shaded ±W window + the implied price-range guides + the span label,
    // all painted over the ladder so nothing hides them.
    if (clearing !== null && clearing !== undefined) {
      var bandX0 = X(Math.max(0, clearMW - CLIFF.W_PRIMARY));
      var bandX1 = X(clearMW + CLIFF.W_PRIMARY);
      svg.appendChild(svgEl("rect", {
        x: bandX0, y: m.t, width: Math.max(1, bandX1 - bandX0), height: ph,
        fill: C.sim, "fill-opacity": isCliff ? 0.12 : 0.06, class: "book-cliff-band",
        "pointer-events": "none",
      }));
      var pr = cliffByW[CLIFF.W_PRIMARY];
      [pr.lo, pr.hi].forEach(function (pp) {
        if (pp <= yMax) svg.appendChild(svgEl("line", {
          x1: bandX0, x2: bandX1, y1: Y(pp), y2: Y(pp), stroke: C.sim,
          "stroke-width": 1, "stroke-opacity": 0.6, "stroke-dasharray": "2 3",
        }));
      });
      var yLoC = Math.min(Y(Math.min(pr.lo, yMax)), m.t + ph);
      var yHiC = Y(Math.min(pr.hi, yMax));
      if (pr.span > 0.5 && pr.hi <= yMax * 1.02) {
        svg.appendChild(svgEl("line", {
          x1: bandX1, x2: bandX1, y1: yHiC, y2: yLoC, stroke: C.sim,
          "stroke-width": 1.5, "stroke-opacity": 0.8,
        }));
        // Anti-collision: the span label sits BELOW the clearing line, centered
        // under the band near the marker (its natural place) — off the crowded
        // clearing-price band where the trade-wedge and 'clearing €X' labels live.
        var clrY = Y(Math.min(clearing, yMax));
        haloText({ x: X(clearMW), y: Math.min(m.t + ph - 4, clrY + 15), "text-anchor": "middle",
          fill: C.sim, "font-size": 10.5, "font-weight": 600 },
          "±" + CLIFF.W_PRIMARY + " MW ⇒ €" + fmt(pr.span, 0));
      }
    }

    // COUPLED TRADE WEDGE — the gap between the marker (local supply cleared at
    // the coupled price P) and where local demand crosses P, at the P level.
    // When per-border flows are loaded (record days) it is a stacked mini-ladder
    // of import SOURCES ordered by the neighbour's price; otherwise an anonymous
    // net brace. Exports mirror to the left. Hidden when |net| is negligible.
    if (impliedNetImport !== null && Math.abs(impliedNetImport) >= CLIFF.TRADE_MIN_MW) {
      var isImport = impliedNetImport > 0;
      var wy = Y(Math.min(clearing, yMax));            // the clearing-price level
      var xNear = X(clearMW);
      var xFar = X(clearMW + impliedNetImport);        // demand-crossing side
      var segs = tradeSegments(state.zone, fday.hours[hourIdx], impliedNetImport);
      // brace baseline at the P level, marker → demand-crossing
      svg.appendChild(svgEl("line", { x1: xNear, x2: xFar, y1: wy, y2: wy,
        stroke: BC.trade, "stroke-width": 2, "stroke-opacity": 0.9 }));
      [xNear, xFar].forEach(function (xe) {
        svg.appendChild(svgEl("line", { x1: xe, x2: xe, y1: wy - 5, y2: wy + 5,
          stroke: BC.trade, "stroke-width": 2 }));
      });
      // stacked source segments (each a coloured band on the brace), laid out
      // PROPORTIONALLY across the wedge span so the stack fills [xNear, xFar]
      // exactly even when the solved-flow MW don't sum to the book-implied net.
      if (segs && segs.length) {
        var sumMW = segs.reduce(function (a, s) { return a + s.mw; }, 0) || 1;
        var runX = xNear;
        segs.forEach(function (s) {
          var wpx = (xFar - xNear) * (s.mw / sumMW);   // signed share of the span
          var sx0 = runX, sx1 = runX + wpx; runX = sx1;
          var xa = Math.min(sx0, sx1), xb = Math.max(sx0, sx1);
          svg.appendChild(svgEl("rect", { x: xa, y: wy - 5, width: Math.max(1, xb - xa),
            height: 10, fill: s.fixed ? C.muted : BC.trade,
            "fill-opacity": s.fixed ? 0.35 : 0.28,
            stroke: BC.trade, "stroke-width": 0.5, "stroke-opacity": 0.6 }));
        });
      }
      // hatched fill under the brace to read as a wedge
      var wx0 = Math.min(xNear, xFar), wx1 = Math.max(xNear, xFar);
      svg.appendChild(svgEl("rect", { x: wx0, y: wy, width: Math.max(1, wx1 - wx0),
        height: Math.min(18, (m.t + ph) - wy), fill: "url(#wedgeHatch)",
        "pointer-events": "none" }));
      // label: sources when known, else anonymous net — placed ABOVE the
      // clearing line (~1.2em up) with a short leader tick down to the wedge, so
      // it never overlaps the 'clearing €X' / cliff-span labels sharing that
      // horizontal band. When the marker sits close to the right edge (tight
      // horizontal room) it collapses to a compact "← X MW", full text on hover.
      var srcTxt = (segs && segs.length)
        ? segs.map(function (s) { return s.label; }).join(" · ")
        : "via coupling";
      var fullLabel = (isImport ? "← imports ~" : "exports → ") +
        fmt(Math.abs(impliedNetImport), 0) + " MW  (" + srcTxt + ")";
      var shortLabel = (isImport ? "← " : "→ ") + fmt(Math.abs(impliedNetImport), 0) + " MW";
      var tight = ((m.l + pw) - xNear) < 0.30 * pw;
      var labelX = (wx0 + wx1) / 2, labelY = Math.max(m.t + 10, wy - 16);
      svg.appendChild(svgEl("line", { x1: labelX, x2: labelX, y1: labelY + 3, y2: wy,
        stroke: BC.trade, "stroke-width": 1, "stroke-opacity": 0.6 }));
      var wtext = haloText({ x: labelX, y: labelY, "text-anchor": "middle",
        fill: BC.trade, "font-size": 10.5, "font-weight": 600 },
        tight ? shortLabel : fullLabel);
      var wtitle = svgEl("title"); wtitle.textContent = fullLabel; wtext.appendChild(wtitle);
    }

    // clearing price line + "ball" where the ladder reaches it. `halo` gives the
    // right-edge label a surface-coloured background so it wins overlaps on the
    // crowded clearing-price band (theme-aware, via haloText).
    function marker(price, color, label, dash, halo) {
      if (price === null || price === undefined) return;
      var yy = Y(price);
      svg.appendChild(svgEl("line", {
        x1: m.l, x2: m.l + pw, y1: yy, y2: yy, stroke: color, "stroke-width": 2,
        "stroke-dasharray": dash || null,
      }));
      var attrs = { x: m.l + pw - 4, y: yy - 5, "text-anchor": "end",
        fill: color, "font-size": 12, "font-weight": 600 };
      if (halo) {
        haloText(attrs, label + " €" + fmt(price, 1));
      } else {
        var t = svgEl("text", attrs);
        t.textContent = label + " €" + fmt(price, 1);
        svg.appendChild(t);
      }
    }
    marker(actual, C.act, "actual", null, false);
    marker(clearing, C.sim, "clearing", "7 4", true);
    // clearing "ball" where the ladder reaches the model price.
    if (clearing !== null && clearing !== undefined) {
      var bx = X(clearMW), by = Y(clearing);
      svg.appendChild(svgEl("line", {
        x1: bx, x2: bx, y1: by, y2: m.t + ph, stroke: C.sim, "stroke-width": 1.5, "stroke-dasharray": "3 4",
      }));
      svg.appendChild(svgEl("circle", { cx: bx, cy: by, r: 6, fill: C.sim, stroke: C.surface, "stroke-width": 2 }));
    }
    // settled-price "ball" where OUR ladder reaches the settled price — the
    // implied ACTUAL quantity (ΔQ endpoint).
    if (settledMW !== null) {
      var sx = X(settledMW), sy = Y(Math.min(actual, yMax));
      svg.appendChild(svgEl("line", {
        x1: sx, x2: sx, y1: sy, y2: m.t + ph, stroke: C.act, "stroke-width": 1.5, "stroke-dasharray": "3 4",
      }));
      svg.appendChild(svgEl("circle", { cx: sx, cy: sy, r: 5, fill: C.act, stroke: C.surface, "stroke-width": 2 }));
    }

    // ---- dual MW markers on the x-axis + the ΔQ bracket ------------------
    // Mark BOTH quantities on the cumulative-MW axis: what the model predicted
    // (where the μπίλια sits) and the implied ACTUAL point (our book's cum-MW at
    // the settled price). The dashed droplines from the two balls already reach
    // the axis at exactly clearMW / settledMW; here we add the labels + a bracket
    // between them that IS the ΔQ readout ("we were only X MW off in energy").
    // Markers MERGE gracefully on plateau hours (the two points ~coincide).
    if (clearing !== null && clearing !== undefined) {
      var axY = m.t + ph;
      var mx = X(clearMW);
      function clampX(xx, txt) {
        var half = txt.length * 3.0;
        return Math.min(Math.max(xx, m.l + half), m.l + pw - half);
      }
      function mwLabel(xx, yrow, color, txt) {
        var tt = svgEl("text", { x: clampX(xx, txt), y: yrow, "text-anchor": "middle",
          fill: color, "font-size": 11, "font-weight": 600,
          "font-variant-numeric": "tabular-nums" });
        tt.textContent = txt;
        svg.appendChild(tt);
      }
      var merged = settledMW !== null && Math.abs(X(settledMW) - mx) < CLIFF.MERGE_PX;
      if (settledMW === null || merged) {
        mwLabel(mx, axY + 50, C.sim, "model: " + fmt(clearMW, 0) + " MW" +
          (merged ? " (settled ~same)" : ""));
      } else {
        var sxx = X(settledMW);
        // ΔQ bracket (top-opening ∏) below the axis-label row, joining the two
        // droplines; the span between the markers is the MW-distance to settled.
        var bBar = axY + 44;
        svg.appendChild(svgEl("path", {
          d: "M " + mx + " " + (bBar - 6) + " L " + mx + " " + bBar +
             " L " + sxx + " " + bBar + " L " + sxx + " " + (bBar - 6),
          fill: "none", stroke: C.act, "stroke-width": 1.5, "stroke-opacity": 0.9,
        }));
        mwLabel((mx + sxx) / 2, bBar + 12, C.act, "ΔQ " + fmt(Math.abs(dQ), 0) + " MW");
        mwLabel(mx, axY + 70, C.sim, "model: " + fmt(clearMW, 0) + " MW");
        mwLabel(sxx, axY + 84, C.act, "at settled €" + fmt(actual, 1) + ": " + fmt(settledMW, 0) + " MW");
      }
    }

    wrap.appendChild(svg);
    wrap.appendChild(tooltip);

    // legend: FUEL families (+ non-fuel tags) present in the visible window,
    // by MW — the consistent palette the slices use. Aggregates fold into their
    // fuel family; tags stay distinct.
    var byKey = {};   // legendKey -> {mw, color, icon, label, isTag}
    supply.forEach(function (o) {
      if (o.cum0 > xMax) return;
      var info = ownerInfo(o.owner);
      var key, color, icon, label, isTag;
      if (info.kind === "tag") {
        key = "tag:" + o.owner; color = BC.tag[info.tagCss] || "#8892A0";
        icon = info.icon; label = info.name; isTag = true;
      } else {
        key = "fuel:" + info.fam; color = BC.fuel[info.fam] || BC.fuel.other;
        icon = info.icon; label = FUEL_FAM_LABEL[info.fam] || info.fam; isTag = false;
      }
      if (!byKey[key]) byKey[key] = { mw: 0, color: color, icon: icon, label: label, isTag: isTag };
      byKey[key].mw += o.mw;
    });
    var order = Object.keys(byKey).sort(function (a, b) { return byKey[b].mw - byKey[a].mw; });
    var lg = $("book-legend");
    lg.textContent = "";
    order.forEach(function (k) {
      var it = byKey[k];
      var span = el("span", it.isTag ? "book-tagkey" : null);
      var key = el("span", "key");
      key.style.background = it.color;
      key.style.borderTopColor = it.color;
      span.appendChild(key);
      span.appendChild(document.createTextNode(
        it.icon + " " + it.label + " · " + fmt(it.mw, 0) + " MW"));
      lg.appendChild(span);
    });
    // demand-curve key (the dashed descending overlay)
    if (demand.length) {
      var dspan = el("span", "book-tagkey");
      var dkey = el("span", "key book-demand-key");
      dkey.style.background = "transparent";
      dkey.style.borderTopColor = C.muted;
      dspan.appendChild(dkey);
      dspan.appendChild(document.createTextNode("⬇ demand curve"));
      lg.appendChild(dspan);
    }

    // ---- commentary + CLIFF badge ---------------------------------------
    var cp = $("book-comment");
    cp.textContent = "";
    var marginal = null;
    supply.forEach(function (o) { if (marginal === null && o.cum1 >= clearMW) marginal = o; });
    // Demand-set price: the clearing coincides with a DEMAND bid inside a supply
    // GAP (not within ε of the marginal supply offer) — a demand bid crosses the
    // vertical supply segment. Attribute the price to that demand bid, not to the
    // nearest supply unit (which would misattribute the hour).
    var PRICE_EPS = 0.5;
    var setByDemand = null;
    if (clearing !== null && clearing !== undefined) {
      var supplySets = marginal && Math.abs(marginal.price - clearing) <= PRICE_EPS;
      if (!supplySets) {
        demand.forEach(function (o) {
          if (setByDemand === null && Math.abs(o.price - clearing) <= PRICE_EPS) setByDemand = o;
        });
      }
    }

    // badge: cliff vs plateau (display heuristic; thresholds in the tooltip)
    var badge = el("span", "cliff-badge " + (isCliff ? "is-cliff" : "is-plateau"));
    badge.textContent = (isCliff ? "⚠ cliff hour" : "▬ plateau hour") +
      " · ±" + CLIFF.W_PRIMARY + " MW ⇒ €" + fmt(primarySpan, 0);
    badge.title =
      "Cliff index = the €/MWh price span of the supply book within ±" +
      CLIFF.W_PRIMARY + " MW of the clearing quantity (windows: " +
      CLIFF.WINDOWS.map(function (W) { return "±" + W + " MW ⇒ €" + fmt(cliffByW[W].span, 0); }).join(", ") +
      "). Above €" + CLIFF.SPAN_CLIFF + " ⇒ a CLIFF: the ladder is near-vertical here, " +
      "so a small input error (a little more/less demand, wind or solar) explodes " +
      "into a large price error. These near-threshold discontinuity hours are where " +
      "input precision matters most (the collapse-question family). Display heuristic, " +
      "not a scored metric.";
    cp.appendChild(badge);

    var txt = " Cleared around " + fmt(clearMW, 0) + " MW of " + fmt(totalMW, 0) + " MW offered. ";
    if (clearing !== null && clearing !== undefined) {
      txt += "Model clearing €" + fmt(clearing, 1) + "/MWh";
      if (setByDemand) {
        txt += ", set by demand bid €" + fmt(setByDemand.price, 1) + " (" +
          ownerLabel(setByDemand.owner) + ") crossing a supply gap";
      } else if (marginal) {
        txt += ", set near " + ownerLabel(marginal.owner) + " (offer €" + fmt(marginal.price, 1) + ")";
      }
      txt += ".";
    }
    if (actual !== null && actual !== undefined) {
      var dP = clearing - actual;
      txt += " Model " + (dP >= 0 ? "+" : "") + fmt(dP, 1) + " €/MWh vs settled €" +
        fmt(actual, 1);
      if (dQ !== null) {
        txt += ", but only " + fmt(Math.abs(dQ), 0) + " MW off in energy" +
          (isCliff ? " — a cliff hour: the €-error is a book discontinuity, not a volume miss." : ".");
      } else {
        txt += ".";
      }
    } else {
      txt += " Actual not yet settled — ex-ante cliff index above.";
    }
    cp.appendChild(document.createTextNode(txt));

    // coupled trade balance: generation + imports = demand (identity), with the
    // per-source breakdown when the solved flows are loaded (record days).
    if (impliedNetImport !== null && Math.abs(impliedNetImport) >= CLIFF.TRADE_MIN_MW) {
      var segs2 = tradeSegments(state.zone, fday.hours[hourIdx], impliedNetImport);
      var brk = segs2 && segs2.length ? " (" + segs2.map(function (s) { return s.label; }).join(" · ") + ")" : "";
      var tradeSpan = el("span", "trade-note");
      tradeSpan.title =
        "In a coupled hour the zonal price is set MARKET-WIDE by the 39-zone clear; " +
        "local supply∩demand is NOT the clearing condition. The marker sits on the " +
        "local supply curve at the coupled price — the gap to local demand is " +
        "cross-border trade (flow variables, absent from this local ladder). " +
        (segs2 && segs2.length
          ? "Sources from the solved flows; ‘(fixed)’ is the out-of-footprint injection residual."
          : "Per-source breakdown appears on record/backfill days (the daily forecast run does not persist flows yet).");
      if (impliedNetImport > 0) {
        tradeSpan.textContent = " Coupled balance: generation " + fmt(clearMW, 0) +
          " + imports " + fmt(impliedNetImport, 0) + brk + " = demand " + fmt(demandAtClear, 0) + " MW.";
      } else {
        tradeSpan.textContent = " Coupled balance: generation " + fmt(clearMW, 0) +
          " − exports " + fmt(-impliedNetImport, 0) + brk + " = demand " + fmt(demandAtClear, 0) + " MW.";
      }
      cp.appendChild(tradeSpan);
    }
  }

  // ---------- footer ----------

  function humanizeAgo(iso) {
    var ms = Date.now() - new Date(iso).getTime();
    if (!isFinite(ms)) return null;
    var min = Math.round(ms / 60000);
    if (min < 1) return "just now";
    if (min < 60) return min + " min ago";
    var h = Math.round(min / 60);
    if (h < 48) return h + " h ago";
    return Math.round(h / 24) + " days ago";
  }

  function renderFooter() {
    var sb = state.scoreboard;
    if (!sb) return;   // manifest may arrive before the scoreboard
    var bits = [];
    if (sb.generated_utc) bits.push("generated " + sb.generated_utc.replace("T", " ").replace("Z", " UTC"));
    if (sb.code_version !== undefined) bits.push("code_version " + sb.code_version);
    bits.push("source: " + (state.source === "api" ? "live data API" :
      state.source === "data" ? "exported model results" : "bundled fixtures"));
    // Freshness badge — only when the API rung actually served the data.
    if (state.source === "api" && state.manifest && state.manifest.updated_at) {
      var ago = humanizeAgo(state.manifest.updated_at);
      if (ago) bits.push("data updated " + ago);
    }
    $("footer-meta").textContent = bits.join(" · ");
  }

  // ---------- wiring ----------

  function selectZone(zone, keepDay) {
    state.zone = zone;
    if (!keepDay) { state.day = null; state.revDay = null; state.bookDay = null; }
    state.hoverIdx = null;
    stopBookPlay();
    $("zone-select").value = zone;
    $("hzone-select").value = zone;
    if ($("bzone-select")) $("bzone-select").value = zone;
    loadZone(zone).then(function () {
      renderExplorer();
      renderHorizon();
      if (state.view === "book") renderBook();
      writeHash();
    }).catch(function (err) {
      $("chart-title").textContent = zone + " — failed to load zone data";
      $("chart-sub").textContent = String(err);
      $("chart-wrap").textContent = "";
      $("day-list").textContent = "";
      $("day-stats").textContent = "";
      $("chart-legend").textContent = "";
      $("hour-table").textContent = "";
    });
  }

  function applyHash() {
    readHash();
    setView(state.view);
    if (state.scoreboard) {
      if (state.scoreboard.zones.indexOf(state.zone) === -1) state.zone = state.scoreboard.zones[0];
      $("zone-select").value = state.zone;
      renderWindowSelect();
      renderScoreboard();
      selectZone(state.zone, true);
    }
  }

  function init() {
    document.querySelectorAll(".tab").forEach(function (t) {
      t.addEventListener("click", function () {
        setView(t.dataset.view);
        writeHash();
      });
    });
    $("zone-select").addEventListener("change", function (ev) {
      selectZone(ev.target.value);
    });
    $("hzone-select").addEventListener("change", function (ev) {
      selectZone(ev.target.value);
    });
    $("map-day-slider").addEventListener("input", function (ev) {
      mapState.dayIdx = +ev.target.value;
      renderMap();
    });
    if ($("bzone-select")) {
      $("bzone-select").addEventListener("change", function (ev) { selectZone(ev.target.value, true); state.bookDay = null; renderBook(); });
    }
    $("book-hour-slider").addEventListener("input", function (ev) {
      stopBookPlay();
      state.bookHour = +ev.target.value;
      var zoneData = state.zoneCache[state.zone];
      var days = zoneData ? freshestByDate(weatherDays(zoneData)) : [];
      var fday = null;
      days.forEach(function (d) { if (!fday && d.date === state.bookDay) fday = d; });
      var book = state.bookCache[state.zone + "|" + state.bookDay];
      if (book && fday) renderBookLadder(book, fday, state.bookHour);
      writeHash();
    });
    $("book-play").addEventListener("click", function () {
      if (bookPlayTimer) { stopBookPlay(); return; }
      var slider = $("book-hour-slider");
      var nH = (+slider.max) + 1;
      $("book-play").textContent = "❚❚ Pause";
      bookPlayTimer = setInterval(function () {
        var zoneData = state.zoneCache[state.zone];
        var days = zoneData ? freshestByDate(weatherDays(zoneData)) : [];
        var fday = null;
        days.forEach(function (d) { if (!fday && d.date === state.bookDay) fday = d; });
        var book = state.bookCache[state.zone + "|" + state.bookDay];
        if (!book || !fday) { stopBookPlay(); return; }
        state.bookHour = (state.bookHour + 1) % nH;
        slider.value = state.bookHour;
        renderBookLadder(book, fday, state.bookHour);
      }, 750);
    });
    $("window-select").addEventListener("change", function (ev) {
      state.window = ev.target.value;
      renderScoreboard();
      writeHash();
    });
    var methodLink = $("predict-method-link");
    if (methodLink) methodLink.addEventListener("click", function (ev) {
      ev.preventDefault();
      var t = $("predict-method");
      if (t) t.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    window.addEventListener("hashchange", function () {
      if (!suppressHash) applyHash();
    });
    document.querySelectorAll(".editor .copy-btn").forEach(function (b) {
      b.addEventListener("click", function () {
        var code = b.closest(".editor").querySelector("code");
        navigator.clipboard.writeText(code.textContent).then(function () {
          b.textContent = "copied";
          setTimeout(function () { b.textContent = "copy"; }, 1200);
        });
      });
    });

    loadWithFallback("scoreboard.json").then(function (res) {
      state.scoreboard = res.json;
      state.source = res.source;
      if (res.json.fixture) setFixtureBanner(true);

      readHash();
      if (state.scoreboard.zones.indexOf(state.zone) === -1) {
        state.zone = state.scoreboard.zones.indexOf("GR") !== -1 ? "GR" : state.scoreboard.zones[0];
      }
      setView(state.view);
      renderZoneSelect();
      renderWindowSelect();
      renderScoreboard();
      renderFooter();
      selectZone(state.zone, true);
    }).catch(function (err) {
      var box = $("load-error");
      box.hidden = false;
      box.textContent =
        "Could not load results data (" + err + "). Expected the live API or the " +
        "bundled ./fixtures/scoreboard.json. Serve this directory with a static " +
        "file server, e.g.: python3 -m http.server --directory web";
    });
  }

  init();
})();
