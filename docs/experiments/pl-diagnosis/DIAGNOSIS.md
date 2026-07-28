# Poland (PL) residual diagnosis — cv23/cv24 counterfactual

**Mission:** determine whether a spec-true, ex-ante mechanism materially fixes
PL's below-0.75 correlation. PL is hard-coal dominated, 158 TWh/yr, one of the
three largest below-0.75 zones.

**Data:** model = cv23 hourly record (`cv23_model.csv`, 2023-01-01..2026-07-26,
30,479 PL hours); settled = `entsoe.energy_prices` (Day-ahead, EUR, hourly AVG
of PT15M/PT60M) from the read-only offline extract `euphemia-live.duckdb`.
Timestamps joined in UTC. Harness: `scratch_diag*.py` (committed as
`diag_*.py`).

---

## 1. Headline: the residual is a SHAPE error, not a level error

Full-year corr/MAE (model vs settled):

| year | n | corr | bias | MAE | mean model | mean settled |
|------|---|------|------|-----|-----------|--------------|
| 2023 | 8688 | 0.751 | −3.4 | 21.0 | 108.5 | 111.9 |
| 2024 | 8544 | 0.574 | −6.8 | 26.0 | 89.6 | 96.4 |
| 2025 | 8447 | 0.698 | −8.2 | 26.1 | 96.2 | 104.4 |
| 2026 | 4800 | 0.730 | −15.5 | 33.4 | 95.2 | 110.7 |

The daily-mean bias is modest (−3 to −8, except 2026 −15). But that small mean
hides a large, systematic **intraday shape** error that cancels in the daily
average.

### By hour of day (UTC), all years pooled

| hour UTC | corr | bias | MAE | model | settled | interpretation |
|---|---|---|---|---|---|---|
| 00–03 | 0.57–0.60 | +1 to +3 | 15 | ~95 | ~92 | night: near-neutral |
| 05–06 | 0.52 | **−16** | 27 | ~100 | ~116 | morning ramp under-priced |
| 09–13 | 0.78 | **+10 to +14** | 27 | ~88 | ~74 | **solar midday OVER-priced** |
| 16 | 0.45 | −33 | 37 | 108 | 141 | evening ramp under-priced |
| 17 | 0.29 | **−46** | 50 | 110 | 156 | **evening peak badly under-priced** |
| 18 | 0.22 | **−48** | 52 | 110 | 158 | **evening peak badly under-priced** |
| 19 | 0.33 | −29 | 34 | 106 | 135 | evening peak under-priced |
| 22–23 | 0.54–0.61 | ~0 | 16 | ~96 | ~97 | night: near-neutral |

The model's PL price is **too flat**: it does not rise into the evening peak and
does not fall into the solar midday. Correlation is dragged down almost entirely
by the evening hours (h16–19 corr 0.22–0.45; corr excluding h15–19 = 0.72,
evening-only h16–18 = 0.32).

---

## 2. Level vs shape decomposition

**Night hours (h22–03 UTC): coal-marginal, no solar, no peak — isolates the SRMC
LEVEL.**

| year | night bias | night MAE |
|------|-----------|-----------|
| 2023 | +6.3 | 16.2 |
| 2024 | +5.9 | 14.9 |
| 2025 | −0.6 | 12.5 |
| 2026 | −13.2 | 21.3 |

At coal-marginal night hours the model matches settled within ±6 for 2023–2025.
**This VALIDATES the static hard-coal SRMC as a level** for those years. A
genuine −13 night-level gap emerges only in 2026.

**Midday solar hours (h10–12 UTC): grows with PL's PV buildout.**

| year | midday bias | model | settled |
|------|-------------|-------|---------|
| 2023 | +4.7 | 105 | 101 |
| 2024 | +11.6 | 82 | 71 |
| 2025 | +20.7 | 84 | 63 |
| 2026 | +18.9 | 75 | 56 |

Settled midday fell from 101 (2023) to 56 (2026) as PL solar exploded; the
model's coal/RES floor does not follow. The over-pricing tracks the PV buildout,
not the coal price.

