# Zone Summary

Validation metrics comparing simulated prices against actual ENTSO-E day-ahead prices across bidding zones. Click column headers to sort.

<ZoneSummaryTable />

## Metric Definitions

| Metric | Definition |
|--------|-----------|
| **MAE** | Mean Absolute Error (EUR/MWh) — average magnitude of price errors |
| **RMSE** | Root Mean Squared Error (EUR/MWh) — penalises large deviations |
| **MAPE** | Mean Absolute Percentage Error (%) — scale-independent accuracy |
| **Correlation** | Pearson correlation — how well simulated prices track actual price movements |
| **Bias** | Mean bias (EUR/MWh) — positive = simulated prices too high, negative = too low |
| **Periods** | Number of time periods validated (quarter-hourly or hourly depending on zone) |

---

*These are placeholder values. Run the Julia export script to populate with actual validation results from the database.*

## Metabase: Zone Statistics

<script setup>
import MetabaseEmbed from '../.vitepress/components/MetabaseEmbed.vue'
import { metabaseEmbeds } from '../.vitepress/metabase.config'
</script>

<MetabaseEmbed :src="metabaseEmbeds.zoneStatistics" title="Zone statistics — Metabase" />
