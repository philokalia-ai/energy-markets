# cv25 — plan

## Invariants

Five things do not change. Everything else is negotiable, and most of it should go.

1. **Ex-ante.** Only information available before the auction gate enters a price.
2. **No forward-looking bias.** Any query window that touches the delivery day is a
   defect, not a trade-off.
3. **Open data.** The published extract reproduces the published record.
4. **Open source.** The tool is meant to be read and run by other people.
5. **Reproducible with HiGHS.** The published record must be reproducible by anyone
   with the open-source solver — that is the invariant, not "HiGHS everywhere".
   This is an academic project with an academic Gurobi licence: **use Gurobi for
   development and iteration**, where it is the faster tool. The ship gate is that
   HiGHS reproduces the result (decomposed mode is bit-identical across solvers, so
   this costs nothing but the confirming run).

Everything below serves those five. Byte-identity with older records, historical
kill-switches, parked levers, and unused subsystems do not — git holds the history.

## What cv25 delivers

A corrected, genuinely ex-ante record on a smaller codebase.

- Four structural defects fixed (they change prices; that is the point).
- The calibration re-derived — not re-tuned — against the corrected physics.
- A materially smaller model: fewer modes, fewer knobs, fewer subsystems.
- A record whose headline number means what it says.

## Phase 0 — Free audits, no code change

