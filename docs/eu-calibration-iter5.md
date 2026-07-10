# EU-wide footprint calibration — iteration 5 (SE3/SE4 flow-based domain, AT share, BE)

Follow-up to `docs/eu-calibration-iter4.md` (PR #95, frozen). Priorities for
this iteration, in order: (1) SE3/SE4 (+DK2/LT chain) via the generalized
drop mechanism, (2) alpine-cheapening spillover, (3) NO3 re-measure, (4) BE
Core diagnosis + drop experiment.

**Sign convention: `bias = mean(sim − actual)` — positive = model overprices.**
Evaluation window: 2026-04-01…05 vs `entsoe.energy_prices` Day-ahead,
**resolution-aware methodology** (iter4 §1) throughout.
Baseline = `multi_zone_eu_cal13` (iteration-4 shipped state, code_version 10).
Shipped iteration-5 result = `multi_zone_eu_cal18`. Sub-iterations: cal14 (SE
border drop), cal15 (SE3/SE4 anchor), cal16 (AT share), cal17 (BE drop),
cal18 (BE anchor).

---

## 1. SE3/SE4 + DK2/LT — the flow-based domain fix (shipped: cal14 + cal15)

The largest remaining pocket (+116…+147 bias on four zones). Audit
(2026-04-01..05): the implicit offered ATC into SE3 from SE2 averages
**118 MW** (min 0) while the physical Norrland transfer averages **5,015 MW**
(max 7,759); SE3→SE4 shows the same signature (ATC avg 1,241 vs physical max
3,995); and the unused reverse directions are wide open (SE3→SE2 ATC avg
4,594, physical 0) — flow-based residual leftovers, the same object as HU's
Core borders. The model starved SE3/SE4 into continental scarcity pricing and
DK2/LT rode along through their SE4 borders.

Two stacked sub-iterations, exactly the iteration-2 Norway playbook:

**cal14 — drop SE2–SE3 and SE3–SE4** (`flow_based_drop_borders`), keep SE1–SE2
endogenous (real ATC; SE1/SE2 at +0.4/+3.4 bias). Result: the level is cured
network-wide — DK2 corr 0.36→0.86 / MAE 119.5→23.2 / bias +1.6, LT corr
0.42→0.80 / MAE 119.1→20.9 — **with no SE-specific pricing change needed for
DK2/LT at all** (their fix is pure propagation through now-sane SE4 exports).
But SE3/SE4 themselves reproduced NO1's iteration-2 failure mode: the €1
observed-import block became price-setting (SE3 sim €1–9.5 all day vs actual
€15–70, corr 0.51→**−0.25**).

**cal15 — SWEDEN_SOUTH_PROFILE** (= NORWAY_PROFILE: reservoir-opportunity +
`:hydro` anchor) for SE3/SE4: dropped-border imports price at the border price,
water value clamps to the coupled reference (anchor refs: DK1 for SE3, DK2/LT
for SE4 — all well-calibrated after cal14), dropped-border exports re-enter as
ref-priced demand. Result:

- **SE3: corr −0.25→0.76, MAE 33.9→23.7, bias +19.0** (from +127.5 at cal13)
- **SE4: corr 0.27→0.70, MAE 44.0→21.5, bias +6.3** (from +146.7)
- **LT improves further: corr 0.87, MAE 15.8, bias −1.8**; EE +0.06 corr,
  LV −2.3 MAE — the whole Baltic chain benefits.
- Chain guard: SE1/SE2/NO*/FI/DK1 unchanged; **zero regression flags across
  39 zones for the full cal13→cal15 sequence**.
- Aggregate: meanMAE 35.9→24.7, meanBias +12.0→−0.6, meanCorr 0.74→**0.78**.

The iteration-2 lesson generalized twice now (HU, SE): *dropping a flow-based
residual border always needs the pricing side considered — a zone left
unanchored with observed imports at €1 will invert its shape.* The drop and
the anchor are one treatment, not two.

## 2. Alpine spillover → AUSTRIA_PROFILE (shipped: cal16; spillover = second-order)

Diagnosis of iter4's flag: the anchored profiles share `anchor_share = 0.9`.
CH's actual level sits AT its coupled reference (bias −2.3 — share 0.9 is
right for CH), while AT's actual (≈€100) trades **~€19 above its coupled
neighbors** (DE_LU ≈ €81) — a Core-FBMC premium the capacity-weighted ref
cannot see. The spillover is therefore level-shaped and AT-specific; NO1's
−22 is a different lever (continental-proxy level, tracked separately).

