# Weak-zone diagnosis: why the model correlates poorly in BE/CH/AT/DK/SE3/IT-CNORTH/SI (+RO/HU/RS)

Investigation of the low-correlation non-hydro zones of the 39-zone EU
counterfactual, measured against the 730-day offline baseline
(`clearing_mode='eu_scn_base'`, cv16, `:v2` ex-ante flows, 2024-07-01..2026-06-30,
`data/results.duckdb`) and ENTSO-E settled day-ahead prices. Investigation
only — no production model changes; prototypes are runtime overrides in
`test/scripts/weak_zone_prototypes.jl`, measured on a stratified 28-day
benchmark.

**Out of scope:** NO1/NO3/NO4/NO5 (known hydro water-value problem).
**Guard:** GR / DE_LU / ES / PT must be untouched (measured below).

## TL;DR

1. **The low correlations are not a shape problem — they are a handful of
   phantom scarcity days.** In every target zone, a small number of days where
   the model clears at the €3,000 cap (while the actual price sits at a median
   of ~€110) destroys the Pearson correlation of the whole 730-day series.
   Excluding just those days: BE 0.24→0.74, DK1 0.09→0.72, DK2 0.23→0.76,
   AT 0.28→0.74, CH 0.34→0.74, SI 0.31→0.68, RO 0.43→0.72, HU 0.48→0.67,
   RS 0.48→0.68 (SE3 0.24→0.54 and IT-CNORTH 0.24→0.57 have a second problem).
2. **The phantom spikes are import starvation, two mechanisms:**
   - *Chronic Core-FBMC residual ATC on endogenous borders that were never
     given the border-drop treatment*: offered implicit ATC into **AT**
     (CZ→AT avg ~300 MW, p10 = 0, vs 1.6 GW physical on spike hours; DE_LU→AT
     1 MW vs 2.0 GW) and into **SI** (AT→SI 3 MW vs 1.3 GW). Same disease that
     earned HU/BE/SK/SE3 their drops in iterations 5–6.
   - *Tail-day understatement of the fixed `:v2` climatology injection* on
     dropped/retained borders (BE +2.1 GW actual-vs-clim on spike hours,
     SE3 +1.9, HU +1.4, DK1 +1.0, RO +0.9, CH +1.1): the 8-week median is the
     *expected* flow; on the ~2% of days when the zone leans hardest on its
     neighbors the book is short by GWs, and with 98% of demand at the cap the
     price jumps from ~1.6×gas straight to €3,000. Reality was often tight on
     those days (RO June 2026: €200–290) — but never €3,000, because more
     import arrives when the price rises. The book has no supply between the
     top domestic tranche and the cap.
3. **Two prototypes measured** (28 days: 16 spike + 12 normal):
   - **P1 (`v1`) border drops**: AT–CZ, AT–DE_LU, AT–SI added to
     `flow_based_drop_borders` + SI moved to the Slovakia treatment
     (continental temperament + `:hydro` anchor).
   - **P2 (`v2`) = P1 + ex-ante elastic import backstop**: per weak zone, one
     extra supply block per hour, qty = recently *demonstrated* import
     headroom beyond the climatology (max of trailing 8 same-weekday days −
     median, ≥0), priced at 1.8×gas SRMC (above every domestic tranche, so it
     only binds when the book would otherwise starve). Implemented via the
     built-in `ZoneScenario.extra_orders` hook — guard zones receive nothing.
   - **Measured (28-day benchmark)**: phantom caps 103 → 19 hours (all
     remaining are out-of-scope Nordic + 3 stragglers); corr BE 0.22→0.85,
     DK1 0.11→0.75, DK2 0.32→0.76, CH 0.11→0.74, AT 0.17→0.80, RO 0.35→0.77,
     RS 0.32→0.79, SI 0.28→0.70, SE3 0.18→0.55; MAE cut 2–3× in every target
     zone; guards GR/DE_LU/ES/PT within ±0.01 corr / ±0.4 MAE (GR improves).
4. **Residual (non-spike) findings**, documented with evidence but not
   prototyped: a shared too-flat intraday shape in the CWE-adjacent zones
   (evening peak −20…−37 €/MWh, midday +5…+17), and SE3's anchor reference
   excluding its dominant physical supplier (SE2) because the SE2–SE3 border
   is dropped.