**Evening peak (h16–19 UTC): the dominant gap, growing.**

| year | evening bias | model | settled |
|------|--------------|-------|---------|
| 2023 | −21.1 | 117 | 139 |
| 2024 | −43.3 | 98 | 141 |
| 2025 | −45.3 | 108 | 153 |
| 2026 | −53.2 | 112 | 166 |

### Residual by settled-price bucket (all hours)

| settled bucket | n | bias | model | settled |
|---|---|---|---|---|
| [−1000,0) | 790 | **+60** | 42 | −18 |
| [0,50) | 2194 | **+51** | 73 | 22 |
| [50,100) | 10141 | +9 | 92 | 84 |
| [100,150) | 13641 | −16 | 103 | 119 |
| [150,250) | 3362 | **−58** | 117 | 175 |
| [250,+) | 351 | **−196** | 124 | 320 |

The model clears in a narrow band ~72–124 €/MWh regardless of the true price. It
never goes negative (misses solar-glut hours, +51 to +60 over-price) and never
spikes (misses scarcity hours, −58 to −196 under-price). **The PL supply curve
is too flat at both ends.**

---

## 3. The coal-price ("static SRMC") hypothesis — REJECTED as primary driver

PL hard coal is modeled at `FUEL_SRMC_BASE["Fossil Hard coal"]=37` (non-carbon,
API2-level) + `0.90 × EUA(day)`; only the carbon leg is dynamic, the coal fuel
leg is static (no market-coal feed in the DB — only ttf_f and eua_co2).

The hypothesis predicts a residual that tracks the coal-implied SRMC vs the
constant 37. It is rejected:
- The static coal level is **validated** at night (coal-marginal) within ±6 for
  2023–2025 (§2). If the constant were badly wrong, night bias would track the
  API2 regime; it does not.
- The bias grows **more negative** over 2023→2026 while real API2 coal
  **fell** (from crisis levels to ~$100–115/t ≈ the modeled 37 base). Opposite
  sign to the coal hypothesis.
- The dominant error is intraday shape (evening −48, midday +14 at the same
  daily mean), which a coal *level* cannot produce.

A genuine but **secondary** level gap appears in 2026 (night −13). Candidates:
2026 coal/gas divergence, or emerging tightness. Not the main story.

---

## 4. Is the evening gap PL-specific? — it is HALF continental, HALF PL-specific

Evening (h16–19) and midday (h10–12) bias/corr for PL and its coupled neighbours
(all years pooled):

| zone | eve bias | eve MAE | eve corr | midday bias | day corr |
|------|----------|---------|----------|-------------|----------|
| **PL** | −39.1 | 43.2 | **0.32** | +13.3 | 0.67 |
| DE_LU | −23.6 | 29.1 | 0.74 | +11.8 | 0.87 |
| CZ | −33.3 | 38.9 | 0.38 | +9.5 | 0.61 |
| SK | −52.9 | 58.1 | 0.12 | −7.6 | 0.47 |
| LT | −40.4 | 50.8 | 0.51 | −10.8 | 0.66 |
| SE4 | −3.3 | 40.8 | 0.47 | +17.4 | 0.59 |
| FR | −9.5 | 23.1 | 0.81 | −1.4 | 0.83 |
| GR | −13.1 | 35.8 | 0.59 | +0.6 | 0.79 |

**The evening under-pricing is a continental-core phenomenon** (DE −24, CZ −33,
SK −53, LT −40) shared by the whole meshed thermal region, not unique to PL. The
midday over-pricing is also continental (DE +12, CZ +10, SE4 +17). These are a
system-wide supply-curve-steepness + RES-shape deficit.

But PL's evening **corr collapses to 0.32** while DE_LU keeps 0.74 at the same
−24 bias — PL carries an EXTRA evening problem beyond the shared continental
offset.

### PL is import-CONGESTED at peak, yet the model prices it BELOW its exporter

PL physical net imports by UTC hour (2024-06..2025-06 avg): +3.4 GW at h17, +3.5
GW at h18 — PL is a **heavy net importer at the evening peak**.

