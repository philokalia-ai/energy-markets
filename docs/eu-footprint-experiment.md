# EU-wide footprint experiment: does making cross-border flows endogenous remove the forward-looking bias?

**Period:** 2026-04-01 … 2026-04-14 (14 days). **Model:** v10 merit-order,
`code_version = 10`. **Solver:** Gurobi (WLS), HiGHS fallback (identical optima).
**Branch:** `experiment/eu-wide-footprint`.

## Motivation

The 5-zone SEE multi-zone clearing (`GR, BG, RO, RS, HU`) makes only the borders
*inside* that set endogenous. Every border to a zone *outside* the set (GR–IT,
GR–AL, GR–TR, …) is injected as an **ex-post observed net import** read from
`entsoe.physical_flows`. Those observed imports are not knowable ahead of the
market, so the counterfactual is not genuinely forward-runnable — it has a
"forward-looking bias".

The hypothesis: extend the footprint to (nearly) all of coupled Europe so those
borders become **endogenous** (flows solved from ex-ante ATC), leaving only
truly external, non-SDAC borders (AL, MK, TR, UA, …) as observed injections.
Then measure the effect on GR and its neighbours.

## Footprint

**Full footprint actually run: 38 zones.** The one-day feasibility test (Gate 2,
2026-04-08) solved in **12.5 s** (MILP: 21 891 orders, 24 periods, 114
directional flow pairs, 2 736 flow variables) with total wall time **328 s**
dominated by the per-zone order-book build. Because the full footprint was
tractable, the GR-centred 2-ring fallback was **not** needed.

Zones: `AT, BE, BG, CZ, DE_LU, DK1, DK2, EE, ES, FI, FR, GR, HU, LT, LV, NL,
NO1–NO5, PL, PT, RO, RS, SE1–SE4, SI, SK` + the seven Italian bidding-zone
sub-nodes `IT-NORTH, IT-CNORTH, IT-CSOUTH, IT-SOUTH, IT-Calabria, IT-Sicily,
IT-Sardinia`.

### Aggregate vs sub-zone deduplication (the Italy / DE / DK trap)

Several countries appear in ENTSO-E under **both** an aggregate code and
bidding-zone sub-codes. Putting both into the footprint double-counts the
country. Decisions, per country, verified against the live data for the period:

| Country | Representation used | Excluded alias | Why |
|---|---|---|---|
| **Italy** | 7 `IT-*` sub-zones | aggregate `IT` | The aggregate `IT` node has **0 generators** (its fleet lives under the sub-zones). Using it would leave a dead supply node. |
| **Germany** | `DE_LU` bidding zone | `DE_50HzT` (+ `DE_Amprion`, `DE_TenneT_GER`, `DE_TransnetBW`) | `DE_50HzT` is a TSO **control area geographically inside** the `DE_LU` bidding zone; including both double-counts the 50 Hertz region. ATC and physical flows are filed at BZN level under `DE_LU`. |
| **Denmark** | `DK1`, `DK2` | aggregate `DK` | `DK1`/`DK2` are the bidding zones used by ATC and physical flows; the aggregate `DK` is redundant. |

**Two independent mechanisms already prevent double-counting; both were verified
by reading the code and the data:**

1. **ATC / flow-variable side.** `create_transfer_capacity_from_entsoe(day,
   zones)` filters ATC rows with an `OR` on the endpoints, so a border like
   `GR–IT` (GR in the footprint, aggregate `IT` not) *is* returned and the
   aggregate `IT` is added to the `TransferCapacity`'s zone list. But the MPCC
   solver (`src/MPCC.jl`) restricts flow variables to pairs whose **both**
   endpoints are order-book nodes (`p[1] in nodes && p[2] in nodes`). The
   aggregate `IT` has no orders → not a node → the `GR–IT` flow variable is
   never created, while `GR–IT-SOUTH` (both nodes) is. The aggregate node is
   inert (no power-balance constraint, no flow variable). ✔

