# EU calibration — iteration 7 (installed-capacity-aware fleet truth)

One scoped change, stacked on iter6 (PR #105): fix the root cause identified in
iteration 6 — **the continental over-pricing cluster (DE_LU +70, PL +76,
CZ/CH/SI/AT downstream) comes from an under-counted thermal fleet**, not from
the scarcity multiplier (proved by iter6-C3: crediting import ATC into the
scarcity margin moved DE_LU only −1.6).

## 1. Diagnosis (Postgres registry vs model fleet vs trailing p95, 2026-02-03)

`entsoe.production_and_generation_units` carries per-unit installed capacity.
Deduplicated (DISTINCT ON unit, latest `valid_from`) COMMISSIONED units vs the
model's filtered fleet (`get_generators`: validity-or-recent-generation, outages)
vs the trailing-30d per-type p95:

| zone | type | installed | model | p95(30d) | reading |
|---|---|---:|---:|---:|---|
| DE_LU | Fossil Hard coal | 20,967 | 9,772 | 8,043 | idle/mothballed capacity missing |
| DE_LU | Lignite | 19,572 | 11,157 | 12,189 | same |
| DE_LU | Fossil Gas | 19,529 | 15,207 | 17,887 | same (plus <100 MW CHP never listed) |
| DE_LU | **Nuclear** | **9,526** | 0 | 0 | **phantom** — stale COMMISSIONED status post-phase-out |
| PL | Fossil Hard coal | 18,582 | 14,140 | 11,320 | idle capacity missing |
| LT | Hydro Pumped Storage | 900 | 450 | 349 | Kruonis PSP half-listed |
| EE | Fossil Oil shale | 1,330 | 1,060 | 637 | small gap |
| LV | (all) | 981 | 981 | — | **no gap** |
| GR | **Lignite** | **4,637** | 1,524 | 892 | **closure** — the v10 crisis derate is CORRECT |

Two lessons: (a) raw installed capacity **over-counts** (stale statuses — DE
nuclear, GR lignite), so a blanket switch to installed would be wrong and would
break Greece; (b) the model fleet **under-counts** the meshed continental core,
where plants idle because of merit order, not closure — they never enter the
p95-based fleet completion, so the book clears deep in the expensive tranches
(DE_LU modeled 44.3 GW total vs ~60 GW genuinely-active installed; sim €178 vs
actual €109 on 2026-02-03).

## 2. The mechanism (one lever, gated)

`ZoneProfile.fleet_truth_mode` (default **`:p95`** = byte-identical v10/iter6
behaviour everywhere, GR/SEE untouched). Non-default modes true every
MARKET-ACTIVE fuel type's fleet to a target — **completed up to it** by fleet
completion and **never derated below it** by fleet truthing (completing and then
derating back to 1.15×p95 would cancel the mechanism for exactly the baseload
derate-types it targets):

- `:installed` — `get_installed_capacity_by_type` (registry dedup, COMMISSIONED,
  deliberately without the validity/recent-generation unit filter — that filter
  is what removes idle-but-existing units).
- `:seasonal` — trailing-365-day per-type p95 (last-year observed capability).
- **Activity gate** (both modes): only types with trailing-30d p95 > 100 MW —
  a type that no longer generates at all is closed capacity with a stale status
  (this alone excludes DE's 9.5 GW phantom nuclear and GR's dead oil).

## 3. Measured on the frozen 36-day sample (all runs vs the iter6 final)

### Experiment A — `:installed` on CONTINENTAL + BALTIC (NOT enabled)

**Transformative accuracy**: aggregate mean MAE **45.2 → 31.8**, mean corr
**0.51 → 0.60**, mean bias +13.9 → −9.3. DE_LU MAE 73.0 → 21.6 / corr
0.62 → **0.80** / bias +68 → −11; PL 86.0 → 29.5; EE/LT/LV halved; and the
predicted anchor-chain propagation: CH corr +0.29, CZ +0.23, FR +0.32,
IT-NORTH/CNORTH +0.28/+0.29, HU +0.17, SK +0.26, SI +0.03/−27 MAE.
(`docs/iter7-results/experiment_installed_all.csv`)

**Why it is NOT enabled**: (1) **1/36 sample days went INFEASIBLE**
(2025-07-24, a high-RES July day) — bisected zone-by-zone to the **DE_LU book**
(~30 GW of added supply produces a complementarity model that survives the whole
MPCC retry ladder — DualReductions, NumericFocus 3, seed — with a degenerate
134k-constraint IIS; looser MIP gap and passes=1 also fail). (2) AT corr
0.48 → 0.32 and DK2 0.45 → 0.24 (their MAE improves ~20 but the shape gate is
violated). (3) Broad mild negative-bias overshoot (installed also pulls in
mothballed/grid-reserve capacity). A robustness regression on a backfill
product is disqualifying — parked, not rejected.

### Experiment B — `:seasonal` (dead end, documented)

On the winter failure days `:seasonal` is a **no-op**: the trailing-365d p95
barely exceeds the winter 30d p95 (DE hard coal p95_365 ≈ 9 GW vs 21 GW
installed). The idle capacity **never generates even across a full year** — it
is offered-but-undispatched (plus a stand-in for the unlisted <100 MW CHP
fleet), so only `:installed` reaches it. Strict output-observability cannot
justify the capacity the market demonstrably prices against.

### Accepted — `:installed` on BALTIC only

36/36 days clear; GR and all non-Baltic zones byte-flat except the intended
coupling neighbours:

| zone | iter6 final (corr/MAE/bias) | iter7 (corr/MAE/bias) |
|---|---|---|
| EE | 0.47 / 128.6 / +83.5 | **0.76 / 49.0 / −34.0** |
| LT | 0.46 / 125.2 / +77.6 | **0.77 / 46.1 / −34.1** |
| LV | 0.47 / 126.3 / +73.9 | **0.76 / 49.0 / −39.5** |
| FI | 0.51 / 35.9 / −25.5 | **0.85** / 36.1 / −33.0 |
| SE4 | 0.37 / 35.9 / −1.0 | **0.65** / 34.2 / −7.4 |
| PL | 0.57 / 86.0 / +75.7 | 0.50 / 74.0 / +62.8 (corr −0.07, documented) |
| GR (guard) | 0.83 / 23.6 / −6.3 | 0.83 / 23.6 / −6.3 (byte-flat) |

Aggregate: mean MAE **45.2 → 38.8**, mean bias +13.9 → **+4.4**, mean corr
0.51 → 0.55. SEE 5-zone guard byte-identical (131.34/84.96, RS dropped); tests
green (zone_profiles incl. the SEE byte-identical book test, eu_footprint,
mpcc, multi_zone_mpcc, network).
(`docs/iter7-results/accepted_installed_baltic.csv`)

The Baltic bias flips from +80 to −35: the trued fleet removes the phantom
scarcity, slightly overshooting — the remaining negative winter bias is the
next Baltic iteration (import pricing / ATC on EE–FI, LT–SE4).

## 4. Iteration-8 queue

1. **Unblock continental `:installed`** — the measured prize is huge (aggregate
   −13 MAE, DE corr 0.80). Two candidate paths: (a) fix the MPCC robustness on
   oversupplied books (diagnose the 2025-07-24 DE infeasibility structurally —
   the complementarity forced-acceptance chain under coupled export caps; add a
   graceful per-day fallback that re-clears with `:p95` books when the ladder
   exhausts); (b) moderate the completion (per-type outage netting — the target
   currently double-counts outaged capacity back in via the aggregate, e.g. CZ
   nuclear +1.1 GW on an outage day; cap additions by export capability).
2. AT/DK2 shape under the new DE level (their anchor shares were calibrated on
   the inflated DE ref).
3. Baltic winter import pricing (the −35 residual).

## 5. Ex-ante note

The registry is slowly-changing reference data — the same ex-ante treatment as
`get_generators`' existing use of it. The activity gate uses the trailing-30-day
p95 (strictly before the market day). No new lookahead.

The public extract (v1/v1.1) already carries `production_and_generation_units`,
so the mechanism runs offline unchanged.
