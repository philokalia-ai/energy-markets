# Iteration-9 scoping — endogenizing AL / MK / ME / HR (39 → 43 zones)

Phase-0 of roadmap item 3 (`docs/experiments/boundary-zones-roadmap.md`):
data/design scoping for promoting Albania, North Macedonia, Montenegro and
Croatia from exogenous boundary counterparties to real footprint zones.
No solver was touched; evidence is Postgres audits (`audit.sql` →
`audit_output.txt`) and offline single-zone merit book builds
(`trial_books.jl` → `trial_books_output.txt`). Audit window
**2024-07-01 .. 2026-07-01** (17,544 h) unless noted. All queries read-only.

**Verdict up front: all four zones are endogenizable now.** No blocker-on-X
anywhere; the caveats are (a) AL's per-type aggregate output only exists from
2026-05-27, (b) MK is missing 40 load-forecast days (5.5%) in the window, and
(c) HR's fleet is built entirely by fleet completion (0 unit-registry rows) —
all three degrade gracefully through existing mechanisms.

---

## 1. Data completeness (hard numbers per table per zone)

### DA prices (`entsoe.energy_prices`, hourly EUR, `contract_type='Day-ahead'`, `area_type_code='BZN'`)

| zone | market | history | resolution | missing days in window | avg €/MWh (window) |
|---|---|---|---|---:|---:|
| AL | ALPEX | 2023-04-12 → current | PT60M | 2 | 116.9 |
| MK | MEMO | 2023-05-11 → current | PT60M | 3 | 109.6 |
| ME | Montenegrin DA exchange (MEPX)* | 2023-04-27 → current (one stray 2014 day) | PT60M | 0 | 108.9 |
| HR | CROPEX (SDAC/Core) | 2017-10-18 → current | PT60M → **PT15M from 2025-10-01** | 0 | 111.2 |

*ENTSO-E files the ME series under BZN `ME` from 2023-04-27; the operator
attribution is not carried in the table.

Neighbor coherence (hourly corr over the window): **HR~SI 0.985, HR~HU 0.951**
(HR is fully Core-coupled), **MK~RS 0.931, MK~GR 0.860, ME~RS 0.835,
AL~GR 0.689, AL~ME 0.720**. AL is the least coupled (ALPEX clears standalone)
and trades at a premium (avg 116.9 vs GR 101.7) — a real out-of-sample test
for the fundamentals model, and exactly the boundary the July-2026 diagnosis
implicated.

### DA load forecast (`day_ahead_total_load_forecast`, BZN-filtered as `Loads.jl`)

| zone | resolution | history | missing days in window | avg / p99 load MW |
|---|---|---|---:|---|
| AL | PT15M | 2015 → current | **1** | 903 / 1,510 |
| MK | PT60M | 2015 → current | **40** (5.5%; clustered 2025-Q2/Q3, 2026-Q2, e.g. 2026-06-15..19) | 670 / 1,235 |
| ME | PT60M | 2014 → current | **0** | 381 / 575 |
| HR | PT15M+PT60M | 2015 → current | **0** | 2,109 / 3,070 |

MK's missing days make the zone-day book fail → the multi-zone builder already
handles this (zone dropped for the day, neighbors rebuilt with observed
imports restored). ~40/730 MK days will be missing from the record; acceptable.

### Wind/solar DA forecast (`generation_forecasts_for_wind_and_solar`, BZN-filtered)

All four zones: **0 missing days** in the window; types present — AL
Solar/WindOn/WindOff, MK Solar/WindOn/WindOff, ME Solar/WindOn, HR Solar/WindOn
(PT15M). Caveat: scattered whole days have **NULL `day_ahead_*_mw`** values
(measured: 2026-04-03 is all-NULL for AL/MK/ME), which fails the strict
single-zone path but is already absorbed by `res_coalesce_missing=true` — the
setting the EU-footprint path (`enrich_network=true`) always uses. Trial builds
confirm (§5).

### Unit registry (`production_and_generation_units`, deduped)

| zone | units | MW by fuel | verdict |
|---|---:|---|---|
| AL | 19 | Hydro reservoir 16u/1,493 MW; Solar 3u/240 MW | real fleet, hydro-only |
| MK | 15 | Lignite 4u/824; Hydro reservoir 8u/264; Gas 2u/251; Oil 1u/165 | real fleet |
| ME | 5 | Lignite 2u/420; Hydro reservoir 3u/342 | real fleet (no wind units — RES forecast covers) |
| HR | **0** | — | **fleet entirely via fleet completion** (works, §5) |

