# Phase B findings — per-unit attribution of counterfactual residuals

*Working research notes. These are descriptive findings from public ENTSO-E
data compared against a competitive counterfactual — candidate hypotheses
for strategic behavior, NOT accusations. Alternative explanations that the
data cannot rule out are listed with each finding.*

## Method

For a candidate day (a day whose actual prices sit persistently above every
competitive reconstruction, after all mechanical model fixes):

1. **Hourly implied markup**: actual price minus the SRMC of the costliest
   unit actually running (≥20% of p_max). Persistent large positive values
   in non-scarcity conditions are the aggregate anomaly.
2. **Per-unit dispatch audit**: for every unit, compare actual output against
   its outage-adjusted capacity over its *in-merit hours* (actual price >
   unit SRMC + 5). Idle in-merit capacity is the candidate set.
3. **Kill the boring explanations, per unit**: filed outages under any asset
   code and any status; operational status in the surrounding weeks (a unit
   that never runs is mothballed/commissioning, not withheld); rational
   peak-shifting for energy-limited hydro (check peak-hour dispatch, not
   daily averages).
4. **Enabling condition**: Residual Supplier Index for the incumbent —
   RSI = (total available capacity − firm capacity + imports) / net demand.
   RSI < 1 means the firm is pivotal: the market cannot clear without it,
   and withholding is profitable almost mechanically.

## Case 1: GR 2025-05-21 (drought day)

**The residual.** Actual: avg €147.6, peak €355 (18:00 UTC). Competitive
counterfactual: ~€84 (single-zone and 5-zone coupled agree within a few €;
the −€63 premium survived the artifact fixes, the border-aware import fix,
daily EUA costs, and the flow-sign fix — corr 0.89 throughout, so the
*shape* is fully explained, only the level is not).

**Aggregate anomaly.** Gas was marginal all 24 hours (SRMC ≈ €95, TTF D−1
36.98). Implied markups: negative midday (RES hours — normal), **+131 to
+260 €/MWh at the evening peak** (prices 226/292/355 vs gas at 95).

**Exonerated:**
- *Reservoir hydro* (1.9 GW at 10% daily utilization): peak-hour dispatch
  shows Kremasta 248, Kastraki 223, Sfikia 198, Polyfyto 149 MW at 16–19 UTC
  — the fleet concentrated scarce water exactly at the peak. Rational
  water-value behavior under drought (reservoir dryness signal: 0.19 below
  same-week prior-year median). Kremasta's reduced ceiling was a **filed**
  planned derate (437 → 300 MW).
- *ELPEDISON_THISVI* (410 MW CCGT, zero all day): documented 0-MW planned
  outage 2025-04-05 → 2025-05-31 under asset code 29WELPEDISONTHIM.

**The finding — two same-firm units dark, unfiled, operational before and
after:**

| unit | firm | capacity | dark window | before | after | outage filed |
|---|---|---|---|---|---|---|
| KOMOTINI_POWER (CCGT) | PPC | 858 MW | May 16–21 | 823–856 MW on May 12–15 | 828–840 MW on May 22–23 | **none, any code/status** |
| AGIOS DIMITRIOS IV (lignite) | PPC | 283 MW | May 17–23 | ~150–160 MW daily through May 16 | ~150 MW from May 24 | **none, any code/status** |

The day-ahead auction for May 21 cleared around noon on May 20, when prices
were visibly climbing (May 20: avg 116, max 299). An 858 MW CCGT that had
run at ~full load four days earlier was not offered into the highest-priced
day of the season, and returned to full output the day after.

**Enabling condition.** At the evening peak (17–18 UTC): load ≈ 5.6 GW,
RES ≈ 1.5 GW, net demand ≈ 4.0–4.1 GW, GR *exporting* ~0.6 GW (coupled
regional scarcity — BG priced identically). Dispatchable capacity ≈ 8.0 GW
of which PPC ≈ 4.8 GW: **RSI_PPC ≈ 0.77–0.80** — PPC was pivotal. The two
dark units total 1.14 GW ≈ 28% of net peak demand.

**Alternative explanations not excluded by this data:** gas nomination or
supply constraints (Komotini sits on the TAP/IGB corridor); unit trips or
maintenance filed via REMIT/HEnEx channels that do not reach the ENTSO-E
unavailability table; crew/scheduling constraints spanning the soft-price
weekend (the dark window *started* during low prices — consistent both with
benign economic shutdown followed by opportunistic non-return, and with
strategic timing). Confirming or excluding these needs non-ENTSO-E sources.

## Generalization queue (next steps)

1. **Unfiled-dark-unit detector**: scan all zone-days for units with
   (a) zero output, (b) no outage record under any code/status,
   (c) demonstrably operational within ±7 days, (d) in-merit prices —
   materialize as a table keyed (unit, day) with the day's counterfactual
   residual. The May 21 case suggests residual spikes and unfiled-dark
   capacity should correlate.
2. **RSI time series**: compute hourly RSI for the incumbent per zone;
   regress implied markups on RSI, margin, RES forecast, reservoir
   dryness (the ex-ante signal catalogue in `research-roadmap.md`).
3. **Cross-firm correlation**: markup shifts correlated across firms beyond
   common signals — the collusion test proper. Needs the firm mapping
   (currently name-regex; formalize into a lookup table).
4. Same audit for BG on the coupled days (GR≡BG to the decimal on
   2025-05-21; the premium is regional, so the BG side deserves the same
   per-unit treatment).
