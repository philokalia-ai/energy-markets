# Pillar 5 — the Bid-Methodology surface: a design

> Chapter one of the SIX-PILLARS program, pillar-5 planning pass. This is a
> **design, not an implementation** — the page/surface spec a following build pass
> executes without re-deriving the pillar. It answers the pillar-5 charter
> (`docs/six-pillars-plan.md §"Pillar 5"`): the Books page is LOVED, so this pass
> **deepens** it — it makes the full order-book-construction machinery
> (`docs/six-pillars.md §5`) legible from the book itself, and adds the reference
> surface that teaches *how* a bid is built from named ex-ante characteristics.
> Verified against the code at `ENERGY_PRICES_CODE_VERSION = 31`.

---

## 0. The one idea

Every order in the merit book already carries a **strategy label** — the honest
source-side "WHY" of that block, written by the code that placed it
(`STRATEGY_DESCRIPTIONS`, `src/merit_order/book_build.jl:36`; rendered as the
book table's *why* column, `web/app.js:2861` `renderBookTable`). That label set is
a **vocabulary**: `srmc_base`, `peak_tranche`, `must_run_deep`, `water_value_*`,
`import_backstop`, `boundary_import`, `res_forecast`, … Each term is the *name of a
construction decision* whose rule lives in one named parameter.

**This surface teaches that vocabulary and wires every term to three things at
once:** (a) a live block in a real book where the term fires, (b) the named
parameter/formula that produced it (SRMC decomposition, a tranche multiplier, a
`ZoneProfile` field), and (c) that parameter's honest provenance — market-observed
vs declared, and which calibration version last moved it.

The jewel — the ladder chart, the coloured owner stacking, the clearing "μπίλια",
the cliff badge, the trade wedge — is **untouched at rest**. Everything here is
*opt-in depth*: an annotation you toggle on a block, a step-by-step assembly of a
book you already trust, and a separate reference page you can read cover to cover.

**The hard rule (charter): never hand-author a book number the site could
compute.** Every price, MW, multiplier and SRMC figure on this surface is either
read from the live book parquet, resolved from the running model's own exported
objects, or computed in-browser from those two — never typed into HTML. The design
below is built entirely around that constraint; where a new number is needed, the
spec names the export that must produce it.

---

## 1. Where it lives — two coupled halves + a bridge

The surface is **not one page**. It is an annotation layer welded onto the loved
Order-book tab, a standalone reference tab, and a step-through mode that bridges
them. Splitting this way is what lets us deepen the book without diluting it.

| # | Component | Home | New tab? |
|---|-----------|------|----------|
| **A** | **In-book annotation layer** — "explain this block" on the existing ladder + table | `#view=book` (extends `renderBookLadder`/`renderBookTable`) | no |
| **B** | **Bid-methodology reference** — SRMC decomposition, tranche/must-run schematic, the parameter→bid-category table, the zone-profile explorer, the strategy glossary, the calibration-honesty ledger | **new tab** `#view=method` ("How bids are built") | yes |
| **C** | **Build-the-book step-by-step** — the nine construction stages animated over a real book | a mode toggle inside `#view=book` | no |
| **D** | **Follow-one-unit walkthrough** (Korinthos-style) — one real unit traced through the nine stages | a scripted tour that opens from B and lands in A | no |

**Recommendation on the tab.** Add **one** new tab, `#view=method`, immediately
after "Order book" in the SPA nav (`web/index.html:72-80`). It is a *reference*
surface (read-first, interactive-second), which wants its own URL and its own
scroll — a sub-panel of the book tab would fight the ladder for vertical space.
The existing static zone-strategy table on the About page
(`web/about.html:570`, fed by `bin/export_zone_strategies.jl`) **stays** as the
honest no-JS fallback, and gains one line linking into the interactive explorer
(B5). The two read the **same** generated JSON, so they cannot disagree.

> Implementer decision left open (with my recommendation = dedicated tab): if the
> nav is judged too crowded at 8 tabs, B collapses into an expandable
> "Methodology" panel pinned above the book table in `#view=book`, and C/D are
> unaffected. Everything in this spec works either way; only the mount point of B
> changes.

---

## 2. Data contract — reuse first, one additive export

The never-drift discipline (`.claude/CODE_STYLEGUIDE.md`: "the published table is
GENERATED from the running code") governs this surface absolutely. Three data
sources already exist; this pass adds **exactly one** new generated file.

### 2.1 What already exists (reuse verbatim)

- **`/api/v1/books/:zone/:date`** — the per-day tagged ladder, `supply`/`demand`
  as `[price, mw, ownerIdx]` plus the parallel `strategies` array and
  `has_strategy` flag (`web/README.md` "Order-book data contract"; consumed by
  `renderBookLadder`, `app.js:2267`). **This already carries every block's WHY
  tag** — components A, C and D need no new book data.
- **`/api/v1/zone_strategies.json`** — every zone's resolved `ZoneProfile`, the
  `field_descriptions`, the deduplicated treatment groups, and the
  `strategy_outside_the_profile` honesty section (`bin/export_zone_strategies.jl`;
  rendered today at `about.html:750` `render`). Component **B5** (zone-profile
  explorer) is a richer render of this exact object.
- **`/api/v1/inputs/…`** — used only for cross-links (D can deep-link a zone's
  reservoir/RES panel); no dependency.

### 2.2 The one new export — `bin/export_book_methodology.jl` → `book_methodology.json`

Mirror `export_zone_strategies.jl` in every respect: resolve the running model's
own constants in-process, emit JSON, write by default OUTSIDE `data/web/v1/` (to
`data/calibration/book_methodology.json`) so publishing it is an explicit act, not
a side effect of `web_data_push.sh` (the exact reasoning in
`export_zone_strategies.jl:19-25`). Served at `/api/v1/book_methodology.json`.

Everything below is read from a `MeritOrderBook`/`Generators` constant — **nothing
is transcribed**. The test that guards it (a sibling of
`test_zone_strategy_export.jl`) asserts each section's key set equals the
`fieldnames`/`keys` of its source object, so adding a fuel or a constant without
describing it fails the build.

```jsonc
{
  "generated_utc": "…Z",
  "code_version": 31,
  "generated_from": "MeritOrderBook + Generators constants, resolved in-process",

  // --- 2a. The SRMC cost model (per fuel type) — src/generators/fuel_costs.jl ---
  "cost_model": {
    "gas": { "efficiency": 0.55, "emission_factor_th": 0.202, "vom": 2.0,
             "formula": "TTF/η + EUA·EF_th/η + VOM",
             "source": "GAS_PLANT_EFFICIENCY / GAS_EMISSION_FACTOR / GAS_VOM_COST" },
    "fuels": {                              // FUEL_SRMC_BASE ∪ FUEL_EMISSION_FACTOR_EL
      "Fossil Brown coal/Lignite": { "base_eur": 25.0, "ef_el": 1.25 },
      "Fossil Hard coal":          { "base_eur": 37.0, "ef_el": 0.90 },
      "Nuclear":                   { "base_eur": 10.0, "ef_el": 0.0  },
      "Hydro Water Reservoir":     { "base_eur": 12.0, "ef_el": 0.0, "note": "O&M only; water value applied in the book layer" },
      "…": {}
    },
    "live": { "ttf_eur_mwh_th": 31.4, "eua_eur_t": 71.2, "as_of": "2026-08-01",
              "note": "last close strictly before as_of — no lookahead; may be null offline" }
  },

  // --- 2b. Form-level constants — identical in all 39 zones (zone_profiles.jl:237-273) ---
  "form_constants": {
    "TRANCHES": [[0.55,0.95],[0.20,1.05],[0.15,1.25],[0.10,1.60]],
    "MUST_RUN_PRICE_FACTOR": 0.05,
    "MUST_RUN_SRMC_THRESHOLD": 1.15,
    "AVAILABILITY_FACTOR": 0.80,
    "PEAK_EXPONENT": 4.0,
    "BACKSTOP_PRICE_MULT": 1.8, "BACKSTOP_WEEKS": 8,
    "DEEP_SURPLUS_FLOOR_EUR": -20.0,
    "DERATE_HEADROOM": 1.15,
    "DEMAND_ELASTIC_SHARE": 0.02, "DEMAND_ELASTIC_PRICE": 250.0, "PRICE_CAP": 3000.0,
    "NUCLEAR_AVAIL_REF": 0.80, "NUCLEAR_AVAIL_FLOOR": 0.50,
    "descriptions": { "…": "one plain line per constant (a new CONST_DESCRIPTIONS map beside the consts)" }
  },

  // --- 2c. The strategy glossary — THE WHY-column vocabulary (book_build.jl:36) ---
  // Emit STRATEGY_DESCRIPTIONS verbatim so the page's glossary is generated, not a
  // third hand-copy. See §5.1: this retires the hand-mirror in app.js.
  "strategy_glossary": {
    "srmc_base": "base tranche at short-run marginal cost: fuel/efficiency + CO₂ + O&M, no scarcity markup",
    "peak_tranche": "…", "must_run_deep": "…", "water_value_reservoir": "…", "…": "…"
  },

  // --- 2d. Provenance — the fit/construct wall INSIDE pillar 5 (§6) ---
  // A new PROVENANCE map beside the ZoneProfile fields + form constants, keyed by
  // characteristic name → {kind, source, cv}. Guarded like FIELD_DESCRIPTIONS.
  "provenance": {
    "ttf/eua":            { "kind": "observed", "source": "market close, strictly pre-auction", "cv": 3 },
    "fleet p95 / installed": { "kind": "observed", "source": "trailing ENTSO-E output", "cv": 10 },
    "import_backstop qty": { "kind": "observed", "source": "trailing-8-weekday demonstrated headroom", "cv": 17 },
    "TRANCHES":           { "kind": "declared", "source": "named bidding form, OOS-validated", "cv": 10 },
    "scarcity_kappa":     { "kind": "declared", "source": "per-region calibration", "cv": 14 },
    "DEEP_SURPLUS_FLOOR_EUR": { "kind": "declared", "source": "support-scheme economics", "cv": 31 },
    "…": {}
  },

  // --- 2e. The calibration cv-ledger (§7). CURATED, but every row cites a repo doc
  // + its measured deltas — the one place hand-entry is admissible because the
  // numbers are results, not book numbers. Committed at docs/pillars/cv-ledger.json,
  // read (not regenerated) by the exporter so it ships in one payload. ---
  "cv_ledger": [
    { "cv": 31, "characteristic": "solar-regime floor (DEEP_SURPLUS_FLOOR_EUR)",
      "change": "regime-gated −20 price-taker floor for 6 continental solar zones",
      "measured": { "setA_dMAE": -1.50, "setB_dMAE": -0.27, "new_caps": 0 },
      "doc": "docs/experiments/solar-regime" },
    { "cv": 23, "characteristic": "nuclear_avail_share (FR)", "…": "…" },
    { "cv": 17, "characteristic": "import_backstop", "…": "…" }
  ]
}
```

**No other backend work.** Everything the four components render is one of: the
live book parquet (exists), `zone_strategies.json` (exists), or
`book_methodology.json` (this one file). This satisfies the charter's "additive
data contracts" anchor.

---

## 3. Component A — the in-book annotation layer

**Goal:** from the loved ladder, reveal *why this block sits here* on demand,
without changing the resting view.

The book table (`renderBookTable`, `app.js:2861`) already prints a `strategy` and
a `why` column when `has_strategy` is true. A deepens that from *label* to
*explanation you can act on*:

1. **Block → glossary link.** Every `why` cell (and every ladder slice tooltip via
   `renderBookLadder`) becomes a link to the matching B4 glossary entry. Hovering
   keeps today's inline `explain`; clicking opens the reference at that term.
   This is the "linked live to the strategy tags" wire — the WHY column *is* the
   glossary's index.

2. **"Explain this block" popover.** Clicking a supply block opens a small popover
   that resolves the block's tag to its *live arithmetic*, computed in-browser from
   `book_methodology.json` + the block's own `[price, mw, owner]`:
   - `srmc_base` on a gas unit → the SRMC waterfall (B2) *instantiated at this
     block's price*: "€94.8 = TTF €31.4 / 0.55  +  EUA €71.2 × 0.202 / 0.55  +
     €2.0 O&M". The three addends must sum to the block's own offered price (a
     built-in self-check; if they don't, the unit is not gas-TTF-priced and the
     popover says so — honesty over a fake reconciliation).
   - `peak_tranche_k` → "tranche k of 4: 15% of p_max at ×1.25 SRMC, plus this
     zone's scarcity/peak κ uplift" with the zone's resolved `scarcity_kappa` /
     `peak_kappa` from `zone_strategies.json`.
   - `must_run_deep` → "technical-minimum block at 5% of SRMC — below cost by
     design (`MUST_RUN_PRICE_FACTOR`)".
   - `import_backstop` → "elastic import headroom at 1.8× gas SRMC
     (`BACKSTOP_PRICE_MULT`), binds only near the cap" + a link to the zone's
     `import_backstop` provenance row.
   - `water_value_*` / `boundary_*` → the matching B-section anchor.

3. **Strategy filter chips.** A row of toggle chips above the ladder (one per tag
   present in this hour) dims every block except the selected strategy — "show me
   only the must-run blocks / only the imports / only the peak tranches". This is
   the read-only precursor to the C build mode and reuses the same tag grouping.

**Honesty guard:** A never adds a computed number the book didn't already imply —
it *decomposes* the block's existing offered price into its named parts and
asserts the parts reconcile. A decomposition that doesn't reconcile is shown as
"offered price €X; cost model does not fully explain this block" rather than
forced.

---

## 4. Component B — the Bid-methodology reference (`#view=method`)

A single scrollable surface, six sections, each generated. Order top-to-bottom is
the reading order of *how one bid is born*: cost → tranches → the parameter map →
the zone that tunes them → the vocabulary → the honesty.

### B1 · The SRMC decomposition explorer (per fuel type)

The atom of every thermal bid. An interactive **waterfall**: pick a fuel family
(reusing the book's `FUEL_META` colours + icons), see its SRMC assemble.

- **Gas** (`Fossil Gas`): three stacked addends `TTF/η`, `EUA·EF_th/η`, `VOM`,
  each a labelled bar, summing to the live SRMC. Two sliders — **TTF** and **EUA**
  — default to the live closes in `cost_model.live`; dragging them recomputes the
  total live, so a reader *feels* "gas SRMC ≈ €95 today, and here's why, and here's
  what it'd be at TTF €80." (Read-only exploration; nothing writes back.)
- **Every other fuel:** `FUEL_SRMC_BASE[fuel] + FUEL_EMISSION_FACTOR_EL[fuel]·EUA`
  — the base bar + the carbon bar, the EUA slider shared with gas. Lignite at
  €25 + 1.25·EUA visibly overtaking gas as carbon rises is the story this makes
  visceral.
- A one-line honest footnote per fuel from the cost-model `note` (hydro reservoir:
  "€12 O&M only — the water value is applied in the book, not the cost model", so
  a reader isn't misled that €12 is a hydro bid).

All numbers from `cost_model`; the arithmetic is in-browser. Fuel with no TTF path
shows the `FUEL_SRMC_BASE` fallback and says so.

### B2 · The tranche ladder + must-run economics schematic

How one unit's p_max becomes offered blocks. A single schematic bar = one unit's
capacity, sliced and priced, each slice tagged with its **strategy label** (the
same vocabulary as the book):

```
 min-load ├ must_run_deep  (×0.05 SRMC)  ┤ must_run_rest (below SRMC)
 above    ├ srmc_base 55% ×0.95 ┤ peak 20% ×1.05 ┤ 15% ×1.25 ┤ 10% ×1.60 ┤
          └──────────────── AVAILABILITY_FACTOR 0.80 of nameplate ────────┘
```

- The four `TRANCHES` shares/multipliers, `MUST_RUN_PRICE_FACTOR`,
  `AVAILABILITY_FACTOR` — all from `form_constants`, drawn to scale.
- **Must-run economics** stated plainly (from the glossary): the deepest block is
  bid *below cost* because restart costs exceed running below cost; a unit is
  "committed" when its SRMC < `MUST_RUN_SRMC_THRESHOLD` × the zone gas SRMC
  (`must_run_rest` = `min(max(0.5·SRMC, SRMC−40), nuclear_ceiling)` — render the
  formula, not a number).
- A "peak-hour" toggle overlays how `peak_kappa` and `PEAK_EXPONENT` lift the
  upper tranches in true peak hours (`norm_demand^4`), using a chosen zone's
  resolved κ. Outside peak the overlay is flat — the honest "this only fires in
  peak hours".

### B3 · The parameter → bid-category table (the interactive §5b)

`docs/six-pillars.md §5b` is *the* explicit characteristics table. Render it
interactively: **rows = named characteristics, columns = {value/source, feeds
which bid category, provenance}**, every value from `form_constants` /
`zone_strategies.json` / `provenance`.

- Each row's "feeds which bid category" cell links to the **strategy tag** it
  produces (→ B4 glossary → live book via A). This closes the loop: characteristic
  → strategy label → real block.
- Rows that vary by zone (κ, water value, anchors, backstops) show "SEE default →
  see per-zone" linking to B5; form-level rows show the single value.
- A **provenance badge** on every row: `observed` (green — market data) or
  `declared` (blue — a named, OOS-validated market characteristic), from
  `provenance.kind`. This badge *is* the fit/construct wall drawn inside pillar 5.

### B4 · The strategy glossary — the WHY-column dictionary

One card per `strategy_glossary` entry (generated from `STRATEGY_DESCRIPTIONS`):
the label, the source-side description, the parameter(s) that set it (link to B3),
and a **"see it live"** link that opens the Order-book tab on a zone/hour where
that tag is present and non-trivial (see §5.3 for how the exemplar is chosen
without hand-authoring). This is the vocabulary the whole surface is built on, so
it is the section every other section links *into*.

### B5 · The per-zone profile explorer

Promote the static About-page table (`about.html:570`) to a first-class explorer,
same JSON (`zone_strategies.json`), more depth:

- **Zone picker** (or click a zone on a small footprint map) → a card of that
  zone's resolved `ZoneProfile`, with **only the fields that differ from
  `SEE_PROFILE`** highlighted (the `differs_from_base` array already in the JSON),
  each field carrying its `field_descriptions` line and its B3 provenance badge.
  So "why does FR behave differently?" answers in one glance: `nuclear_srmc_floor
  55`, `opportunity_anchor :nuclear`, `nuclear_avail_share 0.40–0.95`, `boundary_book
  GB·UKA·3 cables`.
- **Treatment groups** — the `treatments` array: "39 zones resolve to N distinct
  parameter vectors"; group zones that share a vector (the real count of
  behaviours), exactly as the About summary does but clickable.
- **Boundary-book detail** — expand a `boundary_book` to its full struct (the
  `_jsonable` fields already emitted), not just the counterparty label — the
  collapse-hazard `export_zone_strategies.jl:39-43` warns about.
- **"Strategy not in the table"** — render `strategy_outside_the_profile` verbatim
  (border drops, the DE_LU/NL anchor proxy, the env-gated version switches). This
  is non-negotiable honesty: the page must not present the profile as the whole
  story.
- **Deep-link to a book** where the zone's distinctive mechanism fires (§5.3).

### B6 · Calibration honesty — observed vs declared, and the cv-ledger

Two artifacts, side by side (detailed in §6 and §7):

1. **The observed/declared split** — a compact two-column census of every §5b
   characteristic by `provenance.kind`, with the headline "pillar 5 is
   *constructed*: its **inputs** are market-observed, its **form** is declared and
   validated out-of-sample — no price is fitted."
2. **The cv timeline** — `cv_ledger` rendered as a vertical timeline: each entry
   is a characteristic that changed, the version, the measured Set A / Set B delta,
   and a link to the `docs/experiments/…` source. Weak-zone and NO-SHIP entries
   shown with equal prominence (the discipline is the point).

---

## 5. Wiring to the generated objects (the never-drift work)

### 5.1 Retire the hand-mirror of the strategy vocabulary

Today the WHY vocabulary exists **twice**: the Julia `STRATEGY_DESCRIPTIONS`
(`book_build.jl:36`, the source-side canonical) and a hand-kept `STRATEGY_LABELS`
in `app.js:1939`, whose comment says "keep the two in sync; the names are the
contract." A methodology page whose whole claim is "this is generated" cannot ride
on a hand-synced copy. **B4 renders from the exported `strategy_glossary`**, and
the build pass should regenerate `app.js`'s `label`/`explain` map from the same
export (or fetch it), leaving the *names* as the only hand-maintained contract.
Net: one source of truth for the WHY column, on both the book and the methodology
page.

### 5.2 Add two description maps beside their objects (styleguide idiom)

`FIELD_DESCRIPTIONS` (`zone_profiles.jl:285`) already does this for `ZoneProfile`
fields. This pass adds, in the same shape and guarded by the same key-set test:

- **`CONST_DESCRIPTIONS`** — one line per form-level constant
  (`zone_profiles.jl:237-273` + the cost-model constants), for B1/B2/B3.
- **`PROVENANCE`** — characteristic → `{kind, source, cv}`, for the observed/
  declared badge (B3/B6). Lives beside the constants and the `ZoneProfile` fields;
  the guard test asserts its keys cover every §5b characteristic, so a new lever
  cannot ship without declaring whether it is observed or declared.

Both are emitted by `export_book_methodology.jl`; neither is ever typed into the
web layer.

### 5.3 Choosing live exemplars without hand-authoring

B4/B5 promise "see this tag/mechanism in a real book." The exemplar zone-hour is
**not** hardcoded — it is chosen at render time from data already loaded:

- The SPA already fetches book parquets per zone/day. A tag's exemplar = the first
  (zone, hour) in the currently-loaded book set whose ladder contains that tag with
  a non-trivial MW and, ideally, near the clearing point. If nothing loaded yet,
  the link opens the Order-book tab pre-filtered to that tag's strategy chip (A3)
  and the first matching hour resolves client-side.
- For B5's per-zone mechanism deep-link (e.g. `import_backstop`), the target is
  that zone on a day the tag is present — resolved the same way. No committed
  "example day" list to drift.

This keeps the constraint absolute: the surface points *at* computed books, it
never *asserts* a book number.

---

## 6. The fit/construct wall, drawn inside pillar 5

Pillar 5 is a **constructed** pillar (`six-pillars.md`: "we construct the prices").
But "constructed" is not "declared out of thin air" — and this surface is where
that nuance is made honest. Every characteristic is one of:

- **market-observed** — a value read from data that exists before the auction
  gate, no choice involved: TTF/EUA closes; trailing p95 / installed capability;
  demonstrated import headroom (trailing-8-weekday); reservoir fill / dryness;
  flow climatology. The badge is **green**.
- **declared** — a named market characteristic *chosen* and then *validated on
  held-out windows*, never fitted to the scored prices: the tranche shares/
  multipliers, `MUST_RUN_PRICE_FACTOR`, the per-region `scarcity_kappa`/
  `peak_kappa`, `anchor_share`, `DEEP_SURPLUS_FLOOR_EUR`, `BACKSTOP_PRICE_MULT`.
  The badge is **blue**, and the tooltip cites the OOS validation (the cv-ledger
  row).

The B6 census makes the ratio visible: the *inputs* are overwhelmingly observed;
the *form* is a small set of declared, peer-reviewable parameters. That is the
precise, honest version of "no price is fitted" — and it is exactly the claim the
About page's fit/construct wall makes for the whole system, now shown *inside* the
book layer. The provenance map (§5.2) is generated, so this wall cannot rot.

---

## 7. The cv-ledger of measured changes

The charter and the task both ask for "the cv-ledger of measured changes." The
canonical ledger today is prose in `CLAUDE.md`'s `code_version` entry + the
`docs/experiments/` corpus — not machine-readable. Fully generating it is
impossible (the deltas are *results*), and inventing the numbers would violate the
whole ethos. The honest middle path:

- A small **committed** `docs/pillars/cv-ledger.json`, one row per
  characteristic-change: `{cv, characteristic, change, measured{setA_dMAE,
  setB_dMAE, new_caps, …}, doc}`. It is *curated*, but every row **must cite a
  `docs/experiments/…` file and carry the measured deltas from it** — so it is
  auditable against committed measured artifacts, not free-typed. This is the one
  admissible hand-entry on the surface, because these are experiment outcomes, not
  book numbers.
- `export_book_methodology.jl` **reads** (does not regenerate) that file and folds
  it into the payload, so it publishes in one artifact and a CI check can assert
  every `doc` path exists and every `cv` is ≤ `ENERGY_PRICES_CODE_VERSION`.

Rendered (B6) as a timeline, it turns the calibration history into the story the
program is proudest of: mechanisms shipped *with* their held-out numbers, and the
NO-SHIPs (nordic-wetness, cv28/29/30 floor family, cv18 shape levers) kept visible
beside them.

---

## 8. Component C — build the book step by step

The charter's explicit idea: assemble a book in the exact stage order of
`create_merit_order_book` (`book_build.jl:5-15`). This needs **no new data** — it
re-animates the live ladder by filtering on the strategy tags already present.

Map each construction stage to its tags:

| Stage (build order) | Strategy tags revealed |
|---|---|
| RES forecast | `res_forecast` |
| Net imports & trade | `import_fixed`, `import_backstop`, `boundary_import`, `boundary_export`, `ref_priced_export`, `export_demand` |
| Hydro | `water_value_gas_anchored`, `water_value_reservoir`, `water_value_anchored` |
| Thermal | `must_run_deep`, `must_run_rest`, `srmc_base`, `peak_tranche_*` |
| Demand | `demand_firm`, `demand_elastic` |
| Scenario | `extra`, `strategist` |

A stepper (◁ ▷ or "Play build") reveals the ladder cumulatively — RES first, then
imports stacking on top, then hydro, then the thermal tranches climbing, then the
demand curve dropping in from the right and the clearing μπίλια settling where they
cross. Each step shows the stage's one-line description and the count/MW it added.
It is the same ladder the reader already trusts, disassembled and reassembled — the
single most effective way to teach "how a book is built" and it costs only a filter
over `book.strategies`.

**Guard:** on pre-strategy-column books (`has_strategy=false`) C is hidden with a
note, exactly as the book table already degrades (`app.js:2858`). The resting book
view is unchanged unless the reader enters build mode.

---

## 9. Component D — follow one unit (Korinthos-style)

The narrative spine that ties B1–B3 together on a single real unit. "Korinthos" =
a real Greek CCGT in the units reference (e.g. Korinthos Power); the tour is
**data-driven** (any unit selectable), it merely ships pointing at a legible GR
gas unit so the SRMC story is vivid.

Trace the chosen unit through the nine stages, each panel reading its **real**
numbers from the live GR book + `book_methodology.json` + the units reference —
never hand-authored:

1. **Fleet completion / truthing** (`_true_up_fleet`) — the unit's nameplate, and
   its p_max after any p95/`:installed` derate (`DERATE_HEADROOM 1.15`). "This is
   the capacity we actually offer."
2. **SRMC pricing** — the unit's SRMC assembled via B1's gas waterfall at today's
   TTF/EUA. "This is what a MWh costs it."
3. **Committed set** (`_committed_set`) — is its SRMC below
   `MUST_RUN_SRMC_THRESHOLD × gas`? If so it is must-run this hour.
4. **The supply loop** — its blocks placed on the ladder: `must_run_deep` /
   `must_run_rest` (if committed) + the four `srmc_base`/`peak_tranche` tranches,
   each pulled straight from the live book by owner code, with its strategy tag.
5. **Where it landed** — the unit's cleared vs uncleared blocks relative to the
   clearing μβίλια, dropping the reader straight into component A on that exact
   hour with the unit pre-highlighted.

Because every panel resolves against the fetched book by the unit's owner code, D
is a *scripted tour over real data*, not a story with baked numbers — the
constraint holds. D is the page's "aha": one unit, cost → tranches → commitment →
placement → price, the whole pillar in one object.

---

## 10. Honest-labelling rules (bind the build pass)

From the standing anchors (`six-pillars-plan.md`) and the program methodology:

- **The jewel is untouched at rest.** A/C/D are opt-in; the default `#view=book`
  render is byte-for-byte today's ladder + table + wedge.
- **Constructed, not fitted — shown, not asserted.** The observed/declared badge
  (§6) is on every characteristic; the page states plainly that no price is
  regressed and that declared parameters are OOS-validated.
- **Weak zones at equal prominence.** B5 must not hide the low-corr zones or the
  `strategy_outside_the_profile` caveats; B6 shows NO-SHIPs beside ships.
- **Never a hand-authored book number.** Enforced structurally: A decomposes
  offered prices and self-checks reconciliation; B computes from exports; C filters
  the live book; D reads the live book by owner code. The only hand-entered numbers
  on the whole surface are the cv-ledger's *measured experiment deltas* (§7), each
  citing its committed source.
- **This pass does not re-teach coupling or predictions.** The 39-zone dual/ATC
  story is pillar 1; the fitted RES/load inputs are pillars 2–4. Where the book
  needs them (the trade wedge, the RES forecast block) B links out to those
  surfaces rather than re-explaining — the book methodology teaches *bid
  construction*, full stop.

---

## 11. Build sequence for the implementation pass

Ordered so value lands early and each step is independently shippable:

1. **`bin/export_book_methodology.jl` + the two description maps + the guard test**
   (§2.2, §5.2). Nothing renders without the generated object; build it first, with
   `CONST_DESCRIPTIONS`/`PROVENANCE` beside their constants and a
   `test_book_methodology_export.jl` asserting key-set coverage. Commit
   `docs/pillars/cv-ledger.json` with the cv31/23/17 rows to start.
2. **B4 glossary + §5.1 mirror retirement.** Generate the WHY vocabulary once;
   wire `app.js` to it. Small, high-leverage, removes an existing drift risk.
3. **Component A** — glossary links + "explain this block" popover + strategy chips
   on the existing book table/ladder. First reader-visible depth on the loved page.
4. **B1/B2/B3** — the SRMC waterfall, the tranche/must-run schematic, the
   interactive §5b table. The reference core.
5. **B5** — the zone-profile explorer (reuses `zone_strategies.json`); link the
   About static table into it.
6. **Component C** — build-the-book step mode (a filter over `book.strategies`).
7. **B6** — observed/declared census + cv-ledger timeline.
8. **Component D** — the follow-one-unit walkthrough (needs A, B1, B2 in place).

Steps 1–3 are a complete, shippable increment on their own; 4–8 deepen it.

---

## 12. What this pass returns

A single interactive surface — a new `#view=method` reference tab plus an
annotation layer, a step-through mode and a one-unit walkthrough grafted onto the
loved Order-book tab — that makes pillar 5 legible: **how a bid is built from named
ex-ante characteristics, every number generated from the running model, the WHY
vocabulary wired live to real blocks, and the fit/construct wall drawn honestly
inside the book layer.** One additive export (`book_methodology.json`), two
description maps beside their constants, one curated-but-cited cv-ledger; the jewel
untouched at rest. Enough for an implementation pass to build it without
re-deriving the pillar.
