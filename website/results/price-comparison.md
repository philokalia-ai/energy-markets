# Price Comparison

Simulated day-ahead prices versus actual ENTSO-E prices. Use the slider or scroll to zoom into specific time windows. Hover for exact values.

## Greece (GR)

<PriceChart zone="GR" />

---

*To populate with real data, run the Julia export script:*

```bash
julia --project=. bin/export_website_data.jl
```

This generates per-zone JSON files in `website/public/data/` that the chart components load automatically.
