# Per-period decomposition of the coupled clear (the HiGHS-viable option)

The coupled multi-zone market clear (`run_multi_zone_market_clearing`, MPCC in
`src/MPCC.jl`) historically builds **one monolithic MILP** with every period as an
index dimension: `market_price[node, t]`, `flow[pair, t]`, congestion binaries
`congestion_fw_aux/bw_aux[pair, t]`, all over `t in order_book.periods`.

This increment adds a **period-decomposition** solve mode: instead of one large
MILP, solve each period as its own single-period clear and merge the results back
into the same full-day `MPCCResult`. Its purpose is to make **HiGHS a working
choice** for the 39-zone clear — the open-solver half of the public
reproducibility story (open DuckDB extract + HiGHS = fully open, no commercial
license). **Gurobi stays the default and primary solver**; nothing on the Gurobi
path changes.

## Why it is exact — no inter-temporal coupling

The MPCC has **no ramp, storage, block, or t±1 links** — verified across the
model. Every period is a mathematically **independent** clearing problem: the
welfare objective is a plain sum over per-period order acceptances, the nodal
balance is indexed `[node, t]`, and flows/congestion are per period. The
monolithic optimum is therefore *exactly* the concatenation of the per-period
optima, so a per-period solve produces the **same prices** (the duals — the
economic fixed point) as the monolithic solve.

Cross-border **flows** are a degenerate primal (alternative optima on
uncongested links) and need not match — exactly as the repo already documents for
the Postgres↔DuckDB residual. The parity bar is on **prices**.

## How to use

```julia
# Default: Gurobi, monolithic — byte-identical to before.
run_multi_zone_market_clearing(day; zones, order_method=:merit_order,
    enrich_network=true, optimizer="gurobi")

# HiGHS: decomposition auto-enables (monolithic HiGHS can't solve the 39-zone MIP).
run_multi_zone_market_clearing(day; zones, order_method=:merit_order,
    enrich_network=true, optimizer="highs")

# Force either way (overrides the policy):
run_multi_zone_market_clearing(day; ..., optimizer="gurobi", decompose_periods=true)
run_multi_zone_market_clearing(day; ..., optimizer="highs",  decompose_periods=false)
```

## The default policy

`decompose_periods::Union{Nothing,Bool}=nothing` on
`run_multi_zone_market_clearing` resolves as:

| optimizer | `decompose_periods=nothing` (default) | rationale |
|-----------|----------------------------------------|-----------|
| `"gurobi"` / `"auto"` | **monolithic** | byte-identical to the pre-existing path; Gurobi solves the monolith fast |
| `"highs"` | **decomposed** | monolithic HiGHS finds no incumbent on the 39-zone MIP in 20+ min |

An explicit `decompose_periods=true/false` always wins. The policy keys on the
literal string `"highs"`; if you pass `optimizer="auto"` on a machine with no
Gurobi license (so it falls back to HiGHS at solve time), pass
`decompose_periods=true` explicitly.

## Where it lives

- `MPCC.solve_mpcc_market_clearing(...; decompose_periods=false, verbose=true)` —
  when `decompose_periods && length(periods) > 1`, delegates to
  `_solve_mpcc_by_period`. Otherwise the monolithic body runs unchanged. The
  `verbose` flag (default `true`) gates the per-solve flow-setup chatter so the
  many single-period sub-solves stay quiet; the monolithic path's output is
  unchanged.
- `MPCC._solve_mpcc_by_period(order_book; ...)` — the driver. For each period `t`:
  1. Bucket the book's orders by their full-book period assignment
     (`extract_time_period`), so the hourly/timeslot mapping is identical to the
     monolithic grouping.
  2. Build a single-period sub-book: same `nodes`, same `price_limits`, the
     **same** `network_topology` object (the ATC lookup already derives the hour
     from each `YYYYMMDD-HHMM` slot, so it is per-period), and `periods = [t]`.
  3. Solve it via `solve_mpcc_market_clearing(...; decompose_periods=false,
     verbose=false)` — so each period runs the **full retry ladder** (numeric
     focus / different seed / exact indicator-form complementarity for Gurobi),
     letting a single numerically hard period fall back on its own without
     sinking the day.
  4. Merge into one full-day `MPCCResult`.

### Merge semantics

