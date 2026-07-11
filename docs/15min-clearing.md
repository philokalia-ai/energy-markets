# 15-minute-resolution coupled multi-zone clear (Increment 1)

The coupled multi-zone market clear historically ran at **hourly** resolution
(24 periods/day). This increment adds an opt-in **15-minute** mode
(96 periods/day) to `run_multi_zone_market_clearing` on the `:merit_order` path,
kept as a single **monolithic** MPCC solve for now.

## How to use

```julia
# hourly (default) — byte-identical to the previous behaviour
run_multi_zone_market_clearing(day; zones, order_method=:merit_order,
    enrich_network=true, clear_resolution_minutes=60)

# 15-minute coupled clear (96 periods)
run_multi_zone_market_clearing(day; zones, order_method=:merit_order,
    enrich_network=true, optimizer="gurobi", clear_resolution_minutes=15)
```

`clear_resolution_minutes` (default `60`) threads through the whole merit-order
book build: `run_multi_zone_market_clearing` → `_create_multi_zone_order_book_merit`
→ each zone's `create_merit_order_book(...; target_resolution_minutes=…)`. The
exposed stages `mz_build_books` / `mz_rebuild_anchored` and the two-pass
opportunity-anchor rebuild carry it too, so every zone in a clear shares the same
period grid.

## The resolution rule: REPLICATE, never divide

All zones in one clear share a single 96-slot 15-min grid
(`YYYYMMDD-HHMM` at `:00/:15/:30/:45`). Each zone's native input is mapped onto
that grid:

- **Native 15-min zone (PT15M):** use the quarter-hourly values as-is.
- **Native 60-min zone (PT60M):** **replicate** each hourly value into its 4
  quarter-hour slots — the *same MW level* in each quarter. This is a
  piecewise-constant upsample.

The critical invariant is **replicate, not divide**. Load and generation are
power *levels* (MW), not energy (MWh): a plant offering 500 MW offers 500 MW in
every quarter. The energy divides naturally because the period is shorter, but
the level is unchanged. Dividing the level by 4 would quarter both demand and
supply and misprice the entire clear.

The rule applies to **every per-period input** that feeds the book:

| Input | Where it's handled |
|-------|--------------------|
| Load, renewables | `replicate_to_finer_resolution` in the book builder's upsample branch (`create_merit_order_book`) |
| Net imports | Already **hour-keyed** (`get(net_imports, hour(slot), 0)`) — each hour's value is naturally read by all 4 of its quarters |
| ATC / transfer-capacity caps | The MPCC already **extracts the hour from each slot** (`hour = parse(Int, t[10:11])`) and looks up the hourly cap, so each hour's ATC bounds all 4 of its quarter flows |

`replicate_to_finer_resolution(d, native_res, target_res)` lives in
`src/TemporalResolutionUtilities.jl` and is unit-tested directly. Downstream
per-slot computations (scarcity margin, water value, demand orders, tagged
orders) then run on the 96-slot grid unchanged — they were always written
per-slot.

### Why the ATC period alignment "just worked"

This was expected to be the trickiest part. It turned out to need **no change**:
`TransferCapacity` stores caps keyed by integer *hour* strings, and the MPCC's
flow/congestion constraint builder already converts any `YYYYMMDD-HHMM` book
period to its hour before the cap lookup (`src/MPCC.jl`, flow-variable block).
So a 96-slot book automatically gets each hour's ATC replicated across its four
quarters, and every period has a defined `flow` bound. No `Network.jl` change was
required.

## Why this is correct — the reduces-to-hourly proof

The MPCC has **no inter-period coupling**: the objective is a plain sum over
orders with no period-duration weighting, the nodal power balance is indexed
`[node, period]`, and flows/congestion are per period. Every period is a
mathematically independent clearing problem.

Therefore, if a footprint's zones are **all natively hourly** and cleared at
15-min, each hour's four quarters receive *identical* replicated inputs
(load, renewables, imports) and the *same* replicated ATC cap. The four quarter
problems are literally the same LP as the hourly problem, so they must produce
**four identical quarter prices, each equal to the hourly clear's price for that
hour.**

This is the acceptance proof. Measured on the fully-hourly, ATC-coupled
footprint `{BG, RS}` (both load and renewables PT60M on 2026-04-03, coupled over
the RS↔BG border):

```
reduces-to-hourly  max|quarter - hourly|   = 0.000e+00 €/MWh
intra-hour spread  max|quarter - quarter|  = 0.000e+00 €/MWh
```

Bit-exact — including the coupled flow. A non-zero result here would indicate a
divide-instead-of-replicate bug or a period-grid misalignment.

## Native-15 behaviour

On a real day with native PT15M zones, the 15-min clear produces genuine
intra-hour price variation. On `{GR, BG, RS}` (GR native-15) for 2026-04-03:
GR shows an intra-hour price spread in 19 of 24 hours. Aggregating the 15-min
prices back to hourly (simple mean of the 4 quarters) is *close to but not equal
to* the 60-min clear (MAE ≈ 1.9 €/MWh, max ≈ 7 €/MWh) — the expected consequence
of clearing each quarter on its own inputs then averaging prices, versus
averaging the inputs first and clearing once (a Jensen-type gap through the
nonlinear clearing).

## Performance

39-zone EU footprint, 2026-04-03, `enrich_network=true, passes=2`, Gurobi:

| Resolution | Periods | Solve time | Total (incl. book build) | Status |
|-----------|---------|-----------|--------------------------|--------|
| 60-min | 24 | 10.3 s | 33.6 s | optimal, 39/39 priced |
| 15-min | 96 | 45.1 s | 113.3 s | optimal, 39/39 priced |

The 15-min monolithic solve is ~4.4× the hourly solve — in line with the 4×
period count — and remains tractable to proven optimality with Gurobi.

## What's done vs deferred

**Done (Increment 1):**
- `clear_resolution_minutes` kwarg (default 60) on the merit-order coupled path,
  threaded through the book build, network, exposed stages, two-pass rebuild, and
  the `:p95` robustness recursion.
- `replicate_to_finer_resolution` upsample primitive (replicate-not-divide),
  with an upsample branch in `create_merit_order_book` parallel to the existing
  down-aggregate-to-hourly branch (which is untouched).
- Guards: 60-min byte-identity (verified by diffing branch vs clean base to 0),
  reduces-to-hourly (max |Δ| = 0), native-15 intra-hour variation. Unit tests in
  `test/test_15min_resolution.jl` (core suite); coupled-solve acceptance in
  `test/scripts/test_15min_clearing.jl`.

**Deferred (Increment 2): per-period decomposition.**
Because every period is independent, the monolithic 96-period MILP is exactly 96
independent 1-period clears stacked into one solve. Increment 2 will solve them
**separately** — each slice is ~1/96th the monolithic size. That is where true
tractability and **HiGHS-viability** come from (many tiny independent MILPs
instead of one large one, trivially parallelizable), and it removes the ~4×
monolithic cost. This increment deliberately keeps the single monolithic solve so
the machinery and its correctness proof land first.

Also deferred: scenario-hook propagation and the single-zone / `:uc_based` /
`:alternative` paths (Increment 1 is coupled merit-order only).
