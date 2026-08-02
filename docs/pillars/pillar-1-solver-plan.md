# Pillar 1 — The Solver: page design spec

> SIX-PILLARS program, pillar-1 planning pass. This is a **design**, not an
> implementation. It specifies one new surface — **the Solver view** — concrete
> enough that an implementer needs no further design decisions: sections, the data
> contract (what already exists, what is additive), the interactions, ASCII visual
> sketches, and tone-matched copy. Read [`../six-pillars.md`](../six-pillars.md)
> §"Pillar 1" (what the pillar IS) and [`../six-pillars-plan.md`](../six-pillars-plan.md)
> §"Pillar 1" (the charter) first. The validation numbers below are lifted verbatim
> from the committed artifact [`../experiments/pubbooks-clearing/results.md`](../experiments/pubbooks-clearing/results.md).

---

## 0. Decision: a NEW page, `#view=solver`

**A new Solver view, not a Books extension.** The charter asks the pass to decide;
the decision is a dedicated page, for three reasons:

1. **It teaches a different object.** The Books page (pillar 5, LOVED, not to be
   diluted) teaches *one zone's supply/demand curve and where it crosses*. Pillar 1
   is about **coupling** — 39 books solved as ONE system, prices as duals, flows at
   ATC bounds, congestion = price separation. That is a system-level story the
   single-zone ladder structurally cannot carry.
2. **The trust anchor needs its own stage.** The GME **€0.00** validation is the
   single most persuasive fact the project owns — "feed the real published bids in,
   the official price comes out exact." It deserves to be the hero of a page, not a
   link buried under a book.
3. **The about page already promises it.** `web/about.html`'s six-pillar list, item 1,
   says *"Validated on real published auctions (GME €0.00 exact)"* and links
   `#view=book` + the REPRODUCE doc as a stopgap. This page is the real destination;
   after it ships, repoint that pillar-1 link to `#view=solver`.

**Tab placement.** Insert the tab between **Map** and **Predict** in the tab strip
(`web/index.html`, `nav.tabs`): `Recent days · Map · Solver · Predict · Zone
explorer · Order book · Scoreboard · Cases`. Rationale: Map is *outputs* (prices per
zone), Solver is *how those outputs are produced*, Predict/Book are *inputs*. The
page's own out-links (§7) close the loop: Solver → Book (its inputs) and Solver → Map
(its outputs).

**Wiring (mirrors every existing view).** Add `<button … data-view="solver">Solver</button>`
to the tab strip; a `<section id="view-solver" class="view" … hidden>`; the
`$("view-solver").hidden = v !== "solver";` line in the router (~app.js:223-229); and
`if (v === "solver") renderSolver();` in the view-switch (~app.js:232-234). No new
framework — same dependency-free HTML/CSS/inline-SVG idiom as the rest of the SPA.

---

## 1. What the page teaches (and what it must NOT)

Four ideas, in this order. Each maps to a section (§3).

| # | Idea | One-line claim | Section |
|---|------|----------------|---------|
| A | **The mechanism is exact** | Real published bids in → official price out, to the cent. | S1 (hero) |
| B | **Prices are duals** | A zonal price is the shadow value of one more MWh of demand in that zone — an output of the solve, not an input. | S2 |
| C | **Coupling & congestion** | Two zones joined by a big-enough line share one price; when the line saturates, prices *separate*, and the gap is the congestion rent. | S3 (toy) + S4 (real hour) |
| D | **Two passes** | Hydro/nuclear fleets re-bid their opportunity cost against the *coupled* price — the anchor feedback that makes water values footprint-consistent. | S5 |

**Hard constraint — do not re-teach the order book.** The Solver page never renders a
full per-unit merit ladder (that is pillar 5). Where it needs "a book," it uses a
**two-block cartoon** (a cheap slab + a dear slab per zone) — enough to show a
crossing move, never the real ladder. Any impulse to show fuel-coloured unit tranches
belongs on `#view=book`; link there instead (§7).

---

## 2. Honest framing (tone = about.html)

The page inherits the site's voice: plain, exact, and unafraid of the caveat. Three
honesty commitments are load-bearing and must appear as body copy, not footnotes:

- **The solver is validated in ISOLATION; the residual is elsewhere.** S1 must state,
  in the same breath as €0.00, that this proves *only* the clearing mechanism. "The
  mechanism is exact; everything that's hard is in the *inputs* to it — the book we
  construct (pillar 5) and the forecasts we predict (pillars 2-4)." This is the exact
  message of results.md §Headline and it is what keeps the €0.00 from over-claiming.
