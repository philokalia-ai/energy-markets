# Bidding as factories with buildup/builddown — investigation

**Question.** Big thermal plants don't bid independent per-hour price/quantity
points. If we model them as factories with **buildup/builddown** (inter-temporal
constraints), does the counterfactual get closer to the truth? Accepting it's
Gurobi-only.

## 1. Where we are today

`MarketOrders.jl` already *defines* the full EUPHEMIA taxonomy — `BlockOrder`,
`LinkedBlockOrder`, `ExclusiveBlockOrder`, `LoadGradientOrder` (the ramp/gradient
condition), `MICOrder` (minimum income) — but they are **stubs**: each carries a
single price/quantity and one scalar constraint, **no multi-period profile**, and
**the MPCC only clears `SimpleOrder`** (`if isa(order, SimpleOrder)`). So the
clearing is per-period-independent, which is exactly why it decomposes cleanly
(and why HiGHS can solve it per-period).

The current merit book *approximates* one inter-temporal effect statically: the
**must-run split** bids a thermal unit's deepest 60% of p_min at 5%·SRMC so it
"wants to stay on." That's a fixed heuristic, not an endogenous decision.

## 2. Where per-period clearing diverges from reality — three mechanisms

1. **Self-commitment through the midday trough.** A CCGT that will run the
   evening peak stays online at min-load through cheap solar hours, because
   shutting down + restarting costs more (startup + min-downtime) than eating the
   midday loss. Per-period clearing shuts it and lets the cheapest unit set the
   price → **midday collapses far below reality**. Driver: **startup cost /
   min-uptime — i.e. COMMITMENT**, not ramp.
2. **Ramp-limited transitions.** Morning demand rises faster than plants can
   ramp → transient scarcity → price spike (and the mirror at evening ramp-down).
   Per-period clearing lets any unit jump 0→full → no ramp-driven spikes.
3. **Startup-cost recovery / all-or-nothing.** A peaker running 3 evening hours
   needs those prices to cover its startup; it bids a **block** accepted whole or
   not. Per-period clearing can partially accept → uneconomic dispatch.

## 3. Prototype evidence (GR, 2026-04-03) — ramp alone is the *smaller* lever

A pure marginal-cost economic dispatch (perfect-competition benchmark; price =
dual of the hourly balance), solved **with** vs **without** inter-temporal ramp
constraints. Ramp constraints are linear → the dispatch stays an LP with clean
duals (no pricing pathology yet).

| model | corr vs actual | MAE |
|---|---|---|
| ED per-period (flat) | 0.743 | 44.2 |
| ED + ramp (buildup/builddown) | **0.762** | 46.9 |

**Ramp coupling helps correlation only marginally (+0.02) and does not fix the
level.** The dominant error is the **midday collapse**: the pure ED prices hours
08–13 at ~€12 (cheapest unit) while the actual holds ~€95–105. Ramp doesn't stop
it — a cheap unit can ramp down and back up. **What holds midday prices up is
COMMITMENT** (units staying on to avoid startup), which ramp alone can't express.

Corollary: the merit book's existing static must-run split is already a proxy for
exactly this commitment effect — which is why the production model (with must-run)
doesn't show the €12 midday hole the pure ED does.

## 4. So the real lever is COMMITMENT / blocks, and ramp is a refinement

Two ways to model it, both inter-temporal (Gurobi-only):

**A. Block orders (faithful to how the market actually works).** Each unit (or its
startup-sensitive portion) submits a fixed per-period **profile** over a range,
accepted all-or-nothing via a binary `x∈{0,1}`, with a minimum-income/acceptance
condition. Buildup/builddown lives in the **profile shape** (e.g. 30/70/100/100/
70/30%). This is EUPHEMIA's real mechanism; smaller than full UC (one binary per
block).

