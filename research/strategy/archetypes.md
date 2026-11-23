# strategy archetypes: parameters and sources (st-blocks)

Built by `archetype()` in `src/strategy/formats.jl`. Nothing here is fitted to prices. Fuel/carbon closes follow the
repo's gate rule: the last close with date < D−1, i.e. D−2's close (`src/generators/fuel_costs.jl`, `_gate_lag_days`).

| id | zone(s) | size | cost (€/MWh) | technical | source |
|---|---|---|---|---|---|
| CCGT | GR IT-SOUTH DE_LU FR NO2 ES | 400 MW | SRMC = TTF/(0.55·0.90) + 0.202/0.55·EUA + 2.0 | Pmin 35 % (140 MW), min up 4 h, min down 2 h | `fuel_costs.jl` GAS_PLANT_EFFICIENCY 0.55, GAS_NCV_PER_GCV 0.90 (cv45 GAS_HHV, shipped), GAS_EMISSION_FACTOR 0.202, GAS_VOM_COST 2.0; `FuelTypeParameters.jl` "Fossil Gas" row |
| COAL (DE_LU) | DE_LU | 500 MW | SRMC = 37 + 0.90·EUA | Pmin 45 %, min up 8 h, min down 4 h | `fuel_costs.jl` FUEL_SRMC_BASE / FUEL_EMISSION_FACTOR_EL "Fossil Hard coal"; `FuelTypeParameters.jl` "Fossil Hard coal" |
| COAL (GR) | GR | 500 MW | SRMC = 25 + 1.25·EUA | Pmin 45 %, min up 24 h, min down 8 h | same, "Fossil Brown coal/Lignite" |
| start-up (thermal) | — | — | SU € = startup_cost_multiplier × SRMC × Pmax (gas 1.0, hard coal 2.0, lignite 2.5) | one start per run; the unit is off before 00:00 UTC of D | multiplier: `FuelTypeParameters.jl`; formula: `docs/experiments/proto_mini_uc.jl:49` (one full-load hour of fuel+CO2). Sensitivity: × 0.5 |
| HYDRO | NO2 FR ES IT-SOUTH | 300 MW, 3.6 GWh/day | water value = the zone's forecast daily mean price (base.prices of D) | no ramp/min-load | DESIGN.md §2; the baseline book carries no reservoir families (only `ESTOR:`), so there is no book water value to read |
| BESS | all 6 | 100 MW / 200 MWh | η round-trip 0.88 (√ per leg); no degradation cost | SoC empty at the start and end of D | DESIGN.md §2 |
| PSP | all 6 | 300 MW / 2.4 GWh | η round-trip 0.75 | same | DESIGN.md §2 |
| PVBAT | ES GR IT-SOUTH DE_LU | 200 MWp + BESS | PV at 0 €/MWh | PV = D-1 solar forecast / the zone's max hourly D-1 forecast over the prior 365 days × 200 | ENTSO-E D-1 solar forecast (`entsoe.generation_forecasts_for_wind_and_solar`) |
| FLEX | all 6 | 300 MW peak | firm 70 % at 4000 (HMMCP), 10 % curtailable at WTP 300, 20 % shiftable within D (≤ 120 MW/h) | shape = D-1 load forecast scaled to 300 MW peak | DESIGN.md §2; ENTSO-E D-1 load forecast |

A missing D-1 forecast takes the latest earlier day's (≤ 10 days back), logged per day in `inputs/<day>.json`
(`*_src`): 2026-10-25 GR & FR solar, 2026-11-06 and 2026-11-12 ES solar (from 2026-11-04).

Not modelled (stated in the report): no-load cost and part-load efficiency, ramp limits, hot/warm/cold start
distinction, battery degradation, PV/load volume forecast error (delivered = D-1 forecast), multi-day state
(each day starts cold / empty).
