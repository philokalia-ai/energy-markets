#!/usr/bin/env python3
"""Regenerate the thesis + presentation figures from the cv37 record.

Inputs (DATA_DIR, default ./chart_data):
  sim37.csv       zone,ts,price — simulations.energy_prices cv37 multi_zone_eu
  act.csv         zone,ts,price — entsoe.energy_prices Day-ahead EUR, hourly AVG
  gbm_metrics.csv per-zone metric battery from docs/experiments/forecast-eval-2026-08

Outputs: PDFs into thesis/figures/, SVGs into thesis/presentation/figures/.
Also prints a stats summary (JSON) used for the numbers quoted in the text.

The JAO A/B table (48 paired Wednesdays, cv34-off vs cv35 = +JAO+tx+NP) is
transcribed from docs/experiments/jao-maxbex-atc.md — the ratified experiment
record — not recomputed here.
"""
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import numpy as np
import pandas as pd

DATA = os.environ.get("DATA_DIR", os.path.join(os.path.dirname(__file__), "chart_data"))
HERE = os.path.dirname(os.path.abspath(__file__))
PDF = HERE
SVG = os.path.join(HERE, "..", "presentation", "figures")

BLUE = "#1f77b4"    # physics / model
ORANGE = "#ff7f0e"  # settled
PINK = "#e377c2"    # physics + ex-ante GBM
GOLD = "#d4a017"    # pure-stats GBM
GREY = "#9a9a9a"

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 11,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.alpha": 0.25, "grid.linewidth": 0.5,
    "figure.dpi": 110,
})

def save(fig, name):
    fig.savefig(os.path.join(PDF, name + ".pdf"), bbox_inches="tight")
    fig.savefig(os.path.join(SVG, name + ".svg"), bbox_inches="tight")
    plt.close(fig)
    print("wrote", name)

# ── load ─────────────────────────────────────────────────────────────────────
sim = pd.read_csv(os.path.join(DATA, "sim37.csv"))
act = pd.read_csv(os.path.join(DATA, "act.csv"))
sim["t"] = pd.to_datetime(sim.t, format="mixed", utc=True).dt.tz_localize(None)
act["t"] = pd.to_datetime(act.t, format="mixed", utc=True).dt.tz_localize(None)
df = sim.merge(act, on=["z", "t"], suffixes=("_sim", "_act")).dropna()
df["err"] = df.p_sim - df.p_act
df["day"] = df.t.dt.floor("D")
gbm = pd.read_csv(os.path.join(DATA, "gbm_metrics.csv"))

stats = {}
stats["cells"] = int(len(df))
stats["days"] = int(df.day.nunique())
stats["window"] = [str(df.day.min().date()), str(df.day.max().date())]
stats["mae"] = round(float(df.err.abs().mean()), 2)
stats["bias"] = round(float(df.err.mean()), 2)
zc = df.groupby("z").apply(lambda g: g.p_sim.corr(g.p_act), include_groups=False)
zm = df.groupby("z").err.apply(lambda e: e.abs().mean())
stats["corr_mean"] = round(float(zc.mean()), 3)
w = gbm.set_index("zone").energy.reindex(zc.index)
stats["corr_energy_weighted"] = round(float((zc * w).sum() / w.sum()), 3)
stats["energy_share_corr_ge_07"] = round(float(w[zc >= 0.7].sum() / w.sum()), 3)
stats["zones_corr_ge_07"] = int((zc >= 0.7).sum())

# ── 1. monthly footprint MAE + corr over the record ──────────────────────────
df["month"] = df.t.dt.to_period("M").dt.to_timestamp()
mo = df.groupby("month").apply(
    lambda g: pd.Series({
        "mae": g.err.abs().mean(),
        "corr": g.groupby("z").apply(lambda x: x.p_sim.corr(x.p_act), include_groups=False).mean(),
    }), include_groups=False)
