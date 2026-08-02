# The boundary-zones surface — how the model treats the world outside the footprint

> Pillar-6 planning pass of the SIX-PILLARS program. This is a **page spec, not an
> implementation** — enough that a following build pass can ship it without
> re-deriving the pillar. Read [`../six-pillars.md#pillar-6`](../six-pillars.md)
> (what the pillar IS, verified against code) and the charter in
> [`../six-pillars-plan.md#pillar-6`](../six-pillars-plan.md) first. Source of
> truth for every number and mechanism below: `src/merit_order/zone_profiles.jl`
> (the `BoundaryBook` struct + the four book constants), `src/merit_order/boundary.jl`
> (the ladders, capability + firm sizing), `src/merit_order/flows_imports.jl`
> (`get_net_imports`, the `:v3` ex-ante flow rule), `src/merit_order/book_build.jl`
> (Stage 7b — how a book enters the book), and the ledger entries cv21/cv22/cv23 in
> `CLAUDE.md`.

## The one thing this page must teach

The 39-zone footprint is not the whole electrical world. Every hour, power crosses
its edge — from Turkey into Greece, from Britain into France and Denmark, from
Ukraine into Hungary. The model has to say *something* about those neighbours, and
it says **two different things**, and the whole point of this surface is to make the
difference between them legible and honest:

- **Fixed injection** (TR, AL, MK, and every other out-of-footprint neighbour by
  default): the neighbour is a **price-taker schedule**. We take its observed
  cross-border flow — lagged, ex-ante, never same-day — and inject it as a fixed
  quantity. It does not respond to price. It is data, not a model.
- **Elastic counterparty book** (GB on two borders, UA on four): the neighbour is
  promoted to a **bidding participant** with its own supply/demand ladder, anchored
  on *its own fundamental cost* (GB's CCGT SRMC; UA's war-constrained willingness to
  pay), sized by the border's *demonstrated capability*. It responds to price inside
  the coupled clear like any zone.

The charter names a misconception baked into the owner's own dictation: that **TR is
a "book."** It is not. There are no "dropped TR borders." TR is a fixed injection,
full stop — no ladder, no anchor, no capability sizing. The page must correct this
in the open (see the TR card and the "Common misconception" callout). That honesty —
we model GB and UA as counterparties because we can defend their fundamentals, and
we refuse to pretend we model TR — is the pillar-6 story.

Second teaching goal, one level down: **how a fixed injection becomes ex-ante.** The
observed flow we inject is not tomorrow's flow (we don't have it at auction time). It
is the **`:v3` load-analogue rule** — the fastest honest estimate available before
the gate. That rule governs *every* injection, fixed and (for sizing) elastic, and
gets its own panel.

---

## Where it lives, and how it links from the map

**Decision: a new top-level view, `#view=boundary`, tab label "Boundary."** It is a
peer of Map / Book / Scoreboard in `web/index.html`'s `<nav class="tabs">`
(after Map, before Predict — it is a map-adjacent concept). Rationale for a new view
rather than a map overlay: the per-country cards, the fixed-vs-elastic explainer, and
the flow-rule panel are too much to hang on the choropleth without burying the Books
page's sibling detail; and the boundary neighbours (TR/AL/MK/GB/UA) are **not in
`web/geo/zones.geojson`** (which holds exactly the 39 footprint features), so they
have no choropleth home anyway. The boundary view *reuses* the footprint geometry as
a faint backdrop and draws the neighbours as a ring around it (below).

**Link from the map (required by the charter).** The Map view (`#view-map`) gains one
affordance: the footprint's outer edge renders a thin **dashed boundary halo**, and a
sub-line under `#map-sub` reads *"power also crosses the edge — see how the model
treats the 9 out-of-footprint neighbours → Boundary."* Clicking the halo (or the
link) routes to `#view=boundary`. Symmetrically, the boundary view's "← back to the
price map" returns to `#view=map` on the same market day (day slider state is shared
via the existing `state.day` in `web/app.js`). No new day-routing machinery — the
boundary view reads the same `state.day` the map does.

---

## The surface, top to bottom

