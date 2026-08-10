# World S — Phase 0: strategy cartography from the real books (2026-08-10)

Owner design (2026-08-10): behaviors not explainable by competition get their
own book generation — a THIRD parallel world (C competitive / R regulatory /
S strategic), own labels, canonical record untouched. First step: measure the
actual bidding grammar in the two markets that publish their books (the
pubbooks validation assets: 7 GME + 20 OMIE frozen days, raw unit-level).

## Shape cartography (offer price normalized by the day's gas SRMC)

| shape | GME (IT) % MW / acc | OMIE (ES/PT) % MW / acc |
|---|---|---|
| negative | 4.9 / 64% | **27.1 / ~100%** |
| zero (price-taker) | **32.1** / 46% | 8.1 / 68% |
| below SRMC | 2.6 / 62% | 11.4 / 44% |
| SRMC band (0.8–1.25×) | 15.6 / 54% | 12.6 / 15% |
| **markup (1.25–2.5×)** | **32.0 / 21%** | 19.3 / 2% |
| withheld (>2.5×) | 12.8 / **0%** | 21.5 / **0%** |

Gas SRMC per day spanned 87–127 €/MWh over the sample (TTF/0.55 + EUA
carbon + O&M, the house cost model).

## The three findings

1. **Neither market bids SRMC.** Italy's elastic margin lives at 1.25–2.5×
   SRMC (where acceptance is partial — the price-setting band); its
   must-run-ness is expressed at ZERO (GSE bids 100% at 0; bilaterals 61%).
   Iberia expresses must-run-ness as DEEP NEGATIVE offers (27% of the book,
   essentially fully accepted) — which also explains Spain's −300 prints
   without a premium fleet (the regulatory-floor research's caution,
   independently confirmed).
2. **Strategies are stable unit attributes**: 67% of 2,469 GME units and 61%
   of 2,874 OMIE units keep ONE dominant shape across every sampled day
   (2025-01 → 2026-07). This is the enabler for an EX-ANTE strategist:
   assign each unit its trailing-observed profile from lagged public books
   (an admissible input per the methodology) — copying declared behavior,
   never fitting prices.
3. **The withheld tail is real and universal** (13–22% of MW, 0% acceptance
   in both markets) — capacity declared unavailable at low prices, absent
   from our competitive books (the measured near-cap conduct residual now
   has its book-side signature).

Unit-level profiles saved (session scratchpad `pubbooks/{gme,omie}_unit_shapes.csv`
— derived from non-redistributable raw, kept out of the repo).

## Pilot test (prereg sketch — freezes before scoring)

- **Question**: does a strategy book beat the competitive book OUT-OF-SAMPLE
  on (a) book distance (MW band-distribution) and (b) official-price
  closeness, in the zones where we can see the truth?
- **v1 fleet-level** (no unit mapping needed): per zone, reshape our thermal
  ladder so its band distribution matches the TRAILING observed distribution
  (lagged ≥30 days); RES/must-run blocks re-priced per the observed
  zero/negative split. **v2 unit-level**: GME unit_ref ↔ ENTSO-E mapping,
  per-unit profiles via the strategist hook.
- **Calibrate on the 2025 frozen days, test on the 2026 days** (temporal
  hold-out within the sample); metrics: band-distribution distance and
  cleared-price MAE vs official, strategy vs competitive book.
- Then: port the surviving grammar to non-book zones via firm maps
  (unit_firms), as a World-S label the product can show alongside C and R.