fig, ax = plt.subplots(figsize=(9.2, 3.4))
ax.bar(mo.index, mo.mae, width=24, color=BLUE, alpha=0.75, label="MAE (αριστερός άξονας)")
ax.set_ylabel("MAE €/MWh")
ax2 = ax.twinx()
ax2.plot(mo.index, mo["corr"], color=ORANGE, lw=2.2, marker="o", ms=4,
         label="μέση συσχέτιση (δεξιός)")
ax2.set_ylabel("συσχέτιση r", color=ORANGE)
ax2.set_ylim(0, 1)
ax2.grid(False); ax2.spines["right"].set_visible(True)
ax.xaxis.set_major_formatter(mdates.DateFormatter("%m/%y"))
h1, l1 = ax.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels()
ax.legend(h1 + h2, l1 + l2, loc="upper right", frameon=False, fontsize=10)
save(fig, "record_monthly")
stats["monthly_last6"] = {str(k.date()): [round(v.mae, 1), round(v["corr"], 2)]
                          for k, v in mo.tail(6).iterrows()}

# ── 2. per-zone corr on the record ───────────────────────────────────────────
order = zc.sort_values()
fig, ax = plt.subplots(figsize=(7.4, 8.6))
colors = [ORANGE if z == "GR" else BLUE for z in order.index]
ax.barh(range(len(order)), order.values, color=colors, alpha=0.85)
ax.set_yticks(range(len(order)), order.index, fontsize=8.5)
ax.axvline(0.7, color=GREY, ls="--", lw=1)
ax.text(0.705, 0.5, "r = 0,7", color=GREY, fontsize=9, rotation=90, va="bottom")
for i, (z, v) in enumerate(order.items()):
    ax.text(v + 0.008, i, f"{zm[z]:.0f}", va="center", fontsize=7, color=GREY)
ax.set_xlabel("συσχέτιση r ανά ζώνη (αριθμός: MAE €/MWh)")
ax.set_xlim(0, 1.0)
save(fig, "record_zones")

# ── 3. JAO A/B dumbbell (from docs/experiments/jao-maxbex-atc.md, Result 2) ──
JAO = {  # zone: (MAE cv34-off, MAE +JAO+tx+NP)
 "PT": (24.1, 25.2), "DK1": (17.7, 20.2), "ES": (23.0, 23.9), "BE": (18.4, 20.4),
 "DE_LU": (17.5, 19.9), "FR": (21.8, 22.4), "FI": (22.4, 24.4), "GR": (22.4, 21.8),
 "DK2": (26.1, 26.6), "BG": (25.6, 24.5), "RS": (30.9, 29.7), "SE2": (25.3, 25.0),
 "IT-Sardinia": (22.8, 22.9), "NO2": (13.5, 13.6), "NL": (21.9, 20.6),
 "RO": (26.7, 24.7), "PL": (24.3, 23.2), "IT-CSOUTH": (18.6, 18.6),
 "SE1": (26.1, 24.1), "NO1": (24.1, 21.9), "SE4": (28.1, 27.7), "NO5": (27.8, 25.1),
 "IT-SOUTH": (18.0, 18.0), "IT-Sicily": (18.8, 18.7), "IT-Calabria": (17.6, 17.2),
 "CZ": (23.4, 18.5), "IT-NORTH": (23.7, 24.0), "IT-CNORTH": (23.7, 23.9),
 "EE": (35.2, 35.2), "NO4": (28.4, 21.3), "SE3": (27.3, 20.9), "CH": (27.4, 21.6),
 "LT": (38.7, 35.8), "AT": (34.7, 22.0), "LV": (41.1, 36.5), "HU": (38.1, 26.5),
 "SK": (34.5, 21.9), "SI": (40.8, 23.7), "NO3": (43.2, 20.8),
}
jd = pd.DataFrame(JAO, index=["off", "np"]).T
jd["d"] = jd.np - jd.off
jd = jd.sort_values("d")
fig, ax = plt.subplots(figsize=(7.4, 8.6))
for i, (z, r) in enumerate(jd.iterrows()):
    ax.plot([r.off, r.np], [i, i], color=GREY, lw=1.2, zorder=1)
