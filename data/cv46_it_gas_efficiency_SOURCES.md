# cv46 P3a: Italian gas unit efficiency crosswalk (`cv46_it_gas_efficiency_ppm_v0.9.1.csv`)

- **Source:** PyPSA powerplantmatching (MIT licence), https://github.com/PyPSA/powerplantmatching
  - File: `powerplants.csv` at tag **v0.9.1** (published 2026-10-07T16:42:44Z), from
    https://raw.githubusercontent.com/PyPSA/powerplantmatching/v0.9.1/powerplants.csv
  - sha256 `ceccce02edd33813216a264fe6c8e3281ce2249435a259c1b1a1b729ce4f3d78`, downloaded 2026-11-22.
- **ENTSO-E side:** `entsoe.production_and_generation_units` in the extract `euphemia-live-20261115.duckdb` (read-only).
- **Builder:** `python -I bin/cv46_it_gas_efficiency.py powerplants.csv <extract.duckdb> data/cv46_it_gas_efficiency_ppm_v0.9.1.csv v0.9.1`.
  The csv module only parses it; nothing from the download is executed.
- **Rules** (full text in the builder docstring):
  - Italian Natural Gas rows; PPM codes (its EIC set and `projectID['ENTSOE']`) are joined to every production- and generation-unit EIC the ENTSO-E unit ever had.
  - `status == use` requires: PPM Set == PP (CHP excluded), an efficiency inside the technology band, and DateIn/DateRetrofit ≤ 2024.
  - Bands, net LHV: CCGT [0.45, 0.64], Steam Turbine [0.30, 0.45], OCGT/Combustion Engine [0.28, 0.45]. Source: IEA-ETSAP Technology Brief E02 "Gas-Fired Power" (2010); the CCGT upper end is the best demonstrated CCGT.
- **Vintage rule:** a documented plant efficiency is a static engineering characteristic and is not price-informed. A release after the window is used only for units commissioned and retrofitted no later than 2024, strictly before the first decision day (2025-07-03).
- **Coverage:** 9 units, 4,387 MW = 8.3 % of the Italian gas MW with output in 2025-07..2026-11 (52.6 GW); 6.5 % of the registry MW.
  - Units: Mincio 0.46, Porto Corsini ×2 0.553, Rizziconi ×2 0.56, Sparanise ×2 0.56, Gissi ×2 0.57.
- **Compared:**
  - v0.8.1 (2026-02-11, sha256 0bb395b2…ad8ed703) gives the identical 9 units.
  - v0.7.1 (2025-02-01, sha256 347978d8…cfde9993) gives 5 units / 2,507 MW: its Rizziconi and Sparanise values (0.19 and 0.38) fail the band.
  - Astra's crosswalk (`reports/analyst-work/novbias/ppm_gas_eic.parquet`) is derived from PPM; it adds no Italian plant.
