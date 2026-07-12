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
