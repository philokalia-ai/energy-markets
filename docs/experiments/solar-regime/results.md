# Solar-regime program — regime cartography + regime-gated floor sweep

> **SHIPPED as cv31 (August 2026, activation PR after #251).** The accepted arm
> — BLOCKS=full, θ=0.4, ZONES=DE_LU,FR,PL,BE,CZ,CH — is now the DEFAULT for the
> record path (`ENERGY_PRICES_CODE_VERSION = 31`). Kill-switch
> `EUPHEMIA_DISABLE_CV31` ⇒ fully inert (byte-identical to cv27 main); explicit
> `EUPHEMIA_SOLAR_REGIME*` env still wins. See the CLAUDE.md v31 ledger entry.

Branch `feat/solar-regime` off main=cv27. Extract read-only. The owner ask:
market regimes that plausibly activate only under abundant renewables must be
studied SEPARATELY — a regime mechanism must not be rejected because it "hurts
on average" (the cv26/28/29 NO-SHIPs were all judged on all-hours aggregates).
Parameters allowed if SIMPLE and EX-ANTE.

All-off guard: branch with every switch unset is **bit-identical to a fresh main
build** at the same fork point (GR single-zone + 39-zone EU; the provided
`guard_MAIN_239.tsv` reference was stale and was regenerated).

## Phase 1 — regime cartography

Record = cv27 `multi_zone_eu` (results.duckdb, 2023-01-01..2026-07-27, 39 zones,
1.15M zone-hours). Settled = `entsoe.energy_prices` Day-ahead. Regime axes, all
EX-ANTE from D-1 forecasts:
- solar_share_fc = day-ahead solar forecast / day-ahead load forecast (per zone-hour)
- wind_share_fc  = day-ahead (onshore+offshore) / load
- nuclear avail  = trailing-30d p95 nuclear output / installed (cv23 FR signal)
- hydro state    = reservoir fill vs prior-year same ISO-week (dryness/wetness)
- mix anomaly    = each type's monthly forecast share vs its trailing-year same-month
  climatology (subsumed here by the growing solar_share frequency, Phase-1 table D)

### Error-mass map — dominant axis per zone-group (from the record's error)

| zone-group | error-mass share | dominant axis | regime signature (in-regime) |
|---|---|---|---|
| NORDIC | 43.4% | **reservoir WETNESS** | wet(fill≥1.05 vs prior yr) → +23 bias, 51% of Nordic err mass; dry/normal +3 |
| SEE | 21.1% | solar (but centered) | high-solar bias ~0, phantom 22% already — NOT a floor target |
| CWE (DE_LU,PL,BE,CZ,CH) | 16.4% | **solar_share_fc** | solar≥0.4 → +15 bias, settled≤0 in 28%, model reaches ≤5 only 12–24% |
| ITALY | 12.7% | — | best fit; rarely crashes (settle≤5 5–9%), phantom 35–41% — NOT a target |
| IBERIA | 4.5% | solar (UNDER-prices) | solar≥0.4 → bias −9, hit-rate on crashes 95% already — NOT a floor target |
| FR | 2.0% | **solar_share_fc** | solar≥0.3 → +18 bias, settled≤0 in 50–66%, phantom 0 |

Regime frequency is GROWING with the solar buildout (share of hours with
solar_share≥0.4, per year): CWE 5.1→7.1→8.8→12.4%, SEE 4.2→8.1→10.7→15.8%,
IBERIA 10→14→19→23%, FR 0→0→0.9→0.9% (θ≥0.3: 0.2→10.3%). So a mechanism that is
mild "on average 2023-26" still matters increasingly for 2026+.

FR nuclear cross (owner hypothesis FR = solar × low-nuclear): the +15..+18
solar-overprice holds at ALL nuclear-availability levels (nuc<0.75: +18;
nuc≥0.85: +14). Low nuclear only MILDLY amplifies → **solar_share alone is the
sufficient ex-ante FR gate**; nuclear is a second-order amplifier, not needed as
a separate axis.

### Zone-group → axis → θ mapping (the strategies table)

| zone-group | regime axis | θ (gate) | Phase-2 disposition |
|---|---|---|---|
| CWE (DE_LU,PL,BE,CZ,CH) | solar_share_fc ≥ θ | 0.3 / 0.4 / 0.5 | swept (mechanism A) |
| FR | solar_share_fc ≥ θ | 0.3 | swept (same group) |
| NORDIC | reservoir wetness ≥ 1.05 | — | identified; NOT swept this round (needs an unclamped-wetness signal; follow-up) |
| SEE / IBERIA / ITALY | — | — | not floor targets (Phase-1: balanced / under-prices / rarely crashes) |
NL, AT excluded from the CWE floor group (Phase-1: already produce lows,
false-positive 20–39%).

## Phase 2 — regime-gated price-taker floor (mechanism A)

Gate = ex-ante solar_share_fc ≥ θ on the CONTINENTAL_SOLAR zone set
{DE_LU,FR,PL,BE,CZ,CH}. In regime hours the RES block (BLOCKS=res) — and, with
BLOCKS=full, run-of-river + the deepest must-run block — prices at
DEEP_SURPLUS_FLOOR_EUR = −20. Default-inert (byte-identical to main when off).
One declared parameter: θ.

### Polarity (2-cell multi-zone A/Bs, before scoring)
- **res-only is INERT**: flooring RES alone never moves the clearing price — RES
  stays infra-marginal; the marginal block is thermal/must-run above the floor.
- **full mode bites only on the DEEPEST coupled-surplus days**: 2026-05-01
  (settled −111..−303) PL 14.9→1.1, CZ 5.5→−7.1, DE_LU 18.6→8.1, BE 21.5→11.5
  (correct direction, reaching the −20 floor); near-inert on a moderate surplus
  day (2024-07-14, ~0 dP). Bounded at −20 while settled reaches −100..−300, so it
  only PARTIALLY closes the gap.

### Set-A sweep (regime-stratified, 24 cv27-window days, 22,464 cells/arm)

Within-regime = CONTINENTAL_SOLAR zones {DE_LU,FR,PL,BE,CZ,CH} with
solar_share_fc≥θ, scored vs BASE on the SAME hours. Guards: phantom% =
P(settled>20 | sim≤5); outside ΔMAE = MAE(treat)−MAE(base) on all other
zone-hours; new caps vs base.

| arm | θ | reg_n | base MAE | treat MAE | **dMAE** | base bias | treat bias | phantom% | outside ΔMAE | new caps |
|---|---|---|---|---|---|---|---|---|---|---|
| full_t30 | 0.3 | 602 | 36.26 | 35.38 | **−0.89** | +26.45 | +25.59 | 0.0 | −0.007 | 0 |
| full_t40 | 0.4 | 350 | 43.83 | 42.33 | **−1.50** | +36.20 | +34.70 | 0.0 | −0.017 | 0 |
| full_t50 | 0.5 | 185 | 48.48 | 46.33 | **−2.15** | +43.37 | +41.23 | 0.0 | −0.016 | 0 |
| res_t40 | 0.4 | 350 | 43.83 | 43.72 | −0.10 | +36.20 | — | 0.0 | −0.008 | 0 |

Per-zone within-regime dMAE (full_t40): every zone improves or is neutral —
CZ −16.7 (n=6, noisy), PL −2.57, DE_LU −1.17, BE −1.16, FR −0.16, CH −0.08. No
zone harmed. Base min price = +1 (pinned at the RES floor); full arms reach −20
(genuine negatives). hit-rate on ≤5 hours unchanged (base already ≤20 there; the
gain is getting CLOSER to the deeply-negative settled, not crossing a threshold).

### Verdict
All acceptance guards PASS for the full arms at every θ:
within-regime MAE improves, **phantom rate 0.0** (vs cv28's 18% — the ex-ante
solar gate is what eliminates the phantom lows that killed cv28/cv29),
outside-regime |ΔMAE| ≤ 0.017 (< 0.1), **0 new caps**, no zone harmed. res-only
is inert (RES stays infra-marginal). **Accepted config: BLOCKS=full, θ=0.4**
(Phase-1 signature threshold; −1.50 within-regime MAE). θ=0.5 gives a larger
per-hour gain on fewer/deeper hours; θ=0.3 a smaller gain on more hours (similar
total error mass removed).

### Set-B confirmation (accepted config full_t40, 24 disjoint days, run ONCE)
| set | reg_n | base MAE | treat MAE | dMAE | base bias | treat bias | phantom% | outside ΔMAE | new caps |
|---|---|---|---|---|---|---|---|---|---|
| A | 350 | 43.83 | 42.33 | −1.50 | +36.20 | +34.70 | 0.0 | −0.017 | 0 |
| B | 288 | 34.14 | 33.87 | −0.27 | +23.96 | +23.69 | 0.0 | −0.001 | 6=6 (0 new) |

Out-of-sample holds: within-regime improvement, phantom 0, outside ≈0, no new
caps. The smaller Set-B dMAE reflects shallower surplus on those days (base bias
+24 vs +36) — the gain scales with regime depth, as designed.

### Honest magnitude / root cause
The effect is SAFE and directionally correct but MODEST: base bias in these hours
is +26..+43 (the coupled model heavily overprices deep-surplus hours), and the
floor trims only the MAE-improvement amount. Two structural reasons the floor
cannot fully close the gap: (1) on most regime hours the coupled MARGINAL block
stays a thermal/must-run tranche above the floor, so the price-taker reprice is
inframarginal and does nothing; (2) where it DOES bite, it bottoms at −20 while
settled reaches −100..−300. The large residual is a QUANTITY/commitment issue in
the coupled clear (too much must-run thermal / too little modelled surplus-export
in Europe-wide solar hours), not a bid-price issue — the natural follow-ups are a
demand-scaled or deeper regime floor and the must-run/surplus fix, not this lever
alone.

## Ship recommendation
**SHIP-CANDIDATE (conservative): BLOCKS=full, θ=0.4 on the CONTINENTAL_SOLAR
group.** It clears every acceptance gate on BOTH Set A and Set B with ZERO
collateral damage (phantom 0, outside |ΔMAE|≤0.02, 0 new caps, no zone harmed),
it is fully ex-ante (D-1 solar + load forecast), simple (one axis + one θ per
zone-group), and its relevance GROWS with the solar buildout. Under the owner's
discipline it is never "hurts on average" — it does not hurt at all. The mechanism
is default-inert, so it can ship without disturbing the record until a backfill is
run. Given the modest magnitude, the equally-defensible alternative is to HOLD it
(validated, merged-but-inert) pending the follow-ups below that would make it
materially move the record.

Branch stays UNMERGED (per program rules); this PR carries the results.

### Follow-ups (bigger lever, same regime)
1. Deeper / demand-scaled regime floor: settled reaches −100..−300 while the
   floor bottoms at −20 — a regime floor that scales with surplus depth (still
   ex-ante) would close more of the +26..+43 residual bias.
2. The dominant residual is a COMMITMENT/quantity issue (coupled marginal block
   stays thermal in hours the real Europe-wide-solar market clears deeply
   negative) — the must-run/surplus-export fix is orthogonal and larger.
3. NORDIC reservoir-WETNESS regime (Phase-1: 43% of total error mass, +23 bias in
   wet hours) — identified but not swept; needs an unclamped wetness signal
   (get_reservoir_dryness only exposes dryness≥0). This is the single biggest
   error-mass regime and the natural next target.

## Reproduce
Code: `src/merit_order/book_build.jl` (switch-gated, default-inert). Enable:
```
EUPHEMIA_SOLAR_REGIME=1 EUPHEMIA_SOLAR_REGIME_THETA=0.4 \
EUPHEMIA_SOLAR_REGIME_BLOCKS=full \
EUPHEMIA_SOLAR_REGIME_ZONES=DE_LU,FR,PL,BE,CZ,CH
```
Cartography: `scratchpad/solar_regime/{build_base,analyze1,analyze2_capture,analyze3_zones,analyze4_nuc_hydro}.jl`.
Sweep: `sr_day.jl` + `run_sweep.sh A|B` + `score.jl`. Prereg: `PREREG.md`.
All-off guard bit-identical to fresh main (GR single-zone + 39-zone EU).
