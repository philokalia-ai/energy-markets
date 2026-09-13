# Energy markets: cv39 review and improvement priorities

**13 September 2026 · Canonical 39-zone model · Sicily, Germany, noon collapses and external-country integration**

**The next gains should come from correcting the evaluation target and physical constraints before adding more calibration.** cv39 captures broad price movements, but its low-price tail remains weak, and the Sicily cluster demonstrates excessive model scarcity. Germany's ordinary load aggregation is not the faulty path identified in the source: the stronger observed problems are the blending of different auction prices in evaluation and the exclusion of Germany's own network limits.

This review covers code `081e1165ed9326d948c1775e4ae3b06108f4653f` in `/home/pgeorgakopoulos/armada/energy-markets`, inspected through WSL/SSH. Read-only database checks confirmed **743,496 cv39 price rows, 795 saved days and 39 zones**, from 1 July 2024 through 6 September 2026. Source inspection, new database diagnostics and external research underpin the findings below. No model re-clear or production code change was performed. All event times below are UTC.

## 1. Where cv39 stands

An independent cv39-only calculation over 1 July 2024–30 June 2026 reproduces approximately **€24.96/MWh MAE, 0.778 pooled correlation and −€3.55/MWh bias**, over 681,744 matched zone-hours and 729 days. These use the repository's broad hourly settlement averaging convention, restricted to EUR. **They are provisional evaluation figures:** the auction-sequence contamination identified below must be corrected before treating small score differences as model improvement.

The saved record is also not uniformly complete. Within its 795 saved dates, SI has 779 days, BE 791, BG/RS 793, and EE/GR 794; the other zones have 795. Publish the coverage matrix alongside accuracy. An absent zone-day must not disappear silently from a release comparison.

A daytime screening calculation, using hours starting 09:00–15:00 UTC across the footprint, shows the scale of the tail problem:

| Hourly settlement threshold | Observed events | Correctly predicted events | False alarms | Recall |
|---|---:|---:|---:|---:|
| ≤ €5/MWh | 35,085 | 8,379 | 3,892 | 23.9% |
| ≤ €0/MWh | 17,312 | 69 | 0 | 0.4% |
| ≤ −€50/MWh | 781 | 0 | 0 | 0.0% |

These are **screening results over 198,842 matched zone-hours**, using the same provisional settlement convention. The UTC window is a broad daytime screen, not each country's local solar noon, and hourly averaging hides short negative-price episodes. Nevertheless, the near absence of nonpositive model prices merits a dedicated mechanism investigation. A good pooled correlation does not establish useful collapse prediction.

## 2. Sicily: real system stress, exaggerated model scarcity

The cluster on **24 February 2026** is confirmed directly in the database. Sicily has one settlement resolution and four EUR quarter-hour observations in each affected hour, so this comparison does not suffer from Germany's mixed-auction issue.

| Hour starting UTC | cv39, €/MWh | Settled hourly mean, €/MWh | Settled quarter-hour range, €/MWh |
|---|---:|---:|---:|
| 17:00 | 567.62 | 142.44 | 135.00–148.02 |
| 18:00 | 932.44 | 148.02 | 148.02–148.02 |
| 19:00 | 773.45 | 142.51 | 137.00–148.02 |
| 20:00 | 541.19 | 124.03 | 117.06–137.00 |

The four-hour mean absolute error is approximately **€564.43/MWh**. The model is creating a scarcity episode much larger than the day-ahead market priced.

**What the news supports.** Terna's 19 March 2026 announcement confirms that extreme weather on 18–21 January caused a landslide near the **Maida–Rizziconi** transmission line at Polia. Terna planned a local rerouting and identifies this corridor as strategically important for southern Calabria and Sicily. This is a credible reason to investigate transmission restrictions during February. It does **not** establish a specific capacity reduction at 17:00–20:00 on 24 February. The announcement was published after the event, so it is diagnostic evidence rather than an input available at the auction. [Terna announcement](https://download.terna.it/terna/Terna_al_via_iter_variante_elettrodotto_Maida_Rizziconi_Vibonese_8de85a3073dd9ea.pdf).

