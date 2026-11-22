# Complex orders — energy-limited pumped storage and thermal regular blocks (2026-11 sprint)

**Question.** Can a small layer of EUPHEMIA-style complex orders, the kind real
participants actually submit, model the day-ahead market more faithfully without
making the clearing much more complex?

**Answer.**
- **Pumped storage as an energy-limited family (`ps`): yes, small and clean.**
  Footprint MAE −1.08 (ex-IT −1.20). Correlation is unchanged (0.843 → 0.845).
  It improves 7 of 8 days, and its worst zone is SE3 at +0.48. On the 892
  zone-hours where the energy budget binds, MAE drops 3.3 €/MWh.
- **Thermal regular blocks at SRMC (`blocks`): no as a default.** It acts as a
  level lever and costs shape. It overprices collapse days, prints ES/PT at the
  cap on 10-19, and drops pooled correlation 0.84 → 0.74.

Everything is off by default behind `EUPHEMIA_COMPLEX_ORDERS`. With the flag
unset, the book and prices match `main` byte for byte (guard below).

## Mechanism (one layer, two order kinds)

EUPHEMIA solves a welfare master problem that decides the complex orders, then
prices each period with those decisions fixed (fix-and-reprice). We follow the
same split:

1. **Master** (`src/mpcc/complex_orders.jl`). A full-day primal welfare
   program over the coupled footprint. It uses the same orders, ATC bounds, JAO
   net-position limits, shed slack and sign convention as the MPCC, plus the
   complex-order rows. It is an LP for storage families and a MILP once blocks
   are present.
2. **Per-period MPCC, unchanged.** It clears the book with the master's
   decisions fixed. Per-period decomposition, HiGHS viability and the
   competitive price reconstruction are untouched.

The hook sits in one place: the top of `solve_mpcc_market_clearing`, which runs
only when the book contains a `LinkedHourlyOrder`. It covers pass 1 and pass 2,
single-zone and multi-zone. If the master fails, the members are released as
plain hourly orders, so the clear never breaks.

### `ps` — pumped storage as an energy-limited family

The book offers `Hydro Pumped Storage` at its water value in every hour, 24 of
24, which amounts to unlimited energy. Demonstrated daily PS generation is 4–10
full-load hours. For example, DE_LU offers 114.7 GWh/day against 25.2 GWh/day
demonstrated.

With `ps`, a zone's PS water-value offers become one `LinkedHourlyOrder`
family. Its daily budget is the mean daily PS generation over the 14 complete
UTC days before the cutoff, from `entsoe.aggregated_generation_per_type`:
- **Cutoff:** `min(D-1, date(as_of − AGG_GEN_PUBLICATION_LATENCY))`.
- **Legacy path and lead 1 at the gate:** D-15..D-2.
- **Lead 7 issuance:** only days before D-7.
- **Cache:** keyed on the effective cutoff, so issuance vintages never share an
  entry (review fix). This is the divisible form of an exclusive group of
profile blocks, the instrument PS operators use.

The master allocates each family's energy across the hours. Each member then
re-enters the MPCC at its own bid, capped at its allocation:
- Where the cap does not bind, PS can still set the price.
- Where it binds, the next order sets the price, and the storage earns its
  scarcity rent.
- No member can be paradoxically accepted, because the MPCC complementarity
  admits a member only when price ≥ bid.

No pumping demand is added. That family was measured harmful twice (cv34 T3).
The often-cited reason, that the load forecast embeds pumping, is not reliable:
ENTSO-E total load is defined net of storage absorption.

`ps,reservoir` extends the same construction to `Hydro Water Reservoir` outside
the Nordic reservoir-opportunity zones. On the one day it was measured before
the matrix moved to the new base, it changed MAE by −0.18, so it was dropped.

### `blocks` — thermal regular blocks with the EUPHEMIA acceptance rule

Each unit in the static committed set bids its minimum load as one
all-or-nothing regular block over the day, at limit price SRMC. This replaces
the static must-run split, which bid 0.6·p_min at 5 % of SRMC and 0.4·p_min at
max(SRMC/2, SRMC−40).

The master MILP decides acceptance:
- **Accepted blocks** enter the pricing MPCC as **fixed injections**
  (`MPCCOrderBook.fixed_injections`). They are not orders the clear could
  partially reject. A surplus they force goes to the same penalised slack in
  the master and in the MPCC (review fix).
- **No paradoxically accepted block (PAB)** is returned: an accepted block must
  have Σ_t (P_t − b)·q_t ≥ 0 at the repriced prices. Paradoxical rejection is
  allowed, as in EUPHEMIA.