- **Published books are only the DOMESTIC layer.** The reason a single-zone clear of
  the published book *cannot* generally equal the official price is that Italy/Iberia
  are coupled — the price-setter is often an import at the margin, absent from the
  per-zone book. That is not a solver failure; it is the coupling this whole page is
  about. Stating it turns the "77.7% of GME cells miss the official price
  domestically" fact from an embarrassment into the thesis.
- **Raw GME/OMIE bids are non-redistributable.** The interactive clearer therefore
  runs on **synthetic, clearly-labelled** bids (S3), and the "real hour" panel (S4)
  runs on data we already serve and are allowed to publish (coupled prices + flows).
  We never ship a raw exchange bid. Say so where the toy market is introduced.

---

## 3. Page structure (top → bottom)

```
 ┌───────────────────────────────────────────────────────────────────┐
 │  S0  Hero strip — "One auction, 39 prices"                         │
 ├───────────────────────────────────────────────────────────────────┤
 │  S1  THE PROOF — GME €0.00  (the centerpiece; big stat cards)      │
 ├───────────────────────────────────────────────────────────────────┤
 │  S2  Why a price is a dual   (plain-language + tiny SVG)           │
 ├───────────────────────────────────────────────────────────────────┤
 │  S3  Clear it yourself — two-zone toy  (drag ATC slider)          │
 ├───────────────────────────────────────────────────────────────────┤
 │  S4  Congestion on a real hour  (flows + coupled prices, live)    │
 ├───────────────────────────────────────────────────────────────────┤
 │  S5  The second pass — anchor feedback  (small step animation)    │
 ├───────────────────────────────────────────────────────────────────┤
 │  S6  Where this sits — links to Book (inputs) and Map (outputs)   │
 └───────────────────────────────────────────────────────────────────┘
```

### S0 — Hero strip

Reuse `.chart-head` / `.hero-kicker`. Kicker: *"Pillar 1 · constructed"*. Title:
**"One auction, thirty-nine prices."** Sub (one sentence): *"The same coupled
day-ahead auction the real EUPHEMIA engine solves — every zone's book cleared
simultaneously under the transmission network, so each zonal price is a property of
the whole connected system, not of that zone alone."*

### S1 — The proof: GME €0.00 (centerpiece)

The trust anchor. A `.chart-card` titled **"Does the solver clear real bids
correctly? Yes — exactly."** with a 2-up stat grid (reuse `.case-grid` / `.case-stat`
styling) and one explanatory paragraph.

Stat cards (numbers verbatim from results.md §"Layer A"):

| card (accent) | value | sub |
|---|---|---|
| GME (Italy) | **max \|Δ\| = €0.00** | Across the 76 well-determined GME zone-hour cells (of 1,175), the engine reproduces the exchange's own published zonal price to the cent. 100% of all 1,175 cells land inside the valid clearing bracket. |
| OMIE (Iberia) | **100% ≤ €0.50** | On the 232 well-determined Iberian cells (of 480), median \|Δ\| = €0.00, max €0.45; every one of the 480 cells is inside the valid bracket. |

Body copy (honest framing, §2 commitment 1 + 2):

> We fed the engine the **actual published bid books** of two exchanges that publish
> them — GME (Italy, 7 days across 4 seasons) and OMIE (the Iberian pool, 20 days) —
> and asked one question: given these real bids, does our solver find the same price
> the exchange did? On every cell where the bids alone pin a unique price, it does —
> exactly. **This validates the clearing *mechanism* in isolation.** It is deliberately
> a narrow claim: the published books are only the *domestic* layer of a coupled
> market, so on most Italian zone-hours the price is actually set by an import at the
> margin that isn't in the per-zone book at all (77.7% of GME cells). That gap is not
> a solver error — it is exactly the cross-border coupling the rest of this page is
> about. Everything hard lives in the *inputs* to the solver: the book we construct
> (pillar 5) and the forecasts we predict (pillars 2-4). The solver itself is exact.

Footer line of the card: *"Frozen protocol (2026-08-01), fresh Julia process per day,
HiGHS solver. Raw exchange bids are not redistributable; the method and every number
reproduce from the committed harness."* with links to
[`../experiments/pubbooks-clearing/REPRODUCE.md`](../experiments/pubbooks-clearing/REPRODUCE.md)
and `results.md`.

