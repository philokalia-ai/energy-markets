# cv24 — the Italian must-run floor (a bimodal, first-principles IT book)

Model iteration cv24. Encodes the structural knowledge from the **real GME MGP
book** (the object-level validation of PR #203,
[docs/experiments/gme-book-comparison](gme-book-comparison/README.md)) into an
**ex-ante, first-principles** mechanism for the 7 Italian zones. It is the
program's response to the one measured, physically-real gap the GME comparison
found: our Italian book is a **unimodal SRMC stack with 0% of volume at ≤€0**,
while the real book is **bimodal** — a large must-run floor at ≤€0 (~45% of
offered volume) plus a cap-priced tail.

This document is the pre-registration + decision record. Phase 1 (mechanism
design + object validation + pre-registered gates) is written before the price
A/B; Phase 2 (the measured price gates + decision) is appended after.

---

## The measured gaps (GME comparison, PR #203)

Mean over 3 GME sample days × 7 IT zones × 3 hours (04/12/19), our cv23 book vs
the real GME MGP `UP_` domestic-production offers:

| metric | ours (cv23) | GME real |
|---|---|---|
| share of offered supply at **price ≤ 0** | **0.00** | **0.45** |
| share in mid band 0–150 €/MWh | 0.60 | 0.22 |
| share above 300 €/MWh (cap tail) | 0.10 | 0.11 |
| offered domestic supply MW (our / GME `UP_`) | **1.35×** | 1.00 |

Two consequences, both consistent with the standing IT residual:
1. **We over-price troughs.** The real market prices its low-demand hours on the
   must-run/import floor we structurally cannot represent, so our competitive
   SRMC book clears troughs *above* the real market (real NORD 04:00 €141 vs our
   cheapest dispatchable ≈ gas SRMC €167 in Jan-2023).
2. The cap-priced peak tail is **NOT modeled** — it is the market-power conduct
   residual the counterfactual exists to *measure*, not reproduce.

Plus an incidental data-quality bug: our registry carried a corrupt capacity —
IT-CSOUTH unit `26WUUUUUUBUSSI19` at **13,068,005 MW** — a mangled ENTSO-E
`installed_capacity_mw` that propagates a multi-million-MW supply block into the
book, erasing scarcity and pinning the zone at gas SRMC.

---

## The mechanism (how each part derives from fundamentals)

Everything below is **ex-ante** (D-1-legal) and **no-fit**: no parameter is
tuned to observed prices or observed bids. The GME real book is the *validation
instrument*, never a fitting target. Quantities come from the unit registry
(technology classes), technical minima, and trailing **observed output**
statistics (output is physics; bids are conduct); prices come from the economics
of inflexibility and from fuel/carbon SRMC.

### 1. The must-run floor (bimodal book) — `ZoneProfile.must_run_floor`

The physically-inflexible fuel classes bid their **demonstrated overnight base**
at the price floor (≤€0) instead of SRMC — the competitive bid of inflexibility:
shutdown/restart cost exceeds a few negative-price hours, so this base secures
dispatch at the floor rather than cycle. Two kinds of must-run, both priced off
the **same fundamental**:

- **always-on non-dispatchable classes** — geothermal (baseload, Larderello),
  run-of-river hydro (water must pass), biomass and waste (heat-following
  cogeneration / disposal obligation);
- **the baseload thermal floor** — the overnight-demonstrated minimum of the
  gas / hard-coal / oil fleet is the cogeneration + must-run-CCGT base that stays
  on all night: the "baseload securing dispatch by bidding at the floor" the GME
  book shows, and Italy's largest must-run component.