- **Acceptance search (since 2026-11, `solve_with_complex_orders`).** The first
  version re-solved the master with the PABs forced out, for at most 4 rounds,
  and released the blocks to their `BLKFB:` must-run offers when PABs remained
  (2 of the 4 inner days below did). It is replaced by a reversible search:
  seed with ≤ 4 such rounds; if none is PAB-free, prune the accepted set
  (∅ at worst, so the search always ends PAB-free); then reinsert rejected
  blocks that are in the money, in batches, keeping a batch only if welfare
  improves. Budget: 30 pricing solves, or stop within €50k of the first
  master's objective. Validation: `highs-blocks` workspace (R1); every call
  on 09-27, 10-19, 11-04, 11-13 PAB-free with no fallback.
- **On a master failure,** the blocks are released to exactly the baseline
  book (original `BLKFB:` must-run offers restored). This is now the only
  release path.

`EUPHEMIA_BLOCK_PRICE=mustrun` sets the block's limit price to the static
split's blend. That isolates the acceptance rule from the price change.

Known simplification: the unit's hourly tranches above p_min are not linked to
the block, so a rejected unit can still sell them.

## Evaluation

| | |
|---|---|
| Code | `lead/blocks` rebased on main cv43 (35d603d) |
| Runtime | Julia 1.13.4, HiGHS 1.27 (native 1.16) |
| Data | Offline extract 2026-11-14, legacy no-context record path (`run_multi_zone_market_clearing`, 39 zones, `enrich_network`, `passes=2`, decomposed, production time limits) |
| Days | The 8 calibration days in `reports/days.json` (09-16, 09-20, 09-27, 10-06, 10-19, 11-02, 11-04, 11-13), cleared as UTC days |
| Target | The live JSON `actual`: the SDAC series (AT/DE_LU sequence 2), hourly, rounded to 8 decimals before ≤ 0 labels |
| Pairing | Paired (day, zone, UTC hour) cells: 7,486 of 7,488; 2 cells have no settled actual |
| Solves | All 32 arm-days returned `optimal`. Wall time 3–4 min/day (`base`, `ps`) and 7 min/day (`blocks`, `combo`). The master takes 0.6–1.0 s (LP) and 2–19 s (MILP) per call |

| arm vs base | days | cells | MAE all (Δ) | MAE ex-IT (Δ) | bias | corr | ≤0 hit / FA | cap/floor cells |
|---|---|---|---|---|---|---|---|---|
| `ps` | 8 | 7486 | 49.65→48.58 (−1.08) | 48.95→47.75 (−1.20) | −28.5→−26.9 | 0.843→0.845 | 3/3 → 3/3 | 0 |
| `blocks` (SRMC) | 8 | 7486 | 49.65→47.42 (−2.24) | 48.95→48.35 (−0.60) | −28.5→−10.2 | 0.843→0.737 | 3/3 → 1/1 | 2 |
| `combo` = ps+blocks+RES ladder | 8 | 7486 | 49.65→47.10 (−2.56) | 48.95→47.60 (−1.35) | −28.5→−9.1 | 0.843→0.738 | 3/3 → 67/57 | 2 |

Excluding the 2 ES/PT cap cells (10-19 18:00 UTC; see below):
- `blocks`: −2.94 (ex-IT −1.46), correlation 0.84 → 0.82.
- `combo`: −3.26 (ex-IT −2.21), correlation 0.84 → 0.82.

Full per-day and per-zone tables are in `score_f_*.txt`.

**`ps`, where it acts.** Ten families bind their budget on at least one day: AT,
BG, CH, CZ, IT-Sicily, NO2, NO5, PL, SI and SK. On their capped zone-hours (892
cells) MAE drops 56.00 → 52.73, and correlation moves 0.84 → 0.85.

| Zone | ΔMAE on capped cells |
|---|---|
| CH | −7.3 |
| SK | −4.1 |
| SI | −3.6 |
| AT | −3.2 |
| BG | −2.5 |

On the other 6,594 cells the gain is −0.78, which is coupling spillover:

| Zone | ΔMAE |
|---|---|
| HU | −3.2 |
| RO | −3.2 |
| CZ | −2.4 |
| FR | −2.1 |
| PL | −1.6 |
| BE | −1.5 |
| DE_LU | −1.5 |

Where PS is rarely in the money in the master, the budget is slack and nothing
changes. The model prices there sit below the water value. Mean daily use
against budget: DE_LU 2.6/25.7 GWh, ES 4.0/29.5, PT 3.2/18.1, FR 0/16.1. ≤ 0 hours are unchanged: `ps` is a level and shape lever, not
a collapse lever.

**`blocks`: level lever with a shape cost.** About 35 % of committed units'
blocks are rejected on an average master call. Their cheap must-run p_min
leaves the book and prices rise; bias moves −28.5 → −10.2.

- **Level-miss days improve:**

  | Day | ΔMAE |
  |---|---|
  | 11-13 | −10.2 |
  | 11-02 | −5.8 |
  | 11-04 | −3.0 |
  | 09-27 | −2.8 |

- **Collapse and good days get worse:**

  | Day | ΔMAE | bias |
  |---|---|---|
  | 09-20 | +3.3 | +0.4 → +27.9 |
  | 09-16 | +1.2 | |
  | 10-06 | +0.7 | |

