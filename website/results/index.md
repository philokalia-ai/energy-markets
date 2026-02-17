# Results

Simulation results from the Euphemia market clearing engine, validated against actual ENTSO-E day-ahead prices.

## Available Analyses

### [Price Comparison](/results/price-comparison)
Interactive time-series charts comparing simulated and actual day-ahead prices per bidding zone, with zoom and tooltip inspection.

### [Zone Summary](/results/zone-summary)
Sortable table of validation metrics (MAE, RMSE, MAPE, correlation, bias) across all simulated bidding zones.

---

## Metabase Dashboards

Selected results are also available as interactive Metabase charts embedded directly on the pages above. These pull live data from the database — no manual export needed.

To configure the embeds, enable public sharing on your Metabase questions and update the URLs in `.vitepress/metabase.config.ts`. See the [metabase README](https://github.com/silentech-inc/energy-markets/tree/main/metabase) for details.

---

*Additional visualisations (geographic price maps, transmission flow diagrams) are planned for future releases.*
