# GR valley BLOCK-ORDER pilot — true fill-or-kill blocks vs the hourly projection (2026-08)

**Status: measured, pilot complete.** The recorded structural alternative from
the prereg's block-order-equivalence amendment
([prereg-2026-08.md](prereg-2026-08.md)): clear the GR single-zone book as a
per-day MIP with TRUE multi-hour fill-or-kill block orders (endogenous
acceptance, Gurobi) and compare against the shipped hourly-projection lever
(`EUPHEMIA_ENABLE_GRSQ_T2`).

**Headline: the block-MIP reproduces the hourly projection EXACTLY on all five
pilot days — max |Δprice| ≤ 0.005 €/MWh (LP-tie noise), every block accepted,
zero paradoxically-accepted rejections needed.** With the block limit at the
declared floor (−20 €/MWh, the deepest price in the book), acceptance is
never loss-making, so the endogenous test is degenerate by construction — the
prereg's equivalence claim holds not just "when the trailing evidence says the
block would be accepted" but on every day this book shape can produce.

## Method

Script: [`block_order_pilot.jl`](block_order_pilot.jl) (driver, arms a–c) +
[`block_order_mip.jl`](block_order_mip.jl) (the Gurobi MIP; loaded ONLY under
`EUPHEMIA_ENABLE_GRSQ_BLOCKS` — see "Integration contract" below). Offline
extract (`euphemia-live.duckdb`), 15-min GR book, in-process arms:

- **settled** — `entsoe.energy_prices` GR Day-ahead, hourly mean of 15-min slots;
- **base** — engine `:merit_order` clear, all GRSQ switches off, tagged book
  captured via the strategist hook (identity pass-through);