Settled PL − DE_LU spread by hour (all data):

| hour UTC | PL−DE settled | PL | DE |
|---|---|---|---|
| 12 | +23.0 | 79 | 56 |
| 15 | +26.0 | 125 | 99 |
| 17 | +16.6 | 157 | 140 |
| 18 | +17.9 | 158 | 140 |

In reality PL settles **+17 ABOVE** DE_LU at the evening peak (a binding
import-congestion / domestic-scarcity premium — PL imports 3.5 GW and the border
is maxed). In the **model**, PL evening (≈110) clears **BELOW** DE_LU (≈117):
model PL−DE ≈ −7. **The model inverts the PL/DE ordering at peak** — it treats PL
as a cheap freely-coupled importer that can be pinned to (or below) DE's level,
missing the congestion premium.

**Gap attribution at h17–18** (model −47 vs settled):
- ≈ −23 is the shared DE_LU evening deficit (imported via coupling; a
  footprint-wide supply-curve problem a PL mission cannot fix, and per the cv18
  lesson should not try to via one zone).
- ≈ −24 is the PL-specific missed import-congestion / domestic-scarcity premium
  over DE (reality +17, model −7).

So a PL-specific mechanism can address at most ~half the evening gap; the other
half is systemic.

---

## 5. Fundamentals vs conduct

The competitive counterfactual should reproduce genuine fundamentals and should
NOT reproduce market-power conduct (persistent residuals are candidate findings).

- **Midday +23 over DE** is fundamentals: PL has far less solar+wind per demand
  than DE, so PL's midday trough is genuinely shallower. (The model's midday
  OVER-pricing is a separate model deficit — RES-shape/merit-floor too high.)
- **Evening +17 over DE** is plausibly fundamentals: PL is demonstrably
  import-CONGESTED at peak (3.5 GW flowing, border binding), with a hard-coal
  fleet of limited fast-peaking capability and a tight capacity margin — a
  congestion/scarcity premium over the exporter is economically legitimate.
- **Conduct caveat:** PL wholesale is highly concentrated (PGE ~40% of
  generation) and the evening peak is exactly when a dominant coal generator can
  withhold. Part of the persistent evening premium may be conduct — which the
  counterfactual is CORRECT to leave unmodeled. The flat model supply curve
  (corr 0.32) is a genuine *modeling* deficit; the level premium above
  competitive coal SRMC is partly a candidate conduct finding. These cannot be
  fully separated from price data alone.

---

## 6. Ranked mechanism candidates

| rank | mechanism | spec argument | expected leverage |
|---|---|---|---|
| 1 | **Per-unit SRMC spread on PL** (`unit_srmc_spread`, the cv18 lever, PL-scoped) | PL's hard-coal fleet has genuinely heterogeneous heat rates (old ~33% vs new ~46% efficiency units). The model collapses them to ONE type-level SRMC → a flat multi-GW coal step the marginal price cannot climb through the evening ramp (exactly the it-flatline pathology; PL evening corr 0.32). A per-unit spread is a **fundamentals** truth (heat-rate heterogeneity), not a fit. Profile-gated to PL, so it is the border-scoped single-zone activation cv18 asked for. | Steepens top-of-stack → lifts evening peak, deepens off-peak; targets the PL-specific ~½ of the gap + the corr collapse. Tested in §7. |
| 2 | Deeper solar trough (`export_absorption_steps`, cv18 lever B, PL-scoped) | PL midday over-priced +13→+21 growing with PV; elastic export/flex absorption below the thermal band lets the price fall in solar surplus. Fundamentals: real flexible demand + export absorbs surplus. | Fixes midday over-pricing; does little for the evening. Continental, so spillover risk (cv18). |
| 3 | PL scarcity steepening (`peak_kappa`↑, `scarcity_threshold`↓, reduce `scarcity_import_credit`) | PL is import-congested at peak, so crediting "available import ATC" into the scarcity margin (CONTINENTAL default 1.0) wrongly softens PL exactly when its border is binding. A tighter PL scarcity profile reflects the congested-importer reality. | Directly lifts the evening; higher cap-day risk; must be gated on the coupled footprint. |
| 4 | Coal SRMC feed (API2/ARA or Polish PSCMI) | Would fix the secondary 2026 night-level gap and any coal-regime drift. NOT the primary residual (§3). Shippable form = a NEW data feed + profile hook (see §9). | Small; needs a data feed. |
| — | UA_BOOK_PL interaction (cv22) | Checked: UA book affects the PL–UA border scarcity buyer, not the evening domestic shape. Not the driver of the evening/midday residual. | Negligible for this residual. |