| field | merge |
|-------|-------|
| `market_prices` / `transmission_flows` | union of per-period slices |
| `objective_value` / `solve_time` | summed across periods |
| `stepwise_acceptance` | namespaced `"t::order_id"` (per-solve `order_id`s collide across periods; not load-bearing downstream) |
| `status` | `:optimal` iff **every** period optimal; else the worst observed (`:error` > `:infeasible`/`:unbounded` > `:time_limit`). A period that hits its own time limit but returns an incumbent surfaces as `:time_limit` (usable), matching the monolithic convention |

The result has the **same shape** as the monolithic one, so all downstream code —
DB saving, scoring, and the two-pass opportunity-anchor extraction
(`mz_extract_anchor_inputs`, which reads only `market_prices`) — works unchanged.

## Threading

`decompose_periods` is threaded through the full merit-order coupled path:
`run_multi_zone_market_clearing` → pass-1 `solve_mpcc_market_clearing`, the
`:p95` robustness recursion, and pass-2 `mz_solve_pass`. The two-pass anchor flow
works period-by-period: pass 1 produces per-period reference prices (merged
across the per-period solves), the anchor refs are extracted from those merged
prices exactly as before, and pass 2 re-solves the anchored rebuild — also
decomposed. The pipelined backfill (`src/PipelinedBackfill.jl`) uses Gurobi and
keeps its default `decompose_periods=false` (monolithic), so it is unaffected.

## Measured results

39-zone EU footprint, 2026-04-03, `enrich_network=true`, offline DuckDB extract.
See `test/scripts/test_period_decomposition.jl`.

### Guard 1 — Gurobi monolithic == Gurobi decomposed (bit-exact prices)

| Resolution | Periods | max\|Δλ\| (€/MWh) | cells | Gurobi mono | Gurobi decomp |
|-----------|---------|-------------------|-------|-------------|---------------|
| 60-min | 24 | **0.0** | 936 (39×24) | 15.3–15.6 s | 7.0 s |
| 15-min | 96 | **0.0** | 3744 (39×96) | 53.3 s | 28.9 s |

Bit-exact prices, as the independence proof requires. Decomposed Gurobi also ran
*faster* than the monolith at both resolutions (many small MIPs beat one big one).

### Guard 2 — HiGHS decomposed solves the full 39-zone day

Where monolithic HiGHS finds **no incumbent** (time_limit, 0 zones priced), the
decomposed HiGHS clear prices **all 39 zones, all periods**:

| Resolution | Periods | HiGHS status | zones priced | wall time | MAE vs Gurobi | max\|Δ\| vs Gurobi |
|-----------|---------|--------------|--------------|-----------|---------------|--------------------|
| 60-min | 24 | optimal | **39/39** (936/936 cells) | 511 s | **0.0000** | **0.0000** €/MWh |
| 15-min | 96 | optimal | **39/39** (3744/3744 cells) | 1500 s | 0.0068 | 4.24 €/MWh |

**The decisive result: yes — the 39-zone clear now runs end-to-end on HiGHS with
no Gurobi license.** Where monolithic HiGHS never finds a first incumbent (20+ min,
0 zones priced), decomposed HiGHS solves every period to optimality and prices all
39 zones. At 60-min it reproduces the Gurobi prices **bit-identically** (MAE and
max\|Δ\| both 0.0). At 15-min the average error is 0.0068 €/MWh with a 4.24 €/MWh
max on a handful of near-degenerate quarter-hour periods — MIP alternative optima
on the congestion binaries feeding the price reconstruction (the LP-relaxation
duals are otherwise identical); reported honestly rather than hidden.

HiGHS-decomposed is much slower than Gurobi (511 s vs 7 s at 60-min; 1500 s vs
29 s at 15-min) — the accepted cost of the open-solver option, and today
sequential (the per-period parallelism deferred below would cut it hard). The
15-min HiGHS wall time overlapped a concurrent core-test run and is a mild
over-estimate.

## What's done vs deferred

**Done:**
- `decompose_periods` policy + kwarg on the coupled merit-order path, threaded
  through both passes and the `:p95` recursion.
- `_solve_mpcc_by_period` driver reusing the exact monolithic per-period solve
  (same retry ladder, same price reconstruction).
- Guards 1 & 2 at 60-min and 15-min in
  `test/scripts/test_period_decomposition.jl`.

**Deferred:**
- **Parallel per-period solves.** The decomposition is embarrassingly parallel
  (independent MILPs); today they run sequentially. Distributing the period loop
  across workers would recover — and beat — the monolithic wall time on HiGHS.
- Single-zone / `:uc_based` / `:alternative` paths (this is coupled merit-order,
  matching the 15-min increment's scope).