**A small honest table (optional, collapsible `<details>`)** — the two-layer split
that makes the point airtight, from results.md §"Layer B" (GME):

```
                       domestic-only     + observed net position
 median |Δ vs official|   €95.2/MWh   →        €8.4/MWh
```

with caption: *"Injecting the exchange's own net cross-border position — the coupling
layer the published book omits — collapses the gap by €87/MWh. The solver was never
wrong; the domestic book was incomplete."*

### S2 — Why a zonal price is a dual

Plain-language, no jargon wall. One paragraph + one tiny SVG.

Copy:

> A market-clearing price is not a number we choose or predict — it *falls out* of the
> solve. The auction maximizes total economic surplus subject to one balance equation
> per zone (supply + imports = demand + exports) and one capacity limit per border.
> The **price of a zone is the shadow price of its balance equation**: the amount total
> surplus would rise if that zone needed one more MWh. That is why it equals the cost
> of the *marginal* unit serving the zone — and why, when a zone leans on imports, its
> price is set by a plant in a *neighbouring* zone. The price is an **output** of the
> coupled optimisation, the dual variable, not an input to it.

SVG sketch (inline, ~two boxes and an arrow — theme-aware via `currentColor`):

```
      maximise  Σ surplus
          subject to
   ┌──────────────────────────┐        the multiplier on THIS
   │  supply + imports        │  ◄───  constraint = the zone's
   │     = demand + exports   │        clearing price  (its dual)
   └──────────────────────────┘
   ┌──────────────────────────┐        the multiplier on THIS
   │  flow ≤ ATC   (each border)│ ◄──  constraint = the congestion
   └──────────────────────────┘        rent on that border
```

Caption ties it forward: *"When every border constraint is slack, all coupled zones
share one price. When a border binds — flow at its ATC limit — the two zones it joins
can hold different prices, and the difference is that border's congestion rent. The
next two panels show both cases."*

### S3 — Clear it yourself: the two-zone toy (INTERACTIVE)

The primary interactive. A **synthetic** two-zone market the reader clears by dragging
one slider (the ATC between the zones). This is the "drag ATC, watch prices
converge/diverge" element from the charter. Synthetic by necessity (§2 commitment 3)
and labelled as such.

**Setup (fixed, illustrative).** Two zones, **NORTH** (cheap: lots of wind/hydro) and
**SOUTH** (dear: gas-set). Each has a two-block cartoon book — NOT a real ladder:

```
  NORTH book                     SOUTH book
   cheap slab  2000 MW @ €20      cheap slab  1000 MW @ €45
   dear  slab  2000 MW @ €70      dear  slab  3000 MW @ €95
   demand      3000 MW            demand      3000 MW
```

NORTH alone clears at €20 (surplus supply); SOUTH alone at €95. They want to trade:
cheap NORTH power flows south.

**The control.** One slider: **ATC (NORTH → SOUTH), 0 … 2500 MW.** As the reader
drags it, the panel re-solves the tiny two-zone clear *live in JS* (a closed-form
merit-order crossing — no solver call needed for two two-block books) and redraws.

**Three regimes the reader will discover by dragging:**

```
  ATC = 0 MW  (islanded)      ATC = 800 MW (congested)     ATC = 2000 MW (coupled)
  ┌────────┐   ┌────────┐     ┌────────┐→→→┌────────┐      ┌────────┐→→→→→┌────────┐
  │ NORTH  │   │ SOUTH  │     │ NORTH  │800│ SOUTH  │      │ NORTH  │ 1500 │ SOUTH  │
  │ €20    │   │ €95    │     │ €45    │MW │ €70    │      │  €70   │  MW  │  €70   │
  └────────┘   └────────┘     └────────┘   └────────┘      └────────┘     └────────┘
   price gap    €75            gap €25 = congestion rent    ONE price, gap €0
   (no line)    line at bound → prices separate            line slack → prices equalise
```

Under the two books draw a **price read-out** and a **congestion-rent bar**:

```
  NORTH €70 ──────────  SOUTH €70          flow 1500 MW  ·  ATC 2000 MW  (slack)
  ▲ prices equalised — the line has room; one MWh moves freely, so both zones
    price the same marginal unit.                           congestion rent: €0
```

vs at the congested setting:

