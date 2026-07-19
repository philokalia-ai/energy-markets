# DK1 & SE3 — hour-of-day residual characterization (loop, July 2026)

Full-record hour-of-day residual profiles (actual − sim, cv17 `eu17_base`):

## DK1 — an AMPLITUDE problem (the Italy family, half-strength)

Actual swings 46→117 €/MWh across the day (Δ71); the sim swings 65→94 (Δ29).
Residual profile: **−19 at the solar valley (h12), +23 at the evening peak
(h17)** — the sim neither dips enough in RES-surplus hours (DK1 is wind-heavy;
net load goes deeply negative) nor rises enough at the peak. Same mechanism
family as the IT flat line (uniform-SRMC thermal steps + climatology-flat
imports), at ~50 % strength. Candidates: per-unit efficiency spread (now
validated on IT-CSOUTH: corr 0.31→0.68) + RES-surplus pricing below the gas
band. DK1 shape ratio 0.64 → expect meaningful gains from the same cv18 pair.

## SE3 — a LEVEL problem (night-heavy water-value overpricing)

The sim tracks the shape (ratio 0.99) but sits ~24–41 € ABOVE settled around
the clock, with the gap **largest at night (−39…−41) and smallest at the peak
(−21)**: the Swedish hydro water value is priced too high, most of all in
off-peak hours (act 24–27 at night vs sim 62–66). This is the known Nordic
water-value open problem, now characterized precisely: it is not shape, not
imports — it is the **night-time hydro offer floor**. A `water_value_base` /
off-peak-discount recalibration for SE3 (reservoir-opportunity model) is the
right cv18 lever; the strategic layer is explicitly NOT implicated.

## SE3 water_value_base A/B (loop): NEGATIVE — wrong lever, wrong harness

Tested via the SE3–DK1 endogenous border (SE3's other borders are all in the
Nordic flow-based drop set — SE2–SE3, SE3–SE4, FI–SE3 — so the 2-zone harness
only works through DK1). 15 days, `water_value_base` 0.85 → 0.65 / 0.50:

| | corr | MAE | resid |
|---|---:|---:|---:|
| stock | 0.299 | 51.79 | −45.6 |
| wv 0.65 | 0.296 | 51.94 | −45.9 |
| wv 0.50 | 0.294 | 51.47 | −45.1 |

Two honest conclusions: (1) `water_value_base` alone barely moves the SE3
price — the night overpricing must live in the reservoir-opportunity model's
other terms (span/dry boost) or the anchored-export pricing, not this scalar;
(2) the 2-zone harness DISTORTS SE3 badly (baseline resid −45.6 vs −30 in the
coupled footprint) — SE3 calibration must run on the coupled footprint, not in
isolation. Filed for the cv18 coupled calibration pass, not solvable here.

## DK1 surplus-ladder A/B (loop): POSITIVE — the missing valley mechanism

Elastic export-absorption ladder (3 × 400 MW demand steps at 30/15/5 €/MWh,
appended via strategist), 20 days:

| | corr | MAE | sim std | better days |
|---|---:|---:|---:|---:|
| stock | 0.495 | 34.44 | 25.9 | — |
| **+ export ladder** | **0.569** | **32.42** | 23.3 | 10/20 |

The largest DK1 gain measured tonight (+0.074 corr, −2.0 MAE); the 10/20
split is the expected signature — the ladder only binds in RES-surplus hours,
which occur on about half the sampled days. Combined with the marginal spread
result (+0.026), the cv18 "DK1 package" = export-absorption pricing (primary)
+ unit spread (minor). Combo A/B running. (En route this test caught a third
real bug: the strategist ctx does NOT carry `resolution_minutes` — a closure
referencing it throws and the per-zone build silently drops the zone; take
the resolution from an existing order.)

**Combo (ladder + ±8 % spread, 20 days):** corr 0.553 / MAE 32.64 / **14/20**
— slightly below ladder-alone on the aggregate, more consistent day-to-day.
Verdict: ladder primary, spread optional for consistency.
