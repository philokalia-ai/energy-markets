# Where the market sees something we don't — data investigation (2026-08-25)

Owner question after the cv34 evaluation: "it feels we don't have the whole
information for all the cases — investigate the data where we are far off the
correlations; the market must be seeing something else." Evidence base: the
cv34 shipped arm (44 paired Wednesdays 2025-07..2026-06, 39 zones) vs settled
Day-ahead prices, a per-zone data-completeness audit on live Postgres over the
same year, and a web pass on what each region's market watchers cite.

## 1. The worst zones fall into three families with distinct signatures

Shipped arm vs settled, plus how each zone relates to DE_LU in the SETTLED
prices vs in OUR prices (the last four columns are the finding):

| zone | corr | bias | bias @00/06/12/18 | winter / summer bias | settled~DE_LU corr | ours~DE_LU corr | settled − DE_LU | ours − DE_LU |
|---|---|---|---|---|---|---|---|---|
| **Core-FBMC cluster** | | | | | | | | |
| HU | 0.67 | −35 | −28 / −50 / −9 / **−71** | −27 / −39 | 0.84 | 0.56 | **+17** | **−7** |
| SK | 0.64 | −33 | −17 / −49 / −18 / **−72** | −40 / −34 | 0.88 | 0.81 | +10 | −12 |
| SI | 0.54 | −35 | −42 / −40 / −12 / **−54** | −23 / −46 | 0.82 | 0.51 | +12 | −11 |
| AT | 0.60 | −30 | −24 / −37 / −14 / **−50** | −29 / −38 | 0.93 | 0.62 | +10 | −9 |
| CH | 0.74 | −25 | −26 / −23 / −24 / −23 | −20 / −29 | 0.78 | 0.77 | +10 | −4 |
| **Baltics** | | | | | | | | |
| LV | 0.71 | −32 | −18 / −46 / −17 / **−61** | −29 / −30 | 0.60 | 0.46 | −4 | −25 |
| LT | 0.75 | −29 | −12 / −45 / −16 / **−55** | −29 / −25 | 0.60 | 0.53 | −3 | −21 |
| EE | 0.76 | −19 | +1 / −33 / −11 / **−44** | −21 / −13 | 0.50 | 0.44 | −16 | −24 |
| **Nordic hydro** | | | | | | | | |
| NO4 | 0.18 | +1 | +5 / −3 / +1 / 0 | **−31 / +17** | 0.17 | 0.08 | −77 | −65 |
| NO3 | 0.32 | +29 | +34 / +34 / +6 / +40 | **+7 / +57** | 0.14 | **0.63** | −53 | −13 |
| NO1 | 0.34 | +2 | +14 / −1 / −8 / −5 | **−9 / +16** | 0.45 | 0.50 | −23 | −10 |
| NO5 | 0.41 | +6 | +16 / +6 / −11 / +7 | **−12 / +40** | 0.25 | 0.73 | −30 | −13 |
| SE1 | 0.55 | −12 | −11 / −22 / −4 / −14 | **−35 / −4** | 0.16 | −0.06 | −68 | −69 |
| SE2 | 0.55 | −12 | −11 / −20 / −4 / −15 | **−35 / −6** | 0.14 | −0.07 | −68 | −70 |

Reading the columns:

- **Core cluster.** The settled prices of HU/SK/SI/AT sit **+10..+17 €/MWh
  above DE_LU and follow it at corr 0.82–0.93**. Ours sit **−7..−12 below
  DE_LU** and follow it less. The whole miss is the evening: −50..−72 at 18:00.
  The market couples these zones to Germany through the Core flow-based domain
  and adds a congestion premium; we dropped their Core borders (cv15/cv17) and
  inject their observed imports as free, fixed MW — so an importing zone in
  our book can be cheaper than the zone it imports from, which no coupled
  market allows.
- **Baltics.** Same evening shape (−44..−61 at 18:00). Settled ≈ DE_LU −4;
  ours DE_LU −22. Since the Feb-2025 desynchronisation the Baltics are a
  Finland/Sweden-fed island with a thin local stack; their evening price is an
  import-scarcity premium we do not represent.