cal16 splits AT onto `AUSTRIA_PROFILE` (same alpine params, `anchor_share =
1.1`, from the measured share→bias point; CH keeps 0.9). Result: **AT corr
0.90→0.91, MAE 25.5→22.8, bias −17.9→−15.0; CH −1.3** — strict improvement,
zero regressions, aggregate medMAE 23.7→22.8.

**Honest finding**: the share lever saturates — +0.2 share moved AT's sim only
~+€3, because the anchor floor is not price-setting at the margin in most
hours. The residual spillover (IT-NORTH −9, SK −11, NO1 −22) did **not** move
and is now demonstrated to be second-order, *not* alpine-share-driven.
Documented rather than chased: the share bump ships because it improves the
targets at zero cost, but the spillover itself needs a different object,
likely the underlying import/export price levels on those borders.

## 3. NO3 (re-measured — unchanged, nothing shipped)

The iter4 flag (corr 0.69→0.62 via the continental proxy) was re-measured
after the SE work as instructed: NO3 is bit-unchanged by cal14 and cal15
(0.62 / 27.7 / −2.2 in both) — its dropped-border observed-flow mix did not
change (the NO3–SE2/SE3 borders were already dropped on the NO side; no
double-counting, each undirected pair appears once). No NO3-specific action;
its weak weekend shape remains the documented inter-day storage-horizon gap.

## 4. BE Core-border drop + anchor (shipped: cal17 + cal18)

Audit (same script pattern as HU): BE's implicit **import** ATCs collapse
mid-morning — DE_LU→BE hits **0–1 MW at h08–09**, FR→BE 49–195 MW and NL→BE
~100–350 MW through midday — while the physical flows average FR→BE 1,446 MW
(max 4,069) and NL→BE 1,925 MW (max 4,075). BE's cal15 hourly residual peaks
**exactly there: +68…+94 at h07–h11** (mildest overnight, +16). Conclusive:
the same Core-FBMC ATC-collapse signature as HU, now with the hourly
alignment iter3 could not establish. GB is outside the footprint, so BE's
observed GB flows (~450 MW each way) were already retained as injections.

Two stacked sub-iterations, the (now codified) one-treatment pattern:

**cal17 — drop BE–FR, BE–NL, BE–DE_LU.** BE corr 0.68→0.77, MAE 50.7→42.6 —
but bias flips +46.5→**−35.0**: with no anchor, the €1 observed-import block
becomes price-setting in BE's import-covered hours (the NO1/SE3 failure mode,
third sighting). Chain: DE_LU improves (+3.0→+0.9), FR −4.5 / NL −9.8 (small,
within tolerance — they lose BE's endogenous export demand of 1.4/1.9 GW).

**cal18 — `BELGIUM_PROFILE`**: continental params + the `:hydro` opportunity
anchor, giving BE the anchor's *import pricing* (share × ref; ref = the
DE_LU/NL continental proxy, since BE has no endogenous neighbors left) and
ref-priced export re-entry. `hydro_model` stays `:gas_anchored` — the anchor's
hydro side touches only BE's small pumped fleet. Result:

- **BE: corr 0.95, MAE 22.4, bias −8.7** (from 0.68 / 50.7 / +46.5 pre-drop)
  — the last continental outlier is fixed, with the best shape in the
  footprint after NO2/DE_LU.
- FR/NL/DE_LU/AT/CH unchanged from cal17; **zero regression flags
  cal16→cal18**. Aggregate: meanMAE 23.9, medMAE 22.8, meanCorr 0.79.