Terna's monthly report shows Sicily's February electricity requirement at **1,480 GWh, 3.7% above February 2025**. That supports moderately higher demand, not the magnitude or timing of a four-hour price spike. [Terna February 2026 report](https://download.terna.it/terna/Rapporto_Mensile_febbraio_26_8dea05ecff70578.pdf).

The same-date news about San Filippo del Mela concerns the plant's future and the anticipated end of its essential-service regime with new interconnection infrastructure. The regional parliamentary record discusses future security and employment, rather than establishing a shutdown on 24 February. Do not convert that headline into a dated loss of generating capacity. [24 February news report](https://lecronachedeisiciliani.com/2026/02/24/centrale-a2a-di-san-filippo-del-mela-interrogazione-urgente-alla-regione-timori-per-lavoro-e-futuro-energetico/), [Sicilian Assembly record](https://w3.ars.sicilia.it/DocumentiEsterni/ODG_PDF/ODG_18_2026_03_04_234_P.pdf).

**What the operational records establish.** The repository's ENTSO-E outage table contains the following overlapping records:

| Asset | Relevant record | Interpretation |
|---|---|---|
| `UP_ISABENERGY_3` | Zero availability; notice published 28 January | Known pre-auction loss of availability. |
| `UP_S.F._DEL_2` | Zero availability; foreseen maintenance | Known pre-auction maintenance. |
| `UP_S.F._DEL_5` | Zero availability; reason text `dismissione` | Treat as a fleet-status reconciliation issue; avoid counting a retired unit as recoverable headroom. |
| `UP_S.F._DEL_6` | Zero availability across 24 February; notice published 19 February | Known pre-auction maintenance spanning the cluster. |
| `UP_TRAPANI_C_2` | Zero availability, mechanical failure; an applicable version published 17 February | Known pre-auction failure; subsequent revisions must not replace the eligible vintage. |
| `UP_TERMINI_I_6` | Available capacity 350 MW, 17:00–23:00 on 24 February; published at 16:11 that day | Coincides with the cluster, but is unavailable to the day-ahead forecast. The 350 MW is remaining capacity, not the size of the loss. |
| `UP_ANAPO_C.L_1` | Cancelled outage message | Must not be treated as an active pumped-storage outage. |

The Termini notice attributes its derating to ambient air temperature. That is a useful operational lead, not sufficient proof that heat caused the model spike. Its six-hour duration is also below cv39's day-level outage threshold. Under the intended day-ahead cutoff it should not enter that forecast at all. This weakens a simple explanation that this coincident derating directly caused the cv39 price cluster.

**The remaining attribution work should be narrow and decisive.** Reconstruct 23–25 February with a frozen input snapshot and export, for every affected interval: eligible outage message/version, registry capacity, final offered MW by unit and tranche, demand, effective RES, storage availability, border capacities, accepted imports and the price-setting constraint. Reconcile availability against realised production for diagnosis while preserving the pre-auction input set for forecasting.

Then run separate counterfactuals for interval-level generation availability, the verified Calabria–Sicily transfer limits, and storage/thermal headroom. Include nearby non-spike evenings with similar residual load. The success criterion is both a credible explanation of the missing MW and improved prices without hiding genuine scarcity on other days. A Sicily-specific price cap would obscure the mechanism.

## 3. Germany: distinguish load arithmetic, market resolution and auction identity

**The mixed-resolution load defect is real, but is not active in the German source window inspected.** In `/home/pgeorgakopoulos/armada/energy-markets/src/Loads.jl:99`, the supplemental fine-to-coarse path repeatedly computes `(accumulator + next)/2`. Four values of 100, 200, 300 and 400 MW yield 312.5 MW instead of 250 MW. It applies when finer rows fill hours missing from a preferred coarser series.

The database contains only **PT15M** load forecasts for both DE and DE_LU over 1 July 2024–6 September 2026. DE_LU has **76,604 rows over 798 UTC dates**; one date, 26 October 2024, contains 92 rather than 96 records. Its ordinary conversion to the hourly clearing grid uses `sum/count` in `/home/pgeorgakopoulos/armada/energy-markets/src/merit_order/book_build.jl:489`, which is correct for complete equal-duration MW observations. There is no evidence here of Germany's normal load being quartered, quadrupled or processed by the erroneous mixed-resolution recurrence.

Fix the general recurrence with duration-weighted aggregation and interval-coverage checks. For Germany, investigate the missing DST-adjacent hour and its imputation separately. Retain the native quarter-hour profile for a quarter-hour model experiment; averaging correctly can still remove ramps that matter to nonlinear clearing prices.

**The market change is real, but did not introduce quarter-hour German load data.** SDAC moved to 15-minute delivery intervals on **1 October 2025**. German load forecasts were already quarter-hourly in this repository before that date. The change means the market target and the model's hourly approximation need explicit resolution treatment; it does not explain an arithmetic defect. [ENTSO-E SDAC implementation](https://www.entsoe.eu/network_codes/cacm/implementation/sdac/).

SMARD reports Q1 2026 German network load of **127.2 TWh, up 1.9%**, while residual load fell **8.5% to 72.9 TWh**. This supports evaluating changing renewable and demand combinations rather than inferring scarcity from gross load alone. [Bundesnetzagentur Q1 2026 report](https://www.smard.de/page/home/topic-article/219708/220298/nettoexport-von-strom-im-ersten-quartal).

**Load definitions need an explicit reconciliation.** SMARD's network-load definition includes network losses and excludes stored energy; its calculation subtracts pumped-storage charging from net generation plus net imports. It differs from gross electricity consumption and excludes several own-use/industrial components. Match DE versus DE_LU geography, forecast versus actual series, and storage treatment before applying a pumping adjustment. For interval energy in MWh, sum energy; for power in MW, duration-weight the mean. Never apply the MWh conversion to a price already quoted in €/MWh. [SMARD April 2026 manual, load definitions](https://www.smard.de/resource/blob/220052/9d526adf4b948599da4a956dfae6dab9/smard-benutzerhandbuch-04-2026-data.pdf).

**The directly observed aggregation problem is in settlement scoring.** The scorer groups by zone and hour and averages all `Day-ahead` prices without selecting `sequence`. In Germany and Austria, that combines separate auctions. EXAA documents an independent 10:15 auction and a 12:00 SDAC auction; the Austrian regulator explicitly identifies the early EXAA price as ENTSO-E sequence 2. These are economically different targets, not interchangeable revisions. [EXAA auction structure](https://www.exaa.at/energiehandel/handel-mit-exaa/), [E-Control sequence identification](https://www.e-control.at/strom/auffangversorgung).

At **24 February 2026, 17:00 UTC**, the stored German quarter-hour prices are **€198.97 for sequence 1 and €185.50 for sequence 2**, with different publication stamps. The scorer blends them. Across the two-year window, DE_LU has **10,966 hours containing multiple resolutions** and **6,554 hours containing different prices at the same timestamp/resolution** across the stored series. Austria has the same mixed-resolution count. DK1/DK2 also have conflicting same-slot prices and need their own provenance audit; do not assume the German explanation applies to them.

Selecting sequence 1 for the German comparison, without changing a single cv39 prediction, produces:

| Germany metric, 17,496 matched hours | Broad averaging | Sequence 1 |
|---|---:|---:|
| MAE, €/MWh | 20.05 | 21.07 |
| Correlation | 0.88 | 0.85 |
| Observed hours ≤ €5/MWh | 1,351 | 1,683 |
| Correctly predicted hours ≤ €5/MWh | 171 | 171 |
| Collapse recall | 12.7% | 10.2% |

This is a target-selection sensitivity check, not a new model result. The required fix is a canonical settlement view keyed by bidding zone, auction, delivery interval, currency and publication/version policy. Select the intended auction first, resolve revisions within that auction, then aggregate time. Validate samples against the exchange. A global `sequence = 1` filter is inappropriate: in this database it retains only Germany and Austria, so other zones require their own mapping.

**Germany's network limit is also dropped.** `/home/pgeorgakopoulos/armada/energy-markets/src/Network.jl:502` maps `DE` to `DE_LU`, then excludes every hub containing an underscore as virtual. The database supplies 24 German net-position records for 24 February, but this filter discards them. Neighbour constraints still act, so Germany is not wholly unconstrained. Replace string-shape classification with an explicit physical/virtual hub registry and test DE_LU retention. This can alter German surplus evacuation and neighbouring prices independently of load aggregation.

## 4. Noon collapses: improve the quantities and feasible outlets

**Start with a coupled surplus balance.** Diagnose renewable potential plus unavoidable generation, minus underlying load, feasible exports and incremental flexible absorption. Domestic solar/load ratios cannot tell whether surplus can leave the zone. Record why a low-price forecast did or did not occur: insufficient low-priced MW, excessive export capacity, missing must-run output, inflated demand, storage absorption or a binding bid-price floor.

**Carry the effective solar series into every mechanism.** The solar regime in `/home/pgeorgakopoulos/armada/energy-markets/src/merit_order/book_build.jl:1140` reads original rows tagged `Solar`. Weather substitution can change the effective renewable supply without providing the same solar series to the gate. Pass separate effective solar and wind series through book construction, scenario adjustments and regime calculations. Verify that a solar perturbation changes supply and its regime signal consistently, while a wind perturbation does not masquerade as solar.

**Replace bilateral approximations with the feasible exchange domain.** JAO maximum bilateral exchanges are projections calculated under particular net-position assumptions. Treating their collection as independent physical links does not reproduce simultaneous flow-based feasibility. [JAO publication handbook](https://www.jao.eu/sites/default/files/news/mail/Core_PublicationTool_Handbook_v1.4.pdf).

The existing domain probe is useful, but its physical-flow control also violates the published commercial domain. Complete a commercial-net-position control, including all domain coordinates or explicit boundary treatment, before attributing its violation frequency to model physics. Then impose PTDF/RAM constraints in an experimental re-clear and measure the change in collapse recall, false alarms, spreads and accepted exchanges. Domain handling must be dated: Core Advanced Hybrid Coupling went live for delivery **11 June 2026**, so a January mapping does not validate the full backtest. [ENTSO-E implementation record](https://www.entsoe.eu/network_codes/cacm/implementation/sdac/).

Fix the smaller network defects first: enforce true zero limits; apply outage caps after all capacity sources have been assembled; and remove reliance on sequential in-place hub scaling. Sorting the latter makes the approximation repeatable but does not turn it into the simultaneous domain. Source locations: `/home/pgeorgakopoulos/armada/energy-markets/src/Network.jl:894`, `:898`, `:926`, `:946`, `:965`.

**Represent inflexibility and flexibility over time.** Move generation availability from the day-level 12-hour rule to interval-specific MW. Add thermal minimum output, startup/ramp constraints and a limited commitment formulation where these explain both midday must-run supply and evening headroom. Start with a bounded regional experiment before paying the computational cost across all zones.

Storage requires charging/discharging limits, efficiency, inventory evolution and terminal energy value. Reconcile embedded pumping before introducing endogenous charging demand. Without an energy balance, extra pumping can manufacture absorption; without initial inventory, extra discharge can manufacture evening supply. Test noon and evening jointly because charging can raise noon prices even when it improves the daily profile.

The hydro spill gate and conduct/opportunity layers already exist. Advance the spill quantity model using usable reservoir capacity, inventory, inflow and feasible release—not inventory relative to a historical seasonal maximum interpreted as physical fullness. Keep the gate experimental until a canonical 39-zone test supports it. Evaluate coherent low/central/high opportunity-cost assumptions for hydro and thermal flexibility. A fitted markup's predictive contribution alone does not identify market power.

**Forecast event probabilities as well as a central price.** Add probabilities for ≤€5, <€0 and deep-negative prices, together with conditional quantiles and event duration. Use spatially and temporally coherent load/RES/outage/boundary scenarios. Report calibration, precision–recall and onset/duration errors by local daytime, season and zone. A small MW error close to a congestion threshold can flip the event; a single deterministic trajectory hides that risk.

## 5. UK, Türkiye and Ukraine: shared external-country balances

The modelling distinction is membership in the current market footprint and coupling arrangement. The boundary abstraction is a useful starting point, but independently priced border books do not constrain a neighbour's total exportable surplus or import need across all its connections.

There is also a concrete overlap to resolve. The boundary builder independently inserts import supply and export demand; GB ladders can offer supply at `1.00 × anchor` and demand at `1.05 × anchor`. With no shared external balance or directional scheduling constraint, both can clear and create welfare from a virtual round trip. Enforce country energy conservation, cable net schedules, losses and directional capability. Source: `/home/pgeorgakopoulos/armada/energy-markets/src/merit_order/boundary.jl:320` and its profile definitions.

| External system | cv39 representation | Next implementation | Validation focus |
|---|---|---|---|
| **Great Britain** | Elastic books on selected interfaces; other links rely on flow estimates/backstops. Fuel/carbon anchors and proxies vary by profile. | One reduced GB balance spanning connected links, with GB load, wind, nuclear/outages, storage and a fuel-based residual supply curve. Preserve link-specific allocation timing. | Aggregate GB net imports, cable schedules, stress hours, negative-price export demand and simultaneous continental interactions. |
| **Türkiye** | No TR elastic country book in the reviewed code; GR/BG interfaces use external-flow treatment. | A shared two-border TR balance with EPİAŞ fundamentals, hydro state, domestic fuel costs, FX, dated availability and trade limits. | Joint GR/BG effects, hot-weather load, hydro regimes, directional reversals and constrained exports. |
| **Ukraine/Moldova** | UA ladders use local EU gas anchors, demonstrated flow capability and a historical firm-demand slice. | A shared external balance with dated transfer limits, available generation and uncertain import demand; represent Moldova consistently. | Total feasible imports across RO/HU/SK/PL, disruption regimes, recovery periods and boundary uncertainty. |

For GB, add an NBP–TTF basis or direct GB gas input, heat-rate variation, UKA and separately modelled Carbon Price Support. Align issue times and currencies. Elexon's demand-series definitions distinguish treatment of pumping and interconnector demand; choose one consistent with the balance. [Elexon demand API](https://bmrs.elexon.co.uk/api-documentation/endpoint/forecast/demand/day-ahead/history), [UK government carbon-price-support rates](https://www.gov.uk/guidance/climate-change-levy-rates). A shared physical balance must still respect each link's actual trading arrangement. [NESO interconnector study](https://www.neso.energy/document/353466/download).

Türkiye is synchronously connected through Greece and Bulgaria; synchronous operation does not imply SDAC coupling. Use the published physical and commercial arrangements separately. Ingest capacity only from evidenced commissioning and availability dates. [ENTSO-E system report](https://eepublicdownloads.entsoe.eu/clean-documents/SOC%20documents/SOC%20Reports/Continental%20Europe%20Synchronous%20Area%20Separation%20on%2008%20January%202021%20-%20Main%20Report_updated.pdf), [EPİAŞ technical documentation](https://seffaflik-prp.epias.com.tr/electricity-service/technical/tr/index.html).

For Ukraine/Moldova, a trailing flow percentile is an observation of utilisation, not today's commercial transfer limit. ENTSO-E documents changing capacity responsibilities and regional adequacy conditions. Prefer dated published limits and allocations, with an uncertainty band for external demand and supply. Treat the historical firm-import slice as a state estimate rather than an immutable requirement. [ENTSO-E Winter Outlook 2025–2026](https://eepublicdownloads.entsoe.eu/clean-documents/sdc-documents/seasonal/WOR2025/Winter_Outlook_2025-2026_Report.pdf).

## 6. Data and modelling discipline

**Make issuance eligibility enforceable.** `ForecastContext` already exists and controls several outage, fuel and trailing-generation inputs. Some readers only classify stored values as post-gate or unverifiable and still return them. Auditing is valuable, but cannot reconstruct a missing earlier revision. Capture append-only input vintages, persist the source snapshot and audit identity with predictions, and define explicit fallback/failure behaviour for unverifiable inputs. Extend this to remaining ML features, reservoir publications and capacity caches. Test that a later issuance cannot contaminate an earlier issuance in the same process.

Open-Meteo's previous-run offsets represent lead-relative forecasts; they do not automatically select one common model initialization for a fixed D-1 issue time. Retrieve an explicit run and verify its availability before issuance. Keep hindsight diagnostics separate from forecast inputs. [Previous Runs API](https://open-meteo.com/en/docs/previous-runs-api), [Single Runs API](https://open-meteo.com/en/docs/single-runs-api).

**Separate renewable potential from realised injection.** A trailing production percentile mixes installed capacity, weather, outages and curtailment. Use dated capacity and spatial weather weights to estimate unconstrained potential, then model curtailment explicitly. Reconcile behind-the-meter PV with the load definition so it is not subtracted twice. Score TSO forecasts, available renewable production and realised injection as distinct targets.

**Train against the corrected target and test chronologically.** Auction blending can affect model selection, residual correction and conduct diagnostics as well as reported accuracy. Repair the target before retraining. Use rolling-origin training and later held-out blocks, retaining joint load/RES error scenarios. Report coverage, source quality, forecast lead and regime alongside pooled scores. Block-bootstrap by day or week for uncertainty rather than treating coupled zone-hours as independent samples.

**Bind displayed outputs to the evaluated model.** `/home/pgeorgakopoulos/armada/energy-markets/bin/emit_model_lines.py:31` hard-codes a book directory that is not cv39, its default version selector also differs, and it can reuse a cached training artifact. Bind book version, model version, target definition and training artifact hash together; fail on mismatch. Check the emitted record before assuming users see the model evaluated here.

## 7. Recommended execution order

| Priority | Deliverable | Acceptance evidence |
|---|---|---|
| **1 — establish trustworthy evaluation** | Canonical auction-specific settlement view; German/AT sequence reconciliation; DK price-conflict audit; fixed coverage manifest. | One intended price per interval, explicit revision rules, exchange spot checks, and recomputed cv39 accuracy/tail metrics. |
| **2 — repair confirmed implementation defects** | DE_LU hub retention, mixed-resolution fallback mean, effective-solar propagation, final capacity-cap pass and true-zero handling. | Focused unequal-value, hub-mapping and border-cap invariants; isolated re-clears showing each change's contribution. |
| **3 — close the Sicily attribution** | A unit/border/price-setting trace for the cluster and matched control evenings. | Explain missing MW using eligible source records; demonstrate which change resolves excessive scarcity without suppressing real stress. |
| **4 — validate noon physics** | Commercial-domain control and constrained network experiment, followed by bounded commitment/storage/spill experiments. | Better local-noon event recall at a declared false-alarm budget, credible flows/inventories, and no unacceptable evening or seasonal regression. |
| **5 — integrate external balances** | Shared GB, TR and UA/MD reduced models, staged separately. | Country energy conservation, feasible cable schedules, credible total external exchanges and out-of-sample benefit. |
| **6 — release a forecast contract** | Immutable issue-time inputs, chronological ML evaluation, consistent output provenance and calibrated event probabilities. | Reproducible predictions from a declared snapshot; verified eligibility or explicit fallback status for every input family. |

Use cv39 as the frozen control with the **same 39-zone footprint, source snapshot, solver settings and scoring target** for each experiment. Make each package explain its MW and price effects before combining packages. The highest-value immediate work is the settlement-target correction, Germany's missing network constraint and the Sicily operational trace; these determine whether subsequent calibration is learning the market or compensating for avoidable data and structural errors.

**Evidence scope.** Database diagnostics were executed on 13 September 2026 against `simulations.energy_prices`, ENTSO-E load/price/outage tables and `jao.hub_net_positions`. The headline and daytime screening statistics use hourly means of currently stored EUR day-ahead records and carry the target limitations described above. German sequence sensitivity uses only DE_LU sequence 1; Sicily uses its complete four-quarter settlement observations. Source review also covered `/home/pgeorgakopoulos/armada/energy-markets/src/generators/registry.jl:208`, `/home/pgeorgakopoulos/armada/energy-markets/src/ForecastContext.jl`, and the existing flow-domain, spill-gate, conduct-layer and issuance-contract experiment documentation. Causal effects of proposed model changes remain to be established by re-clearing.