### A. The boundary ring — the hero

A single SVG: the 39-zone footprint drawn **faint and undifferentiated** in the
centre (reuse `web/geo/zones.geojson`, one muted fill — this view is not about
internal prices), and a **ring of neighbour nodes** placed around it at their real
compass bearing:

```
                    (N — Nordic edge)
         GB ●━━━ DK1                    ● NO-ext (fixed, faint)
        (elastic)  ┊
   GB ●━━━ FR      │   [ 39-ZONE FOOTPRINT ]      UA ●━━━ HU/SK/RO/PL
  (elastic)        │      (faint backdrop)        (elastic, 4 borders)
                   │                                    ┊
         MA/DZ ● ┄┄┘                          AL ● ┄ GR ┄ ● MK
        (fixed, faint)                       (fixed)      (fixed)
                              TR ●━━━ GR/BG
                             (fixed — NOT a book)
```

Each **node is a neighbour**; each **edge is a modelled border** drawn to its
in-footprint anchor zone(s). Two visual channels carry the whole taxonomy:

- **Kind** (the load-bearing distinction): **elastic books are solid, saturated
  accent edges with a filled node**; **fixed injections are dashed, muted grey
  edges with a hollow node.** A legend states it in one line: *solid = elastic
  counterparty (bids into the clear); dashed = fixed observed injection (price-taker
  schedule).* This is the fit/construct-style wall for pillar 6 and must read at a
  glance, in both light and dark theme.
- **Direction / magnitude** (per market day): each edge is annotated with the day's
  **net flow** across it (MW, signed toward the footprint), pulled from the data
  contract below. Import-heavy edges thicken; export edges reverse an arrowhead. The
  day slider (shared with the map) animates this.

Nodes: **GB** (appears twice — one node per border, DK1 and FR, because they are two
*independent* books with different carbon legs; or one GB node with two edges — see
Open decision D1), **UA** (one node, four edges to HU/SK/RO/PL), **TR**, **AL**,
**MK**, and a faint catch-all **"others (:v3 climatology)"** band on the remaining
edge segments to make the point that *everything* off-footprint is injected, most of
it with no name of its own. Clicking any node opens its card (section C).

### B. The fixed-vs-elastic explainer — the teaching panel

Directly under the ring, a two-column diagram that is the pedagogical heart. Left:
**fixed injection** rendered as a single vertical price-taker line on a mini
supply/demand axis — "observed flow = 800 MW, at any price." Right: **elastic book**
rendered as a **stepped ladder** — three import-supply rungs rising from the anchor,
plus (for UA) a firm demand slab at the cap and an elastic export tail. A toggle
*"show me the actual GB rungs for today"* swaps the schematic for the real
`get_boundary_orders` output of the selected border-day (data contract below). One
caption ties it to the clear: *"the fixed line always sells its full 800 MW no matter
the price; the ladder sells more only as the zone's price rises above GB's own cost —
so the border can now go the other way when we're cheaper than Britain."*

### C. Per-country cards

Clicking a ring node (or scrolling) reveals a card. Every card carries the same
skeleton so they are comparable: **KIND badge · how it enters · anchor · capability
sizing · borders · measured effect · roadmap.** The elastic cards fill every field;
the fixed cards make a virtue of the blanks (an anchor field reading "— none (not a
model)").

#### GB — elastic CCGT counterparty on two borders

- **KIND:** ELASTIC BOOK (CONSTRUCTED, declared anchor). Two independent books:
  **DK1↔GB Viking Link** (`VIKING_GB_BOOK`, cv21) and **FR↔GB IFA/IFA2/ElecLink**
  (`GB_FR_BOOK`, cv23). GB elsewhere is a fixed injection; **GB the zone is PARKED**
  (no internal GB clear until an Elexon/BMRS + UK-ETS fundamentals feed exists) — say
  this plainly.