---

## 1. Failure decomposition (730 days, hourly)

`data/zone_stats.csv`. corr = hourly Pearson; shape = per-day demeaned;
level = daily means; sd_shape = std of daily-demeaned prices.

| zone | corr | shape | level | MAE | bias | sd shape model | sd shape actual |
|------|------|-------|-------|-----|------|----------------|-----------------|
| DK1 | 0.09 | 0.02 | 0.18 | 41.9 | +12.0 | **173.8** | 40.4 |
| DK2 | 0.23 | 0.17 | 0.33 | 38.2 | +7.2 | **165.2** | 41.5 |
| BE | 0.24 | 0.19 | 0.33 | 30.2 | +6.3 | **128.9** | 39.5 |
| IT-CNORTH | 0.24 | 0.25 | 0.26 | 24.7 | +2.1 | 62.7 | 25.3 |
| SE3 | 0.24 | 0.11 | 0.46 | 38.5 | +23.6 | 71.6 | 27.2 |
| AT | 0.28 | 0.22 | 0.37 | 29.1 | −5.9 | **103.0** | 42.0 |
| SI | 0.31 | 0.32 | 0.29 | 43.7 | +9.1 | **201.5** | 50.5 |
| CH | 0.34 | 0.25 | 0.48 | 23.5 | −0.8 | 72.1 | 30.3 |
| RO | 0.43 | 0.42 | 0.49 | 41.2 | +12.6 | **181.2** | 65.4 |
| HU | 0.48 | 0.45 | 0.55 | 35.5 | −9.6 | 75.1 | 66.4 |
| RS | 0.48 | 0.46 | 0.55 | 32.4 | +6.2 | 83.1 | 53.9 |
| *GR (guard)* | 0.80 | 0.79 | 0.81 | 24.1 | −8.6 | 50.4 | 56.3 |
| *DE_LU (guard)* | 0.84 | 0.81 | 0.88 | 19.9 | −2.7 | 24.3 | 44.6 |

Every weak zone has model intraday variability 2.5–4× the actual — the model
is **spiky where reality is smooth**. The spikes are hours where the model
clears at/near the €3,000 cap while the actual price is ordinary
(median €110, p75 €180 across all 1,288 model>€500 hours). They are
**single-zone, day-clustered events** (SI 47 days, RO 38, DK1 24, DK2 22,
RS 17, HU 16, BE 15, AT 7, IT-CNORTH 5, SE3 4, CH 2), concentrated at the
evening peak but present in all hours, and they share regional clusters
(RO/HU/RS/SI all cap through the 2026-01-09..20 cold snap; RO caps every day
of 2026-06-15..30 — a real tight period: one Cernavoda unit partial, wind at
45% of 2025, actual daily means up to €292, covered in reality by BG/HU/UA
imports above climatology).

**Excluding the spike days flips the ranking** (`corr_no_spike`):

| zone | corr (all) | corr excl. spike days | # spike days / 730 |
|------|-----------|----------------------|--------------------|
| BE | 0.24 | 0.74 | 15 |
| DK1 | 0.09 | 0.72 | 24 |
| DK2 | 0.23 | 0.76 | 22 |
| AT | 0.28 | 0.74 | 7 |
| CH | 0.34 | 0.74 | 2 |
| SI | 0.31 | 0.68 | 47 |
| RO | 0.43 | 0.72 | 38 |
| HU | 0.48 | 0.67 | 16 |
| RS | 0.48 | 0.68 | 17 |
| SE3 | 0.24 | 0.54 | 4 |
| IT-CNORTH | 0.24 | 0.57 | 5 |

So the primary target is the ~1,000 phantom cap-hours, not the day-to-day
shape. (SE3 and IT-CNORTH keep a residual problem — §4.)

## 2. Root cause: import starvation

Inputs audit on the spike hours: load forecast present and ordinary; RES
forecast present and roughly right (largest gap DK1 −321 MW forecast-vs-actual
— second-order). The shortage is on the import side
(`data/spike_hour_import_audit.csv`):

