# `simulations.*` schema and the `code_version` ledger

Moved out of the root `CLAUDE.md` (August 2026) so the version history is loaded on
demand instead of in every session. The current `code_version` is
`ENERGY_PRICES_CODE_VERSION` in `src/db/postgres_core.jl`; bump it for every model
iteration that gets a backfill and append its entry here.

**`simulations.energy_prices`** - Generated energy price results by bidding zone, date, and time period
- `clearing_mode`: Distinguishes between `'single_zone'` (independent zone clearing), `'multi_zone'` (joint clearing with transmission), and `'multi_zone_iterative'` (iterative UC-MPCC feedback loop)
- `optimization_run_id`: Foreign key to `optimization_runs` table for traceability
- `code_version`: Model version (**current: 45** for energy_prices, 4 for optimization_runs; the authoritative value is `ENERGY_PRICES_CODE_VERSION` in `src/db/postgres_core.jl`). energy_prices v3 = SRMC/TTF cost model (July 2026); v7 = multi-zone artifact fixes (tight MIP gap, component-wise price reconstruction, border-aware import exclusion, July 2026; 4–6 were taken by legacy uc_based experiment rows); v8 = daily EUA carbon prices from `yfinance.eua_co2` (July 2026); v9 = multi-zone nodal-balance flow signs fixed (flows were physically mirrored, capping each border by the opposite direction's ATC — July 2026); v10 = crisis-year honesty (fleet-truthing derate of baseload types to trailing p95, absolute must-run below-cost discount — July 2026; 2022 GR bias −141 → +1); v14 = the calibrated 39-zone EU-footprint model, i.e. v0.2.0 (network enrichment incl. explicit ATC + aggregate remap + flow-based border drops, ZoneProfiles, two-pass opportunity anchors — July 2026; 11–13 are reserved for the intermediate calibration iterations, whose 5-day records live under `clearing_mode='multi_zone_eu_cal*'` at cv10; the cv14 full-year `multi_zone_eu` backfill 2025-07..2026-07 is the v0.2.0 record); v15 = iterations 6–8 (July 2026): SK Core-FBMC border drop + :hydro anchor (SK winter MAE 956→~40), seasonal reservoir-drawdown water value (SE1/SE2), import-ATC scarcity credit, installed-capacity fleet truth (`fleet_truth_mode=:installed` on the continental core DE_LU/NL/PL/CZ and the Baltics — DE_LU corr 0.62→0.80), and MPCC robustness (exact indicator-form complementarity retry rung + per-day :p95-books fallback — no missing days). v7 and v8 multi_zone rows carried that bug and were deleted; v8 single_zone rows are flow-free (bit-identical to v9 output) and were relabeled to 9. The SEE single_zone/multi_zone product is byte-identical across v10/v14/v15 code — v14/v15 matter for the EU footprint (`multi_zone_eu`). Earlier rows keep their old version and are not mixed with new results. Each version is one selectable "Run" in the Metabase counterfactual dashboard — bump it for every model iteration that gets a backfill. **Ex-ante flow default (cv16 onward):** the EU-footprint multi-zone path (`enrich_network=true` + `:merit_order`) now defaults to the fully ex-ante `:v2` flow rule (flow climatology + D-7 Norwegian recency, `docs/ex-ante-flows.md`) instead of same-day observed flows — this applies to EU-footprint saves from **cv16** onward; the cv15 full-year backfill was produced with `:d0` same-day flows. SEE legacy paths (single-zone, 5-zone multi_zone with `enrich_network=false`) keep `:d0` and their byte-identity. Explicit `EUPHEMIA_FLOW_ASOF_MODE` or the `ex_ante_mode` kwarg always wins over the scoped default. **v17 = weak-zone import fixes** (July 2026, `docs/experiments/weak-zone-diagnosis` + `docs/experiments/cv17-import-fixes.md`): the cv16 EU footprint's low-correlation zones were a handful of phantom-scarcity cap days from import starvation. Shipped: (1) AT–CZ / AT–DE_LU / AT–SI Core-FBMC border drops + SI on the Slovakia treatment (continental temperament + `:hydro` anchor — `SLOVENIA_PROFILE`); (2) profile-gated **ex-ante elastic import backstop** (`ZoneProfile.import_backstop`, quantity = trailing-8-same-weekday demonstrated import headroom beyond the `:v2` climatology minus offered endogenous ATC, priced 1.8×gas SRMC; on for AT/BE/CH/DK1/DK2/SE3/IT-CNORTH/SI/RO/RS/HU; RO/RS/HU also credit the demonstrated headroom in the scarcity margin via `backstop_scarcity_credit`); (3) ref-priced retained-border exports (`ref_priced_exports`: SI–HR, BE–GB). A fourth mechanism — anchor refs over dropped borders (`anchor_include_dropped`, SE3, SE2-flow-weighted) — was built, measured against its gate and switched OFF (it pinned SE3 at SE2's level: corr 0.55→0.31). The SEE single-zone/5-zone products stay byte-identical (measured: full books + GR prices bit-identical cv16↔cv17 code). **v18 = RESERVED (shape levers, activation held back July 2026; the fields and their kill-switch were REMOVED in cv25's subtraction phase — a revival needs re-implementation, not a flag flip)**: `ZoneProfile.unit_srmc_spread` and `export_absorption_steps` are BUILT (default-inert, with the `EUPHEMIA_DISABLE_CV18` worker-safe kill-switch for lever A/Bs) but NOT activated: the 36-day attribution showed strong non-local coupled interactions (DK1 ladder: NO1 caps 15→0 but IT-CSOUTH corr 0.66→0.39, SE3 0.56→0.10, and DK1 itself regime-dependent; spread: continentally benign but NO1 caps 15→44; FI/FR full-year regressions) — 2-zone/20-day pilot gates are structurally insufficient for coupled mechanisms. The cv18 full-year record was measured, documented (PR #162) and deleted from Postgres; activation waits for the border-scoped redesign (export-backstop mirror) validated on the coupled footprint. cv stays 17 until then. **v19 = anad2 ex-ante flows (July 2026, docs/experiments/analogue-flows):** the EU-footprint scoped flow default moves :v2 → :v3 — per-border mean of the load-analogue median (16 trailing-365 days nearest to the delivery day's D-1 load-forecast vector, the ex-ante thermometer) and the D-2 observed flow (fastest admissible signal — catches a new regime in 48 h). Measured on the 39-day coupled A/B: MAE better/flat in all four windows, GR July-flip evening bias +57→+43, corr 0.85→0.87, footprint net-import MAE −15%. A 3-year analogue pool and pure-D-2 were measured and rejected. SEE legacy paths keep :d0 byte-identity. **v20 = solver-invariant canonical mode (July 2026, `docs/period-decomposition.md`):** the per-period-DECOMPOSED clear becomes the canonical mode on the EU-footprint path for every solver, and the `auto` solver default flips to HiGHS (open-source; the Gurobi license is academic — Gurobi stays the development option via `optimizer="gurobi"`). Decomposed is bit-identical across Gurobi/HiGHS; it differs from the legacy monolithic clear only on degenerate pass-2 anchor ties (10/29,679 hourly cells over the 39-day mode A/B, aggregate scores identical to 2 decimals in all four windows). The pipelined backfill applies the same policy. SEE legacy paths (single-zone, 5-zone multi_zone) stay monolithic and keep their byte-identity. **v21 = DK1/Viking virtual boundary book (July 2026, `docs/experiments/cv21-dk1-viking.md`, item 2 of the virtual-boundary-zone program):** the out-of-footprint GB counterparty on the DK1–GB Viking Link is modeled as an ELASTIC neighbor — import-supply + export-demand ladders anchored on GB's OWN CCGT SRMC (TTF/0.52 + EUA-proxied UK carbon/0.52 + O&M) laddered over the border's demonstrated interconnector capability (a runtime Day-ahead-ATC-capped-at-demonstrated-max query with a trailing-365d p95-block floor on ATC gaps — the wave-2 `capability.json` recipe, generalized to every day) — replacing GB's fixed flow injection AND its import-backstop headroom. First-class and profile-gated: `BoundaryBook`/`VIKING_GB_BOOK` on `DK1_PROFILE` (only DK1; DK2 unchanged), default-inert everywhere else, `EUPHEMIA_DISABLE_CV21` kill-switch. Byte-identity guards (GR single-zone, SEE 5-zone, 39-zone EU with the book disabled) all bit-identical vs cv20. Src-implementation confirm A/B (HiGHS, offline extract): March (stable guard, 8/8 days) DK1 MAE 27.9→24.6 / corr 0.55→0.81 — matches the measured reference (27.6→25.2 / 0.55→0.80); July (10/16 days — the extract lacks Day-ahead ATC for 2026-07-16..21, which fail the enriched-network build for both arms) DK1 MAE 29.5→26.6 / corr 0.88→0.90; no FR/NL/NO2 leakage. GB the zone stays PARKED (no broader GB behavioural book until an Elexon/BMRS + UKA feed); UA (boundary item 1) is a separate decision. SEE single-zone / 5-zone products stay byte-identical (guarded); cv21 matters for the EU footprint (`multi_zone_eu`). No backfill shipped with the code change. The remaining SEE evening residual is form/conduct territory (docs/experiments/fit-scarcity: hyperbolic scarcity candidate + BG conduct signature). **v22 = UA firm-slice boundary book + four confirmed price bug-fixes (July 2026, `docs/experiments/cv22.md`): **The cv22 full record (2023-01-01..2026-07-24, 1,301 days, backfilled 2026-07-26) is the canonical published record: comparable full-year corr 0.67 / MAE 27.4 (cv19: 0.64/27.2 — the largest single-version corr step), full 2023+ 0.62/28.1; per-year energy-weighted corr>=0.75 share 50/58/66% for 2023/24/25, GR 0.72->0.87.**** (A) **ua2** (roadmap item 1) ported to src as a first-class, profile-gated `BoundaryBook` like cv21 Viking — UA is a **war-constrained scarcity buyer** on the HU/SK/RO/PL–UA borders: import supply anchored `0.55 × zone gas SRMC` (no UA fundamentals feed — the documented generic-anchor compromise), export demand = a **FIRM cap-priced base slice** (its demonstrated persistent import need, which does not curtail on price — the mechanism that killed the wave-2 HU March breach) plus an elastic tail. `UA_BOOK_DEFAULT`/`UA_BOOK_PL` (PL adds the UA_DobTPP radial); capability = trailing-366d p95 gross flow per 4h block (`:p95_block`), firm = trailing-28d p10 of the daily block-mean export flow — both computed at RUNTIME (no committed JSON; they reproduce the experiment's `firm_ua.json`/`capability_w2.json` exactly on the confirm days, so the book generalizes to every backfill day). Reference confirm (24-day A/B): HU July MAE 72.3→57.1 / corr 0.69→0.79, March breach dead (28.24→28.29); accepted residuals HU March evening 29.2→33.0, RO/BG March ~+1. (B) `flows_imports` `:v2` border map — a Nordic-side border missing its D-7 observation was DELETED (silently zeroed) instead of falling back to climatology; fixed to fall back. (C) `Network.jl` legacy ATC build — took the LAST duplicate capacity row per border-hour (order-dependent); fixed to hourly AVG matching the enriched path — **this deliberately ENDS the SEE 5-zone byte-identity chain (unbroken since cv10)**; measured SEE delta small and within gate (single-zone unaffected). (D) `get_reservoir_drawdown` window `year>$2-2` widened 52→52-104 weeks; fixed to `$2-1` (Nordic only). (E) `get_reservoir_dryness` ±2-ISO-week neighbourhood didn't wrap the year boundary; fixed with a mod-52 wrapped set (only differs Dec/Jan). All five gated behind `EUPHEMIA_DISABLE_CV22` (byte-identity guard: GR single-zone / SEE 5-zone / 39-zone EU bit-identical to cv21 main with the switch set — Viking stays ON via its own CV21 switch), ON by default. NOT shipped (measured NO-SHIP, deferred to cv23): the GB pair (FR-nuclear root cause; the FR–GB double-count stays known-compensated so it does not ship alone) and iter9/43-zones. Plus #182 runner hardening: the pipelined backfill coordinator now resubmits a solver/book worker's orphaned day (retry-once) and respawns the worker on a HiGHS SIGSEGV, so a segfault no longer deadlocks the run; sequential runners rely on the resume flag. cv22 matters for the EU footprint (`multi_zone_eu`). **v23 = FR nuclear opportunity cost + FR–GB re-pair + interior-Norway backstop (July 2026, `docs/experiments/cv23-fr-nuclear.md`, `docs/experiments/norwegian-hydro/`):** (1) availability-scaled `:nuclear` anchor share for FR (trailing-30d fleet p95/installed — ex-ante, no-fit; March confirm FR MAE 38.2→16.2, evening bias −77%); (2) the FR↔GB border re-paired — double-count fix shipping WITH an elastic GB CCGT boundary book (TTF/0.52 + UKA carbon; the cv22 no-ship prescription); (3) interior-Norway import backstop NO1/NO3 + FR cap fix (`import_backstop` + scarcity credit + `nuclear_bid_ref_ceiling`) — kills the dry-spring phantom-scarcity caps (NO1 MAE 62.7→25.8, bias +36.9→−0.1 on the record). Kill-switches `EUPHEMIA_DISABLE_CV23`/`EUPHEMIA_DISABLE_FRCAP`. The cv23 full record (2023-01-01..2026-07-26, 1,303 days) superseded cv22 as canonical: comparable year corr 0.68 / MAE 26.4, full 2023+ 0.63/26.5, FR 0.78, GR 0.85. **CORRECTION (July 2026, docs/experiments/exante-audit-2026-07.md): every pipelined record — cv16, cv17, cv19, cv22, cv23, cv24 — is NOT ex-ante with respect to cross-border flows.** `run_pipelined_backfill`'s book workers call `mz_build_books`, which has no `ex_ante_mode`, so they used the process-wide `:d0` — same-day OBSERVED flows — not the `:v2`/`:v3` scoped default this ledger documents from cv16 onward. Verified by re-clearing record days both ways against the stored prices (`:d0` 93.8–100% bit-identical, `:v3` ~47%). The choice of `:v3` (the cv19 analogue-flows A/B) is not in question — it never reached the record. The live forecast path is unaffected (it resolves `:v3`). Also: 65 of 1,304 cv24 days (5.0% of days, 2.52% of zone-hours) hold fewer than 24 UTC hours because those days are MISSING D-1 load-forecast hours at source for one zone (SI on 48 of them, BE 8, BG 4) and a zone's book takes its timeslots from the load forecast, so a one-hour zone collapses the coupled intersection for all 39. cv25 corrects both (docs/cv25-plan.md). **v24 = registry sanity bound (July 2026, #205): record-consistency bump.** `MAX_PLAUSIBLE_UNIT_MW = 25 GW` drops corrupt ENTSO-E capacity rows (IT-CSOUTH unit `26WUUUUUUBUSSI19` carried 13,068,005 MW → NaN correlation there via the fleet-truthing denominators). No other mechanism content (the IT must-run floor was measured NO-SHIP twice — `docs/experiments/cv24-it-book.md`); prices change only where a corrupt unit was in the fleet (IT-CSOUTH), every other zone byte-identical to cv23 code. Bumped so post-#205 daily forecasts and the refilled record never mix with cv23 rows. **v25 = the cv25 program (July 2026, #228): canonical ATC physics (single flow variable per border), scoped :v3 ex-ante flows in the PIPELINE entries (closing the not-ex-ante record defect), ISO-year + delivery-day fleet-probe fixes, Phase-4 recalibration (T1 BG/GR demonstrated-headroom backstop + T3 IT-NORTH with the aggregate-in-code sizing fix; T2 structural no-op), per-treatment switches EUPHEMIA_DISABLE_CV25_RECAL/_T1/_T3. Ratified ablation record docs/experiments/cv25-phase2-ablation.md + cv25-phase4-recal.md; the 1,238-day cv25 backfill (2026-07-30) was the first truly ex-ante record (hyperbolic-scarcity cv26 candidate measured NO-SHIP the same day — docs/experiments/cv26-scarcity-noship.md; that experimental label never shipped).** **v26 = ATC Day-ahead preference (July 2026, #233):** the implicit offered-capacity table mixes Intraday rows (often 0 MW) into Day-ahead border-hours — contamination grows 34→138→134 borders across 2023→2025 — and since the Nordic FBMC go-live (late 2024) most Nordic/Core borders carry NO Day-ahead rows at all, so 2025 ran on intraday leftovers (NO3→NO1 "23 MW"; EE Aug-Sep 2025: 122 phantom-cap hours). Per border-hour: AVG FILTER (contract_type='Day-ahead') when DA rows exist, else the previous all-rows AVG (FBMC borders unchanged pending their capacity-source redesign — the next prereg's first question). Applied at all four implicit-ATC consumers + the daily-forecast ATC readiness gate counts DA rows; kill-switch EUPHEMIA_DISABLE_ATC_DAPREF (forwarded to pipeline workers). Measured: EE 2025-08-22 20 cap hours → 0 (max 147.5 vs settled 467); NO1 2025-06-15 caps → 0. CHANGES SEE legacy prices too (38,664 mixed border-hours) — deliberate, ledgered like cv22-C. Mid-day source flips exist on 0.23% of border-days (partial-day DA coverage) — accepted; a day-level preference would drop those borders entirely on non-DA hours. **v27 = the bordered demonstrated-capability program (July 2026, docs/experiments/cv27-borders/, ship decision 2026-07-31):** Day-ahead-free (FBMC) border-hours on SEVEN accepted physical borders — DE_LU~FR, CH~FR, CZ~PL, SE1~SE2, IT-CNORTH~IT-NORTH, DK1~SE3, IT-Calabria~IT-Sicily (both directions each, `CV27_SHIPPED_BORDERS` default; `EUPHEMIA_CV27_T1_BORDERS` overrides for A/Bs, present-and-empty = off) — size by demonstrated capability: trailing-366d p95 gross observed flow per 4h block (`_fbmc_capability`, day-cached), replacing the intraday-blend fallback. Accepted per border by a frozen screening protocol (both directions tied — the measured DK2 asymmetry lesson); 5 rejected, isolating the DE_LU pathology (every DE_LU import border except FR degrades DE_LU). Measured: Set A 31.58/0.692 → 31.14/0.701 (−0.44/+0.009), held-out Set B 28.58/0.454 → 28.17/0.450 (−0.41/−0.004, corr at the gate margin), ZERO new cap hours and ZERO envelope breaches in every arm; the four capacity-REDUCING directions manufactured no scarcity. Self-gating: fires only where no Day-ahead rows exist (2024-07 days fire 192/336 border-hours — correct ex-ante behaviour), so live-vs-extract DA-coverage differences degrade to no-op, never to lookahead (live parity measured Jun 2026+: DE_LU~FR/CZ~PL/SE1~SE2/DK1~SE3 fire fully, IT internals ~71% of hours, CH~FR has no recent implicit rows). The cv27-prereg T2 (spill valley) and T3 (deep-surplus floor) did NOT ship (EUPHEMIA_ENABLE_CV27_T2/_T3 opt-ins only; the floor family measured NO-SHIP in cv28/cv29 — docs/experiments/cv28-results.md, cv29-results.md; demand elasticity likewise NO-SHIP, feat/demand-elasticity inert). Ship guard: the default is bit-identical to the campaign's measured combo arm. **v31 = solar-regime price-taker floor ACTIVATED (August 2026, #251 → cv31 ship, docs/experiments/solar-regime):** the regime-gated floor merged default-INERT in #251 becomes the DEFAULT for the record path. Ex-ante gate = day-ahead SOLAR share of forecast load ≥ θ=0.4, on the CONTINENTAL_SOLAR group DE_LU/FR/PL/BE/CZ/CH; in regime hours the RES block + run-of-river + the deepest must-run block price at `DEEP_SURPLUS_FLOOR_EUR` (−20) so the coupled clear can genuinely fall below zero (BLOCKS=full). Phase-1 cartography identified the group as systematically OVERPRICING deep-solar hours by +15..+18 €/MWh where the settled market crashes to ≤0. **Measured within-regime (BLOCKS=full, θ=0.4):** Set A dMAE **−1.50** (base 43.83 → treat 42.33, n=350; bias +36.20 → +34.70), Set B dMAE **−0.27** (base 34.14 → 33.87, n=288); **phantom rate 0.0** (the ex-ante solar gate eliminates the phantom lows that killed cv28/cv29), outside-regime |ΔMAE| ≤ 0.017, **ZERO new caps**, no zone harmed — clears every acceptance gate on BOTH sets. Modest by design: the coupled marginal block often stays a thermal/must-run tranche above the floor, and where it bites it bottoms at −20 while settled reaches −100..−300; the large residual is a commitment/quantity issue (natural follow-ups: demand-scaled deeper floor, must-run/surplus fix, the NORDIC reservoir-wetness regime). Default-ON; kill-switch `EUPHEMIA_DISABLE_CV31` set ⇒ fully inert, byte-identical to cv27 main (guarded: GR single-zone 1032-row + 39-zone EU harness, max |Δ|=0). Explicit `EUPHEMIA_SOLAR_REGIME*` env still wins over the scoped default (θ/BLOCKS/ZONES A/Bs; `EUPHEMIA_SOLAR_REGIME=0` forces off) — the FLOW_ASOF precedent. The new default is bit-identical to the measured accepted arm (guarded on high-solar sweep days). None of the six floor zones is in the SEE single-zone/5-zone products, so those stay byte-identical; cv31 matters for the EU footprint (`multi_zone_eu`). **v32 = winner-input corrections, Sicily+Sardinia scope (August 2026, docs/experiments/recal/cv32-results-2026-08.md): the record path's RES input for IT-Sicily/IT-Sardinia comes from `simulations.input_corrections` (actuals-target LightGBM solar, D-1-legal, profile-scoped to the EU path, kill-switch EUPHEMIA_DISABLE_CV32). Owner-ratified adoption; the full 5-zone set was measured and REJECTED at year scale (GR +2.03/DK1 +2.68 — co-adaptation; their correction series stay in the table awaiting joint mechanism packages). Validation: cv32b_fy year vs fresh baseline — Sicily −0.20/corr +0.009, footprint −0.06, zero new caps, SEE byte-identity untouched. The daily emitter (#319) keeps the table current: bin/emit_input_corrections.jl scores the winners each morning (lead-1 + 3-day catch-up sweep; ON CONFLICT DO NOTHING vintage discipline) from bin/daily_forecast.jl. PL solar joined the winner queue (#321) awaiting its mechanism package.** **v33 = the 2026-08-24 bug sweep (docs/experiments/bug-sweep-2026-08-24.md): no new mechanism — input-side and record-integrity fixes.** Outage versioning (superseded/cancelled ENTSO-E outage versions no longer applied; ≥12 h day-overlap instead of a midnight instant; matched on asset_code; override probe from the binding record; partial derate ≤ installed), registry validity ordering (the row valid on the day wins — the IT-CSOUTH corrupt-row root cause), oil-shale/peat/other-renewable SRMC entries, RES-forecast NULLs (ex-ante persistence, never thrown/zeroed — RS was being DROPPED from SEE clears, ES 2026-06-11 cleared with no RES) and mixed 15/60-min RES rows (one resolution per type — FR 2026-01-08 was quartered/doubled), component-scoped price-reconstruction fallback with a 0.5 MW acceptance tolerance, pass-2 `ex_ante_mode` kwarg forwarded, sequential truncation gate, `optimization_runs`/`transmission_flows` keyed by the price cv + `clearing_mode` (migration adds the column; legacy rows = 'multi_zone'), transfer window bounded to the source slice, forecast-path gate/coverage/score/vintage fixes. The cv34 prereg draft had left 33 unused; the sweep takes it. **v34 = the ex-ante conventions (August 2026, docs/experiments/cv34-exante-conventions.md; owner decisions 2026-08-25):** outage versions as known at the D-1 gate (latest version published before D-1 10:00 UTC) for delivery days ≥ 2025-10-01 — the documented seam where the ENTSO-E publication timestamp becomes a real TSO time; fuel/carbon closes strictly before D-1 (D-2's close is the last that exists at the gate, ~2.3 €/MWh_el on the gas SRMC); the backstop-vs-MPCC border-capacity sync was measured NO-SHIP (neutral/negative, one lost day) and stays opt-in (`EUPHEMIA_ENABLE_BACKSTOP_ATC_SYNC`); the `entsoe` track's weekly-persistence leads 2–7 relabelled `input_mode='entsoe_persist'` (247k live rows relabelled); `forecast_scores` keyed by `is_retro` (live/retro never pooled); `energy_prices` UNIQUE re-keyed without the always-NULL `optimizer` column (0 duplicates, 23.6 s live). The continental-collapse package moves to cv35. **v35 = flow-based capacity data (August 2026, docs/experiments/jao-maxbex-atc.md, ceres PRs #524/#525):** every Core-FBMC and Nordic zone had ZERO Day-ahead offered-ATC rows for a year (flow-based borders leave only intraday leftovers in the ENTSO-E table). JAO's max bilateral exchanges (`jao.max_exchanges`) become the ATC for every Day-ahead-free border-hour and un-drop the Core borders they cover; each hub's simultaneous bilateral maxima are scaled to its JAO min/max net position (`jao.hub_net_positions`; the exact MPCC constraint is parked opt-in pending its price-condition dual); transmission-grid outage messages cap border-hours at the TSO's remaining NTC. 52-Wednesday A/B on live Postgres vs cv34: footprint MAE 26.24 → 23.40, corr 0.680 → 0.761, Core cluster 35.1 → 23.1, Nordic hydro 29.2 → 23.1, SEE 26.4 → 25.2; worse DE_LU +2.4, DK1 +2.5, BE +2.0; collapse hit rate 43 % → 14 % (FA 1019 → 174) — the open cost. HiGHS segfaults on the 108-link network: backfill on Gurobi. Versions 28/29/30 are consumed by documented NO-SHIP labels (cv28/cv29 floor family, cv30 — docs/experiments/cv{28,29,30}-results.md).
- Unique on `(date_time_utc, bidding_zone, contract_type, order_method, clearing_mode, code_version)` - allows storing results from different clearing modes side by side

**`simulations.optimization_runs`** - Optimization run metadata including status, solver info, and performance metrics
- For single-zone runs: `bidding_zone` contains the zone code (e.g., "GR")
- For multi-zone runs: `bidding_zone` is set to "MULTI_ZONE"
- For iterative runs: `bidding_zone` is set to "MULTI_ZONE_ITERATIVE"
- Contains `optimizer`, `solve_time_seconds`, `objective_value`, etc.
- Unique on `(bidding_zone, optimization_date, order_method, model_type, code_version, optimizer)` - allows comparing different solvers
- **Iterative optimization metadata** (for UC-MPCC iterative runs):
  - `is_iterative`: Boolean flag indicating iterative optimization
  - `total_time_seconds`: Total time for all iterations including UC solves
  - `iterations`: Number of iterations performed
  - `converged`: Whether the algorithm achieved convergence
  - `final_price_change`: Final max price change in €/MWh at termination
  - `final_flow_change_pct`: Final flow change percentage at termination

**`simulations.transmission_flows`** - Cross-border transmission flow results from multi-zone clearing

> The `simulations.uc_*` and `generator_inferred_parameters` tables still exist
> with their data, but nothing writes them since cv25 deleted the UC path.

**Joining prices with optimization metadata:**
```sql
SELECT ep.*, opr.optimizer, opr.solve_time_seconds
FROM simulations.energy_prices ep
JOIN simulations.optimization_runs opr ON ep.optimization_run_id = opr.id
```

## v36 — graded upper-tranche ladder; IT-North peak recalibrated (2026-08-27)

`ZoneProfile.tranche_grading` (default 1 = bit-identical staircase): K>1 makes
the upper supply curve piecewise-linear. Promoted on IT-NORTH/IT-CNORTH
(`ITALY_NORTH_PROFILE`: grading 4, peak_kappa 1.2→1.0, thermal 1.2→1.15) after
a Set-A bracket + one held-out Set-B pass — all 7 IT zones' corr improve OOS
(IT-N 0.69→0.71 … Calabria 0.76→0.81), CH/PT improve, footprint −0.16; known
trade: IT bias ~−12 (missing middle = pumped-storage opportunity bids, the
noted follow-up). Experiment: docs/experiments/cv36-graded-tranche/.

## v37 — wetness-adjusted seasonal drawdown (2026-08-27)

`ZoneProfile.wet_adjusted_drawdown` (default false): wet years (signed reservoir
dryness < 0) damp the winter water-value lift in the `:reservoir_opportunity`
form. On NORDIC/NO4 profiles (SE1/SE2/FI/DK1/DK2/NO4). Wet-winter 2024-25:
SE2 −8.0 MAE (corr 0.61→0.69) Wednesdays, −9.3 (0.40→0.63) on the held-out
Sundays; SE1 −6.5/−7.8; spillover beneficial (SE3 −4.0 corr 0.73→0.80, NO3
−3.4); mild winter Set A/B ≈ neutral-positive. Experiment:
docs/experiments/cv37-nordic-wet/.

Verified cv37 record (2y backfill 2026-08-28): footprint corr 0.740, MAE 25.22; energy@corr>=0.7 = 90.0%, >=0.8 = 56.0% (was 44.3% at cv36). SE1 .745 / SE2 .740.

**v38 = deterministic outage readers (September 2026, #370 / PR #373,
docs/experiments/outage-intervals-370/):** ENTSO-E outage messages are stored
one row per time-series interval sharing `(instance_code, version)`; the cv33/34
readers ranked those rows with `ROW_NUMBER() … ORDER BY version DESC` and kept
an arbitrary one, so unit capacities and transmission caps changed from run to
run (1,445 of 9,634 message-versions overlapping 2026-08-20 disagree on
capacity; two runs of unchanged cv37 code gave different DE_LU books — the
cv35–37 non-reproducibility note above has this as its simplest cause). Both
readers now keep every interval of the latest version: hourly availability =
MIN over covering intervals, the day-level capacity = the 12th-smallest hourly
value (the same ≥ 12 h majority rule, applied on hours); `tx_outage_caps` caps
each hour by its covering intervals. Kill-switch
`EUPHEMIA_DISABLE_OUTAGE_INTERVALS`. Measured on 52 Wednesdays 2025-09-03..
2026-08-26 (Gurobi, live Postgres, paired zone-hours, 47,300 cells): footprint
MAE 27.02 → 26.73, energy-weighted 26.38 → 26.02, bias −9.47 → −9.07, corr
0.761 → 0.767; 32 of 38 zones improve (PT −2.1, DK2 −0.8, NO2 −0.6, SI/FR/AT/HU
−0.5..−0.6), worst SE4 +0.65; 23 % of cells move, mean |Δ| 5.4. Noise floor of
the defect it removes: the cv37 record vs a fresh legacy re-run of the same code
differs on 38.6 % of cells, mean |Δ| 8.4 (footprint MAE 27.48 vs 27.03). Three-
zone book fingerprints are bit-identical across processes on the fix. Also the
#369 as-of contract (ForecastContext, legacy path unchanged) lands in this
version. No record backfill yet — the daily forecast writes cv38 from merge.

**Verified cv38 record (backfill 2026-09-08/09, live Postgres, Gurobi 4 solver
workers, 15.4 h for 798 days at 56 days/h; 795 days saved 2024-07-01..2026-09-06,
23 days with one or two zones missing at source — SI/BE/GR load gaps, the same
gaps cv37 has; `docs/experiments/outage-intervals-370/output/cv38_record_*`,
scorer `scripts/eval_cv.py`).** Two-year ladder 2024-07-01..2026-06-30, 729
paired days, 38 zones, 664,076 paired zone-hours vs settled: pooled corr
0.772 → **0.775**, MAE 25.24 → **25.08**, energy-weighted MAE 23.43 → 23.48,
bias −3.99 → −2.48; energy@corr≥0.8 46.2 % → **48.8 %** (IT-SOUTH 0.802,
IT-CSOUTH 0.815 cross), ≥0.75 83.4 → 83.3 %, ≥0.7 90.2 → 88.6 % (HU 0.706 →
0.695 drops below). 22 zones better / 16 worse: DK2 −2.5 (bias −13.3 → −6.1),
IT-SOUTH −1.8, IT-Calabria −1.5, IT-Sicily −1.4, IT-NORTH/CNORTH −0.9, LT/LV/EE
−0.4..−0.5; worse SE4 +1.2, BE +1.1 (bias +7.8 → +10.1), DE_LU +0.9 (+0.3 →
+2.7), NL +0.7, DK1 +0.6, NO2 +0.6. By year: 2024 H2 28.76 → 29.05, 2025
22.96 → 22.75, 2026 H1 26.27 → 25.78; evening 16–19 UTC 36.15 → 35.60, bias
−15.2 → −14.3. Full window to 2026-09-06 (786 paired days): corr 0.775 → 0.778,
MAE 26.13 → 25.92, ew 24.26 → 24.25, energy@corr≥0.8 60.3 → 62.8 %. Read it
with the caveat that a record-vs-record comparison carries the cv37 draw's
own randomness (38.8 % of cells differ, mean |Δ| 7.5 — the same magnitude as
cv37 re-run against itself) and two weeks of source refills; the paired
52-Wednesday A/B in the v38 entry above is the clean measurement of the fix.
cv38 is the first record that reproduces itself bit-for-bit across runs.

**cv38 CORRECTION (2026-09-09, external review):** the cv38 record above and
the three A/Bs behind it (#370, #366, #367) were run on a **38-zone footprint
without CH** — the zone list was copied from `bin/eu_footprint_experiment.jl`
instead of the record driver (`bin/reproduce.jl`, 39 zones). The cv37 record
has CH. cv38 therefore cleared a different market (CH's neighbours DE_LU, FR,
AT, IT-NORTH lost an endogenous counterparty) and its ladder is not comparable
to cv37; the 38-zone A/B deltas are internally paired but do not cover the
requested footprint. The cv38 rows stay labelled as this defective record
until the owner decides to delete them. Also from the review, fixed in cv39:
the per-unit generation probes (stale-outage override, registry activity
probe) ended at delivery midnight regardless of the issuance context; the
outage audit reported `verified` per call although the gate admits NULL
publication stamps; the ≥ 12 h outage rule counted touched hourly buckets
rather than duration (an 11-hour 00:30–11:30 interval qualified). The spill
gate stays an opt-in experiment (its ratio is a seasonal-history maximum, not
a physical storage limit) and did not enter cv38.

**v39 = cv38 re-run on the canonical 39-zone footprint + review fixes
(September 2026):** deterministic interval outage readers with the ≥ 12 h rule
on duration (`_day_level_capacity`; fixtures for half-hour boundaries, short
outages, partial deratings, midnight crossing), issuance-bounded per-unit
generation probes inside a ForecastContext (`PER_UNIT_GEN_LATENCY` = 6 d,
audit `:latency_policy`), row-level audit of outage versions (NULL stamps
`:unverifiable`), load/RES readers normalised to naive UTC (#378). Legacy
record path: the duration rule is the only behaviour change vs cv38 code.
Record and ladder: appended below when the backfill lands.

**Verified cv39 record (backfill 2026-09-09/10, live Postgres, Gurobi 4 solver
workers, 15.7 h for 798 days at 51 days/h; 795 days saved 2024-07-01..
2026-09-06 on the canonical 39-zone footprint incl. CH; 23 days with one or
two zones missing at source — SI/BE/GR/RS load gaps, 2024-11-17 truncated —
the same gaps as cv37; `docs/experiments/outage-intervals-370/output/
cv39_record_*`, scorer `scripts/eval_cv.py`).** Two-year ladder 2024-07-01..
2026-06-30, 729 paired days, 39 zones, 681,570 paired zone-hours vs settled:
pooled corr 0.773 → **0.778**, MAE 25.20 → **24.96**, energy-weighted MAE
23.45 → **23.32**, bias −4.20 → −3.54; energy@corr≥0.8 47.4 → **49.2 %**
(IT-SOUTH 0.800, IT-CSOUTH 0.811 cross), ≥0.75 83.8 → 84.7 %, ≥0.7 90.5 →
89.7 % (NO4 0.705 → 0.699). 28 zones better / 11 worse: DK2 −2.9 (bias −13.3
→ −7.2, corr 0.703 → 0.734), IT-SOUTH −1.6, IT-Calabria −1.4, IT-Sicily −1.1,
IT-CNORTH/NORTH −0.7, LT/LV/EE −0.4..−0.5; the continental hub is flat
(DE_LU −0.02, BE +0.04, NL −0.04, FR −0.04, CH +0.005 — the BE/DE_LU/NL
degradation of the defective 38-zone cv38 run was the missing CH, not the
fix); worse only SE4 +0.97 (bias +7.2 → +10.4), NO3 +0.21, NO2/NO5 +0.17,
NO4 +0.15, SE2 +0.13. By year: 2024 H2 flat, 2025 22.99 → 22.70 (corr 0.815
→ 0.822), 2026 H1 26.28 → 25.88; evening 16–19 UTC 35.87 → 35.43. Full window
to 2026-09-06 (786 paired days): corr 0.775 → 0.781, MAE 26.10 → 25.85, ew
24.28 → 24.16, energy@corr≥0.8 61.2 → 67.8 %. Cells ≥ 500 €/MWh: 12 in cv39
vs 6 in cv37 — the largest new cluster IT-Sicily 2026-02-24 17–20 UTC at
541–932 against settled 135–148, to be looked at (an interval-rule capacity removal on
that day is the suspect). Same caveat as before: record-vs-record carries the
cv37 draw's own randomness (29.7 % of cells differ, mean |Δ| 6.6) and source
refills; the paired 52-Wednesday A/B (38 zones) is the clean measurement of
the fix and its 39-zone re-run is pending. cv39 supersedes cv37 as the
canonical record; the cv38 rows are the defective 38-zone run.

**v40 = cv39-review implementation defects (September 2026, PR #386,
docs/experiments/cv40-review-fixes/):** three network/load reader corrections
and the model-line provenance binding, from the external review at
`docs/energy-markets-cv39-review.md`, amended after its cv40 follow-up
(`docs/energy-markets-cv40-review.md`). (1) **Germany's JAO net-position
limits never reached the clear**: the interconnector-hub test (an underscore in
the hub name — DK1_CO, NO2_SK, SE3_FS) ran on the MAPPED name, where `DE`
becomes `DE_LU`, so 24 records a day were discarded; it now runs on the raw JAO
name (`EUPHEMIA_DISABLE_CV40_DEHUB`). (2) **Transmission-outage caps** ran
before explicit ATC and the pre-gate fallback were added, so border-hours from
those sources escaped the remaining-NTC cap; the pass now runs after every
capacity source is assembled and before the remap/drop passes. (3)
**Fine→coarse load aggregation is duration-weighted**: the recurrence
`(acc + next)/2` is a running mean that over-weighted the last observation
(100/200/300/400 MW → 312.5 instead of 250); fires only on mixed-resolution
zone-days. (4) Not record-affecting: `bin/emit_model_lines.py` binds the book
directory, the training dataset and its provenance together and aborts on a
mismatch instead of publishing lines from a model fitted on other books.
**DEFERRED, opt-in only** (`EUPHEMIA_ENABLE_CV40_ZEROCAP`): treating a
published net-position limit of exactly 0 as a zero gross cap. A zero bound
constrains `exports − imports`, so balanced transit stays feasible; deleting
the outgoing capacity is the wrong constraint and the right one belongs in the
solver. A/B on 52 Wednesdays × the canonical 39 zones, scored against the
canonical SDAC settlement target: footprint MAE 27.27 → 27.26, energy-weighted
26.48 → 26.43, corr 0.758 unchanged, 9.8 % of cells moved; HU −0.43, DE_LU
−0.27, DK1 −0.10 against AT +0.31, CH +0.16, SK +0.12 — the redistribution a
binding hub limit should produce. Collapse recall (0.175) and false alarms
(161) unchanged: these fixes concern feasible exchange, not the low-price
mechanism. **No record backfill shipped with cv40** — the aggregate is flat, so
cv39 remains the canonical record until the Sicily attribution and the
flow-based domain work justify one consolidated run.

**v41 = registry unit bound 25 GW -> 5 GW (November 2026).** Two registry rows
that entered on market day 2026-09-17 sat just under the old ceiling: IT-NORTH
`26WTRGNRZNMRF10A` (22,600 MW) and IT-SOUTH `26WMTRIAGASCM106` (23,940 MW), both
"Geothermal", at about EUR 29/MWh. Lead-1 weather track, Sep 17 - Oct 31: IT-NORTH
bias -200, IT-SOUTH -207, the sim near 26 and 2 against settled 226 and 209. The
7 Italian zones' MAE went from 57 (Sep 1-16) to 181, energy-weighted; the bias of
the neighbouring spill zones (CH, AT, SI, HU, SK, RO, RS, BG, GR) went from -29 to
-82. Measured from the published vintages; the fix itself has not yet been cleared
on a real day. Frozen cv40 vintages stay as they are, and no backfill ships with this.

**v42 = the unit bound applies to the raw registry row (November 2026).** `get_generators`
checked the bound after `DISTINCT ON` and after the outage `LEAST`. So a corrupt row
derated below 5 GW passed, and a corrupt row that won the dedupe cost the unit its
valid row. The bound is now a `WHERE` clause on the raw capacity, which runs before
both and matches what `get_installed_capacity_by_type` already did. Rejected rows are
logged per zone and day. No backfill ships with this.

## v43 — Italy feed anchor + weather-track solar gate + in-merit truthing (November 2026)

Independent changes from the 2026-11-14 sprint (`em-team/reports/analyst.md`,
`level.md`). Each has a kill-switch. **No backfill ships with this**, and the cv40/cv42
vintages stay as they are.

1. **Feed-anchored fleet rescue window** (`src/generators/registry.jl`,
   `EUPHEMIA_DISABLE_FEED_ANCHOR`). The root cause behind v41/v42.
   - **Mechanism.** Stale-registry units (validity ended, e.g. Italy's 2025-12-30
     vintage) stay in the fleet only if they generated in the last 60 days. The
     Italian per-unit generation feed is absent from ~2026-07-19 until data for
     11-03 (first ingested 11-06). From market day 2026-09-17 (07-19 + 60 d) about
     40 GW of Italian fleet left the book.
   - **Consequence.** Under cv40 the two corrupt ~23 GW rows filled the hole, so
     Italy priced at 1–40 €/MWh. Under cv41/42 those rows are rejected, which
     exposed the hole as 3000 €/MWh caps on 11-03..05.
   - **Fix.** When a zone's last per-unit observation is more than 7 d older than
     the anchor bound, the 60-day window is anchored at that observation and a
     staleness warning is logged. The anchor bound is D−1 10:00 UTC −
     `PER_UNIT_GEN_LATENCY`, capped by the probe upper bound.
   - **Fleet, 2026-11-14 extract.** IT conventional 16.4 → 58.5 GW (09-20),
     16.1 → 56.8 GW (10-19), 18.8 → 61.7 GW (11-02). Gas 8 → 39–41 GW. Over 39 zones
     × the 8 sprint calibration days, only the 45 Italian zone-days change.
   - **Measured, 39-zone HiGHS clear vs cv42, 936 cells/day (934 on 09-20).**
     10-19: MAE 91.5 → 70.3, corr 0.43 → 0.74, 3 caps → 0. 09-20: 46.8 → 49.3.
     Italy 10-19: 187.5 → 60.2. Italy 09-20: 46.8 → 63.3; cv42's short fleet lifted
     a low-demand Sunday toward settled.
   - **Coupling.** Vs cv40 code, Italy's phantom capacity accounted for only
     8.5 / 5.9 €/MWh of its neighbours' −46 / −120 bias (09-20 / 10-19).
2. **Weather-track solar gate input** (`bin/weather_res.jl`, `bin/ml_inputs.jl`,
   `bin/daily_forecast.jl`, `src/merit_order/book_build.jl` fill entries).
   - **Defect.** The cv31 gate reads "Solar" RES rows. On the weather (live,
     pre-gate) track RES arrives as untyped "WeatherFill" rows, and TSO 14.1.D
     solar for D lands after the 08–10 UTC run. So the gate never fired on the live
     product.
   - **Fix.** The weather/ML predictors return their solar component and the fill
     emits typed "Solar" + "WeatherFill" rows. Quantity-neutral.
   - **Evidence.** On 2026-09-20, gate-time inputs flag 15 zone-hours (DE_LU 6,
     BE 5, CH 2, PL 2), of which 13 settled ≤ 0. Plumbing check: 0 → 28
     negative-priced supply orders, total supply identical.
   - **Not price-measured** (open-meteo is not reachable offline). The record path
     and the entsoe track are unchanged.
   - **Review fix (#401 P2).** The issued solar is collected from the typed fill
     entries BEFORE the TSO-coverage check and overrides TSO "Solar" rows in the
     share (`_solar_share_by_hour`). So a wind-only or partial TSO row no longer
     masks the weather gate. Quantities keep merge-never-replace.
3. **In-merit truthing, default-on** (`src/merit_order/book_build.jl`,
   `EUPHEMIA_DISABLE_INMERIT_TRUTH`; `EUPHEMIA_INMERIT_TRUTH=0` also forces off).
   - **Defect.** Under `fleet_truth_mode=:installed` (DE_LU/NL/PL/CZ, Baltics),
     in-merit hard coal and lignite were completed to installed capacity and never
     derated. Autumn 2026, TTF ≈ 90: DE_LU offered 17.5 GW of hard coal against a
     30-day output p95 of 4.7 GW.
   - **Fix.** A baseload derate-type whose SRMC is below gas SRMC on D and D−30
     falls back to the :p95 truthing rule.
   - **Measured.** 8 calibration days × 39 zones, gate-time record inputs, 7,486
     cells: MAE 60.52 → 50.01, ex-IT 61.46 → 49.44, bias −43.3 → −28.6, corr
     0.82 → 0.84, 0 new caps. 7/8 days better (09-20 +1.0). 33 zones better, 6
     worse (SE3 +4.3, NO3 +2.5).
   - **Exposed.** Evening (15–20 UTC) cells > +50 too high, 107 → 208 of 1,536.
     That is the gas peak-tranche conduct layer, previously masked by coal.
   - **Review fix (#401 P1, level).** Inside a ForecastContext the fuel readers
     used the issuance cutoff for every requested day, so the D−30 side of the
     merit test collapsed onto today's prices. The D−30 costs now read with an
     explicit cutoff (`legacy_fuel_cutoff(D−30)`, bounded by issuance). Outside a
     context the record-path D−30 costs are unchanged (8 days × 4 fuels, 32/32).
4. **Deterministic JAO hub net-position scaling** (`src/Network.jl`, ops;
   `test/test_jao_scaling_order.jl`).
   - **Defect.** The per-hub/CCR/direction scaling of bilateral maxima to the JAO
     min/max net position was applied sequentially in Dict traversal order. So a
     border-hour's capacity depended on iteration order and differed between Julia
     versions, by up to ~2 GW.
   - **Fix.** Every factor is computed from the ORIGINAL capacities, one minimum
     factor is applied per border-hour, and summation keys are sorted. The
     zero-bound opt-in and the JAO-only scope are unchanged.
   - **Measured (ops, 2026-11-14).** Old source vs the min-factor fixed source on
     Julia 1.12.7 + HiGHS.jl 1.27.0 (native 1.16.0), with the feed-anchor fix in
     both arms. Three UTC days (2026-09-20, 11-04, 11-13), retrospective
     legacy-record inputs without a ForecastContext (not a live/ex-ante score).
     All 144 period solves optimal per arm.
     - All 39 zones, n = 2,806: **pooled ΔMAE −1.07 €/MWh**, Δbias +0.76. Per day:
       09-20 −0.75, 11-04 −1.62, 11-13 −0.85; all 3 days better. 463–498 of 936
       cells move per day, max |Δprice| 46.8 / 120.7 / 60.9.
     - Excluding Italy, n = 2,304: **pooled ΔMAE −1.32**, Δbias +0.94. Per day:
       09-20 −0.85, 11-04 −2.02, 11-13 −1.09.
     - The fix adds 2 non-positive hits (0 false alarms). Changing the runtime
       from 1.12 to 1.13.4 on the fixed source changes 0 of 2,808 prices.
     - Cell deltas: `em-team/results/ops/fixed/{score_deltas,price_differences}.csv`
       (sprint workspace).
   - **Single-day check (analyst).** The 2026-11-02 39-zone HiGHS clear, cv43
     head vs cv43 without this commit, library-default kwargs: 273/936 cells
     move (max |Δ| 150 €/MWh, NO1/NO2 18 UTC), MAE 66.79 → 66.52, corr
     0.731 → 0.743. Neutral to slightly better, consistent with ops.
   - No kill-switch: this is a determinism fix.


## v44 — pumped-storage complex orders on by default (November 2026)

Owner decision, phase 2 of the 2026-11 sprint (PR #407 built the layer; write-up
in `docs/experiments/complex-orders-2026-11/`). `EUPHEMIA_COMPLEX_ORDERS` now
defaults to `ps`.

**Mechanism.**
- Each zone's `Hydro Pumped Storage` water-value offers become one
  energy-limited `LinkedHourlyOrder` family.
- **Budget:** mean daily PS generation over the 14 complete UTC days before
  `min(D-1, date(as_of − AGG_GEN_PUBLICATION_LATENCY))`. On the record path and
  at lead 1 that window is D-15..D-2.
- **Master:** a full-day welfare LP over the coupled footprint allocates each
  family's energy across the hours.
- **Pricing:** members re-enter the unchanged per-period MPCC at their own bid,
  capped at their allocation (fix-and-reprice). Per-period decomposition is
  kept.
- **Why:** before cv44 the book offered PS 24 h/day at the water value, i.e.
  unlimited energy. DE_LU, for example, offered 114.7 GWh/day against
  25.2 GWh/day demonstrated.

**Kill-switch.** `EUPHEMIA_COMPLEX_ORDERS=off` (also `none` or
present-and-empty) gives the cv43 book byte-identically. It is forwarded to
pipelined-backfill workers. `blocks` (thermal regular blocks + PAB loop) and
`reservoir` stay opt-in through an explicit list, e.g.
`EUPHEMIA_COMPLEX_ORDERS=ps,blocks`.

**Measured** on the 8 sprint calibration days, cv43 base vs `ps`:
- **Setup:** 39-zone HiGHS 1.27 clear, Julia 1.13.4, offline extract
  2026-11-14, legacy record path. 7,486 paired cells against the live-JSON SDAC
  actual; every arm-day `optimal`.
- **Footprint:** MAE 49.65 → 48.58 (−1.08); excluding Italy 48.95 → 47.75
  (−1.20). Bias −28.5 → −26.9. Correlation 0.843 → 0.845. ≤ 0 hits and false
  alarms unchanged (3/3).
- **Days:** better on 7 of 8 (09-20 +0.04, 11-04 −3.88). Worst zone SE3 +0.48.
- **Where the budget binds** (892 zone-hours: CH, SK, SI, AT, BG, CZ, PL,
  IT-Sicily, NO2, NO5): MAE −3.3 (CH −7.3, SK −4.1, SI −3.6, AT −3.2).
- **Spillover:** HU and RO −3.2, CZ −2.4, FR −2.1.
- **Slack budgets:** DE_LU, ES, PT and FR PS rarely run in the money.
- **Cost:** master LP 0.6–1.0 s per pass. Wall time per day, single process,
  39 zones, two passes:

  | Day | cv43 (`off`) | cv44 |
  |---|---|---|
  | 09-20 | 285 s | 314 s |
  | 11-04 | 246 s | 285 s |

  That is +30–40 s per day (+10–16 %), so a 60-day serial backfill takes about
  +0.5 h.
- **Default-on evidence:** cv44 with the env unset reproduces the flagged `ps`
  arm bit-for-bit, and `EUPHEMIA_COMPLEX_ORDERS=off` reproduces the cv43 base
  bit-for-bit. Checked on 09-20 and 11-04: 936/936 cells each, max |Δ| 0.

Every path that builds merit-order books changes where a PS family forms. That
includes the SEE single-zone and 5-zone products (GR and BG have PS), so their
byte-identity chain ends here.

## v45 — gas on the TTF gross (HHV) basis + guarded oil/"Other" availability (adopted 2026-11-21)

**Why.** The offline cv44 weather-track backfill was biased −45 €/MWh on
Nov 8–15 2026 (−80 on Nov 10), and the cv44 record shows sim/SRMC falling
behind actual/SRMC as gas rose (slope −0.0019 per €/MWh of SRMC). Diagnosis:
`reports/analyst-nov-bias.md`. The independent review
(`reviews/fable-nov-bias.md`) showed that most of the gap is **quantity**: no
pumping demand, flat storage hydro and over-offered oil/"Other". Fixing those
plus the gas units error lets the existing tranche ladder lift the clear.
Nothing here re-tunes `TRANCHES`, `scarcity_*` or `peak_kappa`.

**Changes.** One env knob each (`src/cv45_knobs.jl`). Each is `on`/`off`.
**Shipped** (`CV45_SHIPPED`; unset follows `EUPHEMIA_CV45`, default `on`):
GAS_HHV, GB_HHV, AVAIL, AVAIL_INMERIT. **Deferred** (unset ⇒ off; opt-in with
`=on`): PUMP, RESERVOIR, HYDRO_CAP, ELASTIC. `EUPHEMIA_CV45=off` ⇒ cv44
byte-identical.

| Knob | Change | Value source |
|---|---|---|
| `EUPHEMIA_CV45_PUMP` | expected pumping (same-hour mean PS consumption, the PS budget's 14-day window) added to load — *deferred: failed do-no-harm alone (fixed midday load where cv44 already over-prices); priced pumping is a cv46 candidate* | load excludes pumping (review §2.3 regression) |
| `EUPHEMIA_CV45_RESERVOIR` | `reservoir` complex family on by default (non-`:reservoir_opportunity` zones) — *deferred: no measurable gain* | existing family |
| `EUPHEMIA_CV45_AVAIL` | `Fossil Oil` and `Other` in the fleet-truthing derate (1.15 × 30d p95) | declared `DERATE_HEADROOM` |
| `EUPHEMIA_CV45_AVAIL_INMERIT` | With AVAIL enabled, cap each fuel only when its SRMC is below gas on both D and D−30. To replay the original AVAIL arm, turn this modifier off. | cv43 in-merit test and historical close cutoff |
| `EUPHEMIA_CV45_GAS_HHV` | gas fuel term `TTF / (0.55 × 0.90)` | TTF on GCV (GTS Definitions Code Gas); NCV/GCV 0.90 (Energy Statistics Manual 2005) |
| `EUPHEMIA_CV45_GB_HHV` | GB boundary fuel term `TTF / (0.52 × 0.90)` on DK1 and FR. Carbon and the missing-TTF fallback retain their existing calculations. | declared LHV GB efficiency and the domestic NCV/GCV conversion |
| `EUPHEMIA_CV45_HYDRO_CAP` | anchored water-value clamp `TRANCHES[end]` (1.6) × gas SRMC — *deferred: small gain, spends the Nordic margin* | declared constant |
| `EUPHEMIA_CV45_ELASTIC` | elastic-demand price `max(250, BACKSTOP_PRICE_MULT × gas SRMC)` — *deferred: no measurable gain* | declared constant |

Not in v45: the coal price feed (no series in the extract for the window),
the gas heat-rate ladder (a cv46 candidate only if a gap remains), and
"Other" priced as gas.

**Freeze rule.** These change price-informed behaviour (gas SRMC moves every
water value and threshold), so v45 restarts the out-of-sample clock from its
adoption date: the scoreboard's since-freeze window is cv ≥ 45 from 2026-11-21
(`bin/scoreboard_windows.jl`). Pre-registered pass criteria and periods:
`reports/analyst-cv45.md` §0.

**Evidence (record mode, gate-matched, HiGHS; 2024-07-01..2026-11-14, 866 days,
808,704 paired zone-hours vs cv44; 2024-11-17 fails in both arms).**
- The full eight-knob set **failed** criterion (1): do-no-harm (2024-07..2026-06)
  dMAE +0.72, Iberia +3.93, Nordic south +2.14, Nordic north +2.07.
- Single-knob arms on 185 sample days (every 5th day + 2026-11-01..14)
  attributed the harm to PUMP (+0.66 alone) and showed no gain from RESERVOIR or
  ELASTIC; two independent reviews (`reviews/{fable,astra}-cv45-singles.md`)
  chose the shipped set, pre-registered in `reports/analyst-cv45.md` §0c before
  its clear.
- **Shipped set, full window — criterion (1) PASS:** do-no-harm dMAE **−0.16**
  (bias −1.06 → +3.17); worst region Nordic north **+1.70** (≤ +2.00); Iberia
  +1.59, Nordic south +0.61, others negative. Development (2026-07..11-14)
  **−3.46** (bias −17.7 → −6.5). November 2026 **−7.97** (bias −38.7 → −16.5).
  All days −0.68.
- Known weak spots (cv46): Nordic north and Iberia already run high in cv44 and
  v45 raises them (Nordic north development +3.35); the extract lacks ES D-1
  wind/solar on 2026-11-06..11, inflating Iberia on those days in every arm.

## Operations and scoring notes (not code versions)

Dated reminders and scoring-policy notes that do not change `code_version`.

- **2026-11-23 — DuckDB between Postgres and Julia (owner rule); prices unchanged, no `code_version` bump.**
  Every production job runs fill → run → transfer: one Postgres read (the fill) and one Postgres write (the
  transfer), both through DuckDB's postgres extension (`attach_postgres!`, src/db/pg_attach.jl); Julia reads no
  Postgres row and opens no LibPQ connection in those jobs.
  - Fill: `bin/fill_run_duckdb.jl --profile record|daily-forecast|export|retro|rescore` copies exactly the rows the
    job's readers need into a run-local `inputs.duckdb` (manifest `FILL_SPECS`, src/db/fill_manifest.jl: per table the
    zone filter and the readers' lookback per delivery day; the filter runs inside Postgres, timestamptz arrive as naive
    UTC) and seeds the read-back slices (forecasts, scores, cv32 corrections, recent flows, the record's existing prices)
    into `results.duckdb`. A strict guard makes any read outside the filled tables/windows fail loudly
    (`FillGuardError`, which no soft fallback or outer catch swallows); a table absent in the source is recorded and
    its reader falls back exactly as against that source; every libpq session is pinned to UTC.
  - Results: every forecast-side and record write goes to the results DuckDB and logs one op;
    `bin/transfer_run_results.jl` / `bin/transfer_results_to_postgres.jl` stage the rows through the extension and apply
    them in one server-side transaction (guards and plans re-decided in Postgres, a changed plan aborts with nothing
    written; `simulations.transfer_log` makes it exactly once; record checksums verified inside the transaction).
  - Workflows: daily-forecast (both jobs), generate-multi-zone-prices, publish-web-data, retro-backfill, rescore-hourly,
    rescore-q15; the nightly extract refresh also copies through the extension. `measure-duckdb-path.yml` is the guarded,
    read-only runner measurement.
  - Evidence (throwaway test Postgres): 31-day spot check, Postgres path vs fill path vs record #2: <31-day>; the transfer's
    Postgres state as expected, replay a no-op, a stale plan refused; retro-backfill and rescore-hourly as written match
    Postgres; pipelined record (2 book workers) fill path = extract path; a non-UTC session gives identical outage
    inputs on both paths; fill of the 7-lead daily forecast <fill-time>, peak <fill-rss> (record fills: 2.2–2.75 GiB RSS
    at 10–11 days).

- **2026-11-23 — perf-96: faster clearing and input reads; prices unchanged, no `code_version` bump.**
  Bit-identical prices on the 31-day spot check vs record #2 (29,016/29,016) and on 4 days at 96 steps.
  - LP certificate: the welfare LP is one `MOI.copy_to` from a filtered view of the model (`_WelfareSource`)
    instead of `copy_model` + deleting the price-side rows and variables (same LP, byte-identical MPS); the
    vector delete compiled for ~75 s in every fresh process. The fixed-pattern model is solved as an LP
    (integrality dropped after the pattern fixes every binary, restored on a fallback): 44 → 8 s per joint
    96-step pricing. `extract_time_period` uses one compile-time `DateFormat` (~300k calls per 96-step pass).
  - Inputs: pass 2 reuses pass 1's transfer capacity; the feed-anchor staleness check probes the last 7 days
    before running the full-history `MAX` (39 such scans per first clear since cv43); four day caches that
    were write-only now return hits; `get_generators` shares one recent-generation scan per zone-day; shared
    day caches fill once under the threaded book build.
  - JIT: a DB-free PrecompileTools workload (3-zone clear) compiles the clearing path at precompile time;
    module-level state after `using Euphemia` is asserted empty (`test_precompile_state.jl`).

- **2026-11-22 — Block acceptance search replaces the PAB loop (blocks/r1-only).** With
  `EUPHEMIA_COMPLEX_ORDERS=…blocks` (opt-in), the 4-round PAB loop and its release to the `BLKFB:`
  must-run offers are replaced by a reversible acceptance search (seed, prune to a PAB-free set,
  reinsert in-the-money rejected blocks; 30 pricings / €50k gap stop): every call PAB-free, no
  fallback; release only on a master failure. Only the blocks path changes: the default config
  clears no blocks and its code path is untouched. Block clears are deterministic for a given book;
  book inputs can still differ at the ulp level between runs (order-dependent SQL sums), a separate
  follow-up. No model change and no backfill, so no `code_version` bump (the rule: "bump it for
  every model iteration that gets a backfill").

- **2026-11-22 — Gurobi removed; HiGHS only; prices unchanged.** The Gurobi dependency, optimizer choice,
  licence handling and Gurobi-only retry rungs are deleted; HiGHS (with the LP certificate and the
  per-period HiGHS rungs) is the only solve path. The HiGHS path itself is unchanged, so no `code_version`
  bump (the rule: bump for every model iteration that gets a backfill).

- **2026-11-22 — LP certificate replaces the MIP-first MPCC solve (cv46/lp-cert).** Each MPCC is
  solved by the welfare LP + fixed-pattern LP (`src/mpcc/lp_certificate.jl`); the MIP runs only on
  a failed certificate. Full-record re-clear (2024-07-01..2026-11-14) vs the cv45 record: 809,611 of
  809,616 hourly prices identical, 0 MIP fallbacks. Of the 5 others, 3 (RS, SE3, BG) are
  equal-welfare flow-pattern ties (same objective to ≤ 1 ulp; a link at its ATC limit in one
  solution and just below it in the other, mapped to a different price component); the MIP-first
  path reproduced all 5 record values on re-runs, and only RS swaps under an ulp-level input change.
  NO3/NO5 2025-05-09 08:00 is a run-context knife-edge on which two certificate runs disagree
  (809,614 / 809,616 cells equal between them). No model change and no backfill, so no
  `code_version` bump (the rule: bump for every model iteration that gets a backfill);
  docs/experiments/lp-certificate.md.

- **2026-11-15 — Freeze rule (owner-approved 2026-11-16, #431).** The 43
  declared `PROVENANCE` characteristics in `src/merit_order/zone_profiles.jl`
  (40 of them `price_informed=true`) are frozen as of cv44's adoption on
  2026-11-15.
  - Any change to a `price_informed=true` characteristic, or to its
    calibration (values, mechanism, or the windows it was chosen on), bumps
    `ENERGY_PRICES_CODE_VERSION` and restarts the out-of-sample clock from
    that version's adoption date.
  - Every historical evaluation window overlaps the calibration windows, so
    the live scores since the freeze are the only out-of-sample physics record.
    On the site this is the scoreboard window "since freeze (cv44, 2026-11-15)".
  - Recalibration aimed at benchmark rankings is out of policy.
- **2026-11-17 — live scoreboard windows exclude reconstructed rows (#431 R1,
  #449; scoring/export policy, no code_version change).** The scoreboard's live
  windows — "all", the months and "since freeze" — and their naive baselines now
  read live rows only (`is_retro = false`, `live_only_sql` in
  `bin/forecast_common.jl`, both exporters). Before, a market day that had only
  reconstructed (`is_retro`) rows pooled into those windows: the 2026-08 data-reset
  gap-fills (`reset_tag = 2026-08-01-reset`).
  - Published "all" and monthly numbers in the reset window change: fewer `n_days`
    and different MAE/bias/corr where reconstructed days were counted. No live score
    row changes.
  - Reconstructions are published only in their own window: the cv44 backfill
    (`reset_tag = cv44-backfill-2026-11`) as "backfilled (reconstructed, cv44;
    in-sample — calibration overlaps)". The zone charts keep reconstructed days with
    the ↺ mark, and a reconstruction never replaces a live day there.
  - Rollback: `EXPORT_LIVE_RETRO=1` on the export steps restores the old pooling.
- **2026-11-17 — previous-runs weather: public gap-fill of the self-hosted instance
  (#431 R3; input plumbing, no code_version change).** The cv44 backfill run
  43990408427 skipped 2026-09-14..10-17. The self-hosted open-meteo has
  previous-run data only from about 2026-10-17 03:00 UTC. For earlier dates it
  answered HTTP 200 all-null: the pack fetchers fell back to the public API, but the
  ML overlay's RES fetch (`fetch_ml_res_weather`) had no fallback, so the overlay
  emptied RES for all 39 pilot zones. The chunk straddling the boundary came back
  partial, which nothing filled.
  - Now all three previous-runs fetchers (pack RES, pack load, ML RES) share one
    driver (`_fetch_batch_with_fallback`, `bin/weather_vintage.jl`). It replaces an
    all-null answer with the public one and fills only the cell-hours missing from a
    partial answer; a primary hour is never overwritten.
  - The vintage is unchanged: the same `<var>_previous_day{n}` of the same
    `models=` (gfs_seamless), only from another server. The live lag-0 path is
    unchanged: the pack fetchers keep their all-null/HTTP-error fallback, and the ML
    RES fetch at lag 0 still has no fallback (one request, an HTTP error propagates);
    its new fallback applies to previous-run vintages only (#453 review).
  - The retro `⛔` skip now names the failing input per zone, e.g.
    `RES[ml] 0/24 h: AT,… (39)`, and each chunk prints a `📡 weather` line per fetch
    kind: the primary's first data hour, what fell back, and what is still missing.
  - Rollback: `EUPHEMIA_OPENMETEO_GAPFILL=0` restores the old fetch behaviour exactly.
- **2026-11-16 — owner-approved GBM strict as-of default from 2026-11-17
  (#431 D2).** GBM rows freeze at their delivery-day gate; `MODEL_LINES_STRICT_ASOF=0`
  restores the #439 non-strict path, and `MODEL_LINES_REWRITE_PAST=1` permits explicit
  backfills. Before **2027-03-28**, arrange an earlier summer GBM issue or accept
  empty next-day lines: the unchanged 10:40 UTC cron is after the 10:00 UTC summer
  gate (winter gate 11:00 UTC). No schedule or clearing code-version change here.

- **2026-11-17 — scoring policy `sdac-v1`: hourly evaluation target = SDAC (#431 PR C2,
  owner decision 2026-11-16).** `EUPHEMIA_DA_TARGET` now defaults to `sdac`. That covers
  the scorer, the actual charts, the scoreboard naives, collapse evaluation labels and the
  TSFM evaluator: AT and DE_LU use SDAC sequence 1 instead of the EXAA sequence 2, and
  DK1/DK2 use their main series (float-noise change only). Every other zone is identical.
  Shadow diff (`docs/experiments/sdac-target-2026-11/`):
  - live lead-1 physics MAE: AT 85.16 → 88.83, DE_LU 58.46 → 59.17;
  - cv44 record: AT 18.00 → 20.43, DE_LU 19.09 → 20.20.

  The full hourly history is rescored once by `.github/workflows/rescore-hourly.yml`
  (snapshot artifact first; AT/DE_LU/DK1/DK2; q15 columns untouched). `forecast_scores` has
  no policy column, so the policy is recorded here and in that run's summary. Rows scored
  after the rescore run carry `TARGET_POLICY=sdac` in the scorer log.

  **Model inputs are pinned separately:** `EUPHEMIA_DA_INPUT`, default `highest_seq`, covers
  Timestral's price context, the GBM lag history and the collapse logistic's training labels
  and features. Changing them is a separate model decision.

  **Kill switch:** repo variable / env `EUPHEMIA_DA_TARGET=highest_seq`, then rescore-hourly
  `action=restore restore_run_id=<run>`. That restores only that run's campaign keys, and
  only rows not rescored since. No code_version bump.

- **2026-11-16 — revisit the 10:40 UTC overlay refresh before 2027-03-28
  (#431).** The refresh (Timestral postsim + GBM lines) is scheduled in UTC.
  In winter it runs before the 11:00 UTC SDAC gate, but its site pickup at
  about 11:30 UTC comes after it. From 2027-03-28 (CEST) the gate is 10:00 UTC,
  so the run itself is after the gate too. The site describes it as "a forecast
  on pre-gate inputs, not a pre-gate publication". Before the switch, decide
  whether to keep that label (no change) or move to local-time scheduling (an
  ops PR plus a server crontab edit by the owner).