2. **Observed-net-import side.** `get_net_imports` (`src/MeritOrderBook.jl`)
   already restricts `entsoe.physical_flows` rows to `BZN`-level area types on
   **both** sides. Empirically, every aggregate alias for the period is
   published at **CTA/CTY** level (`GR–IT` appears as `BZN/CTA/CTY ↔ CTA/CTY`;
   the aggregates `IT` and `DK` never appear `BZN`-both-sides; `DE_50HzT` never
   appears at `BZN` at all). So the aggregates are dropped by the existing
   filter, while the true sub-zone borders (`GR–IT-SOUTH` = `BZN ↔ BZN/CTA/CTY`)
   are kept. ✔

Because the aggregates are already filtered out on both paths, the defensive
helper added here — `shadowed_aggregate_codes(footprint)` in `src/Euphemia.jl`,
which appends `IT` / `DK` / German-CTA codes to *every* footprint zone's
observed-import exclusion list when the corresponding sub-zones are present — is
a **belt-and-suspenders no-op for the current data**. Critically it returns an
**empty set** for any footprint without split-country sub-zones, so the 5-zone
SEE path is unchanged (unit-tested in `test/test_eu_footprint.jl`; the
exclude vector is byte-identical to the pre-change value, hence the SEE
order-book build is byte-identical).

**RS:** kept in the footprint. It has no implicitly-coupled ATC borders (outside
SDAC), so `atc_linked[RS]` is empty and RS retains all its observed net imports
— effectively standalone, coupled only through observed injections. Harmless to
GR.

## The Italy islanding artifact (the decisive finding)

Choosing the Italian **sub-zones** (mandatory, since the aggregate `IT` has no
fleet) has a serious side effect that ATC data forces on us: **Italy's
continental interconnectors (IT–FR, IT–AT, IT–SI, IT–CH) are filed in
`offered_transfer_capacities_implicit` only under the aggregate `IT` code, never
under a sub-zone.** With the aggregate `IT` excluded, those borders disappear.
The Italian sub-zones remain internally connected (the `IT-SOUTH ⇄ … ⇄ IT-NORTH`
chain) and connect to the rest of the footprint **only** through the single
`GR ⇄ IT-SOUTH` link.

Consequence: **Italy is islanded from continental Europe.** With abundant cheap
must-run in the south and only one thin export path (to GR), the whole Italian
sub-system collapses to the price floor. `IT-SOUTH` clears at **€6.0/MWh on
every day** of the period against a realised day-ahead price of **€145–157/MWh**.

Because `GR ⇄ IT-SOUTH` is now endogenous, GR imports this phantom-cheap Italian
power, which **drags GR's price down by ~€30/MWh** and injects a large negative
bias that the observed-import SEE baseline never had.

This is not a bug in the dedup logic — it is a structural limitation of building
Italy from sub-zones while ATC publishes Italy's external borders only under the
aggregate. The correct fix (future work) is to **remap the aggregate-`IT` ATC
borders onto `IT-NORTH`** (the zone that physically hosts every Italian
continental interconnector), reconnecting Italy to FR/AT/SI. That was out of
scope for this experiment (it is a modelling change, not a dedup fix).

## Results: three-case comparison

Hourly prices vs realised ENTSO-E day-ahead (`entsoe.energy_prices`,
`contract_type = 'Day-ahead'`), all series aggregated to hourly means over the
14 days. Bias = mean(sim − real).