```
  NORTH €45 ──/ /── SOUTH €70              flow 800 MW  ·  ATC 800 MW  (AT BOUND)
  ▲ the line is full. NORTH can't export its next cheap MWh; the zones decouple
    and price their own margins.               congestion rent: (€70−€45) × 800MW
```

**Why this is the whole pillar in one control:** dragging ATC from 0 → high walks the
reader through islanded → congested → coupled, and the price gap closing to zero *is*
the coupling. The congestion rent appearing exactly when flow hits the bound *is* "flow
at ATC ⇒ price separation." No text can teach it as fast as the slider.

**Labels:** a persistent `SYNTHETIC · illustrative two-block books, not real bids`
chip on the card (reuse `.chip`). A one-line "what's real" note: *"The numbers here are
invented to make the mechanism visible in two blocks. The real engine does this with
39 zones and thousands of real unit offers at once — see a real congested hour just
below, and a real full book on the Order-book page."*

### S4 — Congestion on a real hour (LIVE data, no synthetic)

Now the same story on **real model output**, using data the site already serves. Picks
one curated exemplar: a real market day + hour + border where the coupled clear
produced a **price separation** (congestion). Shows the two neighbouring zones' actual
coupled prices and the flow between them.

Layout — two zone tiles + the border between them, driven by `/api/v1/flows/:date` and
`/api/v1/zones/:zone`:

```
   ── 2025-01-22, hour 18 (evening peak) ─────────────────────────────

     ┌─────────────┐        flow 1,950 MW  ▶▶▶        ┌─────────────┐
     │   FR        │   ═══════════════════════════▶   │   IT-NORTH  │
     │  €112 /MWh  │        (at the day's ATC)         │  €167 /MWh  │
     └─────────────┘                                   └─────────────┘
              price separation:  €55/MWh  ·  congestion rent €107k this hour

   Both zones cleared in the SAME auction. France's cheaper margin can't reach
   Italy's demand because the interconnector is full — so the two hold different
   prices. Equal prices would mean the border had room to spare.
```