- **Nordic hydro.** Not a level problem but a **season** problem: winter
  −31..−35 (too cheap), summer +17..+57 (too expensive) in NO3/NO4/NO5/SE1/SE2
  — the water value is mis-phased. And NO3/NO5 follow DE_LU in OUR prices (corr
  0.63/0.73) but not in reality (0.14/0.25): the `:hydro` opportunity anchor
  couples interior Norway to the continental reference through borders the
  real grid bottlenecks.

## 2. What the data actually holds for those zones (live Postgres, 2025-07..2026-06)

| zone | outage msgs / assets | RES NULL % / types | load NULL % / days | **ATC Day-ahead rows** | ATC all rows | borders | registry MW (Other %) |
|---|---|---|---|---|---|---|---|
| AT | 1,171 / 42 | 0.0 / 2 | 0 / 365 | 28,032 | 479,716 | 6 | 15,115 |
| CH | 2,335 / 42 | 0.2 / 2 | 0 / 365 | **0** | 37,210 | 3 | 13,723 |
| HU | 8,453 / 111 | 0.0 / 2 | 0 / 365 | **0** | 349,440 | 4 | 16,033 (6.1 %) |
| SK | 127 / 18 | 0.2 / 2 | 0 / 365 | **0** | 262,080 | 3 | 4,383 |
| SI | 42 / 3 | 3.5 / **1** | 0 / **357** | 3,601 | 353,041 | 4 | 2,694 |
| EE | 151 / 7 | 0.0 / 2 | 0 / 365 | 56,400 | 231,120 | 2 | 2,251 |
| LT | 114 / 8 | 0.0 / 2 | 0 / 365 | 62,476 | 324,556 | 5 | 2,655 |
| LV | 30 / 6 | 0.0 / 2 | 0 / 365 | 36,936 | 211,656 | 2 | **981** |
| NO1 | 26 / 5 | 0.0 / 2 | 0 / 365 | **0** | 279,552 | 4 | 1,691 |
| NO3 | 27 / 3 | 0.0 / 2 | 0 / 365 | **0** | 349,440 | 4 | 1,798 |
| NO4 | 252 / 19 | 0.0 / 2 | 0 / 365 | **0** | 262,080 | 3 | 3,168 |
| NO5 | 523 / 32 | 0.0 / 2 | 0 / 365 | **0** | 174,720 | 3 | 3,059 |
| SE1 | 974 / 36 | 1.7 / 2 | 0 / 365 | **0** | 262,080 | 3 | 1,495 |
| SE2 | 164 / 17 | 1.7 / 2 | 0 / 365 | **0** | 349,440 | 4 | **443** |
| DK2 | 163 / 10 | 1.2 / 3 | 0 / 365 | **0** | 262,080 | 3 | 1,819 |
| (DE_LU) | 62,661 / 186 | 0.0 / 3 | 0 / 365 | 56,832 | 843,072 | 9 | 49,034 |
| (FR) | 10,226 / 276 | 0.4 / 3 | 0 / 365 | 62,976 | 419,858 | 5 | 93,188 |

Three findings, in order of weight:

1. **The market's capacity information is missing for exactly the worst
   zones.** Every Core-FBMC and Nordic zone above has **zero Day-ahead
   offered-ATC rows for the whole year** (SI: 3,601). Those borders are
   allocated flow-based (Core since June 2022, the Nordics since 29 Oct 2024)
   and ENTSO-E's "offered capacity" table only carries what remains — intraday
   leftovers, often 0 MW. Our network there runs on the cv26 all-rows fallback
   or the cv27 demonstrated-capability p95 per 4-hour block (7 borders). The
   flow-based domain the market cleared on — per-hour **max bilateral
   exchanges (maxBEX)** and **min/max net positions** per hub, and underneath
   them the PTDF/RAM constraints — is **not in our data at all**. It is public:
   the JAO Publication Tool exposes Core and Nordic CCRs (and Italy North) over
   an API (see §4).