### Per-type aggregate output (`aggregated_generation_per_type`, hourly)

| zone | history | types (p95 MW in window) |
|---|---|---|
| AL | **2026-05-27 → only** (~1 month!) | Hydro res 1,112; Solar 274; RoR 56 |
| MK | full window | Lignite 393; Gas 227; Hydro res 329; WindOn 36 |
| ME | full window | Hydro res 526; Lignite 200; WindOn 105 |
| HR | full window (PT15M) | Hydro res 893; WindOn 880; Gas 512; RoR 283; Pumped 257; Hard coal 200; Solar 288; Biomass 76 |

**AL consequence**: before 2026-05-27 fleet completion/truthing are inert
(empty p95 dict — skipped loudly) and `hydro_scale` stays 1.0 (no
`get_hydro_availability` data). The book builds from the registry fleet alone;
reservoir dryness still works (weekly filling data exists 2024→: 114 rows;
MK 2022→, ME/HR 2015→). Fleet-truthing for MK is material and works: lignite
824 MW registry derated ×0.29–0.46 to the real ~210–390 MW running fleet.

### Actual load / per-unit output / reservoir weekly

`actual_total_load`: all four full window (eval OK). Per-unit
`actual_generation_output`: AL 8, MK 14, ME 4 units with recent output; HR 0
(no registry) — irrelevant for `:merit_order` (no UC, no ramp inference).
`aggregated_hydro_storage_filling_rate`: AL 2024→, MK 2022→, ME/HR 2015→.

### Offered ATC per border (window, MW)

**Implicit** (`offered_transfer_capacities_implicit`) — only HR appears, and
**only `contract_type='Intraday'`** rows (no Day-ahead rows exist for HR):

| border | avg | p10 | max | physical avg (dir) |
|---|---:|---:|---:|---|
| HU→HR | 558 | **1** | 4,752 | 498 |
| SI→HR | 548 | **0** | 4,067 | 396 |
| HR→HU | 235 | **0** | 3,004 | 33 |
| HR→SI | 657 | 12 | 4,008 | 149 |

The p10=0–1 collapse is the same flow-based-residual signature measured for
HU/BE/SK/AT/SI. Note the implicit loader (`_fetch_atc_aggregated`) has **no
contract_type filter**, so these Intraday leftovers WOULD be ingested as
endogenous ATC if HR simply joined the footprint.

**Explicit Day-ahead** (`offered_transfer_capacities_explicit`) — full window
coverage except where noted:

| border | avg out→in / in→out | p10 | note |
|---|---|---|---|
| GR–AL | 215 / 376 | 86 / 216 | endogenous candidate |
| GR–MK | 387 / 459 | 268 / 295 | endogenous candidate |
| AL–ME | 179 / 224 | 97 / 148 | endogenous candidate |
| MK–RS | 481 / 428 | 264 / 213 | endogenous candidate |
| ME–RS | 237 / 239 | 118 / 117 | endogenous candidate |
| HR–RS | 408 / 473 | 308 / 376 | endogenous candidate |
| BG–MK | 410 / 381 | 400 / 356 | **rows only from 2026-01-01** — endogenous from 2026, observed injection before (per-day `atc_linked` handles this automatically) |
| IT–ME | 478 / 609 | 25 / 385 | filed under aggregate **`IT`** — needs remap to **IT-CSOUTH** (Monita cable; physical flows confirm ME↔IT-CSOUTH). The blanket `IT→IT-NORTH` remap would mis-wire it |
| HR–BA, ME–BA, ME–XK, MK–XK | 431–581 avg | — | counterparty exogenous → stays observed injection |

**AL–MK: no border exists** — no ATC rows, no physical-flow rows in either
direction (there is no AL–MK interconnector). Not a modeling question.

### Physical flows (`physical_flows`, BZN both sides)

Every border of the four zones has full-window hourly coverage (HR–HU/SI at
15-min): GR↔AL, GR↔MK, AL↔ME, AL↔XK, MK↔BG/RS/XK, ME↔BA/RS/XK/IT-CSOUTH,
HR↔BA/RS/SI/HU. Nothing missing.