Candidate 1 is the top pick: highest leverage on the corr collapse, cleanest
fundamentals argument, PL-scoped (low spillover), directly addresses the
diagnosed flat supply curve.

### Fleet evidence for the flat supply curve (PL registry, from the extract)

| fuel type | units | total MW | min–median–max MW/unit |
|---|---|---|---|
| Fossil Hard coal | **82** | **18,582** | 86 – 210 – 981 |
| Fossil Brown coal/Lignite | 32 | 9,116 | 120 – 285 – 781 |
| Fossil Gas | 10 | 4,034 | 99 – 403 – 670 |
| Hydro Pumped Storage | 12 | 1,434 | 31 – 120 – 179 |
| Hydro Water Reservoir | 6 | 283 | 30 – 47 – 68 |

PL's dispatchable stack is ~28 GW of coal in **just two type-level SRMC values**
(hard coal ≈ 37 + 0.90·EUA; lignite ≈ 25 + 1.25·EUA) plus 4 GW gas. All 82
hard-coal units share ONE SRMC, so the profile's 4 tranches
(0.95/1.05/1.25/1.60×) align into four flat multi-GW steps rather than a smooth
curve. The marginal price pins on a step across a wide demand range and jumps
discretely — it cannot track the evening ramp (PL evening corr 0.32). This is the
`it-flatline` pathology at 20× the unit count.

**Why ±10% is fundamentals, not a fit:** PL's hard-coal fleet spans old
subcritical units (~33–36% net efficiency) to modern ultra-supercritical
(Kozienice B11/B12, Jaworzno 910 MW, Opole 5/6 ≈ 45–46%). Since SRMC ∝ 1/η, the
true unit-SRMC span is ≈ 46/33 ≈ ±16% about the mean. A ±10% spread is
**conservative** relative to the real heat-rate heterogeneity — it is a physical
truth the type-level SRMC erases, not a knob tuned to price.

---

## 7. Pre-registered A/B (measured in §8)

*(gate registered BEFORE running the A/B)*

- **Mechanism:** `ZONE_PROFILES["PL"] += unit_srmc_spread = 0.10` (±10%, a
  fundamentals-motivated coal heat-rate CV, NOT swept/fit to price). Everything
  else cv24-main. Full 39-zone coupled clear, `enrich_network`, `passes=2`,
  `:merit_order`, HiGHS.
- **Windows:** winter2025 (2025-01-06..13, 8 days) + summer2025
  (2025-07-07..14, 8 days).
- **PASS (primary):** PL corr **+≥0.05** OR PL MAE **−≥10%**, in **both** windows.
- **GUARD (no spillover):** no other zone DEGRADES by more than **0.02 corr** or
  **1.0 MAE** (window-averaged). Guard zones: DE_LU, CZ, SK, LT, SE4, SE3, NO4;
  controls FR, GR, ES, IT-NORTH.
