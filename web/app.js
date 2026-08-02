/* Euphemia results browser — plain JS, no build step.
 * Data contract: ONE rung, live-only.
 *   live Worker API (issue #152): API_BASE/v1/{zones/<Z>,scoreboard,map,…}
 *   — R2-backed, fresh seconds after each pipeline run; ?api=<base> overrides
 *   the origin (point it at a local wrangler dev worker for offline work).
 *   ?live=0 disables the plane entirely (every view then shows its honest
 *   "live data unavailable — retry" state).
 *
 * There is NO bundled-snapshot fallback. The owner directive is absolute:
 * synthetic/example data must NEVER be rendered as if it were model output.
 * When the API does not answer, each view paints an honest empty/error state
 * with a retry action (liveUnavailable) — it never substitutes a snapshot.
 */
(function () {
  "use strict";

  var QUERY = new URLSearchParams(window.location.search);
  var API_BASE = QUERY.get("api") || "https://api.philokalia.ai/api";
  var LIVE = QUERY.get("live") !== "0";
  var SVGNS = "http://www.w3.org/2000/svg";

  var state = {
    scoreboard: null,
    source: null,          // "api" (the sole live plane) once it answers
    manifest: null,        // /api/v1/manifest payload (freshness badge)
    zoneCache: {},         // zone -> zone file json
    bookCache: {},         // "zone|date" -> book ladder json
    units: null,           // code -> {name, fuel, firm, zone} (order-book join)
    flowsCache: {},        // date -> {tsIso: [[source,sink,mw],…]} | null (trade wedge)
    view: "horizon",       // "horizon" | "explorer" | "board" | "book" | "predict" | "method"
    predictTarget: "overview", // predict sub-nav: overview | load | solar | wind
    methodology: null,     // /api/v1/book_methodology payload (pillar-5 generated numbers)
    zoneStrategies: null,  // /api/v1/zone_strategies payload (resolved per-zone profiles)
    boundaries: null,      // /api/v1/boundaries payload (pillar-6 boundary-zones object)
    methodZone: "FR",      // zone selected in the #view=method profile explorer (B5)
    methodFuel: "Fossil Gas", // fuel selected in the SRMC explorer (B1)
    methodTTF: null,       // slider state for B1 (null -> default from cost_model.live/fallback)
    methodEUA: null,
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

  // Load from the live Worker API — the SOLE data plane. There is no bundled
  // snapshot fallback: a failed fetch (or ?live=0) rejects, and the caller
  // surfaces an honest empty/error state (never synthetic data). Kept returning
  // {json, source} so call sites read res.json uniformly.
  function loadLive(rel) {
    if (!LIVE) return Promise.reject(new Error("live data plane disabled (?live=0)"));
    return fetchJSON(apiPath(rel)).then(function (j) {
      onApiSuccess();
      return { json: j, source: "api" };
    });
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

  // A retroactively-reconstructed day (post data-reset backfill): the export
  // stamps is_retro / reset_tag when present. Absent field ⇒ ordinary live day.
  function isRetro(day) { return !!(day && day.is_retro); }

  // ---------- hash routing ----------

  function readHash() {
    var h = window.location.hash.replace(/^#/, "");
    var params = {};
    h.split("&").forEach(function (kv) {
      var i = kv.indexOf("=");
      if (i > 0) params[decodeURIComponent(kv.slice(0, i))] = decodeURIComponent(kv.slice(i + 1));
    });
    if (["board", "explorer", "horizon", "map", "predict", "cases", "book", "solver", "method", "boundary"].indexOf(params.view) !== -1) state.view = params.view;
    if (["overview", "load", "solar", "wind"].indexOf(params.target) !== -1) state.predictTarget = params.target;
    if (params.mzone) state.methodZone = params.mzone;
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
    if (state.view === "predict" && state.predictTarget && state.predictTarget !== "overview") parts.push("target=" + state.predictTarget);
    if (state.view === "method" && state.methodZone) parts.push("mzone=" + encodeURIComponent(state.methodZone));
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
    return loadLive("zones/" + encodeURIComponent(zone) + ".json").then(function (res) {
      state.zoneCache[zone] = res.json;
      return res.json;
    });
  }

  // The pillar-5 bid-methodology object (cost model, form constants, strategy
  // glossary, provenance, cv-ledger) — every number GENERATED by the running
  // model (bin/export_book_methodology.jl). LIVE-ONLY (loadLive): there is no
  // bundled snapshot; a failed fetch rejects and the method view surfaces the
  // honest liveUnavailable state, the popover its no-decompose path. On success
  // it also OVERLAYS the WHY vocabulary onto the book-table explanations so
  // production has a single source of truth for the strategy glossary (§5.1 —
  // retires the hand-mirror). The built-in STRATEGY_LABELS.explain strings remain
  // only as a last-resort when the object has not been published yet.
  function loadMethodology() {
    if (state.methodology) return Promise.resolve(state.methodology);
    return loadLive("book_methodology.json").then(function (res) {
      state.methodology = res.json;
      var gl = res.json && res.json.strategy_glossary;
      if (gl) for (var k in gl) {
        if (STRATEGY_LABELS[k]) STRATEGY_LABELS[k].explain = gl[k];
      }
      return res.json;
    });
  }

  // The resolved per-zone ZoneProfile calibration (bin/export_zone_strategies.jl) —
  // the same object the About page renders; the B5 explorer is a richer view of it.
  // Live-only; a failed load leaves state.zoneStrategies null and B5 degrades to
  // its honest "not published yet" note (never a synthetic profile).
  function loadZoneStrategies() {
    if (state.zoneStrategies) return Promise.resolve(state.zoneStrategies);
    return loadLive("zone_strategies.json").then(function (res) {
      state.zoneStrategies = res.json;
      return res.json;
    });
  }

  // The pillar-6 boundary-zones object (elastic books walked from ZONE_PROFILES's
  // BoundaryBook structs + the cited fixed-neighbour list + the :v3 flow rule) —
  // generated by bin/export_boundaries.jl. LIVE-ONLY (loadLive): a failed fetch
  // rejects and the boundary view surfaces the honest liveUnavailable state; there
  // is NO bundled snapshot.
  function loadBoundaries() {
    if (state.boundaries) return Promise.resolve(state.boundaries);
    return loadLive("boundaries.json").then(function (res) {
      state.boundaries = res.json;
      return res.json;
    });
  }

  // ==================== Pillar 6 — the boundary view ==========================
  // Every number/label here is GENERATED (bin/export_boundaries.jl walks the
  // BoundaryBook structs) or QUOTED from the cited effects file — never recomputed
  // in the browser. The whole view degrades honestly (liveUnavailable) when the
  // object is not being served; per-day flow annotations layer on top (D3) and are
  // honestly absent where the coupled solve does not publish them.

  var boundaryState = {
    dayIdx: null,          // index into the shared map day list (slider)
    explainBook: null,     // book name selected in the explainer (default GB Viking)
    showRungs: false,      // "show today's actual rungs" toggle
  };
  var BOUNDARY_BOOK_DEFAULT_EXPLAIN = "VIKING_GB_BOOK";

  // D2: fixed compass bearings (degrees, 0 = north, clockwise). Stable across days,
  // matches mental geography, anchored by the footprint backdrop.
  var BOUNDARY_BEARINGS = {
    GB: 315,   // north-west
    UA: 90,    // east
    TR: 138,   // south-east
    MK: 170,   // ~south (east of due south)
    AL: 200,   // ~south (west of due south)
  };

  // Group the generated elastic records by counterparty → ring node with its edges
  // (D1: ONE GB node, TWO labelled edges; UA one node, four edges).
  function boundaryNodes(data) {
    var nodes = [];
    var byCp = {};
    (data.elastic || []).forEach(function (b) {
      var n = byCp[b.counterparty];
      if (!n) {
        n = byCp[b.counterparty] = {
          counterparty: b.counterparty, kind: "elastic", books: [], borders: [], edges: [],
        };
        nodes.push(n);
      }
      n.books.push(b);
      b.borders.forEach(function (z) {
        if (n.borders.indexOf(z) === -1) n.borders.push(z);
        n.edges.push({ zone: z, carbon: b.carbon_source, book: b.book });
      });
    });
    (data.fixed || []).forEach(function (f) {
      var n = { counterparty: f.counterparty, kind: "fixed", fixed: f, borders: f.borders.slice(), edges: [] };
      f.borders.forEach(function (z) { n.edges.push({ zone: z }); });
      nodes.push(n);
    });
    return nodes;
  }

  // The shared day list (same source the map uses). Best-effort: the ring renders
  // statically without it; the slider + flow annotations layer on when present.
  function boundaryDays() {
    return (mapState.data && mapState.data.days) ? mapState.data.days : null;
  }
  function boundarySelectedDate() {
    var days = boundaryDays();
    if (!days || !days.length) return state.day || null;
    if (boundaryState.dayIdx === null || boundaryState.dayIdx >= days.length) boundaryState.dayIdx = days.length - 1;
    return days[boundaryState.dayIdx].date;
  }

  // The day-net flow on a boundary edge from /api/v1/flows, signed toward the
  // footprint (import +). Footprint flows are zone-to-zone, so out-of-footprint
  // counterparties are usually ABSENT — we return null and say so honestly, never
  // invent a number. Only fires when the counterparty happens to appear as a flow
  // endpoint against one of its border zones.
  function boundaryEdgeFlow(date, counterparty, borderZone) {
    var byTs = state.flowsCache[date];
    if (!byTs) return null;
    var net = 0, seen = false;
    Object.keys(byTs).forEach(function (ts) {
      (byTs[ts] || []).forEach(function (r) {
        var src = r[0], snk = r[1], mw = r[2];
        if (src === counterparty && snk === borderZone) { net += mw; seen = true; }
        else if (src === borderZone && snk === counterparty) { net -= mw; seen = true; }
      });
    });
    return seen ? net / 24 : null;   // day-mean MW toward the footprint
  }

  function renderBoundary() {
    var status = $("boundary-status");
    return loadBoundaries().then(function (data) {
      if (state.view !== "boundary") return;
      if (!data || !Array.isArray(data.elastic) || !Array.isArray(data.fixed)) {
        throw new Error("boundaries object incomplete");
      }
      if (boundaryState.explainBook === null) boundaryState.explainBook = BOUNDARY_BOOK_DEFAULT_EXPLAIN;
      if (status) {
        status.textContent = "";
        var n = data.n_named_neighbours;
        status.appendChild(el("span", null,
          "Generated from the running model · code_version " + data.code_version + " · " +
          n + " named out-of-footprint neighbour" + (n === 1 ? "" : "s") + " (" +
          data.n_elastic_books + " elastic book" + (data.n_elastic_books === 1 ? "" : "s") +
          " over " + boundaryBorderCount(data) + " borders, " +
          data.n_fixed_neighbours + " fixed injections), plus the unnamed :v3 climatology band."));
      }
      // Static ring + cards + panels first (no per-day dependency — D3).
      renderBoundaryRing(data);
      renderBoundaryExplainer(data);
      renderBoundaryCards(data);
      renderBoundaryFlowRule(data);
      renderBoundaryPropagation(data);
      renderBoundaryRoadmap(data);
      // Then layer the shared day slider + per-day flow annotations, best-effort.
      loadMap().then(function () {
        if (state.view !== "boundary") return;
        renderBoundaryDaySlider(data);
        var date = boundarySelectedDate();
        if (date) loadFlows(date).then(function () {
          if (state.view === "boundary") renderBoundaryRing(data);
        });
      }, function () { /* no map days → ring stays static, honestly */ });
    }).catch(function () {
      if (state.view !== "boundary") return;
      liveUnavailable(status, function () { renderBoundary(); },
        "This boundary surface loads only from the live data API and never " +
        "substitutes synthetic data. The generated object " +
        "(bin/export_boundaries.jl) is not being served right now.");
      ["boundary-ring", "boundary-explainer", "boundary-cards", "boundary-flowrule",
       "boundary-propagation", "boundary-roadmap"].forEach(function (id) {
        var h = $(id); if (h) h.textContent = "";
      });
    });
  }

  function boundaryBorderCount(data) {
    var s = {};
    (data.elastic || []).forEach(function (b) { b.borders.forEach(function (z) { s[b.counterparty + "|" + z] = 1; }); });
    return Object.keys(s).length;
  }

  function renderBoundaryDaySlider(data) {
    var days = boundaryDays();
    var slider = $("boundary-day-slider"), lbl = $("boundary-day-label");
    if (!slider || !days || !days.length) { if (lbl) lbl.textContent = "—"; return; }
    if (boundaryState.dayIdx === null || boundaryState.dayIdx >= days.length) boundaryState.dayIdx = days.length - 1;
    slider.max = String(days.length - 1);
    slider.value = String(boundaryState.dayIdx);
    if (lbl) lbl.textContent = dayLabel(days[boundaryState.dayIdx].date);
  }

  // ---- A · the boundary ring -----------------------------------------------
  function renderBoundaryRing(data) {
    var host = $("boundary-ring");
    if (!host) return;
    host.textContent = "";
    var C = chartColors();
    var W = 900, H = 600, cx = W / 2, cy = H / 2 + 8;
    var rx = 330, ry = 232;
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": "Boundary ring: the footprint and its out-of-footprint neighbours" });
    host.appendChild(svg);

    // faint footprint backdrop (undifferentiated — this view is not about internal prices)
    var fpW = 300, fpH = 190;
    svg.appendChild(svgEl("rect", { x: cx - fpW / 2, y: cy - fpH / 2, width: fpW, height: fpH,
      rx: 18, fill: C.grid, opacity: 0.28, stroke: C.muted, "stroke-width": 1, "stroke-dasharray": "3 4" }));
    var fpLabel = svgEl("text", { x: cx, y: cy - 4, "text-anchor": "middle",
      fill: C.muted, "font-size": 15, "font-family": "var(--mono)", "font-weight": 700 });
    fpLabel.textContent = "39-ZONE FOOTPRINT";
    svg.appendChild(fpLabel);
    var fpSub = svgEl("text", { x: cx, y: cy + 16, "text-anchor": "middle",
      fill: C.muted, "font-size": 11, "font-family": "var(--mono)", opacity: 0.85 });
    fpSub.textContent = "(faint backdrop — the coupled clear)";
    svg.appendChild(fpSub);

    // faint "others (:v3 climatology)" band — everything off-footprint is injected,
    // most of it with no name of its own.
    var oth = polar(cx, cy, rx, ry, 25);
    svg.appendChild(svgEl("line", { x1: cx, y1: cy - fpH / 2, x2: oth.x, y2: oth.y,
      stroke: C.muted, "stroke-width": 1, "stroke-dasharray": "1 6", opacity: 0.5 }));
    var othLbl = svgEl("text", { x: oth.x, y: oth.y - 8, "text-anchor": "middle",
      fill: C.muted, "font-size": 10.5, opacity: 0.8 });
    othLbl.textContent = "others (:v3 climatology)";
    svg.appendChild(othLbl);

    var date = boundarySelectedDate();
    var nodes = boundaryNodes(data);
    var accent = C.accent || "#c8783c";

    nodes.forEach(function (node) {
      var ang = BOUNDARY_BEARINGS[node.counterparty];
      if (ang === undefined) ang = 45;
      var p = polar(cx, cy, rx, ry, ang);
      var elastic = node.kind === "elastic";
      var stroke = elastic ? accent : C.muted;

      node.edges.forEach(function (edge, i) {
        // fan the edges of a multi-border node slightly so they read separately
        var spread = (node.edges.length > 1) ? (i - (node.edges.length - 1) / 2) * 6 : 0;
        var ep = polar(cx, cy, rx, ry, ang + spread);
        var inner = polar(cx, cy, fpW / 2 + 6, fpH / 2 + 6, ang + spread);
        var flow = date ? boundaryEdgeFlow(date, node.counterparty, edge.zone) : null;
        var w = elastic ? 3 : 1.6;
        if (flow !== null) w = Math.max(1.4, Math.min(9, Math.abs(flow) / 400));
        var lineAttrs = { x1: ep.x, y1: ep.y, x2: inner.x, y2: inner.y,
          stroke: stroke, "stroke-width": w, "stroke-linecap": "round",
          opacity: elastic ? 0.95 : 0.6 };
        if (!elastic) lineAttrs["stroke-dasharray"] = "6 5";
        svg.appendChild(svgEl("line", lineAttrs));

        // edge label: the border zone, its carbon leg (elastic), and the day flow
        var midx = (ep.x + inner.x) / 2, midy = (ep.y + inner.y) / 2;
        var lab = edge.zone + (edge.carbon ? " (:" + edge.carbon + ")" : "");
        var t = svgEl("text", { x: midx, y: midy - 3, "text-anchor": "middle",
          fill: C.muted, "font-size": 9.5, "font-family": "var(--mono)" });
        t.textContent = lab;
        svg.appendChild(t);
        var ft = svgEl("text", { x: midx, y: midy + 9, "text-anchor": "middle",
          fill: flow !== null ? (elastic ? accent : C.muted) : C.muted, "font-size": 9,
          opacity: flow !== null ? 1 : 0.6 });
        ft.textContent = flow !== null
          ? (flow >= 0 ? "→ " : "← ") + fmtMWk(Math.abs(flow)) + " MW"
          : "flow n/p";
        svg.appendChild(ft);
      });

      // node marker: filled (elastic) vs hollow (fixed)
      var g = svgEl("g", { class: "boundary-node", role: "button", tabindex: "0",
        "aria-label": node.counterparty + " — " + (elastic ? "elastic book" : "fixed injection") });
      g.appendChild(svgEl("circle", { cx: p.x, cy: p.y, r: 15,
        fill: elastic ? accent : "none", stroke: stroke, "stroke-width": elastic ? 2 : 2,
        "stroke-dasharray": elastic ? "none" : "3 3" }));
      var nt = svgEl("text", { x: p.x, y: p.y + 4, "text-anchor": "middle",
        fill: elastic ? (C.surface || "#fff") : C.muted, "font-size": 11,
        "font-weight": 700, "font-family": "var(--mono)" });
      nt.textContent = node.counterparty;
      g.appendChild(nt);
      var kt = svgEl("text", { x: p.x, y: p.y + 30, "text-anchor": "middle",
        fill: C.muted, "font-size": 9.5 });
      kt.textContent = elastic ? "elastic" : "fixed";
      g.appendChild(kt);
      var jump = function () { scrollToBoundaryCard(node.counterparty); };
      g.addEventListener("click", jump);
      g.addEventListener("keydown", function (ev) {
        if (ev.key === "Enter" || ev.key === " ") { if (ev.preventDefault) ev.preventDefault(); jump(); }
      });
      svg.appendChild(g);
    });

    // legend (the fit/construct wall, one line)
    var lg = $("boundary-ring-legend");
    if (lg) {
      lg.textContent = "";
      var e1 = el("span", "boundary-leg-item");
      e1.appendChild(el("span", "boundary-leg-swatch solid"));
      e1.appendChild(document.createTextNode("solid = elastic counterparty (bids into the clear)"));
      var e2 = el("span", "boundary-leg-item");
      e2.appendChild(el("span", "boundary-leg-swatch dashed"));
      e2.appendChild(document.createTextNode("dashed = fixed observed injection (price-taker schedule)"));
      lg.appendChild(e1); lg.appendChild(e2);
      var e3 = el("span", "boundary-leg-note",
        date ? ("edges show the day's net flow toward the footprint where the coupled solve publishes it (" +
                dayLabel(date) + "); “flow n/p” = not published (boundary exchanges are injected, not solved zone-to-zone).")
             : "select a day to annotate edges with net flow where available.");
      lg.appendChild(e3);
    }
  }

  function polar(cx, cy, rx, ry, angDeg) {
    var t = angDeg * Math.PI / 180;
    return { x: cx + rx * Math.sin(t), y: cy - ry * Math.cos(t) };
  }

  function scrollToBoundaryCard(cp) {
    var card = document.getElementById("boundary-card-" + cp);
    if (card && card.scrollIntoView) card.scrollIntoView({ behavior: "smooth", block: "center" });
    if (card && card.classList) { card.classList.add("boundary-card-flash"); }
  }

  // ---- B · fixed-vs-elastic explainer --------------------------------------
  function renderBoundaryExplainer(data) {
    var host = $("boundary-explainer");
    if (!host) return;
    host.textContent = "";
    var C = chartColors();
    var accent = C.accent || "#c8783c";

    // book picker (which elastic book's ladder to draw on the right)
    var picker = el("div", "boundary-explainer-picker");
    picker.appendChild(el("span", "filter-label", "Ladder shown:"));
    (data.elastic || []).forEach(function (b) {
      var label = b.counterparty + " " + b.borders.join("/") + " (:" + b.carbon_source +
        (b.firm_slice ? ", firm slice" : "") + ")";
      var btn = el("button", "boundary-chip" + (boundaryState.explainBook === b.book && sameBorders(b) ? " on" : ""), label);
      btn.type = "button";
      btn.addEventListener("click", function () {
        boundaryState.explainBook = b.book;
        boundaryState._explainBorders = b.borders.join("/");
        renderBoundaryExplainer(data);
      });
      picker.appendChild(btn);
    });
    host.appendChild(picker);

    function sameBorders(b) {
      return !boundaryState._explainBorders || boundaryState._explainBorders === b.borders.join("/");
    }
    var book = (data.elastic || []).filter(function (b) {
      return b.book === boundaryState.explainBook && sameBorders(b);
    })[0] || (data.elastic || [])[0];

    var cols = el("div", "boundary-explainer-cols");
    host.appendChild(cols);

    // LEFT — fixed injection = a vertical price-taker line
    var left = el("div", "boundary-explainer-col");
    left.appendChild(el("h3", "panel-title", "Fixed injection"));
    left.appendChild(el("p", "day-comment",
      "The neighbour is a price-taker schedule: it sells its full observed quantity at any price. A vertical line on the supply/demand axis."));
    left.appendChild(miniLadderSVG(C, "fixed", null, accent));
    left.appendChild(el("p", "boundary-explainer-caption",
      "Observed flow (e.g. 800 MW), at any price — it does not respond to the clear. TR, AL, MK and every unnamed neighbour enter this way."));
    cols.appendChild(left);

    // RIGHT — elastic book = a stepped ladder
    var right = el("div", "boundary-explainer-col");
    right.appendChild(el("h3", "panel-title", "Elastic book — " + book.counterparty + " " + book.borders.join("/")));
    right.appendChild(el("p", "day-comment",
      "A stepped ladder rising from the neighbour's OWN cost (" + anchorPhrase(book) + "), sized by the border's demonstrated capability (:" + book.capability_mode + ")." +
      (book.firm_slice ? " Plus a FIRM demand slab at the cap that does not curtail on price." : "")));
    right.appendChild(miniLadderSVG(C, "elastic", book, accent));

    // "show me today's actual rungs" toggle — reads the live BOUNDARY-tagged orders
    var toggWrap = el("div", "boundary-rungs-toggle");
    var togg = el("button", "boundary-chip" + (boundaryState.showRungs ? " on" : ""),
      boundaryState.showRungs ? "showing today's actual rungs" : "show me the actual rungs for today");
    togg.type = "button";
    togg.addEventListener("click", function () {
      boundaryState.showRungs = !boundaryState.showRungs;
      renderBoundaryExplainer(data);
    });
    toggWrap.appendChild(togg);
    right.appendChild(toggWrap);

    var rungsHost = el("div", "boundary-rungs-live");
    right.appendChild(rungsHost);
    if (boundaryState.showRungs) renderLiveRungs(rungsHost, book);

    right.appendChild(el("p", "boundary-explainer-caption",
      "The fixed line always sells its full quantity no matter the price; the ladder sells more only as the zone's price rises above " +
      book.counterparty + "'s own cost — so the border can go the OTHER way when we're cheaper than " + book.counterparty + "."));
    cols.appendChild(right);

    var note = $("boundary-explainer-note");
    if (note) note.textContent = "Both books share the wave-2 ladder shapes — import supply and export demand as multiples of the anchor; the difference between the two neighbours is the anchor and the sizing, not the shape.";
  }

  function anchorPhrase(book) {
    return book.anchor === "gb_ccgt_srmc"
      ? (book.anchor_mult + " × GB CCGT SRMC, :" + book.carbon_source + " carbon")
      : book.anchor === "zone_gas_srmc"
      ? "0.55 × our own zone gas SRMC (generic — no counterparty feed)"
      : book.anchor;
  }

  // A schematic mini supply/demand axis: a vertical price-taker line (fixed) or a
  // stepped ladder from the anchor (elastic), drawn from the book's own multipliers.
  function miniLadderSVG(C, kind, book, accent) {
    var W = 380, H = 220, m = { l: 44, r: 14, t: 16, b: 34 };
    var pw = W - m.l - m.r, ph = H - m.t - m.b;
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, role: "img",
      "aria-label": kind === "fixed" ? "Fixed price-taker line" : "Elastic ladder" });
    // axes
    svg.appendChild(svgEl("line", { x1: m.l, y1: m.t, x2: m.l, y2: m.t + ph, stroke: C.grid, "stroke-width": 1 }));
    svg.appendChild(svgEl("line", { x1: m.l, y1: m.t + ph, x2: m.l + pw, y2: m.t + ph, stroke: C.grid, "stroke-width": 1 }));
    var yl = svgEl("text", { x: m.l - 6, y: m.t + 6, "text-anchor": "end", fill: C.muted, "font-size": 10 });
    yl.textContent = "€/MWh"; svg.appendChild(yl);
    var xl = svgEl("text", { x: m.l + pw, y: m.t + ph + 22, "text-anchor": "end", fill: C.muted, "font-size": 10 });
    xl.textContent = "MW"; svg.appendChild(xl);
    if (kind === "fixed") {
      var fx = m.l + pw * 0.55;
      svg.appendChild(svgEl("line", { x1: fx, y1: m.t + 6, x2: fx, y2: m.t + ph, stroke: accent, "stroke-width": 3 }));
      var ft = svgEl("text", { x: fx + 6, y: m.t + 24, fill: accent, "font-size": 10.5, "font-family": "var(--mono)" });
      ft.textContent = "sells 800 MW @ any price"; svg.appendChild(ft);
    } else {
      // import-supply ladder rising from the anchor
      var rungs = (book && book.imp_ladder) || [[1.0, 0.5], [1.15, 0.3], [1.3, 0.2]];
      var anchorY = m.t + ph * 0.62;        // schematic anchor level
      var x = m.l, cum = 0, unit = pw * 0.72;
      var maxMult = 0; rungs.forEach(function (r) { maxMult = Math.max(maxMult, r[0]); });
      rungs.forEach(function (r) {
        var w = unit * r[1];
        var y = anchorY - (r[0] - 1) * ph * 0.5;
        svg.appendChild(svgEl("line", { x1: x, y1: y, x2: x + w, y2: y, stroke: accent, "stroke-width": 3 }));
        if (cum > 0) svg.appendChild(svgEl("line", { x1: x, y1: prevY, x2: x, y2: y, stroke: accent, "stroke-width": 1.5, opacity: 0.6 }));
        var rt = svgEl("text", { x: x + w / 2, y: y - 5, "text-anchor": "middle", fill: C.muted, "font-size": 9, "font-family": "var(--mono)" });
        rt.textContent = "×" + r[0].toFixed(2); svg.appendChild(rt);
        x += w; cum += 1; var prevY = y; miniLadderSVG._prevY = y;
      });
      // anchor reference line
      svg.appendChild(svgEl("line", { x1: m.l, y1: anchorY, x2: m.l + pw, y2: anchorY, stroke: C.muted, "stroke-width": 1, "stroke-dasharray": "2 4", opacity: 0.7 }));
      var at = svgEl("text", { x: m.l + 4, y: anchorY - 4, fill: C.muted, "font-size": 9.5 });
      at.textContent = "anchor"; svg.appendChild(at);
      // firm slab at the cap (UA)
      if (book && book.firm_slice) {
        var firmY = m.t + 10;
        svg.appendChild(svgEl("rect", { x: m.l + pw * 0.02, y: firmY, width: pw * 0.30, height: 12, fill: accent, opacity: 0.35 }));
        var fmt2 = svgEl("text", { x: m.l + pw * 0.02, y: firmY - 3, fill: C.muted, "font-size": 9 });
        fmt2.textContent = "firm demand @ cap (price-taker)"; svg.appendChild(fmt2);
      }
    }
    return svg;
  }

  // The "actual rungs today" path: read the border zone's live book, filter the
  // BOUNDARY:<cp>-tagged orders for the selected hour, list them. Honest absence
  // when the book (or its boundary orders) is not published for the day.
  function renderLiveRungs(host, book) {
    host.textContent = "";
    var days = boundaryDays();
    var date = boundarySelectedDate();
    var zone = book.borders[0];
    if (!date) { host.appendChild(el("p", "day-comment", "Select a market day to read today's rungs.")); return; }
    host.appendChild(el("p", "day-comment", "Reading " + zone + "'s live book for " + dayLabel(date) + " …"));
    loadBook(zone, date).then(function (bk) {
      if (!boundaryState.showRungs) return;
      host.textContent = "";
      if (!bk || !bk.owners || !bk.hours || !bk.hours.length) {
        host.appendChild(boundaryAbsence("No published book for " + zone + " on " + dayLabel(date) +
          " — today's actual rungs are only available on record/backfill days."));
        return;
      }
      // pick a representative hour (evening peak ~ index for 18:00 Athens, else mid)
      var hi = Math.min(bk.hours.length - 1, 18);
      var want = "BOUNDARY:" + book.counterparty;
      var rungs = [];
      ["supply", "demand"].forEach(function (side) {
        var arr = (bk[side] && bk[side][hi]) || [];
        arr.forEach(function (o) {
          var owner = bk.owners[o[2]] || "";
          if (owner.indexOf(want) === 0) rungs.push({ side: side, price: o[0], mw: o[1], owner: owner });
        });
      });
      if (!rungs.length) {
        host.appendChild(boundaryAbsence("This day's " + zone + " book carries no BOUNDARY:" +
          book.counterparty + " orders (the book may predate cv" + (book.effect ? (book.effect.cv || "") : "") +
          ", or " + book.counterparty + " was disabled). No rungs invented."));
        return;
      }
      var tbl = el("table", "boundary-rungs-table");
      var thead = el("thead"); var htr = el("tr");
      ["Side", "€/MWh", "MW", "owner"].forEach(function (h) { htr.appendChild(el("th", null, h)); });
      thead.appendChild(htr); tbl.appendChild(thead);
      var tb = el("tbody");
      rungs.sort(function (a, b) { return a.side === b.side ? a.price - b.price : (a.side === "supply" ? -1 : 1); });
      rungs.forEach(function (r) {
        var tr = el("tr");
        tr.appendChild(el("td", null, r.side === "supply" ? "import supply" : "export demand"));
        tr.appendChild(el("td", null, fmt(r.price, 2)));
        tr.appendChild(el("td", null, fmt(r.mw, 1)));
        tr.appendChild(el("td", "boundary-rung-owner", r.owner));
        tb.appendChild(tr);
      });
      tbl.appendChild(tb);
      host.appendChild(el("p", "day-comment", zone + " · " + hourLabel(bk.hours[hi]) + " Athens · the live " + book.counterparty + " boundary ladder:"));
      host.appendChild(tbl);
    }, function () {
      host.textContent = "";
      host.appendChild(boundaryAbsence("The live book for " + zone + " did not load — no rungs invented."));
    });
  }

  function boundaryAbsence(msg) {
    var box = el("div", "boundary-absence");
    box.appendChild(el("span", "boundary-absence-mark", "—"));
    box.appendChild(el("span", null, msg));
    return box;
  }

  // ---- C · per-country cards ------------------------------------------------
  function renderBoundaryCards(data) {
    var host = $("boundary-cards");
    if (!host) return;
    host.textContent = "";
    // Elastic first (GB, UA), then fixed (TR/AL/MK). One card per COUNTERPARTY.
    var nodes = boundaryNodes(data);
    nodes.sort(function (a, b) {
      if (a.kind !== b.kind) return a.kind === "elastic" ? -1 : 1;
      return a.counterparty < b.counterparty ? -1 : 1;
    });
    nodes.forEach(function (node) {
      host.appendChild(node.kind === "elastic"
        ? boundaryElasticCard(node)
        : boundaryFixedCard(node));
    });
  }

  function cardField(label, valueNode) {
    var row = el("div", "boundary-field");
    row.appendChild(el("span", "boundary-field-label", label));
    var v = el("span", "boundary-field-value");
    if (typeof valueNode === "string") v.textContent = valueNode;
    else if (valueNode) v.appendChild(valueNode);
    row.appendChild(v);
    return row;
  }

  function boundaryElasticCard(node) {
    var card = el("div", "boundary-card boundary-card-elastic");
    card.id = "boundary-card-" + node.counterparty;
    var head = el("div", "boundary-card-head");
    head.appendChild(el("span", "boundary-card-title", node.counterparty));
    head.appendChild(el("span", "kind-badge kind-elastic", "ELASTIC BOOK · constructed"));
    card.appendChild(head);

    // GB gets its parked-zone plain statement; UA its firm-slice story.
    if (node.counterparty === "GB") {
      card.appendChild(el("p", "boundary-card-lede",
        "Two INDEPENDENT books with different carbon legs. GB the ZONE stays PARKED — there is no internal GB clear until an Elexon/BMRS + UK-ETS fundamentals feed exists; only these two interconnector borders are modelled."));
    } else if (node.counterparty === "UA") {
      card.appendChild(el("p", "boundary-card-lede",
        "A war-constrained scarcity buyer — the weakest anchor we ship, and we say so. The FIRM slice, not the elastic anchor, does the load-bearing work."));
    }

    // KIND · how it enters · anchor · capability · borders — filled per book.
    node.books.forEach(function (b) {
      var sub = el("div", "boundary-book-block");
      sub.appendChild(el("h4", "boundary-book-name", b.book + " · borders " + b.borders.join("/")));
      sub.appendChild(cardField("How it enters",
        "import-supply + export-demand ladders in the border zone's book (owner BOUNDARY:" + b.counterparty +
        "), replacing the fixed injection — its codes " + b.net_exclude_codes.join(", ") +
        " are stripped from net-imports and the backstop."));
      var anchorNode = el("span", null, anchorPhrase(b) + " (η=" + b.efficiency + "). ");
      var badge = el("span", b.anchor === "zone_gas_srmc" ? "prov-badge prov-declared" : "prov-badge prov-observed",
        b.anchor === "zone_gas_srmc" ? "declared: generic" : "declared: defensible");
      anchorNode.appendChild(badge);
      sub.appendChild(cardField("Anchor", anchorNode));
      if (b.carbon_source === "uka") {
        sub.appendChild(cardField("Carbon leg", ":uka — the correct UK-ETS price (carbon.uka_price), falling back to EUA on the offline extract. The EUA/UKA split between the two GB books is a real honesty detail, not noise."));
      } else if (b.counterparty === "GB") {
        sub.appendChild(cardField("Carbon leg", ":eua — the Viking book's validated cv21 config."));
      }
      var capText = b.capability_mode === "atc_capped"
        ? "the day's offered Day-ahead ATC, capped at the trailing-366d demonstrated max, with a p95-per-4h-block floor on ATC gaps."
        : "pure trailing-366d p95 gross flow per 4h block — UA's explicit ATC is stale/absent (understates realised flow ~4×), so the demonstrated-capability floor is used uniformly (no ATC cap).";
      if (b.double_count_fix) {
        capText += " FR↔GB has NO aggregate offered ATC (published only per-cable), so it AVGs within IFA/IFA2/ElecLink then SUMS — the detail where the double-count lived.";
      }
      sub.appendChild(cardField("Capability (:" + b.capability_mode + ")", capText));
      sub.appendChild(cardField("Ladders",
        "import supply × [" + b.imp_ladder.map(function (r) { return r[0].toFixed(2); }).join(", ") +
        "] · export demand × [" + b.exp_ladder.map(function (r) { return r[0].toFixed(2); }).join(", ") + "]" +
        (b.firm_slice ? " · FIRM slab: trailing-" + b.firm_window_days + "d p" + Math.round(b.firm_quantile * 100) +
          " of daily block-mean export flow, priced €" + b.firm_price + " (≈ cap, price-taker)." : ".")));
      if (b.double_count_fix) sub.appendChild(boundaryDoubleCountExhibit(b));
      card.appendChild(sub);
    });

    // Measured effect — QUOTED from the effect block.
    node.books.forEach(function (b) {
      if (b.effect) card.appendChild(boundaryEffectPanel(b));
    });

    // UA's HU-March lesson exhibit (first-class honesty).
    var uaEff = node.books.map(function (b) { return b.effect; }).filter(Boolean)[0];
    if (node.counterparty === "UA" && uaEff && uaEff.hu_march_lesson) {
      var lesson = el("div", "boundary-lesson");
      lesson.appendChild(el("h4", "boundary-lesson-title", "The HU-March lesson — why the SHAPE of a boundary bid matters"));
      lesson.appendChild(el("p", null, uaEff.hu_march_lesson));
      card.appendChild(lesson);
    }

    // Roadmap.
    card.appendChild(cardField("Roadmap", node.counterparty === "GB"
      ? "GB the zone stays parked; a full GB behavioural book (all its borders, an internal clear) waits on an Elexon/BMRS + UKA feed."
      : "the honest upgrade is a real UA fundamentals feed (retire the :zone_gas_srmc generic anchor); until then the firm slice carries the book."));

    // Illustrative kill-switch honesty toggle (client-side only).
    var ks = el("div", "boundary-killswitch");
    var disableEnv = node.books[0].disable_env;
    var btn = el("button", "boundary-chip", "illustrate " + disableEnv + " (disable this book)");
    btn.type = "button";
    btn.addEventListener("click", function () {
      card.classList.toggle("boundary-card-disabled");
      btn.textContent = card.classList.contains("boundary-card-disabled")
        ? "book disabled (illustrative) — click to restore"
        : "illustrate " + disableEnv + " (disable this book)";
    });
    ks.appendChild(btn);
    ks.appendChild(el("span", "day-comment",
      " Illustrative only — greys the ladder to show what " + disableEnv + " does; no re-clear happens in the browser."));
    card.appendChild(ks);
    return card;
  }

  function boundaryDoubleCountExhibit(b) {
    var ex = el("div", "boundary-doublecount");
    ex.appendChild(el("h4", "boundary-exhibit-title", "The FR↔GB double-count fix — a first-class honesty exhibit"));
    ex.appendChild(el("p", null,
      "ENTSO-E publishes the FR↔GB flow BOTH as the aggregate GB code AND as the three cables, so get_net_imports summed it ≈2×. net_exclude_codes = [" +
      b.net_exclude_codes.join(", ") + "] strips all four; the ladder then prices the border once."));
    if (b.effect && b.effect.double_count_fix) {
      var d = b.effect.double_count_fix;
      var beforeAfter = el("div", "boundary-beforeafter");
      var bf = el("div", "boundary-ba-col");
      bf.appendChild(el("span", "boundary-ba-label", "before"));
      bf.appendChild(el("span", null, "fixed DOUBLE injection (phantom + true)"));
      var af = el("div", "boundary-ba-col");
      af.appendChild(el("span", "boundary-ba-label", "after"));
      af.appendChild(el("span", null, "single priced elastic border"));
      beforeAfter.appendChild(bf); beforeAfter.appendChild(af);
      ex.appendChild(beforeAfter);
      ex.appendChild(el("p", "day-comment", "Shipped alone it cost " + d.shipped_alone_cost +
        ". So it shipped PAIRED: " + d.paired_lever + ". " + d.lesson + "."));
    }
    return ex;
  }

  function boundaryEffectPanel(b) {
    var eff = b.effect;
    var p = el("div", "boundary-effect");
    p.appendChild(el("h4", "boundary-effect-title",
      "Measured effect — " + (eff.zone || b.counterparty) + " · " + (eff.ledger || "").toUpperCase() +
      (eff.standalone === false ? " (HALF of a two-bug lever — not a standalone win)" : "")));
    if (eff.windows) {
      var wt = el("table", "boundary-effect-table");
      var th = el("thead"); var htr = el("tr");
      ["window", "MAE", "corr"].forEach(function (h) { htr.appendChild(el("th", null, h)); });
      th.appendChild(htr); wt.appendChild(th);
      var tb = el("tbody");
      eff.windows.forEach(function (w) {
        var tr = el("tr");
        tr.appendChild(el("td", null, w.name));
        tr.appendChild(el("td", null, w.mae ? (fmt(w.mae[0], 2) + " → " + fmt(w.mae[1], 2)) : "—"));
        tr.appendChild(el("td", null, w.corr ? (fmt(w.corr[0], 2) + " → " + fmt(w.corr[1], 2)) : "—"));
        tb.appendChild(tr);
      });
      wt.appendChild(tb); p.appendChild(wt);
    }
    if (eff.fr_corr_record !== undefined) {
      p.appendChild(el("p", null, "FR full-year corr on the cv23 record: " + fmt(eff.fr_corr_record, 2) + "."));
    }
    if (eff.note) p.appendChild(el("p", "boundary-effect-note", eff.note + "."));
    if (eff.spillovers && eff.spillovers.length) {
      p.appendChild(el("p", "day-comment", "Spillovers: " + eff.spillovers.join("; ") + "."));
    }
    if (eff.residuals && eff.residuals.length) {
      var res = el("div", "boundary-residuals");
      res.appendChild(el("span", "boundary-residuals-label", "Accepted residuals (shown at equal weight — the honesty rule):"));
      res.appendChild(el("span", null, " " + eff.residuals.join("; ") + ". A boundary book that helps July and slightly hurts a shoulder window is a TRADE, presented as one."));
      p.appendChild(res);
    }
    if (eff.src_confirm) p.appendChild(el("p", "day-comment", "Src-implementation A/B: " + eff.src_confirm + "."));
    if (eff.anchor_weakness) p.appendChild(el("p", "boundary-effect-note", eff.anchor_weakness));
    return p;
  }

  function boundaryFixedCard(node) {
    var f = node.fixed;
    var card = el("div", "boundary-card boundary-card-fixed");
    card.id = "boundary-card-" + node.counterparty;
    var head = el("div", "boundary-card-head");
    head.appendChild(el("span", "boundary-card-title", node.counterparty));
    head.appendChild(el("span", "kind-badge kind-fixed", "FIXED INJECTION · observed schedule"));
    card.appendChild(head);

    card.appendChild(cardField("How it enters",
      "on the " + f.borders.map(function (z) { return z + "–" + node.counterparty; }).join(" and ") +
      " border(s), the observed physical flow is committed as price-taking supply (import) or firm demand (export) at the ex-ante-lagged :v3 value — never same-day."));
    card.appendChild(cardField("Anchor", el("span", "boundary-blank", "— none (not a model)")));
    card.appendChild(cardField("Capability sizing", el("span", "boundary-blank", "— none")));
    card.appendChild(cardField("Ladder", el("span", "boundary-blank", "— none")));
    card.appendChild(cardField("Borders", f.borders.join(", ")));

    // The verbatim "NOT a book" correction (TR).
    if (f.correction) {
      var callout = el("div", "boundary-callout");
      callout.appendChild(el("h4", "boundary-callout-title", "Common misconception — TR is NOT a book"));
      callout.appendChild(el("p", null, f.correction));
      card.appendChild(callout);
    }

    // The "what a TR book would need" roadmap panel (the most instructive one).
    if (f.roadmap && f.roadmap.length) {
      var rm = el("div", "boundary-roadmap-panel");
      rm.appendChild(el("h4", "boundary-exhibit-title", "What a " + node.counterparty + " book would need"));
      var ol = el("ol", "boundary-roadmap-list");
      f.roadmap.forEach(function (step) { ol.appendChild(el("li", null, step)); });
      rm.appendChild(ol);
      card.appendChild(rm);
    } else if (f.roadmap_short) {
      card.appendChild(cardField("Roadmap", f.roadmap_short));
    }
    card.appendChild(el("p", "boundary-effect-note",
      "The absence of a " + node.counterparty + " book is a DECISION, not an oversight."));
    return card;
  }

  // ---- D · the :v3 flow rule -------------------------------------------------
  function renderBoundaryFlowRule(data) {
    var host = $("boundary-flowrule");
    if (!host) return;
    host.textContent = "";
    var fr = data.flow_rule;
    if (!fr) { host.appendChild(boundaryAbsence("Flow-rule descriptor not published.")); return; }
    var steps = el("div", "boundary-flow-steps");
    var d = fr.descriptions || {};
    [["Load-analogue median",
      "Take the delivery day's D-1 load-forecast vector (the ex-ante thermometer), find the 16 trailing-365-day days nearest to it in load shape, take the median of their observed flows on this border. Warm days look like warm days."],
     ["D-2 observed blend",
      "Average that with the D-2 observed flow — the fastest admissible signal, catching a regime change within 48h."],
     ["D-7 Norwegian recency",
      "On Norwegian reservoir borders, add the :v2 D-7 recency component."],
     [":d0 is legacy only",
      "Same-day observed flow is the SEE legacy / byte-identity path ONLY — never the footprint default. Tomorrow's flow does not exist at auction time."]
    ].forEach(function (s, i) {
      var box = el("div", "boundary-flow-step");
      box.appendChild(el("span", "boundary-flow-num", String(i + 1)));
      var body = el("div");
      body.appendChild(el("span", "boundary-flow-step-title", s[0]));
      body.appendChild(el("p", null, s[1]));
      box.appendChild(body);
      steps.appendChild(box);
    });
    host.appendChild(el("p", "day-comment", "Footprint default: :" + fr.footprint_default +
      " (" + (fr.ledger || "").toUpperCase() + "). Legacy: :" + fr.legacy + "."));
    host.appendChild(steps);
    if (d.v3) host.appendChild(el("p", "day-comment", ":v3 in one line — " + d.v3));

    var audit = $("boundary-flowrule-audit");
    if (audit) {
      audit.textContent = "";
      var box = el("div", "boundary-audit-box");
      box.appendChild(el("h4", "boundary-exhibit-title", "We caught our own lookahead — the cv25 audit"));
      box.appendChild(el("p", null, fr.audit_note));
      audit.appendChild(box);
    }
  }

  // ---- E · propagation / trade-wedge ---------------------------------------
  function renderBoundaryPropagation(data) {
    var host = $("boundary-propagation");
    if (!host) return;
    host.textContent = "";
    host.appendChild(el("p", null,
      "A boundary book is just orders in the border zone's book — an import-supply stack tagged owner = \"BOUNDARY:GB\" / strategy boundary_import, and an export-demand stack tagged boundary_export (firm slab + tail). It replaces the fixed injection (its codes are stripped from get_net_imports AND the import backstop), then clears like any other order."));
    var chain = el("div", "boundary-prop-chain");
    ["Viking's cheap GB supply enters DK1", "DK1's price is pulled toward GB's CCGT cost",
     "pass-2 :hydro anchors in the Nordic re-bid against that coupled price",
     "zones that never touch the DK1–GB border move too"].forEach(function (s, i, arr) {
      chain.appendChild(el("span", "boundary-prop-node", s));
      if (i < arr.length - 1) chain.appendChild(el("span", "boundary-prop-arrow", "→"));
    });
    host.appendChild(chain);
    host.appendChild(el("p", "day-comment",
      "The same emergent coupling the scenario surface documents (+demand in DE_LU moves NO2's water value). The trade wedge: the fixed injection we removed (a flat line) vs the flow the elastic book produces (which reverses when the footprint is cheaper than GB). Per-day cleared flows and BOUNDARY-tagged rungs are in the order book →"));
  }

  // ---- footer · roadmap honesty --------------------------------------------
  function renderBoundaryRoadmap(data) {
    var host = $("boundary-roadmap");
    if (!host) return;
    host.textContent = "";
    var items = [
      ["GB the zone is PARKED", "needs an Elexon/BMRS + UKA fundamentals feed before an internal GB clear."],
      ["UA runs on a generic gas anchor", "needs a real UA fundamentals feed to retire :zone_gas_srmc; the firm slice carries it until then."],
      ["TR / AL / MK are fixed injections BY DECISION", "a book needs a defensible anchor, a capability series, and a measured confirm on the coupled footprint. TR's fundamentals (BOTAŞ gas, no EU-ETS, Akkuyu nuclear) are not in our feeds."]
    ];
    items.forEach(function (it) {
      var row = el("div", "boundary-roadmap-row");
      row.appendChild(el("span", "boundary-roadmap-key", it[0]));
      row.appendChild(el("span", null, it[1]));
      host.appendChild(row);
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

  // ---------- honest "live data unavailable" state ----------

  // The ONE consistent empty/error component every view uses when the live
  // plane does not answer. Never a snapshot — an honest message plus a retry
  // action. `host` is cleared and repopulated; `retry` (optional) wires the
  // button. Returns the panel element (for tests).
  function liveUnavailable(host, retry, msg) {
    if (!host) return null;
    host.textContent = "";
    var box = el("div", "live-unavailable");
    box.setAttribute("role", "status");
    box.appendChild(el("p", "lu-title", "Live data unavailable"));
    box.appendChild(el("p", "lu-msg", msg ||
      "This view loads only from the live data API and never substitutes " +
      "synthetic data. The API did not respond."));
    if (retry) {
      var btn = el("button", "lu-retry", "Retry");
      btn.type = "button";
      btn.addEventListener("click", retry);
      box.appendChild(btn);
    }
    host.appendChild(box);
    return box;
  }

  // ---------- view switching ----------

  var VIEW_CRUMBS = {
    horizon: "recent days",
    map: "map",
    boundary: "boundary",
    solver: "solver",
    predict: "predicting RES & loads",
    explorer: "zone explorer",
    board: "scoreboard",
    book: "order book",
    method: "how bids are built",
    cases: "case studies"
  };

  function setView(v) {
    state.view = v;
    $("view-explorer").hidden = v !== "explorer";
    $("view-board").hidden = v !== "board";
    $("view-horizon").hidden = v !== "horizon";
    $("view-map").hidden = v !== "map";
    if ($("view-boundary")) $("view-boundary").hidden = v !== "boundary";
    $("view-solver").hidden = v !== "solver";
    $("view-predict").hidden = v !== "predict";
    $("view-book").hidden = v !== "book";
    if ($("view-method")) $("view-method").hidden = v !== "method";
    $("view-cases").hidden = v !== "cases";
    var crumb = $("crumb-view");
    if (crumb) crumb.textContent = VIEW_CRUMBS[v] ? "/ " + VIEW_CRUMBS[v] : "";
    if (v === "map") loadMap().then(renderMap, function () {
      liveUnavailable($("map-wrap"), function () { setView("map"); },
        "The live data API did not return the map. This site never substitutes " +
        "synthetic data — retry once the API is reachable.");
      $("map-title").textContent = "Live data unavailable";
      $("map-comment").textContent = "";
    });
    if (v === "solver") renderSolver();
    if (v === "predict") loadPredict().then(renderPredict);
    if (v === "book") renderBook();
    if (v === "method") renderMethod();
    if (v === "boundary") renderBoundary();
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
      accent: css.getPropertyValue("--accent").trim(),
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

  // The ±5-day ribbon around "now": the freshest ex-ante (weather-track)
  // forecast per delivery date, for the HZ_PAST settled days before the seam
  // and the first pending (today) + upcoming forecast days after it — one
  // continuous window straddling the present. The "now" seam (drawn in
  // renderHorizon) is the boundary between the last settled actual and the
  // first forecast-only hour; past days overlay the settled actual (+ per-day
  // MAE/bias), today & future show the freshest forecast alone. The window is
  // anchored on the FRONTIER — the first fully-pending (forecast-only) delivery
  // day — so it self-locates from the data alone, without a wall clock.
  // Leads collapsed (directive 1).
  var HZ_PAST = 5, HZ_FUTURE = 5;
  function horizonDays(zoneData) {
    var asc = freshestByDate(weatherDays(zoneData)).slice().reverse();   // oldest -> newest
    if (!asc.length) return [];
    var frontier = asc.length;   // first forecast-only (fully pending) day = today/tomorrow
    for (var i = 0; i < asc.length; i++) {
      if (isPending(asc[i])) { frontier = i; break; }
    }
    var start = Math.max(0, frontier - HZ_PAST);
    var end = Math.min(asc.length, frontier + HZ_FUTURE);
    return asc.slice(start, end);
  }

  function renderHorizon() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) return;
    var days = horizonDays(zoneData);
    $("hz-title").textContent = state.zone + " — the days around now";
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
    var pastN = days.filter(function (d) { return !isPending(d); }).length;
    var futureN = days.length - pastN;
    $("hz-sub").textContent =
      "Freshest ex-ante (weather) forecast per delivery day — settled actual " +
      "overlaid on the days left of “now”, forecast alone ahead of it (" +
      pastN + " back · " + futureN + " ahead) · hours in Europe/Athens (market day)";

    // Retro rows (post data-reset backfill) shown inline, with the reset note.
    var retroDays = days.filter(isRetro);
    if (retroDays.length) {
      var tags = {};
      retroDays.forEach(function (d) { if (d.reset_tag) tags[d.reset_tag] = 1; });
      var tagList = Object.keys(tags);
      wrap.appendChild(el("p", "pending-note",
        retroDays.length + (retroDays.length > 1 ? " days were" : " day was") +
        " reconstructed retroactively after a data reset" +
        (tagList.length ? " (" + tagList.join(", ") + ")" : "") +
        " — shown inline (marked ↺); each prediction stays frozen at its retro compute instant."));
    }

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
      "Hourly ex-ante forecast vs actual across " + pastN + " past and " + futureN +
      " upcoming market days around now, " + state.zone);
    var svg = sc.svg, X = sc.X, Y = sc.Y, m = sc.m;

    // "now" seam: the boundary between the last hour carrying a settled actual
    // and the first forecast-only hour. Everything to its right is pure
    // forecast (no actual yet). Drawn as a faint wash now (behind the paths)
    // and a labelled line after the day paths (on top).
    var lastSettled = -1;
    for (var si = 0; si < n; si++) {
      if (pts[si].a !== null && pts[si].a !== undefined) lastSettled = si;
    }
    var hasSeam = lastSettled >= 0 && lastSettled < n - 1;
    var seamX = lastSettled < 0 ? m.l
      : lastSettled >= n - 1 ? X(n - 1)
      : (X(lastSettled) + X(lastSettled + 1)) / 2;
    if (hasSeam) {
      svg.appendChild(svgEl("rect", {
        x: seamX, y: m.t, width: (m.l + sc.pw) - seamX, height: sc.ph,
        fill: C.sim, opacity: 0.05,
      }));
    }

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
      // past days carry a per-day MAE·bias chip; pending days read "forecast"
      var scored = d.mae !== null && d.mae !== undefined;
      var statusTxt = isPending(d) ? "forecast"
        : scored ? ("MAE " + fmt(d.mae, 1)
            + (d.bias === null || d.bias === undefined ? ""
               : " · " + (d.bias >= 0 ? "+" : "−") + fmt(Math.abs(d.bias), 1)))
        : (isPartial(d) ? "settling" : "settled");
      if (isRetro(d)) statusTxt += " ↺";
      status.textContent = statusTxt;
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

    // the "now" seam line + labels, on top of the day paths
    if (hasSeam) {
      var seamColor = C.accent || C.act;
      svg.appendChild(svgEl("line", {
        x1: seamX, x2: seamX, y1: m.t - 6, y2: m.t + sc.ph,
        stroke: seamColor, "stroke-width": 1.6,
      }));
      var nowLbl = svgEl("text", {
        x: seamX, y: m.t - 10, "text-anchor": "middle",
        fill: seamColor, "font-size": 11, "font-weight": 600,
      });
      nowLbl.textContent = "now";
      svg.appendChild(nowLbl);
      if (seamX < m.l + sc.pw - 60) {
        var fcHint = svgEl("text", {
          x: seamX + 6, y: m.t + 12, "text-anchor": "start",
          fill: C.muted, "font-size": 10,
        });
        fcHint.textContent = "forecast →";
        svg.appendChild(fcHint);
      }
    }

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
      loadLive("map.json").then(function (res) {
        mapState.data = res.json;
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

  var predictState = { manifest: null, reservoir: null, geo: null, scorecard: null,
    skill: null, zone: null, zoneData: {} };

  // Coverage ramp: neutral (load-covered) -> deep green (RES ≥ load, collapse risk).
  var RAMP_COVER = ["#E7DFC9", "#B9CDA0", "#7FB077", "#3F9B6D", "#1F7A4A", "#0F5A34"];
  var COVER_DOMAIN = [0, 1.2];

  // The four surfaces of the Predictions family (hub + 3). `overview` is the hub.
  var PREDICT_TARGETS = ["overview", "load", "solar", "wind"];
  var PREDICT_TARGET_LABELS = { overview: "Overview", load: "Load", solar: "Solar", wind: "Wind" };

  // Per-target driver subsets (§3.2/4.2/5.2) — each page shows only its own
  // physics-relevant knobs. Keys index the zone parquet `series`. Solar's
  // clearness / sun-elevation are model-internal derived features (not exported),
  // called out in the physics panel rather than charted from absent data.
  var TARGET_DRIVERS = {
    load:  [["temp_c", "Temperature", "°C"], ["ghi_wm2", "Solar radiation (GHI)", "W/m²"]],
    solar: [["ghi_wm2", "Solar radiation (GHI)", "W/m²"], ["cloud_pct", "Cloud cover", "%"],
            ["pressure_hpa", "Surface pressure", "hPa"]],
    wind:  [["wind100_ms", "Wind speed (100 m)", "m/s"], ["cloud_pct", "Cloud cover", "%"],
            ["pressure_hpa", "Surface pressure", "hPa"]],
  };
  // The single target series each page plots (pred / ENTSO-E ref / settled actual).
  var TARGET_OUTPUT = {
    load:  { pred: "pred_load_mw",  ref: "ref_load_mw",  act: "act_load_mw",  title: "Load" },
    solar: { pred: "pred_solar_mw", ref: "ref_solar_mw", act: "act_solar_mw", title: "Solar" },
    wind:  { pred: "pred_wind_mw",  ref: "ref_wind_mw",  act: "act_wind_mw",  title: "Wind" },
  };
  // Holiday-map classification (rollout-39.md amendment 1, committed source):
  // Orthodox-Easter zones, Western-Easter zones; all others carry an empty map.
  var HOLIDAY_ORTHODOX = ["GR", "BG", "RO", "RS"];
  var HOLIDAY_WESTERN = ["ES", "DE_LU", "SE1", "SE2", "SE3", "SE4"];
  // Offshore-heavy wind zones — the ML's favourable regime (plan §5.1).
  var WIND_OFFSHORE = ["NL", "DK1", "DK2", "BE"];

  function loadPredict() {
    // Each panel degrades to an EMPTY (honest "warming up / fills next run")
    // structure on failure — an absent panel, never fabricated numbers.
    var pM = predictState.manifest ? Promise.resolve() :
      loadLive("inputs/manifest.json").then(function (r) {
        predictState.manifest = r.json;
      }, function () { predictState.manifest = { map: [], pilot_zones: [] }; });
    var pR = predictState.reservoir ? Promise.resolve() :
      loadLive("inputs/reservoir.json").then(function (r) {
        predictState.reservoir = r.json;
      }, function () { predictState.reservoir = { zones: {} }; });
    // The two additive artifacts (plan §7) — model-card scores + per-lead skill.
    // Non-fatal: an absent file leaves the card/strip in a graceful pending state.
    var pS = predictState.scorecard ? Promise.resolve() :
      loadLive("inputs/scorecard.json").then(function (r) {
        predictState.scorecard = r.json;
      }, function () { predictState.scorecard = { scores: [], winner_counts: {} }; });
    var pK = predictState.skill ? Promise.resolve() :
      loadLive("inputs/skill.json").then(function (r) {
        predictState.skill = r.json;
      }, function () { predictState.skill = { status: "warming_up", skill: [] }; });
    var pG = predictState.geo ? Promise.resolve() :
      (mapState.geo ? (predictState.geo = mapState.geo, Promise.resolve()) :
        fetchJSON("./geo/zones.geojson").then(function (g) { predictState.geo = g; mapState.geo = mapState.geo || g; }));
    return Promise.all([pM, pR, pS, pK, pG]);
  }

  function scorecardRow(zone, target) {
    var sc = predictState.scorecard;
    if (!sc || !sc.scores) return null;
    for (var i = 0; i < sc.scores.length; i++) {
      if (sc.scores[i].zone === zone && sc.scores[i].target === target) return sc.scores[i];
    }
    return null;
  }
  function skillRows(zone, target) {
    var sk = predictState.skill;
    if (!sk || !sk.skill) return [];
    return sk.skill.filter(function (r) { return r.zone === zone && r.target === target; });
  }
  // The live per-(zone,target) provenance: prefer the zone parquet's own src label
  // (what actually served the row); fall back to the reconciled scorecard winner.
  function winnerOf(zone, target) {
    var zd = predictState.zoneData[zone];
    if (zd && zd.src && zd.src[target]) return zd.src[target];
    var row = scorecardRow(zone, target);
    return row ? row.winner : null;
  }

  function coverMap() {
    var m = {};
    ((predictState.manifest && predictState.manifest.map) || []).forEach(function (r) { m[r.zone] = r; });
    return m;
  }

  // The footprint coverage map (midday RES coverage, collapse-risk flagged) —
  // the hub centrepiece. Unchanged from the pre-hub predict page.
  function renderPmap() {
    var man = predictState.manifest;
    var wrap = $("pmap-wrap");
    if (!wrap) return;
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
  }

  function loadPredictZone(zone) {
    if (predictState.zoneData[zone]) return Promise.resolve(predictState.zoneData[zone]);
    return loadLive("inputs/" + encodeURIComponent(zone) + ".json").then(function (r) {
      predictState.zoneData[zone] = r.json;
      return r.json;
    });
  }

  // Shared zone state across the sub-nav (plan §2.1): pick GR on Solar, switch to
  // Wind, still GR. Backed by the app-wide state.zone (promoted to &zone=).
  function selectPredictZone(zone) {
    state.zone = zone;
    predictState.zone = zone;
    var sel = $("predict-zone-select"); if (sel) sel.value = zone;
    renderPredict();
    if (typeof writeHash === "function") writeHash();
  }

  // ---------- Predictions hub + target dispatcher ----------

  function buildPredictSubnav() {
    var nav = $("predict-subnav");
    if (!nav) return;
    nav.textContent = "";
    PREDICT_TARGETS.forEach(function (t) {
      var b = el("button", null, PREDICT_TARGET_LABELS[t]);
      b.type = "button";
      b.dataset.target = t;
      b.setAttribute("aria-pressed", String((state.predictTarget || "overview") === t));
      b.addEventListener("click", function () {
        state.predictTarget = t;
        renderPredict();
        writeHash();
      });
      nav.appendChild(b);
    });
  }

  function predictZones() {
    var man = predictState.manifest;
    var zs = (man && man.zones && man.zones.length) ? man.zones.slice() :
      (state.scoreboard ? state.scoreboard.zones.slice() : ["GR"]);
    zs.sort(function (a, b) { return a === "GR" ? -1 : b === "GR" ? 1 : (a < b ? -1 : 1); });
    return zs;
  }

  function syncPredictZoneSelect() {
    var sel = $("predict-zone-select");
    if (!sel) return;
    var zs = predictZones();
    if (zs.indexOf(state.zone) === -1) state.zone = zs[0];
    if (sel.children && sel.children.length !== zs.length) sel.textContent = "";
    if (!sel.children || !sel.children.length) {
      zs.forEach(function (z) { var o = el("option", null, z); o.value = z; sel.appendChild(o); });
    }
    sel.value = state.zone;
    predictState.zone = state.zone;
  }

  function renderPredict() {
    buildPredictSubnav();
    syncPredictZoneSelect();
    var tgt = state.predictTarget || "overview";
    var isHub = tgt === "overview";
    var hub = $("predict-hub"), tv = $("predict-target-view");
    if (hub) hub.hidden = !isHub;
    if (tv) tv.hidden = isHub;
    if (isHub) renderPredictHub();
    else renderPredictTarget(tgt);
  }

  function renderPredictHub() {
    renderPmap();
    var contract = $("predict-contract-hub");
    if (contract) { contract.textContent = ""; contract.appendChild(buildContractStrip(null, null)); }
    var fam = $("predict-family");
    if (fam) { fam.textContent = ""; fam.appendChild(buildFamilyTable()); }
    var cards = $("predict-target-cards");
    if (cards) { cards.textContent = ""; cards.appendChild(buildTargetCards()); }
    var rbox = $("predict-reservoir-hub");
    if (rbox) {
      var resv = predictState.reservoir && predictState.reservoir.zones &&
        predictState.reservoir.zones[state.zone];
      if (resv && resv.length) { rbox.hidden = false; rbox.textContent = "";
        rbox.appendChild(buildReservoir(state.zone, resv)); }
      else rbox.hidden = true;
    }
  }

  function renderPredictTarget(target) {
    var host = $("predict-target-view");
    if (!host) return;
    host.textContent = "";
    var zone = state.zone;
    var zd = predictState.zoneData[zone];
    if (!zd) {
      host.appendChild(el("p", "chart-sub", "Loading " + zone + " inputs…"));
      loadPredictZone(zone).then(function () { renderPredictTarget(target); }, function () {
        liveUnavailable(host, function () { renderPredictTarget(target); },
          "The live data API did not return " + zone + "'s prediction inputs. This " +
          "site never substitutes synthetic data — retry once the API is reachable.");
      });
      return;
    }
    host.appendChild(buildTargetView(zone, target));
  }

  // ---------- A. Honest fitted-model contract strip (every page) ----------

  function buildContractStrip(zone, target) {
    var card = el("div", "contract-strip");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", "chart-title", "The honest fitted-model contract"));
    card.appendChild(head);
    var chips = el("div", "contract-chips");
    var tname = target || "load / solar / wind";
    chips.appendChild(el("span", "chip",
      "target: the TSO's published D-1 " + tname + " forecast — what the auction clears on, not outturn"));
    chips.appendChild(el("span", "chip",
      "vintage: GFS previous_day1 (issued D-1) — never across the 12:00 CET gate"));
    if (target && zone) {
      var w = winnerOf(zone, target);
      if (w === "ml" || w === "pack") {
        chips.appendChild(srcBadge(target, w));
      } else if (w === "skip") {
        chips.appendChild(el("span", "chip", target + ": no resource — not modeled"));
      }
    }
    card.appendChild(chips);
    var p = el("p", "chart-sub",
      "If our predicted input equals the TSO's forecast, the ex-ante weather price track " +
      "converges to the reference track — so error is measured against what the market used. ");
    var a = el("a", null, "The full recipe →");
    a.href = "https://github.com/philokalia-ai/energy-markets/blob/main/docs/predictions.md";
    p.appendChild(a);
    card.appendChild(p);
    return card;
  }

  // ---------- B. Per-zone model card ----------

  function statCell(label, val, sub) {
    var d = el("div", "mc-stat");
    d.appendChild(el("span", "mc-stat-label", label));
    d.appendChild(el("span", "mc-stat-val", val));
    if (sub) d.appendChild(el("span", "mc-stat-sub", sub));
    return d;
  }

  function buildModelCard(zone, target) {
    var card = el("div", "model-card");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", "chart-title", zone + " · " + TARGET_OUTPUT[target].title + " — model card"));
    card.appendChild(head);
    var row = scorecardRow(zone, target);
    var winner = row ? row.winner : winnerOf(zone, target);

    if (winner === "skip") {
      card.appendChild(el("p", "chart-sub",
        "No " + target + " regime in " + zone + " — this zone has no meaningful " + target +
        " resource (decided ex-ante from the installed-scale signal), so it is not modeled; the " +
        "clear takes a pack/zero passthrough. Not a model loss — an honest scope boundary."));
      return card;
    }

    // Verdict line — names the shipped model and, on a corr-guard demotion, tells
    // the honest "ML beaten by pack on corr — pack ships" story.
    var verdict = el("p", "mc-verdict");
    var demoted = row && winner === "pack" && row.mae_new != null && row.mae_base != null &&
      row.corr_new != null && row.corr_base != null &&
      row.mae_new < row.mae_base && row.corr_new < row.corr_base;
    verdict.appendChild(srcBadge(target, winner));
    verdict.appendChild(document.createTextNode(" "));
    if (winner === "ml") {
      verdict.appendChild(document.createTextNode(
        "LightGBM ships — it beat the committed linear pack on the frozen out-of-sample scorecard."));
    } else if (demoted) {
      verdict.appendChild(document.createTextNode(
        "The linear pack ships. The ML cut MAE (" + fmt(row.mae_new, 1) + " vs " + fmt(row.mae_base, 1) +
        ") but LOST on correlation (" + fmt(row.corr_new, 3) + " vs " + fmt(row.corr_base, 3) +
        ") — beaten by the pack on corr, so the pack ships (the corr-guard verdict)."));
    } else {
      verdict.appendChild(document.createTextNode(
        "The committed linear pack ships — it won the frozen out-of-sample scorecard here."));
    }
    card.appendChild(verdict);

    if (row) {
      var stats = el("div", "mc-stats");
      var maeDelta = (row.mae_new != null && row.mae_base != null) ?
        fmt(row.mae_new - row.mae_base, 1) + " vs pack" : null;
      stats.appendChild(statCell("MAE (new)", row.mae_new != null ? fmt(row.mae_new, 1) : "—", maeDelta));
      stats.appendChild(statCell("MAE (pack)", row.mae_base != null ? fmt(row.mae_base, 1) : "—", "€/MWh-scale MW"));
      stats.appendChild(statCell("corr (new)", row.corr_new != null ? fmt(row.corr_new, 3) : "—",
        row.corr_base != null ? "pack " + fmt(row.corr_base, 3) : null));
      stats.appendChild(statCell("bias (new)", row.bias_new != null ? fmt(row.bias_new, 1) : "—", "pred − ref"));
      stats.appendChild(statCell("n valid", row.n_valid != null ? fmt(row.n_valid, 0) : "—",
        predictState.scorecard && predictState.scorecard.valid_window ?
          predictState.scorecard.valid_window.first + "…" + predictState.scorecard.valid_window.last : null));
      card.appendChild(stats);
    } else {
      card.appendChild(el("p", "chart-sub", "VALID scores fill when the scorecard exports."));
    }

    // Collapse metrics are a SOLAR-only, first-class card element.
    if (target === "solar") {
      var col = el("div", "mc-collapse");
      col.appendChild(el("h3", "panel-title", "Collapse classification (hit / false-alarm)"));
      var hasCollapse = row && row.collapse && row.collapse.hit_rate != null;
      if (hasCollapse) {
        var cg = el("div", "mc-stats");
        cg.appendChild(statCell("hit-rate", fmt(row.collapse.hit_rate * 100, 0) + "%", "≤ €5 caught"));
        cg.appendChild(statCell("false-alarm", fmt(row.collapse.fa_rate * 100, 0) + "%", "cried collapse, wasn't"));
        col.appendChild(cg);
      } else {
        var note = predictState.scorecard && predictState.scorecard.collapse_note ?
          predictState.scorecard.collapse_note :
          "Per-zone collapse hit/false-alarm metrics fill in a later pass.";
        col.appendChild(el("p", "chart-sub warming", "Pending — " + note));
      }
      card.appendChild(col);
    }
    return card;
  }
  var renderModelCard = buildModelCard;

  // ---------- C. Per-lead skill strip ----------

  function buildSkill(zone, target) {
    var card = el("div", "skill-strip");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", "chart-title", "Per-lead input skill (D-1 → D-7)"));
    card.appendChild(head);
    var rows = skillRows(zone, target);
    var sk = predictState.skill;
    if (!rows.length) {
      var msg = (sk && sk.note) ? sk.note :
        "Per-lead skill fills as the GFS vintage archive accumulates.";
      card.appendChild(el("p", "chart-sub warming",
        "Warming up — the honest degradation story (how much skill we lose predicting D-2…D-7 " +
        "ahead) fills lead by lead as the archived vintages land. " + msg));
      return card;
    }
    rows.sort(function (a, b) { return a.lead_days - b.lead_days; });
    var leads = rows.map(function (r) { return "D-" + r.lead_days; });
    var accent = "#2C6BA8";
    var box = el("div", "predict-drivers");
    driverMiniChart(box, { title: "MAE by lead", unit: "MW", hours: leads,
      series: [{ label: "MAE", color: accent, values: rows.map(function (r) { return r.mae; }) }] });
    driverMiniChart(box, { title: "Correlation by lead", unit: "r", hours: leads,
      series: [{ label: "corr", color: "#1F7A4A", values: rows.map(function (r) { return r.corr; }) }] });
    card.appendChild(box);
    return card;
  }
  var renderSkill = buildSkill;

  // ---------- D/E. knobs + output chart ----------

  function buildKnobs(zone, target) {
    var card = el("div", "predict-knobs-card");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", "chart-title", "The knobs — what the model reads from the weather"));
    head.appendChild(el("p", "chart-sub",
      "Only " + TARGET_OUTPUT[target].title + "'s physics-relevant drivers, from the same D-1 GFS " +
      "vintage the forecast consumes."));
    card.appendChild(head);
    var zd = predictState.zoneData[zone];
    var box = el("div", "predict-drivers");
    var accent = "#2C6BA8";
    (TARGET_DRIVERS[target] || []).forEach(function (d) {
      driverMiniChart(box, { title: d[1], unit: d[2], hours: zd.hours,
        series: [{ label: d[1], color: accent, values: zd.series[d[0]] }] });
    });
    card.appendChild(box);
    return card;
  }

  function buildOutput(zone, target) {
    var card = el("div", "predict-output-card");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", "chart-title",
      TARGET_OUTPUT[target].title + " — predicted vs ENTSO-E reference vs settled actual"));
    card.appendChild(head);
    var zd = predictState.zoneData[zone];
    var C = chartColors();
    var cols = TARGET_OUTPUT[target];
    var box = el("div", "predict-outputs");
    driverMiniChart(box, { title: cols.title, unit: "MW", hours: zd.hours, big: true,
      series: [
        { label: "predicted", color: C.sim, values: zd.series[cols.pred] },
        { label: "ENTSO-E reference", color: "#B08A3E", values: zd.series[cols.ref], dashed: true },
        { label: "actual", color: C.act, values: zd.series[cols.act] },
      ] });
    card.appendChild(box);
    return card;
  }

  // Bin y over x into `nb` equal-width buckets; returns {labels, means} for the
  // non-empty buckets — the primitive behind the temperature-response and
  // power-curve physics charts (fed straight into driverMiniChart).
  function binnedCurve(xs, ys, nb, unitFmt) {
    var pts = [];
    for (var i = 0; i < xs.length; i++) {
      var x = xs[i], y = ys[i];
      if (x == null || y == null || !isFinite(x) || !isFinite(y)) continue;
      pts.push([x, y]);
    }
    if (!pts.length) return { labels: [], means: [] };
    var lo = Math.min.apply(null, pts.map(function (p) { return p[0]; }));
    var hi = Math.max.apply(null, pts.map(function (p) { return p[0]; }));
    var w = (hi - lo) / nb || 1;
    var sum = new Array(nb).fill(0), cnt = new Array(nb).fill(0);
    pts.forEach(function (p) {
      var b = Math.min(nb - 1, Math.floor((p[0] - lo) / w));
      sum[b] += p[1]; cnt[b] += 1;
    });
    var labels = [], means = [];
    for (var b = 0; b < nb; b++) {
      if (!cnt[b]) continue;
      labels.push(unitFmt(lo + (b + 0.5) * w));
      means.push(sum[b] / cnt[b]);
    }
    return { labels: labels, means: means };
  }

  // Midday (UTC 9–14) mean RES-coverage per delivery date — the input-level
  // collapse signal, extended from the hub map's single day to a trailing window.
  function middayCoverageByDate(zd) {
    var byDate = {};
    for (var i = 0; i < zd.hours.length; i++) {
      var h = new Date(zd.hours[i]).getUTCHours();
      if (h < 9 || h > 14) continue;
      var d = zd.hours[i].slice(0, 10);
      var res = zd.series.pred_res_mw[i], load = zd.series.pred_load_mw[i];
      if (res == null || load == null || !(load > 0)) continue;
      var b = byDate[d] || (byDate[d] = { res: 0, load: 0, n: 0 });
      b.res += res; b.load += load; b.n += 1;
    }
    var dates = Object.keys(byDate).sort();
    return { dates: dates, cov: dates.map(function (d) { return byDate[d].res / byDate[d].load; }) };
  }

  // ---------- F. physics panels (target-specific) ----------

  function buildLoadPhysics(zone, target) {
    var card = el("div", "physics-panel");
    card.appendChild(el("h2", "chart-title", "Load physics — a calendar-and-temperature machine with memory"));
    var zd = predictState.zoneData[zone];
    var box = el("div", "predict-drivers");
    var tr = binnedCurve(zd.series.temp_c, zd.series.pred_load_mw, 14,
      function (v) { return fmt(v, 0) + "°"; });
    driverMiniChart(box, { title: "Temperature-response curve", unit: "MW vs °C", hours: tr.labels,
      series: [{ label: "pred load", color: "#C4643C", values: tr.means }] });
    card.appendChild(box);
    card.appendChild(el("p", "chart-sub",
      "Predicted load binned against pop-weighted temperature — the U-shape: heating below " +
      "~16.5 °C (HDH base), cooling above ~21 °C (CDH base)."));

    var holClass = HOLIDAY_ORTHODOX.indexOf(zone) !== -1 ? "Orthodox-Easter map (Julian/Meeus computus)" :
      HOLIDAY_WESTERN.indexOf(zone) !== -1 ? "Western-Easter map" : null;
    var hp = el("p", "chart-sub");
    hp.appendChild(el("strong", null, "Calendar & holidays. "));
    hp.appendChild(document.createTextNode(holClass ?
      (zone + " carries a national holiday map (" + holClass + "), so movable feasts enter the model.") :
      (zone + " carries NO active holiday map (empty set → is_hol ≡ 0) — an honest gap; where holidays " +
        "matter the pack can win here, and the winner selection defends it.")));
    card.appendChild(hp);

    var ar = el("p", "chart-sub");
    ar.appendChild(el("strong", null, "Autoregression. "));
    ar.appendChild(document.createTextNode(
      "The model already knows the D-1 (ar1) and D-7 (ar7) same-hour day-ahead load forecasts — " +
      "both admissible at the gate — so persistence is an input, not a leak."));
    card.appendChild(ar);
    return card;
  }

  function buildSolarPhysics(zone, target) {
    var card = el("div", "physics-panel");
    card.appendChild(el("h2", "chart-title", "Solar physics — the collapse cliff"));
    var zd = predictState.zoneData[zone];
    if (winnerOf(zone, "solar") === "skip") {
      card.appendChild(el("p", "chart-sub",
        zone + " has no meaningful solar regime — the collapse cliff does not apply here."));
      return card;
    }
    var mc = middayCoverageByDate(zd);
    var box = el("div", "predict-drivers");
    driverMiniChart(box, { title: "Midday RES-coverage cliff", unit: "RES ÷ load", hours: mc.dates,
      series: [
        { label: "midday coverage", color: "#1F7A4A", values: mc.cov },
        { label: "collapse threshold", color: "#B08A3E", values: mc.dates.map(function () { return 1.0; }), dashed: true },
      ] });
    card.appendChild(box);
    card.appendChild(el("p", "chart-sub",
      "Midday (Athens ~11–16) predicted wind+solar ÷ load across recent days. Days that cross ≥ 1.0 " +
      "are where price-taker RES meets or exceeds demand — the regime where the midday price can collapse."));
    var why = el("p", "chart-sub");
    why.appendChild(el("strong", null, "Why a small error flips it. "));
    why.appendChild(document.createTextNode(
      "Near the threshold a small solar-forecast error flips whether the midday price collapses (≤ €5 / " +
      "negative) or not — a classification that dominates the continuous MAE there. Solar is predicted as a " +
      "ratio against the fleet's trailing-30-day p95 capacity (cap95_solar), so a growing fleet doesn't " +
      "drift the forecast; the prediction is night-clamped to 0 at sun-elevation 0."));
    card.appendChild(why);
    card.appendChild(el("p", "chart-sub warming",
      "cap95_solar growth strip and clearness / sun-elevation knobs are model-internal derived features, " +
      "not in the exported input plane yet — they fill when the driver export widens."));
    return card;
  }

  function buildWindPhysics(zone, target) {
    var card = el("div", "physics-panel");
    card.appendChild(el("h2", "chart-title", "Wind physics — the power curve, and where the pack beats the ML"));
    var zd = predictState.zoneData[zone];
    if (winnerOf(zone, "wind") === "skip") {
      card.appendChild(el("p", "chart-sub",
        zone + " has no meaningful wind regime — not modeled."));
      return card;
    }
    var pc = binnedCurve(zd.series.wind100_ms, zd.series.pred_wind_mw, 14,
      function (v) { return fmt(v, 0); });
    var box = el("div", "predict-drivers");
    driverMiniChart(box, { title: "Power curve", unit: "MW vs m/s", hours: pc.labels,
      series: [{ label: "pred wind", color: "#2C6BA8", values: pc.means }] });
    card.appendChild(box);
    card.appendChild(el("p", "chart-sub",
      "Predicted wind binned against 100 m wind speed — the cut-in → ramp → rated shape the physical " +
      "pack encodes and the ML approximates."));

    var w = winnerOf(zone, "wind");
    var hp = el("p", "chart-sub");
    hp.appendChild(el("strong", null, "Pack-vs-ML honesty. "));
    hp.appendChild(document.createTextNode(w === "pack" ?
      (zone + "'s wind ships the committed physical PACK, not the ML. On onshore / low-penetration " +
        "fleets the monotone physical curve generalizes better than a boosted tree on a short record — " +
        "a feature, not a caveat: the pack wins 25 of the 32 modeled wind zones.") :
      (zone + "'s wind ships the ML — it beat the pack here. Offshore-heavy fleets are the ML's strong ground.")));
    card.appendChild(hp);
    if (WIND_OFFSHORE.indexOf(zone) !== -1) {
      card.appendChild(el("p", "chart-sub",
        zone + " is offshore-heavy — the ML's favourable regime."));
    }
    card.appendChild(el("p", "chart-sub warming",
      "cap95_wind growth strip is a model-internal ratio denominator, not in the exported input plane yet."));
    return card;
  }

  var TARGET_PHYSICS = { load: buildLoadPhysics, solar: buildSolarPhysics, wind: buildWindPhysics };

  // The shared skeleton (A → F), composed for one (zone, target). Pure — reads
  // predictState; returned as one element so it renders offline and under test.
  function buildTargetView(zone, target) {
    var view = el("div", "predict-target");
    [buildContractStrip(zone, target),
     buildModelCard(zone, target),
     buildSkill(zone, target),
     buildKnobs(zone, target),
     buildOutput(zone, target),
     TARGET_PHYSICS[target](zone, target)].forEach(function (node) {
      var wrap = el("div", "chart-card"); wrap.appendChild(node); view.appendChild(wrap);
    });
    return view;
  }

  // ---------- hub composites ----------

  function winnerChip(zone, target) {
    var w = winnerOf(zone, target) || (scorecardRow(zone, target) || {}).winner;
    var row = scorecardRow(zone, target);
    var span = el("span", "fam-cell fam-" + (w || "na"));
    span.appendChild(el("span", "fam-badge", w === "ml" ? "ML" : w === "pack" ? "pack" : w === "skip" ? "skip" : "—"));
    if (row && row.corr_new != null && w !== "skip") span.appendChild(el("span", "fam-corr", fmt(row.corr_new, 2)));
    if (w === "ml" || w === "pack") {
      span.setAttribute("role", "button"); span.tabIndex = 0;
      span.addEventListener("click", function () {
        state.zone = zone; predictState.zone = zone; state.predictTarget = target;
        var sel = $("predict-zone-select"); if (sel) sel.value = zone;
        renderPredict(); writeHash();
      });
    }
    return span;
  }

  function buildFamilyTable() {
    var card = el("div", "family-card");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", "chart-title", "The family — per-zone winner across all three targets"));
    var wc = (predictState.scorecard && predictState.scorecard.winner_counts) || {};
    var total = (wc.ml || 0) + (wc.pack || 0) + (wc.skip || 0);
    head.appendChild(el("p", "chart-sub",
      (wc.ml || 0) + " of " + (total || 117) + " zone-targets ship the NEW LightGBM model; " +
      (wc.pack || 0) + " keep the linear pack; " + (wc.skip || 0) + " have no resource (not modeled). " +
      "Each cell links into that zone's target page."));
    card.appendChild(head);
    var scroll = el("div", "table-scroll");
    var table = el("table", "data-table");
    var thead = el("thead"); var htr = el("tr");
    ["zone", "load", "solar", "wind"].forEach(function (h) { htr.appendChild(el("th", null, h)); });
    thead.appendChild(htr); table.appendChild(thead);
    var tbody = el("tbody");
    predictZones().forEach(function (z) {
      var tr = el("tr");
      tr.appendChild(el("td", null, z));
      ["load", "solar", "wind"].forEach(function (t) {
        var td = el("td"); td.appendChild(winnerChip(z, t)); tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
    table.appendChild(tbody); scroll.appendChild(table); card.appendChild(scroll);
    return card;
  }

  function buildTargetCards() {
    var wrap = el("div", "predict-cards-grid");
    var wc = (predictState.scorecard && predictState.scorecard.winner_counts) || {};
    var meta = {
      load:  ["Calendar · temperature · holidays · autoregression.", "near-universal ML win"],
      solar: ["Capacity growth + the collapse question — midday is the whole game.", "owns collapse"],
      wind:  ["Power curves — where the physical pack still beats the ML.", "the honest pack-vs-ML split"],
    };
    ["load", "solar", "wind"].forEach(function (t) {
      var c = el("div", "predict-card case-stat");
      c.setAttribute("role", "button"); c.tabIndex = 0;
      c.appendChild(el("span", "cs-label", PREDICT_TARGET_LABELS[t]));
      c.appendChild(el("span", "predict-card-teaser", meta[t][0]));
      c.appendChild(el("span", "cs-sub", meta[t][1]));
      c.addEventListener("click", function () { state.predictTarget = t; renderPredict(); writeHash(); });
      wrap.appendChild(c);
    });
    return wrap;
  }

  function buildReservoir(zone, resv) {
    var card = el("div", "reservoir-card");
    var head = el("div", "chart-head");
    head.appendChild(el("h2", "chart-title", "Hydro reservoir state — " + zone + " (price-side)"));
    head.appendChild(el("p", "chart-sub",
      "Weekly reservoir fill ratio and dryness — a hydro water-value / PRICE knob, not a RES/load " +
      "input. Shown here on the hub, clearly out of scope for the input models (pending the price pillars)."));
    card.appendChild(head);
    var box = el("div", "predict-drivers");
    var wks = resv.map(function (w) { return w.week_start; });
    driverMiniChart(box, { title: "Reservoir fill ratio", unit: "share of 52-wk max", hours: wks,
      series: [{ label: "fill ratio", color: "#2C6BA8", values: resv.map(function (w) { return w.fill_ratio; }) }] });
    driverMiniChart(box, { title: "Reservoir dryness", unit: "vs prior-year median", hours: wks,
      series: [{ label: "dryness", color: "#C4643C", values: resv.map(function (w) { return w.dryness; }) }] });
    card.appendChild(box);
    return card;
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

  // ---- strategy taxonomy: the honest source-side "WHY" of each block --------
  // The book builder writes each block's strategy label into the parquet
  // `strategy` column; the worker (shapeBook) indexes them into book.strategies;
  // here we turn a label into a short `label` (tooltip line + table cell) and a
  // longer `explain` (the table's explanation column). Parametric peak tranches
  // arrive as "peak_tranche_<k>" — strategyMeta strips the numeric suffix so the
  // single "peak_tranche" row covers them all.
  //
  // SINGLE SOURCE OF TRUTH (pillar-5 §5.1): the NAMES + short `label`s are the
  // hand-maintained display contract. The long `explain` text is OVERLAID at
  // runtime from the GENERATED glossary (book_methodology.json →
  // STRATEGY_DESCRIPTIONS, in loadMethodology), so the production book table and
  // the methodology page cannot drift. The strings below are only the offline
  // fallback for when that generated object is unavailable (fixtures/tests).
  var STRATEGY_LABELS = {
    must_run_deep:            { label: "must-run · deep block", explain: "Technical-minimum block bid near €0 (5% of SRMC) — shutting down and restarting costs more than running below cost." },
    must_run_rest:            { label: "must-run · remainder", explain: "The rest of minimum load bid below SRMC (start-up cost amortised over the committed hours)." },
    srmc_base:                { label: "SRMC base tranche", explain: "Base tranche at short-run marginal cost: fuel / efficiency + CO₂ + O&M, with no scarcity markup." },
    peak_tranche:             { label: "peak tranche", explain: "Upper capacity priced above cost for the scarcity margin plus peak-hour strategic bidding." },
    water_value_gas_anchored: { label: "water value · gas-anchored", explain: "Reservoir opportunity cost anchored to gas SRMC — a premium at peak, boosted when the reservoir is dry." },
    water_value_reservoir:    { label: "water value · reservoir", explain: "Shadow price of stored water — near-free when reservoirs are full, rising toward the thermal alternative as they empty." },
    water_value_anchored:     { label: "water value · coupled anchor", explain: "Export opportunity cost set to the pass-1 coupled reference price (two-pass anchor)." },
    res_forecast:             { label: "RES forecast", explain: "Renewable forecast offered as a price-taker (support schemes make output price-insensitive); floored negative in a solar-surplus regime." },
    import_fixed:             { label: "scheduled import", explain: "Net scheduled cross-border imports injected as price-taking supply." },
    ref_priced_export:        { label: "ref-priced export", explain: "Net export re-priced at the coupled reference so the exporter curtails under domestic stress." },
    export_demand:            { label: "scheduled export", explain: "Net scheduled cross-border exports taken as firm demand at the price cap." },
    import_backstop:          { label: "import backstop", explain: "Ex-ante elastic import headroom beyond the endogenous ATC, priced above every domestic tranche — binds only when the book would otherwise hit the cap." },
    boundary_import:          { label: "boundary import", explain: "Out-of-footprint neighbour import supply, laddered on the neighbour's own SRMC over the border's demonstrated capability." },
    boundary_export:          { label: "boundary export", explain: "Out-of-footprint neighbour export demand over the border's demonstrated capability (firm base slice + elastic tail)." },
    demand_firm:              { label: "firm demand", explain: "Inelastic demand at the price cap (must-serve load)." },
    demand_elastic:           { label: "elastic demand", explain: "Price-sensitive demand tail — curtails above the elastic bid price." },
    extra:                    { label: "scenario order", explain: "Added via the extra_orders scenario hook." },
    strategist:               { label: "strategist order", explain: "Produced by the strategist scenario hook (replaces the source ladder)." },
  };
  // Resolve a raw strategy label (incl. "peak_tranche_<k>") to {label, explain};
  // null for an empty/unknown label (older books, or a not-yet-mapped name).
  function strategyMeta(strat) {
    if (!strat) return null;
    if (STRATEGY_LABELS[strat]) return STRATEGY_LABELS[strat];
    var base = String(strat).replace(/_\d+$/, "");
    return STRATEGY_LABELS[base] || null;
  }

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
    unitsPromise = loadLive("units").then(
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
    flowsPromise[date] = loadLive("flows/" + date).then(
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
    return loadLive("books/" + encodeURIComponent(zone) + "/" + date).then(
      function (res) { state.bookCache[key] = res.json; return res.json; },
      function () { state.bookCache[key] = null; return null; }   // no book for this day
    );
  }

  // Put the per-block table host into a single-message state (loading skeleton /
  // empty / error), replacing ANY previously-rendered table. The table shares
  // the chart's lifecycle: every selector change clears it here first, so a stale
  // table can never outlive its selection (bound as tightly as the chart wrap).
  function bookTableMessage(msg, cls) {
    var host = $("book-table");
    if (!host) return;
    host.textContent = "";
    host.appendChild(el("p", cls || "bt-note", msg));
  }

  function renderBook() {
    var zoneData = state.zoneCache[state.zone];
    if (!zoneData) {
      loadZone(state.zone).then(renderBook, function () {
        $("book-title").textContent = state.zone + " — live data unavailable";
        $("book-legend").textContent = "";
        $("book-comment").textContent = "";
        liveUnavailable($("book-wrap"), function () { renderBook(); },
          "The live data API did not return " + state.zone + "'s data. This site " +
          "never substitutes synthetic data — retry once the API is reachable.");
        bookTableMessage("Live data unavailable for " + state.zone + ".");
      });
      return;
    }
    if ($("bzone-select")) $("bzone-select").value = state.zone;
    // Warm the methodology object (+ its glossary overlay) so the "explain this
    // block" popovers can decompose a block's price. Best-effort, non-blocking;
    // if it isn't served the popover shows its honest no-decompose path.
    loadMethodology().catch(function () {});

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
      bookTableMessage("No order book captured for " + state.zone + " yet.");
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
    // Clear the table for the NEW selection immediately (skeleton), so the
    // previous day/zone/hour's table cannot linger while this one loads.
    bookTableMessage("Loading order book…", "pending-note");

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
        // explicit empty state IN PLACE of the table (no stale rows).
        bookTableMessage("No order book captured for " + dayLabel(state.bookDay) + ".");
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
    }).catch(function (err) {
      if (state.view !== "book" || state.bookDay !== fday.date) return;   // stale
      wrap.textContent = "";
      wrap.appendChild(el("p", "pending-note",
        "Could not load the order book for " + dayLabel(state.bookDay) + " (" + err + ")."));
      $("book-legend").textContent = "";
      $("book-comment").textContent = "";
      bookTableMessage("Could not load the order book for " + dayLabel(state.bookDay) + ".");
      stopBookPlay();
    });
  }

  function renderBookLadder(book, fday, hourIdx) {
    var wrap = $("book-wrap");
    wrap.textContent = "";
    // Resolve the strategy label from o[3] via book.strategies (both additive;
    // absent on pre-strategy-column books → strat null, handled everywhere).
    var bookStrats = book.strategies || null;
    function stratOf(o) {
      return bookStrats && o[3] != null ? (bookStrats[o[3]] || null) : null;
    }
    var supply = (book.supply[hourIdx] || []).map(function (o) {
      return { price: o[0], mw: o[1], owner: book.owners[o[2]], strat: stratOf(o) };
    });
    // Demand ladder (willingness-to-pay), descending in price from shapeBook.
    var demand = (book.demand[hourIdx] || []).map(function (o) {
      return { price: o[0], mw: o[1], owner: book.owners[o[2]], strat: stratOf(o) };
    });
    var hasStrategy = !!book.has_strategy;
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
        var sm = strategyMeta(o.strat);
        if (sm) tooltip.appendChild(el("div", "tt-strat", sm.label + " — " + sm.explain));
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
            var sm = strategyMeta(o.strat);
            if (sm) tooltip.appendChild(el("div", "tt-strat", sm.label + " — " + sm.explain));
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

    // ---- per-block decision-trace table (below the chart) ----------------
    // Pass the coupled-trade net + its per-source decomposition (same sign-gated
    // rule as the wedge) so the table can render coupling imports/exports as
    // synthetic rows at the neighbour's merit position.
    var tableTradeSegs = (impliedNetImport !== null &&
                          Math.abs(impliedNetImport) >= CLIFF.TRADE_MIN_MW)
      ? tradeSegments(state.zone, fday.hours[hourIdx], impliedNetImport) : null;
    renderBookTable(supply, demand, {
      clearMW: clearMW, clearing: clearing, actual: actual, settledMW: settledMW,
      totalMW: totalMW, hasStrategy: hasStrategy,
      impliedNetImport: impliedNetImport, tradeSegs: tableTradeSegs,
    });
  }

  // Per-block table for the selected hour: one row per supply block (merit-order
  // sorted), split at the clearing point (cleared vs uncleared visually
  // distinct), with a separate demand section. Contiguous same-owner tranches
  // fold into ONE expandable group row (keeps a 100+-block ladder legible).
  // Columns: position (waterfall mini-bar) | cumulative MW | type (fuel family
  // icon + name) | owner (firm + icon + name) | strategy | price €/MWh | block
  // MW | why. The waterfall bars carry vertical guides at the clearing quantity
  // (bold) and the demand-curve steps (light), aligned across all rows so the
  // table reads as a vertical waterfall of the merit order. Coupled cross-border
  // trade appears as synthetic "(coupling) …" rows at the neighbour's merit
  // position (dashed sub-track, tinted). On books WITHOUT the strategy column
  // (has_strategy=false) the strategy + why columns are dropped and a note says
  // why. The waterfall cumulative axis = total SUPPLY MW (matches the chart);
  // coupling rows don't change it (least-confusing option — see the PR).
  function renderBookTable(supply, demand, ctx) {
    var host = $("book-table");
    if (!host) return;
    host.textContent = "";
    if (!supply.length && !demand.length) return;
    var showStrat = !!ctx.hasStrategy;
    var clearMW = ctx.clearMW;
    var C = chartColors(), BC = bookColors();
    // Waterfall axis = total SUPPLY MW — identical to the chart's x-axis, so the
    // per-row bars match the merit-order chart exactly. Coupling rows do NOT
    // change this axis (they render on a separate lighter sub-track).
    var axisMax = ctx.totalMW ||
      supply.reduce(function (m, o) { return Math.max(m, o.cum1 || 0); }, 1) || 1;
    // Demand-curve step quantities (internal willingness-to-pay drops) in range —
    // drawn as light vertical guides across every waterfall bar (e.g. the
    // elastic-demand step); the clearing quantity is the bold guide.
    var demandSteps = [];
    for (var _di = 0; _di < demand.length - 1; _di++) {
      var _q = demand[_di].cum1;
      if (_q != null && _q > 1 && _q < axisMax - 1) demandSteps.push(_q);
    }
    // Cumulative supply MW at which a price would clear (merit insertion point) —
    // where a coupling row of that price sits in the ladder.
    function supplyCumAtPrice(p) {
      for (var i = 0; i < supply.length; i++) if (supply[i].price >= p) return supply[i].cum0;
      return axisMax;
    }
    // One waterfall cell: faint track + the block's [cum0,cum1] filled in its
    // fuel colour, with the demand-step + clearing guides overlaid so they line
    // up vertically across ALL rows. Coupling bars use a thinner dashed sub-track.
    function waterfallCell(cum0, cum1, color, coupling) {
      var td = el("td", "bt-waterfall");
      var W = 120, H = 12;
      var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, width: W, height: H,
        class: "bt-wf", "aria-hidden": "true" });
      var X = function (q) { return Math.max(0, Math.min(W, (q / axisMax) * W)); };
      var ty = coupling ? 6.5 : 2.5, bh = coupling ? 4 : 7;
      svg.appendChild(svgEl("rect", { x: 0, y: ty, width: W, height: bh, rx: 1, fill: C.grid }));
      var fx0 = X(cum0), fx1 = X(cum1);
      var rectAttrs = { x: Math.min(fx0, fx1), y: ty, width: Math.max(1.2, Math.abs(fx1 - fx0)),
        height: bh, rx: 1, fill: color, "fill-opacity": coupling ? 0.5 : 0.92 };
      if (coupling) { rectAttrs.stroke = BC.trade; rectAttrs["stroke-width"] = 0.8; rectAttrs["stroke-dasharray"] = "2 1.5"; }
      svg.appendChild(svgEl("rect", rectAttrs));
      demandSteps.forEach(function (q) {
        var gx = X(q);
        svg.appendChild(svgEl("line", { x1: gx, x2: gx, y1: 0, y2: H, stroke: C.muted,
          "stroke-width": 1, "stroke-opacity": 0.4, class: "bt-wf-demand" }));
      });
      if (clearMW != null) {
        var cx = X(clearMW);
        svg.appendChild(svgEl("line", { x1: cx, x2: cx, y1: 0, y2: H, stroke: C.sim,
          "stroke-width": 1.5, class: "bt-wf-clear" }));
      }
      td.appendChild(svg);
      return td;
    }
    // Type (fuel-family) cell text: 🔥 Gas for units, the tag's own icon+name for
    // RES/IMPORT/DEMAND/BACKSTOP, 🔗 coupling for synthetic coupling rows.
    function typeText(owner, coupling) {
      if (coupling) return "🔗 coupling";
      var ti = ownerInfo(owner);
      return ti.kind === "tag" ? ti.icon + " " + ti.name
                               : ti.icon + " " + (FUEL_FAM_LABEL[ti.fam] || ti.fam);
    }

    // Split any supply block that straddles the clearing quantity so each row is
    // wholly cleared or wholly uncleared (clean visual split + correct grouping).
    var rows = [];
    supply.forEach(function (o) {
      var isCleared = o.cum0 < clearMW - 1e-9;
      if (clearMW > o.cum0 + 1e-9 && clearMW < o.cum1 - 1e-9) {
        rows.push({ price: o.price, mw: clearMW - o.cum0, owner: o.owner, strat: o.strat,
                    cum0: o.cum0, cum1: clearMW, cleared: true, marginal: true });
        rows.push({ price: o.price, mw: o.cum1 - clearMW, owner: o.owner, strat: o.strat,
                    cum0: clearMW, cum1: o.cum1, cleared: false, marginal: false });
      } else {
        rows.push({ price: o.price, mw: o.mw, owner: o.owner, strat: o.strat,
                    cum0: o.cum0, cum1: o.cum1, cleared: isCleared, marginal: false });
      }
    });

    // Group contiguous same-owner + same-cleared-state rows.
    var groups = [];
    rows.forEach(function (r) {
      var g = groups[groups.length - 1];
      if (g && g.owner === r.owner && g.cleared === r.cleared) {
        g.rows.push(r); g.mw += r.mw; g.cum1 = r.cum1;
        g.pmin = Math.min(g.pmin, r.price); g.pmax = Math.max(g.pmax, r.price);
        if (r.marginal) g.marginal = true;
      } else {
        groups.push({ owner: r.owner, cleared: r.cleared, rows: [r], mw: r.mw,
                      cum0: r.cum0, cum1: r.cum1, pmin: r.price, pmax: r.price,
                      marginal: !!r.marginal });
      }
    });

    var table = el("table", "book-table");
    var thead = el("thead");
    var htr = el("tr");
    var cols = ["position", "cumulative MW", "type", "owner", "strategy", "price €/MWh", "block MW", "why"];
    if (!showStrat) cols = ["position", "cumulative MW", "type", "owner", "price €/MWh", "block MW"];
    cols.forEach(function (c) { htr.appendChild(el("th", null, c)); });
    thead.appendChild(htr);
    table.appendChild(thead);
    var tbody = el("tbody");

    function priceCell(pmin, pmax) {
      return pmin === pmax ? fmt(pmin, 2) : fmt(pmin, 2) + "–" + fmt(pmax, 2);
    }
    // One <tr> for a group summary (expandable when it folds >1 tranche).
    function groupRow(g) {
      var tr = el("tr", "book-trow " + (g.cleared ? "is-cleared" : "is-uncleared"));
      if (g.marginal) tr.className += " is-marginal";
      if (g.coupling) tr.className += " bt-coupling";
      var multi = g.rows.length > 1;
      // waterfall position bar (coupling rows on their own lighter dashed track)
      tr.appendChild(waterfallCell(g.cum0, g.cum1,
        g.coupling ? BC.trade : ownerColor(g.owner, BC), g.coupling));
      // cumulative-MW range (coupling rows show their added MW, not a supply range)
      tr.appendChild(el("td", "bt-range",
        g.coupling ? ("+" + fmt(g.mw, 0)) : (fmt(g.cum0, 0) + "–" + fmt(g.cum1, 0))));
      // type = fuel family (icon + name), duplicated on purpose alongside owner
      tr.appendChild(el("td", "bt-type", typeText(g.owner, g.coupling)));
      // owner cell: firm · icon name, with an expander caret when multi-tranche
      var oc = el("td", "bt-owner");
      if (multi) {
        var caret = el("span", "bt-caret", "▸");
        oc.appendChild(caret);
      }
      oc.appendChild(document.createTextNode((multi ? " " : "") + (g.coupling ? g.owner : ownerLabel(g.owner))));
      tr.appendChild(oc);
      if (showStrat) {
        var stratTxt;
        if (g.coupling) stratTxt = g.couplingStrat;
        else if (multi) stratTxt = g.rows.length + " tranches";
        else { var sm = strategyMeta(g.rows[0].strat); stratTxt = sm ? sm.label : "—"; }
        var sc = el("td", "bt-strat", stratTxt);
        // record the group's strategy set for the filter chips + attach the
        // "explain this block" affordance (Component A) on non-coupling rows.
        var gStrats = g.coupling ? [] : g.rows.map(function (r) { return String(r.strat || "").replace(/_\d+$/, ""); });
        tr.setAttribute("data-strats", gStrats.join(" "));
        if (!g.coupling && !multi) {
          var eb = el("button", "bt-explain", "ⓘ"); eb.type = "button";
          eb.setAttribute("aria-label", "explain this block");
          eb.addEventListener("click", function (ev) {
            ev.stopPropagation();
            showBlockExplain(eb, { price: g.rows[0].price, mw: g.mw, owner: g.owner, strat: g.rows[0].strat });
          });
          sc.appendChild(document.createTextNode(" "));
          sc.appendChild(eb);
        }
        tr.appendChild(sc);
      }
      tr.appendChild(el("td", "bt-price", priceCell(g.pmin, g.pmax)));
      tr.appendChild(el("td", "bt-mw", fmt(g.mw, 1)));
      if (showStrat) {
        var whyTxt;
        if (g.coupling) whyTxt = g.couplingWhy;
        else if (multi) whyTxt = "expand for per-tranche detail";
        else { var sm2 = strategyMeta(g.rows[0].strat); whyTxt = sm2 ? sm2.explain : ""; }
        tr.appendChild(el("td", "bt-why", whyTxt));
      }
      var childRows = [];
      if (multi) {
        tr.classList.add("is-expandable");
        tr.setAttribute("role", "button");
        tr.setAttribute("tabindex", "0");
        tr.setAttribute("aria-expanded", "false");
        g.rows.forEach(function (r) {
          var ctr = el("tr", "book-trow bt-child " + (g.cleared ? "is-cleared" : "is-uncleared"));
          ctr.hidden = true;
          ctr.appendChild(waterfallCell(r.cum0, r.cum1, ownerColor(g.owner, BC), false));
          ctr.appendChild(el("td", "bt-range", fmt(r.cum0, 0) + "–" + fmt(r.cum1, 0)));
          ctr.appendChild(el("td", "bt-type", ""));
          ctr.appendChild(el("td", "bt-owner bt-child-owner", "↳"));
          var sm3 = strategyMeta(r.strat);
          ctr.setAttribute("data-strats", String(r.strat || "").replace(/_\d+$/, ""));
          if (showStrat) {
            var csc = el("td", "bt-strat", sm3 ? sm3.label : "—");
            var ceb = el("button", "bt-explain", "ⓘ"); ceb.type = "button";
            ceb.setAttribute("aria-label", "explain this block");
            ceb.addEventListener("click", function (ev) {
              ev.stopPropagation();
              showBlockExplain(ceb, { price: r.price, mw: r.mw, owner: g.owner, strat: r.strat });
            });
            csc.appendChild(document.createTextNode(" ")); csc.appendChild(ceb);
            ctr.appendChild(csc);
          }
          ctr.appendChild(el("td", "bt-price", fmt(r.price, 2)));
          ctr.appendChild(el("td", "bt-mw", fmt(r.mw, 1)));
          if (showStrat) ctr.appendChild(el("td", "bt-why", sm3 ? sm3.explain : ""));
          childRows.push(ctr);
        });
        function toggle() {
          var open = tr.getAttribute("aria-expanded") === "true";
          tr.setAttribute("aria-expanded", String(!open));
          tr.querySelector(".bt-caret").textContent = open ? "▸" : "▾";
          childRows.forEach(function (c) { c.hidden = open; });
        }
        tr.addEventListener("click", toggle);
        tr.addEventListener("keydown", function (e) {
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); }
        });
      }
      return [tr].concat(childRows);
    }

    // supply: cleared groups first, then a clearing divider, then uncleared.
    var clearedGroups = groups.filter(function (g) { return g.cleared; });
    var unclearedGroups = groups.filter(function (g) { return !g.cleared; });

    // COUPLING ROWS — the wedge's cross-border imports/exports as synthetic rows
    // at the neighbour's merit position. Same sign-gated decomposition as the
    // wedge: per-source when v1/flows is loaded AND the sign gate passed
    // (ctx.tradeSegs), else one net row at the model clearing price. Import rows
    // join the supply side (cleared/uncleared by their price); export rows join
    // demand. Visually distinct (bt-coupling: dashed sub-track + tinted).
    var demandCoupling = [];
    var couplingRendered = false;
    var netImp = ctx.impliedNetImport;
    if (netImp != null && Math.abs(netImp) >= 50) {
      var isImp = netImp > 0;
      var specs = (ctx.tradeSegs && ctx.tradeSegs.length)
        ? ctx.tradeSegs.map(function (sg) {
            return { label: sg.fixed ? "(coupling) fixed " + (isImp ? "imports" : "exports")
                                     : "(coupling) " + sg.zone,
                     price: sg.price != null ? sg.price : ctx.clearing, mw: sg.mw, fixed: !!sg.fixed };
          })
        : [{ label: "(coupling) net " + (isImp ? "imports" : "exports"),
             price: ctx.clearing, mw: Math.abs(netImp), fixed: false }];
      specs.forEach(function (rs) {
        var startCum = supplyCumAtPrice(rs.price == null ? (ctx.clearing || 0) : rs.price);
        var g = {
          owner: rs.label, coupling: true,
          cleared: rs.price == null || ctx.clearing == null || rs.price <= ctx.clearing,
          rows: [{ price: rs.price == null ? ctx.clearing : rs.price, mw: rs.mw, owner: rs.label, strat: null }],
          mw: rs.mw, cum0: startCum, cum1: startCum + rs.mw,
          pmin: rs.price == null ? ctx.clearing : rs.price, pmax: rs.price == null ? ctx.clearing : rs.price,
          marginal: false,
          couplingStrat: isImp ? "coupled import" : "coupled export",
          couplingWhy: rs.fixed
            ? "Fixed out-of-footprint injection (TR/AL/MK …) — not in the coupled flow table; the reconciliation residual."
            : "Cross-border " + (isImp ? "import" : "export") +
              " from the coupled 39-zone clear, at the neighbour's clearing price (flow variable, not a local book slice)." };
        couplingRendered = true;
        if (isImp) { (g.cleared ? clearedGroups : unclearedGroups).push(g); }
        else { demandCoupling.push(g); }
      });
      // keep merit order: existing groups are already price-ascending, so a
      // stable sort by pmin just slots the coupling rows into place.
      clearedGroups.sort(function (a, b) { return a.pmin - b.pmin; });
      unclearedGroups.sort(function (a, b) { return a.pmin - b.pmin; });
    }

    clearedGroups.forEach(function (g) { groupRow(g).forEach(function (tr) { tbody.appendChild(tr); }); });
    // clearing divider row
    var ncol = showStrat ? 8 : 6;
    var dtr = el("tr", "bt-divider");
    var dtd = el("td", null,
      "— clears at " + (ctx.clearing == null ? "?" : "€" + fmt(ctx.clearing, 2)) +
      " · " + fmt(clearMW, 0) + " MW —");
    dtd.setAttribute("colspan", String(ncol));
    dtr.appendChild(dtd);
    tbody.appendChild(dtr);
    unclearedGroups.forEach(function (g) { groupRow(g).forEach(function (tr) { tbody.appendChild(tr); }); });

    // demand section (own subheader, willingness-to-pay descending).
    if (demand.length || demandCoupling.length) {
      var dhr = el("tr", "bt-section");
      var dth = el("td", null, "Demand (willingness to pay)");
      dth.setAttribute("colspan", String(ncol));
      dhr.appendChild(dth);
      tbody.appendChild(dhr);
      // group contiguous same-owner demand blocks (mostly DEMAND / IMPORT)
      var dgroups = [];
      demand.forEach(function (o) {
        var g = dgroups[dgroups.length - 1];
        if (g && g.owner === o.owner) {
          g.rows.push(o); g.mw += o.mw; g.cum1 = o.cum1;
          g.pmin = Math.min(g.pmin, o.price); g.pmax = Math.max(g.pmax, o.price);
        } else {
          dgroups.push({ owner: o.owner, cleared: false, rows: [o], mw: o.mw,
                         cum0: o.cum0, cum1: o.cum1, pmin: o.price, pmax: o.price, marginal: false });
        }
      });
      // coupling EXPORTS sit among demand by willingness-to-pay (descending).
      demandCoupling.forEach(function (g) { dgroups.push(g); });
      dgroups.sort(function (a, b) { return b.pmax - a.pmax; });
      dgroups.forEach(function (g) {
        groupRow(g).forEach(function (tr) { tr.classList.add("bt-demand"); tbody.appendChild(tr); });
      });
    }

    table.appendChild(tbody);
    if (!showStrat) {
      host.appendChild(el("p", "bt-note",
        "Strategy tags are available for books captured after 2026-08-02 — this " +
        "day predates them, so the WHY column is hidden."));
    }

    // ---- strategy filter chips (Component A) — dim every row except the
    // selected strategy/-ies. Read-only, reuses the same tag vocabulary as the
    // glossary; a chip per distinct base-strategy present among the supply rows.
    if (showStrat) {
      var present = [];
      groups.forEach(function (g) {
        if (g.coupling) return;
        g.rows.forEach(function (r) {
          var b = String(r.strat || "").replace(/_\d+$/, "");
          if (b && present.indexOf(b) === -1) present.push(b);
        });
      });
      if (present.length > 1) {
        var chipbar = el("div", "bt-chips");
        chipbar.appendChild(el("span", "bt-chips-lab", "show only:"));
        var selected = {};
        function applyChips() {
          var any = Object.keys(selected).some(function (k) { return selected[k]; });
          var trs = table.querySelectorAll(".book-trow");
          trs.forEach(function (tr) {
            if (tr.classList.contains("bt-coupling")) return;
            var s = (tr.getAttribute("data-strats") || "").split(/\s+/).filter(Boolean);
            var match = !any || s.some(function (x) { return selected[x]; });
            if (match) tr.classList.remove("bt-dim"); else tr.classList.add("bt-dim");
          });
        }
        present.forEach(function (b) {
          var m = strategyMeta(b);
          var chip = el("button", "bt-chip", m ? m.label : b);
          chip.type = "button";
          chip.setAttribute("aria-pressed", "false");
          chip.addEventListener("click", function () {
            selected[b] = !selected[b];
            chip.setAttribute("aria-pressed", String(!!selected[b]));
            chip.classList.toggle("is-on", !!selected[b]);
            applyChips();
          });
          chipbar.appendChild(chip);
        });
        host.appendChild(chipbar);
      }
    }
    host.appendChild(table);

    // tiny waterfall legend under the table
    var legend = el("div", "bt-legend");
    function legItem(cls, txt) {
      var s = el("span", "bt-leg-item");
      s.appendChild(el("span", "bt-leg-key " + cls));
      s.appendChild(document.createTextNode(" " + txt));
      return s;
    }
    legend.appendChild(el("span", "bt-leg-title", "waterfall:"));
    legend.appendChild(legItem("k-clear", "clearing quantity (μπίλια)"));
    if (demandSteps.length) legend.appendChild(legItem("k-demand", "demand step"));
    if (couplingRendered) legend.appendChild(legItem("k-coupling", "coupling import/export"));
    host.appendChild(legend);
  }

  // ================= Pillar 5 — "How bids are built" (#view=method) ===========
  // Every number rendered here is READ from the generated book_methodology object
  // (+ zone_strategies) or COMPUTED in-browser from it — never hand-authored.

  var TRANCHE1_MULT_FALLBACK = 0.95;   // TRANCHES[0][1]; only used if the object is missing

  function methodReady() { return !!(state.methodology && state.methodology.cost_model); }

  // SRMC arithmetic — the SAME formulas the model uses, computed in the browser.
  function gasSRMC(cost, ttf, eua) {
    var g = cost.gas;
    return ttf / g.efficiency + eua * g.emission_factor_th / g.efficiency + g.vom;
  }
  function fuelSRMC(cost, fuel, eua) {
    var f = cost.fuels[fuel];
    if (!f) return null;
    return f.base_eur + (f.ef_el || 0) * eua;
  }

  // Provenance badge (observed / declared) for a characteristic key.
  function provBadge(key) {
    var p = state.methodology && state.methodology.provenance;
    var m = p && p[key];
    if (!m) return null;
    var b = el("span", "prov-badge prov-" + m.kind, m.kind);
    b.title = m.source + " · introduced/last moved at cv" + m.cv;
    return b;
  }

  // The characteristic → strategy-tag map (which bid category a parameter feeds).
  var CONST_TO_STRAT = {
    TRANCHES: ["srmc_base", "peak_tranche"], MUST_RUN_PRICE_FACTOR: ["must_run_deep"],
    MUST_RUN_SRMC_THRESHOLD: ["must_run_deep", "must_run_rest"],
    DEEP_SURPLUS_FLOOR_EUR: ["res_forecast", "must_run_deep"], AVAILABILITY_FACTOR: ["srmc_base"],
    PEAK_EXPONENT: ["peak_tranche"], BACKSTOP_PRICE_MULT: ["import_backstop"],
    BACKSTOP_WEEKS: ["import_backstop"], DEMAND_ELASTIC_SHARE: ["demand_elastic"],
    DEMAND_ELASTIC_PRICE: ["demand_elastic"], PRICE_CAP: ["demand_firm", "export_demand"],
    WATER_VALUE_DRY_BOOST: ["water_value_gas_anchored"], DERATE_HEADROOM: ["srmc_base"],
    FLEET_COMPLETION: ["srmc_base"], FLEET_TRUTHING: ["srmc_base"],
    NUCLEAR_AVAIL_REF: [], NUCLEAR_AVAIL_FLOOR: [],
  };

  function fmtConstVal(v) {
    if (v === true) return "on"; if (v === false) return "off";
    if (Array.isArray(v)) {   // TRANCHES: [[share,mult],…]
      if (v.length && Array.isArray(v[0])) {
        return v.map(function (t) { return Math.round(t[0] * 100) + "% ×" + fmt(t[1], 2); }).join(" · ");
      }
      return v.join(", ");
    }
    return typeof v === "number" ? fmt(v, 2) : String(v);
  }

  // ---- B1: the SRMC decomposition explorer (waterfall + live sliders) --------
  function b1Defaults() {
    var live = state.methodology.cost_model.live || {};
    var ttf = state.methodTTF != null ? state.methodTTF
      : (live.ttf_eur_mwh_th != null ? live.ttf_eur_mwh_th : 35.0);
    var eua = state.methodEUA != null ? state.methodEUA
      : (live.eua_eur_t != null ? live.eua_eur_t : 75.0);
    return { ttf: ttf, eua: eua, live: live };
  }

  function renderB1() {
    var cost = state.methodology.cost_model;
    var ctrls = $("b1-controls"), wf = $("b1-waterfall"), note = $("b1-note");
    if (!ctrls || !wf) return;
    ctrls.textContent = ""; wf.textContent = ""; note.textContent = "";
    var d = b1Defaults();

    // fuel picker — gas first, then the rest of the cost model's fuels.
    var fuels = Object.keys(cost.fuels);
    fuels.sort(function (a, b) { return a === "Fossil Gas" ? -1 : b === "Fossil Gas" ? 1 : (a < b ? -1 : 1); });
    if (!cost.fuels[state.methodFuel]) state.methodFuel = fuels[0];
    var picker = el("div", "method-fuelpicker");
    fuels.forEach(function (f) {
      var meta = FUEL_META[f] || FUEL_META.Other;
      var btn = el("button", "method-chip" + (f === state.methodFuel ? " is-on" : ""),
        (meta.icon || "") + " " + (FUEL_FAM_LABEL[meta.fam] || f));
      btn.type = "button";
      btn.addEventListener("click", function () { state.methodFuel = f; renderB1(); });
      picker.appendChild(btn);
    });
    ctrls.appendChild(picker);

    var isGas = state.methodFuel === "Fossil Gas";
    // sliders
    function slider(label, unit, min, max, val, key) {
      var wrap = el("label", "method-slider");
      wrap.appendChild(el("span", "method-slider-lab", label + " — €" + fmt(val, 1) + unit));
      var inp = document.createElement("input");
      inp.type = "range"; inp.min = min; inp.max = max; inp.step = "0.5"; inp.value = val;
      inp.addEventListener("input", function (e) {
        state[key] = +e.target.value; renderB1();
      });
      wrap.appendChild(inp);
      return wrap;
    }
    var sl = el("div", "method-sliders");
    if (isGas) sl.appendChild(slider("TTF gas", "/MWhₜₕ", 5, 150, d.ttf, "methodTTF"));
    sl.appendChild(slider("EUA carbon", "/t", 0, 160, d.eua, "methodEUA"));
    ctrls.appendChild(sl);

    // waterfall parts (in-browser arithmetic)
    var parts, total;
    if (isGas) {
      var g = cost.gas;
      parts = [
        { lab: "TTF ÷ η", detail: "€" + fmt(d.ttf, 1) + " ÷ " + fmt(g.efficiency, 2), val: d.ttf / g.efficiency },
        { lab: "carbon", detail: "€" + fmt(d.eua, 1) + " × " + fmt(g.emission_factor_th, 3) + " ÷ " + fmt(g.efficiency, 2), val: d.eua * g.emission_factor_th / g.efficiency },
        { lab: "O&M", detail: "VOM", val: g.vom },
      ];
    } else {
      var f = cost.fuels[state.methodFuel];
      parts = [{ lab: "fuel + O&M base", detail: "FUEL_SRMC_BASE", val: f.base_eur }];
      if (f.ef_el) parts.push({ lab: "carbon", detail: "€" + fmt(d.eua, 1) + " × " + fmt(f.ef_el, 2) + " EF", val: f.ef_el * d.eua });
    }
    total = parts.reduce(function (s, p) { return s + p.val; }, 0);

    // proportional stacked bar
    var bar = el("div", "method-wf-bar");
    var palette = ["#3b82f6", "#f59e0b", "#94a3b8", "#10b981"];
    parts.forEach(function (p, i) {
      var seg = el("div", "method-wf-seg");
      seg.style.flexGrow = String(Math.max(0.02, p.val));
      seg.style.background = palette[i % palette.length];
      seg.title = p.lab + ": €" + fmt(p.val, 2) + " (" + p.detail + ")";
      bar.appendChild(seg);
    });
    wf.appendChild(bar);
    // breakdown list
    var list = el("ul", "method-wf-list");
    parts.forEach(function (p, i) {
      var li = el("li");
      var k = el("span", "method-wf-key"); k.style.background = palette[i % palette.length];
      li.appendChild(k);
      li.appendChild(el("span", "method-wf-lab", p.lab + " "));
      li.appendChild(el("span", "method-wf-detail", "(" + p.detail + ")"));
      li.appendChild(el("span", "method-wf-val", " = €" + fmt(p.val, 2)));
      list.appendChild(li);
    });
    var tot = el("li", "method-wf-total",
      "SRMC = €" + fmt(total, 2) + " /MWh");
    list.appendChild(tot);
    wf.appendChild(list);

    var live = d.live;
    var srcNote = (isGas && live.ttf_eur_mwh_th != null) || (!isGas && live.eua_eur_t != null)
      ? "Sliders default to the live market close (" + (live.as_of || "") + "; strictly pre-auction, no lookahead)."
      : "No live close in this snapshot — sliders start at an illustrative value; the arithmetic is still computed, never typed in.";
    var f2 = cost.fuels[state.methodFuel];
    if (f2 && f2.note) note.appendChild(el("div", null, "Note: " + f2.note));
    note.appendChild(el("div", "method-src", srcNote));
  }

  // ---- B2: tranche ladder + must-run schematic ------------------------------
  function renderB2() {
    var host = $("b2-schematic"), note = $("b2-note");
    if (!host) return;
    host.textContent = ""; note.textContent = "";
    var fc = state.methodology.form_constants.values;
    var tranches = fc.TRANCHES || [[0.55, 0.95], [0.20, 1.05], [0.15, 1.25], [0.10, 1.60]];
    var avail = fc.AVAILABILITY_FACTOR;

    // one nameplate bar; the offered fraction (AVAILABILITY_FACTOR) sliced by TRANCHES.
    var bar = el("div", "method-cap-bar");
    var offered = el("div", "method-cap-offered");
    offered.style.width = (avail * 100) + "%";
    tranches.forEach(function (t, i) {
      var seg = el("div", "method-tranche" + (i === 0 ? " is-base" : ""));
      seg.style.flexGrow = String(t[0]);
      seg.appendChild(el("span", "method-tranche-lab",
        (i === 0 ? "SRMC base" : "peak " + (i + 1)) ));
      seg.appendChild(el("span", "method-tranche-mult",
        Math.round(t[0] * 100) + "% · ×" + fmt(t[1], 2)));
      offered.appendChild(seg);
    });
    bar.appendChild(offered);
    var rest = el("div", "method-cap-rest");
    rest.style.width = ((1 - avail) * 100) + "%";
    rest.appendChild(el("span", "method-cap-rest-lab", "reserve / derate headroom"));
    bar.appendChild(rest);
    host.appendChild(el("div", "method-cap-title",
      "One unit's nameplate → offered blocks (AVAILABILITY_FACTOR = " + fmt(avail, 2) + " of nameplate):"));
    host.appendChild(bar);

    // must-run economics, stated as FORMULAS (never a fabricated number)
    var mr = el("div", "method-mustrun");
    mr.appendChild(el("h4", null, "Must-run economics"));
    var ul = el("ul");
    ul.appendChild(el("li", null,
      "A unit is committed (must-run) this hour when its SRMC < MUST_RUN_SRMC_THRESHOLD (" +
      fmt(fc.MUST_RUN_SRMC_THRESHOLD, 2) + ") × the zone's gas SRMC."));
    ul.appendChild(el("li", null,
      "Deepest must-run block priced at MUST_RUN_PRICE_FACTOR (" + fmt(fc.MUST_RUN_PRICE_FACTOR, 2) +
      ") × SRMC — below cost by design (restart cost exceeds running below cost)."));
    ul.appendChild(el("li", null,
      "Must-run remainder = min( max(0.5·SRMC, SRMC − 40), nuclear ceiling ) — start-up cost amortised over the committed hours."));
    ul.appendChild(el("li", null,
      "In a solar-surplus regime the RES + run-of-river + deepest block price at DEEP_SURPLUS_FLOOR_EUR (€" +
      fmt(fc.DEEP_SURPLUS_FLOOR_EUR, 0) + ") so the coupled clear can fall below zero."));
    ul.appendChild(el("li", null,
      "Peak hours scale the upper tranches by 1 + κ · norm_demand^PEAK_EXPONENT (exponent " +
      fmt(fc.PEAK_EXPONENT, 0) + "); flat off-peak — κ is per-zone (see §5)."));
    mr.appendChild(ul);
    host.appendChild(mr);
  }

  // ---- B3: the parameter → bid-category table -------------------------------
  function renderB3() {
    var host = $("b3-table");
    if (!host) return;
    host.textContent = "";
    var fc = state.methodology.form_constants;
    var table = el("table", "method-param-table");
    var thead = el("thead"), htr = el("tr");
    ["characteristic", "value / source", "feeds bid category", "provenance"].forEach(function (c) {
      htr.appendChild(el("th", null, c));
    });
    thead.appendChild(htr); table.appendChild(thead);
    var tb = el("tbody");

    // form-level constants
    Object.keys(fc.descriptions).sort().forEach(function (name) {
      var tr = el("tr");
      var c0 = el("td", "mp-name"); c0.appendChild(el("code", null, name));
      c0.appendChild(el("div", "mp-desc", fc.descriptions[name]));
      tr.appendChild(c0);
      tr.appendChild(el("td", "mp-val", fmtConstVal(fc.values[name])));
      var c2 = el("td", "mp-feeds");
      (CONST_TO_STRAT[name] || []).forEach(function (s) {
        var m = strategyMeta(s);
        var a = el("a", "mp-taglink", m ? m.label : s);
        a.href = "#view=book";
        c2.appendChild(a);
      });
      tr.appendChild(c2);
      var c3 = el("td", "mp-prov");
      var b = provBadge(name); if (b) c3.appendChild(b);
      tr.appendChild(c3);
      tb.appendChild(tr);
    });

    // per-zone ZoneProfile fields (values vary → point at B5)
    var zs = state.zoneStrategies;
    if (zs && zs.field_descriptions) {
      var sep = el("tr", "mp-sep");
      var sepc = el("td", null, "Per-zone characteristics (vary by zone — see §5)");
      sepc.setAttribute("colspan", "4"); sep.appendChild(sepc); tb.appendChild(sep);
      Object.keys(zs.field_descriptions).sort().forEach(function (f) {
        var tr = el("tr");
        var c0 = el("td", "mp-name"); c0.appendChild(el("code", null, f));
        c0.appendChild(el("div", "mp-desc", zs.field_descriptions[f]));
        tr.appendChild(c0);
        var c1 = el("td", "mp-val");
        var a = el("a", "mp-taglink", "SEE default → per-zone"); a.href = "#view=method";
        a.addEventListener("click", function () { setView("method"); var t = $("method-b5"); if (t) t.scrollIntoView({ behavior: "smooth" }); });
        c1.appendChild(a); tr.appendChild(c1);
        tr.appendChild(el("td", "mp-feeds", ""));
        var c3 = el("td", "mp-prov"); var b = provBadge(f); if (b) c3.appendChild(b);
        tr.appendChild(c3);
        tb.appendChild(tr);
      });
    }
    table.appendChild(tb);
    var scroll = el("div", "table-scroll"); scroll.appendChild(table);
    host.appendChild(scroll);
  }

  // ---- B4: the strategy glossary --------------------------------------------
  function renderB4() {
    var host = $("b4-glossary");
    if (!host) return;
    host.textContent = "";
    var gl = state.methodology.strategy_glossary || {};
    Object.keys(gl).sort().forEach(function (name) {
      var card = el("div", "method-gloss-card");
      var m = strategyMeta(name);
      card.appendChild(el("h4", "method-gloss-name", m ? m.label : name));
      card.appendChild(el("code", "method-gloss-tag", name));
      card.appendChild(el("p", "method-gloss-desc", gl[name]));
      var live = el("a", "method-gloss-live", "see it live in the order book →");
      live.href = "#view=book";
      card.appendChild(live);
      host.appendChild(card);
    });
  }

  // ---- B5: the per-zone profile explorer ------------------------------------
  function renderB5() {
    var ctrls = $("b5-controls"), card = $("b5-zone"),
        tg = $("b5-treatments"), out = $("b5-outside");
    if (!ctrls) return;
    ctrls.textContent = ""; card.textContent = ""; tg.textContent = ""; out.textContent = "";
    var zs = state.zoneStrategies;
    if (!zs || !zs.zones) {
      card.appendChild(el("p", "bt-note",
        "The per-zone calibration table is not published yet. It is generated by " +
        "bin/export_zone_strategies.jl — run it (or publish it) to populate this explorer."));
      return;
    }
    var zones = zs.zones.map(function (r) { return r.zone; });
    if (zones.indexOf(state.methodZone) === -1) state.methodZone = zones.indexOf("FR") !== -1 ? "FR" : zones[0];
    var picker = el("div", "method-fuelpicker");
    zones.forEach(function (z) {
      var btn = el("button", "method-chip" + (z === state.methodZone ? " is-on" : ""), z);
      btn.type = "button";
      btn.addEventListener("click", function () { state.methodZone = z; renderB5(); writeHash(); });
      picker.appendChild(btn);
    });
    ctrls.appendChild(picker);

    var row = null;
    zs.zones.forEach(function (r) { if (r.zone === state.methodZone) row = r; });
    if (!row) return;
    card.appendChild(el("h4", "method-zone-title", state.methodZone + " — differences from the SEE base profile"));
    if (!row.differs_from_base || !row.differs_from_base.length) {
      card.appendChild(el("p", "bt-note", "This zone resolves to the SEE base profile — no per-zone overrides."));
    } else {
      var tbl = el("table", "method-param-table");
      var tb = el("tbody");
      row.differs_from_base.slice().sort().forEach(function (f) {
        var tr = el("tr");
        var c0 = el("td", "mp-name"); c0.appendChild(el("code", null, f));
        var desc = zs.field_descriptions && zs.field_descriptions[f];
        if (desc) c0.appendChild(el("div", "mp-desc", desc));
        tr.appendChild(c0);
        tr.appendChild(el("td", "mp-val", fmtProfileVal(row.values[f])));
        var c2 = el("td", "mp-prov"); var b = provBadge(f); if (b) c2.appendChild(b);
        tr.appendChild(c2);
        tb.appendChild(tr);
      });
      tbl.appendChild(tb);
      var scroll = el("div", "table-scroll"); scroll.appendChild(tbl);
      card.appendChild(scroll);
    }

    // treatment groups summary
    if (zs.treatments) {
      tg.appendChild(el("h4", null,
        zs.n_zones + " zones resolve to " + zs.n_distinct_treatments + " distinct parameter vectors:"));
      var gl = el("div", "method-treat-groups");
      zs.treatments.forEach(function (g) {
        var chip = el("span", "method-treat-chip" + (g.zones.indexOf(state.methodZone) !== -1 ? " is-on" : ""),
          "(" + g.n + ") " + g.zones.join(", "));
        gl.appendChild(chip);
      });
      tg.appendChild(gl);
    }

    // "strategy not in the table" honesty section
    if (zs.strategy_outside_the_profile) {
      out.appendChild(el("h4", null, "Strategy not in the table (non-negotiable honesty)"));
      zs.strategy_outside_the_profile.forEach(function (o) {
        var d = el("div", "method-outside-item");
        d.appendChild(el("strong", null, o.mechanism || ""));
        if (o.where) d.appendChild(el("span", "method-outside-where", " — " + o.where));
        if (o.note) d.appendChild(el("p", "method-outside-note", o.note));
        out.appendChild(d);
      });
    }
  }
  function fmtProfileVal(v) {
    if (v === true) return "on"; if (v === false) return "off";
    if (v === null || v === undefined) return "—";
    if (Array.isArray(v)) return JSON.stringify(v);
    if (typeof v === "object") return Object.keys(v).map(function (k) { return k + ": " + v[k]; }).join(", ");
    return typeof v === "number" ? fmt(v, 3) : String(v);
  }

  // ---- B6: observed/declared census + cv-ledger timeline --------------------
  function renderB6() {
    var census = $("b6-census"), ledger = $("b6-ledger");
    if (!census) return;
    census.textContent = ""; ledger.textContent = "";
    var prov = state.methodology.provenance || {};
    var obs = [], dec = [];
    Object.keys(prov).sort().forEach(function (k) {
      (prov[k].kind === "observed" ? obs : dec).push(k);
    });
    function col(title, cls, items) {
      var c = el("div", "method-census-col " + cls);
      c.appendChild(el("h4", null, title + " (" + items.length + ")"));
      var ul = el("ul");
      items.forEach(function (k) {
        var li = el("li");
        li.appendChild(el("code", null, k));
        var src = prov[k].source;
        if (src) li.appendChild(el("span", "method-census-src", " — " + src));
        ul.appendChild(li);
      });
      c.appendChild(ul);
      return c;
    }
    census.appendChild(el("p", "method-census-head",
      "The inputs are overwhelmingly observed; the form is a small set of declared, " +
      "peer-reviewable parameters — the precise, honest version of “no price is fitted.”"));
    var cols = el("div", "method-census-cols");
    cols.appendChild(col("observed — market data, no choice", "prov-observed", obs));
    cols.appendChild(col("declared — named, OOS-validated", "prov-declared", dec));
    census.appendChild(cols);

    var rows = state.methodology.cv_ledger || [];
    rows.forEach(function (r) {
      var item = el("div", "method-ledger-item ledger-" + (r.status || "shipped"));
      var head = el("div", "method-ledger-head");
      head.appendChild(el("span", "method-ledger-cv", "cv" + r.cv));
      head.appendChild(el("span", "method-ledger-status " + (r.status === "no_ship" ? "st-noship" : "st-ship"),
        r.status === "no_ship" ? "NO-SHIP" : "shipped"));
      head.appendChild(el("span", "method-ledger-char", r.characteristic));
      item.appendChild(head);
      if (r.change) item.appendChild(el("p", "method-ledger-change", r.change));
      if (r.measured) {
        var mline = Object.keys(r.measured).map(function (k) {
          return k + ": " + r.measured[k];
        }).join(" · ");
        item.appendChild(el("p", "method-ledger-measured", mline));
      }
      if (r.doc) {
        var a = el("a", "method-ledger-doc", r.doc);
        a.href = "https://github.com/philokalia-ai/energy-markets/tree/main/" + r.doc;
        a.target = "_blank"; a.rel = "noopener";
        item.appendChild(a);
      }
      ledger.appendChild(item);
    });
  }

  function renderMethod() {
    var status = $("method-status");
    // LIVE-ONLY: the methodology object drives every number on this page. If the
    // live plane does not answer (e.g. it has not been published yet), show the
    // shared honest empty state with a retry — never a synthetic/bundled snapshot.
    return loadMethodology().then(function () {
      if (state.view !== "method") return;
      if (!methodReady()) throw new Error("methodology object incomplete");
      if (status) status.textContent =
        "Generated from the running model · code_version " + state.methodology.code_version;
      renderB1(); renderB2(); renderB4(); renderB6();
      // Per-zone sections (B3's per-zone rows + B5) want zone_strategies, but the
      // rest of the page must not depend on it — render them either way.
      return loadZoneStrategies().then(function () {
        if (state.view === "method") { renderB3(); renderB5(); }
      }, function () {
        if (state.view === "method") { renderB3(); renderB5(); }   // B5 shows its honest note
      });
    }).catch(function () {
      if (state.view !== "method") return;
      liveUnavailable(status, function () { renderMethod(); },
        "This bid-methodology reference loads only from the live data API and " +
        "never substitutes synthetic data. The generated object " +
        "(bin/export_book_methodology.jl) is not being served right now.");
    });
  }

  // ============ Component A — "explain this block" popover =====================
  // Decomposes a block's OWN offered price into its named parts and asserts they
  // reconcile (a ⚠ when they don't — honesty over a fake reconciliation). Pure &
  // testable: reads state.methodology, returns a DOM element.
  function ownerFuel(owner) {
    var ti = ownerInfo(owner);
    if (ti.kind === "tag") return null;
    return ti.fuel || null;   // ownerInfo resolves AGG/unit codes to a fuel
  }
  // block = { price, mw, owner, strat }
  function buildBlockExplain(block) {
    var box = el("div", "block-explain");
    var strat = block.strat || "";
    var base = String(strat).replace(/_\d+$/, "");
    var m = strategyMeta(strat);
    box.appendChild(el("div", "be-title", (m ? m.label : (strat || "block")) +
      " · €" + fmt(block.price, 2) + " / " + fmt(block.mw, 1) + " MW"));
    if (m) box.appendChild(el("p", "be-desc", m.explain));

    if (!methodReady()) {
      box.appendChild(el("p", "be-warn", "⚠ methodology object not loaded — cannot decompose."));
      return box;
    }
    var cost = state.methodology.cost_model, fc = state.methodology.form_constants.values;
    var live = cost.live || {};
    var t1mult = (fc.TRANCHES && fc.TRANCHES[0]) ? fc.TRANCHES[0][1] : TRANCHE1_MULT_FALLBACK;
    var fuel = ownerFuel(block.owner);
    var isGas = fuel === "Fossil Gas";

    // The self-check: reconstruct the SRMC from the LIVE closes, apply the tag's
    // pricing rule, and require it to sum to the block's OWN offered price.
    function reconcileBox(reconstructed, ruleLabel, addends) {
      var wrap = el("div", "be-recon");
      addends.forEach(function (a) {
        var li = el("div", "be-addend");
        li.appendChild(el("span", "be-addend-lab", a.lab));
        li.appendChild(el("span", "be-addend-val", "€" + fmt(a.val, 2)));
        wrap.appendChild(li);
      });
      wrap.appendChild(el("div", "be-sum", "sum = €" + fmt(reconstructed, 2) + "  " + ruleLabel));
      return wrap;
    }

    if (base === "srmc_base" && isGas && live.ttf_eur_mwh_th != null && live.eua_eur_t != null) {
      var g = cost.gas, ttf = live.ttf_eur_mwh_th, eua = live.eua_eur_t;
      var addends = [
        { lab: "TTF €" + fmt(ttf, 1) + " ÷ " + fmt(g.efficiency, 2), val: ttf / g.efficiency },
        { lab: "EUA €" + fmt(eua, 1) + " × " + fmt(g.emission_factor_th, 3) + " ÷ " + fmt(g.efficiency, 2), val: eua * g.emission_factor_th / g.efficiency },
        { lab: "O&M", val: g.vom },
      ];
      var srmc = addends.reduce(function (s, a) { return s + a.val; }, 0);
      var expected = srmc * t1mult;   // srmc_base tranche = SRMC × tranche-1 multiplier
      var reconciles = Math.abs(expected - block.price) <= Math.max(0.03 * block.price, 0.5);
      box.appendChild(reconcileBox(srmc, "× " + fmt(t1mult, 2) + " (tranche-1 multiplier) = €" + fmt(expected, 2), addends));
      if (reconciles) {
        box.appendChild(el("div", "be-ok", "✓ reconciles with the offered €" + fmt(block.price, 2) + "."));
      } else {
        box.appendChild(el("div", "be-warn",
          "⚠ offered €" + fmt(block.price, 2) + "; the live cost model does not fully explain this block " +
          "(different fuel-day prices, a non-gas unit, or an anchored/scarcity-adjusted bid)."));
      }
      return box;
    }

    // Non-reconciled tags: name the rule + constant, never fabricate a number.
    var ruleText = null;
    if (base === "must_run_deep") ruleText = "technical-minimum block at MUST_RUN_PRICE_FACTOR (" + fmt(fc.MUST_RUN_PRICE_FACTOR, 2) + ") × SRMC — below cost by design.";
    else if (base === "must_run_rest") ruleText = "min( max(0.5·SRMC, SRMC − 40), nuclear ceiling ).";
    else if (base === "peak_tranche") ruleText = "tranche of " + (fc.TRANCHES ? "the ladder" : "capacity") + " at ×multiplier, then × (1 + κ·norm_demand^" + fmt(fc.PEAK_EXPONENT, 0) + ") in peak hours (zone κ, §5).";
    else if (base === "srmc_base") ruleText = "SRMC × tranche-1 multiplier (" + fmt(t1mult, 2) + ")" + (live.ttf_eur_mwh_th == null ? " — no live close in this snapshot, so the numeric waterfall is unavailable; drag the sliders in §1 to explore." : "") + ".";
    else if (base === "import_backstop") ruleText = "elastic import headroom at BACKSTOP_PRICE_MULT (" + fmt(fc.BACKSTOP_PRICE_MULT, 1) + ") × gas SRMC — binds only near the cap.";
    else if (base === "demand_elastic") ruleText = "price-sensitive tail curtailing above DEMAND_ELASTIC_PRICE (€" + fmt(fc.DEMAND_ELASTIC_PRICE, 0) + ").";
    else if (base === "demand_firm" || base === "export_demand") ruleText = "bid at PRICE_CAP (€" + fmt(fc.PRICE_CAP, 0) + ").";
    else if (base.indexOf("water_value") === 0) ruleText = "hydro opportunity cost — see §1–§2 and the zone's water-value fields (§5).";
    else if (base.indexOf("boundary") === 0) ruleText = "out-of-footprint neighbour, laddered on its own SRMC over the border's demonstrated capability (§5).";
    if (ruleText) box.appendChild(el("div", "be-rule", "rule: " + ruleText));
    var link = el("a", "be-more", "how this is built →");
    link.href = "#view=method";
    link.addEventListener("click", function () { setView("method"); writeHash(); });
    box.appendChild(link);
    return box;
  }

  // Open the popover anchored near an element (real-browser only; tests call
  // buildBlockExplain directly).
  var openPopover = null;
  function closeBlockExplain() { if (openPopover && openPopover.parentNode) openPopover.parentNode.removeChild(openPopover); openPopover = null; }
  function showBlockExplain(anchorEl, block) {
    closeBlockExplain();
    var pop = el("div", "block-explain-pop");
    pop.appendChild(buildBlockExplain(block));
    var close = el("button", "be-close", "×"); close.type = "button";
    close.addEventListener("click", closeBlockExplain);
    pop.appendChild(close);
    document.body.appendChild(pop);
    try {
      var r = anchorEl.getBoundingClientRect();
      pop.style.position = "absolute";
      pop.style.top = (window.scrollY + r.bottom + 4) + "px";
      pop.style.left = (window.scrollX + Math.min(r.left, window.innerWidth - 340)) + "px";
    } catch (e) { /* non-DOM env */ }
    openPopover = pop;
    setTimeout(function () {
      document.addEventListener("click", function h(ev) {
        if (openPopover && !openPopover.contains(ev.target) && ev.target !== anchorEl) {
          closeBlockExplain(); document.removeEventListener("click", h);
        }
      });
    }, 0);
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

  // ================= Solver view (pillar 1 — the coupled clearing) =========
  //
  // A dependency-free surface over data that already ships. S1 (the GME/OMIE
  // proof) is static content in index.html. S3 clears a SYNTHETIC two-zone toy
  // live in JS (clearTwoZone, below). S4 opens a real congested border-hour from
  // the live /api/v1/flows + /api/v1/zones planes (every number computed here,
  // nothing hand-authored). S5 is an illustrative two-pass click-through.

  // ---- S3: the two-zone toy -------------------------------------------------
  // Two SYNTHETIC two-block books (NOT a real ladder). NORTH is cheap (wind/
  // hydro), SOUTH dear (gas-set). The reader drags the ATC and watches the
  // clear move through islanded → congested → coupled.
  // Neutral, unmistakably-invented names + round numbers: NOT real bidding zones
  // or model output. "Zone A" is the cheap exporter, "Zone B" the dear importer.
  var SOLVER_TOY_BOOKS = {
    north: { name: "Zone A", blocks: [{ mw: 3000, price: 20 }, { mw: 2000, price: 70 }], demand: 2500 },
    south: { name: "Zone B", blocks: [{ mw: 500, price: 45 }, { mw: 3000, price: 95 }], demand: 2500 },
  };

  // Marginal supply price to serve quantity q from ascending price blocks.
  // 0 for q<=0; Infinity beyond total capacity (scarcity).
  function solverMarginalPrice(blocks, q) {
    if (q <= 0) return 0;
    var cum = 0;
    for (var i = 0; i < blocks.length; i++) {
      cum += blocks[i].mw;
      if (q <= cum + 1e-9) return blocks[i].price;
    }
    return Infinity;
  }

  // Closed-form clear of two two-block books joined by a NORTH→SOUTH line of
  // capacity `atc`. Pure function — the whole of pillar 1 in one control:
  //   1. merge both books, dispatch the combined inelastic demand by merit order
  //      → the efficient (unconstrained) NORTH export x* and the single price p*;
  //   2. if x* <= atc the line has room → COUPLED: one price p* in both zones,
  //      flow = x* (< atc = slack), zero congestion rent;
  //   3. else the line is full → CONGESTED: flow = atc, each zone prices its own
  //      margin (NORTH at demand+atc, SOUTH at demand−atc), and the gap between
  //      them, times the flow, is the border's congestion rent.
  function clearTwoZone(atc, books) {
    books = books || SOLVER_TOY_BOOKS;
    var N = books.north, S = books.south;
    var merged = N.blocks.map(function (b) { return { mw: b.mw, price: b.price, z: "N" }; })
      .concat(S.blocks.map(function (b) { return { mw: b.mw, price: b.price, z: "S" }; }))
      .sort(function (a, b) { return a.price - b.price; });
    var demand = N.demand + S.demand, rem = demand, nUsed = 0, pStar = 0;
    for (var i = 0; i < merged.length && rem > 1e-9; i++) {
      var take = Math.min(merged[i].mw, rem);
      if (take > 0) { pStar = merged[i].price; if (merged[i].z === "N") nUsed += take; rem -= take; }
    }
    var xUnc = nUsed - N.demand;   // efficient NORTH→SOUTH export (copper-plate)
    var flow, pN, pS, congested;
    if (xUnc <= atc + 1e-9) {
      congested = false; flow = Math.max(0, xUnc); pN = pStar; pS = pStar;
    } else {
      congested = true; flow = atc;
      pN = solverMarginalPrice(N.blocks, N.demand + atc);
      pS = solverMarginalPrice(S.blocks, S.demand - atc);
    }
    var gap = pS - pN;
    return {
      atc: atc, flow: flow, pN: pN, pS: pS, gap: gap,
      rent: congested ? gap * flow : 0, congested: congested, coupled: !congested,
    };
  }

  function solverColors() {
    var css = getComputedStyle(document.documentElement);
    return {
      grid: css.getPropertyValue("--grid").trim(),
      baseline: css.getPropertyValue("--baseline").trim(),
      muted: css.getPropertyValue("--text-muted").trim(),
      text: css.getPropertyValue("--text-secondary").trim(),
      surface: css.getPropertyValue("--surface-1").trim(),
      heading: css.getPropertyValue("--heading").trim(),
      good: css.getPropertyValue("--status-good").trim(),
      weak: css.getPropertyValue("--status-weak").trim(),
      cheap: css.getPropertyValue("--status-good").trim(),
      dear: css.getPropertyValue("--fuel-gas").trim(),
      trade: css.getPropertyValue("--book-trade").trim(),
      sim: css.getPropertyValue("--series-sim").trim(),
    };
  }

  function eur(v, d) { return "€" + fmt(v, d === undefined ? 0 : d); }

  // A cartoon two-block book column: a cheap slab (green) under a dear slab
  // (orange), height ∝ MW, with the zone's clearing price called out.
  function solverBookColumn(svg, x, w, book, price, C, dispatched) {
    var top = 24, maxMW = 5200, hMax = 150;
    var y = top, cum = 0;
    book.blocks.forEach(function (b, i) {
      var h = (b.mw / maxMW) * hMax;
      var lit = cum < dispatched - 1e-9;   // this block is (partly) dispatched
      svg.appendChild(svgEl("rect", {
        x: x, y: y, width: w, height: h, rx: 2,
        fill: i === 0 ? C.cheap : C.dear, opacity: lit ? 0.9 : 0.28,
        stroke: C.surface, "stroke-width": 1,
      }));
      var lbl = svgEl("text", { x: x + w / 2, y: y + h / 2 + 4, "text-anchor": "middle",
        "font-size": 11, fill: C.surface, "font-family": "var(--mono)" });
      lbl.textContent = b.mw + " @ " + eur(b.price);
      if (h > 18) svg.appendChild(lbl);
      y += h; cum += b.mw;
    });
    var name = svgEl("text", { x: x + w / 2, y: top - 8, "text-anchor": "middle",
      "font-size": 12, fill: C.heading, "font-family": "var(--serif)", "font-weight": 700 });
    name.textContent = book.name;
    svg.appendChild(name);
    var pr = svgEl("text", { x: x + w / 2, y: y + 18, "text-anchor": "middle",
      "font-size": 15, fill: C.heading, "font-family": "var(--mono)", "font-weight": 700 });
    pr.textContent = isFinite(price) ? eur(price) + "/MWh" : "scarcity";
    svg.appendChild(pr);
    var dm = svgEl("text", { x: x + w / 2, y: y + 34, "text-anchor": "middle",
      "font-size": 10.5, fill: C.muted, "font-family": "var(--mono)" });
    dm.textContent = "demand " + book.demand + " MW";
    svg.appendChild(dm);
  }

  function renderSolverToy() {
    var host = $("solver-toy");
    if (!host) return;
    var slider = $("solver-atc");
    var atc = slider ? +slider.value : 800;
    var vlab = $("solver-atc-val");
    if (vlab) vlab.textContent = atc + " MW";
    var r = clearTwoZone(atc);
    var C = solverColors();

    host.textContent = "";
    // Unmistakable, always-visible label ON the widget (not a tooltip): this is
    // the ONE pedagogical synthetic element on the page.
    host.appendChild(el("div", "solver-toy-label",
      "Illustrative synthetic market — not model data"));
    var W = 640, H = 320;
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, width: "100%",
      role: "img", "aria-label": "Illustrative synthetic two-zone toy clear at ATC " + atc + " MW — not model data" });

    var colW = 150, leftX = 40, rightX = W - 40 - colW;
    // dispatched MW per zone = local demand ± the cross-border flow (NORTH
    // exports r.flow, SOUTH imports it), used only to light the served blocks.
    var dispN = SOLVER_TOY_BOOKS.north.demand + r.flow;
    var dispS = SOLVER_TOY_BOOKS.south.demand - r.flow;
    solverBookColumn(svg, leftX, colW, SOLVER_TOY_BOOKS.north, r.pN, C, dispN);
    solverBookColumn(svg, rightX, colW, SOLVER_TOY_BOOKS.south, r.pS, C, dispS);

    // the line between them: an arrow whose width ∝ flow, magenta (trade wedge).
    var midY = 96, ax0 = leftX + colW + 8, ax1 = rightX - 8;
    var slack = r.coupled;
    svg.appendChild(svgEl("line", { x1: ax0, y1: midY, x2: ax1, y2: midY,
      stroke: C.baseline, "stroke-width": 1, "stroke-dasharray": "3 3" }));
    if (r.flow > 1) {
      var sw = Math.max(2, Math.min(16, (r.flow / 2500) * 16));
      svg.appendChild(svgEl("line", { x1: ax0, y1: midY, x2: ax1 - 10, y2: midY,
        stroke: C.trade, "stroke-width": sw, "stroke-linecap": "round" }));
      svg.appendChild(svgEl("path", {
        d: "M " + (ax1 - 12) + " " + (midY - 7) + " L " + ax1 + " " + midY + " L " + (ax1 - 12) + " " + (midY + 7) + " Z",
        fill: C.trade }));
    }
    var flab = svgEl("text", { x: (ax0 + ax1) / 2, y: midY - 12, "text-anchor": "middle",
      "font-size": 11, fill: C.text, "font-family": "var(--mono)" });
    flab.textContent = "flow " + Math.round(r.flow) + " MW";
    svg.appendChild(flab);
    var alab = svgEl("text", { x: (ax0 + ax1) / 2, y: midY + 20, "text-anchor": "middle",
      "font-size": 10.5, fill: slack ? C.good : C.weak, "font-family": "var(--mono)" });
    alab.textContent = slack ? "ATC " + atc + " (slack)" : "ATC " + atc + " (AT BOUND)";
    svg.appendChild(alab);

    // read-out band: the price gap and the congestion rent.
    var by = 250;
    var gapTxt = svgEl("text", { x: W / 2, y: by, "text-anchor": "middle",
      "font-size": 14, fill: C.heading, "font-family": "var(--mono)", "font-weight": 700 });
    gapTxt.textContent = r.coupled
      ? "ONE price — gap €0 (the line has room; both zones price the same marginal unit)"
      : "price gap " + eur(r.gap) + "/MWh — the line is full, the zones decouple";
    svg.appendChild(gapTxt);

    // congestion-rent bar: appears only when the border binds and the gap > 0.
    var rentY = by + 20, barMaxW = 360, barX = (W - barMaxW) / 2;
    svg.appendChild(svgEl("line", { x1: barX, y1: rentY + 12, x2: barX + barMaxW, y2: rentY + 12,
      stroke: C.grid, "stroke-width": 8, "stroke-linecap": "round" }));
    var rentMax = 60000;
    if (r.rent > 1) {
      var rw = Math.max(6, Math.min(barMaxW, (r.rent / rentMax) * barMaxW));
      svg.appendChild(svgEl("line", { x1: barX, y1: rentY + 12, x2: barX + rw, y2: rentY + 12,
        stroke: C.weak, "stroke-width": 8, "stroke-linecap": "round" }));
    }
    var rentTxt = svgEl("text", { x: W / 2, y: rentY + 34, "text-anchor": "middle",
      "font-size": 11.5, fill: r.rent > 1 ? C.weak : C.muted, "font-family": "var(--mono)" });
    rentTxt.textContent = r.rent > 1
      ? "congestion rent " + eur(r.gap) + " × " + Math.round(r.flow) + " MW = " + eur(r.rent) + "/h"
      : "congestion rent: €0";
    svg.appendChild(rentTxt);

    host.appendChild(svg);
  }

  // ---- S4: a real congested border-hour ------------------------------------
  // Curated pointers into the reproducible historical record (borders + dates
  // squarely inside the multi_zone_eu record). Every displayed number is
  // computed live from the persisted record via /api/v1/flows + /api/v1/zones —
  // there is NO fixture/synthetic fallback here: if the record flow for a
  // border-hour isn't served, S4 shows an honest empty state, never invented
  // data. (The two-zone toy above is the ONLY synthetic element on this page,
  // and it is labelled as such on the widget itself.)
  var SOLVER_EXEMPLARS = [
    { date: "2025-01-22", hour_utc: "2025-01-22T18:00:00Z", from_zone: "FR", to_zone: "IT-NORTH",
      note: "Winter evening peak: French supply can't fully reach Italy — the interconnector fills and the two zones decouple." },
    { date: "2025-01-22", hour_utc: "2025-01-22T03:00:00Z", from_zone: "FR", to_zone: "IT-NORTH",
      note: "The same border a few hours earlier: demand is low, the line has room, and the two prices sit together — the contrast that proves the rule." },
    { date: "2025-06-15", hour_utc: "2025-06-15T11:00:00Z", from_zone: "DE_LU", to_zone: "FR",
      note: "Solar-surplus midday on the continental core: a low/negative-price separation as one side floods with cheap PV." },
    { date: "2025-02-05", hour_utc: "2025-02-05T17:00:00Z", from_zone: "NO2", to_zone: "DK1",
      note: "Nordic hydro exporting into a tight Danish winter evening across the Skagerrak link." },
    { date: "2025-01-15", hour_utc: "2025-01-15T08:00:00Z", from_zone: "SE3", to_zone: "SE4",
      note: "A Nordic internal winter-morning constraint between two Swedish zones." },
  ];
  var solverFlowsCache = {};   // date -> {tsIso:[[src,snk,mw],…]} | null (live-only)
  var solverZoneCache = {};    // zone -> zone forecast json | null (live-only)

  // LIVE-ONLY fetch for the S4 exemplars — hits the record API directly and is
  // uses the live record API directly (loadLive is live-only too now, but this
  // stays explicit for the record contract), so nothing can ever
  // stand in for the persisted record (the owner directive: never render
  // synthetic content as if it were model output). Rejects when the live plane
  // is disabled (?live=0) or the record has no such object → honest empty state.
  function solverRecordJSON(rel) {
    if (!LIVE) return Promise.reject(new Error("record API disabled (?live=0)"));
    return fetchJSON(apiPath(rel));
  }
  function solverLoadRecordFlows(date) {
    if (solverFlowsCache[date] !== undefined) return Promise.resolve(solverFlowsCache[date]);
    return solverRecordJSON("flows/" + date).then(
      function (j) { solverFlowsCache[date] = (j && j.flows) || null; return solverFlowsCache[date]; },
      function () { solverFlowsCache[date] = null; return null; }
    );
  }
  function solverLoadRecordZone(zone) {
    if (solverZoneCache[zone] !== undefined) return Promise.resolve(solverZoneCache[zone]);
    return solverRecordJSON("zones/" + encodeURIComponent(zone) + ".json").then(
      function (j) { solverZoneCache[zone] = j || null; return solverZoneCache[zone]; },
      function () { solverZoneCache[zone] = null; return null; }
    );
  }
  var solverExemplarIdx = 0;

  // A zone's coupled `sim` price at a UTC hour, from its (cached) forecast for
  // the exemplar's market day. null when the day/hour isn't loaded.
  function solverZonePriceAt(zoneData, dateStr, tsIso) {
    if (!zoneData || !zoneData.days) return null;
    var day = null;
    zoneData.days.forEach(function (d) {
      if (d.date === dateStr && (!day || d.lead_days < day.lead_days)) day = d;
    });
    if (!day) return null;
    var i = day.hours.indexOf(tsIso);
    return i >= 0 && day.sim ? day.sim[i] : null;
  }

  // Net flow from→to on a border at a UTC hour, from the day's flow rows
  // (either stored direction). null when no flows / no border row.
  function solverBorderFlow(flows, tsIso, from, to) {
    if (!flows) return null;
    var rows = flows[tsIso];
    if (!rows || !rows.length) return null;
    var net = 0, hit = false;
    rows.forEach(function (r) {
      if (r[0] === from && r[1] === to) { net += r[2]; hit = true; }
      else if (r[0] === to && r[1] === from) { net -= r[2]; hit = true; }
    });
    return hit ? net : null;
  }

  function renderSolverExemplarSteps() {
    var bar = $("solver-exemplar-steps");
    if (!bar) return;
    bar.textContent = "";
    SOLVER_EXEMPLARS.forEach(function (ex, i) {
      var b = el("button", null, ex.from_zone + " · " + ex.to_zone);
      b.type = "button";
      b.setAttribute("aria-pressed", String(i === solverExemplarIdx));
      if (i === solverExemplarIdx) b.classList.add("is-active");
      b.addEventListener("click", function () {
        solverExemplarIdx = i;
        renderSolverExemplarSteps();
        renderSolverExemplar();
      });
      bar.appendChild(b);
    });
  }

  function solverExemplarMessage(host, msg) {
    host.textContent = "";
    host.appendChild(el("p", "pending-note", msg));
  }

  function renderSolverExemplar() {
    var host = $("solver-exemplar");
    if (!host) return;
    var ex = SOLVER_EXEMPLARS[solverExemplarIdx];
    solverExemplarMessage(host, "Opening the " + ex.from_zone + " · " + ex.to_zone + " border…");
    // LIVE record only — never a fixture fallback (see solverRecordJSON).
    Promise.all([
      solverLoadRecordFlows(ex.date),
      solverLoadRecordZone(ex.from_zone),
      solverLoadRecordZone(ex.to_zone),
    ]).then(function (res) {
      // guard against a stale in-flight render if the reader stepped on.
      if (SOLVER_EXEMPLARS[solverExemplarIdx] !== ex) return;
      var flows = res[0];
      var pFrom = solverZonePriceAt(res[1], ex.date, ex.hour_utc);
      var pTo = solverZonePriceAt(res[2], ex.date, ex.hour_utc);
      var net = solverBorderFlow(flows, ex.hour_utc, ex.from_zone, ex.to_zone);
      if (net === null || pFrom === null || pTo === null) {
        solverExemplarMessage(host,
          "Record flows unavailable for this border-hour. Congestion exemplars load only " +
          "from the reproducible historical record (the persisted coupled clear and its " +
          "cross-border flows), served live from the record API — this page never " +
          "substitutes synthetic data. Try the live site, another exemplar above, or check " +
          "back once the record covers this date.");
        return;
      }
      drawSolverExemplar(host, ex, pFrom, pTo, net);
    });
  }

  function drawSolverExemplar(host, ex, pFrom, pTo, net) {
    var C = solverColors();
    var sep = Math.abs(pFrom - pTo);
    var rent = sep * Math.abs(net);
    // flow direction: physical power runs cheap → dear; net sign is from→to.
    var srcZone = net >= 0 ? ex.from_zone : ex.to_zone;
    var dstZone = net >= 0 ? ex.to_zone : ex.from_zone;
    var congested = sep > 0.5;

    host.textContent = "";
    var W = 640, H = 220;
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, width: "100%", role: "img",
      "aria-label": ex.from_zone + "–" + ex.to_zone + " coupled prices and flow" });

    var head = svgEl("text", { x: W / 2, y: 22, "text-anchor": "middle", "font-size": 12,
      fill: C.muted, "font-family": "var(--mono)" });
    head.textContent = ex.date + ", " + hourLabel(ex.hour_utc) + " (" + hourEndLabel(ex.hour_utc) + ") Athens";
    svg.appendChild(head);

    var tileW = 170, tileH = 92, ty = 48, lX = 40, rX = W - 40 - tileW;
    function tile(x, zone, price) {
      svg.appendChild(svgEl("rect", { x: x, y: ty, width: tileW, height: tileH, rx: 10,
        fill: C.surface, stroke: C.baseline, "stroke-width": 1 }));
      var zt = svgEl("text", { x: x + tileW / 2, y: ty + 34, "text-anchor": "middle",
        "font-size": 15, fill: C.heading, "font-family": "var(--serif)", "font-weight": 700 });
      zt.textContent = zone;
      svg.appendChild(zt);
      var pt = svgEl("text", { x: x + tileW / 2, y: ty + 66, "text-anchor": "middle",
        "font-size": 18, fill: C.sim, "font-family": "var(--mono)", "font-weight": 700 });
      pt.textContent = eur(price) + " /MWh";
      svg.appendChild(pt);
    }
    tile(lX, ex.from_zone, pFrom);
    tile(rX, ex.to_zone, pTo);

    var midY = ty + tileH / 2, ax0 = lX + tileW + 6, ax1 = rX - 6;
    // arrow points from the physically-exporting (cheaper) zone to the importer.
    var forward = srcZone === ex.from_zone;
    var sw = Math.max(3, Math.min(18, (Math.abs(net) / 3000) * 18));
    svg.appendChild(svgEl("line", { x1: ax0, y1: midY, x2: ax1, y2: midY,
      stroke: C.trade, "stroke-width": sw, "stroke-linecap": "round" }));
    var tipX = forward ? ax1 : ax0, backX = forward ? ax1 - 13 : ax0 + 13;
    svg.appendChild(svgEl("path", {
      d: "M " + backX + " " + (midY - 8) + " L " + tipX + " " + midY + " L " + backX + " " + (midY + 8) + " Z",
      fill: C.trade }));
    var fl = svgEl("text", { x: (ax0 + ax1) / 2, y: midY - 14, "text-anchor": "middle",
      "font-size": 11.5, fill: C.text, "font-family": "var(--mono)" });
    fl.textContent = "flow " + fmt(Math.abs(net), 0) + " MW  " + srcZone + " → " + dstZone;
    svg.appendChild(fl);

    var sy = ty + tileH + 44;
    var sepTxt = svgEl("text", { x: W / 2, y: sy, "text-anchor": "middle", "font-size": 14,
      fill: congested ? C.weak : C.good, "font-family": "var(--mono)", "font-weight": 700 });
    sepTxt.textContent = congested
      ? "price separation: " + eur(sep) + "/MWh · congestion rent " + eur(rent) + " this hour"
      : "prices equalised (Δ " + eur(sep, 2) + ") — the border had room to spare";
    svg.appendChild(sepTxt);

    host.appendChild(svg);
    host.appendChild(el("p", "solver-exemplar-note", ex.note));
  }

  // ---- S5: the two-pass anchor click-through (illustrative) -----------------
  var solverPassStep = 1;
  var SOLVER_PASS = [
    { tag: "pass 1", price: 58, water: null,
      cap: "NO2's reservoir bids a first-guess water value → the footprint clears → a coupled price of €58/MWh emerges." },
    { tag: "the anchor", price: 58, water: 52,
      cap: "NO2 asks: what is my water worth to the WHOLE connected market right now? It re-prices at 0.9 × €58 = €52." },
    { tag: "pass 2", price: 55, water: 52,
      cap: "The footprint re-clears with NO2's opportunity-cost bid → final coupled prices, consistent across every anchored zone." },
  ];

  function renderSolverPass() {
    var host = $("solver-pass");
    if (!host) return;
    var s = SOLVER_PASS[(solverPassStep - 1) % 3];
    var C = solverColors();
    host.textContent = "";
    var W = 640, H = 190;
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, width: "100%", role: "img",
      "aria-label": "Two-pass anchor feedback, step " + solverPassStep });

    var steps = ["pass 1", "the anchor", "pass 2"];
    steps.forEach(function (t, i) {
      var on = i === (solverPassStep - 1) % 3;
      var cx = 90 + i * 90;
      svg.appendChild(svgEl("circle", { cx: cx, cy: 30, r: 12,
        fill: on ? C.sim : C.surface, stroke: on ? C.sim : C.baseline, "stroke-width": 1.5 }));
      var num = svgEl("text", { x: cx, y: 34, "text-anchor": "middle", "font-size": 11,
        fill: on ? C.surface : C.muted, "font-family": "var(--mono)", "font-weight": 700 });
      num.textContent = String(i + 1);
      svg.appendChild(num);
      if (i < 2) svg.appendChild(svgEl("line", { x1: cx + 13, y1: 30, x2: cx + 77, y2: 30,
        stroke: C.baseline, "stroke-width": 1 }));
      var tl = svgEl("text", { x: cx, y: 56, "text-anchor": "middle", "font-size": 9.5,
        fill: on ? C.heading : C.muted, "font-family": "var(--mono)" });
      tl.textContent = t;
      svg.appendChild(tl);
    });

    // NO2 water-value tile + the coupled-price read-out.
    var ty = 82, tileW = 190, tileH = 76;
    svg.appendChild(svgEl("rect", { x: 40, y: ty, width: tileW, height: tileH, rx: 10,
      fill: C.surface, stroke: C.baseline, "stroke-width": 1 }));
    var zt = svgEl("text", { x: 40 + tileW / 2, y: ty + 26, "text-anchor": "middle", "font-size": 13,
      fill: C.heading, "font-family": "var(--serif)", "font-weight": 700 });
    zt.textContent = "NO2 · reservoir";
    svg.appendChild(zt);
    var wv = svgEl("text", { x: 40 + tileW / 2, y: ty + 54, "text-anchor": "middle", "font-size": 16,
      fill: s.water == null ? C.muted : C.good, "font-family": "var(--mono)", "font-weight": 700 });
    wv.textContent = s.water == null ? "water value: first guess" : "water value €" + s.water + "/MWh";
    svg.appendChild(wv);

    var arrX0 = 40 + tileW + 10, arrX1 = W - 40 - 190;
    svg.appendChild(svgEl("line", { x1: arrX0, y1: ty + tileH / 2, x2: arrX1 - 12, y2: ty + tileH / 2,
      stroke: C.trade, "stroke-width": 4, "stroke-linecap": "round" }));
    svg.appendChild(svgEl("path", {
      d: "M " + (arrX1 - 14) + " " + (ty + tileH / 2 - 7) + " L " + (arrX1 - 2) + " " + (ty + tileH / 2) +
        " L " + (arrX1 - 14) + " " + (ty + tileH / 2 + 7) + " Z", fill: C.trade }));

    svg.appendChild(svgEl("rect", { x: W - 40 - 190, y: ty, width: 190, height: tileH, rx: 10,
      fill: C.surface, stroke: C.baseline, "stroke-width": 1 }));
    var ct = svgEl("text", { x: W - 40 - 95, y: ty + 26, "text-anchor": "middle", "font-size": 12,
      fill: C.muted, "font-family": "var(--mono)" });
    ct.textContent = "coupled price";
    svg.appendChild(ct);
    var cp = svgEl("text", { x: W - 40 - 95, y: ty + 54, "text-anchor": "middle", "font-size": 18,
      fill: C.sim, "font-family": "var(--mono)", "font-weight": 700 });
    cp.textContent = eur(s.price) + "/MWh";
    svg.appendChild(cp);

    host.appendChild(svg);
    host.appendChild(el("p", "solver-pass-cap", "Step " + solverPassStep + " · " + s.tag + " — " + s.cap));
  }

  // ---- S2: the dual sketch (static, theme-aware) ---------------------------
  function renderSolverDual() {
    var host = $("solver-dual");
    if (!host) return;
    var C = solverColors();
    host.textContent = "";
    var W = 640, H = 200;
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, width: "100%", role: "img",
      "aria-label": "A zonal price is the dual of the balance constraint" });
    var top = svgEl("text", { x: W / 2, y: 22, "text-anchor": "middle", "font-size": 13,
      fill: C.heading, "font-family": "var(--serif)", "font-weight": 700 });
    top.textContent = "maximise  Σ economic surplus   subject to:";
    svg.appendChild(top);

    function constraintRow(y, label, dualText, accent) {
      svg.appendChild(svgEl("rect", { x: 40, y: y, width: 300, height: 46, rx: 8,
        fill: C.surface, stroke: C.baseline, "stroke-width": 1 }));
      var t = svgEl("text", { x: 56, y: y + 28, "font-size": 12.5, fill: C.heading,
        "font-family": "var(--mono)" });
      t.textContent = label;
      svg.appendChild(t);
      svg.appendChild(svgEl("line", { x1: 340, y1: y + 23, x2: 380, y2: y + 23,
        stroke: accent, "stroke-width": 2 }));
      svg.appendChild(svgEl("path", { d: "M 344 " + (y + 18) + " L 340 " + (y + 23) + " L 344 " + (y + 28) + " Z",
        fill: accent }));
      var d = svgEl("text", { x: 392, y: y + 20, "font-size": 12, fill: C.text,
        "font-family": "var(--sans)" });
      d.textContent = dualText[0];
      svg.appendChild(d);
      var d2 = svgEl("text", { x: 392, y: y + 37, "font-size": 12, fill: C.text,
        "font-family": "var(--sans)" });
      d2.textContent = dualText[1];
      svg.appendChild(d2);
    }
    constraintRow(50, "supply + imports = demand + exports",
      ["the multiplier on THIS constraint =", "the zone's clearing price (its dual)"], C.sim);
    constraintRow(120, "flow ≤ ATC   (each border)",
      ["the multiplier on THIS constraint =", "the congestion rent on that border"], C.trade);
    host.appendChild(svg);
  }

  var solverBooted = false;
  function renderSolver() {
    renderSolverDual();
    renderSolverToy();
    renderSolverPass();
    if (!solverBooted) { renderSolverExemplarSteps(); solverBooted = true; }
    renderSolverExemplar();
  }

  function renderFooter() {
    var sb = state.scoreboard;
    if (!sb) return;   // manifest may arrive before the scoreboard
    var bits = [];
    if (sb.generated_utc) bits.push("generated " + sb.generated_utc.replace("T", " ").replace("Z", " UTC"));
    if (sb.code_version !== undefined) bits.push("code_version " + sb.code_version);
    bits.push("source: live data API");
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
    }).catch(function () {
      // Honest live-unavailable state in the zone-backed views (explorer +
      // horizon), with a retry that re-selects the zone. Never a snapshot.
      $("chart-title").textContent = zone + " — live data unavailable";
      $("chart-sub").textContent = "";
      $("day-list").textContent = "";
      $("day-stats").textContent = "";
      $("chart-legend").textContent = "";
      $("hour-table").textContent = "";
      var retry = function () { selectZone(zone, true); };
      liveUnavailable($("chart-wrap"), retry,
        "The live data API did not return " + zone + "'s forecast. This site never " +
        "substitutes synthetic data — retry once the API is reachable.");
      var hz = $("hz-wrap");
      if (hz) {
        $("hz-title").textContent = zone + " — live data unavailable";
        $("hz-sub").textContent = "";
        liveUnavailable(hz, retry,
          "The live data API did not return " + zone + "'s forecast. This site never " +
          "substitutes synthetic data — retry once the API is reachable.");
      }
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
    if ($("boundary-day-slider")) {
      $("boundary-day-slider").addEventListener("input", function (ev) {
        boundaryState.dayIdx = +ev.target.value;
        var days = boundaryDays();
        var lbl = $("boundary-day-label");
        if (lbl && days && days[boundaryState.dayIdx]) lbl.textContent = dayLabel(days[boundaryState.dayIdx].date);
        if (state.boundaries) {
          var date = boundarySelectedDate();
          // reset the live-rungs toggle target to the new day
          if (date) loadFlows(date).then(function () {
            if (state.view === "boundary") { renderBoundaryRing(state.boundaries); renderBoundaryExplainer(state.boundaries); }
          });
        }
      });
    }
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
    if ($("solver-atc")) {
      $("solver-atc").addEventListener("input", renderSolverToy);
    }
    if ($("solver-pass-step")) {
      $("solver-pass-step").addEventListener("click", function () {
        solverPassStep = (solverPassStep % 3) + 1;
        renderSolverPass();
      });
    }
    var methodLink = $("predict-method-link");
    if (methodLink) methodLink.addEventListener("click", function (ev) {
      ev.preventDefault();
      var t = $("predict-method");
      if (t) t.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    var pzsel = $("predict-zone-select");
    if (pzsel) pzsel.addEventListener("change", function (ev) { selectPredictZone(ev.target.value); });
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

    bootstrapData();
  }

  // Load the scoreboard (the app-level bootstrap) from the live plane. On
  // failure paint the honest empty/error state with a Retry that re-runs this
  // — never a bundled snapshot.
  function bootstrapData() {
    var box = $("load-error");
    box.hidden = true;
    box.textContent = "";
    loadLive("scoreboard.json").then(function (res) {
      state.scoreboard = res.json;
      state.source = res.source;
      box.hidden = true;

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
      box.hidden = false;
      liveUnavailable(box, bootstrapData,
        "Could not reach the live data API (" + err + "). This site shows only " +
        "live model results — it never falls back to bundled or synthetic data. " +
        "Retry, or check the API status.");
    });
  }

  // Auto-boot in the browser. A test harness sets window.__EUPHEMIA_NO_AUTOINIT
  // to drive individual render functions without the full data-plane bootstrap.
  if (typeof window === "undefined" || !window.__EUPHEMIA_NO_AUTOINIT) init();

  // Browser-safe test surface (a debug handle the app never itself relies on) —
  // lets web/DOM tests drive the order-book table + strategy map in isolation.
  if (typeof window !== "undefined") {
    window.__euphemiaBook = {
      renderBookTable: renderBookTable,
      bookTableMessage: bookTableMessage,
      strategyMeta: strategyMeta,
      STRATEGY_LABELS: STRATEGY_LABELS,
      // pillar-5 test surface: drive Component A + the method view in isolation.
      buildBlockExplain: buildBlockExplain,
      renderMethod: renderMethod,
      setMethodology: function (m) {
        state.methodology = m;
        var gl = m && m.strategy_glossary;
        if (gl) for (var k in gl) { if (STRATEGY_LABELS[k]) STRATEGY_LABELS[k].explain = gl[k]; }
      },
      setZoneStrategies: function (z) { state.zoneStrategies = z; },
      // pillar-6 test surface: drive the boundary view from a fixture in isolation.
      renderBoundary: renderBoundary,
      setBoundaries: function (b) { state.boundaries = b; },
      boundaryNodes: boundaryNodes,
      renderBoundaryRing: renderBoundaryRing,
      renderBoundaryCards: renderBoundaryCards,
      renderBoundaryExplainer: renderBoundaryExplainer,
      renderBoundaryFlowRule: renderBoundaryFlowRule,
      setView: setView,
      state: state,
    };
    // Solver-view test surface: the pure two-zone closed-form clear (S3) plus
    // the render entry points, so web/DOM tests can drive the Solver view in
    // isolation without the full data-plane bootstrap.
    window.__euphemiaSolver = {
      clearTwoZone: clearTwoZone,
      solverMarginalPrice: solverMarginalPrice,
      renderSolver: renderSolver,
      renderSolverToy: renderSolverToy,
      SOLVER_TOY_BOOKS: SOLVER_TOY_BOOKS,
      SOLVER_EXEMPLARS: SOLVER_EXEMPLARS,
    };
    // Predictions hub+3 test surface — lets DOM tests drive the composed target
    // views + hub composites against test fixtures, in isolation from bootstrap.
    window.__euphemiaPredict = {
      predictState: predictState,
      buildContractStrip: buildContractStrip,
      buildModelCard: buildModelCard,
      buildSkill: buildSkill,
      buildKnobs: buildKnobs,
      buildOutput: buildOutput,
      buildTargetView: buildTargetView,
      buildFamilyTable: buildFamilyTable,
      buildTargetCards: buildTargetCards,
      buildReservoir: buildReservoir,
    };
    // Views test surface — lets a DOM smoke test drive each view's live-only
    // load+render with the API absent and assert the honest empty state (no
    // synthetic fallback anywhere). Also exposes the shared honest component.
    window.__euphemiaViews = {
      state: state,
      liveUnavailable: liveUnavailable,
      loadLive: loadLive,
      bootstrapData: bootstrapData,
      selectZone: selectZone,
      loadMap: loadMap,
      renderMap: renderMap,
      setView: setView,
      renderBook: renderBook,
      loadPredict: loadPredict,
      renderPredictTarget: renderPredictTarget,
      renderMethod: renderMethod,
      renderBoundary: renderBoundary,
    };
  }
})();