**Selection logic (spec):** a small committed `web/data/solver-exemplars.json` (or
`v1/solver/exemplars.json` served by the worker — see §4) lists ~4-6 curated stories,
each `{date, hour_utc, from_zone, to_zone, note}`. At render time the SPA fetches
`/api/v1/flows/<date>` (flow_mw on that border-hour) and `/api/v1/zones/<from>` &
`/zones/<to>` (each zone's `sim` price at that hour), computes the separation and the
rent (`|Δprice| × flow_mw`), and draws the tile pair. A `◂ ▸` segmented control (reuse
`.segmented`) steps between exemplars; each is a different regime: a congested peak, an
*un*congested hour where the same border shows equal prices (the contrast that proves
the rule), a negative-price solar-surplus separation, a Nordic hydro border.

**Honesty note on the card:** flows are persisted only for **record/backfill** days
(the `multi_zone_eu` save path), not the daily ex-ante forecast (`save_to_db=false`) —
so exemplars are drawn from the multi-year record, and the note says so: *"These are
hours from the reproducible historical record, where the full coupled solve and its
cross-border flows are persisted. The map and explorer show the same prices; here we
open the border between two of them."* This is the exact phasing already documented in
`bin/export_flows_parquet.jl`.

### S5 — The second pass: anchor feedback (light animation)

The two-pass opportunity anchor, told as a 3-step click-through (not autoplay; a
`▸ step` button advances, reuse `.book-play` styling). This is the charter's
"pass-1→pass-2 anchor animation." Small SVG, one hydro zone (NO2) + one coupled price.

```
  step 1  ── pass 1 ──   NO2's reservoir bids a first-guess water value → the
                         footprint clears →  coupled price €58/MWh emerges.

  step 2  ── the anchor ─ NO2 asks: "what is my water worth to the WHOLE connected
                         market right now?"  →  it re-prices at 0.9 × €58 = €52.

  step 3  ── pass 2 ──   the footprint re-clears with NO2's opportunity-cost bid →
                         final coupled prices, consistent across every anchored zone.
```

Copy:

> Reservoir hydro and French nuclear don't have a fuel cost that sets their bid — they
> have an *opportunity* cost: the value of holding the water (or the nuclear output)
> for a better hour. But "a better hour" is defined by the coupled price, which doesn't
> exist until the market clears. So the footprint clears **twice**: the first pass
> produces a coupled price; the hydro and nuclear fleets re-bid their opportunity cost
> against *that* price; the second pass re-clears. The result is water values that are
> consistent across the whole connected system — a Norwegian reservoir and a French
> reactor both pricing against the same market-wide signal.

Honest caveat line: *"This is a two-pass approximation, not a full inter-temporal
storage optimisation — the storage charge/discharge cycle is a known modelling gap
(see the model map on the About page)."*

### S6 — Where this sits

Closing strip (reuse `.book-cta`), two out-links that place the solver between its
inputs and outputs:

- **← Its inputs: the order book.** *"The solver clears the books pillar 5 builds.
  See a real zone's full per-unit supply ladder and where it crosses."* → `#view=book`.
- **Its outputs: the price map. →** *"Every zonal price on this page is one cell of the
  map. See all 39 at once, any day."* → `#view=map`.

---

## 4. Data contract — what exists, what is additive

**Almost everything the page needs already ships.** The page is deliberately designed
to lean on the existing `v1/` contract (charter: "Additive data contracts").

| Need | Source | Status |
|---|---|---|
| GME/OMIE validation numbers (S1) | committed artifact `docs/experiments/pubbooks-clearing/results.md` | **exists** as prose. Values are a FIXED experiment result (7 GME days), not a live feed — so they are **static content in the page** (like the case-study numbers in `index.html`), with links to REPRODUCE.md/results.md. No new data plane. |
| Two-zone toy (S3) | none — synthetic, computed in JS | **no data needed.** Closed-form two-block merit crossing in `app.js`. |
| Real congested hour: coupled prices (S4) | `GET /api/v1/zones/:zone` → `days[].sim[hourIdx]` | **exists** (used by explorer/horizon/book already). |
| Real congested hour: cross-border flow (S4) | `GET /api/v1/flows/:date` → `{date_time_utc, source_zone, sink_zone, flow_mw}` | **exists** (`bin/export_flows_parquet.jl`, worker route `/api/v1/flows/:date`, already consumed by the Book view's trade wedge). |
| Exemplar list (S4) | `web/data/solver-exemplars.json` (committed) OR `v1/solver/exemplars.json` | **NEW, tiny** — a hand-curated list of ~5 `{date, hour_utc, from_zone, to_zone, note}`. Committed static is fine (like the case studies); the *numbers* it displays are all computed live from flows+zones, so nothing is hand-authored that the site could compute. |
| Two-pass animation (S5) | none — the three numbers are illustrative | **no data needed** (labelled illustrative, like S3). |

**One optional additive enrichment (nice-to-have, not required):** add an `atc_mw`
column to the `v1/flows/<date>.parquet` rows so S4 can render "flow **at bound**"
explicitly (flow_mw / atc_mw as a fill bar) instead of inferring congestion purely
from price separation. The exporter already reads `simulations.transmission_flows`;
the offered ATC per border-hour is available from the enriched `Network` build. If
this is not done, S4 still works — **price separation alone proves congestion in a
coupled market** (equal prices ⇔ slack border), which is precisely the teaching point,
so the ATC bar is illustrative polish, not a correctness dependency. Recommend shipping
S4 on existing flows first; add `atc_mw` as a fast follow.

**Non-goal:** no new solver-in-the-browser, no WASM, no live re-clear of real books.
The toy (S3) is two two-block books — a few lines of arithmetic. Everything else is a
fetch of data already published.

---

## 5. Interaction spec (precise)

- **S3 ATC slider.** `<input type=range min=0 max=2500 step=50>`. On `input`: recompute
  the two-zone clear (below) and redraw both cartoon books, the price read-outs, the
  flow arrow width (∝ flow), and the congestion-rent bar. Debounce not needed (pure
  arithmetic). Keyboard-accessible (native range). Three labelled tick marks at the
  regime boundaries (islanded 0 / congestion onset / full-coupling threshold) so a
  reader who doesn't drag still sees the three states.
  - *Closed-form clear:* with NORTH marginal cost curve `S_N(q)` and SOUTH `S_S(q)`,
    both piecewise-constant two-block, and inelastic demand `D_N, D_S`: find the export
    `x ∈ [0, ATC]` that equalises marginal prices `p_N(D_N + x) = p_S(D_S − x)` if
    feasible (⇒ coupled, one price, `x < ATC`); else `x = ATC` (⇒ congested, two
    prices). Trivial to evaluate; document the four-line function inline.
- **S4 exemplar stepper.** `.segmented` `◂ ▸` (or a row of small buttons, one per
  exemplar). On select: fetch (cached) `/api/v1/flows/<date>` + the two zones, find the
  border-hour row (`source_zone/sink_zone` match, `date_time_utc` == `hour_utc`), read
  each zone's `sim` at that hour, render. Handle "flows dormant / not found" with a
  graceful empty state (the phasing note copy).
- **S5 step button.** `▸ step` cycles 1→2→3→1; each step swaps the SVG layer and the
  caption. No timer.
- **Theme.** All SVG uses `currentColor` / the CSS custom properties
  (`--series-sim`, `--book-import`, `--book-trade` magenta for the flow arrow,
  `--status-good`/`--status-weak` for coupled/congested states). Verified in both
  light and dark by using the existing tokens only — no hard-coded hex.
- **Responsive.** Stat grids reuse `.case-grid` (already responsive). The two-zone and
  two-tile SVGs sit in `.chart-wrap` with `viewBox` + `max-width:100%`; on narrow
  screens the two zone tiles stack vertically and the flow arrow rotates to point down.

---

## 6. Visual language (matches the existing SPA)

- **Colours (from `style.css :root`):** cheap/coupled = `--status-good` green,
  dear/scarce = `--fuel-gas` orange, the cross-border flow arrow = `--book-trade`
  magenta (#C51D74 — already the site's "coupled cross-border trade wedge" colour, so
  S3/S4 reuse the exact hue the Book view uses for the wedge — one consistent visual
  grammar for "power crossing a border"), imports = `--book-import` steel. Prices in
  `--series-sim` aegean, settled actuals (if shown) in `--series-act` terracotta.
- **Type:** titles in the serif heading stack (`--didot`/`--serif` via `.chart-title`);
  numbers/prices in `--mono` (JetBrains Mono), as the case stats already do.
- **Cards:** `.chart-card`, `.chart-head`, `.chart-title`, `.chart-sub`; stat tiles
  `.case-grid`/`.case-stat`/`.cs-label`/`.cs-value`/`.cs-sub`; chips `.chip`;
  collapsibles `.table-details`. Nothing new in CSS beyond a handful of solver-scoped
  classes (`.solver-toy`, `.solver-zone-tile`, `.solver-rent-bar`) added to
  `style.css`.
- **Meander divider** (`.meander`) between S1 and S2, as the about page uses between
  major movements.

---

## 7. Copy tone — reference lines (drop-in)

Voice check against `about.html`: declarative, exact number first, caveat in the same
paragraph, no hype. Approved phrasings, ready to use:

- Hero: *"One auction, thirty-nine prices."*
- S1 title: *"Does the solver clear real bids correctly? Yes — exactly."*
- S1 anti-overclaim: *"The mechanism is exact; everything that's hard is in the inputs
  to it."*
- S2: *"A price is not a number we choose or predict — it falls out of the solve."*
- S3 chip: *"SYNTHETIC · illustrative two-block books, not real bids."*
- S4: *"Both zones cleared in the same auction; the full line is why they hold
  different prices."*
- S5 caveat: *"A two-pass approximation, not a full storage optimisation — a known
  gap, kept visible."*

---

## 8. Acceptance (what "done" means for the implementer)

1. A `#view=solver` tab renders S0-S6, wired into the router exactly like the other
   views; no console errors; theme toggle correct in both modes; responsive to 360px.
2. S1 shows the €0.00 / 100%-bracket stat cards with the verbatim numbers from
   results.md and working links to REPRODUCE.md + results.md.
3. S3's ATC slider live-re-clears the two-zone toy through all three regimes
   (islanded → congested → coupled), with the price gap closing to €0 at full coupling
   and the congestion-rent bar appearing exactly when flow = ATC.
4. S4 loads at least one real exemplar from live `/api/v1/flows/:date` + `/zones/:zone`,
   computes separation + rent client-side, and degrades gracefully when flows are
   absent (fixture/offline or a forecast-only day).
5. No raw exchange bid, no hand-authored number that live data could compute, and every
   synthetic/illustrative element carries its label.
6. About-page pillar-1 link repointed `#view=book` → `#view=solver`.

---

## 9. Out of scope (explicitly, so the implementer doesn't gold-plate)

- No browser solver / WASM / real-book re-clear.
- No new heavy data plane (only the tiny exemplar list; `atc_mw` is optional polish).
- No fuel-coloured per-unit ladder (that is `#view=book`).
- No editing of the record, the pipeline, or any Julia clearing code — this is a web
  surface over data that already exists.
