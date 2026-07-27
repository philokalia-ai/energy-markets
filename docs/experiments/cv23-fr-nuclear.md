# cv23 — French nuclear opportunity-cost bidding (+ the re-paired GB border)

Model iteration cv23. Two coupled components that ship together or not at all,
in the order the cv22 GB investigation prescribed:

1. **FR nuclear opportunity-cost bidding** — an availability-scaled "nuclear
   water value" that steepens France's supply curve when the fleet is
   energy-constrained (summer maintenance + river-temperature derating) and
   flattens it when the fleet is abundant (winter). This fixes France's
   too-cheap evening supply curve — the root cause the GB pair's NO-SHIP verdict
   named (`docs/experiments/gb-borders-cv22.md` §4).
2. **The GB pair** (roadmap item 5) — the FR↔GB physical-flow double-count fix +
   the elastic GB boundary book (UKA/CCGT anchor), re-run **on top of** the FR
   fix, exactly as the cv22 verdict prescribed ("fix France's supply curve
   first, then re-run this exact A/B").

This document is the pre-registration + decision record. Phase 1 (diagnosis) is
committed before any src change; Phase 2 (implementation + measured gates) is
appended after.

---

## Phase 1 — Diagnosis

All figures are the **shipped cv22 record** (`simulations.energy_prices`,
`code_version=22`, `clearing_mode='multi_zone_eu'`, FR) exported once to CSV vs
realized FR Day-ahead prices (`entsoe.energy_prices`, `map_code='FR'`, averaged
to the UTC hour) from the offline extract `data/extracts/euphemia-live.duckdb`.
Join: 30,384 hourly rows, 2023-01-01…2026-07-24. Evening = 17–20 UTC (19–22 CET).
Scripts: `scratchpad/diag1.jl`, `corr2.jl`, `corr3.jl`, `nuc.jl`.

### 1a. The residual is strongly year- and season-structured

| year | MAE | bias (sim−real) | corr | mean real | mean sim |
|---|---|---|---|---|---|
| **2023** (nuclear crisis) | **26.3** | **−12.0** | **0.611** | 97.2 | 85.1 |
| 2024 | 20.2 | −0.4 | 0.792 | 58.1 | 57.7 |
| 2025 | 20.4 | +0.1 | 0.840 | 61.3 | 61.4 |
| 2026 (H1) | 28.8 | +4.1 | 0.742 | 66.3 | 70.4 |

2023 — the year the EDF fleet was chronically de-rated (stress-corrosion
inspections, ~50–68% availability all year) — is France's **worst** year, and
the model runs **€12/MWh too cheap**. This is the signature of a supply curve
that is too flat when nuclear energy is scarce.

### 1b. The evening residual flips sign with the season

Evening (17–20 UTC) bias by season × year:

| | DJF | MAM | JJA | SON |
|---|---|---|---|---|
| 2023 | **+29.7** | −15.5 | −13.9 | +2.3 |
| 2024 | +6.6 | +21.1 | −3.0 | −11.1 |
| 2025 | +3.2 | +2.8 | **−20.9** | +5.6 |
| 2026 | +19.4 | +3.2 | **−23.3** | — |

**Summer (JJA) evenings the model runs €20–23 too cheap** (2025/2026); **winter
(DJF) evenings it runs €20–30 too dear** (2023/2026). A uniform lift would fix
one and break the other — the correction must be regime-aware.

### 1c. The regime variable is nuclear availability

FR nuclear fleet: 59 units, **64.8 GW** installed. Monthly demonstrated
availability = daily-peak summed nuclear output ÷ installed:

- **Winter (Dec–Feb): 0.74–0.84** (peak ~48–54 GW) — fleet near-maxed.
- **Summer (May–Aug): 0.50–0.66** (peak ~32–42 GW) — maintenance + river-temp
  de-rating season.
- **2023 all year: 0.50–0.73** — the chronic-crisis regime.

Splitting the hourly bias by whether same-day availability is below/above the
median (0.645):

| hour (UTC) | TIGHT (low avail) bias | LOOSE (high avail) bias |
|---|---|---|
| 08–09 (morning ramp) | 0.0 / −1.3 | **+14.7 / +11.8** |
| 15 | **−15.5** | −8.4 |
| 16 | **−21.0** | −8.6 |
| 17 | **−15.8** | +1.8 |
| 18–19 (eve peak) | −0.8 / 0.0 | **+11.6 / +8.1** |

The mechanism is unambiguous:

- **Tight nuclear → the late-afternoon ramp (h15–17, 17–19 CET) is €15–21 too
  cheap.** This is the heat-wave scarcity window: nuclear scarce, solar
  collapsing, demand ramping, neighbors pulling exports. Scarce nuclear should
  bid at a high opportunity cost; the cv22 book bids it near fuel SRMC.
- **Loose nuclear → the peak & morning ramp are €8–15 too dear.** Abundant
  winter nuclear should bid close to fuel cost; the cv22 fixed anchor over-lifts.

corr(daily evening residual, availability) = **+0.26** on a trailing-14-day
ex-ante availability signal (+0.21 same-day); evening residual by ex-ante
availability quartile: Q1(tight, 0.56) **−4.9** → Q4(loose, 0.77) **+9.9**,
monotone. (These residuals still carry the FR↔GB double-count's phantom export,
which props FR *up* — so the true tight-regime undershoot after the GB fix is
larger; see §2.)

### 1d. Root cause (from the GB investigation, corroborated)

`docs/experiments/gb-borders-cv22.md` §4 measured that removing the FR↔GB
double-count drops FR July evenings to €109–115 vs realized ~€150 — France's
evening supply curve clears at bare thermal SRMC. The double-count's phantom
export (≈2× the true FR→GB flow) was *accidentally* propping FR's residual
demand up. The compensated error is **France's too-cheap evening supply curve,
NOT a GB-flow mis-statement** — a FRANCE_PROFILE calibration matter (nuclear
opportunity-cost bidding). This diagnosis confirms it from the price side and
supplies the missing physics: the opportunity cost is **energy-budget scarcity**
and it is **availability-scaled**.

### 1e. Literature

French nuclear is genuinely energy-constrained, and most so in summer:

- River-temperature de-rating is a hard regulatory constraint — plants must cut
  output to hold downstream discharge-temperature limits; June-2026's heatwave
  cut ~4.1 GW (~7% of demand) at midday, and 2022 saw multi-reactor summer curbs
  ([Reuters/GBAF](https://www.globalbankingandfinance.com/high-french-river-temperatures-expected-limit-nuclear-power/),
  [pv-magazine](https://www.pv-magazine.com/2026/07/01/when-the-rivers-ran-warm-how-a-heatwave-thinned-frances-nuclear-export-cushion/),
  [Euronews](https://www.euronews.com/2026/06/25/france-takes-nuclear-reactors-offline-amid-record-heatwave),
  [S&P Global 2022](https://www.spglobal.com/commodity-insights/en/news-research/latest-news/electric-power/061722-edf-extends-river-temperature-restrictions-to-second-st-alban-reactor-to-july-8)).
  Temperature curbs "could prompt price swings of several tens of €/MWh on
  intraday peaks and day-ahead prices" ([Bloomberg 2026](https://www.bloomberg.com/news/articles/2026-05-26/french-power-prices-jump-as-hot-weather-spurs-nuclear-concerns)).
- The energy-limited-resource **water-value / opportunity-cost** framing — the
  value of deploying a budget-limited MWh now vs saving it for a higher-value
  hour — is standard for storage and hydro and transfers directly to an
  annually-de-rated nuclear fleet ([arXiv: storage bidding & price formation](https://arxiv.org/pdf/2407.21409),
  [World Nuclear Assoc. — economics](https://world-nuclear.org/information-library/economic-aspects/economics-of-nuclear-power)).
- Post-ARENH (2026) taxes EDF nuclear revenue 50% above €78/MWh and 90% above
  €110/MWh ([Bruegel](https://www.bruegel.org/policy-brief/europes-under-radar-industrial-policy-intervention-electricity-pricing),
  [World Nuclear News](https://www.world-nuclear-news.org/Articles/Agreement-on-post-ARENH-nuclear-electricity-pricin)) —
  a revenue ceiling that does not remove the *marginal* opportunity-cost bidding
  below those thresholds, which is what forms the day-ahead price.

---

## The designed rule — availability-scaled nuclear water value (EX-ANTE, NO-FIT)

France already carries an `opportunity_anchor = :nuclear` (cv-history): in pass 2
of the coupled clear, nuclear's effective bid base is
`max(fuel_SRMC, anchor_share × coupled_reference_price[ts])` with a **fixed**
`anchor_share = 0.55`. The coupled reference already carries the hourly shape
(evenings high), so the anchor lifts evenings more in absolute terms — but the
*fixed* share cannot be tight in summer and loose in winter at once, which is
exactly the §1b/§1c failure.

**cv23 makes the share an ex-ante function of nuclear energy-budget tightness** —
the reservoir/water-value analogy applied to the nuclear fleet:

```
share_eff(day) = share_lo + (share_hi − share_lo) · tightness(day)
tightness(day) = clamp( (a_ref − a(day)) / (a_ref − a_lo), 0, 1 )
a(day)         = ex-ante nuclear availability fraction
               = trailing-30d nuclear output p95 ÷ installed nuclear capacity
```

`a(day)` is **already computed by the book** — fleet-truthing queries the
trailing-30d nuclear output p95 (`get_type_output_p95`, strictly historical) and
the installed nuclear capacity; the availability fraction is free and ex-ante (no
lookahead, no price input).

Constants are read off the **availability fundamentals**, not fitted to prices:

| constant | value | fundamental basis |
|---|---|---|
| `a_ref` | 0.80 | winter-peak fleet availability — above it nuclear is abundant, no scarcity premium (Dec–Feb demonstrated 0.74–0.84) |
| `a_lo` | 0.50 | crisis / deep-maintenance floor — 2023-summer and heatwave lows; at/below it the premium saturates |
| `share_lo` | 0.40 | abundant-fleet share — nuclear undercuts to keep the fleet dispatched (below the current 0.55) |
| `share_hi` | 0.95 | scarce-fleet share — nuclear captures ~full export/opportunity value of a budget-limited MWh |

Behaviour at the observed regimes:

- Winter (a≈0.80): tightness 0 → **share 0.40** (< 0.55) → nuclear bids nearer
  fuel cost → pulls the €8–15 winter-evening/morning overpricing **down**.
- Summer (a≈0.60): tightness 0.67 → **share 0.73** (> 0.55) → scarce nuclear
  prices the ramp higher → lifts the €15–21 h15–17 undershoot **up**.
- 2023 crisis (a≈0.55): tightness 0.83 → **share 0.86** → strong lift where
  the model is €12 too cheap all year.

The water-value clamp is preserved: the effective base is still floored at fuel
SRMC and capped by the coupled reference, so the mechanism can never manufacture
scarcity above the export opportunity — it only redistributes the nuclear bid
across the availability regime. `share_lo=share_hi=0.55` reproduces cv22 exactly
(the mechanism is a strict generalization). Gated behind `EUPHEMIA_DISABLE_CV23`;
default-on for FR only.

**Why this is no-fit.** The *shape* (share rising as availability falls) is the
opportunity-cost physics, not a price regression. The *breakpoints* (`a_ref`,
`a_lo`) are the fleet's own demonstrated availability envelope. The *share
endpoints* sit in the same economically-bounded band FRANCE_PROFILE's 0.55 was
argued from (0.4 undercut ↔ 0.95 full-opportunity). The A/B measures whether this
fundamentals-grounded mapping improves the fit; any endpoint refinement stays
inside those fundamental bounds and is documented, exactly as the original 0.55
calibration was.

---

## Pre-registered gates (Phase 2)

Baseline = cv22 (FR fixed `:nuclear` anchor, FR↔GB double-count present, GB pair
off). Treatment = cv23 = availability-scaled FR nuclear water value **+** the GB
pair (double-count fix + elastic GB book). Full 39-zone coupled clears
(`enrich_network=true, passes=2, :merit_order`, HiGHS decomposed, offline
extract, `save_to_db=false`), scored on realized DA prices over the standard
windows (`docs/experiments/cv21-dk1-viking/windows_ab.json`: July-2026 failure +
March-2026 stable) plus a 2023 stratified 10-day sample (the crisis regime).

1. **FR target (evening):** July-evening bias cut **≥30%**, FR MAE **−1.5 or
   better**, corr **+0.03 or better** vs cv22.
2. **GB-pair neighbor guard:** FR/BE/NL/NO2/DK1 no degradation **>0.03 corr or
   >1.5 MAE** in any window (the specific gate the cv22 GB pair failed — FR must
   NOT show the +4.2 July MAE regression).
3. **2023 crisis regime:** FR improves on the 2023 sample too (MAE and evening
   bias), not only 2026.
4. **SEE guard:** GR single-zone + SEE 5-zone byte-identical with everything
   disabled (`EUPHEMIA_DISABLE_CV23` + the GB switch); 39-zone EU with both
   switches set bit-identical to cv22 main.

If the FR mechanism passes but the GB pair still fails its leg, **ship FR alone**
and document GB honestly again (the cv22 discipline).

## Phase 2 — implementation + measurement

### Implemented (committed)

- **FR nuclear availability-scaled share** — `ZoneProfile.nuclear_avail_share_lo/hi`
  + `nuclear_avail_ref/floor` (`zone_profiles.jl`); `_effective_nuclear_share` /
  `_nuclear_avail_frac` (`book_build.jl`), used in place of the fixed
  `anchor_share` in the `:nuclear` anchor branch. FRANCE_PROFILE carries
  `(0.40, 0.95, 0.80, 0.50)`.
- **FR↔GB boundary pair** — ported from `fix/gb-borders-cv22` and reconciled onto
  cv22 main: `BoundaryBook` gains `net_exclude_codes` / `atc_codes` /
  `carbon_source`; `GB_FR_BOOK` on `FR_PROFILE`; `uka_price` (EUA fallback
  offline); per-cable ATC AVG-within-cable → SUM-across-cables.
- Both gated by one `EUPHEMIA_DISABLE_CV23`. **Does NOT bump the cv** (coordinator
  serializes the cv22→23 bump across concurrent agents).

### Guard 1 — byte-identity (PASS)

`EUPHEMIA_DISABLE_CV23=1` vs cv22 main (`cv22_guard.jl`, 2026-03-03, offline
extract): **1152 / 1152 price rows BIT-IDENTICAL** — GR single-zone (96) + SEE
5-zone (120) + 39-zone EU (936). The shared boundary-code changes (ATC SUM
restructure, `_boundary_anchor(book)`, `boundary_net_exclude`) are byte-identical
for the DK1/Viking + UA books when cv23 is disabled, and the FR nuclear share
reverts to the fixed 0.55. So cv23-off reproduces cv22 exactly.

### Guard 2 — the mechanism responds correctly to availability (ex-ante, no fit)

The `:nuclear` effective share, computed by the shipped code from the ex-ante
availability signal (trailing-30d nuclear p95 ÷ installed), across regimes:

| day | nuclear availability | effective share | vs fixed 0.55 |
|---|---|---|---|
| 2023-07-15 (crisis summer) | 0.53 | **0.89** | strong lift |
| 2025-07-15 (summer) | 0.66 | **0.65** | lift |
| 2026-07-15 (summer) | 0.70 | **0.58** | mild lift |
| 2026-03-03 (spring) | 0.80 | **0.41** | pulls down |
| 2026-01-15 (winter) | 0.86 | **0.40** | pulls down |

Exactly the regime shape the diagnosis prescribes: scarce fleet → higher
opportunity cost, abundant fleet → nearer fuel cost. `EUPHEMIA_DISABLE_CV23=1`
returns the fixed 0.55 on every day.

### A/B — the coupled measurement (one clean day; window A/B blocked in-session)

**Environment limits (documented, not code issues).** Two independent obstacles
prevented completing the full multi-window coupled A/B in this session, both
orthogonal to the cv23 code (the cv22 baseline arm hits them identically):

1. **July-2026 is data-blocked on the available extract.** The coupled clear
   drops periods "not covered by all zones" — for 2026-07-11 only 3 of 24 UTC
   hours are common across all 39 zones (≥1 footprint zone lacks the July
   day-ahead forecast), so the **primary target window (July evening) cannot be
   scored here**. March-2026 clears cleanly to 24 h (guard: full 936 EU rows).
2. **Heavy machine contention.** A concurrent agent held ~50 Julia processes
   through the session; coupled 39-zone clears that run ~4.5 min solo stalled
   many minutes in the Nordic-zone (reservoir full-history) scan under
   contention, exceeding the harness timeouts. The harness
   (`docs/experiments/cv23/ab_cv23.jl` + `score_cv23.jl`, `windows_ab.json`) is
   committed for the coordinator to run the full backfill A/B off-contention.

**Clean measured day — 2026-03-03 (March stable-guard window), 39-zone coupled,
offline extract, scored on the extract's realized DA prices** (cv22 = the guard's
`EUPHEMIA_DISABLE_CV23=1` EU clear; cv23 = both mechanisms on):

| zone | cv22 MAE / bias / eve-bias | cv23 MAE / bias / eve-bias | ΔMAE |
|---|---|---|---|
| **FR** | **38.2 / +38.2 / +47.4** | **16.2 / +13.4 / +11.1** | **−22.0** |
| BE | 23.3 / +19.8 / +17.4 | 23.2 / +19.7 / +17.1 | −0.0 |
| NL | 29.4 / −4.3 / −49.4 | 29.4 / −4.3 / −49.4 | 0.0 |
| NO2 | 13.4 / +13.0 / +6.1 | 13.4 / +13.0 / +6.1 | 0.0 |
| DK1 | 19.0 / +5.1 / −13.1 | 19.0 / +5.1 / −13.1 | 0.0 |

- **FR improves dramatically and directionally as designed:** MAE −22.0 (gate
  −1.5), evening bias +47.4 → +11.1 (**−77%**, gate ≥30%). 2026-03-03 is winter
  (availability 0.80 → share 0.41 pulls the over-priced evenings down) plus the
  GB double-count removal — exactly the winter-overpricing fix the diagnosis
  identified (§1b: 2023/2026 DJF evenings +20…+30 too dear).
- **GB-pair neighbor guard PASSES:** BE/NL/NO2/DK1 all within ±0.1 MAE (0.0) —
  no leakage, and crucially **no FR regression** (the cv22 GB-pair failure was
  +4.2 FR July MAE; here FR is −22 with the nuclear fix underneath, as the cv22
  verdict predicted).

**Honest caveats on the single day.** (a) One day is not a window mean — the
direction (FR winter overpricing cut, neighbors neutral) is robust and matches
the diagnosis, but the magnitude is one draw. (b) The offline-extract cv22 FR
03-03 evening bias (+47) runs hotter than the Postgres cv22 record's March
average (~+3, §1b) — the extract's 03-03 flow/ATC conditions overprice FR more
than the shipped record, so the −22 magnitude is partly day/extract-specific;
the shipped-record improvement will be smaller. (c) **The July-evening summer-
scarcity target — the mechanism's home regime, where the nuclear share lifts
(2025-07 → 0.65, 2023-07 → 0.89) and the GB double-count removal drops FR —
is UNMEASURED here** (data-blocked); it must be run on an extract with complete
July forecast coverage before cv23 ships. The winter result confirms the
lower half of the mechanism (share < 0.55 fixes over-pricing); the summer half
(share > 0.55 fixes under-pricing) is verified only at the share level, not yet
on coupled prices.

### Verdict / next step

The mechanism is **implemented, correctness-guarded (byte-identical when
disabled), and confirmed firing with the right availability shape**; the one
clean coupled day it could be scored on (March) shows a large FR improvement
with zero neighbor leakage — the GB-pair guard the cv22 investigation demanded.
**Ship decision is deferred to the full window A/B** (July + March + 2023) on a
non-contended run with complete July forecast coverage, via the committed
harness. The FR mechanism and the GB pair are wired to ship together per the
cv22 verdict; if the full A/B shows the GB leg still failing while FR passes,
ship FR alone (the cv22 discipline).