- **projection** — engine clear with `EUPHEMIA_ENABLE_GRSQ_T2=1` (lever 2);
- **block-MIP** — from the captured BASE book: for each overnight runner
  (`_valley_continuation_commits`, same ex-ante test as the lever) remove its
  cheapest committed MW from every valley period (04–13 UTC, day-ahead solar
  share ≥ 0.25 — the lever's gate, replicated exactly) and offer that energy
  as ONE fill-or-kill block (single binary; quantity = committed MW in every
  valley period; limit −20 €/MWh). Clear as welfare-max MIP (hourly orders
  divisible, Gurobi, MIPGap 1e-9), then EUPHEMIA-style price formation: fix
  binaries → LP → balance duals as prices → force-reject any accepted block
  with volume-weighted average price < limit (PAB) → re-solve to fixpoint.
  Paradoxically REJECTED blocks allowed, as in real EUPHEMIA.

**Reconstruction validity (sanity arm):** the same LP on the UNMODIFIED book
reproduces the engine's own base prices to max |Δ| ≤ 0.005 €/MWh on all
5 × 96 periods (0 periods off by > 0.01) — the comparison platform is faithful.

## Results

Valley-hour prices (€/MWh; hourly means of the 15-min book):

| day | hr | settled | base | projection | block-MIP |
|---|---|---|---|---|---|
| 2026-02-23 | 06 | 0.00 | 87.51 | 81.37 | 81.37 |
| 2026-02-23 | 07 | 0.00 | 63.52 | 33.90 | 33.90 |
| 2026-02-23 | 08 | −2.39 | 4.28 | 1.00 | 1.00 |
| 2026-02-23 | 09 | −10.38 | 1.00 | 1.00 | 1.00 |
| 2026-02-23 | 10 | −23.73 | 1.00 | 1.00 | 1.00 |
| 2026-02-23 | 11 | −25.00 | 1.00 | 1.00 | 1.00 |
| 2026-02-23 | 12 | −21.15 | 1.82 | 1.00 | 1.00 |
| 2026-02-23 | 13 | −1.02 | 24.97 | 2.64 | 2.64 |
| 2026-02-24 | 06 | 106.30 | 131.80 | 131.80 | 131.80 |
| 2026-02-24 | 07 | 0.01 | 86.26 | 80.41 | 80.41 |
| 2026-02-24 | 08 | 0.00 | 62.53 | 43.48 | 43.48 |
| 2026-02-24 | 09 | 0.00 | 14.34 | 1.81 | 1.81 |
| 2026-02-24 | 10 | 0.00 | 4.23 | 1.00 | 1.00 |
| 2026-02-24 | 11 | 0.00 | 4.23 | 1.00 | 1.00 |
| 2026-02-24 | 12 | 0.00 | 4.23 | 1.00 | 1.00 |
| 2026-02-24 | 13 | 0.00 | 34.55 | 13.53 | 13.53 |
| 2026-03-29 | 06 | 107.23 | 102.12 | 23.84 | 23.84 |
| 2026-03-29 | 07 | 0.00 | 45.76 | 1.00 | 1.00 |
| 2026-03-29 | 08 | 0.00 | 6.26 | 1.00 | 1.00 |
| 2026-03-29 | 09 | 0.00 | 1.00 | 1.00 | 1.00 |
| 2026-03-29 | 10 | 0.00 | 1.00 | 1.00 | 1.00 |
| 2026-03-29 | 11 | 0.00 | 5.66 | 1.00 | 1.00 |
| 2026-03-29 | 12 | 0.01 | 6.26 | 1.00 | 1.00 |
| 2026-03-29 | 13 | 0.33 | 22.01 | 1.00 | 1.00 |
| 2026-04-29 | 05 | 127.60 | 114.54 | 114.54 | 114.54 |
| 2026-04-29 | 06 | 70.24 | 84.60 | 69.12 | 69.12 |
| 2026-04-29 | 07 | 0.00 | 5.22 | 1.00 | 1.00 |
| 2026-04-29 | 08–12 | ≈0.00 | 1.00 | 1.00 | 1.00 |
| 2026-04-29 | 13 | 0.00 | 4.27 | 1.00 | 1.00 |
| 2026-05-05 | 05 | 121.60 | 130.32 | 130.32 | 130.31 |
| 2026-05-05 | 06 | 23.74 | 65.66 | 46.38 | 46.39 |
| 2026-05-05 | 07 | −0.01 | 2.15 | 1.00 | 1.00 |
| 2026-05-05 | 08–12 | 0.00 | 1.00 | 1.00 | 1.00 |
| 2026-05-05 | 13 | 0.00 | 1.46 | 1.00 | 1.00 |

Valley-hour MAE vs settled (€/MWh):

| day | base | projection | block-MIP | n |
|---|---|---|---|---|
| 2026-02-23 | 33.60 | 25.82 | 25.82 | 8 |
| 2026-02-24 | 29.48 | 20.97 | 20.97 | 8 |
| 2026-03-29 | 11.59 | 11.26 | 11.26 | 8 |
| 2026-04-29 | 4.66 | 2.35 | 2.35 | 9 |
| 2026-05-05 | 6.58 | 4.26 | 4.26 | 9 |

Per-day mechanics (all days: **1 PAB iteration, 0 forced rejections, 0
paradoxically rejected**):

| day | runners | committed MW | blocks | accepted | MIP s | LP s | gap |
|---|---|---|---|---|---|---|---|
| 2026-02-23 | 8 | 1,542 | 8 | 8 | 0.07 | 0.72¹ | 0 |
| 2026-02-24 | 7 | 1,524 | 7 | 7 | 0.05 | 0.01 | 1.4e-15 |
| 2026-03-29 | 9 | 2,427 | 9 | 9 | 0.10 | 0.01 | 0 |
| 2026-04-29 | 7 | 1,340 | 7 | 7 | 0.05 | 0.01 | 0 |
| 2026-05-05 | 6 | 1,035 | 6 | 6 | 0.05 | 0.01 | 0 |

¹ first solve carries the Gurobi env warm-up.

Block vs projection divergence: **max |Δ| ≤ 0.005 €/MWh** on every day, valley
and all-hours alike (LP degenerate-tie noise at the crossing; e.g. 05-05 hr05
130.32 vs 130.31 after hourly averaging).

## Why the equivalence is structural, not coincidental

The block limit is the declared floor (−20 €/MWh), and **no order in the GR
book is priced below −20** — so clearing prices are bounded below by −20 and a
supply block at that limit can never be loss-making. Acceptance is therefore
always weakly welfare-improving: the MIP accepts every block, the PAB test can
never fire, and the fill-or-kill constraint never binds. The projection's
divisible −20 tranches are likewise always fully accepted whenever the price
clears above −20. The two mechanisms can only diverge in hours priced exactly
at/below the floor (partial vs forced-full acceptance of the marginal MW) —
which the duals show never moves the price. **Endogenous acceptance with
limit = floor is degenerate on this book by construction, on any day.**

Two honest corollaries:

1. **No over-collapse protection.** On 2026-03-29 hr 06 the projection
   collapses an hour that actually settled HIGH (base 102.1 → proj 23.8,
   settled 107.2 — a −83 €/MWh error the base book did not have). The
   block-MIP does NOT avoid this: with a −20 limit the block is profitable at
   23.8 just as at 102, so it is accepted and produces the identical collapse.
   Guarding against this failure mode needs a *higher* limit price encoding
   real cycling economics (e.g. SRMC minus amortized start cost over the
   valley), not endogenous acceptance per se — with such a limit the
   fill-or-kill machinery would genuinely adjudicate acceptance, at the cost
   of a new declared parameter.
2. **The remaining depth deficit is lever 1's, not lever 2's.** In the deep
   hours (02-23 09–12 UTC settled −10..−25) both arms bottom at 1.00 — the
   book's RES-block price — because GR has no negative-price capability
   without the lever-1 floor. Blocks do not change that; the two levers stay
   orthogonal exactly as the prereg frames them.

## Solve-time reality

Per-day MIP+LP: **≈ 0.06–0.12 s** after env warm-up (≈ 5,600 hourly orders,
96 balance rows, ≤ 9 binaries; MIPGap 1e-9 closed to 0 in one node). A
year-scale backfill of the block clearing is computationally trivial (< 1 min
of solver time per year-zone); the cost is architectural (a per-day MIP joint
clear replacing 96 independent intersections, plus the Gurobi dependency),
not computational.

## Implementation notes / traps (price formation with blocks)

- **Dual scaling.** With the objective in € (order value × period length w_p)
  and MW balance rows, the balance dual is w_p × price — on the 15-min book
  the raw duals are exactly 4× too small. Divide by w_p. (Found by the sanity
  arm: "prices" of 0.25 where the engine said 1.00.)
- **Dual sign.** JuMP's dual sign for `==` rows under a Max objective is
  convention-dependent; the pilot auto-detects it against the engine's own
  base prices (sanity arm) and feeds it to the PAB test (`DUAL_SIGN`).
- **Compare per-slot, not per-hour.** An hourly-mean comparison inflated the
  sanity gap to 20.7 €/MWh purely from within-hour ramps on the 15-min book;
  per-slot the true reconstruction error is ≤ 0.005 €/MWh.
- **PAB loop semantics.** Force-rejecting a PAB keeps the unit's committed MW
  OUT of the market (fill-or-kill reality — the hourly MW were removed when
  the block was built); the projection instead always leaves the MW available
  per-hour at the floor. This is exactly where the two mechanisms would
  diverge — the loop never fired on these days (see above).
- Degeneracy: block acceptance was never marginal (no fractional LP z after
  fixing, gap 0), so no multiple-optima ambiguity in acceptance; price-side
  ties are the usual crossing degeneracy, ≤ 0.005 €/MWh here.

## Recommendation

**Do not pursue the block-MIP as a shipping mechanism at this floor design.**
It is price-identical to the shipped hourly projection on all five anatomy
days — and structurally must be, as long as the block limit equals the book's
deepest price. The projection delivers the same numbers with 96 independent
hourly intersections, no binaries, and no solver-vendor constraint. The
block machinery becomes worth revisiting only if (a) the limit is re-derived
from real cycling economics (start-cost amortization → limits ABOVE the
floor, giving endogenous acceptance real work to do — also the only route to
over-collapse protection, cf. 03-29 hr 06), or (b) lever 1 introduces prices
below the block limit into the GR book.

### Integration contract (owner directive, 2026-08)

- The block-order path is **Gurobi-gated and opt-in**: nothing block-related
  runs unless `EUPHEMIA_ENABLE_GRSQ_BLOCKS` is set (the pilot script loads
  JuMP/Gurobi and builds blocks only under the switch; unset ⇒ arms a–c only).
- If this ever lands in src it ships **default-OFF behind
  `EUPHEMIA_ENABLE_GRSQ_BLOCKS` and requires `optimizer="gurobi"`**, never
  touching the canonical HiGHS record path (house convention since cv20:
  Gurobi is the development option, HiGHS is the record path).
- **The projection lever (`EUPHEMIA_ENABLE_GRSQ_T2`) remains the
  HiGHS-compatible default candidate**; the block-MIP is the Gurobi-gated
  structural alternative, measured here as equivalent.

## Reproduction

```bash
EUPHEMIA_ENABLE_GRSQ_BLOCKS=1 julia --project=. \
    docs/experiments/gr-surplus-quantity/block_order_pilot.jl
# PILOT_DAYS=... PILOT_OUT=... to override; unset EUPHEMIA_ENABLE_GRSQ_BLOCKS
# to run the settled/base/projection arms only (no JuMP/Gurobi loaded).
```

Extract: `data/extracts/euphemia-live.duckdb` (read-only). Outputs:
`block_pilot_prices.csv` / `block_pilot_blocks.csv` / `block_pilot_diag.csv`
in `PILOT_OUT`.
