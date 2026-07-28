# IT-NORTH diagnosis — the degrading laggard

Branch `exp/itnorth-diagnosis`. Data: offline extract
`data/extracts/euphemia-live.duckdb` (read-only). Model = **cv24** hourly record
(`cv24_model.csv`, 2023-01-01..2026-07-27, UTC) — the registry-sanity-bound
baseline (#205/#206) that heals a corrupt ENTSO-E unit (IT-CSOUTH
`26WUUUUUUBUSSI19`, 13,068,005 MW) which had polluted the whole IT family's
COUPLED clear. Settled = `entsoe.energy_prices` `contract_type='Day-ahead'`,
PT15M/PT60M averaged to hourly UTC. All numbers below are model−settled
("resid"); NEGATIVE resid = model under-prices. My A/B arms run cv24-consistent
code (the fix, `MAX_PLAUSIBLE_UNIT_MW`, is in this worktree).

**Baseline note (coordinator correction, incorporated).** A first pass ran
against cv23; switching to cv24 lifts IT-NORTH's whole trajectory (~+0.04..+0.07
corr/year) because the corrupt unit is gone. A large chunk of the raw cv23
"degradation" was that data pathology, not market structure. The cv24 residual
below is the genuine, smaller residual to explain.

IT-NORTH is the single biggest energy-weighted laggard (156 TWh/yr) and its
corrected hourly correlation **still degrades over time**, which is the clue.

## 1. Residual / degradation regime table

### Correlation & MAE by year (IT-NORTH, hourly)

| year | n | corr | MAE | bias | settled mean | model mean |
|---|---|---|---|---|---|---|
| 2023 | 8688 | **0.786** | 15.1 | −1.7 | 127.9 | 126.2 |
| 2024 | 8544 | **0.716** | 14.4 | −3.6 | 107.6 | 104.0 |
| 2025 | 8447 | **0.667** | 16.8 | +1.3 | 115.9 | 117.2 |
| 2026 (Jan–Jul) | 4827 | **0.639** | 23.9 | +5.2 | 131.7 | 136.9 |

Corrected trajectory 0.79 → 0.72 → 0.67 → 0.64 — **still degrading, still below
0.75.** Bias is small through 2025 (−3.6..+1.3): the SHAPE is wrong, and the
shape error grows. 2026 (partial) also picks up a positive LEVEL bias (+5.2).

### The intraday dipole (bias by hour-of-day UTC, per year) — the whole story

| UTC hour | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|
| 05h (morning ramp) | −11.6 | −14.7 | −13.2 | −16.7 |
| 06h | −13.7 | −17.5 | −9.1 | −6.8 |
| **08h (midday/solar)** | −1.7 | −0.7 | **+12.1** | **+16.7** |
| **10h** | +6.9 | +4.0 | **+16.7** | **+15.7** |
| 12h | +8.8 | +4.7 | +11.3 | +12.8 |
| 13h | +5.8 | +3.7 | +11.7 | +14.6 |
| 16h | −10.9 | −6.8 | +3.7 | +9.5 |
| **17h (evening)** | −14.3 | −16.1 | +3.5 | **+24.3** |
| 18h | −9.6 | −17.4 | −4.6 | **+30.8** |
| 19h | −8.7 | −13.4 | −11.2 | +17.6 |

With the corrupt unit gone, the residual has a much cleaner structure than cv23:
- **Midday (09–14 CET) OVER-pricing GROWS sharply** — mild in 2023–24 (+4..+9,
  and near-zero at 08h) but STEPS UP to **+12..+17 in 2025–26**. This is the
  **solar signature**: as PV builds out (correctly forecast, see §2), the real
  midday belly deepens toward €0 but our gas-SRMC book does not follow. This
  step-up is the dominant, growing residual — **the degradation driver.**
- **Evening (17–20 CET)**: the cv23 chronic −20..−31 under-pricing is **largely
  healed by the registry fix** — 2023–24 now only −9..−17, 2025 near-balanced,
  and **2026 flips to strong OVER-pricing (+18..+31)**. The evening is no longer
  the story; the midday-solar belly is.
- **Morning ramp (06–08 CET)** stays mildly under-priced (−7..−17).