ax.scatter(jd.off, range(len(jd)), s=26, color=GREY, label="χωρίς JAO (cv34)", zorder=2)
ax.scatter(jd.np, range(len(jd)), s=30, color=BLUE, label="δίκτυο JAO (cv35)", zorder=3)
ax.set_yticks(range(len(jd)), jd.index, fontsize=8.5)
ax.set_xlabel("MAE €/MWh — 48 κοινές Τετάρτες 7/2025–6/2026")
ax.legend(loc="lower right", frameon=False)
save(fig, "jao_ab")

# ── 4. GBM per-zone MAE ──────────────────────────────────────────────────────
g = gbm.sort_values("MAE_phys", ascending=True).reset_index(drop=True)
fig, ax = plt.subplots(figsize=(7.4, 8.6))
y = np.arange(len(g))
ax.scatter(g.MAE_phys, y, s=26, color=BLUE, label="φυσική (αντιπαράδειγμα)")
ax.scatter(g.MAE_full, y, s=26, color=PINK, marker="D", label="φυσική + ex-ante GBM")
ax.scatter(g.MAE_stats, y, s=26, color=GOLD, marker="s", label="καθαρή στατιστική GBM")
ax.set_yticks(y, g.zone, fontsize=8.5)
ax.set_xlabel("MAE €/MWh — 729 ημέρες, εκτός δείγματος")
ax.legend(loc="lower right", frameon=False)
save(fig, "gbm_zones")

# ── 5. GBM battery (footprint, energy-weighted) ─────────────────────────────
batt = [  # label, phys, full, stats, higher_is_better
    ("MAE €/MWh", 23.1, 14.9, 14.5, False),
    ("rMAE έναντι\nαφελούς εβδομάδας", 0.81, 0.52, 0.49, False),
    ("συσχέτιση", 0.79, 0.88, 0.89, True),
    ("κατεύθυνση\nώρα-προς-ώρα", 0.61, 0.75, 0.80, True),
    ("ανάκληση αιχμών\n(≥p90)", 0.39, 0.68, 0.69, True),
    ("ακρίβεια αιχμών", 0.77, 0.73, 0.74, True),
    ("ανάκληση\nκατάρρευσης (≤5€)", 0.23, 0.49, 0.49, True),
]
fig, ax = plt.subplots(figsize=(9.2, 3.6))
x = np.arange(len(batt)); wdt = 0.26
for k, (col, lbl) in enumerate([(BLUE, "φυσική"), (PINK, "φυσική + ex-ante GBM"), (GOLD, "καθαρή στατιστική")]):
    vals = [b[1 + k] / (b[1] if not b[4] else 1) if not b[4] else b[1 + k] for b in batt]
    # normalize MAE-like metrics to the physics value so all bars share a scale
    ax.bar(x + (k - 1) * wdt, vals, wdt, color=col, label=lbl, alpha=0.9)
for i, b in enumerate(batt):
    ax.text(i, 1.04 if not b[4] else max(b[1:4]) + 0.04,
            "↓ καλύτερο" if not b[4] else "↑ καλύτερο", ha="center", fontsize=7.5, color=GREY)
ax.set_xticks(x, [b[0] for b in batt], fontsize=9)
ax.set_ylabel("τιμή μετρικής\n(MAE/rMAE: λόγος προς τη φυσική)")
ax.legend(frameon=False, fontsize=9, loc="upper right")
save(fig, "gbm_battery")

