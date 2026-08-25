# cv34 — the ex-ante conventions (owner decisions 2026-08-25)

After the two bug sweeps (#342, #343) five items were left that were not bugs
but conventions only the owner could set. Decided 2026-08-25 ("go with the
suggested fixes, then run a full evaluation, bump CV"). This is the record of
what each one now means in code, the one-off migrations that were run, and the
evaluation. cv34 was the number the continental-collapse prereg draft had
designated; that package moves to cv35.

## B1. Outage versions as known at the gate

ENTSO-E outage messages are versioned; until cv33 the LATEST version counted,
including versions published after the D-1 12:00 CET auction (a same-day forced
trip published at 15:00 reached that day's book: 2026-04-03 DE_LU 1.9 GW, GR
837 MW, RS 349 MW of future knowledge). Now: for delivery days **from
2025-10-01** the version that counts is the latest one **published before D-1
10:00 UTC** (the 12:00 CET/CEST gate, conservative). The seam is where
`version_publication_timestamp_utc` becomes a real TSO time (the ETL captured
it from 2025-09-28; before that the column holds ingestion time, so no vintage
filter is possible). Both directions move: a same-day forced outage no longer
disappears from the fleet, and an outage **cancelled after the gate** now
correctly still counts. 2026-04-03 fleets vs cv33: FR +225 MW, DE_LU −1,022 MW,
GR +105 MW, RS unchanged. Before the seam the record is D-0 knowledge for
outages and says so here.

## B2. Fuel and carbon closes strictly before D-1

The D-1 close (17:30) does not exist at the 12:00 gate; the last close that
does is D-2's. `get_ttf_price`, `eua_price` and the UKA lookup read
`date < D − 1 day`. 2026-04-03: TTF 47.51 (the 04-01 close) instead of 50.04
(04-02); gas SRMC 114.2 instead of ~118. Mean |Δ| between consecutive closes
over 2023+ is 1.3 €/MWh gas ≈ 2.3 €/MWh_el on the gas SRMC (p90 4.9, crisis
days up to 23).

## B3. The `entsoe` track's persistence leads are labelled

`bin/horizon_forecast.jl` fills leads 2–7 of the "As announced" track with the
T-7 lead-1 slice (weekly persistence). They were stamped `input_mode='entsoe'`
and the running cv — indistinguishable from a model clear. Now
`input_mode='entsoe_persist'`; the site's track switch matches the `entsoe*`
prefix so they still render on the As-announced track, labelled. One-off
relabel run 2026-08-25 on live: 247,008 `forecast_prices` rows and 9,341
`forecast_scores` rows moved from `entsoe` to `entsoe_persist` at leads ≥ 2.

## B4. The lead ladder measures weather decay only — declared, and unpooled

`docs/experiments/pregate-7lead.md` §2b states it: only the weather is
vintage-honest at lead n; flows, analogue pool, fuel, outages, capability
windows and the AR load features are delivery-day anchored (retro) or absent
(live). Live and retro rows are no longer pooled: `forecast_scores` PK now
includes `is_retro` (migrated live, 0.5 s), `upsert_score!` conflicts on it,
the discovery's NOT-EXISTS matches on it, and the summary reports
`<mode>/retro` rows separately. Making the other inputs vintage-aware is a
separate project.

## B5. `energy_prices` unique key re-keyed

The live constraint had grown an `optimizer` column that no writer populates;
NULLs are distinct, so it rejected nothing. Pre-check found 0 duplicate groups
on the intended key; the migration (`ensure_energy_prices_table`, catalog-first,
skips loudly if duplicates exist) dropped it and added
`UNIQUE (date_time_utc, bidding_zone, contract_type, order_method,
clearing_mode, code_version)`. Ran live 2026-08-25 in 23.6 s.

## C. Import backstop sized against the MPCC's own border capacity — MEASURED NO-SHIP

`get_import_backstop` re-derives the endogenous-border ATC from the offered-ATC
tables without the cv27 demonstrated capability, the border drops or the as-of
filter, so on cv27 borders in Day-ahead-free hours it reads ~0 while the flow
variables deliver the p95 capability. The candidate handed the enriched
network's per-hour import capacity into the backstop instead. On the 47-day
evaluation it was **neutral to slightly negative** (footprint MAE 27.32 with vs
27.25 without; DK2 27.4 vs 26.4, AT 34.8 vs 34.2, everything else within 0.1)
and it made one period of 2026-03-04 non-optimal (the day was refused; without
it the day clears). The code stays, **opt-in** via
`EUPHEMIA_ENABLE_BACKSTOP_ATC_SYNC`; the shipped default is the re-query. The
scarcity credit's `get_import_atc_capacity` was never changed (different scope).

## Evaluation (2026-08-25)

**Design.** 52 Wednesdays 2025-07-02..2026-06-24 (one per week, both halves of
the seam), 39 zones, public extract, HiGHS, per-period decomposition, passes=2,
8 solver workers (`run_pipelined_backfill`, ~11 min per arm). Arms: the cv31
record (Postgres rows), `cv34` (everything incl. C), `cv34 −C`, `cv34 −B1`
(`EUPHEMIA_DISABLE_CV34_GATE`), `cv34 −B2` (`EUPHEMIA_DISABLE_CV34_D2CLOSE`);
B3/B4/B5 do not touch prices. Scored against settled Day-ahead prices
(resolution-aware hourly actuals from Postgres) on the **44 days every arm
cleared** (the record lacks 4 of the 52 — 3 are source-data truncations
2025-11-12 / 2026-03-18 / 2026-06-03 that the gate now refuses too; the arms
lost 0–3 further days each to a sporadic single-period HiGHS non-optimal, see
Follow-ups). All arms carry #342 + #343.

```
days paired: 44   zones: 39   arms: ['cv31 record', 'cv34', 'cv34 −C', 'cv34 −B1', 'cv34 −B2']
zone                   cv31 record                  cv34               cv34 −C              cv34 −B1              cv34 −B2
                   MAE  bias  corr       MAE  bias  corr       MAE  bias  corr       MAE  bias  corr       MAE  bias  corr
BE              19.5   -7.7   0.76    22.1   -1.6   0.31    22.0   -1.5   0.31    27.1   +5.5   0.23    22.5   -2.4   0.31
BG              25.9   -4.7   0.78    28.8   +5.4   0.73    28.8   +5.3   0.73    28.6   +5.1   0.73    28.7   +4.7   0.73
NO1             25.8   -3.7   0.39    27.0   +1.1   0.34    27.0   +1.1   0.33    27.0   +0.9   0.33    28.5   -0.6   0.30
RO              27.3   -7.3   0.76    29.4   +3.2   0.71    29.4   +3.0   0.71    29.2   +2.9   0.71    29.3   +2.5   0.71
GR              21.9   -3.5   0.83    23.5   +1.5   0.81    23.5   +1.3   0.81    22.6   +1.9   0.83    23.5   +0.9   0.81
RS              31.6   +3.6   0.63    32.0   +8.7   0.65    32.0   +8.6   0.65    31.7   +8.8   0.66    32.1   +8.2   0.65
AT              34.7  -27.9   0.64    33.5  -27.3   0.64    33.3  -27.0   0.64    32.5  -25.0   0.64    35.0  -28.3   0.61
NO3             42.2  +24.7   0.31    42.2  +26.5   0.32    42.2  +26.5   0.31    42.3  +26.9   0.32    42.5  +25.5   0.30
NO4             28.7   -0.9   0.15    28.9   -0.6   0.17    28.9   -0.6   0.17    28.9   -0.6   0.17    28.8   -0.8   0.14
SE3             27.7  +10.7   0.61    26.7  +12.0   0.66    26.8  +12.0   0.66    26.4  +13.3   0.68    27.8  +10.8   0.61
ES              22.5   +6.0   0.79    22.9   +5.5   0.78    22.9   +5.5   0.78    23.3   +7.1   0.78    22.6   +4.9   0.78
IT-CSOUTH       21.8   +6.2   0.65    21.4   +7.1   0.66    21.4   +7.2   0.66    22.1   +8.6   0.67    21.8   +6.1   0.65
NO5             29.3   +2.0   0.37    28.0   +3.8   0.42    28.1   +3.9   0.42    28.3   +4.0   0.42    29.3   +2.5   0.37
HU              40.1  -35.6   0.70    39.8  -33.1   0.66    39.8  -33.1   0.66    38.0  -31.0   0.67    40.1  -33.4   0.66
PT              23.7   +6.4   0.76    24.0   +5.9   0.75    24.0   +5.9   0.75    24.4   +7.4   0.76    23.7   +5.3   0.76
IT-Sardinia     23.4   -0.9   0.61    23.1   -1.1   0.62    23.1   -1.1   0.62    23.4   -0.3   0.62    23.3   -1.6   0.62
IT-Calabria     21.6   -8.4   0.63    20.9   -7.5   0.65    20.9   -7.5   0.65    21.2   -7.0   0.64    21.4   -8.5   0.64
NO2             15.1   -0.1   0.73    14.0   +1.2   0.78    14.0   +1.2   0.78    13.8   +2.5   0.80    14.8   +0.3   0.75
IT-Sicily       23.2  -10.5   0.61    22.2   -9.5   0.63    22.2   -9.5   0.63    22.5   -9.0   0.63    22.9  -10.5   0.62
CZ              23.7   -7.7   0.70    23.2   -2.6   0.71    23.1   -2.7   0.71    22.9   -1.5   0.72    23.3   -2.4   0.70
IT-SOUTH        22.2   -5.5   0.66    21.2   -4.4   0.68    21.3   -4.4   0.68    21.6   -3.8   0.67    21.7   -5.4   0.67
NL              22.4   -9.9   0.69    21.7   -8.3   0.68    21.7   -8.2   0.68    21.6   -7.5   0.68    21.9   -8.4   0.67
DK2             27.4   -9.4   0.69    28.2   -3.5   0.66    27.1   -5.4   0.69    27.9   -1.8   0.67    26.9   -6.3   0.69
FR              22.6   +4.5   0.78    22.1   +5.6   0.79    22.0   +5.7   0.79    21.7   +7.5   0.80    22.1   +5.3   0.79
CH              29.5  -25.4   0.66    28.2  -24.4   0.72    28.2  -24.2   0.72    27.7  -22.3   0.69    28.9  -24.6   0.69
IT-NORTH        30.8  +17.9   0.65    29.9  +18.1   0.66    29.8  +18.1   0.66    30.6  +19.5   0.67    30.1  +17.0   0.65
IT-CNORTH       30.8  +17.3   0.64    29.8  +17.5   0.65    29.7  +17.5   0.65    30.5  +19.0   0.66    30.0  +16.4   0.64
SE1             27.2   -9.6   0.50    26.0  -11.5   0.55    26.0  -11.5   0.55    26.0  -11.5   0.55    26.2  -11.8   0.55
SE2             26.4   -9.8   0.50    25.2  -11.6   0.56    25.2  -11.6   0.56    25.2  -11.6   0.56    25.3  -11.9   0.55
FI              24.3  -14.5   0.80    23.4   -6.5   0.80    23.1   -6.5   0.80    22.8   -5.6   0.80    23.2   -6.6   0.80
SE4             30.9  -18.9   0.64    29.5   -8.1   0.60    29.1   -8.5   0.61    29.3   -6.6   0.60    29.7   -9.2   0.60
SI              41.7  -36.7   0.54    39.8  -32.0   0.51    39.8  -32.1   0.51    38.9  -30.8   0.52    40.5  -32.7   0.51
DE_LU           19.2  -11.8   0.84    17.9   -9.2   0.86    17.9   -9.2   0.86    17.1   -8.2   0.87    17.9   -9.4   0.86
DK1             18.5   -5.8   0.80    17.1   -4.0   0.84    17.2   -3.8   0.83    16.8   -3.2   0.84    17.1   -4.2   0.84
PL              25.9  -13.2   0.71    23.9   -8.8   0.76    24.0   -8.8   0.76    23.4   -7.6   0.77    23.9   -8.7   0.76
SK              38.0  -34.4   0.60    35.6  -32.1   0.66    35.6  -32.1   0.66    34.1  -30.1   0.72    35.9  -31.8   0.63
EE              42.6  -35.2   0.77    36.5  -19.0   0.76    36.3  -19.1   0.76    35.7  -18.3   0.77    36.6  -18.8   0.76
LT              45.1  -40.1   0.76    38.0  -27.6   0.76    37.7  -27.8   0.77    37.0  -26.2   0.77    38.1  -27.9   0.76
LV              50.3  -46.1   0.70    41.0  -31.6   0.72    40.8  -31.5   0.72    40.3  -30.8   0.72    40.9  -31.3   0.72
--------------------------------------------------------------------------------------------------------------------------
cv31 record  footprint MAE  28.34  corr 0.650  cap-hours     0  collapse hit 1042/2381 (44%)  false-alarm 1084
cv34         footprint MAE  27.40  corr 0.647  cap-hours     1  collapse hit 1038/2381 (44%)  false-alarm 1002
cv34 −C      footprint MAE  27.33  corr 0.648  cap-hours     1  collapse hit 1035/2381 (43%)  false-alarm 997
cv34 −B1     footprint MAE  27.30  corr 0.650  cap-hours     3  collapse hit 1031/2381 (43%)  false-alarm 989
cv34 −B2     footprint MAE  27.66  corr 0.638  cap-hours     1  collapse hit 1029/2381 (43%)  false-alarm 1040
cv34 vs cv31 record: zones better 28 / worse 10; max worsening (2.86450284090909, 'BG')

```

**Reading.**
- **Shipped default (`cv34 −C`) vs record: footprint MAE 28.34 → 27.33, corr
  0.650 → 0.648, collapse hit rate 44 → 43 %, false alarms 1084 → 997, 28
  zones better / 10 worse.** Largest gains where the sweeps' input bugs were:
  LV 50.3 → 40.8, LT 45.1 → 37.7, EE 42.6 → 36.3, SK 38.0 → 35.6, SE4 30.9 →
  29.1, PL 25.9 → 24.0, SI 41.7 → 39.8, DE_LU 19.2 → 17.9, DK1 18.5 → 17.2.
  Pre-seam (13 days, B1 inactive) 25.06 → 24.40; post-seam (35 days) 29.54 →
  28.48.
- **B2 (D-2 close) is a gain, not a cost: −B2 is 0.33 worse (27.66 vs 27.33)
  and −0.010 corr.** The market prices its gas off the close it actually had at
  the gate; the D-1 close was lookahead AND noise.
- **B1 (outages as known at the gate) costs ~0.1 MAE** (−B1 27.30 vs cv34
  27.40, C held): AT 32.5 → 33.5, SK 34.1 → 35.6, HU 38.0 → 39.8 — outages
  cancelled after the gate correctly still count, tightening those fleets —
  while BE improves 27.1 → 22.1 and its cap hours fall 3 → 1. That is the
  price of not using post-gate information; kept.
- **C is a measured NO-SHIP** (27.40 vs 27.33; DK2 28.2 vs 27.1) — opt-in only.
- **Worse zones** (shipped arm vs record): BG 25.9 → 28.8, RO 27.3 → 29.4,
  GR 21.9 → 23.5, RS 31.6 → 32.0 — the SEE group's bias moves from −4..−7 to
  +3..+5 (prices up ~9 €/MWh) in BOTH halves of the seam and in every arm, so
  it comes from #342/#343 (outage-aware fleet completion / outage semantics),
  not from B1/B2/C; and BE 19.5 → 22.1 with corr 0.76 → 0.31, entirely one
  hour: **2026-01-14 17:00 clears at the 3000 cap (settled 172, record 221)**
  in every cv34 arm. See Attribution.

**Attribution of the two regressions** (single-day re-clears of the same
extract under three code states: pre-sweep `e974cb8`, after #342 `182256c`,
after #343 = cv34 with every cv34 switch off).

- **BE 2026-01-14 17:00 = 3000.** Pre-sweep 296.3, after #342 295.7, after
  #343 **3000 (3 cap hours that day)**. It is #343's outage-aware fleet
  completion: BE has 1,260 MW of gas on outage that day; the old completion
  re-added 771 MW of gas regardless (trailing p95 5,807 MW vs 5,037 MW
  available) and that tranche kept the evening off the cap; the new one logs
  "Fossil Gas gap 753 MW explained by 1,260 MW on outage — not re-added", the
  import backstop is capped at demonstrated headroom, and the peak hour hits
  the cap. Settled was 172, so the real system found ~800 MW — imports beyond
  the demonstrated headroom, or an outage version not binding at 17:00 (B1
  alone reduces the day's cap hours 3 → 1). The physics of the fix is right
  (a unit on outage does not bid); what is missing is the market's *response*
  to a known outage, which the backstop cap does not allow. Candidate for the
  owner: when the outage explains the gap, offer the gap as an "unfiled
  capability" tranche at the backstop price (1.8× gas SRMC) instead of either
  re-adding it at SRMC (pre-#343) or refusing it (now). 1 hour in 1,716
  zone-days of this evaluation; not changed here.
- **The SEE +9 €/MWh shift (BG/GR/RO/RS bias −4..−7 → +3..+5).** Three days
  (2025-08-13, 2025-12-10, 2026-05-06), MAE / bias vs settled:

  | zone | cv31 record | pre-sweep re-clear | after #342 | after #343 + cv34 |
  |---|---|---|---|---|
  | GR | 21.1 / −0.8 | 22.8 / +4.1 | 22.6 / +3.6 | 22.5 / +5.4 |
  | BG | 26.3 / +1.8 | 26.7 / +3.9 | 26.9 / +4.3 | 26.8 / +6.7 |
  | RO | 31.4 / −6.0 | 31.6 / −3.7 | 31.9 / −3.4 | 31.4 / −1.0 |
  | RS | 26.3 / +8.0 | 25.8 / +10.0 | 26.0 / +10.0 | 27.1 / +11.7 |
  | HU | 51.8 / −51.8 | 55.2 / −51.4 | 57.2 / −53.4 | 47.9 / −42.3 |
  | footprint | 30.11 | 30.38 | 30.31 | **28.76** |

  About half of the shift (GR −0.8 → +4.1) is already there when the
  **pre-sweep code** re-clears the same days on the extract — i.e. it is the
  **data vintage** (the public extract vs the live database at the time the
  cv31 record was built: later ENTSO-E revisions, the cv26 Day-ahead
  preference applied to refreshed ATC rows), not code. #342 adds nothing;
  #343 + cv34 add the other half (~+2 €/MWh: outage-aware completion, gate-
  vintage outages) while taking the footprint from 30.38 to 28.76 on the
  same days. **Caveat for the whole table above: the "cv31 record" column is
  not a same-data baseline.** The code-only effect, measured where both codes
  saw identical inputs, is larger than the record comparison suggests
  (−1.6 on these three days vs −1.0 record→cv34 over 44 days).

**Follow-ups surfaced by the run** (not fixed here):
1. Per-period HiGHS non-optimal on one hour refuses the whole day (0/1/0/3 of
   52 days across the four arms with near-identical books; the record was
   built by the same code path and lost days the same way). The Gurobi retry
   ladder does not apply; the decomposed path needs its own per-period retry
   (seed / presolve / monolithic fallback for that hour).
2. Mixed-resolution LOAD publications truncate a day (2025-11-12 GR: 1 period;
   2026-06-03: 2 periods) — the load-side twin of the RES fix in #342.
3. The SEE +9 €/MWh shift and the BE 2026-01-14 hour (attribution below).
