#!/usr/bin/env python3
"""Figures for the physics-audit experiment (README.md in this directory).

Reads the public extract's parquet directory + the full-sweep findings CSV and
writes the three committed PNGs. Rerun after a new sweep:

  python docs/experiments/physics-audit/make_figures.py \
      --parquet data/public/euphemia-data-v1.1 \
      --findings <audit-full.csv> \
      --out docs/experiments/physics-audit
"""
import argparse
import duckdb
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

# Reference dataviz palette (light mode): series-1 blue, series-2 orange,
# neutral ink/greys; one axis per chart, thin marks, recessive grid.
BLUE, ORANGE, INK, MUTED, GRID = "#2a78d6", "#eb6834", "#0b0b0b", "#52514e", "#e5e4e0"
SURFACE = "#fcfcfb"


def style(ax, title, subtitle, ylabel):
    ax.set_facecolor(SURFACE)
    ax.figure.set_facecolor(SURFACE)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    ax.tick_params(colors=MUTED, labelsize=9)
    ax.set_ylabel(ylabel, color=MUTED, fontsize=9)
    ax.set_title(subtitle, color=MUTED, fontsize=9, loc="left", pad=4)
    ax.figure.suptitle(title, color=INK, fontsize=12, fontweight="bold", x=0.065,
                       ha="left")


def fig_pt_shifted(con, P, out):
    """The PT 2025-06-01/02 displaced solar bell vs the zone's typical day."""
    df = con.execute(f"""
        SELECT date_time_utc ts, avg(day_ahead_generation_forecast_mw) fc
        FROM '{P}/entsoe.generation_forecasts_for_wind_and_solar.parquet'
        WHERE production_type='Solar' AND area_map_code='PT'
          AND date_time_utc >= '2025-05-31' AND date_time_utc < '2025-06-03'
        GROUP BY 1 ORDER BY 1""").df()
    clim = con.execute(f"""
        SELECT hour(date_time_utc) h,
               median(day_ahead_generation_forecast_mw) fc
        FROM '{P}/entsoe.generation_forecasts_for_wind_and_solar.parquet'
        WHERE production_type='Solar' AND area_map_code='PT'
          AND date_time_utc >= '2025-06-03' AND date_time_utc < '2025-07-01'
        GROUP BY 1 ORDER BY 1""").df()
    hmap = dict(zip(clim.h, clim.fc))
    df["clim"] = [hmap.get(t.hour, 0.0) for t in df.ts]
    fig, ax = plt.subplots(figsize=(9, 3.6), dpi=150)
    ax.plot(df.ts, df.clim, color=MUTED, lw=1.6, label="typical June day (median bell)")
    ax.plot(df.ts, df.fc, color=ORANGE, lw=2.0, label="published D-1 forecast")
    ax.axvspan(pd.Timestamp("2025-05-31 23:00"), pd.Timestamp("2025-06-02 04:00"),
               color=ORANGE, alpha=0.06, lw=0)
    ax.annotate("5.7 GW 'solar' at 01:00 UTC;\nzero across the real day",
                xy=(pd.Timestamp("2025-06-02 01:00"), 5720), fontsize=9,
                xytext=(pd.Timestamp("2025-06-02 07:00"), 5000), color=INK,
                arrowprops=dict(arrowstyle="-", color=MUTED, lw=0.8))
    ax.legend(frameon=False, fontsize=9, loc="upper left", labelcolor=INK)
    style(ax, "PT day-ahead solar forecast, 2025-05-31 … 2025-06-02 (UTC)",
          "the whole solar bell displaced into the night — caught by solar_night + solar_day_missing",
          "MW")
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(f"{out}/fig_pt_shifted_solar.png")
    plt.close(fig)


