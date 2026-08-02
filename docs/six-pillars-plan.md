# The six-pillars meta-plan — a plan of plans

> Chapter one of the SIX-PILLARS program. This is **not** a design. It is the brief
> handed to six dedicated planning passes — one per pillar — each of which gets its
> **own context** to "design something genuinely nice". Read
> [`six-pillars.md`](six-pillars.md) first (what each pillar IS); this file says what
> each *planning pass* should deliver and the constraints it must respect.

## Standing anchors (bind every pass)

- **The Books page is LOVED.** The per-plant tagged order ladders + the demand curve
  + the crossing tranche that sets the price (`web/index.html` `#view=book`) are the
  jewel. A plan may *extend* it, never replace or dilute it.
- **The horizon page is LOVED — with one required addition.** The "Recent days" /
  next-7 view (`#view=horizon`) with its frozen-vintage "what we said, when" overlay
  stays. **It MUST gain the PREVIOUS 5 days alongside the next 5** — a symmetric
  ±5-day window centred on today, so a visitor sees settled-vs-said history and the
  forward horizon in one continuous strip. This is a hard requirement on the pillar-2
  (or a dedicated horizon) pass, not a suggestion.
- **Everything else is open for reinvention.** map, explorer, predict, scoreboard,
  cases, about — a pass may re-cut, merge, or replace these. New surfaces are
  explicitly invited (a solver page? per-prediction pages with the knobs exposed? a
  boundary-zones page?).
- **Honesty is non-negotiable.** Every surface keeps the fit/construct wall visible,
  labels FITTED vs CONSTRUCTED, shows weak zones with the same prominence as strong,
  and never implies a price was fitted.
- **Additive data contracts.** Prefer extending the existing `v1/` parquet/Worker-API
  contract (books, inputs, scoreboard) over inventing new backends.

---

## Pillar 1 — The solver: charter for a "how the auction clears" pass

Design a surface that makes the *clearing mechanism itself* legible — the thing that
is provably exact (GME €0.00). The pass should decide whether this is a new **Solver
page** or an extension of the Books page: show the coupled 39-zone clear as a system
(zonal balance duals = prices, ATC-bounded flows, the two-pass anchor feedback), and
foreground the **published-auction validation** (feed real GME/OMIE books → recover
the official price) as the trust anchor that separates "the mechanism is right" from
"the inputs are hard". Candidate elements: an interactive single-border two-zone
clear (drag ATC, watch prices converge/diverge), the pass-1→pass-2 anchor animation,
and a plain-language "why zonal prices are duals". Constraint: it must not re-teach
the order book (that's pillar 5) — it teaches *coupling*. Deliverable: a page spec +
the data/compute it needs (most already exists in the extract).

## Pillar 2 — Load prediction: charter for a per-prediction pass (+ the horizon fix)

Design the **load** prediction surface AND own the **horizon ±5-day** requirement
above. The per-prediction view should expose the model as a first-class object: which
family serves this zone (LightGBM vs pack, the badge already exists), the drivers
(temperature, degree-hours, calendar/holidays, AR lags), the honest vintage, and the
OOS scorecard (MAE/corr/bias vs the pack and vs ENTSO-E's own D-1). The owner's
"per-prediction pages with the knobs" idea lives here: let a visitor perturb a driver
(a cold snap, a holiday) and watch the predicted load — and then, because load feeds
demand, optionally watch the price move (the scenario API already supports this via
`load_modifier`). Constraint: keep prediction (fitted) visually distinct from the
price it feeds (constructed). Deliverable: the load-prediction page spec + the
horizon-page redesign that adds the previous 5 settled days beside the next 5.

## Pillar 3 — Solar prediction: charter for the collapse-first pass

Design the **solar** surface around the one thing that makes solar special: the
**collapse question**. Near the RES-coverage threshold a small solar error flips
whether midday price crashes to ≤0, and that classification dominates MAE. The pass
should make *tomorrow's predicted midday RES coverage* and its collapse-risk the
headline (the map already leans this way — decide whether solar gets its own view or
owns the map's colouring), and surface collapse hit/false-alarm rates as first-class
metrics beside MAE/corr. Show the capacity-normalization honestly (ratio vs trailing
p95). Constraint: this pass must coordinate with the pillar-5 solar-regime floor
(cv31) — the fitted solar input and the constructed price floor are two halves of one
story and should read as such. Deliverable: a solar-prediction/collapse page spec.

## Pillar 4 — Wind prediction: charter for the "physics still wins" pass

Design the **wind** surface honestly around the finding that the *physical
power-curve pack still beats LightGBM on onshore* — a rare case where the simpler,
more physical model wins, and a good story. Show the power curve, the 100m-cell / OSM
115k-turbine geometry, the GFS-vintage discipline (and the v1→v2 train/serve bug fix
as a worked honesty example), and the per-zone ML-vs-pack verdict. Expose the
onshore/offshore split (offshore-heavy NL is where ML wins). Constraint: do not
oversell — wind is the weakest of the three inputs and the surface should say so, with
the residual seasonal bias visible. Deliverable: a wind-prediction page spec that
could share a frame with solar (a unified "RES prediction" page is a legitimate
outcome if the pass argues for it).

## Pillar 5 — Order-book construction: charter for the Books-page extension pass

The Books page is LOVED — this pass **deepens** it, it does not rebuild it. The
opportunity: today the page shows the crossing tranche; the full pillar-5 machinery
(the named characteristics table in `six-pillars.md §5b`) is not yet legible from the
book alone. Design how to reveal, on demand, *why each block sits where it does* —
the strategy label is already on every order (`STRATEGY_DESCRIPTIONS`); surface the
must-run discount, the scarcity/peak κ uplift, the water-value anchor, the import
backstop, the solar floor as annotations a visitor can toggle. Consider a "build the
book step by step" mode (RES first, then imports, then hydro, then thermal tranches,
then demand — the exact stage order in `create_merit_order_book`). Keep the
generated-from-code zone-strategy table (`about.html`) wired to the same object.
Constraint: never hand-author a book number the site could compute. Deliverable: a
Books-page extension spec.

## Pillar 6 — Out-of-EU behaviours: charter for a boundary-zones pass

Design the **boundary-zones** surface the owner floated. The story is unusually
concrete: TR/AL/MK enter as fixed (ex-ante-lagged) observed injections; GB and UA are
promoted to *elastic counterparty books* on named borders, each anchored on the
neighbour's OWN fundamentals (GB CCGT SRMC with UK-ETS carbon; UA's war-constrained
firm slice). Design a page that shows the footprint boundary as a ring of neighbours,
each labelled by *how* it enters (fixed injection vs elastic book) and *why*, and for
the elastic ones shows the demonstrated-capability sizing and the anchor. This is
also where the **ex-ante flow rule** (`:v3` load-analogue + D-2) should be made
legible — it governs every injection. Constraint: correct the common misconception
(baked into the owner's own dictation) that TR is a "book" — it is not; the page must
teach the fixed-vs-elastic distinction cleanly. Deliverable: a boundary-zones page
spec + how it links from the map.

---

## What each pass returns

A single page/surface spec (structure, data contract, the honest labels, the
interactions) — enough that a following implementation pass can build it without
re-deriving the pillar. No pass ships code here; the [site stub](../web/about.html)
in this same branch makes the six-pillar structure visible now, and the per-pillar
redesigns replace it surface by surface.
