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
    view: "explorer",      // "explorer" | "board"
    zone: "GR",
    lead: null,            // number
    day: null,             // "YYYY-MM-DD"
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
    if (params.view === "board" || params.view === "explorer") state.view = params.view;
    if (params.zone) state.zone = params.zone;
    if (params.lead && !isNaN(+params.lead)) state.lead = +params.lead;
    if (params.day && /^\d{4}-\d{2}-\d{2}$/.test(params.day)) state.day = params.day;
    if (params.window) state.window = params.window;
  }

  var suppressHash = false;
  function writeHash() {
    var parts = ["view=" + state.view, "zone=" + encodeURIComponent(state.zone)];
    if (state.lead !== null) parts.push("lead=" + state.lead);
    if (state.day) parts.push("day=" + state.day);
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
    document.querySelectorAll(".tab").forEach(function (t) {
      t.setAttribute("aria-selected", String(t.dataset.view === v));
    });
  }

  // ---------- explorer rendering ----------

  function renderZoneSelect() {
    var sel = $("zone-select");
    sel.textContent = "";
    var zones = state.scoreboard.zones.slice();
    // GR pinned first
    zones.sort(function (a, b) {
      if (a === "GR") return -1;
      if (b === "GR") return 1;
      return a < b ? -1 : a > b ? 1 : 0;
    });
    zones.forEach(function (z) {
      var o = el("option", null, z);
      o.value = z;
      sel.appendChild(o);
    });
    sel.value = state.zone;
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
    renderLegend(day);
    renderChart(day);
    renderHourTable(day);
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
    if (!keepDay) state.day = null;
    state.hoverIdx = null;
    loadZone(zone).then(function () {
      renderExplorer();
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