**B. Integrated UC-constrained economic dispatch (the physical ideal).** Embed
commitment `u[g,t]`, startup `v[g,t]`, min output when on, min up/down, ramp, and
startup/no-load costs directly in the coupled clear; price = dual of balance.
This is the theoretically-correct **competitive counterfactual** — a social
planner respecting physics — and the residual vs actual is the cleanest
market-power signal. The project already has this machinery in
`UnitCommitment.jl` (today used only in the separate `:uc_based` bid-conversion,
not in the clear).

## 5. The catch both approaches share — non-convex pricing

With integer commitment/blocks the LP dual is undefined (integrality). Day-ahead
markets resolve this with a specific rule; the standard, tractable one is
**fix-and-reprice**: solve the MILP, **fix the binaries**, re-solve the LP →
the balance dual is the price (a plant on min-load may then be marginal, which is
what supports the midday price). Convex-hull (Gribik) pricing is the fancier
alternative. This is a real design decision, not a detail.

## 6. Tractability (Gurobi-only, accepted)

- Inter-temporal coupling **breaks the per-period decomposition** and HiGHS
  viability — this is Gurobi-only by nature, as expected.
- Single-zone GR (~33 dispatchable units × 24 h) with commitment binaries is
  easy. A few coupled zones (SEE) is fine. The **full 39-zone UC-in-clearing** is
  a large MILP and may need a gap/time-limit or block-orders (Approach A, fewer
  binaries) rather than full UC.

## 6b. Mini-UC with fix-and-reprice (GR, 2026-04-03) — the decisive test

Built the full experiment: commitment MILP (startup cost, no-load, min-output when
on, ramp, min-uptime) → fix `u*` → re-solve LP → price = balance dual. Hydro/
storage priced at **water value** (0.85·gas SRMC) so midday isn't an artefact of
hydro's ~zero variable cost — this isolates the *commitment* effect on a realistic
cost stack. Compared against a clean per-period merit dispatch with the **same
water-valued costs**.

| model | corr vs actual | MAE |
|---|---|---|
| per-period merit (same costs) | **0.884** | **22.7** |
| mini-UC (commitment + fix-and-reprice) | 0.747 | 23.4 |

**Commitment does NOT bring GR closer — it's slightly worse.** Two findings:

1. **The midday support was never about commitment — it's the water value.** Once
   hydro bids its opportunity cost (~€100) instead of €12, the *per-period* clear
   already holds midday at ~€100, matching actual. The €12 collapse in §3 was a
   cost-stack artefact, not a missing inter-temporal mechanism.
2. **Commitment's min-load / min-uptime constraints mildly *distort* the marginal
   price** (forcing units on at min-load flattens the shoulders), costing
   correlation (0.88→0.75). Its one win is the **evening peak**: the mini-UC
   spikes hour 17 to €154 (vs per-period €118, actual €175) — startup dynamics do
   help *at the peak* — but it loses more on the shoulders than it gains there.

**Interpretation.** For GR the price shape is governed by the **cost stack**
(above all the hydro water value), which the per-period clear already captures at
corr 0.88. Time-coupling is second-order and net-negative here. The residual
(actual peak €175 vs model €118) is the **market-power signal** — the competitive
counterfactual is *supposed* to sit below it.

