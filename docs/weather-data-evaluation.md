# Weather data for DA price simulation — evaluation (July 2026)

Empirical evaluation of whether the `silentech.weather` database (see
`READING_WEATHER_DATA.md`) can improve day-ahead price simulation accuracy.
Benchmark: GR, 4 held-out days (2023-12-01, 2025-04-26, 2025-07-02,
2026-01-26), `:merit_order` method, 168 hourly points.

## Method

Correlate the model's hourly price residuals (simulated − actual DAM) against
national-average hourly weather from `weather.city_measure`, plus per-day bias
against trailing-60-day precipitation (hydro wetness proxy).

## Results

| Signal | Correlation with residual | Verdict |
|---|---|---|
| `temperature_2m` | +0.04 | none |
| `wind_speed_10m` | +0.00 | none |
| `direct_radiation` | +0.20 | weak |
| trailing-60d precipitation vs day bias | −0.03 (4 pts) | none measurable |

**Temperature and wind carry no incremental signal.** This is expected, not a
data problem: the model already consumes the ENTSO-E day-ahead load forecast
and wind/solar generation forecasts, which are themselves weather-driven. For
*price* simulation the market's own forecasts are the correct information set
— weather is upstream of inputs we already have.

**The radiation correlation is explained by curtailment, not forecast error.**
Actual GR solar output runs below the DA forecast (−370 MW average across the
3 post-2024 benchmark days; −628 MW on the high-solar April day), and the gap
correlates −0.70 with radiation. That gap is renewable curtailment: the DA
auction cleared on the forecast, so "correcting" the solar input toward
actuals would inject information the market did not have at auction time
(lookahead). Not a legitimate improvement path for DA price backtesting.

## What weather COULD still be used for

1. **Hydro water value modulation (most promising).** The merit-order book
   prices reservoir hydro at a fixed multiple of gas SRMC. In reality water
   value depends on hydrological conditions: wet periods → lower opportunity
   cost, dry → higher. Trailing precipitation (from `city_measure`, past data
   only — no lookahead) is a legitimate driver. The 4 benchmark days cannot
   discriminate this (needs a dedicated wet-vs-dry study across months, e.g.
   correlate monthly hydro output share vs trailing precipitation, then price
   residuals in high-hydro hours).
2. **Zones with poor ENTSO-E forecast coverage** — a weather-based RES/load
   proxy could fill gaps (GR does not need this).
3. **Honest forward-looking features**: `weather.city_forecast` archives
   near-continuous history from 2024-06-01; because it is upserted nightly,
   the stored value for a past timestamp approximates the last pre-delivery
   forecast — a legitimate day-ahead information set for backtests of dates
   after mid-2024.

## Gotchas found

- The connection snippet in `READING_WEATHER_DATA.md` appends
  ` connect_timeout=30` to a URL-format connection string, which libpq
  rejects — use `?connect_timeout=30` for URL-style strings.
- `city_measure` (ERA5) lags ~5-6 days; use `city_forecast` for the DA
  horizon, as the guide says.

## Conclusion

Not wired into the pricing model: measured incremental signal on the
benchmark is negligible because the ENTSO-E forecasts already embody the
weather. The one structurally-sound future use is precipitation-driven hydro
water value; it needs a dedicated seasonal study before adding parameters.