# ── GR figures from the cv37 record ─────────────────────────────────────────
gr = df[df.z == "GR"].sort_values("t")
stats["gr_mae"] = round(float(gr.err.abs().mean()), 1)
stats["gr_bias"] = round(float(gr.err.mean()), 1)
stats["gr_corr"] = round(float(gr.p_sim.corr(gr.p_act)), 3)
dcorr = gr.groupby("day").apply(lambda g: g.p_sim.corr(g.p_act) if g.p_sim.std() > 0 else np.nan,
                                include_groups=False).dropna()
stats["gr_daycorr_median"] = round(float(dcorr.median()), 3)
stats["gr_days_gt085"] = round(float((dcorr > 0.85).mean()), 3)
stats["gr_days_gt070"] = round(float((dcorr > 0.70).mean()), 3)

# 6. daily means over the whole record
gd = gr.groupby("day")[["p_sim", "p_act"]].mean()
fig, ax = plt.subplots(figsize=(9.2, 3.2))
ax.plot(gd.index, gd.p_act, color=ORANGE, lw=0.9, label="πραγματική (EnEx)")
ax.plot(gd.index, gd.p_sim, color=BLUE, lw=0.9, alpha=0.9, label="μοντέλο (cv37)")
ax.set_ylabel("€/MWh — ημερήσιος μέσος")
ax.xaxis.set_major_formatter(mdates.DateFormatter("%m/%y"))
ax.legend(frameon=False, loc="upper right", fontsize=10)
save(fig, "daily")

# 7. one recent week, hourly
wk = gr[(gr.t >= "2026-06-15") & (gr.t < "2026-06-22")]
fig, ax = plt.subplots(figsize=(9.2, 3.2))
ax.plot(wk.t, wk.p_act, color=ORANGE, lw=1.4, label="πραγματική")
ax.plot(wk.t, wk.p_sim, color=BLUE, lw=1.4, alpha=0.9, label="μοντέλο")
ax.set_ylabel("€/MWh")
ax.xaxis.set_major_formatter(mdates.DateFormatter("%a %d/%m"))
ax.legend(frameon=False, loc="upper right", fontsize=10)
save(fig, "week")

# 8. intraday profile (CET hours ≈ UTC+1/2; keep UTC, label it)
prof = gr.assign(h=gr.t.dt.hour).groupby("h")[["p_sim", "p_act"]].mean()
fig, ax = plt.subplots(figsize=(9.2, 3.0))
ax.plot(prof.index, prof.p_act, color=ORANGE, lw=2.2, marker="o", ms=4, label="πραγματική")
ax.plot(prof.index, prof.p_sim, color=BLUE, lw=2.2, marker="o", ms=4, label="μοντέλο")
ax.set_xlabel("ώρα UTC"); ax.set_ylabel("μέση τιμή €/MWh")
ax.legend(frameon=False, fontsize=10)
save(fig, "profile")

# 9. scatter
fig, ax = plt.subplots(figsize=(4.6, 4.4))
ax.hexbin(gr.p_act, gr.p_sim, gridsize=55, cmap="Blues", mincnt=1,
          extent=(-100, 400, -100, 400))
ax.plot([-100, 400], [-100, 400], color=ORANGE, lw=1.2, ls="--")
ax.set_xlabel("πραγματική €/MWh"); ax.set_ylabel("μοντέλο €/MWh")
ax.set_xlim(-100, 400); ax.set_ylim(-100, 400)
save(fig, "scatter")

# 10. day-corr histogram
fig, ax = plt.subplots(figsize=(4.6, 3.2))
ax.hist(dcorr, bins=np.arange(-0.2, 1.01, 0.05), color=BLUE, alpha=0.85)
ax.axvline(dcorr.median(), color=ORANGE, lw=1.6, ls="--",
           label=f"διάμεσος {dcorr.median():.2f}")
ax.set_xlabel("ενδοημερήσια συσχέτιση ανά ημέρα"); ax.set_ylabel("ημέρες")
ax.legend(frameon=False, fontsize=9, loc="upper left")
save(fig, "daycorr")

print(json.dumps(stats, indent=1, ensure_ascii=False))
