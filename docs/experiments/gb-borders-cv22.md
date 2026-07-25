# cv22 candidate — FR↔GB double-count fix, paired with the GB premium

Roadmap item 5 ("GB done right", docs/experiments/boundary-zones-roadmap.md).
Two bugs that must ship **together** or not at all:

1. **FR–GB physical-flow double-count** in the net-imports path.
2. The **missing GB evening premium** the double-count was accidentally masking
   (shipping the fix alone costs FR +5.3 July MAE — wave-2 measurement).

The pair: extend the cv21 DK1/Viking virtual-boundary treatment to the FR↔GB
border — remove the whole (doubled) GB injection and price the exchange with an
elastic GB counterparty anchored on GB's OWN CCGT SRMC (UK-ETS carbon).

## 1. The double-count — audit (which borders, how big)

`entsoe.physical_flows` publishes the FR↔GB exchange **twice**: as the aggregate
map code `GB` **and** as the three per-interconnector codes `GB_IFA`, `GB_IFA2`,
`GB_ElecLink`. `get_net_imports` keys borders by `(hour, counterparty, dir)`
after only an `_IPS`-suffix strip, so `GB`, `GB_IFA`, `GB_IFA2`, `GB_ElecLink`
are four distinct counterparties and all four are summed — ≈2× the true flow.

Verified: the aggregate `GB` net **equals** the cable-sum net to the MW over the
full 2026-03..07 window (max |Δ| = 0.00 across 3,431 hours). So `GB` is exactly
`GB_IFA + GB_IFA2 + GB_ElecLink`, and counting all four doubles it.

**Audit of every GB border (2026-03 week):**

| footprint zone | GB codes present in `physical_flows` | double-count? |
|---|---|---|
| **FR** | `GB` **and** `GB_IFA`, `GB_IFA2`, `GB_ElecLink` | **YES (2×)** |
| BE | `GB` only (Nemo not split) | no |
| DK1 | `DK1↔GB` only (Viking not split; `DK↔GB` is a different `DK` code, not matched by DK1) | no |
| NL | `GB` only (BritNed not split) | no |
| NO2 | `NO2↔GB` only (NSL not split; `NO↔GB` is the `NO` country code, not matched by NO2) | no |

**Only FR double-counts.** BE/NL/NO2/DK1 carry a single aggregate code, so their
injection is already single-counted — they need no accounting fix (and get no new
book here). This matches the roadmap: the negative-evening-bias family
(BE/NL/…) is Core-FBMC coupling, not a GB-boundary problem.

### The accounting, per hour (FR, 2026-03-04)

`agg_net` = aggregate `GB` net into FR; `cables_net_sum` = Σ of the three cables;
`base_net_imports_GB` = what cv21 sums (agg + cables); `phantom` = the erroneous
excess.

| h | agg_net | cables_net_sum | cv21 counts (base) | phantom |
|---|---|---|---|---|
| 00 | −3567 | −3567 | **−7133** | −3567 |
| 03 | −3566 | −3566 | **−7133** | −3566 |
| 12 | −3566 | −3566 | **−7133** | −3566 |
| 18 | −3567 | −3567 | **−7134** | −3567 |
| 20 | −3441 | −3441 | **−6882** | −3441 |

(negative = FR exports to GB). cv21 injects ≈−7,133 MW every hour where the true
exchange is ≈−3,567 MW — a phantom −3,566 MW/hour of export that props FR's
residual demand (hence price) up. The treatment **excludes all four GB codes**
from the injection and prices the exchange via the elastic ladder instead —
the GB exchange is then counted exactly once (by the coupled clear), no double.

## 2. The GB premium (paired) — design

`GB_FR_BOOK` on `FR_PROFILE` (src/merit_order/zone_profiles.jl), the cv21
`BoundaryBook` mechanism generalized:

- **`net_exclude_codes = [GB, GB_IFA, GB_IFA2, GB_ElecLink]`** — the full
  exclusion that kills the double-count (DK1 needs only its single `GB`).
- **`flow_codes = [GB]`** — capability flow measured on the aggregate (the true
  border flow).
- **`atc_codes = [GB_IFA, GB_IFA2, GB_ElecLink]`** — FR↔GB offered ATC is
  published only per-cable (no aggregate ATC row), so `get_boundary_capability`
  now AVG-within-cable then **SUM across cables** for the total border ATC. A
  single-code border (DK1) sums one cable ⇒ byte-identical to cv21.
