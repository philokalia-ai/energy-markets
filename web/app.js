/* Euphemia results browser — plain JS, no build step, no external requests.
 * Data contract:
 *   ./data/scoreboard.json   (fallback ./fixtures/scoreboard.json)
 *   ./data/zones/<ZONE>.json (fallback ./fixtures/zones/<ZONE>.json)
 */
(function () {
  "use strict";

  var BASES = ["./data", "./fixtures"];
  var SVGNS = "http://www.w3.org/2000/svg";

  var state = {
    scoreboard: null,
    source: null,          // "data" | "fixtures"
    fixture: false,
    zoneCache: {},         // zone -> zone file json
    view: "horizon",       // "horizon" | "explorer" | "board"
    zone: "GR",
    lead: null,            // number
    day: null,             // "YYYY-MM-DD"
    revDay: null,          // "YYYY-MM-DD" selected in the revision panel
    window: "all",
    sort: { lead: null, metric: "mae", dir: 1 }, // dir 1 = best first
    hoverIdx: null,
  };

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

  // Try ./data first, fall back to ./fixtures.
  function loadWithFallback(rel) {
    return fetchJSON(BASES[0] + "/" + rel).then(
      function (j) { return { json: j, source: "data" }; },
      function () {
        return fetchJSON(BASES[1] + "/" + rel).then(function (j) {
          return { json: j, source: "fixtures" };
        });
      }
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
    if (["board", "explorer", "horizon", "map"].indexOf(params.view) !== -1) state.view = params.view;
    if (params.zone) state.zone = params.zone;
    if (params.lead && !isNaN(+params.lead)) state.lead = +params.lead;
    if (params.day && /^\d{4}-\d{2}-\d{2}$/.test(params.day)) state.day = params.day;
    if (params.rev && /^\d{4}-\d{2}-\d{2}$/.test(params.rev)) state.revDay = params.rev;
    if (params.metric && ["sim", "act", "err"].indexOf(params.metric) !== -1) mapState.metric = params.metric;
    if (params.window) state.window = params.window;
  }

  var suppressHash = false;
  function writeHash() {
    var parts = ["view=" + state.view, "zone=" + encodeURIComponent(state.zone)];
    if (state.lead !== null) parts.push("lead=" + state.lead);
    if (state.day) parts.push("day=" + state.day);
    if (state.revDay) parts.push("rev=" + state.revDay);
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

  function zoneDays(zoneData, lead) {
    return zoneData.days.filter(function (d) { return d.lead_days === lead; });
  }

  function zoneLeads(zoneData) {
    var seen = {};
    zoneData.days.forEach(function (d) { seen[d.lead_days] = true; });
    return Object.keys(seen).map(Number).sort(function (a, b) { return a - b; });
  }

  // ---------- fixture banner ----------

  function setFixtureBanner(on) {
    if (on) state.fixture = true;
    $("fixture-banner").hidden = !state.fixture;
  }

  // ---------- view switching ----------

  function setView(v) {
    state.view = v;
    $("view-explorer").hidden = v !== "explorer";
    $("view-board").hidden = v !== "board";
    $("view-horizon").hidden = v !== "horizon";
    $("view-map").hidden = v !== "map";
    if (v === "map") loadMap().then(renderMap);
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
    ["zone-select", "hzone-select"].forEach(function (id) {
      var sel = $(id);
      sel.textContent = "";
      zones.forEach(function (z) {
        var o = el("option", null, z);
        o.value = z;
        sel.appendChild(o);
      });
      sel.value = state.zone;
    });
  }

  function renderLeadButtons(leads) {
    var wrap = $("lead-filter");
    var box = $("lead-buttons");
    box.textContent = "";
    wrap.hidden = leads.length < 2;
    leads.forEach(function (l) {
      var b = el("button", null, l === 1 ? "D-1" : "D-" + l);
      b.type = "button";
      b.setAttribute("aria-pressed", String(l === state.lead));
      b.addEventListener("click", function () {
        if (state.lead === l) return;
        state.lead = l;
        state.hoverIdx = null;
        renderExplorer();
        writeHash();
      });
      box.appendChild(b);
    });
  }

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
    items.forEach(function (it) {
      var span = el("span");
      var key = el("span", "key " + it[0]);
      key.setAttribute("aria-hidden", "true");
      span.appendChild(key);
      span.appendChild(document.createTextNode(it[1]));
      lg.appendChild(span);
    });
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
    var simPath = svgEl("path", {
      d: pathFor(day.sim), fill: "none", stroke: C.sim,
      "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
    });
    svg.appendChild(simPath);
    var actD = pathFor(day.actual);
    if (actD) {
      svg.appendChild(svgEl("path", {
        d: actD, fill: "none", stroke: C.act,
        "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
      }));
      // lone realized points (no neighbors) would be invisible in a path
      for (var k = 0; k < n; k++) {
        var a = day.actual[k];
        if (a === null || a === undefined) continue;
        var prev = k > 0 ? day.actual[k - 1] : null;
        var next = k < n - 1 ? day.actual[k + 1] : null;
        if ((prev === null || prev === undefined) && (next === null || next === undefined)) {
          svg.appendChild(svgEl("circle", {
            cx: X(k), cy: Y(a), r: 4, fill: C.act, stroke: C.surface, "stroke-width": 2,
          }));
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
  }

  function renderExplorer() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) return;

    var leads = zoneLeads(zoneData);
    if (state.lead === null || leads.indexOf(state.lead) === -1) state.lead = leads[0];
    renderLeadButtons(leads);

    var days = zoneDays(zoneData, state.lead);
    if (!days.length) {
      $("day-list").textContent = "";
      $("chart-title").textContent = state.zone + " — no days available";
      $("chart-wrap").textContent = "";
      return;
    }
    var found = days.some(function (d) { return d.date === state.day; });
    if (!state.day || !found) state.day = days[0].date;

    renderDayList(days);
    var day = null;
    days.forEach(function (d) { if (d.date === state.day) day = d; });

    $("chart-title").textContent = state.zone + " — " + dayLabel(day.date);
    var madeAt = day.prediction_made_utc
      ? " · prediction frozen " + day.prediction_made_utc.replace("T", " ").replace("Z", " UTC")
      : "";
    $("chart-sub").textContent =
      "Lead time D-" + day.lead_days + madeAt +
      " · hours shown in Europe/Athens (market day)";
    renderDayStats(day);
    renderDayComment(day);
    renderLegend(day);
    renderChart(day);
    renderHourTable(day);
  }

  // ---------- horizon (next 7 days) + revision panel ----------

  // Opacity by data age: fresh D-1 fully saturated, D-7 faint.
  function leadOpacity(lead) {
    return Math.max(0.3, 1 - (lead - 1) * 0.11);
  }

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

  // Days grouped by date with the freshest (lowest-lead) entry per date.
  function futureDays(zoneData) {
    var byDate = {};
    zoneData.days.forEach(function (d) {
      if (!isPending(d)) return;                     // horizon = unsettled days only
      var cur = byDate[d.date];
      if (!cur || d.lead_days < cur.lead_days) byDate[d.date] = d;
    });
    return Object.keys(byDate).sort().map(function (k) { return byDate[k]; }).slice(0, 8);
  }

  function renderHorizon() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) return;
    var days = futureDays(zoneData);
    $("hz-title").textContent = state.zone + " — the next " + (days.length || 7) + " market days";
    var wrap = $("hz-wrap");
    wrap.textContent = "";
    var lg = $("hz-legend");
    lg.textContent = "";

    if (!days.length) {
      $("hz-sub").textContent = "";
      wrap.appendChild(el("p", "pending-note",
        "No unsettled forecast days available yet — the horizon fills as the daily runs accumulate."));
      renderRevisions();
      return;
    }
    $("hz-sub").textContent =
      "Freshest published prediction per delivery day · solid = next-day model forecast (D-1), " +
      "faded = further out · hours in Europe/Athens";

    // legend
    [["1", "D-1 (model, frozen the evening before)"],
     ["4", "D-2…D-7 (weekly persistence of the model — fades with age)"]].forEach(function (it) {
      var span = el("span");
      var key = el("span", "key sim");
      key.style.opacity = leadOpacity(+it[0]);
      key.setAttribute("aria-hidden", "true");
      span.appendChild(key);
      span.appendChild(document.createTextNode(it[1]));
      lg.appendChild(span);
    });

    // concatenated point list
    var pts = [];   // {iso, v, day}
    days.forEach(function (d) {
      d.hours.forEach(function (h, i) {
        pts.push({ iso: h, v: d.sim[i], day: d });
      });
    });
    var n = pts.length;
    var sc = chartScaffold(wrap, pts.map(function (p) { return p.v; }), n,
      "Hourly price forecast for the next " + days.length + " market days, " + state.zone);
    var svg = sc.svg, X = sc.X, Y = sc.Y, C = sc.C, m = sc.m;

    // day separators + weekday labels
    var idx0 = 0;
    days.forEach(function (d) {
      var idx1 = idx0 + d.hours.length - 1;
      if (idx0 > 0) {
        svg.appendChild(svgEl("line", {
          x1: X(idx0) , x2: X(idx0), y1: m.t, y2: m.t + sc.ph,
          stroke: C.baseline, "stroke-width": 1, "stroke-dasharray": "3 4",
        }));
      }
      var lbl = svgEl("text", {
        x: (X(idx0) + X(idx1)) / 2, y: m.t + sc.ph + 18, "text-anchor": "middle",
        fill: C.muted, "font-size": 11.5,
      });
      lbl.textContent = dayLabel(d.date).slice(0, 3) + " " + d.date.slice(5);
      svg.appendChild(lbl);
      var lead = svgEl("text", {
        x: (X(idx0) + X(idx1)) / 2, y: m.t + sc.ph + 32, "text-anchor": "middle",
        fill: C.muted, "font-size": 10, "font-style": d.lead_days > 1 ? "italic" : "normal",
      });
      lead.textContent = "D-" + d.lead_days;
      svg.appendChild(lead);

      // per-day path with age fade
      var seg = pts.slice(idx0, idx1 + 1).map(function (p) { return p.v; });
      var Xoff = function (i) { return X(idx0 + i); };
      svg.appendChild(svgEl("path", {
        d: pathString(seg, Xoff, Y), fill: "none", stroke: C.sim,
        "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round",
        opacity: leadOpacity(d.lead_days),
      }));
      idx0 = idx1 + 1;
    });

    // hover
    var hoverLine = svgEl("line", { y1: m.t, y2: m.t + sc.ph, stroke: C.baseline, "stroke-width": 1, visibility: "hidden" });
    svg.appendChild(hoverLine);
    var dot = svgEl("circle", { r: 4.5, fill: C.sim, stroke: C.surface, "stroke-width": 2, visibility: "hidden" });
    svg.appendChild(dot);
    var overlay = svgEl("rect", {
      x: m.l, y: m.t, width: sc.pw, height: sc.ph, fill: "transparent",
      class: "hover-rect", tabindex: "0", "aria-label": "Forecast values across the horizon.",
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
      dot.setAttribute("cx", x); dot.setAttribute("cy", Y(p.v));
      dot.setAttribute("visibility", "visible");
      tooltip.textContent = "";
      tooltip.appendChild(el("div", "tt-head",
        dayLabel(p.day.date) + " · " + hourLabel(p.iso) + "–" + hourEndLabel(p.iso) + " Athens"));
      var row = el("div", "tt-row");
      var key = el("span", "tt-key");
      key.style.borderTopColor = C.sim;
      row.appendChild(key);
      row.appendChild(el("span", "tt-val", fmt(p.v, 2)));
      row.appendChild(el("span", "tt-name", "forecast (D-" + p.day.lead_days + ")"));
      tooltip.appendChild(row);
      var rect = svg.getBoundingClientRect();
      var scale = rect.width / sc.VBW;
      var px = x * scale, tw;
      tooltip.style.display = "block";
      tw = tooltip.offsetWidth;
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
      dot.setAttribute("visibility", "hidden");
      tooltip.style.display = "none";
    });

    renderRevisions();
  }

  // Revision panel: every vintage we published for one delivery day.
  function renderRevisions() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) return;
    var byDate = {};
    zoneData.days.forEach(function (d) {
      (byDate[d.date] = byDate[d.date] || []).push(d);
    });
    // days worth showing: newest 14 (future first for defaults)
    var dates = Object.keys(byDate).sort().slice(-14);
    var wrap = $("rev-wrap");
    var lg = $("rev-legend");
    var btns = $("rev-daybtns");
    wrap.textContent = ""; lg.textContent = ""; btns.textContent = "";
    if (!dates.length) {
      $("rev-title").textContent = "What we said, when";
      return;
    }
    if (!state.revDay || dates.indexOf(state.revDay) === -1) {
      // default: tomorrow-most future day with >1 vintage, else newest
      var multi = dates.filter(function (dd) { return byDate[dd].length > 1; });
      state.revDay = multi.length ? multi[multi.length - 1] : dates[dates.length - 1];
    }
    dates.forEach(function (dd) {
      var b = el("button", null, dd.slice(5));
      b.type = "button";
      b.title = dayLabel(dd) + " · " + byDate[dd].length + " vintage" + (byDate[dd].length > 1 ? "s" : "");
      b.setAttribute("aria-pressed", String(dd === state.revDay));
      b.addEventListener("click", function () {
        state.revDay = dd;
        renderRevisions();
        writeHash();
      });
      btns.appendChild(b);
    });

    var entries = byDate[state.revDay].slice().sort(function (a, b) { return b.lead_days - a.lead_days; });
    var newest = entries[entries.length - 1];
    $("rev-title").textContent = "What we said, when — " + state.zone + " · " + dayLabel(state.revDay);

    var C = chartColors();
    // legend: one chip per vintage + actual
    entries.forEach(function (d) {
      var span = el("span");
      var key = el("span", "key sim");
      key.style.opacity = leadOpacity(d.lead_days);
      span.appendChild(key);
      span.appendChild(document.createTextNode("D-" + d.lead_days));
      lg.appendChild(span);
    });
    var hasActual = !isPending(newest);
    if (hasActual) {
      var span = el("span");
      span.appendChild(el("span", "key act"));
      span.appendChild(document.createTextNode("Actual (settled)"));
      lg.appendChild(span);
    }

    // values pool for scale
    var vals = [];
    entries.forEach(function (d) { d.sim.forEach(function (v) { vals.push(v); }); });
    newest.actual.forEach(function (a) { if (a !== null && a !== undefined) vals.push(a); });
    var n = newest.hours.length;
    var sc = chartScaffold(wrap, vals, n, "Forecast vintages for " + state.revDay + ", " + state.zone);
    var svg = sc.svg, X = sc.X, Y = sc.Y;

    for (var i = 0; i < n; i += 3) {
      var tx = svgEl("text", {
        x: X(i), y: sc.m.t + sc.ph + 20, "text-anchor": "middle",
        fill: sc.C.muted, "font-size": 11.5, "font-variant-numeric": "tabular-nums",
      });
      tx.textContent = hourLabel(newest.hours[i]);
      svg.appendChild(tx);
    }
    entries.forEach(function (d) {
      svg.appendChild(svgEl("path", {
        d: pathString(d.sim, X, Y), fill: "none", stroke: sc.C.sim,
        "stroke-width": d.lead_days === 1 ? 2.4 : 1.8,
        "stroke-linejoin": "round", "stroke-linecap": "round",
        opacity: leadOpacity(d.lead_days),
      }));
    });
    if (hasActual) {
      svg.appendChild(svgEl("path", {
        d: pathString(newest.actual, X, Y), fill: "none", stroke: sc.C.act,
        "stroke-width": 2.4, "stroke-linejoin": "round", "stroke-linecap": "round",
      }));
    }
    wrap.appendChild(svg);
    if (entries.length === 1) {
      wrap.appendChild(el("p", "pending-note",
        "One vintage so far — earlier leads appear as the horizon runs accumulate day by day."));
    }
  }

  // ---------- map view ----------

  // Tile-grid layout: [col, row], geographically suggestive. One tile per zone.
  var MAP_GRID = {
    NO4: [2.4, 0], SE1: [4.2, 0], FI: [6.0, 0.4],
    NO3: [2.6, 1], SE2: [4.2, 1],
    NO5: [1.4, 2], NO1: [2.6, 2], SE3: [4.2, 2], EE: [6.6, 2],
    NO2: [1.8, 3], DK1: [3.0, 3.2], SE4: [4.6, 3], LV: [6.6, 3],
    DK2: [3.9, 4], LT: [6.6, 4],
    NL: [2.2, 5], DE_LU: [3.6, 5], PL: [5.4, 5],
    BE: [1.8, 6], CZ: [4.8, 6.2], SK: [6.0, 6.4],
    FR: [1.4, 7.4], CH: [3.0, 7.2], AT: [4.4, 7.2], HU: [5.6, 7.4], RO: [6.8, 7.4],
    PT: [0.0, 9.0], ES: [1.2, 9.0], SI: [4.2, 8.2], RS: [5.8, 8.4], BG: [7.0, 8.4],
    "IT-NORTH": [3.2, 8.6], "IT-CNORTH": [3.6, 9.6], "IT-CSOUTH": [4.2, 10.5],
    "IT-SOUTH": [5.0, 11.2], "IT-Calabria": [5.2, 12.2], "IT-Sicily": [4.3, 13.0],
    "IT-Sardinia": [2.9, 11.2],
    GR: [6.8, 10.6],
  };

  var mapState = { data: null, dayIdx: null, metric: "sim" };

  var MAP_METRICS = [
    ["sim", "Forecast"],
    ["act", "Actual (settled)"],
    ["err", "Error (fc − act)"],
  ];

  function loadMap() {
    if (mapState.data) return Promise.resolve(mapState.data);
    return loadWithFallback("map.json").then(function (res) {
      mapState.data = res.json;
      if (res.json && res.json.fixture) setFixtureBanner(true);
      return res.json;
    });
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

  function renderMap() {
    if (!mapState.data || !mapState.data.days || !mapState.data.days.length) {
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
    $("map-title").textContent = mDef[1] + " — " + dayLabel(day.date) +
      (metric !== "err" ? " (€/MWh, day average)" : " (€/MWh)");

    var dom = metricDomain(metric);
    var ramp = metric === "err" ? RAMP_DIV : RAMP_SEQ;
    $("map-legend-lo").textContent = "€" + fmt(dom[0], 0);
    $("map-legend-hi").textContent = "€" + fmt(dom[1], 0) + (metric === "err" ? "" : "+");
    $("map-legend-bar").style.backgroundImage = rampCss(ramp);

    var wrap = $("map-wrap");
    wrap.textContent = "";
    var TW = 76, TH = 52, GX = 84, GY = 60, PAD = 10;
    var maxC = 0, maxR = 0;
    Object.keys(MAP_GRID).forEach(function (z) {
      maxC = Math.max(maxC, MAP_GRID[z][0]);
      maxR = Math.max(maxR, MAP_GRID[z][1]);
    });
    var VBW = PAD * 2 + maxC * GX + TW, VBH = PAD * 2 + maxR * GY + TH;
    var svg = svgEl("svg", { viewBox: "0 0 " + VBW + " " + VBH, role: "img",
      "aria-label": "Map of day-ahead prices by bidding zone" });
    var css = getComputedStyle(document.documentElement);
    var C = { muted: css.getPropertyValue("--text-muted").trim(),
              line: css.getPropertyValue("--border").trim() };

    var tooltip = el("div", "tooltip");
    tooltip.style.display = "none";
    wrap.appendChild(svg);
    wrap.appendChild(tooltip);

    Object.keys(MAP_GRID).forEach(function (zn) {
      var pos = MAP_GRID[zn];
      var x = PAD + pos[0] * GX, y = PAD + pos[1] * GY;
      var z = day.zones[zn];
      var v = mapValue(z, metric);
      var has = v !== null && v !== undefined;
      var t = has ? (v - dom[0]) / (dom[1] - dom[0]) : 0;
      var g = svgEl("g", { class: "map-tile", tabindex: "0", role: "button",
        "aria-label": zn + (has ? ": " + fmt(v, 1) + " €/MWh" : ": no data") });
      g.appendChild(svgEl("rect", {
        x: x, y: y, width: TW, height: TH, rx: 8,
        fill: has ? rampColor(ramp, t) : "transparent",
        stroke: C.line, "stroke-width": has ? 0.5 : 1,
        "stroke-dasharray": has ? "none" : "3 3",
      }));
      var dark = has && (t < 0.28 || t > 0.78);
      var name = svgEl("text", {
        x: x + TW / 2, y: y + 21, "text-anchor": "middle",
        "font-size": zn.length > 6 ? 10 : 12, "font-weight": 600,
        fill: has ? (dark ? "#FBF8F1" : "#22303F") : C.muted,
      });
      name.textContent = zn.replace("IT-", "IT·").replace("DE_LU", "DE/LU");
      g.appendChild(name);
      var val = svgEl("text", {
        x: x + TW / 2, y: y + 40, "text-anchor": "middle",
        "font-size": 12, "font-variant-numeric": "tabular-nums",
        fill: has ? (dark ? "#FBF8F1" : "#22303F") : C.muted,
      });
      val.textContent = has ? (metric === "err" && v > 0 ? "+" : "") + fmt(v, 0) : "—";
      g.appendChild(val);

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
        var scale = rect.width / VBW;
        tooltip.style.display = "block";
        var left = (x + TW + 6) * scale;
        if (left + tooltip.offsetWidth > rect.width) left = (x - 6) * scale - tooltip.offsetWidth;
        tooltip.style.left = Math.max(0, left) + "px";
        tooltip.style.top = Math.max(0, y * scale - 8) + "px";
      }
      g.addEventListener("pointerenter", showTip);
      g.addEventListener("focus", showTip);
      g.addEventListener("pointerleave", function () { tooltip.style.display = "none"; });
      g.addEventListener("blur", function () { tooltip.style.display = "none"; });
      g.addEventListener("click", function () {
        state.zone = zn;
        state.day = day.date;
        setView("explorer");
        selectZone(zn, true);
        writeHash();
      });
      svg.appendChild(g);
    });

    $("map-comment").textContent = buildMapComment(day);
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

  function scoreboardWindows() {
    var seen = {};
    state.scoreboard.scores.forEach(function (s) { seen[s.window] = true; });
    var wins = Object.keys(seen);
    wins.sort(function (a, b) {
      if (a === "all") return -1;
      if (b === "all") return 1;
      return a < b ? 1 : -1; // months newest first
    });
    return wins;
  }

  function scoreboardLeads() {
    var seen = {};
    state.scoreboard.scores.forEach(function (s) { seen[s.lead_days] = true; });
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
    var leads = scoreboardLeads();
    var scores = state.scoreboard.scores.filter(function (s) { return s.window === state.window; });
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

  // ---------- footer ----------

  function renderFooter() {
    var sb = state.scoreboard;
    var bits = [];
    if (sb.generated_utc) bits.push("generated " + sb.generated_utc.replace("T", " ").replace("Z", " UTC"));
    if (sb.code_version !== undefined) bits.push("code_version " + sb.code_version);
    bits.push("source: " + (state.source === "data" ? "exported model results" : "bundled fixtures"));
    $("footer-meta").textContent = bits.join(" · ");
  }

  // ---------- wiring ----------

  function selectZone(zone, keepDay) {
    state.zone = zone;
    if (!keepDay) { state.day = null; state.revDay = null; }
    state.hoverIdx = null;
    $("zone-select").value = zone;
    $("hzone-select").value = zone;
    loadZone(zone).then(function () {
      renderExplorer();
      renderHorizon();
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
    $("window-select").addEventListener("change", function (ev) {
      state.window = ev.target.value;
      renderScoreboard();
      writeHash();
    });
    window.addEventListener("hashchange", function () {
      if (!suppressHash) applyHash();
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
        "Could not load results data (" + err + "). Expected ./data/scoreboard.json " +
        "or the bundled ./fixtures/scoreboard.json. Serve this directory with a static " +
        "file server, e.g.: python3 -m http.server --directory web";
    });
  }

  init();
})();