**Caveats (why this isn't the last word):** one day, one **hydro-dominated** zone,
a mild spring day. Commitment should matter more where it's actually binding:
thermal-**cycling** zones (DE/PL) and **tight/peaky** days with real startups.

## 6c. Confirming test — DE_LU (thermal), 2025-12-15 winter: it FLIPS

Same mini-UC on Germany, a thermal-cycling zone on a tight winter day. Caveat: my
raw fleet (142 recently-active units) undercounts DE installed capacity (the known
DE gap the production model fixes with `fleet_truth_mode=:installed`), so both
models hit the VOLL shortage floor at the 15:00–17:00 peak — a capacity artefact,
not the mechanism. Excluding those 3 hours to isolate commitment:

| model | corr vs actual | MAE |
|---|---|---|
| per-period merit | 0.831 | 21.3 |
| mini-UC (commitment + reprice) | **0.870** | **14.8** |

**For DE, commitment HELPS — MAE −30% (21.3→14.8), corr +0.04.** The mini-UC
captures the **overnight dip** (€69.7 vs actual €67; per-period sits flat at €82)
and pulls midday toward reality, because DE's coal/gas/lignite plants genuinely
stay committed through the troughs and cycle for the peak — which per-period
clearing structurally cannot represent. Opposite sign to GR.

**The result is therefore ZONE-DEPENDENT:**

| zone class | example | commitment effect |
|---|---|---|
| hydro / water-value-set | GR, Nordics, SEE | **none / slightly worse** (cost stack already captures it) |
| thermal-cycling | DE_LU, PL, CZ, continental | **materially better** (−30% MAE on the test day) |

## 7. Recommendation (revised after both mini-UC tests)

1. **It's zone-dependent, so build it selectively — not globally.** Adding
   commitment as a **Gurobi-only refinement for the thermal-cycling continental
   zones** (DE_LU, PL, CZ, and likely the tight/peaky continental core) is
   justified: −30% MAE on the DE test day. For hydro/water-value zones (GR,
   Nordics, SEE — our primary product) it does nothing or slightly hurts, so leave
   `:merit_order` per-period there.
2. **Prerequisite for DE: fix the fleet capacity first.** The DE test was
   confounded by the installed-capacity undercount (VOLL shortage at peak). Any
   real DE commitment model must run on the `:installed`-truthed fleet, or the
   shortage artefact swamps the commitment gain.
3. **Build it as first-class block orders** (binary acceptance + per-period
   profile) with **fix-and-reprice** pricing — smaller and cleaner than embedding
   a full UC per zone, and it's the actual market mechanism.
4. For GR/SEE specifically: the lever is the **cost stack** (water value), which
   per-period already captures at corr 0.88. Spend effort on the peak-hour
   residual (the market-power signal) and costs, not inter-temporal machinery.

**Bottom line:** the honest answer is **"it depends on the zone."** Bidding
factories with buildup/builddown does NOT help hydro-dominated Greece (per-period
+ correct costs already wins), but it DOES help thermal-cycling Germany (−30% MAE),
where plants genuinely cycle and per-period clearing can't represent it. So it's a
targeted continental-thermal refinement, Gurobi-only, gated behind a fleet-capacity
fix — not a global rewrite.

## 8. The clean isolation — commitment-informed must-run (v17, `must_run_mode=:endogenous`)

The 16-zone block-commitment canary (v17_block_canary.jl) showed
`:block_commitment` losing to the calibrated merit book essentially everywhere.
REVIEW VERDICT on that test: it swapped TWO things at once — it stripped the
calibrated bidding layer (tranche ladder, scarcity factor, must-run split) AND
changed the clearing mechanism, so "commitment loses" and "the calibration is
doing the work" were confounded.

**The isolation.** Keep the ENTIRE calibrated merit book and change exactly ONE
variable: WHICH units self-schedule their p_min, per hour. Today's static rule
picks a day-level set (cheapest thermal with SRMC ≤ 1.15×gas until capacity ≥
1.05× peak residual — the same set in every timeslot). The new
`must_run_mode = :endogenous` (a `ZoneProfile` field + `create_merit_order_book`
kwarg) instead solves the BlockCommitment MILP on the book's exact fundamentals
— same fleet, same costs, same net demand — **anchored to real initial
conditions** (`get_initial_conditions`, 72 h lookback: u₀/g₀ enter the t=1
startup and ramp constraints, and units already running serve out their
remaining min-uptime; this closes the known free-hour-1 gap). A unit
self-schedules its must-run split in slot *ts* iff u\*[unit, hour(ts)] = 1;
uncommitted capacity still offers through the normal tranche ladder. Everything
else — tranche ladder, scarcity factor, water values, demand, RES, imports, the
must-run PRICE split itself — is byte-identical. Any MILP failure warns and
falls back to `:static` (the clear never breaks).

**Guards.** `:static` (the default) verified bit-identical in price on GR
2026-01-14, DE_LU 2026-04-15, NO2 2026-06-15 (orders bit-identical except NO2
quantity jitter ≤ 9.1e-13 MW — the documented last-ULP SQL-aggregate
non-determinism, present on unmodified code too). All 46 MILPs solved OPTIMAL
in ≤ ~2 s; zero fallbacks.

### Canary (same 16 zones × 3 days, single-zone, same decision rule)

Per-zone 3-day average, static vs endogenous committed set (improve = MAE
−≥1 €/MWh AND corr not dropped). Harness:
test/scripts/v17_endogenous_mustrun_canary.jl.

| zone | s_corr | s_MAE | e_corr | e_MAE | ΔMAE | Δcorr | improves | mean Jaccard |
|---|---|---|---|---|---|---|---|---|
| GR | 0.896 | 44.9 | 0.783 | 40.6 | +4.3 | −0.113 | no | 0.53 |
| BG | 0.513 | 464.4 | 0.511 | 463.9 | +0.5 | −0.003 | no | 0.67 |
| RS | 0.671 | 64.1 | 0.645 | 48.6 | +15.5 | −0.026 | no | 0.46 |
| RO | 0.715 | 78.6 | 0.693 | 73.6 | +5.1 | −0.022 | no | 0.47 |
| DE_LU | 0.939 | 28.5 | 0.928 | 28.8 | −0.3 | −0.011 | no | 0.39 |
| PL² | 0.838 | 22.5 | 0.735 | 17.5 | +5.0 | −0.103 | no | 0.32 |
| CZ | 0.824 | 19.5 | 0.837 | 16.5 | +3.0 | +0.013 | **YES** | 0.47 |
| NL | 0.582 | 26.2 | 0.590 | 29.6 | −3.5 | +0.009 | no | 0.32 |
| FR | 0.849 | 25.7 | 0.870 | 24.8 | +0.9 | +0.021 | no | 0.79 |
| ES² | 0.920 | 23.8 | 0.900 | 28.2 | −4.4 | −0.020 | no | 0.67 |
| PT | 0.908 | 23.4 | 0.937 | 19.7 | +3.7 | +0.028 | **YES** | 0.52 |
| IT-NORTH¹ | 0.780 | 29.0 | 0.713 | 25.1 | +3.8 | −0.068 | no | 0.03 |
| FI | 0.697 | 25.8 | 0.781 | 26.1 | −0.3 | +0.084 | no | 0.30 |
| NO2¹ | 0.778 | 469.3 | 0.778 | 469.3 | 0.0 | 0.000 | no | 1.00 |
| AT³ | 0.599 | 183.7 | 0.616 | 178.8 | +4.8 | +0.017 | **YES** | 0.27 |
| SK³ | 0.657 | 110.7 | 0.679 | 101.1 | +9.6 | +0.022 | **YES** | 0.77 |

Aggregate: static mean MAE 102.5 / corr 0.76 → endogenous 99.5 / 0.75.
**Improving zones under the rule: CZ, PT, AT, SK** (4/14 usable — BG's
baseline is broken in both arms, NO2 is inert by construction; FR misses the
gate by −0.9 MAE despite corr +0.021).

¹ NO2 has zero must-run-eligible units (all hydro) → the two arms are
identical by construction. IT-NORTH's STATIC set is empty on all three days
(the Italy SRMC multiplier pushes every thermal unit above the 1.15×gas
eligibility threshold), so there the experiment measures turning must-run ON,
not re-timing it.
² PL and ES 2026-06-15 excluded: the static book build itself fails on those
days with a pre-existing Missing→Float64 data error (shared harness; both
arms affected equally).
³ Baseline trust: see the spot-check below — AT/SK/BG/NO2 baselines are
dominated by single-zone scarcity-cap artifacts, so their verdicts carry
little weight. The trustworthy improvements are **CZ (19.5→16.5)** and
**PT (23.4→19.7)**.

### Committed-set overlap (sanity)

On the mild April day the endogenous set is broadly a SUBSET of the static set
(Jaccard 0.30–0.84; e.g. GR 6.0 vs 15 units, CZ 12.5 vs 27, SK 8.6 vs 13):
the MILP simply de-commits units the peak-sized static rule kept on — sensible,
not a cost mismatch. Winter days flip in the tight zones: the MILP commits MORE
than the static rule allows (BG 18.9 vs 5, PL 52.1 vs 11, RO 15.8 vs 8),
because static's SRMC ≤ 1.15×gas eligibility cap excludes the expensive units
that really do run on a tight day. Outliers (NL/DE_LU June, Jaccard ~0.03–0.05:
near-total de-commitment in RES-heavy summer) are where the endogenous arm lost
the most correlation.

### KEY FINDING — the commitment signal is real but SEASONAL

Splitting the same runs by day instead of by zone: on the **winter day
(2026-01-14), 11 of 14 usable zones improve MAE** (RS −42.3, AT −11.2,
RO −9.0, GR −7.1, PT −6.9, IT-NORTH −4.5, PL −4.3, CZ −3.5, DE_LU −3.4 …)
with correlation held or up in most — exactly the conditions where thermal
genuinely cycles and hour-by-hour commitment carries information the static
peak-sized set cannot. The **summer day broadly hurts** (GR +16.2, NL +10.9,
DE_LU +8.7): in RES-dominated conditions the MILP de-commits almost the whole
must-run set (the Jaccard ~0.03–0.05 outliers above) and the resulting trough
re-pricing distorts the daily shape. So endogenous commitment information is
REAL, but conditionally so — it helps when the system is tight/thermal-cycling
and misleads when RES sets the shape.

### Baseline spot-check — BG 2026-01-14 (and what AT/SK/NO2 numbers mean)

The anomalous merit baselines (BG 464, NO2 469, AT 184, SK 111) are **model
artifacts of single-zone clearing, not harness artifacts**. BG 2026-01-14
verified directly: the actuals are clean (one EUR sequence, 96 PT15M rows,
day-avg €189 — a genuinely expensive winter day region-wide: RO €189/max 393,
HU €182/max 346), but the single-zone sim prices hours 15–18 at the €3000 cap
(phantom scarcity, supply/demand ratio 1.15 with no coupled imports at the
peak) vs actual ~€250–283; those 4 cap-hours alone contribute ~€457 of the
~€495 MAE. Off the cap episode the sim tracks actuals to ±€30–120. Both arms
share the artifact, but per-zone verdicts on these zones are dominated by
whether the committed set happens to shift a cap hour — hence footnote ³.

### Verdict

**Per the decision rule, only 4/14 usable zones improve (2 on trustworthy
baselines: CZ 19.5→16.5, PT 23.4→19.7) — so NO blanket full-year backfill.**
With the confound removed, the clean one-variable swap yields aggregate MAE
−3 €/MWh (on 102.5, mostly artifact zones) at mean correlation −0.01, and the
zone-level losses are real: GR (−0.113), PL (−0.103) and IT-NORTH (−0.068)
lose correlation to the same shoulder-flattening distortion §6b found. The
mechanism is now understood, not just scored: endogenous commitment lowers MAE
by de-committing must-run in trough hours (prices rise toward SRMC where static
under-priced), but that same re-timing distorts the daily shape — and whether
it helps is SEASONAL, not zonal (winter 11/14 better, summer broadly worse).
The static day-level heuristic — crude as it is — is calibrated WITH the rest
of the book, and the MILP's unconditionally-"better" commitment is not better
for prices.

**The unconditional temporal-orders question is closed with a clean
methodology**: neither the mechanism swap (§6b–6c, block canary) nor the
committed-set-only swap (§8) beats the calibrated per-period book as a
default. **The promising follow-up is a winter/tight-day-GATED endogenous
must-run** (the lever is cheap: a per-zone-day 1–2 s Gurobi MILP behind a
`ZoneProfile` field, with a guaranteed `:static` fallback), best tested next
on the frozen 36-day stratified sample before committing to any 365-day run.