**Quantity (fundamentals, not bids).** `get_overnight_output_p5(zone, day)` — the
trailing p5 of each type's **00–06 UTC** hourly output (the MW the type
demonstrably never drops below overnight, strictly historical). The must-run
fraction of each type is `must_run_frac[type] = clamp(overnight_p5 / offered
fleet, 0, 1)`; each unit of that type floors `must_run_frac × offered_pmax`. This
is the exact derivation the roadmap prescribes ("a unit's must-run quantity = the
trailing p5 of its overnight output … offered at ≤€0"), generalized from cv10's
absolute must-run below-cost discount into a proper two-part bid.

**Price (economics of inflexibility).** The must-run base is split like cv10's
graduated self-schedule, but the **deep slice (60%) bids at the price floor
(€0)** — the base that never shuts down — and the shallow slice bids **below
cost** (`max(0.5×SRMC, SRMC−40)`); the flexible remainder keeps the SRMC tranche
ladder (scarcity/peak markup intact). This makes the book **bimodal** (a ≤€0
must-run floor + the SRMC tail) while preserving a **convex** low-price region,
so night/high-RES troughs re-price down instead of jumping floor→SRMC.

**Volume-neutral.** The mechanism reprices/reclassifies the *same* offered
capacity; it adds no MW. The 1.35× offered-volume over-count is discussed under
"Volume" below.

### 2. The registry sanity bound — `MAX_PLAUSIBLE_UNIT_MW`

`get_generators` drops any registry row whose installed capacity exceeds
**25,000 MW** — larger than any genuine European generation unit (~1.7 GW single
units; a few GW aggregate rows), so it rejects only garbage. Only IT-CSOUTH
carries such a row in the footprint, so **non-IT zones are byte-identical** either
way. This is the proper upstream fix the GME comparison flagged (previously the
comparison harness merely dropped >5,000 MW rows for its curve math).

### Gating & kill-switch

`must_run_floor` is on for the 7 IT zones (set on `ITALY_PROFILE`;
`ITALY_CNORTH_PROFILE` inherits it). `EUPHEMIA_DISABLE_CV24` reverts **both**
deltas (the floor on every IT profile, and the registry sanity bound) so the EU
book is byte-identical to cv23 main by construction. Worker-safe via ENV like
every other kill-switch.

---

## Object-level validation (the novel gate) — measured

Re-running the GME composition measure on OUR new book (single-zone IT merit book,
`docs/experiments/cv24/object_validation.jl`, 3 GME sample days × hours 04/12/19,
corrupt >25 GW block dropped in both arms):

| zone | base ≤0 | **cv24 ≤0** | GME real ≤0 | offered MW (base→cv24) |
|---|---|---|---|---|
| IT-NORTH | 0.00 | 0.07 | 0.36 | 34,275 → 34,275 |
| IT-CNORTH | 0.00 | 0.13 | 0.64 | 4,119 → 4,119 |
| IT-CSOUTH | 0.00 | 0.02 | 0.27 | 14,480 → 14,480 |
| IT-SOUTH | 0.00 | 0.08 | 0.36 | 7,553 → 7,553 |
| IT-Calabria | 0.00 | 0.04 | 0.34 | 4,329 → 4,329 |
| IT-Sicily | 0.00 | 0.07 | 0.38 | 4,934 → 4,934 |
| IT-Sardinia | 0.00 | 0.12 | 0.79 | 2,620 → 2,620 |
| **aggregate** | **0.00** | **0.08** | **~0.45** | volume-neutral |

The ≤0 share moves **0.00 → 0.08 aggregate**, decisively off zero and toward the
real 0.45. **The gap is honest and expected:** the remaining ~0.37 is (a) the
below-cost intermediate slice our convex must-run parks just *above* €0 rather
than at it (the shape shift is larger than the ≤0-bucket count alone shows), and
(b) the strategic price-taker / reservoir-hydro / **import** must-run the real
book front-loads at the floor — which is either conduct we deliberately do not
model or the import layer this single-zone object omits (imports enter through
the coupled network, not as book orders). Only the **physically-derivable** part
appears, exactly as the roadmap requires.

**Volume ratio stays 1.35×** (the mechanism is volume-neutral by design). The
1.35× is *offered* volume, not cleared: our book floats the whole
commissioned-and-available fleet at SRMC while the real book offers less domestic
production per hour (self-scheduling, bilateral cover, units not bid into MGP).
The over-count sits in the SRMC mid-band **above** the clearing point on almost
every hour, so it is largely price-irrelevant. Reducing it would require
output-truthing the gas fleet's offered quantity — which the crisis-honesty
derate deliberately **excludes** for gas/oil (mid-merit fuels run below capacity
on merit order; their capacity *is* available at SRMC, and derating it
manufactures phantom scarcity). We therefore leave offered volume unchanged and
report the 1.35× honestly as future work, rather than manufacture scarcity to hit
a volume target.

---

## Byte-identity guard — measured

`docs/experiments/cv24/byte_identity.jl` builds the full tagged book on
2023-07-19 with the cv24 mechanism ACTIVE vs the `EUPHEMIA_DISABLE_CV24` switch
(= cv23 main by construction), per zone:

- **GR (single-zone), the SEE 5-zone set (GR/BG/RO/RS/HU), and the continental
  EU sample (DE_LU/FR/NO2/CH/ES): bit-identical** (hash-equal) — the mechanism
  does not leak.
- **All Italian zones change** (the mechanism fires).

Since `EUPHEMIA_DISABLE_CV24` reverts every cv24 delta by construction (all new
code is behind `profile.must_run_floor` or the env guard), non-IT bit-identity
here **is** byte-identity vs main.

---

## Pre-registered price gates (decided BEFORE the A/B)

Full 39-zone coupled clear (`enrich_network`, `passes=2`, `:merit_order`, HiGHS
decomposed) on the offline extract, base (`EUPHEMIA_DISABLE_CV24`) vs cv24,
scored against realized ENTSO-E Day-ahead prices. Windows
(`docs/experiments/cv24/windows_ab.json`): `march2026_stable` (8 d),
`summer2025` (8 d, the JJA evening residual), and a trough-focused
`trough_highres_weekends` (8 high-RES spring weekend days, where the ≤€0 floor
bites in the low-demand midday troughs).

**Ship (bump cv 23→24) iff ALL hold:**
- **IT zones:** aggregate MAE across the 7 improves **≥1.5**; trough hours
  (10:00–16:00 UTC on the high-RES window) bias moves **materially toward zero**;
  **no** IT zone degrades in corr by **>0.03**.
- **Neighbors (CH/SI/AT/FR/GR):** none degrades by **>0.03 corr** or **>1.5 MAE**.
- **Byte-identity:** GR single-zone, SEE 5-zone, EU-with-kill-switch bit-identical
  vs main (measured above — PASS).
- **Object-level:** the ≤0 volume share moves off 0 toward ~0.45 (measured — PASS,
  0.00 → 0.08; gap reported honestly).

If any price gate fails: **no cv bump**, push the branch with an honest
diagnosis, no PR.

---

## Phase 2 — measured price gates + decision

### Directional probe (2026-03-04, full 39-zone coupled clear)

A single-day probe (base = `EUPHEMIA_DISABLE_CV24` vs cv24) before the full run,
scored vs realized ENTSO-E Day-ahead:

| zone | base MAE / bias / corr / eveBias | cv24 MAE / bias / corr / eveBias | ΔMAE |
|---|---|---|---|
| IT-NORTH | 17.7 / −14.2 / 0.65 / −24.8 | 16.1 / −11.9 / 0.68 / +2.8 | **−1.6** |
| IT-CSOUTH | 23.9 / −22.3 / **NaN** / −45.9 | 17.6 / −13.4 / **0.58** / +2.8 | **−6.3** |
| IT-SOUTH | 23.9 / −22.3 / NaN / −45.9 | 17.6 / −13.4 / 0.58 / +2.8 | **−6.3** |
| IT-Calabria | 19.7 / −17.5 / NaN / −45.9 | 13.4 / −8.6 / 0.71 / +2.8 | **−6.3** |
| IT-Sicily | 20.4 / −18.3 / NaN / −49.5 | 13.4 / −9.4 / 0.73 / −0.8 | **−7.1** |
| IT-Sardinia | 26.4 / −24.9 / 0.11 / −26.7 | 27.5 / −20.7 / 0.27 / +10.2 | +1.1 |
| CH | 18.3 / … / 0.97 | 17.7 / … / 0.96 | −0.5 |
| SI | 37.7 / … / 0.91 | 34.1 / … / 0.90 | −3.5 |
| AT | 26.3 / … / 0.93 | 25.3 / … / 0.93 | −1.0 |
| FR | 19.9 / … / 0.89 | 19.5 / … / 0.90 | −0.4 |
| GR | 15.4 / … / 0.95 | 15.4 / … / 0.95 | −0.0 |

**IT aggregate MAE ≈ 21.4 → 17.4 (−4.0)** on this single day. The probe looked
strong, but a single March day does not capture the seasonal behaviour — the full
A/B below shows the mechanism regresses in summer.

### Full 3-window A/B (39-zone coupled, HiGHS, offline extract; base = `EUPHEMIA_DISABLE_CV24` = cv23 main)

`launch_ab.sh` / `fork_arm.sh` (24 days × 2 arms), scored vs realized ENTSO-E
Day-ahead by `score_cv24.jl` (full table in `docs/experiments/cv24/ab/SCORE.txt`).
IT **aggregate** MAE = mean over the 7 IT zones.

| window | IT MAE base → cv24 (Δ) | IT corr | IT evening bias (17–20 UTC) base → cv24 | neighbors |
|---|---|---|---|---|
| **march2026_stable** (8 d) | 19.67 → 17.63 (**−2.04** ✓) | all +0.04..+0.17 | −3..−44 → −11..+7 (toward 0) | pass |
| **summer2025** (8 d) | 18.09 → 20.33 (**+2.24** ✗) | IT-NORTH **−0.16** ✗ (others +0.01..+0.06) | −28..−31 → **+16..+52** (overshoot) | pass |
| **trough_highres_weekends** (8 d) | 20.84 → 19.70 (−1.14) | all +0.02..+0.05 | +6..+11 → +1..+5 (toward 0) | pass |
| **all 24 days** | 19.53 → 19.22 (**−0.31** ✗) | — | — | — |

Neighbor gate (CH/SI/AT/FR/GR): PASS in every window — no neighbor degrades
>0.03 corr or >1.5 MAE; SI/CH/AT/FR mostly improve (e.g. SI summer −1.5 MAE,
March −1.3).

### Decision: NO-SHIP (no cv bump)

Gate outcomes against the pre-registration:
- **IT MAE improves ≥1.5: FAIL.** Overall −0.31 (< 1.5); summer **worsens +2.24**.
- **No IT zone degrades corr >0.03: FAIL.** IT-NORTH corr −0.16 in summer.
- Trough bias toward zero: partial — March and the high-RES-trough window move the
  bias toward zero (the mechanism does exactly what the GME shape gap predicted
  there), but **summer over-corrects** the evening bias to positive.
- Object-level (≤0 share 0→0.08) and byte-identity: PASS (Phase 1).

March and the high-RES trough window are clean wins, but **summer2025 is a clear
regression** (all 7 IT MAE worse, IT-NORTH corr −0.16, evening bias overshoot).
Per the program's standing rule — a win in one regime that costs another does not
ship until the cost is understood and fixed — this is a **NO-SHIP**. cv stays 23.

### Diagnosis: the raw-output p5 must-run size is RES-confounded (under-sizes in summer)

The floor quantity is `must_run_frac[type] × offered`, with `must_run_frac =
(trailing p5 of 00–06 UTC RAW output) / offered`. In the high-RES season the
overnight raw thermal output is **depressed** — gas cycles off overnight when
low demand is covered by must-run RES/imports — so `must_run_frac(gas)` in summer
falls **below** the technical `p_min` that cv23's committed must-run used. cv24
therefore offers *less* below-cost thermal than cv23 in summer, so the coupled
evening clear **rises** (bias −28 → +16..+52) and MAE worsens. In winter/spring
(March; and the spring high-RES *weekends*, whose overnight output is still
thermal-backed) the floor base is well-sized and the mechanism helps. The failure
is a **sizing signal confounded by RES**, not the two-part-bid principle — and it
is the mirror image of what a naïve reading expects (the floor *raises* summer
prices because it thins the below-cost band relative to cv23's p_min base).

### cv24.1 lever — BUILT, measured, also NO-SHIP (the Phase-2 diagnosis was wrong)

Both parts were implemented (`get_overnight_floor_residual_p5` — trailing p5 of
the **summed** overnight 00–06 UTC output of the floor fleet ÷ offered — plus the
hard floor-of-the-floor `must_run = max(mrf_system × offered, min(p_min,
offered))`) and the **summer2025 inner-loop** was run first (base = cv23 vs
cv24.1, 8 days, 39-zone coupled; `fork_summer.sh` / `wait_score_summer.sh`, full
table in `ab_summer/SCORE.txt`). Object gate held (≤0 share 0.09 ≥ cv24's 0.08);
byte-identity held. But summer **regressed harder than cv24**:

| zone | base MAE / eveBias | cv24 ΔMAE | **cv24.1 ΔMAE / Δcorr / cv24.1 eveBias** |
|---|---|---|---|
| IT-NORTH | 14.6 / −28.1 | +2.0 | **+4.3** / −0.16 / −21.2 |
| IT-CNORTH | 15.0 / −30.6 | +2.8 | **+4.9** / −0.00 / **+12.8** |
| IT-CSOUTH | 15.1 / −30.9 | +2.7 | **+4.7** / +0.02 / **+12.6** |
| IT-SOUTH / Calabria | 18.8 / −30.9 | +1.6 | **+4.2** / +0.01 / **+10.3** |
| IT-Sicily | 22.3 / +22.8 | +2.4 | **+4.6** / +0.03 / **+52.1** |
| IT-Sardinia | 22.0 / −23.2 | +2.7 | **+5.3** / +0.02 / **+7.6** |
| **footprint** | mean 23.22 / −6.6 | +0.4 | mean MAE **24.62**, corr 0.641 → **0.607**, eveBias → **+4.5** |

IT aggregate MAE worsens **+4.6** (vs cv24's +2.2); the evening bias flips
positive (+8..+52). The floor-of-the-floor made it **worse, not better** —
**FINAL NO-SHIP for the must-run floor this cycle.** cv stays 23.

### Corrected mechanism reading (why forcing ≥ p_min over-corrected)

The Phase-2 diagnosis — "cv24 under-sized the floor, so raising it to ≥ p_min
fixes summer" — had the **sign backwards**, and cv24.1 falsified it cleanly. The
floor is **volume-neutral but SHAPE-changing**: moving each unit's must-run slice
out of the low SRMC tranches down to ≤€0 **thins the mid-merit tranche ladder**
that serves the steep evening ramp. Meeting the RES-depleted summer evening demand
then climbs **higher** into the (now thinner) marked-up tranches — so the trough
drops but **the evening rises**. cv23's below-cost path already covers the summer
trough, so the extra floor volume does not lower the trough further (it is already
saturated); it only **displaces mid-merit capacity into the evening ramp**,
lifting the peak. Forcing MORE floor volume (≥ p_min) enlarges exactly this
displacement, which is why cv24.1's evening bias (+8..+52) is worse than cv24's.
The mechanism **trades a lower trough for a higher peak** — a bad trade in the
high-RES season, where the evening ramp is the error and the trough is not.

This is the real, honest finding: the two-part must-run bid does reproduce the GME
book's bimodal *shape* (object gate ≤0 share 0 → 0.08–0.09), but on the *coupled
price* it steepens the evening supply curve, and in summer that costs more than
the trough correction is worth. The object-level shape win and the price outcome
point in opposite directions here — exactly the kind of tension the object-level
validation instrument exists to surface.

### Forward lever for cv25 (specified; not built)

Deliver the bimodality **without steepening the evening supply curve** — the floor
must not thin the evening-ramp tranches, and it must be RES-conditional **in a
measured way**, validated **summer-inner-loop FIRST** (the harness now exists):
1. **Floor only the genuinely all-hours-inframarginal volume** — the overnight
   minimum that never has to ramp — and CAP it so the flexible tranche ladder
   keeps its depth for the peak; leave the rest of p_min on cv23's below-cost path
   (do NOT move evening-serving tranche volume to the floor).
2. **Make the floor a strict reclassification of all-hours-inframarginal MW
   only** (never volume the evening needs), so the mid-merit ladder available to
   the evening ramp is unchanged by construction.
Both keep the ≤0 shape gain while leaving the evening supply curve at its cv23
slope; whichever is measured non-regressing in summer first earns a full
3-window run. That is the cv25 iteration.

### Registry sanity bound — split out

The `MAX_PLAUSIBLE_UNIT_MW = 25 GW` guard (the corrupt 13-TW IT-CSOUTH unit) is an
**independently-correct data-hygiene fix**, byte-identity-proven outside
IT-CSOUTH, that fixes IT-CSOUTH's NaN-correlation pathology on its own. It does
**not** depend on the must-run floor, so it ships **separately** on branch
`fix/registry-sanity-bound` (small PR off main). It changes IT-CSOUTH prices, so
it rides into the price record at the next cv bump (coordinator-serialized; no
bump in that PR).