---

## 2. Network design

**New endogenous borders** (explicit-DA-ATC-backed, both directions): GR–AL,
GR–MK, AL–ME, MK–RS, ME–RS, HR–RS, MK–BG (2026→), ME–IT-CSOUTH (via the new
per-border remap). All go through the existing explicit-union path — the same
mechanism that carries CH and RS today.

**Dropped borders (Core FBMC)**: HR–SI and HR–HU join
`flow_based_drop_borders` (gated on `"HR" in fp`), falling back to observed
flows import-only, priced at the coupled anchor reference through HR's
profile anchor — the exact SK/AT/SI treatment. Rationale in §1: Intraday-only
residual rows with p10 = 0–1 vs 1.8–2.4 GW physical peaks.

**Remaining exogenous injections after iteration-9** (the new boundary): BA
(against HR, ME, RS), XK (against AL, MK, ME, RS), TR (against GR, BG), MD/UA
(RO/HU/SK/PL), GB, MT — unchanged elsewhere. BA is itself a future
endogenization candidate (real explicit ATC both directions, load/gen data,
but no 2026 DA prices — stays exogenous this iteration).

**Knock-on effects that MUST be re-audited in the coupled A/B** (all are
by-design changes, not regressions per se):

1. **RS**: MK/ME/HR leave RS's observed net-import injection and its
   `import_backstop` headroom accounting (demonstrated imports minus offered
   *endogenous* ATC — three new endogenous borders shift the quantity). The
   wave-1 scope decision explicitly deferred RS's boundary borders because of
   this entanglement; iteration-9 takes it on and must measure RS.
2. **SI**: `SLOVENIA_PROFILE.ref_priced_exports` currently treats SI–HR as a
   *retained exogenous* border (its ~1 GW HR export re-priced at the anchor
   ref). Border drops are undirected pairs, so dropping HR–SI applies on the
   SI side too: SI's observed HR flows move to the dropped-border code path
   (import-only injection + `anchor_export_mw` export demand for anchored SI)
   and the `ref_priced_exports` retained-border mechanism no longer sees HR.
   Same economics through a different mechanism — verify SI holds in the A/B.
3. **HU**: HU exports avg ~500 MW to HR (physical HU→HR 498 avg). With HR–HU
   dropped, that export leaves HU's book (HU carries no opportunity anchor, so
   no `anchor_export_mw` re-entry) — downward pressure on HU. The A/B carries
   a control arm (HR–HU endogenous on the Intraday-avg ATC, which at avg 558
   tracks the physical 498 surprisingly well) to measure which arm HU/HR
   prefer.
4. **GR/BG**: AL/MK leave their observed injections; the July-2026 boundary
   swing (+390 MW evening) must now be delivered endogenously by the AL/MK
   books + ATC. This is the point of the exercise — the July window is a
   primary eval window.
5. **IT-CSOUTH**: ME's ~240 MW avg export to IT-CSOUTH becomes endogenous.

### The HR / Core-FBMC recommendation