- **10-19, ES/PT 18:00 UTC at the €3000 cap.** The day solved `optimal`, so
  this is the mechanism, not a solver artifact. The pass-2 PAB loop rejected
  126 of 578 accepted blocks before converging, and the rejected Iberian blocks
  removed enough p_min to create scarcity. Pooled correlation that day falls
  0.76 → 0.45.
- **The PAB loop does not always converge within its 4-round cap.** `blocks`
  ended 2 master calls with 3 and 4 blocks still paradoxically accepted.
  `combo` ended its 10-19 pass 1 with 73 left; its pass 2 converged.
- **Zone spread:**

  | Better | ΔMAE | Worse | ΔMAE |
  |---|---|---|---|
  | LV | −17.6 | PT | +18.9 |
  | IT-Sardinia | −13.9 | | |
  | LT | −12.4 | | |
  | IT-NORTH | −11.6 | | |

  Elsewhere, zones whose level was already right get worse, as seen on the old
  base (DE_LU, BE, CZ, ES, FI, EE).
- **The isolation arm settles the question.** `blockmr` (all-or-nothing at the
  calibrated must-run price) was +3.75 worse on the old base: fixed p_min
  pushes prices down. So the `blocks` gain comes from the SRMC price, not from
  the acceptance rule. It is the same price-for-level trade the §8 endogenous
  must-run study found, and it is seasonal.

**`combo`.** Same level and shape profile as `blocks`. The RES ladder (#399)
adds ≤ 0 hits (3 → 67) together with false alarms (3 → 57).

**Byte-identity guard.** origin/main 35d603d, cleared directly, versus
`lead/blocks` with the flag unset, on 2026-11-13: 936 of 936 cells identical,
max |Δ| = 0. This holds both before the review fixes (d2ad46c) and after them
(45fb9de).

**Review-fix verification (45fb9de).**
- **`ps`:** re-cleared 11-04 and 11-13. Both are bit-identical to the table's
  `ps` run (936/936, max |Δ| 0). The context-aware budget cutoff equals the
  legacy D-15..D-2 window on the record path and at the lead-1 gate, which the
  unit test also checks.
- **`blocks`:** the rows in the table predate the fixed-injection and
  PAB-fallback fixes (and the 2026-11 acceptance search, which removes the
  fallback). The post-fix re-measure ran on the 4 inner days (3,742
  cells, all optimal):
  - **Footprint:** MAE −1.71 (ex-IT −0.29), correlation 0.821 → 0.794, bias
    −30.9 → −17.4. No cap or floor prints; the 10-19 ES/PT €3000 is gone.
  - **PAB fallback on 2 of 4 days** (10-19, 11-04): the PAB loop was still
    violated after 4 rounds in the final pass. Those days clear the baseline
    book bit-identically (0 cells moved), which confirms that the fallback
    restores the original must-run offers.
  - **09-20 (+3.31) and 11-13 (−10.15)** are unchanged from the pre-fix run.
  - **Pre-fix on the same 4 days:** −2.79 (ex-IT −0.49), correlation
    0.82 → 0.66.
  - **Reading:** with the acceptance rule now enforced, `blocks` is valid but
    converges within 4 rounds on only half of these days. That is one more
    reason to keep it opt-in.
  - **`combo` was not re-run:** the 2-process memory cap during verification
    didn't allow it. Its pre-fix row inherits the `blocks` caveat.

## Verdict (ship/no-ship is the owner's call)

- `ps` is physically right: storage cannot generate energy it does not have. It
  is ex-ante, tiny in code, adds about 1 s of LP per pass, and improves where it
  acts (CH/AT/SI/SK) with no correlation cost. It is a candidate for default-on
  in a code-version bump with a backfill, if the owner agrees. Coverage is 8
  days; a longer window would firm up the −1.1.
- `blocks` should stay opt-in. The machinery (MILP master + PAB loop) is the
  faithful EUPHEMIA structure and is reusable. With SRMC limit prices, though,
  the outcome is a level shift that overshoots wherever levels are already
  right. Real block limit prices fold in heat obligations and ancillary-service
  value. A faithful price needs data we don't have ex-ante.

## History and caveats

- Two earlier matrices, an Italy-fix-only base and then Italy + in-merit on
  Julia 1.12 / HiGHS 1.16, are kept only as a labelled appendix in the sprint
  results folder (`results/blocks/appendix_oldhighs_cv42fix/`). Under 20-way
  contention, old HiGHS timed out per period and segfaulted 3 times (twice in
  base). Their directions agree with the table above.
- The scores are a paired comparison inside one input contract: legacy, with
  gate-time ENTSO-E forecasts. Absolute levels must not be pooled with the live
  weather-track product or with issuance-context ablations.
- These are UTC days, not Athens market days, which costs about 2 h at each
  edge.