def fig_fr_missing(con, P, out):
    """FR loses its entire solar forecast for seven consecutive days."""
    df = con.execute(f"""
        SELECT CAST(date_time_utc AS DATE) d,
               max(day_ahead_generation_forecast_mw) mx
        FROM '{P}/entsoe.generation_forecasts_for_wind_and_solar.parquet'
        WHERE production_type='Solar' AND area_map_code='FR'
          AND date_time_utc >= '2026-02-15' AND date_time_utc < '2026-04-20'
        GROUP BY 1 ORDER BY 1""").df()
    df["d"] = pd.to_datetime(df.d)
    bad = df[df.mx <= 1.0]
    fig, ax = plt.subplots(figsize=(9, 3.4), dpi=150)
    ax.bar(df.d, df.mx, width=0.8, color=BLUE, linewidth=0)
    ax.bar(bad.d, [df.mx.max() * 0.02] * len(bad), width=0.8, color=ORANGE, linewidth=0)
    ax.annotate("2026-03-25 … 03-31: no solar forecast at all\n(the auction-input model cleared FR on zero solar)",
                xy=(pd.Timestamp("2026-03-28"), df.mx.max() * 0.03), fontsize=9,
                xytext=(pd.Timestamp("2026-02-16"), df.mx.max() * 0.93), color=INK,
                bbox=dict(facecolor=SURFACE, edgecolor="none", alpha=0.9, pad=2),
                arrowprops=dict(arrowstyle="-", color=MUTED, lw=0.8))
    style(ax, "FR day-ahead solar forecast — daily maximum, Feb–Apr 2026",
          "seven consecutive days with the forecast absent — caught by solar_day_missing", "MW")
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(f"{out}/fig_fr_missing_week.png")
    plt.close(fig)


def fig_errors_by_zone(findings_csv, out):
    df = pd.read_csv(findings_csv)
    err = df[df.severity == "error"].copy()
    err = err[~err.zone.str.contains("->")]
    counts = err.groupby("zone").size().sort_values(ascending=True).tail(20)
    fig, ax = plt.subplots(figsize=(7, 5.4), dpi=150)
    ax.barh(counts.index, counts.values, color=BLUE, height=0.62, linewidth=0)
    for i, v in enumerate(counts.values):
        ax.text(v + 0.6, i, str(v), va="center", fontsize=8.5, color=MUTED)
    ax.grid(axis="y", visible=False)
    style(ax, "Physics-audit :error findings per zone",
          "2023-01-01 … 2026-07-01, 39 zones, public extract — top 20 zones", "")
    ax.set_xlabel("findings (zone-days / units / weeks)", color=MUTED, fontsize=9)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(f"{out}/fig_error_findings_by_zone.png")
    plt.close(fig)


def fig_si_reservoir(con, P, out):
    df = con.execute(f"""
        SELECT year, week, avg(stored_energy_mwh) e
        FROM '{P}/entsoe.aggregated_hydro_storage_filling_rate.parquet'
        WHERE area_map_code='SI' AND area_type_code LIKE 'BZN%'
          AND year >= 2023
        GROUP BY 1,2 ORDER BY 1,2""").df()
    df["t"] = [pd.Timestamp.fromisocalendar(int(y), int(w), 1) for y, w in zip(df.year, df.week)]
    glitch = df[df.e <= 0]
    fig, ax = plt.subplots(figsize=(9, 3.2), dpi=150)
    ax.plot(df.t, df.e, color=BLUE, lw=1.8, label="weekly stored energy")
    ax.scatter(glitch.t, glitch.e, color=ORANGE, s=26, zorder=3, label="zero-glitch weeks (flagged)")
    ax.legend(frameon=False, fontsize=9, loc="lower left", labelcolor=INK)
    style(ax, "SI weekly reservoir storage, 2023–2026",
          "isolated drops to exactly 0 MWh and back — caught by reservoir_anomaly", "MWh")
    fig.tight_layout(rect=(0, 0, 1, 0.92))
    fig.savefig(f"{out}/fig_si_reservoir.png")
    plt.close(fig)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--parquet", default="data/public/euphemia-data-v1.1")
    ap.add_argument("--findings", required=True)
    ap.add_argument("--out", default="docs/experiments/physics-audit")
    a = ap.parse_args()
    con = duckdb.connect()
    fig_pt_shifted(con, a.parquet, a.out)
    fig_fr_missing(con, a.parquet, a.out)
    fig_errors_by_zone(a.findings, a.out)
    fig_si_reservoir(con, a.parquet, a.out)
    print("wrote 4 figures to", a.out)