**HR joins now, with the border-drop treatment — do not wait.** Grounds:
(a) its published capacities are not merely flow-based residuals, they are
*Intraday* leftovers — there is no DA implicit ATC to endogenize at all, so
"waiting for better ATC" has nothing to wait for short of a real FBMC domain
model (explicitly out of scope, roadmap item 6); (b) the identical situation
(SK, AT, SI, BE, HU) was measured five times: drop + anchor-priced observed
imports works, keeping the residual starves the zone into phantom scarcity;
(c) HR's price is 0.985-correlated with SI — an anchored HR book referencing
its endogenous RS border and the coupled proxy will inherit the right level;
(d) HR brings the best data package of the four (full 15-min everything,
9 years of prices). The one genuine risk is the HU export loss (#3 above),
which the control arm resolves empirically.

---

## 3. Profile design

| zone | actual fuel mix (verified §1) | family | starting profile |
|---|---|---|---|
| AL | pure hydro (1.5 GW reservoir + 240 MW solar), winter import-dependent, ALPEX premium vs GR | SEE hydro, gas-anchored water value | `SEE_PROFILE` as-is (registry default). Watch: winter books are structurally short (§5) — endogenous GR/ME borders must deliver; if AL over-prices at the cap on normal winter days, the RO/RS-style `import_backstop` is the designed lever. A later `:reservoir_opportunity` upgrade is possible (weekly filling data exists 2024→) but NOT in the first cut — AL's price premium suggests gas-anchored SEE temperament is right |
| MK | lignite ~330 MW real (824 paper — truthing catches it) + gas 227 + hydro ~410 + heavy transit imports | SEE, import-leaning | `SEE_PROFILE` first; expect the RS/RO failure mode (scarcity markup blind to demonstrated imports) → promote to the `SERBIA_PROFILE` shape (`import_backstop` + `backstop_scarcity_credit`) if the A/B shows cap-days on import-covered hours |
| ME | hydro 953 p95 + lignite 200 real + wind 105; KAP smelter base-load demand; exports to IT-CSOUTH/RS | SEE hydro | `SEE_PROFILE` first. ME~RS corr 0.835 and the shared SEE temperament argue no special treatment; the IT-CSOUTH border gives it its export outlet endogenously |
| HR | hydro 893+283+257 + gas 512 + coal 200 + wind 880 p95; fleet 100% via completion; Core-coupled (SI 0.985) | Core FBMC, dropped borders + anchor | new `CROATIA_PROFILE` = the `SLOVENIA_PROFILE` shape: continental scarcity temperament (threshold 1.25, κ 1.5, peak κ 0.6), `opportunity_anchor=:hydro`, `import_backstop=true`. Anchor refs come from its endogenous RS border (+ SI/HU excluded by the drop) with the DE_LU/NL proxy fallback. `ref_priced_exports` for the retained HR–BA export (~216 MW avg) mirrors SI–HR's cv17 rationale — measure before adopting |

Registry changes: add `"HR" => CROATIA_PROFILE`; AL/MK/ME resolve to
`SEE_PROFILE` by default (add explicit entries + docstrings for the record).

---

## 4. Interaction with the virtual-boundary program

After iteration-9: **GR's only remaining virtual counterparty is TR; BG's is
TR** (both were GR–TR/BG–TR + GR–AL/GR–MK/BG–MK in wave 1). The wave-1
Mechanism-A books and the `NET_IMPORT_EXCLUDE_EXTRA`/`BACKSTOP_EXCLUDE_EXTRA`
hooks live only on the `exp/boundary-zones` branch — **grepped: zero
occurrences in main's `src/`** — so there is no double-treatment risk in the
product today. Sequencing rule: iteration-9 (this item) ships real AL/MK books
INSTEAD of the wave-1 virtual AL/MK books; the TR fundamental anchor (roadmap
item 4, needs the EPİAŞ ETL) then applies to the TR borders only. If item 4
lands first, its AL/MK arms must be dropped from its scope. The exclusion of
newly-endogenous counterparties happens natively via `atc_linked` (no hooks
needed).

New virtual-boundary candidates that appear once AL/MK/ME/HR are endogenous:
XK (borders AL/MK/ME/RS; has DA prices + load but no RES forecast) and BA
(borders HR/ME/RS; no current DA prices) — both stay observed injections this
iteration and inherit the "partial" verdicts of the wave-1 inventory.

---

## 5. Trial book builds (offline, no clearing)

`trial_books.jl`: single-zone `create_merit_order_book` per zone on
2026-01-21 (winter), 2026-04-03 (benchmark day), 2026-06-10 (summer;
MK's missing-load windows avoided). Result: **12/12 build cleanly under
EU-path settings** (9/12 with strict single-zone defaults — the three
2026-04-03 failures are the all-NULL RES-forecast day, absorbed by
`res_coalesce_missing=true`, re-verified individually).

| zone-day | day supply/demand MWh ratio | worst hour | notes |
|---|---:|---:|---|
| AL 2026-01-21 | **0.76** | 0.69 | winter: structurally short even with observed imports — endogenous borders essential |
| AL 2026-04-03 | 0.96 | — | NULL-RES day, coalesced |
| AL 2026-06-10 | 1.32 | 0.89 | hydro scale 0.89 from the new aggregate data |
| MK 2026-01-21 | 1.38 | 1.25 | truthing derates lignite ×0.46 |
| MK 2026-04-03 | 1.54 | — | |
| MK 2026-06-10 | 1.94 | 1.52 | |
| ME 2026-01-21 | 1.18 | 1.02 | completion +283 MW hydro |
| ME 2026-04-03 | 2.57 | — | |
| ME 2026-06-10 | 1.35 | 0.84 | hydro scale 0.58, dryness 0.11 (reservoir) |
| HR 2026-01-21 | 1.06 | 0.88 | fleet 100% completed: +953 hydro, +577 gas, +258 pumped, +206 RoR, +202 coal |
| HR 2026-04-03 | 1.49 | 1.11 | |
| HR 2026-06-10 | 1.19 | 0.88 | |

Fleet found / load found / RES found: yes across the board (HR's fleet via
completion, logged per type). Reservoir-level dryness resolves for all four
(“(reservoir levels)” in every hydro log line).

---

## 6. Implementation plan and gates

Ordered steps (each its own measured sub-iteration, standard doctrine):

1. **Network plumbing.** (a) Per-border aggregate-remap override so `IT↔ME`
   remaps to IT-CSOUTH while other `IT↔X` keep IT-NORTH (extend
   `AGGREGATE_BORDER_REPRESENTATIVE` to allow per-counterparty entries);
   (b) `flow_based_drop_borders` += HR–SI, HR–HU gated on `"HR" in fp`.
   Both inert for footprints without ME/HR.
2. **Profiles.** `CROATIA_PROFILE` (SLOVENIA shape) + registry entries for
   AL/MK/ME (SEE) with rationale docstrings.
3. **Footprint 43.** Add AL/MK/ME/HR to the EU footprint in `bin/` runners
   (`FOOTPRINT` constants); no library change needed — books, backstops,
   anchors, and per-day `atc_linked` all key off the passed zone list.
4. **Coupled A/B (the cv18 rule: full footprint from day one).** 39-zone
   baseline vs 43-zone treatment on (i) the 2026-04-01..05 benchmark,
   (ii) the 28-day production benchmark, (iii) the July-2026 regime window
   (primary target: GR/BG evening bias), (iv) a stable-window guard (March).
   Control arm for HR–HU endogenous-vs-dropped (§2.3).
5. **Re-audit the knock-on set**: RS backstop accounting, SI export path, HU
   export loss, IT-CSOUTH.
6. **cv bump + backfill + Metabase** per protocol (cv is 19 today; iteration-9
   ships as the next free cv with its ledger entry).

### The SEE byte-identity guard, restated for a footprint change

Adding zones changes multi-zone prices **by design** (coupling, injections,
anchor refs). The guard therefore splits in three:

- **G1 (byte-identity, must hold):** the single-zone SEE product and the
  5-zone SEE multi-zone product (`enrich_network=false`) are bit-identical
  under the new code — nothing in steps 1–3 touches their paths (drops are
  footprint-gated, remap override inert without ME, new profiles are new
  registry keys, `SEE_PROFILE` untouched).
- **G2 (byte-identity, must hold):** the **39-zone** EU footprint run under
  the NEW code (without the four zones in the zone list) is bit-identical to
  the same run under old code — proves every addition is footprint-gated.
  This is the refactor-guard recipe applied to a feature.
- **G3 (measured delta, by design):** the 43-zone run changes existing zones'
  prices; gated by the standard acceptance rule — target zones (new four +
  GR/BG July evenings) improve; no currently-good zone regresses >0.05 corr /
  >10 MAE on the benchmark windows.

Acceptance gates for the new zones themselves (there is no prior sim
baseline): MAE/corr vs their real DA prices on the A/B windows, judged
against the footprint's current tier — target corr ≥0.7 and MAE ≤35 for
HR/MK/ME (well-coupled, corr-to-neighbor ≥0.84 makes this realistic);
AL is the honest out-of-sample case (standalone ALPEX, corr-to-GR 0.689) —
report it, gate it only on "no cap-pinning / no negative-bias collapse"
(the NO1/BE/SE3 dropped-border failure modes), and calibrate a second
sub-iteration if needed.

Eval methodology notes: HR actuals are 15-min from 2025-10 (the
resolution-aware hourly-mean path already handles this); MK has 3 and AL 2
missing price days in the window; MK loses ~40 sim days to missing load
forecasts (graceful zone-drop, footprint unaffected).