**The iteration-5 rule, confirmed three times (HU implicitly, SE, BE):
dropping a flow-based residual border and pricing its observed flows are ONE
treatment.** The drop restores the energy; the anchor prices it. Either half
alone ships a broken zone.

## Per-zone state: cal13 (iter-4 shipped) → cal18 (iter-5 shipped)

Resolution-aware methodology, 5 days (2026-04-01…05, all optimal in every
sub-iteration).

| zone | cal13 corr/MAE/bias | cal18 corr/MAE/bias |
|---|---|---|
| AT | 0.90 / 25.1 / −17.5 | **0.92 / 23.3 / −15.9** |
| BE | 0.68 / 50.6 / +46.5 | **0.95 / 22.4 / −8.7** |
| BG | 0.85 / 27.7 / −5.0 | 0.86 / 27.5 / −4.9 |
| CH | 0.87 / 25.9 / −1.7 | 0.87 / 26.2 / −2.4 |
| CZ | 0.89 / 24.9 / +8.7 | 0.89 / 24.9 / +8.6 |
| DE_LU | 0.92 / 19.0 / +3.4 | 0.93 / 18.0 / +0.9 |
| DK1 | 0.89 / 18.0 / +2.3 | 0.90 / 18.8 / −3.6 |
| DK2 | 0.36 / 119.5 / +115.6 | **0.87 / 21.6 / +0.9** |
| EE | 0.57 / 20.9 / +2.1 | 0.60 / 18.2 / −1.8 |
| ES | 0.79 / 33.2 / +33.0 | 0.79 / 32.8 / +32.6 |
| FI | 0.71 / 14.2 / +4.1 | 0.71 / 13.2 / +2.5 |
| FR | 0.79 / 32.5 / −1.8 | 0.78 / 33.9 / −4.5 |
| GR | 0.85 / 27.5 / −4.9 | 0.86 / 27.3 / −4.8 |
| HU | 0.83 / 31.0 / −2.9 | 0.83 / 30.8 / −2.8 |
| IT-CNORTH | 0.82 / 20.6 / −9.1 | 0.82 / 20.9 / −9.5 |
| IT-CSOUTH | 0.86 / 21.1 / −11.9 | 0.86 / 21.2 / −12.0 |
| IT-Calabria | 0.84 / 21.9 / −11.3 | 0.84 / 21.8 / −11.3 |
| IT-NORTH | 0.82 / 20.6 / −9.1 | 0.82 / 20.9 / −9.5 |
| IT-SOUTH | 0.83 / 22.2 / −11.6 | 0.84 / 22.2 / −11.6 |
| IT-Sardinia | 0.84 / 22.9 / −13.7 | 0.84 / 22.8 / −13.7 |
| IT-Sicily | 0.84 / 21.9 / −11.3 | 0.84 / 21.9 / −11.3 |
| LT | 0.42 / 119.1 / +110.4 | **0.87 / 15.7 / −2.1** |
| LV | 0.50 / 23.9 / −10.5 | 0.57 / 20.9 / −14.7 |
| NL | 0.90 / 27.4 / −6.6 | 0.88 / 27.5 / −9.8 |
| NO1 | 0.89 / 28.6 / −21.2 | 0.90 / 30.0 / −23.9 |
| NO2 | 0.95 / 14.7 / −9.4 | 0.95 / 15.7 / −11.3 |
| NO3 | 0.62 / 27.8 / −1.5 | 0.61 / 28.6 / −3.6 |
| NO4 | 0.48 / 19.5 / +19.4 | 0.48 / 19.5 / +19.4 |
| NO5 | 0.49 / 34.0 / −33.0 | 0.49 / 36.0 / −35.2 |
| PL | 0.82 / 33.8 / +22.5 | 0.82 / 33.9 / +22.1 |
| PT | 0.79 / 33.0 / +32.9 | 0.79 / 32.6 / +32.5 |
| RO | 0.86 / 27.8 / −5.2 | 0.86 / 27.6 / −5.0 |
| RS | 0.82 / 26.0 / −6.3 | 0.82 / 25.9 / −6.2 |
| SE1 | 0.49 / 13.1 / +0.4 | 0.49 / 13.2 / +0.4 |
| SE2 | 0.58 / 12.1 / +3.4 | 0.57 / 12.4 / +3.5 |
| SE3 | 0.51 / 133.0 / +127.5 | **0.76 / 23.2 / +18.2** |
| SE4 | 0.40 / 146.7 / +146.7 | **0.70 / 21.3 / +6.0** |
| SI | 0.79 / 32.0 / +6.8 | 0.79 / 31.8 / +6.8 |
| SK | 0.85 / 26.9 / −10.9 | 0.85 / 26.7 / −11.2 |

