# Datasets

This page catalogues the datasets used and produced by the Euphemia market clearing engine. Datasets are available as Parquet files for efficient columnar access. Generate them by running the Julia export script:

```bash
julia --project=. bin/export_website_data.jl
```

## ENTSO-E Source Data

<div class="dataset-grid">

<DatasetCard
  name="Production & Generation Units"
  description="Commissioned generation units across European bidding zones, including capacity, fuel type, location, and validity periods."
  format="Parquet"
  rows="~25,000"
/>

<DatasetCard
  name="Day-Ahead Total Load Forecast"
  description="Hourly or quarter-hourly day-ahead load forecasts per bidding zone from ENTSO-E Transparency Platform."
  format="Parquet"
/>

<DatasetCard
  name="Wind & Solar Generation Forecasts"
  description="Day-ahead generation forecasts for wind onshore, wind offshore, and solar per bidding zone."
  format="Parquet"
/>

<DatasetCard
  name="Offered Transfer Capacities (ATC)"
  description="Day-ahead net transfer capacities between bidding zones. Filtered to Day-ahead contract type only (excludes Intraday residual capacities)."
  format="Parquet"
  rows="~44 corridors"
/>

<DatasetCard
  name="Generator Unavailability"
  description="Planned and forced outages for generation units, including available capacity during partial outages."
  format="Parquet"
/>

<DatasetCard
  name="Actual Generation per Unit"
  description="Historical actual generation output per generation unit at 15/30/60-minute resolution. Used for parameter inference."
  format="Parquet"
  size="~54 GB (full)"
/>

</div>

## Simulation Results

<div class="dataset-grid">

<DatasetCard
  name="Energy Prices"
  description="Simulated day-ahead energy prices by bidding zone, clearing mode (single-zone, multi-zone, iterative), and optimizer."
  format="Parquet"
/>

<DatasetCard
  name="Optimization Runs"
  description="Metadata for each optimization run: solver, solve time, objective value, methodology parameters, and convergence metrics."
  format="Parquet"
/>

<DatasetCard
  name="Transmission Flows"
  description="Cross-border transmission flows from multi-zone market clearing, per corridor and time period."
  format="Parquet"
/>

<DatasetCard
  name="Inferred Generator Parameters"
  description="Plant-specific operational parameters (ramp rates, p_min, uptime/downtime) inferred from historical generation data."
  format="Parquet"
/>

<DatasetCard
  name="UC Results"
  description="Cached unit commitment solutions including generation schedules, commitment decisions, and cost breakdowns."
  format="Parquet"
/>

</div>

## Usage Examples

### Python (pandas + pyarrow)

```python
import pandas as pd

prices = pd.read_parquet("energy_prices.parquet")
prices_gr = prices[prices["bidding_zone"] == "GR"]
prices_gr.plot(x="date_time_utc", y="price", title="GR Day-Ahead Prices")
```

### Julia (Arrow.jl)

```julia
using Arrow, DataFrames
prices = DataFrame(Arrow.Table("energy_prices.parquet"))
filter!(r -> r.bidding_zone == "GR", prices)
```

### DuckDB (SQL)

```sql
SELECT bidding_zone, AVG(price) as avg_price
FROM read_parquet('energy_prices.parquet')
GROUP BY bidding_zone
ORDER BY avg_price;
```
