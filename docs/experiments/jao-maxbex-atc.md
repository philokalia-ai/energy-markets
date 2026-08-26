# JAO flow-based max exchanges as the ATC for Day-ahead-free borders (2026-08-26)

Follow-up to [data-investigation-2026-08-25.md](data-investigation-2026-08-25.md)
§4 item 1, owner-directed ("do the ETL job at ceres, continue").

## The data

- **Source.** JAO Publication Tool, `GET https://publicationtool.jao.eu/<ccr>/api/data/maxExchanges?FromUtc=…&ToUtc=…`
  (public, no key, ranges capped at ~1 day). `core` since the 2022-06-09
  go-live (150 directed borders, hourly), `nordic` since 2024-10-30 (62
  directed borders, 15-minute MTU). No Italy-North endpoint. The value is the
  **max bilateral exchange** per directed border from the final flow-based
  computation — the capacity the day-ahead market cleared on — published D-1
  ~10:30 CET, i.e. before the 12:00 CET gate (ex-ante by construction).
- **ETL.** ceres `data/entsoe/update_JaoMaxExchanges.py` (PR pankgeorg/ceres#524):
  day-by-day, long table `jao.max_exchanges(ccr, date_time_utc, border_from,
  border_to, max_exchange_mw, fetched_at)`, delete-then-COPY per (ccr, day),
  `jao.fetch_log` watermark, incremental step in `update_entsoe_data` after
  the implicit-ATC step (last stored day − 3 .. tomorrow). Full backfill run
  2026-08-26 (Core 2022-06-09→, Nordic 2024-10-30→).
- **Extract.** `bin/extract_common.jl` carries `jao.max_exchanges` in new
  extracts; older extracts lack it and the model degrades to the previous
  fallbacks (loud once per process).

## The mechanism (`Network.jao_maxbex`, `EUPHEMIA_DISABLE_JAO_ATC` to revert)

Hub codes → map codes (`DE` → `DE_LU`; virtual hubs Baltic/BigHub/COBRA/
NorNed/SwePol/VH/SE3SWL/SE4SWL/ALBE/ALDE dropped); where Core and Nordic both
publish a border, the CCR the border is internal to wins. Hourly mean per
(source, sink, period). Three uses in the enriched network build:

1. **Every implicit-table border-hour with no Day-ahead row** takes the JAO
   value (before the cv27 demonstrated-capability override, which now only
   applies where JAO has nothing).
2. **Borders JAO publishes that the implicit table does not carry at all** are
   added with the JAO capacity.
3. **A flow-based drop border JAO covers is not dropped** (`multi_zone_books`):
   the cv15/cv17 drops (AT–CZ, AT–DE_LU, AT–SI, SK–CZ, SK–PL, …) existed
   because the implicit table gave those Core borders phantom intraday-leftover
   capacity; JAO's maxBEX is the market's own number, so the border becomes
   endogenous and the zone's observed-import injection over it is removed
   (the existing endogenous-border accounting). This is the change aimed at
   the Core-cluster signature (HU/SK/SI/AT/CH settled = DE_LU +10..+17, ours
   DE_LU −7..−12, evening −50..−72).

The pre-gate ATC readiness gate (`bin/daily_forecast.jl`) counts JAO rows for
tomorrow as day-ahead capacity too.

## Second mechanism: transmission-grid outages cap the border (`Network.tx_outage_caps`)

`entsoe.unavailability_in_the_transmission_grid` (10.1.A/B) has been ingested
since 2014 (36.9M rows) and never consumed. It carries, per Active message,
the directed border (`out/in_area_map_code`) and the TSO's **remaining NTC**
(`new_ntc_mw`): EstLink 2 at 358 MW from 2024-12-25 to 2025-06-19, EstLink 1,
NordLink (DE_LU–NO2), Cobra (DE_LU–DK1), ES–PT, LT–LV, PL–LT, IT-NORTH–AT/FR
are all there. Per directed border-hour the minimum `new_ntc_mw` over the
current-version Active messages covering the hour caps the capacity from
whatever source (Day-ahead ATC, JAO, cv27). Same gate-vintage rule as the
generation outages (from 2025-10-01 only versions published before D-1 10:00
UTC). `EUPHEMIA_DISABLE_TX_OUTAGE_ATC` reverts.

## A/B

52 Wednesdays 2025-07-02..2026-06-24, live Postgres (the public extract
predates both tables), cv34 code + these changes, three arms so each is
attributed: `ab_jao_off` (both switches off = cv34 behaviour), `ab_jao_on`
(JAO only), `ab_jao_tx` (JAO + outage caps). HiGHS decomposed, 8 solver
workers. Results appended below.

### Result 1 — `off` vs `+JAO` (48 paired days, live Postgres; `off` HiGHS, `+JAO` 13 days HiGHS + 39 Gurobi)

```
days paired: 48  zones: 39
zone                       cv31 record                cv34 (off)                      +JAO
                  MAE  bias  corr  b18      MAE  bias  corr  b18      MAE  bias  corr  b18
FR              22.5   +3.0  0.78    +4    21.8   +3.3  0.79    +5    34.0  +28.0  0.66   +13
RO              26.8   -6.7  0.76    -8    26.7   -1.3  0.76    -1    34.8  -24.6  0.72   -72
BG              25.4   -4.1  0.79    +3    25.6   +1.2  0.79   +11    31.4  -22.5  0.75   -57
FI              24.6  -14.7  0.79   -19    22.4   -5.4  0.81    -9    28.6   +1.7  0.77    +2
RS              30.9   +3.6  0.64   -11    30.9   +6.2  0.65   -10    33.2   -7.1  0.54   -54
DK1             18.7   -6.5  0.81   -32    17.7   -4.1  0.81   -24    21.0   -4.0  0.78   -23
DE_LU           19.2  -12.0  0.84   -40    17.5   -9.5  0.87   -32    21.4  -10.7  0.80   -33
PL              26.0  -13.5  0.70   -54    24.3  -10.1  0.75   -47    27.5  -22.4  0.78   -53
ES              22.6   +5.4  0.79   +27    23.0   +4.6  0.77   +20    24.1   +9.7  0.76   +23
PT              23.7   +5.8  0.76   +29    24.1   +4.9  0.75   +22    24.9   +9.7  0.74   +24
GR              22.3   -3.7  0.83   +12    22.4   +0.1  0.83   +17    23.3  -12.9  0.82   -25
NO4             28.5   +1.3  0.13    +1    28.4   +1.4  0.17    +2    29.4  +25.7  0.82   +31
SE2             26.3  -10.0  0.49   -13    25.3  -12.0  0.55   -15    27.0  +20.3  0.80   +26
SE1             27.0   -9.9  0.49   -12    26.1  -11.9  0.54   -14    26.3  +19.2  0.80   +24
NO1             25.5   -2.6  0.39    -9    24.1   -0.5  0.45    -6    24.3  -18.6  0.74   -23
NO2             15.2   +0.5  0.73    -7    13.5   +2.2  0.80    -4    13.9   -5.7  0.75   -10
BE              19.6   -8.2  0.76   -31    18.4   -4.4  0.78   -25    18.1   +0.7  0.80   -19
IT-Sardinia     24.3   -0.3  0.58   +56    22.8   -0.2  0.61   +43    22.6   -0.5  0.61   +42
DK2             27.2   -9.1  0.70   -23    26.1   -7.3  0.72   -15    25.2  -11.0  0.72   -29
CZ              24.0   -8.4  0.68   -39    23.4   -4.2  0.69   -32    21.8  -16.0  0.84   -37
IT-CSOUTH       21.4   +5.6  0.65   +57    18.6   -0.3  0.68   +45    18.3   -0.6  0.67   +43
EE              41.8  -33.4  0.76   -59    35.2  -18.6  0.77   -41    38.3  -11.7  0.74   -31
SE4             31.4  -18.3  0.62   -39    28.1  -13.2  0.66   -32    27.4   -2.7  0.64   -16
NL              22.7  -10.6  0.69   -46    21.9   -8.5  0.69   -43    18.7   -4.9  0.80   -25
IT-Calabria     21.4   -8.4  0.66   +30    17.6   -3.0  0.74   +37    17.4   -3.3  0.74   +34
IT-Sicily       22.9  -10.3  0.64   +23    18.8   -5.3  0.72   +30    18.6   -5.7  0.72   +27
IT-SOUTH        22.1   -5.7  0.67   +41    18.0   -0.6  0.74   +43    17.7   -1.0  0.74   +41
SE3             28.2  +11.5  0.59    +3    27.3  +14.2  0.66    +7    22.3   -8.1  0.71   -16
NO5             28.8   +3.2  0.38    +4    27.8   +5.0  0.42    +6    22.9  -12.9  0.78   -11
IT-NORTH        29.7  +16.8  0.65   +60    23.7   +8.5  0.67   +47    23.3   +8.2  0.66   +45
IT-CNORTH       29.7  +16.0  0.65   +55    23.7   +7.9  0.67   +43    23.3   +7.6  0.66   +41
HU              40.6  -36.4  0.71   -67    38.1  -33.9  0.73   -64    32.8  -28.4  0.78   -77
LT              45.7  -40.2  0.73   -67    38.7  -29.7  0.75   -55    37.0  -23.1  0.73   -42
CH              29.2  -25.3  0.68   -27    27.4  -24.1  0.75   -22    20.2  -17.5  0.80   -20
AT              35.2  -28.7  0.64   -42    34.7  -28.7  0.63   -42    24.1  -20.9  0.84   -35
SK              37.6  -33.9  0.62   -66    34.5  -30.6  0.72   -61    25.8  -20.9  0.81   -47
LV              50.4  -45.8  0.68   -75    41.1  -32.6  0.72   -59    38.1  -25.4  0.73   -47
SI              42.4  -37.8  0.56   -57    40.8  -36.7  0.58   -55    28.1  -23.4  0.74   -57
NO3             43.5  +27.5  0.31   +37    43.2  +29.2  0.34   +40    20.4   +7.0  0.83   +14
------------------------------------------------------------------------------------------
cv31 record  footprint MAE  28.32  corr 0.650  cap-hours    0  collapse hit 1103/2578 (43%)  FA 1202
cv34 (off)   footprint MAE  26.24  corr 0.680  cap-hours    0  collapse hit 1099/2578 (43%)  FA 1019
+JAO         footprint MAE  25.32  corr 0.746  cap-hours    0  collapse hit 339/2578 (13%)  FA 122
  Core cluster   cv31 record: MAE  37.0 bias -32.4 b18   -52  cv34 (off): MAE  35.1 bias -30.8 b18   -49  +JAO: MAE  26.2 bias -22.2 b18   -47
  Baltics        cv31 record: MAE  45.9 bias -39.8 b18   -67  cv34 (off): MAE  38.3 bias -27.0 b18   -52  +JAO: MAE  37.8 bias -20.1 b18   -40
  Nordic hydro   cv31 record: MAE  29.9 bias  +1.6 b18    +1  cv34 (off): MAE  29.2 bias  +1.9 b18    +2  +JAO: MAE  25.1 bias  +6.8 b18   +10
  SEE            cv31 record: MAE  26.4 bias  -2.7 b18    -1  cv34 (off): MAE  26.4 bias  +1.6 b18    +4  +JAO: MAE  30.7 bias -16.7 b18   -52
  core west      cv31 record: MAE  21.0 bias  -7.0 b18   -28  cv34 (off): MAE  19.9 bias  -4.8 b18   -24  +JAO: MAE  23.0 bias  +3.3 b18   -16
```

**Reading.** Footprint MAE 26.24 → 25.32, corr 0.680 → **0.746**. The Core
cluster does what the diagnosis predicted (AT 34.7 → 24.1, SK 34.5 → 25.8, SI
40.8 → 28.1, CH 27.4 → 20.2, HU 38.1 → 32.8; corr 0.63–0.75 → 0.78–0.84);
NO3 43.2 → 20.4 (corr 0.34 → 0.83), NO5 27.8 → 22.9, SE3 27.3 → 22.3, CZ
23.4 → 21.8, NL 21.9 → 18.7. **But the same table shows the physics flaw of
maxBEX-as-ATC**: FR 21.8 → 34.0 (bias +28), RO 26.7 → 34.8 and BG 25.6 → 31.4
(bias −23), SE1/SE2 bias −12 → +20, NO4 bias +1 → +26; the collapse hit rate
falls 43 % → 13 % (false alarms 1019 → 122). Each maxBEX is the maximum for
ONE border with the others at zero; used simultaneously, a hub exports at
every border's max at once. Measured on FR: modelled net export 8.0 GW (`off`)
→ 16.4 GW (`+JAO`) against a bilateral-max sum of 34 GW (real FR net exports
average ~10 GW). The missing constraint is the hub's **min/max net position**,
which JAO publishes (`maxNetPos`, per hub per hour) — next arm. The full
flow-based domain (`finalComputation`: every CNEC with PTDFs and RAM, ~13k
rows/hour) is also public and is the real model for later.

HiGHS note: on the 108-link JAO network HiGHS segfaulted on 5 of the first 12
days (retry-once recovered 3); the JAO arm was finished on Gurobi (4 WLS
sessions, 40 days/h, 0 failures). Any backfill of this network should run on
Gurobi.