**(a) Same-day net imports vs the `:v2` climatology the model injects**
(mean over each zone's spike hours, MW):

| zone | actual net import | clim injection | gap |
|------|------------------|----------------|-----|
| BE | 2,885 | 812 | **+2,074** |
| SE3 | 3,180 | 1,236 | **+1,944** |
| HU | 2,710 | 1,280 | **+1,430** |
| AT | 2,353 | 910 | **+1,444** |
| CH | 2,682 | 1,609 | **+1,073** |
| DK1 | 1,333 | 306 | **+1,027** |
| RO | 2,014 | 1,106 | **+908** |
| DK2 | 1,183 | 719 | +464 |
| SI | −294 | −470 | +177 |
| IT-CNORTH | 1,445 | 1,333 | +112 |
| RS | 99 | 73 | +26 |

**(b) Offered ATC vs physical flow on the *endogenous* borders** (spike-hour
sample): the borders the model believes it can flow over are choked exactly
when needed —

| border | offered ATC (MW) | physical flow (MW) | character |
|--------|------------------|--------------------|-----------|
| CZ→AT | 19 | 1,584 | chronic (quarterly avg ~110–360, p10 = 0) |
| DE_LU→AT | 1 | 2,009 | chronic (avg 52–355, p10 = 0) |
| AT→SI | 3 | 1,328 | chronic (avg 83–285, p10 = 0) |
| DE_LU→DK1 | 295 | 1,907 | episodic (avg ~2.5 GW, collapses on tight hours) |
| SE4→DK2 | 9 | 698 | chronic-ish (avg 164–581, p10 = 0) |
| SE3→DK1 | 31 | 317 | chronic (avg 27–167) |
| IT-CSOUTH→IT-CNORTH | 95 | 1,220 | episodic (avg ~3 GW, p10 dips to ~210) |
| FR→CH (explicit, 2025-01-01) | ~300 | 1,662 | holiday auction gap (DE_Amprion offered 0) |

AT and SI are **Core-FBMC members whose implicit "offered ATC" is the same
stale flow-based residual** already documented and treated for HU (iter 3),
BE (iter 5) and SK (iter 6) — they were simply never given the drop
treatment. DK1/DK2/CH/IT-CNORTH starve only episodically, so a blanket drop
is not justified there; they need a *backstop*, not a drop.

**(c) A book-construction asymmetry amplifies both errors:** the demand side
is 98% price-inelastic at the cap, and the supply side ends at the top
domestic tranche (1.60×gas×scarcity). When the injected imports fall ~1 GW
short there is **no supply between ~€170 and €3,000**, so the clearing price
does not rise gracefully — it jumps to the cap. Reality has a continuum
(more imports arrive as the price rises above neighbors' costs). SI adds the
mirror image: its retained-border exports (~1 GW to HR at climatology) enter
as **firm demand at the cap**, so on a tight day the model must serve them at
any price even though a real exporter would curtail.

## 3. Prototypes and measured results

Both prototypes are pure runtime overrides (`test/scripts/weak_zone_prototypes.jl`);
`VARIANT=v0` replicates the stored baseline bit-identically (max |Δ| = 2.8e-14
on 2025-10-05, 936 prices).

- **P1 (`v1`) — extend the flow-based drop set** with AT–CZ, AT–DE_LU, AT–SI
  (the three chronic residual-ATC borders) and move SI onto the Slovakia
  treatment (continental scarcity temperament + `:hydro` opportunity anchor)
  so its dropped-border imports price at the coupled Core reference rather
  than €1. AT already carries the anchor.
- **P2 (`v2`) — P1 + ex-ante elastic import backstop** for the 11 weak zones:
  qty(h) = max(0, max over trailing 8 same-weekday days of net import(h) −
  climatology median(h)) — the *recently demonstrated* import headroom beyond
  what the book already injects, from data strictly before the D-1 auction;
  price = 1.8× that day's gas SRMC, above every domestic tranche multiplier
  (max 1.60), so it displaces nothing in normal hours and only prevents the
  jump to the cap. Guards receive no backstop.

Benchmark: 16 spike days (every target zone represented, incl. the SEE
cold-snap cluster and the RO June-2026 run) + 12 spike-free days across
seasons and weekday/weekend. Metrics vs settled prices.

### Results — P1 (`v1`, drops + SI anchor), 28-day benchmark vs settled prices

Baseline columns are the stored `eu_scn_base` rows on the same 28 days (the
sample is spike-heavy by construction, so baseline corr here is lower than the
730-day figures).

| zone | corr base→v1 | MAE base→v1 | bias base→v1 |
|------|--------------|-------------|---------------|
| **AT** | **0.17 → 0.75** | **85.3 → 28.9** | +38.6 → −18.8 |
| **SI** | **0.28 → 0.70** | **64.5 → 41.1** | +25.0 → −29.6 |
| RS | 0.32 → 0.42 | 44.6 → 39.7 | +20.4 → +13.8 |
| IT-CNORTH | 0.59 → 0.61 | 26.2 → 24.1 | +6.6 → +3.1 |
| HU | 0.74 → 0.73 | 37.8 → 40.8 | −14.6 → −21.2 |
| BE / CH / DK1 / DK2 / SE3 / RO | unchanged (±0.02) | | (need the backstop) |
| *GR (guard)* | 0.85 → 0.86 | 24.2 → 24.0 | −7.7 → −8.8 |
| *DE_LU (guard)* | 0.88 → 0.87 | 20.7 → 20.9 | −5.4 → −6.5 |
| *ES (guard)* | 0.83 → 0.84 | 23.5 → 23.2 | +4.2 → +3.7 |
| *PT (guard)* | 0.80 → 0.80 | 25.2 → 24.9 | +5.2 → +4.7 |

AT's and SI's phantom caps disappear entirely (>500 hours on the benchmark:
AT 13→0, SI 9→0). Both now sit slightly *below* reality (bias −19/−30): the
anchored import price is clamped at gas SRMC and the SK-style continental
temperament softens the peak markup — the production implementation has
`anchor_share` and the clamp as calibration levers (AT's own share was
calibrated the same way in iter 5). Guards move ≤0.01 corr / ≤0.3 MAE
(coupling-level effects only; the hooks never touch them).

### Results — P2 (`v2` = drops + backstop), 28-day benchmark vs settled prices

Full table: `evidence/variant_metrics.csv` (also split by the 16 spike days).

| zone | corr base→v1→v2 | MAE base→v1→v2 | bias v2 |
|------|-----------------|-----------------|---------|
| **BE** | 0.22 → 0.22 → **0.85** | 63.5 → 63.5 → **21.0** | −3.5 |
| **DK1** | 0.11 → 0.10 → **0.75** | 71.8 → 71.9 → **28.8** | −7.0 |
| **DK2** | 0.32 → 0.32 → **0.76** | 82.6 → 82.8 → **29.4** | −9.2 |
| **CH** | 0.11 → 0.10 → **0.74** | 49.9 → 47.2 → **24.1** | −8.8 |
| **AT** | 0.17 → 0.75 → **0.80** | 85.3 → 28.9 → **28.0** | −21.1 |
| **RO** | 0.35 → 0.34 → **0.77** | 54.8 → 54.4 → **31.8** | −5.0 |
| **RS** | 0.32 → 0.42 → **0.79** | 44.6 → 39.7 → **28.3** | −2.4 |
| **SI** | 0.28 → 0.70 → **0.70** | 64.5 → 41.1 → **41.1** | −31.8 |
| SE3 | 0.18 → 0.18 → 0.55 | 53.8 → 53.7 → 36.2 | +13.3 |
| IT-CNORTH | 0.59 → 0.61 → 0.63 | 26.2 → 24.1 → 21.5 | +0.4 |
| HU | 0.74 → 0.73 → 0.73 | 37.8 → 40.8 → 41.1 | −28.8 |
| *GR (guard)* | 0.85 → 0.86 → 0.86 | 24.2 → 24.0 → 23.4 | −10.3 |
| *DE_LU (guard)* | 0.88 → 0.87 → 0.87 | 20.7 → 20.9 → 21.1 | −6.7 |
| *ES (guard)* | 0.83 → 0.84 → 0.84 | 23.5 → 23.2 → 23.0 | +3.0 |
| *PT (guard)* | 0.80 → 0.80 → 0.80 | 25.2 → 24.9 → 24.8 | +4.1 |

Hours > €500 on the benchmark: **103 (base) → 19 (v2)**, and the remainder is
FI 4 / NO1 12 (out-of-scope Nordic hydro) + 1 each in IT-NORTH / IT-CNORTH /
RO. Every in-scope phantom cap is gone. On the previously-capping SEE
cold-snap day (2026-01-13) the coupled SEE block now clears 124–569 vs actual
250–400 — direction right, residual overpricing from the scarcity *markup*
still firing (the scarcity margin does not see backstop/restored-import
supply; a production implementation should credit it, like
`scarcity_import_credit`).

Attribution: v1-alone moves only AT/SI (the chronic-ATC pair); the backstop
provides the rest. The two mechanisms are complementary, matching the
diagnosis. Cautions measured: **HU** bias drifts −14.6 → −28.8 (its
climatology injection was already adequate — HU should be dropped from the
backstop set or its scarcity margin credited); **AT/SI** now sit ~20–30 low
(anchored import price clamped at gas SRMC + softened temperament —
`anchor_share`/clamp are the production calibration levers, as in the iter-5
AT calibration); **SE3** improves (0.18→0.55, spikes gone) but keeps the flat
night overpricing of §4b — its fix is the anchor-ref change, not imports.

**`v3` (attribution control — backstop WITHOUT the drops):** confirms the
two mechanisms are complementary, not interchangeable:
- **SI needs the drop**: backstop-only leaves SI at corr **0.33** (4 cap
  hours remain) vs **0.70** with the SI–AT drop (v1/v2/v4). As designed, the
  backstop quantity (headroom above the climatology) cannot stand in for a
  chronically starved *endogenous* border, whose expected imports the
  climatology already counts as delivered.
- **AT can be rescued by either mechanism** (v1 drops-only 0.75, v3
  backstop-only 0.78) and is best with both (0.80).
- **HU prefers backstop-only** (MAE 37.0 / bias −23.1 vs 41.1 / −28.8 under
  v2) — the AT-drop coupling cheapens HU's neighborhood. Production shape:
  keep the AT/SI drops but re-check HU's backstop membership and scarcity
  credit when calibrating.
- All other zones: v3 ≈ v2 within ±0.01 corr.

**`v4` (window robustness):** widening the backstop capability window from
the 8 same-weekday draws to the trailing 56 calendar days is a marginal
refinement — RO 0.77→0.80, CH 0.74→0.76, the last in-scope cap hour gone
(18 remaining are all FI/NO1/IT-NORTH edge) — at the cost of slightly deeper
negative bias (HU −28.8→−30.4). The window is a minor calibration knob; the
8-week same-weekday form is already sufficient.

## 4. Residual (non-spike) findings — documented, not prototyped

**(a) Shared too-flat intraday shape (CWE-adjacent zones).** On non-spike
days the hour-of-day bias profile is the same in DK1, DK2, BE, AT, CH, SI,
IT-CNORTH: **evening peak underpriced** (h16–19: DK1 −37, DK2 −31, AT −31,
BE −25, IT-CNORTH −17, SI −15, CH −10 €/MWh) and **midday overpriced**
(+5…+17), plus an underpriced morning ramp (h4–6). Model shape sd ≈ 25–31
vs actual 40–48. Two candidate contributors, both fundamentals-side: (i) the
climatology injection flattens the within-day import profile; (ii) the
continental/Nordic profiles' softened `peak_kappa` (0.5–0.6) was calibrated
*while the books were starving* — the phantom-scarcity cure may have
over-suppressed the genuine evening flexibility premium. Re-examine
peak markups only after the import fixes land, on fundamentals evidence
(pumped-storage/peaker opportunity cost), not by fitting.

**(b) SE3's anchor reference excludes its dominant supplier.** SE3's price is
anchored to the capacity-weighted pass-1 price of its *endogenous* neighbors
— which after the iter-5 drops is essentially only DK1 (€82 night) — while
its real marginal supply is Norrland hydro over the dropped SE2–SE3 cut
(5.6 GW observed vs DK1's ~0.3 GW border). Actual SE3 sits between SE2 and
DK1 (night 40 vs SE2 20 / DK1 82; day 54); the model pins it at 0.9×DK1
(night 68). Recommendation: include dropped in-footprint borders in
`compute_opportunity_anchor_refs`, weighted by observed (climatology) flow —
SE3's ref would become SE2-dominated and its level/shape would fall toward
reality. Likely also helps SE4 (already decent) and is the natural companion
of the P1 drops for AT/SI.

**(c) IT-CNORTH.** Beyond the 5 spike days (episodic IT-CSOUTH→IT-CNORTH ATC
dips), its residual is a north–south split misread: morning/midday overpriced
+12…+16, evening underpriced ~−17 — the same family as (a) plus internal-IT
border modelling; no zone-specific pathology found in the inputs.

**(d) Model floor too sticky.** Actual prices go ≤€5 in 5–9% of hours in
BE/CH/DK/HU/SI (negative down to −20 typical) vs 0.5–3% in the model, whose
supply floor is the €1 RES/import block and never negative. Secondary to the
spikes for correlation; matters for level realism in high-RES hours.

## 5. Ranked recommendations

**Versioning gate:** this experiment is investigation-only — no production
code path changes, and the cv16 record stays untouched. Implementing ANY of
the ranked fixes below (border drops, SI treatment, import backstop, anchor
refs, export pricing) is a model-strategy change and MUST ship under
`ENERGY_PRICES_CODE_VERSION = 17` (or the next free version if 17 is taken by
then), with the corresponding code_version history entry in CLAUDE.md and a
fresh labeled backfill — never under cv16, whose record remains immutable and
comparable.

1. **AT–CZ / AT–DE_LU / AT–SI border drops + SI Slovakia treatment (P1)** —
   direct precedent (HU/BE/SK/SE), chronic disease measured, prototype
   validated. Risk: low-moderate (changes AT/SI coupling for all days; CZ and
   DE_LU lose the AT export outlet — watch their bias in the backfill gate).
2. **Elastic import backstop (P2)** — fixes the tail-day starvation cluster
   (BE/DK1/DK2/CH/RO/HU/RS/IT-CNORTH and residual AT/SI days) with one
   ex-ante mechanism; inert in normal hours by construction. Production form:
   a `ZoneProfile` field (e.g. `import_backstop::Bool` / headroom quantile)
   with the quantity computed next to the `:v2` climatology in
   `get_net_imports`' machinery, OFF for SEE/Iberia so the guard product is
   byte-identical. Refinement for endogenous-border zones: subtract offered
   endogenous ATC from the headroom to avoid double counting.
   Risk: low (supply-only, priced above the domestic stack; measured no
   guard movement).
3. **Anchor refs over dropped borders (SE3, flow-weighted)** — cures the one
   target zone the spike fixes cannot (0.24 → ~0.54 ceiling otherwise).
   Moderate implementation risk (touches the two-pass machinery); measure
   SE4/DK2 side effects.
4. **Retained-border exports should not be firm at the cap** (SI–HR, BE–GB):
   price them at the coupled/anchor reference (the existing
   `anchor_export_mw` treatment generalized), so exporters curtail under
   stress like real ones. Small code change, but touches every zone's book —
   gate per profile.
5. **Evening-peak flexibility premium re-examination** (after 1–2): the flat
   evening underpricing across CWE-adjacent zones suggests the softened
   `peak_kappa` compensated for starvation; revisit against pumped-storage /
   peaker opportunity-cost fundamentals once books no longer starve.

## Reproduction

```bash
# Diagnosis (python, offline, ~2 min)
python3 test/scripts/weak_zone_diagnosis.py

# Prototypes (Julia + Gurobi, ~45 min per variant for the 28-day benchmark)
VARIANT=v0 DAYS=2025-10-05 julia --project=. test/scripts/weak_zone_prototypes.jl  # replication check
VARIANT=v1 julia --project=. test/scripts/weak_zone_prototypes.jl
VARIANT=v2 julia --project=. test/scripts/weak_zone_prototypes.jl
python3 test/scripts/weak_zone_eval.py v1 v2   # metrics tables
```