- **Anchor:** GB's *own* CCGT SRMC = `TTF/0.52 + carbon/0.52 + €2 O&M`, then
  `× 1.15` (`GB_CCGT_EFFICIENCY = 0.52`, `boundary.jl:12`; `anchor_mult = 1.15`). The
  1.15 is the wave-2 sensitivity choice (DK1 favoured it monotonically; plain SRMC
  understates GB's willingness to pay) — flag it as *chosen, documented, not fit to a
  price*. **Carbon leg differs by border:** Viking uses `:eua` (its validated cv21
  config); FR uses `:uka` — the *correct* UK-ETS price from `carbon.uka_price`,
  falling back to EUA on the offline extract. Surface both; the difference is a real
  honesty detail, not noise.
- **Capability sizing:** `:atc_capped` (`boundary.jl:105`) — the day's offered
  Day-ahead explicit ATC, capped at the trailing-366d demonstrated max, with a
  trailing p95-per-4h-block floor on ATC gaps. FR↔GB has **no aggregate offered ATC**
  (published only per cable), so it AVGs within each of IFA/IFA2/ElecLink then SUMS —
  a detail worth a tooltip because it is where the double-count lived.
- **Ladders:** import supply `× [1.00, 1.15, 1.30]` at shares 50/30/20; export demand
  `× [1.05, 0.90]` at 50/50 (both books share the wave-2 shapes).
- **The double-count story (FR only — a first-class honesty exhibit):** ENTSO-E
  publishes the FR↔GB flow **both** as the aggregate `GB` code **and** as the three
  cables, so `get_net_imports` summed it ≈2×. `net_exclude_codes = ["GB", "GB_IFA",
  "GB_IFA2", "GB_ElecLink"]` strips all four; the ladder then prices the border once.
  Shipping the fix *alone* cost FR +4.2 July MAE (the phantom had accidentally been
  compensating France's too-cheap evening supply), so it shipped **paired** with the
  FR nuclear opportunity-cost anchor that fixes that curve at the root — a clean
  worked example of "you cannot ship half a correction." Render this as a small
  before/after: fixed double injection → single priced border.
- **Measured effect (the confirm A/Bs — cite the ledger, do not recompute):**
  - Viking, cv21 confirm 2026-07-24: DK1 July MAE **31.5→28.3**, corr **0.90→0.93**;
    March MAE **27.6→25.2**, corr **0.55→0.80**; no FR/NL/NO2 leakage. Src-implement
    confirm reproduced it (March 27.9→24.6 / 0.55→0.81; July 29.5→26.6 / 0.88→0.90).
  - FR↔GB pair, cv23: shipped with the FR nuclear fix (FR March MAE 38.2→16.2 for the
    combined lever); FR full-year corr **0.78** on the cv23 record. Label the pair
    honestly — the GB book is *half* of a two-bug lever, not a standalone win.
- **Roadmap:** GB the zone stays parked; a full GB behavioural book (all its borders,
  an internal clear) waits on an Elexon/BMRS + UKA feed. Say what's missing.

#### UA — war-constrained firm-slice buyer on four borders

- **KIND:** ELASTIC BOOK (CONSTRUCTED, declared anchor — the weakest anchor we ship,
  and we say so). `UA_BOOK_DEFAULT` on **HU / SK / RO**, `UA_BOOK_PL` on **PL** (PL
  adds the `UA_DobTPP` Dobrotvir radial to its flow codes). cv22.
- **The mechanism, stated as a story:** UA is a *war-constrained scarcity buyer*. On
  the **import** side it sells cheap surplus (nuclear/hydro-marginal) into the
  footprint at `0.55 × zone gas SRMC × [0.85, 1.00, 1.20]`. On the **export** side it
  buys with a **FIRM cap-priced base slice** — its demonstrated persistent import
  need, which *does not curtail on price* (a price-taker at the cap) — **plus** an
  elastic tail at `gas × [1.20, 1.00]`. The firm slice is the load-bearing piece; the
  elastic anchor is secondary (see below).
- **Anchor:** `:zone_gas_srmc` — our *own* gas SRMC, because **no UA fundamentals feed
  exists.** This is the documented "generic-anchor compromise" — the wave-1 risk,
  accepted here *because the firm slice, not the elastic anchor, does the work.* The
  card must state this weakness in the open, next to the measured win, so the win is
  not oversold.
- **Capability sizing:** `:p95_block` (`boundary.jl:239`) — pure trailing-366d p95
  gross flow per 4h block. UA's explicit ATC is stale/absent and understates realised
  flow ~4×, so the demonstrated-capability floor is used *uniformly* (no ATC cap).
  Worth a tooltip: this is *why* UA differs from GB's `:atc_capped`.
- **Firm slice:** `firm_price = 2999` (≈ cap), `firm_window_days = 28`,
  `firm_quantile = 0.10` — the firm base = trailing-28d **p10** of the daily
  4h-block-mean gross export flow zone→UA (`get_boundary_firm`, `boundary.jl:275`).
  Computed at runtime; no committed JSON.
- **The HU March lesson (a first-class honesty exhibit):** an early UA arm modelled
  UA's demand as *fully elastic*, which let HU's price breach in March when the
  elastic tail curtailed under stress. The firm slice — demand that *doesn't* back off
  on price — killed the breach. Render the lesson: elastic-only → breach; firm-base +
  elastic-tail → breach dead (**HU March MAE 28.24→28.29**, i.e. no damage while the
  July win landed). This is the single clearest illustration of *why the shape of a
  boundary bid matters*, not just its level.
- **Measured effect (cv22 confirm 2026-07-24, 24-day A/B — cite):** HU July MAE
  **72.3→57.1**, corr **0.69→0.79**; March breach dead (**28.24→28.29**); spillovers
  SK July eve bias **−82→−73**, SI July MAE **80.7→70.1**. **Accepted residuals
  (show them — the honesty rule):** HU March evening MAE **29.2→33.0**, RO/BG March
  **~+1**. A boundary book that helps July and slightly hurts HU-March-evening is a
  *trade*, and the surface should present it as one.
- **Roadmap:** the honest upgrade is a real UA fundamentals feed (retire the
  `:zone_gas_srmc` generic anchor); until then the firm slice carries the book.

#### TR — fixed observed injection (NOT a book)

- **KIND:** FIXED INJECTION (ex-ante-lagged observed schedule). **Anchor: — none.
  Capability sizing: — none. Ladder: — none.** The blanks are the point.
- **How it enters:** on the BG–TR and GR–TR borders, TR's observed physical flow
  (`entsoe.physical_flows`, via `get_net_imports`, `flows_imports.jl:466`) is
  committed as a price-taking supply (when TR imports into the footprint) or firm
  demand (when it exports) — at the ex-ante-lagged `:v3` value, never same-day. TR is
  listed as a GR neighbour in `Network.jl:734`.
- **Common misconception callout (verbatim intent of the charter):** *"The dictation
  called TR a 'book on dropped borders.' It is neither. (1) 'Flow-based border drops'
  are an internal fix for **in-footprint** Core-FBMC borders (AT–SI, CZ–SK…) —
  nothing to do with TR. (2) TR is simply never in the footprint, so its flow is
  injected as an observed schedule. The BG–TR p95-block recipe in the code
  (`boundary.jl` comment) is the **ancestor** of the UA sizing, not a TR book. If TR
  ever gets an elastic book it will be a new pillar-6 item — today it has none."*
- **Roadmap honesty — "what a TR book would need"** (make this a real, concrete
  panel, because it is the most instructive one):
  1. **A TR fundamentals anchor.** GB works because we can build GB CCGT SRMC from
     TTF + UK-ETS. TR's fleet is gas + lignite + hydro + a large and growing nuclear
     (Akkuyu) block, priced off BOTAŞ gas and a TL-denominated cost base with no
     EU-ETS carbon — none of which is in our feeds. Without a defensible TR marginal
     cost, an elastic anchor would be a guess, and the project's rule is that a
     declared anchor must be *defensible*, not invented.
  2. **A demonstrated-capability series for the BG–TR / GR–TR borders** — we already
     have this (the p95-block recipe), so this is the *easy* half.
  3. **A reason to believe TR bids elastically at all** at the day-ahead horizon
     across a non-synchronous DC-ish interconnection with its own market design —
     versus the current honest default that its schedule is exogenous. The bar to
     *promote* TR is the same bar GB/UA cleared: a measured confirm A/B on the coupled
     footprint showing GR/BG improve *within a regime* with zero new cap-hours and no
     envelope breach. Until that exists, fixed injection is the honest choice, and the
     page should say the absence of a TR book is a *decision*, not an oversight.

#### AL / MK — fixed observed injections

- One shared card (they behave identically). KIND: FIXED INJECTION, ex-ante-lagged,
  on the GR–AL and GR–MK borders (`Network.jl:734`). Same blanks as TR, same
  price-taker mechanics, same "no book, by decision" note. Kept distinct from TR only
  so the ring has honest per-node granularity. A one-line roadmap: same bar as TR;
  smaller borders, lower priority.

### D. The ex-ante flow rule (`:v3`) — the panel that makes every injection honest

Every fixed injection (TR/AL/MK and the unnamed rest) and the ATC-gap floors under
the elastic books rely on a flow we do **not** have at auction time (tomorrow's flow
publishes after the gate). So the footprint path defaults to the **`:v3`** rule
(`FLOW_ASOF_MODE`, `flows_imports.jl:63`; scoped default resolved in
`multi_zone_books.jl:549`). Make it legible with a small worked diagram, per border:

- **Load-analogue median.** Take the delivery day's D-1 **load-forecast vector** (the
  ex-ante "thermometer"), find the **16 trailing-365-day days nearest** to it in load
  shape, take the **median** of their observed flows on this border. (Warm days look
  like warm days; the analogue pool is the ex-ante climatology conditioned on
  tomorrow's forecast weather-via-load.)
- **D-2 observed blend.** Average that with the **D-2** observed flow — the fastest
  admissible signal (catches a regime change within 48 h).
- **D-7 Norwegian recency.** On Norwegian reservoir borders, add the `:v2` D-7
  recency component.
- `:d0` (same-day observed) is the **SEE legacy / byte-identity path only** — never
  the footprint default.

**One honest historical note the panel must carry** (the project's own audit
discipline): the pipelined *records* through cv24 were **NOT** ex-ante on flows — the
book workers silently used `:d0`. The audit found it (`docs/experiments/
exante-audit-2026-07.md`) and cv25 closed it. The live forecast path was always
correct. Show this as a "we caught our own lookahead bug" exhibit — it is exactly the
kind of honesty the whole site advertises.

### E. Propagation — the trade-wedge / flows tie-in

The charter asks how a boundary book propagates into the coupled solution. One panel,
built on the mechanism in `book_build.jl` Stage 7b (`:1165`):

- A boundary book is **just orders in the border zone's book** — an import-supply
  stack tagged `owner = "BOUNDARY:GB"` / strategy `boundary_import`, and an
  export-demand stack tagged `boundary_export` (firm slab + tail). It replaces the
  fixed injection (its codes are stripped from `get_net_imports` **and** the import
  backstop, `book_build.jl:720`), then clears like any other order.
- Because it is *in the clear*, its effect **propagates through the two-pass anchors**
  to zones that don't touch the border at all — the same emergent coupling documented
  for scenarios (+demand in DE_LU moves NO2's water value). Show it concretely:
  Viking's cheap GB supply into DK1 pulls DK1's price toward GB's CCGT cost, which
  the pass-2 `:hydro` anchors in the Nordic then re-bid against.
- **Tie into a flow view:** for the selected border-day, plot the **fixed injection
  we removed** (a flat line) against the **flow the elastic book produced** (which now
  reverses when the footprint is cheaper than GB) — the visible "trade wedge." Source:
  the removed injection from `get_net_imports`'s excluded codes; the produced flow
  from `simulations.transmission_flows` (or the boundary orders' cleared quantity).

---

## Data contract (additive — extend `v1/`, invent no backend)

Two sources, both already producible:

1. **`v1/boundaries.json` — generated from code, never hand-kept** (the same
   discipline as `bin/export_zone_strategies.jl`, which serialises `ZONE_PROFILES`).
   A new tiny exporter (`bin/export_boundaries.jl`) walks `ZONE_PROFILES`, collects
   every non-`nothing` `boundary_book`, and emits one record per (counterparty,
   border) plus the fixed-neighbour list. Proposed shape:

   ```json
   {
     "code_version": 31,
     "flow_rule": { "default": "v3", "legacy": "d0",
       "v3": "median of 16 load-analogue days (trailing 365, nearest D-1 load vector) blended with D-2 observed; + D-7 Norwegian recency" },
     "elastic": [
       { "counterparty": "GB", "book": "VIKING_GB_BOOK", "borders": ["DK1"],
         "anchor": "gb_ccgt_srmc", "carbon_source": "eua", "anchor_mult": 1.15,
         "efficiency": 0.52, "capability_mode": "atc_capped",
         "imp_ladder": [[1.00,0.5],[1.15,0.3],[1.30,0.2]],
         "exp_ladder": [[1.05,0.5],[0.90,0.5]], "firm_slice": false,
         "disable_env": "EUPHEMIA_DISABLE_CV21",
         "effect": { "zone":"DK1", "windows":[
           {"name":"July","mae":[31.5,28.3],"corr":[0.90,0.93]},
           {"name":"March","mae":[27.6,25.2],"corr":[0.55,0.80]}],
           "note":"no FR/NL/NO2 leakage", "ledger":"cv21" } },
       { "counterparty": "GB", "book": "GB_FR_BOOK", "borders": ["FR"],
         "anchor":"gb_ccgt_srmc","carbon_source":"uka","anchor_mult":1.15,
         "capability_mode":"atc_capped",
         "net_exclude_codes":["GB","GB_IFA","GB_IFA2","GB_ElecLink"],
         "atc_codes":["GB_IFA","GB_IFA2","GB_ElecLink"],
         "double_count_fix": true, "disable_env":"EUPHEMIA_DISABLE_CV23",
         "effect": { "note":"ships paired with FR nuclear anchor; not standalone",
           "fr_corr_record": 0.78, "ledger":"cv23" } },
       { "counterparty": "UA", "book": "UA_BOOK", "borders": ["HU","SK","RO","PL"],
         "anchor":"zone_gas_srmc","anchor_note":"generic — no UA feed; firm slice carries the book",
         "imp_ladder":[[0.4675,0.5],[0.55,0.3],[0.66,0.2]],
         "exp_ladder":[[1.20,0.5],[1.00,0.5]], "capability_mode":"p95_block",
         "firm_slice": true, "firm_price":2999, "firm_window_days":28, "firm_quantile":0.10,
         "pl_extra_codes":["UA_DobTPP"], "disable_env":"EUPHEMIA_DISABLE_CV22",
         "effect": { "zone":"HU", "windows":[
           {"name":"July","mae":[72.3,57.1],"corr":[0.69,0.79]},
           {"name":"March breach","mae":[28.24,28.29]}],
           "residuals":["HU March eve MAE 29.2→33.0","RO/BG March ~+1"],
           "spillovers":["SK July eve bias −82→−73","SI July MAE 80.7→70.1"],
           "ledger":"cv22" } }
     ],
     "fixed": [
       { "counterparty":"TR", "borders":["GR","BG"], "book": null,
         "roadmap":"needs a defensible TR marginal-cost anchor (BOTAŞ gas, no EU-ETS), a capability series (have it), and a measured confirm A/B to promote" },
       { "counterparty":"AL", "borders":["GR"], "book": null, "roadmap":"same bar as TR; lower priority" },
       { "counterparty":"MK", "borders":["GR"], "book": null, "roadmap":"same bar as TR; lower priority" }
     ]
   }
   ```

   The `effect` blocks are **the ledger's measured confirm numbers, quoted** — the
   exporter copies them from a small committed table (they are frozen historical
   measurements, not recomputed each run), so the surface never fabricates a score.

2. **Per-border-day realised flows and rungs — the existing books + flows parquet.**
   The `v1/books` capture (`run_pipelined_backfill(...; books_dir=)`) already tags
   boundary orders `owner = "BOUNDARY:GB"` / `"BOUNDARY:UA"` with strategy
   `boundary_import` / `boundary_export`, and fixed injections `owner = "IMPORT"`
   (`book_build.jl:1176`, `:49`). So the ring's per-day flow annotations, the "show
   the actual rungs today" toggle, and the trade-wedge panel **all read the books
   parquet already published** — filter `owner LIKE 'BOUNDARY:%'` for elastic rungs,
   `owner='IMPORT'` for fixed injections — plus `simulations.transmission_flows` for
   the cleared border flow. **No new backend.** If a lighter contract is wanted, add a
   `v1/boundary_flows.parquet` (columns `market_date, counterparty, border_zone, ts,
   kind, mw, price`) derived from the same capture, but the books parquet already
   suffices.

---

## Honest labels (non-negotiable, per the standing anchors)

- Every card carries a **KIND badge**: `ELASTIC BOOK · constructed` or `FIXED
  INJECTION · observed schedule`. The elastic badge sub-labels the anchor as
  *declared* (GB: defensible CCGT SRMC; UA: **generic — no UA feed**).
- **No price was fitted** — a footer line states the pillar-6 anchors are neighbour
  *fundamentals*, not regressions against our price errors; the confirm A/Bs are
  out-of-sample validation, not fit.
- **Show the residuals.** UA's card shows the HU-March-evening regression and RO/BG
  +1 with the same weight as the July win. The GB-FR card states it is half of a
  two-bug lever. Weak/absent (TR/AL/MK) get equal ring prominence to GB/UA.
- The `:v3` panel carries the **"we caught our own lookahead"** cv25 audit note.

## Interactions

- **Day slider** (shared `state.day`) animates every edge's flow and the "rungs
  today" toggle across the record window.
- **Click a node** → its card; **click an edge** → the trade-wedge panel for that
  border-day.
- **Kill-switch honesty toggle** (optional, nice): a "disable this book" switch per
  elastic card that, in a *client-side illustrative* mode, greys the ladder and
  restores the fixed injection line — visually reconstructing what
  `EUPHEMIA_DISABLE_CV21/22/23` does. It is illustrative only (no re-clear in the
  browser); label it as such.

## Roadmap honesty block (page footer)

One consolidated panel: **"What's not modelled yet, and why."** GB the zone is parked
(needs Elexon/BMRS + UKA feed). UA runs on a generic gas anchor (needs a UA
fundamentals feed). TR/AL/MK are fixed injections **by decision** — a book needs a
defensible anchor, a capability series, and a measured confirm on the coupled
footprint, and TR's fundamentals (BOTAŞ gas, no EU-ETS, Akkuyu nuclear) are not in
our feeds. The bar to promote any neighbour is the bar GB/UA cleared — stated once,
plainly, so the absence of the other books reads as rigour, not a gap.

---

## Open decisions for the implementation pass

- **D1 — one GB node or two?** Two edges from one GB node is geographically honest
  (Britain is one place) but hides that they are two *independent* books with
  different carbon legs. Recommendation: **one GB node, two labelled edges**, with the
  card showing both books stacked — the carbon-leg difference (EUA vs UKA) becomes a
  teaching detail rather than a confusing duplicate node.
- **D2 — ring geometry.** Fixed compass-bearing placement vs a force-directed ring.
  Recommendation: fixed bearings (TR SE, GB NW, UA E, AL/MK S) — stable across days,
  matches mental geography, and the footprint backdrop anchors it.
- **D3 — does the boundary view need per-day data, or is it mostly static?** The
  taxonomy (kind/anchor/capability/effect) is static from `boundaries.json`; only the
  edge-flow annotations and the "rungs today" toggle need per-day parquet. Ship the
  static ring + cards first (no per-day dependency), layer the per-day flows second.
- **D4 — the "9 neighbours" count.** The charter says "9 out-of-footprint neighbours";
  confirm the exact set for the map halo copy (named: TR, AL, MK, GB, UA; plus the
  unnamed `:v3` climatology band on other edges) so the number on the surface is
  computed from `boundaries.json`, not hand-typed.