- **Anchor = 1.15 × GB CCGT SRMC**, `carbon_source = :uka` — TTF/0.52 +
  0.202/0.52·UKA + €2 O&M. Ladders are the wave-2/cv21 Viking shapes (import
  supply ×[1.00,1.15,1.30] @ 50/30/20, export demand ×[1.05,0.90] @ 50/50). No
  price fit.
- Gated by **`EUPHEMIA_DISABLE_CV22GB`** (leaves DK1/Viking on), so the cv22 A/B
  baseline is cv21.

### UKA carbon leg + N2EX anchor validation

GB left the EU ETS; its CCGT fleet pays the **UK** allowance, which has diverged
from EUA (2026-03: UKA €53 vs EUA €69; 2026-07: UKA €66 vs EUA €76). `uka_price`
(src/generators/fuel_costs.jl) reads `carbon.uka_price` (ICAP APE secondary,
EUR), last close strictly `< day` (no lookahead). The ICAP feed lags ~quarterly
at the live edge, so a July-2026 `day` naturally returns the last available
(2026-06-30) close — the documented last-value-before fallback, like TTF. Falls
back to `eua_price` when the table is absent (the offline extract carries no
`carbon.*`).

**Anchor vs realized N2EX** (`nordpool.n2ex_da_prices`, the only overlap —
GB DA prices land 2026-07-23):

| day | UKA-anchor (×1.0 CCGT SRMC) | EUA-anchor | N2EX all-hours | N2EX evening |
|---|---|---|---|---|
| 2026-07-23 | 147.8 | 154.0 | 158.7 | 188.2 |
| 2026-07-24 | 146.5 | 152.0 | 150.7 | 191.7 |
| 2026-07-25 | 149.8 | 155.0 | 90.2 (windy/long GB) | 166.3 |

The GB CCGT-SRMC anchor tracks N2EX all-hours within ~€8/MWh on the two tight
days — a fundamentals anchor, no fit. On 07-25 GB was long (wind) and priced far
below CCGT SRMC; the anchor is a marginal-cost floor and correctly does not chase
a below-SRMC print. Evening N2EX (~€190) sits above the ×1.15 anchor (~€168–175),
which the export-demand ladder recovers when GB pulls in scarce hours.

## 3. Pre-registered gate

Standard A/B (same 24 days as cv21: July-2026 failure 16 + March-2026 stable 8),
full 39-zone coupled clears (`enrich_network=true, passes=2, :merit_order`,
HiGHS), scored on realized DA prices. Baseline = **cv21** (DK1/Viking on, FR
untreated via `EUPHEMIA_DISABLE_CV22GB`); treatment = + FR↔GB pair. Real UKA
seeded into the offline path from Postgres (`uka_seed.json`).

**Gate:** FR/BE/NL/NO2/DK1 **neutral-or-better** (no zone worse by >0.03 corr or
>1.5 MAE in any window); FR must NOT show the +5.3 July MAE regression. SEE
byte-identity guards intact; EU-with-`EUPHEMIA_DISABLE_CV22GB` bit-identical to
cv21.

## 4. Results — GATE FAILED (no-ship)

Full 39-zone coupled A/B, HiGHS, offline extract, real UKA seeded. **July window
complete (10 days, 07-06..15; 07-16..21 fail the enriched-network build on the
extract for BOTH arms — the same Day-ahead-ATC gap cv21 documented). March 8/8.**
Baseline = cv21 (Viking on, FR untreated); treatment = + FR↔GB pair.