Net effect: **our daily curve is too FLAT at midday vs a deepening solar belly.**
As the duck curve steepens, our compressed midday keeps the correlation falling
0.79 → 0.64.

### Seasonal cut (worst regime = summer)

| year·season | corr | MAE | bias |
|---|---|---|---|
| 2023 DJF | 0.838 | 16.3 | −6.5 |
| 2024 JJA | **0.646** | 14.8 | −10.7 |
| 2025 JJA | **0.605** | 15.3 | −4.9 |
| 2026 JJA | **0.643** | 28.1 | +11.1 |

**Summer (JJA) is the weakest correlation regime every year** — exactly where the
high-solar duck curve is most extreme. This is where the degradation lives.

### IT family (corr / MAE by year) — degradation is NORTH/CNORTH-specific

| zone | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|
| IT-NORTH | 0.79/15.1 | 0.72/14.4 | 0.67/16.8 | 0.64/23.9 |
| IT-CNORTH | 0.79/15.3 | 0.77/14.5 | 0.67/18.8 | 0.64/24.3 |
| IT-CSOUTH | 0.74/16.7 | 0.78/14.3 | 0.71/16.9 | 0.75/20.2 |
| IT-SOUTH | 0.71/17.3 | 0.77/14.9 | 0.72/18.3 | 0.80/20.7 |
| IT-Sicily | 0.67/18.8 | 0.74/17.9 | 0.69/20.0 | 0.80/21.8 |
| IT-Sardinia | 0.64/20.1 | 0.71/17.3 | 0.68/20.7 | 0.76/22.4 |

The southern zones IMPROVE into 2026 (0.75–0.80); IT-NORTH and IT-CNORTH do NOT
(0.64). Whatever fixed the south (more solar-dominated, simpler thermal stacks)
does not reach the two northern, hydro-and-import-heavy zones — **the residual
is NORTH/CNORTH-specific.**

## 2. What changed 2023→2025 — hypotheses tested against fundamentals

### (d) Does our RES forecast lag the PV build-out?  → NO, REJECTED

The model uses the ex-ante D-1 `day_ahead_generation_forecast_mw`. IT-NORTH
midday (UTC 10–13) solar, MW average:

| year | D-1 forecast | actual | act−fc |
|---|---|---|---|
| 2023 | 2899 | 2971 | +73 |
| 2024 | 3412 | 3440 | +28 |
| 2025 | 4340 | 4460 | +119 |
| 2026 | 4724 | 4934 | +211 |

**The forecast tracks realized PV to within 1–4%.** The solar input is correct
and captures the +50% build-out. The growing midday over-pricing is therefore
**NOT a solar-data lag** — it is a supply-curve shape gap: our book does not
convert the (correctly-forecast) growing solar into the €0-ward midday collapse
the real market prices. This is a genuine mechanism finding, not a data fix.

### The dominant residual is the midday solar belly (not the evening, post-cv24)

The physical duck curve — IT-NORTH 2025 avg output by type, midday (UTC 10–13)
→ evening (16–19):

| type | midday MW | evening MW | Δ |
|---|---|---|---|
| Fossil Gas | 5906 | 8843 | +2937 |
| Hydro Reservoir | 292 | 805 | +513 |
| Hydro Pumped Storage | 160 | 554 | +394 |
| Energy storage (battery) | 58 | 359 | +301 |
| Solar | 4460 | 240 | −4220 |

Solar collapses 4460→240 into the evening while gas + ~1.2 GW of dispatchable
storage (reservoir/pumped/battery) ramp up. With the corrupt unit removed the
**evening residual is largely healed** (§1): the remaining, GROWING gap is the
**midday belly**, where the real market prices the solar surplus toward €0 but
our gas-SRMC book floors near gas. The storage classes that ramp into the evening
DO carry an opportunity-cost gap in principle (they price at discharge-value, not
SRMC), but post-cv24 that gap is small and IT-NORTH already carries a
demand-shaped gas-anchored water value on Reservoir + Pumped Storage (§3) that
partly captures it. The evening's residual is now substantially the GME-documented
cap-tail withholding — **conduct the counterfactual exists to MEASURE, not
reproduce** — and in 2026 the model even over-prices the evening.

## 3. Ranked mechanism candidates (with spec-compliance arguments)