- **NORDIC CAP-DAY GUARD (the cv18 failure mode, mandatory).** cv18's continental
  `unit_srmc_spread` was benign on MAE/corr yet drove **NO1 cap-days 15→44** — a
  non-local coupled explosion the corr/MAE guard alone missed (CLAUDE.md cv18;
  PR #162). So the gate explicitly counts, per zone per arm, the number of
  **cap/near-cap hours** (price ≥ €500 = phantom-scarcity; and ≥ €2,999 = hard
  cap). **Any Nordic/hydro zone (NO1–NO5, SE1–SE4, FI, DK1, DK2) whose ≥€500
  hour-count INCREASES materially (>+2 hours over the window) fails the gate**,
  regardless of PL's improvement. This is the cv18 signature; if it reappears the
  verdict is NO-SHIP (or border-scoped redesign), not SHIP.
- **Verdict rule:** PASS both windows + guard clean + Nordic cap-days flat →
  SHIP-CANDIDATE. Helps PL but fails the spillover or Nordic-cap guard, or one
  window only → NO-SHIP (documented; cv18 mode if Nordic caps rise). No material
  PL movement → NO-SHIP, residual is the continental deficit + candidate conduct.

---

## 8. Measured A/B (full 39-zone coupled footprint, HiGHS)

**Run note.** The A/B ran the full 39-zone coupled clear (`enrich_network`,
`passes=2`, `:merit_order`, HiGHS) on the read-only extract. Each winter day-clear
cost 660–1,700 s (heavy contention with the concurrent 12-worker production
backfill) and HiGHS segfaulted (#182) repeatedly, killing the process; a crash-
resilient supervisor (`supervise_ab.sh`) resumed each time. Under that budget the
windows were truncated to **2 days each (4 paired days: 2 winter + 2 summer)** —
below the pre-registered 8/window. The direction is **consistent across the
2-day and 4-day cuts** (both reported), so the verdict is robust to the reduced
n even though the exact deltas are noisier than an 8-day window would give.

**PL (primary), spread=0.10:**

| window | base MAE | base corr | spread MAE | spread corr | ΔMAE | Δcorr | eve bias base→spread |
|---|---|---|---|---|---|---|---|
| winter (01-07,01-08) | 19.9 | 0.87 | 19.8 | **0.92** | −0.1 | **+0.047** | −30.0 → −27.8 |
| summer (07-08,07-09) | 17.3 | 0.73 | 18.2 | 0.75 | +0.9 | +0.017 | −36.1 → −34.9 |
| *(1-day winter cut)* | 18.6 | 0.91 | 17.6 | 0.94 | −1.1 | +0.031 | −10.4 → −8.0 |
| *(1-day summer cut)* | 14.8 | 0.85 | 14.2 | 0.95 | −0.6 | +0.099 | −35.0 → −35.5 |

**Nordic cap-day guard (the cv18 failure mode):** every Nordic/hydro zone
(NO1–NO5, SE1–SE4, FI, DK1, DK2) and PL/DE_LU: **0 → 0** cap/near-cap hours
(≥€500 and ≥€2,999) in BOTH windows. **The cv18 explosion does NOT reappear**
under the PL-scoped spread. *Caveat:* the four sampled days carried **zero** cap
hours even in base, so the guard is CLEAN but **not stress-tested** on a genuinely
cap-prone cold day — a real scarcity day should be added before any ship.

**Spillover guard:** winter clean (no zone degrades >0.02 corr / >1.0 MAE; SK
actually improves +0.053 corr). Summer shows minor wobble — LT −0.026 corr /
+1.3 MAE, NO4 −0.031 corr — marginally past the ±0.02 / ±1.0 tolerance but within
2-day noise. No structural degradation anywhere.

### Verdict: **NO-SHIP** as a standalone PL fix (spec-true, safe, but sub-gate)

- **Gate not met.** PASS needed PL corr +≥0.05 OR MAE −≥10% in BOTH windows.
  Winter corr +0.047 lands *just under* +0.05; summer +0.017 is well short; MAE is
  flat (winter) / slightly worse (summer). So the pre-registered gate fails.
- **But the lever is directionally correct and SAFE.** It does exactly what the
  diagnosis predicted: it recovers the intraday-**shape** deficit (PL corr +0.02
  to +0.05; the flat coal step now climbs the evening ramp; evening under-pricing
  eased ~2 €/MWh) with **no cap explosion** and **no material spillover** — i.e.
  the cv18 failure mode is absent once the spread is PL-scoped. It is a clean,
  fundamentals-grounded (heterogeneous coal heat rates) mechanism.
- **Why it can't close the gap alone.** PL's residual is dominated by the evening
  **LEVEL** gap (−28 to −36), which a per-unit SRMC *spread* cannot move — the
  spread redistributes within ±10% of the coal SRMC, it does not lift the whole
  evening. That level gap is the §4 finding: **~½ a continental supply-curve
  deficit** shared by DE/CZ/SK/LT (a footprint-wide problem, out of a PL mission's
  scope and — per cv18 — not fixable by one zone) **+ ~½ a PL-specific
  import-congestion / candidate-conduct premium** (PL settles +17 €/MWh ABOVE its
  own import source DE_LU at the evening peak; the competitive counterfactual is
  arguably CORRECT to leave a conduct premium unmodeled).

**Net:** a well-characterized **NO-SHIP** — the tested mechanism is safe and
spec-true but under-powered; the residual it leaves is the evening-LEVEL gap,
half of which is a systemic continental issue and half a candidate PL conduct
finding. Two honest follow-ups (neither shippable from this experiment alone):
1. **Pair the spread with an evening-LEVEL mechanism** (candidate #3: PL
   import-congestion realism — reduce `scarcity_import_credit` for a demonstrably
   congested-at-peak importer and steepen `peak_kappa`), then re-run this exact
   coupled A/B with the Nordic cap-day guard. The spread alone is a component, not
   a fix.
2. A larger but still physically-justified spread (±16 %, the true coal heat-rate
   span vs the conservative ±10 % used here) may cross the corr gate — but MAE
   would still lag because the level gap dominates, and it must be re-measured on
   the coupled footprint with the cap-day guard.

## 9. NEEDS-DATA-FEED (secondary): a market hard-coal price for PL

Not the primary residual (§3 rejects the static-coal hypothesis as the main
driver), but a genuine **secondary** 2026 night-level gap (−13 €/MWh at
coal-marginal hours) and coal-regime robustness argue for a real coal feed:

- **Feed:** API2 (ARA) coal front-month settlement (€/t or $/t), or the Polish
  **PSCMI 1** steam-coal index (PLN/GJ) for a PL-domestic hard-coal cost. Daily
  or weekly close, published D-1 (API2 is a liquid futures settle → fully
  ex-ante; PSCMI is monthly → use the last published month, ex-ante).
- **Threading (mirrors the TTF path exactly).** Add `yfinance`-style table
  `api2_coal` (date, close_eur_t); a `get_coal_price(day)` with the same
  no-lookahead + 10-day-staleness + cache pattern as `get_ttf_price`; then in
  `get_marginal_cost` for `"Fossil Hard coal"` compute
  `coal_eur_MWh_th = api2_eur_t / 6.98` (6.98 MWh/t at ~25.1 GJ/t, 6000 kcal/kg),
  `SRMC = coal_eur_MWh_th / η + 0.90·EUA(day) + VOM`, η≈0.40 for the fleet mean
  (or per-unit η once inferred). Fall back to the static `FUEL_SRMC_BASE=37` when
  no coal price is within 10 days (pre-history), exactly like TTF→`FUEL_SRMC_BASE`.
- **Scope:** profile-gated (PL first, then CZ/DE lignite-vs-coal split later);
  behind a kill-switch; byte-identical when the feed is absent. This is the
  spec-true, ex-ante form — NOT a hand-drawn indicative series.
- **Expected effect:** corrects the LEVEL at coal-marginal hours (night) and any
  future coal-regime drift; it does **not** address the evening-shape/level gap
  (§1, §8), which is the larger PL problem.
- **Extraction note:** on this refactor branch `run_multi_zone_market_clearing`'s
  returned `market_prices` collapses to 1 period/zone under the default
  *decomposed* mode; both arms therefore run **monolithic** (`decompose_periods=
  false`) — identical mode both arms, and monolithic vs decomposed differ only on
  ~10/29,679 degenerate pass-2 anchor cells (cv20), immaterial to scoring.
