# Support schemes & rational negative-bid depth per zone (desk research, 2026-08-10)

Sourced reference for the regulatory-floor (World R) design. Full citations
inline; explicit not-found flags at the end. Headline: **"floor = −premium"
is wrong almost everywhere — three regimes recur, and depth is
TIME-DEPENDENT and compressing every year.**

## The three regimes

- **(a) Legacy FiT / obligation-d'achat fleets** (DE pre-2016 vintages & TSO-
  marketed FiT, FR OA ≈ 40% of supported RES energy, CZ FiT): paid regardless
  of price → price-INELASTIC volume at/near the −500 exchange floor. They set
  volume, almost never the marginal price.
- **(b) Market-premium fleets under N-consecutive-hour rules** (DE §51 6h/4h/
  3h/2h/1h ladder by vintage, PL 6h, BE offshore 6h, AT 6h, NL 2016-22 6h):
  rational bid ≈ −(premium) ONLY inside streaks shorter than N; DE's
  whole-period forfeiture makes mid-streak hours a cliff (depth decays toward
  0 as the streak-threshold probability rises).
- **(c) New-vintage "immediate" rules** (DE post-Feb-2025 Solarspitzengesetz,
  NL SDE++ 2023+, CH): no payment in any negative (quarter-)hour → rational
  bid ≈ 0.

**The marginal negative price is set by the ELASTIC fleets** (b)/(c) plus
thermal shutdown economics — which is why FR averages only −15/−16 €/MWh in
negative hours despite an OA fleet bidding −500 (CRE Nov-2024 note, Fig. 1).

## Per-zone anchors (levels with sources — see the agent transcript for the full set)

| zone | premium/strike level | negative-price rule | implied elastic depth |
|---|---|---|---|
| DE_LU | aW wind ~€60–70, solar ~€47 (BNetzA 2025 auctions); legacy solar FiT €250–500 | §51 ladder by vintage: none (<2016) / 6h / 4h / 3h / 2h / 1h / immediate (≥Feb-2025); 15-min basis since Oct-2025 | −10..−50 inside short streaks; legacy inelastic at floor; new ≈0 |
| FR | PPE2 wind €77–87, solar ~€74; OA legacy fixed | CR: no premium in negative hours + non-production premium → CR bids ≈ 0; OA: no rule → −500 | **bimodal: ≈0 (CR) + inelastic floor (OA)** — no premium-depth band at all |
| PL | CfD strikes: solar €50–78, wind €23–74 (URE 2024-25) | 6-consecutive-hour exclusion (ZRSA) | deep (toward floor, CfD made-whole) inside <6h; → 0 beyond |
| BE | offshore certificates €90–138 by vintage | 6h rule (RD 17/8/2018) + €0 min for 72h/yr | −90..−138 inside <6h (offshore); regional: unresolved |
| CZ | legacy 2009-10 solar FiT (hundreds €/MWh); green bonus (ERÚ annual) | support NOT cut in negative hours (2025 abolition attempt withdrawn); FiT nets to FiT+p; hourly bonus capped at its 0-price value | very deep for legacy FiT (→ floor); ≈ −bonus(0) for bonus fleet |
| CH | mostly one-time investment grants; KEV vs quarterly ref price | n/a (no per-MWh premium); 2027: hourly spot pass-through | **≈ 0 — no subsidy-driven depth at all** |
| NL | SDE++ sliding premium | none (<2015) / 6h (2016-22) / any negative hour (2023+, 15-min from 2024) | old ≈ −premium; mid: streak-truncated; new ≈0 |
| AT | EAG aW wind ~€96 | 6h rule (BMLUK) | potentially deep inside <6h |
| ES | REER ~€24-25 small fleet; mostly merchant/RECORE | REER negative-hour clause UNRESOLVED | shallow — and the Feb-2026 −300 print is NOT subsidy-driven (caution) |

## Structural implications for World R

1. Depth must be a **per-zone LADDER**, not one number: a small inelastic
   legacy block near the floor + an elastic premium block at −(aW−MV)
   truncated by streak rules + a new-vintage block at ≈0.
2. Depth is **vintage-weighted and time-dependent**; the binding rules
   tighten annually (DE 4→3→2→1h + immediate), so the fleet-weighted depth
   COMPRESSES over the record period — a World-R model frozen at one number
   would be wrong at both ends of 2023-2026.
3. **CH gets no regulatory floor at all** (round-2's T5/its census wall must
   be explained elsewhere — imports/hydro, not subsidies), and **FR's depth
   is not premium-shaped** (bimodal 0/floor): two zones where World R
   CHANGES the census interpretation rather than deepening a floor.
4. ES's deep 2026 prints without a premium fleet warn against attributing
   all depth to subsidies — inflexibility/must-run dynamics coexist.

## Not-found flags (from the research, to resolve or declare)

DE GW-by-§51-rule split (vintage estimate only); CZ current bonus €/MWh; PL
certificate price; BE regional certificate values/cutoff; ES REER clause
(RD 960/2020 art. 14); NL SDE++ current base amounts; AT PV award averages.
