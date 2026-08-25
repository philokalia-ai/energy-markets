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
