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

_(appended after the A/B)_