| Zone | Case | clearing_mode | mean sim | mean real | MAE | bias | corr |
|---|---|---|---:|---:|---:|---:|---:|
| **GR** | (a) 5-zone SEE | `multi_zone` | 96.9 | 95.1 | **40.7** | **+1.8** | **0.647** |
| **GR** | (b) EU-wide | `multi_zone_eu` | 85.3 | 95.1 | **39.4** | **−9.8** | **0.658** |
| **GR** | (c) single-zone | `single_zone` | 85.9 | 95.1 | **37.7** | **−9.3** | **0.675** |
| BG | (a) 5-zone SEE | `multi_zone` | 98.9 | 95.9 | 42.5 | +2.9 | 0.636 |
| BG | (b) EU-wide | `multi_zone_eu` | 89.1 | 95.9 | 41.4 | −6.8 | 0.644 |
| RO | (a) 5-zone SEE | `multi_zone` | 98.9 | 97.7 | 42.6 | +1.1 | 0.639 |
| RO | (b) EU-wide | `multi_zone_eu` | 89.1 | 97.7 | 41.9 | −8.6 | 0.645 |
| IT-SOUTH | (b) EU-wide | `multi_zone_eu` | 5.2 | 121.2 | **116.0** | **−115.9** | 0.528 |
| FR | (b) EU-wide | `multi_zone_eu` | 28.4 | 55.0 | 42.9 | −26.6 | 0.425 |
| DE_LU | (b) EU-wide | `multi_zone_eu` | 232.5 | 82.9 | **164.6** | **+149.6** | 0.356 |

(€/MWh; 14 days, hourly, n ≈ 332 h; IT-SOUTH n = 284 h because it failed the
2 short days. Cases (a)/(c) exist only for SEE zones — the EU-only zones have no
5-zone or single-zone counterpart.)

**Reading the GR rows (the whole point of the experiment):**

- **MAE** barely moves: 40.7 (SEE) → 39.4 (EU) → 37.7 (single). The EU footprint
  is a hair *better* than SEE on MAE but a hair *worse* than plain single-zone.
- **Correlation** barely moves: 0.647 → 0.658 → 0.675, same ordering.
- **Bias** is where the change shows: the well-calibrated SEE bias **+1.8**
  degrades to **−9.8** under the EU footprint — GR becomes ~€10/MWh too cheap.
  That −9.8 is essentially the single-zone bias (−9.3): **the 38-zone EU MILP
  collapses GR onto the single-zone answer.**

The same signature appears in BG and RO (both SEE zones coupled to GR): a
~€8–10/MWh downward bias shift and a marginal MAE improvement.

## Additional diagnostics

**Endogenous vs observed cross-border energy (GR, 2026-04-08).** The endogenous
flows carry real energy of a magnitude comparable to the observed baseline they
replace:

| Metric | EU endogenous | Observed (physical_flows) |
|---|---:|---:|
| GR mean net cross-border position | −291.5 MW | −463.5 MW |
| as % of GR load (5 173 MW) | −5.6 % | −9.0 % |

(Negative = net export; on this day GR was a net exporter both in reality and in
the model.) So making the borders endogenous is not a cosmetic change — it moves
~300–460 MW (6–9 % of GR load). But the endogenous solution routes some of GR's
export capability toward pulling in phantom-cheap Italian power (IT-SOUTH cleared
at €5.7 that day), which is what produces GR's downward price bias.

**Price coupling.** GR≡neighbour coupling is visible in both footprints. In the
EU run GR/BG/RO clear within ~€4 of each other (85.3 / 89.1 / 89.1); in SEE they
sit at 96.9 / 98.9 / 98.9. Coupling is present in both; the EU footprint simply
shifts the whole SEE cluster **down** ~€10 through the newly-endogenous
`GR ⇄ IT-SOUTH` link.

**Distant-zone data quality is the noise floor.** `DE_LU` (MAE 165, bias +150)
and the Nordic/Baltic zones repeatedly hit the €3 000/MWh demand cap: their
generator/load coverage in the DB is incomplete, so the merit book runs short of
supply and prices scarcity. On 2 of the 14 days, 10 of the 38 zones dropped to
the failed-zone path entirely (28/38 priced). This noise is mostly *electrically
distant* from GR and does not reach it directly, but it makes the EU footprint
unusable as a price model for those zones themselves.