**0.1 Which flow mode measured which calibration decision.** The scoped `:v3`
resolution lives only in `run_multi_zone_market_clearing`; `mz_build_books` (the
pipeline's entry) has none, so pipelined runs used `:d0`. Sequential A/B harnesses
resolved `:v3`. For every shipped treatment (cv17 backstops, cv21/22 boundary books,
cv23 FR/Norway), read its experiment doc and record which harness — therefore which
mode — measured it. **This sizes the real re-calibration surface.** Decisions
validated under `:v3` need no revisit *on account of the flow defect* — but every
shipped treatment was measured under the doubled ATC regardless of harness, so this
is not a Phase-4 exemption.

**0.2 Restate cv24 honestly.** The published figures are not ex-ante figures. Say so
in the README and the ledger now, independently of cv25. This is invariant 1, not a
cv25 deliverable.

**0.3 Truncated-day policy.** 65 of 1,304 days carry fewer than 24 UTC hours. Decide
before the backfill whether the source data is genuinely missing (record explicit
holes) or recoverable (repair the extract). The headline denominator depends on it.

**0.4 Cold start.** `:v3` needs a trailing-365-day analogue pool and a flow
climatology. On 2023-01-01 — day one of the record — the extract has no trailing
history. Establish what the first pool-buildup window actually uses and whether the
extract's lookback is deep enough, before Phase 5 discovers it.

**0.5 Fix-4 frequency.** Count the days on which a stale-validity unit generating on
day D actually enters the fleet. The plan asserts "few"; measure it.

**0.6 Lookahead sweep.** Grep every date-bounded query in `src/` for day-inclusive
upper bounds. Two are known (`registry.jl:182,266`). Invariant 2 deserves a
systematic pass, not two point fixes.

## Phase 1 — Subtraction (price-inert, guarded bit-identical)

Ships before any physics change, so the fixes land on a small codebase.

**Design target: the code should look like the table.** The published zone-strategy
matrix — one row per zone, columns being discrete treatments (scarcity shape, hydro
model, anchor, import backstop, credits, boundary book, fleet truth, thermal
multiplier) — is not a rendering of the calibration; it *is* the calibration, and the
code should say so. After Phase 1 a zone's strategy should be one flat struct whose
fields are exactly that row, read by code that does not need to know which cv
introduced which field. Concretely: the 19 never-varying fields leave the struct (they
are model constants, not zone strategy), the shadowing kwargs go, the 17 distinct
vectors are named for what they *are* rather than for the region that first needed
them, and a reader can put the struct and the table side by side and see the same
thing. If a future mechanism cannot be expressed as another column, that is a signal
to reconsider the mechanism, not to widen the struct.

| remove | evidence |
|---|---|
| **`:uc_based` + `:alternative` order methods** and the UC subsystem behind them — `src/uc/`, `UnitCommitment.jl`, `BiddingStrategy.jl`, `AlternativeOrderBook.jl`, `clearing/iterative.jl`, the `simulations.uc_*` tables, the two nightly workflows | **~4,500 lines** once the modules below are counted with it (the adapters, inference, initial conditions, the iterative driver and the partial cuts) — the 2,387 in `src/uc` + `UnitCommitment.jl` + `BiddingStrategy.jl` + `AlternativeOrderBook.jl` + `iterative.jl` is only half of it. Not reachable from the product: the EU footprint, the daily forecast and every backfill are `:merit_order`. Only `generate-energy-prices.yml` still *produces* `:alternative` rows on schedule; the multi-zone nightly already defaults to `merit_order`. **Decision needed: does anything consume those two products?** If yes, keep the workflows and drop the rest; if no, all of it goes. |
| **`:v3` mode dispatch cleanup** | `:v3` is *implemented on* the `:v2` source map and degrades to it, so what is deletable is the mode dispatch and `FLOW_ASOF_LAG` — a few dozen lines, not a subsystem. Say so rather than claiming a large win. |
| **cv18 parked levers** `unit_srmc_spread`, `export_absorption_steps` + their two `book_build.jl` sites + `EUPHEMIA_DISABLE_CV18` | Measured, documented, never activated. |
| **19 `ZoneProfile` fields that never vary** across 39 zones | They are constants wearing a parameter's clothes. Move to module constants; the struct keeps only what differs. |
| **23 of `create_merit_order_book`'s 39 kwargs** | Each shadows a profile field with a `x === nothing ? profile.x : x` line. `with_profile` already exists; one `overrides` argument replaces the lot. |
| **Duplicate profiles** | `ROMANIA_PROFILE`, `SERBIA_PROFILE`, `HUNGARY_PROFILE` are identical definitions; `IBERIA_PROFILE` equals `SEE_PROFILE`. 22 names describe 17 distinct vectors — name the 17. |
| **The remaining name-vs-vector gap** | After the Iberia and Sweden-South aliases go, the file still holds **19 constants for 17 distinct vectors**. Measured field-wise: `SE3_PROFILE === NORWAY_ANCHORED_PROFILE`; `SWISS_PROFILE` has silently converged to both; `CONTINENTAL_PROFILE == BALTIC_PROFILE`; `BELGIUM_PROFILE == SLOVENIA_PROFILE`. The first two are pure duplication and should merge. The last two are *semantic coincidences with different rationales* — their real difference lives in the network build (border drops), not the profile — so merging them would hide a distinction rather than reveal one. **Decision: merge the duplicates, keep the coincidences, and say in the atlas why two zones with the same vector are still different treatments.** That is the defined end state for this step. |
| **`water_value_base` / `water_value_span` are collinear with `hydro_model`** | Measured across all 39 zones there are exactly two combinations: `:gas_anchored → (0.85, 0.9)` (26 zones) and `:reservoir_opportunity → (0.6, 0.5)` (13). They are constants *of the hydro model*, not zone strategy. Key them off `hydro_model` → 20 → 18 fields, and the table's water-value columns collapse into "hydro model". |
| **The remaining 8 shadow kwargs** | `scarcity_threshold`, `scarcity_kappa`, `peak_kappa`, `water_value_base`, `water_value_span`, `thermal_srmc_multiplier`, `hydro_model`, `nuclear_srmc_floor` still duplicate profile fields through `x === nothing ? profile.x : x`. Their only caller outside `book_build.jl` is a test. `with_profile` + `profile=` replaces the lot. |
| **FR's four nuclear scalars are one treatment in four columns** | `nuclear_srmc_floor`, `nuclear_avail_share_lo/hi`, `nuclear_bid_ref_ceiling` are FR-only and always move together. A `BoundaryBook`-style bundle makes the table row read "nuclear book: FR" instead of four numbers — which is what "the code should look like the table" means. |
| **Strategy that lives OUTSIDE the struct** | The FR-by-name and `CV23_NO_ZONES` env-gated rewrites inside `get_zone_profile`, the hardcoded `("DE_LU","NL")` anchor proxy, and the border drops in the network build. A reader cannot see these in the table at all. Either bring them into the profile or make the published table show them as their own columns. |
| **Kill-switches AND `:d0`, at ship time — not in Phase 1** | `:d0` is the process default and the SEE single-zone path never resolves a mode, so deleting it in Phase 1 breaks Phase 1's own bit-identity gate by construction. Worse, the Phase-3 "Δ from ex-ante honesty" arm *is* a `:d0` run — deleting it early forces that arm cross-binary, which the plan forbids elsewhere. Keep `:d0`, `:clim`, `:dlag` and the switches through Phase 3 as ablation arms; delete them all in one sweep afterwards. |
| **`test/archive/`, stale `test/scripts/`, `test/manual/`** | 3 + 42 + 11 files; keep what a third party would run. |
| **`src/mpcc/order_books.jl`** (363) — the UC→book adapters | Callers are only the `:uc_based` branches (`single_zone.jl:241`, `iterative.jl:132`, `multi_zone_run.jl:200`). |
| **The parameter-inference subsystem**: `generators/parameter_inference.jl` (265), `inference_cache.jl` (454), `initial_conditions.jl` (331), the `simulations.generator_inferred_parameters` table, `bin/refresh_inference_cache.jl` (121) and its workflow | Verified: no caller outside `src/generators/` and `src/uc/` — only module exports. UC is their sole consumer. |
| **`bin/iterative_multi_zone_main.jl`** (251) + its workflow | The plan deleted `clearing/iterative.jl` but not its driver. |
| **Partial cuts**: `_create_multi_zone_order_book_alternative` (~370 lines of `multi_zone_books.jl`), the `:uc_based` branches in `single_zone.jl` / `batch_runners.jl`, the `MARKUP_FACTOR` plumbing | |
| **Extract the competitive price reconstruction** as a pure function (~140 lines of `mpcc/solver.jl`) | Numerically inert, so Phase-1 eligible. It is the arithmetic that decides every published price and today it cannot execute outside a live MIP solve. Highest-leverage change for an outside reader auditing how a price is made. |

> **The hand-maintained atlas had already drifted.** `docs/calibration-atlas.md`
> listed RO/RS/HU/SI as plain `SEE_PROFILE` and had no row at all for the
> import-backed treatment — wrong against the registry it claims to describe. It was
> corrected in the same PR, but this is precisely why the plan's ship gate requires
> the zone-strategy table to be **generated from `get_zone_profile`**: a calibration
> table maintained by hand is wrong within one iteration, and a wrong table is worse
> than none when it is also the design spec.

> **Consequence recorded during Phase 1.** `docs/experiments/pl-diagnosis/`
> recommendation #1 was a PL-scoped `unit_srmc_spread` activation, and its harness
> `ab_pl_both.jl` now throws. Under "git holds the history" that is accepted — but
> the PL path is no longer a flag flip, it is a re-implementation. Any future
> revival should come back as a border-scoped redesign validated on the coupled
> footprint, which was the cv18 verdict's own prescription.

Gate: the 39-zone EU + GR single-zone bit-identity guard, at every step. Prices do
not move in Phase 1.

## Phase 2 — The four fixes, with ablation

Each behind a switch so arms come from one binary.

1. **ATC canonicalisation** — one flow variable per unordered border
   (`exp/atc-canonicalisation`, measured).
2. **Flow-mode resolution** — `mz_build_books` takes the policy; better, both callers
   go through one `mz_resolve_policy` that owns flow mode, decomposition and the
   `:p95` fallback. After Phase 1 there is only `:v3` to resolve.
3. **ISO-year in the reservoir queries** — `year(day - Day(dayofweek(day) - 4))`.
4. **Delivery-day exclusion in the fleet probe** — both sites.

Plus the same-class stragglers, which are not optional here:

- `MAX_PLAUSIBLE_UNIT_MW` in `fleet_data.jl`'s `get_installed_capacity_by_type`
  (verified missing). It feeds the `:installed` fleet-truth denominators and FR's
  nuclear availability share — the flagship cv23 mechanism. Re-calibrating FR around
  a corrupt denominator would bake in a new absorbed defect.
- Price-provenance observability: the rent-sign check abandons the competitive
  reconstruction for a whole period with no warning and no field on the result.
  Make it countable before calibrating against those prices.
- **The rent-sign fallback is period-WIDE across unrelated components** (found by
  #223's review): a violation on one border discards the reconstructed price of
  every other component in that period too, including isolated ones that were
  perfectly consistent. Now one `if`-scope away from being fixable per component,
  and pinned by a test.
- The marginal-price accumulator mixes supply-max and demand-min in one variable,
  seeded by whichever marginal order is enumerated first — the published price for
  such an hour is an artifact of book-assembly order. Same class as the provenance
  straggler above: a nondeterminism in the published price.
- `test/scripts/pipeline_identity.jl` compares a `:v3` arm against a `:d0` arm and
  calls the result identity. Fix it, or it certifies nothing.

**Measurement:** leave-one-out ablation on the seasonal windows. Fixes 3 and 4 fire on
few days and their arms are nearly free. The one interaction that needs a combined arm
is 1 × 2 — capacity halves while flow *information* changes.

## Phase 3 — The honest baseline

All fixes ON, **calibration untouched**. Score it on the full standing methodology.
Pre-register that number as what re-calibration must beat.

cv24's headline is not the target. Asking a re-calibration to recover a lost
information advantage and phantom transmission capacity through parameter choices is
the definition of fitting. Publish the decomposition — Δ from ex-ante honesty, Δ from
ATC physics, Δ from re-calibration — not a single cv24→cv25 delta.

## Phase 4 — Re-calibration, constrained

Scope: only zones on a pre-registered affected-border list, derived mechanically from
per-border Δcapacity and Δnet-transfer. The measured damage localizes to IT-*, SI, HU,
AT, CH.

Rules, in order:

1. **Recompute before retune.** Several mechanisms are formulas over quantities the
   ATC fix changes — the backstop quantity is demonstrated headroom *minus offered
   endogenous ATC*; boundary-book capability is ATC-capped. Rerun the derivations,
   touch no knob, measure. Only what fails after that earns a change.
2. **Deletion before addition.** `import_backstop` and `scarcity_import_credit` were
   introduced to fix phantom-scarcity caps diagnosed under the doubled-ATC solver. The
   first question per mechanism is whether it is still needed at all — answered by a
   switch-off arm.
3. **Pre-registration without the residual.** State the zone, the lever, the physical
   or institutional hypothesis, the expected direction and the falsifier — before the
   run, and without reference to the residual's sign. A treatment whose only
   justification is the residual it removes is rejected by rule.

   **This rule cannot be mechanically enforced and the plan says so plainly.** The
   same analyst has seen every residual map; "without reference to the residual" is
   good faith, not a check. What *is* enforceable: commit the pre-registration file to
   git before the run (the commit timestamp is the evidence), require a stated
   falsifier, and derive the affected-border list from **Δcapacity alone** — a physics
   quantity — with its threshold written down before any screening result is re-read.
   Naming the damaged zones from a residual map, as an earlier draft of this plan did,
   is exactly the failure this rule exists to prevent.
4. **Held-out windows.** Calibrate on set A, accept only what holds on disjoint blind
   set B, drawn by a published calendar rule. The scoring harness refuses days outside
   the committed pre-registration, and scoring runs append to a log in the results DB
   so a re-score after a failure is visible.
5. **Publish two audit numbers.** The distinct-parameter-vector count (17 today) and
   the number of zones whose treatment changed, each with its one-line justification.
   A calibration that shrinks is evidence of physics; one that grows is evidence of
   fitting, and the writeup says so. **Mechanical:** a CI test prints the distinct
   count, so no writeup can misstate it.

Enforceability, stated honestly: rule 1 is checkable (an empty `git diff` on
`zone_profiles.jl` for the recompute arm, required as an artifact); rule 2 is a
required artifact (per-mechanism off-arm scores for every affected zone, in the PR
before any new lever is reviewable); rule 3 is good faith with a timestamp; rules 4
and 5 are mechanical.

## Phase 5 — Ship

1. **Full-record offline screening backfill** (~1,300 days, DuckDB extract, HiGHS).
   The canonicalisation makes the clear ~4× faster — but 144 s/day × 1,300 days is
   ~52 h single-process, so "overnight" requires the pipeline with several HiGHS
   solver workers. HiGHS has no session cap, so state the worker count rather than
   implying the run is free. Score with the regime table, per-year
   energy-weighted correlation shares, Nordic cap-hour counts, coverage checks, and
   the truncated-day denominator handled identically in both arms.
2. Only then the Postgres backfill, extract rebuild, book capture, record refresh.
3. **Ship gate:** cv25 beats the Phase-3 honest baseline, no pre-registered neighbour
   breach, no new cap hours, calibration no larger than it was.

   Each of those needs a definition committed *before* the run, or it is not a gate:
   which metric decides when MAE and correlation move in opposite directions (they did
   in the ATC A/B); what the neighbour envelope actually is, numerically; and what
   Phase 0.3 decides about the truncated-day denominator, applied identically to both
   arms.

4. **Community gates**, which are the only test of invariants 3 and 4:
   - the test suite is green (`main` today: 14 failures + 12 errors);
   - the documentation describes the model that exists — `CLAUDE.md`,
     `docs/ex-ante-flows.md`, the scenario exercises and the accuracy history all
     still describe deleted subsystems and `:d0`-era byte-identity chains, and the
     ledger is a multi-thousand-word accretion that should become a short model
     description plus a CHANGELOG;
   - the headline metric's definition is findable and rerunnable by a newcomer;
   - **a fresh-clone reproduction by someone who did not write the code**, using
     HiGHS (invariant 5);
   - **the zone-strategy table published at `energy.philokalia.ai/about`** —
     **generated from the running code**, never hand-maintained: a
     `bin/export_zone_strategies.jl` resolves `get_zone_profile` for the footprint,
     diffs each zone against the base, and emits the table with the same data plane
     as the rest of the site. A hand-written copy would drift from the model within
     one iteration; a generated one is a standing check that the calibration is still
     small enough to fit in a table.

**Rollback** is cheap and should be stated plainly: `code_version` is row provenance,
cv24 rows are never rewritten, the dashboard selects by cv, the product pins a
constant. Rollback = do not flip the default. The flow-transfer worry is closed:
`transfer_flows!` deletes on `(code_version, window)`, so a cv25 transfer cannot touch
cv24 flows — the real (documented) hazard is same-cv cross-mode.

## Consequences to handle, not discover

- **Standing conduct hypotheses** in the affected zones (Italian evening tail,
  Alpine/Balkan import premium) were derived on a footprint that was more
  interconnected than the real grid. Each needs a re-derivation-or-withdrawal verdict.
- **The live product** stamps the library's `code_version`. Merging cv25 code starts
  emitting cv25 rows from a not-yet-validated model. Settle merge-vs-activate ordering
  before the merge.
- **The post-`:d0` behaviour of the SEE products** must be stated, not discovered:
  does `generate_energy_prices` move to `:v3`, or do the single-zone and 5-zone
  products go away? `:v3`'s per-border machinery should work zone-aggregated, but that
  is an assumption until someone checks it.
- **The reproducibility recipe** is versioned: the published artifact reproduces cv24;
  after cv25 the docs must say which tag reproduces which record.

---

## Phase 0 results (2026-07-29)

**0.2 Restatement — done.** README correction box + ledger correction, pointing at the
audit and this plan. The live forecast is explicitly exempted: it resolves `:v3`.

**0.3 Truncated days — the plan's premise was RIGHT: the source data is missing.**

An earlier version of this section claimed the opposite. It was produced by a query
that counted zones and hours **aggregated across the whole footprint** — 39 zones
present *somewhere* in the day, 24 hours present *somewhere* — which cannot detect a
zone with one hour. The correct per-zone query is one line different and falsifies it:

```sql
SELECT area_map_code, count(DISTINCT date_trunc('hour', date_time_utc)) nh
FROM entsoe.day_ahead_total_load_forecast
WHERE date_time_utc >= $d AND date_time_utc < $d + 1
  AND area_type_code IN ('BZN','BZN/CTA','BZN/CTY','BZN/CTA/CTY')
GROUP BY 1 HAVING nh < 24;
```

On 2025-11-12 that returns exactly one row: **SI, 1 hour**.

**Census over the record window** (2023-01-01..2026-07-24), zone-days with fewer than
24 D-1 forecast hours: **SI 48, BE 8, BG 4, SE1/SE2/SE3/SE4/DE_LU/RS/EE/GR 2 each,
LT 1 — spanning exactly 65 distinct days**, matching the 65 truncated days in the
record one for one. SI's gaps come in adjacent pairs (23h+2h, 22h+2h, 22h+1h): one
missing **CET-day** forecast block straddling two UTC days.

**Mechanism, and no NULL is involved.** A zone's book takes its timeslots directly
from the load forecast — `target_timeslots = sort(collect(keys(load_by_time)))`
(`book_build.jl:265, 285`). One forecast hour ⇒ a one-slot book ⇒ `reduce(intersect,
…)` (`multi_zone_books.jl:591`) collapses all 39 zones to that hour. The
`MethodError: Cannot convert Missing to Float64` seen in a standalone build is a
downstream symptom, not the cause; "fix the NULL handling" would have aimed at the
wrong thing.

**Policy consequence.** The fork is *repair the source* (re-fetch the missing ENTSO-E
blocks — the adjacent-pair pattern suggests an ETL boundary bug worth reporting
upstream) or *record explicit holes*. What is NOT available: falling back to
`actual_total_load` to fill a missing D-1 forecast — that is realized data and would
violate invariant 1.

**0.4 Cold start — real, but not the number or the mechanism first stated.**
The analogue pool is selected from `entsoe.actual_total_load`
(`flows_imports.jl:235`), which reaches back to **2021-10-27**, so 2023-01-01 has a
full ~364-day candidate pool — not the 31 days first claimed (that was the start of
`physical_flows` / the D-1 forecast, 2022-12-01).

The real defect is quieter: the analogue *days* can be selected from before flow data
exists, and `_zone_border_hourly_analogue` then medians each border over only those
analogue days that actually have flows — possibly one, possibly none — with **no
minimum-sample guard and no logging**, plus a discontinuous flip to D-2/`:v2` when
fewer than `k` candidates exist. The `:v2` climatology degrades the same silent way.
And `get_import_backstop` imputes **0.0** for missing lagged weeks before taking a
max, so on a structural net exporter missing history *manufactures* phantom import
headroom.

Nor is `:v3` the only mechanism with an uninstrumented cold start: the UA
firm/capability windows (366d/28d), Viking capability, fleet-truth p95 and FR's
trailing-30d nuclear share all have their own. Phase 5 needs a warm-up policy and
sample-count instrumentation, not just a start date.

**0.6 Lookahead sweep — clean beyond the two known sites.** The only day-inclusive
upper bounds in `src/` are `registry.jl:182` and `:266` (both already scheduled for
Phase 2). Two non-sargable `DATE(date_time_utc) = $x` filters exist
(`results_store.jl:520`, `batch_runners.jl:519`) — a performance issue, not a lookahead.

**0.1 Which flow mode measured which calibration decision — the surface is small.**
The scoped resolution landed in `cb47b67` ("`:v2` is the default for the EU-footprint
path, cv16 onward"). Every calibration A/B harness that decided a shipped treatment
calls `run_multi_zone_market_clearing`, i.e. the sequential path that *does* resolve
it:

| decision | harness | path |
|---|---|---|
| cv17 weak-zone import backstops | `test/scripts/weak_zone_prototypes.jl` | sequential (mode set explicitly) |
| cv17 benchmark | `test/scripts/cv17_bench.jl` | sequential (scoped default) |
| cv19 `:v3` analogue flows | `docs/experiments/analogue-flows/ab_price_v3.jl` | sequential (mode set explicitly) |
| cv21 Viking | `cv21-dk1-viking/ab_confirm.jl`, `test/scripts/cv21_guards.jl` | sequential |
| cv22 UA + bug batch | `cv22/ab_cv22.jl`, `cv22_guard.jl`, `see_delta.jl` | sequential |
| cv23 FR nuclear + FR cap | `cv23/ab_cv23.jl`, `frcap_decomp.jl`, `frcap_verify.jl` | sequential |
| IT-NORTH / PL / NL diagnoses | `*/ab_*.jl` | sequential |

The only pipeline callers among the experiment scripts are a crash test
(`cv22/test_pipeline_crash.jl`) and a scenario runner that sets the mode explicitly.

**So the flow defect contaminated the RECORD, not the calibration decisions** — from
cv16 onward those were measured under `:v2`/`:v3`. This bounds Phase 4: no treatment
needs revisiting *on account of the flow defect*. Every treatment was still measured
under the doubled ATC, which is a separate and much larger claim on Phase 4's scope.
Pre-cv16 decisions (the v10 SEE baseline, fleet truthing) predate the scoped default
and were measured with `:d0` everywhere — they are base calibration, not import
mechanisms.

**0.5 Fix-4 frequency — NOT rare; the plan's assumption was wrong.**
Sampling every 14th day over 2023-01-01..2026-07-24 (92 days): **34 of them (37%)**
have at least one unit whose *only* output in the 60-day probe window falls on the
delivery day itself. That is an upper bound on the days the fix changes the fleet —
the probe only decides membership for units the registry's date-validity filter
rejects — but it is nowhere near the "fires on few days, its arm is nearly free"
the plan assumed. **Fix 4 needs a full ablation arm, not a token one.**