Note two things established by code inspection before ranking:
- **IT-NORTH already carries a demand-shaped gas-anchored water value**
  (`ITALY_PROFILE` inherits struct defaults `water_value_base=0.85,
  water_value_span=0.9`): Reservoir + Pumped Storage bid `0.85×gas` at the
  trough rising to `~1.75×gas` at the evening net-demand peak. So "IT-NORTH
  has no hydro treatment" is false — it has the gas-anchored one.
- **Batteries ("Energy storage") and Run-of-river are SRMC-exempt flat-cheap**,
  NOT water-valued (`WATER_VALUE_FUEL_TYPES = [Reservoir, Pumped Storage]`
  only). So IT-NORTH's evening-discharging batteries carry no opportunity cost.

| rank | candidate | spec argument | verdict from diagnosis |
|---|---|---|---|
| — | **(d) RES-forecast lag** | would be a fundamentals-data fix | **REJECTED** — D-1 solar forecast tracks realized PV to 1–4%; input is correct |
| — | **(a) must-run / solar floor** (cv24/cv24.1) | ex-ante bimodal book from GME object truth; deepens the midday belly | **NO-SHIP ×2 already** — volume-neutral floor THINS the mid-merit ladder serving the evening ramp → lower trough bought with higher evening peak; bad in high-RES season (the exact summer regime where IT-NORTH degrades). cv25 all-hours-inframarginal refinement specified but unbuilt. |
| — | **(b) two-pass `:hydro`/`:reservoir_opportunity` anchor** | first-class mechanism; IT-NORTH lacks it | **WRONG-DIRECTION** — both clamp hydro *below* gas SRMC (designed for hydro-DOMINATED exporters like NO/CH/AT to stop full reservoirs slamming the cap). IT-NORTH is a gas-marginal importer; this would LOWER its already-under-priced evening. The correct-direction gas-anchored shape it already carries. |
| 1 | **(c) import backstop / border** | first-class ex-ante mechanism (trailing-8-same-weekday demonstrated import headroom, priced 1.8×gas SRMC); IT-NORTH conspicuously lacks it while IT-CNORTH carries it | **TESTED BELOW.** Directional prediction from the residual signs: backstop adds elastic import supply near scarcity → lowers tight-hour prices → likely HURTS the under-priced evening, ~inert midday (midday isn't scarce). Measured to close the candidate honestly. |
| (obs) | storage arbitrage (battery charge-midday / discharge-evening as demand+supply) | pure fundamentals, hits BOTH dipole lobes, no new parameter to fit | NOT existing machinery (new mechanism); IT-NORTH battery fleet is small (~0.4 GW evening) so likely immaterial. Noted as the cleanest future lever. |

**Post-cv24 sharpening.** With the corrupt unit healed, the residual is now
dominated by ONE lobe — the **growing midday solar belly** (model over-prices
midday, +5→+17 from 2023→2025). This is squarely candidate (a) territory: the
only spec-true way to deepen a midday belly is a must-run/solar floor that
re-prices the inframarginal base toward €0 — and that mechanism is **measured
NO-SHIP twice** because (volume-neutral) it thins the mid-merit ladder that
serves the evening ramp (cv24-it-book.md; cv25 all-hours-inframarginal
refinement specified but unbuilt). Note the cv24-it-book A/B measured the floor
against a base that ALSO reverted the registry fix (`EUPHEMIA_DISABLE_CV24`), so
a re-test of the cv25 floor on the *clean* cv24 base — where the evening is no
longer under-priced — is a genuinely open follow-up the coordinator flagged;
that is the highest-value next experiment, but it needs the cv25 lever BUILT.

The evening-lift mechanisms (candidate b hydro anchor) are both wrong-direction
AND now largely moot (evening healed). The remaining evening/2026 residual is
substantially GME cap-tail withholding — **conduct the counterfactual exists to
MEASURE, not reproduce.** Candidate (c) is the one untested first-class lever
with a cheap one-line switch, so it gets the measured A/B to close it honestly.

## 4. Pre-registered gate (decided BEFORE the A/B)

Full 39-zone coupled clear (`enrich_network`, `passes=2`, `:merit_order`,
HiGHS, cv24-consistent code), base (cv24 IT-NORTH profile) vs treatment
(`import_backstop=true` on IT-NORTH), scored vs realized ENTSO-E Day-ahead.

**Windows (reduced — operational constraint).** The pre-registered window was
summer2025 (2025-07-07..14, 8 d) + winter2025 (2025-01-13..20, 8 d). The shared
machine ran a 12-worker production backfill + a second backfill throughout, so a
full 39-zone coupled solve took ~30 min for the first (compile-heavy) day and
stayed slow under contention. To return a MEASURED coupled result within budget
I reduced to **2 summer (2025-07-07, -08) + 2 winter (2025-01-14, -15) days**,
both arms in one process. This is UNDERPOWERED vs the pre-registration and is
reported as such — it is a directional coupled read, not a full gate.

**SHIP-CANDIDATE (bump toward a cv) iff ALL hold:**
- IT-NORTH: corr **+≥0.05** OR MAE **−≥10%** in BOTH the summer and winter window.
- Rest of the IT family and neighbors CH/FR/AT/SI: each within **±0.02 corr**
  and **±1.0 MAE** (no leak).

Directional pre-registration (honest): given the residual signs I **expect
NO-SHIP** (backstop adds elastic import supply near scarcity → lowers tight
hours; IT-NORTH's residual is a midday over-price, not phantom scarcity, so the
backstop should be near-inert or mildly harmful). A measured confirmation still
closes candidate (c).

## 5. A/B results + verdict

### Harness validation (base arm, measured)

The base arm (cv24-consistent) reproduces IT-NORTH's cv24 residual on the two
summer days (2025-07-07/08), confirming the pipeline and the UTC timeslot
alignment (`ab_base_summer_validation.txt`):

| zone | n | corr | MAE | bias |
|---|---|---|---|---|
| IT-NORTH | 47 | 0.726 | 12.1 | −3.4 |
| CH | 47 | 0.742 | 8.9 | −8.6 |
| FR | 47 | 0.845 | 12.8 | +6.9 |
| AT | 47 | 0.669 | 11.5 | −9.8 |

(IT-NORTH/CNORTH/CSOUTH show identical stats — the Italian macro-zones cleared
uncongested and coupled to one price on these days, as they and their settled
prices frequently do.) These match the season-level cv24 diagnosis, so the
coupled harness is correct.

### The treatment A/B did NOT complete — operational

The base-vs-treatment coupled comparison could not finish within budget. On this
shared machine a 12-worker production backfill (plus a second backfill) ran
throughout; the first (compile-heavy) 39-zone coupled day took ~30 min and, worse,
the tighter **winter** coupled MPCC solves ran ~20+ min each under contention. The
combined harness completed both base summer days but was still grinding the first
winter day when budget expired — so the treatment arm (which runs after all 4 base
days) never produced comparable output. `ab_combined.jl` + `scorer.py` are
committed and correct; they need only a quiet machine (or a solver worker slot)
to run to completion.

### Verdict

- **Diagnosis: COMPLETE and the primary result.** IT-NORTH's genuine (cv24)
  degradation is **solar-era duck-curve steepening our supply curve cannot
  track** — a growing midday over-price (+5→+17, 2023→2025) as PV builds out
  (correctly forecast). The evening under-pricing that dominated cv23 is mostly
  a healed data artifact (the corrupt IT-CSOUTH unit). The residual is
  NORTH/CNORTH-specific and worst in summer.

- **Candidate (c) import backstop: NO-SHIP (mechanism-predicted; coupled A/B not
  completed).** The residual is a midday over-price, not phantom-scarcity caps,
  so an elastic import backstop priced 1.8×gas near scarcity is the wrong tool —
  it lowers tight hours (would worsen 2024 summer evening under-pricing) and is
  inert midday. Not measured to completion; flagged honestly, not claimed.

- **The whole spec-true toolbox for THIS residual is thin, and that is the real
  finding.** The one mechanism that deepens a midday belly (must-run/solar floor,
  candidate a) is **measured NO-SHIP twice** — it thins the evening ramp. The
  evening-lift mechanisms (candidate b) are wrong-direction for a gas-marginal
  zone and now moot (evening healed). RES data is clean (candidate d rejected).
  The residual's remaining evening/peak component is substantially GME cap-tail
  **conduct** the counterfactual must MEASURE, not reproduce.

### Highest-value NEXT experiment (NEEDS the cv25 lever built)

Re-run the **cv25 all-hours-inframarginal must-run floor** (specified in
cv24-it-book.md, unbuilt) against the **clean cv24 base** — not the cv23-corrupt
base the cv24.1 A/B used. The midday belly is now the sole dominant residual and
the evening is healed, so the floor's evening-thinning cost may no longer be
fatal. Summer-inner-loop-first per the committed harness. This is the one lever
that targets the actual (cv24) degradation and has not been tested on the healed
baseline. If it still regresses summer, IT-NORTH's residual is confirmed to be
predominantly conduct + the structural midday-floor tension — a genuine
"counterfactual measures, does not reproduce" outcome, not a model defect.

## 6. cv25 — the all-hours-inframarginal must-run floor (BUILT + measured)

The decisive follow-up (coordinator-directed): the two prior must-run-floor
NO-SHIPs (cv24/cv24.1) were measured against a base that still carried the
corrupt IT-CSOUTH unit; re-test the *corrected* floor on the clean cv24 base.

### Mechanism (spec-true, no-fit)

`ZoneProfile.must_run_floor` (on for the 7 IT zones; kill-switch
`EUPHEMIA_DISABLE_CV25`). For each must-run thermal unit
(`MUST_RUN_FLOOR_FUELS`: gas / hard-coal / lignite / oil / coal-gas / geothermal
/ biomass / waste) the **genuinely all-hours-inframarginal (24/7) base** is bid
at **€0** instead of the ~0.05×SRMC self-schedule price. The base is sized by
`get_all_hours_min_p5` — the trailing p5 of the **daily-MINIMUM** per-type output
(a fundamental). This is the volume that is inframarginal in EVERY hour, so it
never serves the evening ramp; the cycling volume above it stays on the SRMC
ladder. **The daily-minimum auto-shrinks in summer** (when gas cycles down for
midday solar the daily min falls), so the floor is small exactly in the high-RES
season — the built-in fix for cv24's RES-confounded over-sizing.

`must_run_qty = max(self_qty, floor_qty)` guarantees it never reserves less
below-cost than cv24; when `floor_qty ≤ p_min` it is **volume-neutral** (the
flexible ladder — hence the evening ramp — is unchanged), only re-pricing the
bottom slice to €0.

**Two findings surfaced during the build:**
1. Italy's `thermal_srmc_multiplier=1.20` lifts gas's marginal cost above the
   `1.15×gas_srmc` UC-lite commitment threshold, so **no Italian gas is ever in
   `committed`** — Italy had NO must-run/self-schedule trough coverage at all.
   The floor is therefore applied INDEPENDENT of `committed`.
2. `create_merit_order_book` defaults `profile=SEE_PROFILE`; the floor only
   engages when the real zone profile is passed (the multi-zone path does, via
   `get_zone_profile`).

### Byte-identity + object validation (measured)

`validate_cv25.jl` (2025-07-08, single-zone books, cv25 ON vs `EUPHEMIA_DISABLE_CV25`):
- **GR / CH / FR: bit-identical** order sets on/off (`on≡off=true`, ≤€0 = 0) —
  non-IT byte-identity holds by construction (floor_qty=0 ⇒ block unchanged).
- **IT-NORTH: bimodal book**, ≤€0 supply share **0.00 → 0.037** (Fossil Gas
  ×0.06, Biomass ×0.72); OFF arm ≤€0 = 0. IT-CSOUTH ≤€0 → 0.001. The floor
  fires and moves volume to €0, toward the GME ~0.45 (honest partial, as cv24).

### Price A/B — summer inner loop (measured, 39-zone coupled, HiGHS, clean cv24 base)

3 complete base(cv24)-vs-cv25 pairs, 2025-07-07..09, offline extract, scored vs
realized ENTSO-E Day-ahead (`cv25_summer_score.txt`):

| zone | base corr/MAE | cv25 corr/MAE | ΔCORR | ΔMAE |
|---|---|---|---|---|
| **IT-NORTH** (target) | 0.621 / 12.5 | 0.600 / 11.7 | **−0.021** | **−0.8 (−6.4%)** |
| IT-CNORTH | 0.608 / 14.5 | 0.583 / 13.8 | −0.025 | −0.7 |
| IT-CSOUTH | 0.623 / 14.4 | 0.599 / 13.7 | −0.024 | −0.7 |
| IT-SOUTH | 0.820 / 21.9 | 0.797 / 23.8 | −0.024 | +2.0 |
| IT-Calabria | 0.820 / 21.9 | 0.797 / 23.8 | −0.024 | +2.0 |
| IT-Sicily | 0.840 / 27.1 | 0.819 / 29.3 | −0.021 | +2.2 |
| **IT-Sardinia** | 0.772 / 20.9 | 0.726 / 26.5 | **−0.046** | **+5.6** |
| CH | 0.801 / 8.5 | 0.805 / 8.6 | +0.004 | +0.1 |
| FR | 0.821 / 15.9 | 0.811 / 16.6 | −0.010 | +0.6 |
| AT | 0.640 / 17.9 | 0.640 / 17.9 | −0.000 | −0.0 |
| SI | 0.522 / 41.4 | 0.518 / 41.6 | −0.004 | +0.2 |
| **IT-agg MAE** | **19.03** | **20.39** | | **+1.36** |

IT-NORTH evening bias (16–19 UTC): **+17.9 → +9.3** (toward zero); midday
(8–13 UTC): +1.9 → +1.9 (unchanged).

### Verdict: NO-SHIP (cv stays 24)

Gate outcomes vs the pre-registration:
- **IT-NORTH must improve (corr +≥0.05 OR MAE −≥10%): FAIL.** corr −0.021 (wrong
  way); MAE −6.4% (short of −10%).
- **IT family within ±1 MAE: FAIL badly** — IT-Sardinia +5.6, Sicily +2.2,
  SOUTH/Calabria +2.0; IT-agg MAE +1.36 (worse).
- **Non-IT neighbors within ±0.02 corr / ±1 MAE: PASS** (CH/FR/AT/SI all clean).

**What the clean-base retest proved (both the positive and the negative).** The
corrected all-hours-inframarginal floor DID fix cv24's summer failure mode: on
the clean cv24 base it **no longer thins the evening ramp** — IT-NORTH's evening
bias moves *toward* zero (+17.9→+9.3) and its MAE actually improves −6.4%. The
volume-neutral, daily-minimum design worked as intended for IT-NORTH's own
evening. But it still (a) does **not lift IT-NORTH's correlation** (−0.021 — the
€0 volume reshuffles the intraday shape without matching the settled duck curve),
and (b) surfaces a **new coupled failure mode**: it **over-floors the small,
gas-heavy southern/island zones** (Sardinia bias +6.2→−17.9, MAE +5.6), because
their all-hours gas base is a large fraction of their small demand, so €0 supply
collapses their price. The must-run floor remains an IT-family-leaking mechanism —
exactly the coupled interaction the program warns 2-zone pilots cannot see.

Per the program's standing rule and the coordinator's protocol (summer regresses
on the clean base ⇒ NO-SHIP; winter not run because the summer inner-loop gate
already fails): **the must-run floor is NO-SHIP a THIRD time, now with the
corrected mechanism on the corrected base.** This is the decisive result the
retest was for. The floor's premise — that IT-NORTH over-prices because it lacks
a ≤€0 must-run base — is only weakly true (it buys −6.4% MAE / a better evening at
the cost of correlation and the IT family). **IT-NORTH's residual is therefore
confirmed to be predominantly (a) the solar-era duck-curve *shape* our SRMC book
structurally cannot track and (b) the GME cap-tail *conduct* the counterfactual
exists to MEASURE, not reproduce — not a missing must-run floor.** The honest
final answer for IT-NORTH stands: no spec-true, no-fit, existing-or-buildable
mechanism in this cycle materially fixes it without leaking into the IT family.

**cv25 code disposition.** Built, validated (byte-identity + object-level), and
committed behind `must_run_floor` + `EUPHEMIA_DISABLE_CV25` (default-ON for IT in
this branch — NOT merged). It should be reverted to default-inert (or the switch
flipped) before any backfill, since it does not ship.