**Runtime / forward-runnability.** Per day: MILP solve **7–13 s** (Gurobi WLS),
total wall **~5–7 min** dominated by the 38-zone order-book build (per-zone DB
queries), not the solve. The full 14-day backfill took ~68 min. Computationally
this is entirely feasible as a daily forward model.

## Verdict

**1. Is the forward-looking bias removed? Yes, in principle.** With the EU
footprint, GR's Italian and Bulgarian borders are solved endogenously from
ex-ante ATC instead of being read from ex-post `physical_flows`. Only genuinely
external, non-SDAC borders (AL, MK, TR) remain as observed injections. The
counterfactual is therefore *forward-runnable* for the coupled borders, and the
solve is fast enough (7–13 s) to run daily ahead of the market. On this axis the
experiment succeeds.

**2. Does it improve GR's accuracy? No — the effect is small and mixed, net
slightly negative.** GR's MAE (40.7 → 39.4) and correlation (0.647 → 0.658)
barely move, while its bias degrades from a well-calibrated **+1.8** to **−9.8**.
The 38-zone EU MILP essentially reproduces the *single-zone* GR result
(MAE 37.7, bias −9.3) — i.e. all the extra machinery buys nothing over ignoring
coupling entirely, and costs ~€10/MWh of downward bias.

**3. Why: the Italy sub-zone islanding artifact.** The single largest driver is
that Italy's continental interconnectors (IT–FR/AT/SI) are published in ATC
**only** under the aggregate `IT` code, which must be excluded because it has no
generator fleet. Building Italy from its sub-zones therefore islands it from the
continent; `IT-SOUTH` collapses to the €5–6/MWh price floor (vs realised
€121–157), and the now-endogenous `GR ⇄ IT-SOUTH` link imports that phantom-cheap
power into GR. This is a structural ATC-data limitation, not a dedup bug.

**4. Operational verdict.** As a *forward* model the EU footprint is
computationally feasible but **not currently worth adopting for GR**: it removes
the forward-looking bias only to introduce an Italy-islanding bias of similar
size, and it is unusable for the distant zones (DE_LU, Nordics) whose data is
incomplete. A Europe-wide competitive counterfactual is only as good as its
worst-data zone.

**Recommended follow-ups to realise the benefit (out of scope here):**
1. **Remap the aggregate-`IT` ATC borders onto `IT-NORTH`** (the zone that
   physically hosts every Italian continental interconnector). This is the
   decisive fix — it reconnects Italy to FR/AT/SI and should lift `IT-SOUTH` off
   the floor, removing GR's imported bias. It is a modelling change (endpoint
   remap), distinct from the double-counting dedup handled in this PR.
2. **Complete generator/load coverage** (or apply per-type fleet completion) for
   DE_LU and the Nordic/Baltic zones so they stop pricing the €3 000 cap.
3. Only then re-measure — with a reconnected Italy and complete distant-zone
   data, the endogenous GR bias should shrink toward the SEE baseline while
   retaining forward-runnability.

## Reproducibility

- Runner: `bin/eu_footprint_experiment.jl` (env: `START_DATE`, `END_DATE`,
  `FOOTPRINT=full|core`, `SAVE`, `OPTIMIZER`). Resumable per-day; saves **only**
  `energy_prices` under `clearing_mode='multi_zone_eu'` (deliberately not
  `transmission_flows`/`optimization_runs`, which lack a clearing_mode
  discriminator and would clobber the SEE baseline).
- Import diagnostic: `bin/eu_gr_import_diag.jl` (env: `DAY`).
- Accuracy query: `bin/eu_footprint_analyze.sql` (three-case comparison vs
  `entsoe.energy_prices`).
- Dedup helper + unit tests: `Euphemia.shadowed_aggregate_codes`,
  `test/test_eu_footprint.jl`.