| window | zone | corr base→treat | MAE base→treat | eve_bias base→treat |
|---|---|---|---|---|
| **July** | **FR** | 0.79 → 0.84 | **35.58 → 39.79 (+4.21)** | −21.96 → −39.26 |
| July | BE | 0.83 → 0.83 | 34.74 → 35.26 (+0.52) | −37.9 → −38.0 |
| July | DK1 | 0.90 → 0.90 | 26.61 → 27.31 (+0.70) | −46.0 → −46.4 |
| July | NL | 0.83 → 0.83 | 27.83 → 27.74 (−0.09) | −50.8 → −50.8 |
| July | NO2 | 0.92 → 0.91 | 17.22 → 18.25 (+1.03) | −15.9 → −16.2 |
| **March** | **FR** | 0.82 → 0.83 | **26.38 → 21.37 (−5.01)** | +17.9 → +2.4 |
| March | BE | 0.82 → 0.83 | 23.13 → 22.65 | −5.1 → −5.1 |
| March | DK1 | 0.91 → 0.91 | 23.85 → 24.05 (+0.20) | −32.5 → −32.5 |
| March | NL | 0.73 → 0.74 | 32.23 → 32.28 | −47.9 → −47.9 |
| March | NO2 | 0.75 → 0.76 | 12.12 → 11.93 | +0.3 → +0.3 |

Footprint July mean MAE 31.70 → 32.03 (12 better / 24 worse); March 25.03 → 24.61
(21 / 7). (March scored on 6/8 days — 03-01..06; the A/B was stopped once the
**July window, the decisive/failing one, was complete**. March direction is
settled — a strong improvement — and is not the failing window, so the two
un-run days cannot change the verdict.)

**Verdict: NO-SHIP.** **FR July MAE regresses +4.21** — a clear breach of the
"no zone worse by >1.5 MAE" gate, and the specific FR regression the gate names.
BE/DK1/NL/NO2 stay within band and March improves broadly (FR −5.0), but the
July FR breach is disqualifying and the gate must not be weakened.

### Why the pair can't save July (the compensated error is not GB)

FR **exports** to GB even on July evenings (e.g. 07-08 17-21 UTC, net −1,951 MW).
The cv21 double-count doubled that export (≈−3,900 MW of phantom residual
demand), which pushed FR up its supply curve to €135–149 — **accidentally
matching the realized ~€150**. Removing the phantom (treatment) drops FR to its
true marginal cost (€109–115 on 07-08), and the honest GB export-demand ladder,
priced at GB's €151–177 willingness-to-pay, is **inframarginal** against France's
cheap nuclear/gas evening supply — GB happily buys the export volume but France's
own units still set the clearing price, so the price does NOT lift back to €150.

The error the double-count compensated is therefore **France's too-cheap evening
supply curve** (a FRANCE_PROFILE calibration matter — nuclear opportunity-cost
bidding), NOT a GB-flow mis-statement. No GB anchor level can fix it: FR clears
*below* the anchor, so raising the anchor changes nothing, and raising it to
force a lift would be price-fitting (forbidden). March works because the export
regime is different (FR–GB near-balanced/import) and France's spring supply
curve is steep enough that the honest removal helps.

**Consequence:** cv22 ships WITHOUT the GB pair. The FR–GB double-count stays
**documented as known-compensated** (this file + boundary-zones-roadmap item 5).
Shipping the accounting fix alone is *also* wrong (it would ship the +4.2 July
regression naked). The correct future path is to first fix France's evening
supply curve (opportunity-cost nuclear bidding), THEN the double-count fix +
GB pair become net-positive in both regimes — re-run this exact A/B then.

## 5. Byte-identity guards — ALL PASS

Branch vs unmodified main (cv21), offline extract, 2026-03-04
(`scratchpad/guards.jl`, digests over sorted book orders):

| guard | branch | main (cv21) | identical? |
|---|---|---|---|
| GR single-zone book | `fcbf8bc2f056fcdf` (1920 ord) | `fcbf8bc2f056fcdf` | **yes** |
| BG single-zone book | `446da6faab73c4c9` (768 ord) | `446da6faab73c4c9` | **yes** |
| DK1/Viking capability (24h) | 1100/1000 all h | 1100/1000 all h | **yes** |
| DK1/Viking orders (ladder) | 153.37/176.37/199.38 … | (same) | **yes** |
| **39-zone EU, `EUPHEMIA_DISABLE_CV22GB`** | 936 price rows | 936 rows | **bit-identical (0 diff)** |

The DK1/Viking match proves the `get_boundary_capability` ATC generalization
(AVG-within-cable → SUM-across-cables) is byte-identical for a single-code
border. The full-EU kill-switch match proves the mechanism adds nothing when
disabled — the cv22 candidate reverts exactly to cv21. SEE zones (GR/BG shown)
are untouched: the FR profile and boundary code are the only additions, and no
SEE/single-zone code path was modified.