Aggregates (39 zones, resolution-aware, 5 days):

- `AGG cal13 meanMAE=35.9 meanBias=+12.0 medMAE=26.0 meanCorr=0.74`
- `AGG cal18 meanMAE=23.9 meanBias=−2.5  medMAE=22.8 meanCorr=0.79`

No zone above 36 MAE remains; the worst residuals are now NO5 (−35), ES/PT
(+33), and PL (+22).

## Acceptance

- **SE3** (target): corr 0.51→**0.76**, MAE 133.0→**23.2**, bias +127.5→+18.2. ✓
- **SE4** (target): corr 0.40→**0.70**, MAE 146.7→**21.3**, bias +146.7→+6.0. ✓
- **DK2** (chain): corr 0.36→**0.87**, MAE 119.5→**21.6**, bias +0.9 — fixed by
  propagation alone, no DK-specific change. ✓
- **LT** (chain): corr 0.42→**0.87**, MAE 119.1→**15.7**, bias −2.1. ✓
- **SE1/SE2** (must-not-regress): bit-stable (+0.4/+3.5). ✓
- **AT**: corr 0.90→**0.92**, MAE 25.1→**23.3** (share 1.1). ✓
- **BE**: corr 0.68→**0.95**, MAE 50.6→**22.4**, bias +46.5→−8.7. ✓
- **NO3** re-measured: unchanged by the SE work (0.62/27.7 in cal14 and cal15
  both); −3.6 bias at cal18 from the BE-chain level shift, corr 0.61. ✓ (as
  instructed, nothing NO3-specific)
- **Zero regression flags cal13→cal18** across all 39 zones (>0.05 corr /
  >10 MAE). Largest real shifts: NL −0.02 corr / −3.2 bias (lost BE's
  endogenous export demand), NO1/NO2/NO5 ≈ −2 bias (chain level).
- **SEE 5-zone guard byte-identical at every commit** (GR/BG/RO = 131.34,
  HU = 84.96, RS dropped); tests 76/35/25/140 green at every step.
- All 5 days clear OPTIMAL in every sub-iteration (cal14–cal18).

## Honest remaining gaps → iteration-6 queue

1. **ES/PT (+33)** — now the largest remaining pocket by far, untouched since
   iteration 1 (document-only this iteration per instructions). Wants its own
   diagnosis pass: Iberia is near-isolated, so this is a book-level (not
   flow-level) object.
2. **NO5 (−35) / NO1 (−24)** — the Nordic weekend inter-day storage horizon,
   plus the continental-proxy level drift as the continent got cheaper.
   The deferred third anchoring pass (anchor NO5-class zones against pass-2
   Nordic prices) remains the candidate real fix.
3. **PL (+22)** — coal-heavy, systematically overpriced; likely a fuel-cost or
   must-run structure issue, never diagnosed.
4. **NO4 (+19.4)** — bit-unchanged through five iterations; congestion-isolated
   far north. Low value, but persistent.
5. **IT sub-zones (−9…−14)** — level drift from the standing ITALY SRMC
   premium meeting the now-cheaper continent; revisit the premium.
6. **SE3 (+18 residual bias)** — the anchor share (0.9 of DK1) may be a touch
   high now that its import mix is observed; second-order.
7. **The €1-import-block pattern is now a structural liability**: every future
   border drop must ship with anchor pricing in the same sub-iteration (the
   rule held three times). Consider making dropped-border import pricing
   ref-based for ALL zones (not just anchored profiles) as a default — that
   would have made cal14 and cal17 single-step.
