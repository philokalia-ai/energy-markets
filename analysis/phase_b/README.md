# Phase B — statistical attribution of the counterfactual residual

Reproducible pipeline for the four pre-specified tests attributing the GR
day-ahead residual (actual − v10 competitive counterfactual) to observable
strategic-behaviour signals. Findings and interpretation live in
[`docs/phase-b-analysis.md`](../../docs/phase-b-analysis.md). This directory is
just the code and its captured output.

**Register:** market-monitoring research — candidate hypotheses with alternatives
documented, never accusations.

## Run order

From the repository root, with a `.env` containing `ENERGY_CONN_STR` present:

```bash
set -a; source .env; set +a          # export the Postgres conn string

# 1. Build the three support tables (idempotent DROP+CREATE, ~seconds each)
psql "$ENERGY_CONN_STR" -f analysis/phase_b/01_build_phase_b_daily.sql
psql "$ENERGY_CONN_STR" -f analysis/phase_b/02_build_rsi_hourly.sql
psql "$ENERGY_CONN_STR" -f analysis/phase_b/03_build_firm_dark_share.sql

# 2. Run all regressions + figures; capture stdout as the canonical results
uv run --with pandas,numpy,statsmodels,matplotlib,scipy,psycopg2-binary \
    python3 analysis/phase_b/04_regressions.py | tee analysis/phase_b/results.txt
```

## Files

| File | Produces |
|---|---|
| `01_build_phase_b_daily.sql` | `simulations.phase_b_daily` — GR daily panel (1642 rows): residual + dark capacity + cost/demand/hydro/outage signals + FE dummies |
| `02_build_rsi_hourly.sql` | `simulations.rsi_hourly` — GR hourly RSI_PPC (39383 rows): net demand, net imports, fleet/PPC availability, hourly residual |
| `03_build_firm_dark_share.sql` | `simulations.phase_b_firm_dark` — firm×day dark_share (3 firms × 1642 days) for the cross-firm test |
| `04_regressions.py` | Tests A–D, figures under `docs/figures/phase_b/`, stdout → `results.txt` |
| `results.txt` | Canonical committed output — every number in the findings doc traces here |

## The four tests (see the doc for verdicts)

- **A (primary)** — daily `residual ~ dark_mw + controls + year FE`, HAC lag 7;
  reported per GW, with/without the 2022 regulated window, plus a `dark_mw_all`
  robustness cut and a binned-scatter figure.
- **B (primary)** — hourly residual by RSI_PPC bin + the same regression at
  hourly grain with an `RSI_PPC<1` dummy; share of pivotal hours per year.
- **C (exploratory)** — dark×pivotal interaction, dark split by fuel, and a
  ±5-day lead-lag cross-correlogram.
- **D (primary, first-pass)** — pairwise correlation of each firm's
  signal-residualised dark_share (daily and weekly), with a heatmap.

## Notes

- All writes are new `simulations.phase_b_*` / `rsi_*` tables; nothing existing
  is modified.
- Timezone discipline (`AT TIME ZONE 'UTC'` on every `entsoe.*` timestamp) is
  applied throughout — see header comments in the SQL files and the doc.
- Statistical honesty: A and B are exactly as specified (no specification search);
  C is labelled exploratory; nulls are reported as nulls with 95% CIs.