2. **The per-unit registry barely exists in the Nordics/Baltics.** SE2 443 MW,
   LV 981 MW, SE1 1.5 GW, NO1/NO3 1.7–1.8 GW of registered units against
   fleets of 4–10 GW: ENTSO-E's unit registry lists units ≥ 100 MW and the
   Nordic/Baltic fleets are hundreds of small hydro and wind plants. The p95
   fleet completion carries those zones almost entirely, at one SRMC per type
   — the water-value ladder has ~no unit structure to work with there.
3. **Outage reporting is thin where it matters least and where it matters
   more.** NO1 26 messages/year, NO3 27, LV 30, SI 42, SK 127 (DE_LU 62,661).
   For hydro that is tolerable; for SK's nuclear/thermal and SI's Krško it is
   not. SI additionally has only a solar RES forecast (no wind series) and 8
   days without a load forecast; HU carries 1 GW of "Other" in its registry.

RES/load NULLs, on the other hand, are now handled (#342, and the load twin in
this PR) and are not what separates these zones from the good ones.

## 3. What each region's watchers say drives its price

- **Austria / Hungary / Slovakia (Core).** Austria trades at a premium over
  Germany, largest when hydro is weak, since the DE–AT split of Oct 2020; the
  region has been inside Core flow-based coupling since June 2022, so its
  price is DE_LU plus whatever Core congestion costs that hour
  ([APG](https://markt.apg.at/en/electricity-market/european-internal-electricity-market/),
  [Montel: Austria — bottleneck or catalyst](https://montel.energy/commentary/austria-bottleneck-or-catalyst-for-price-convergence),
  [Next-Kraftwerke on FBMC](https://www.next-kraftwerke.com/knowledge/market-coupling)).
  HUPX peak prices ran 97 €/MWh in Sep 2025 and 142 in Nov 2025 — a peak
  premium the trade press attributes to import dependence at the evening ramp
  ([HUPX Sep 2025](https://serbia-energy.eu/hungary-hupx-electricity-prices-rise-27-in-september-2025-trading-volumes-decline/),
  [HUPX Nov 2025](https://serbia-energy.eu/hungary-hupx-electricity-prices-rise-in-november-2025-as-day-ahead-volume-hits-2-76-million-mwh/)).
  EU-wide 2025 wholesale was up ~10 % on gas ([IEA Electricity 2026](https://www.iea.org/reports/electricity-2026/prices)).
- **Baltics.** Desynchronised from BRELL 8–9 Feb 2025; EstLink 2 out from
  Dec 2024 until 19 Jun 2025 and EstLink 1 (350 MW) out most of Sep 2025,
  cutting Finland import capacity 1,000 → 650 MW; morning/evening spikes
  (Lithuania/Latvia daily averages near 291 €/MWh in Oct 2025, individual
  hours above 1,000); 15-minute MTU since Oct 2025
  ([AST market review](https://www.ast.lv/en/electricity-market-review?month=6&year=2025),
  [Elenger Q4 2025](https://elenger.ee/en/power-market-overview-q4-2025/),
  [ERR on reserve-market spikes](https://news.err.ee/1609765872/huge-price-spikes-on-baltic-reserves-market-likely-due-to-one-latvian-participant),
  [Euronews Feb 2025](https://www.euronews.com/2025/02/12/electricity-prices-rise-in-estonia-after-cut-from-russian-power-grid)).
  **Interconnector outages are the Baltic price story and we do not model
  them**: the unavailability table we read is for generation units; ENTSO-E
  publishes transmission outages separately (`unavailability_of_transmission
  _infrastructure`), which is not in our ETL.
- **Northern Norway (NO3/NO4).** NO4 averaged ~5 øre/kWh in Q2 2025, 12–14×
  below the south; reservoirs in NO3/NO4 above the historical maximum since
  2024 (85.5 % end of Q2 2025); the north–south corridors bottleneck, so the
  price is local hydrology, not the continent
  ([SSB](https://www.ssb.no/en/energi-og-industri/energi/statistikk/elektrisitetspriser/article-for-electricity-prices/lowest-electricity-price-in-four-years),
  [Montel: what drives NO1–NO5](https://montel.energy/resources/blog/what-factors-influence-norways-no1-no5-hydropower-prices),
  [arXiv: forecasting Norway's five zones post-crisis](https://arxiv.org/html/2604.26634v1)).
  This is our NO3 signature exactly (ours follows DE_LU at 0.63, reality 0.14).
- **Northern Sweden (SE1/SE2).** 2025 exceptionally wet → very low SE1/SE2;
  2026 forecasts ~35 öre vs 60–80 in the south; Svenska kraftnät's own
  simulations say **flow-based raises SE1/SE2 prices** by exporting more, and
  the new Aurora line to Finland adds export capacity
  ([Sweden Herald](https://swedenherald.com/article/cheaper-electricity-expected-in-2026-for-southern-sweden),
  [Theia](https://www.theia.global/article/electricity-price-gap-in-sweden-expected-to-narrow-by-2026-37832ea5),
  [LyncMe](https://www.lync.me/blog/660/electricity-prices-2026-zone-4-south-pays-more)).
- **Italy North.** Highest DA prices in Europe (~152 €/MWh 2026 average);
  evening spikes when gas exceeds ~20 % of the mix; TIDE dispatching reform
  and 15-minute balancing from Feb 2026
  ([IBTimes IT](https://it.ibtimes.com/why-italy-pays-europes-highest-power-prices-why-diversification-hasnt-helped-100937),
  [Argus on TIDE](https://www.argusmedia.com/en/news-and-insights/latest-market-news/2772776-italy-to-update-power-dispatching-rules),
  [PricePedia on PUN hourly effects](https://www.pricepedia.it/en/magazine/article/2024/11/12/hourly-and-daily-effects-on-the-pun-price/)).
  Our IT-NORTH is +40 in winter evenings — the opposite sign of the Core
  cluster — so it is a stack/scarcity-form issue, not a coupling one.

## 4. What to add to the data, in order of expected return

1. **JAO flow-based publications** (Core, Nordic, Italy North CCRs; public
   API at `publicationtool.jao.eu/<ccr>/api/data/<dataset>`, no key needed —
   **verified 2026-08-25**: `GET /core/api/data/maxExchanges?FromUtc=…&ToUtc=…`
   returns 24 rows for the day with one column per directed border,
   `border_AT_HU` = 2,978 MW at 2026-04-03 00:00 UTC, `border_AT_DE` 4,747,
   `border_AT_CZ` 4,719 …): per-hour **max bilateral exchange** per border and
   min/max net position per hub — the market's own day-ahead capacity
   information for every border that has no Day-ahead ATC row. First use: replace the cv26 all-rows fallback / cv27 p95 on
   FB borders with maxBEX as the ATC (ex-ante: published D-1 ~10:30 CET,
   before the gate). Second use: the actual flow-based constraints (PTDF ·
   net positions ≤ RAM) as a network model, which would also give the Core
   cluster its congestion premium mechanically instead of by a bidding rule.
2. **ENTSO-E transmission-infrastructure unavailability** (interconnector and
   line outages) into the ETL — the Baltic (EstLink) and Nordic story.
3. **Aggregate per-type installed capacity per zone** (ENTSO-E 14.1.A) to
   complete the Nordic/Baltic fleets where the unit registry stops at 100 MW.
4. Fill SI's wind forecast series and check its 8 missing load days; classify
   HU's 1 GW of "Other".

## 5. Model-side candidates the data suggests (for A/B, not shipped)

- **Ref-priced imports over dropped Core borders**: the observed-import
  injection into HU/SK/SI/AT is priced at the pass-1 coupled reference of the
  exporting hub (DE_LU/AT), not injected free — the same idea as
  `ref_priced_exports` (SI–HR, BE–GB), on the import side. Expected to move
  the evening miss (−50..−72) most of the way; this is the physics a coupled
  market enforces (an importer cannot clear below its source).
- **Nordic water-value phase**: winter too cheap / summer too dear in every
  hydro zone — the seasonal drawdown term is mis-phased; and the `:hydro`
  anchor over-couples NO3/NO5 to the continental reference.
