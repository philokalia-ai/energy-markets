#!/usr/bin/env python3
"""
Phase B — statistical attribution of the v10 competitive-counterfactual residual
(actual - counterfactual) to observable strategic-behaviour signals, GR only.

Runs the four PRE-SPECIFIED primary tests (A-D) plus clearly-labelled
exploratory variants. Every printed number is the source of a claim in
docs/phase-b-analysis.md. Figures written to docs/figures/phase_b/.

Reproducible:
    source .env
    uv run --with pandas,numpy,statsmodels,matplotlib,scipy,psycopg2-binary \
        python3 analysis/phase_b/04_regressions.py

Requires the three support tables built first (01/02/03 *.sql).

Statistical honesty: the A and B primary regressions are EXACTLY as specified.
No specification search on them. Exploratory analyses are labelled [EXPLORATORY].
Nulls are reported as nulls. Effect sizes carry 95% CIs.
"""
import os
import sys
import warnings
warnings.filterwarnings("ignore")  # silence pandas/psycopg2 SQLAlchemy notice
import numpy as np
import pandas as pd
import statsmodels.api as sm
import psycopg2
from scipy import stats
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
FIGDIR = os.path.abspath(os.path.join(HERE, "..", "..", "docs", "figures", "phase_b"))
os.makedirs(FIGDIR, exist_ok=True)

CONN = os.environ["ENERGY_CONN_STR"]
HAC_LAG_DAILY = 7
HAC_LAG_HOURLY = 24

# colour-blind-safe palette (Okabe-Ito subset)
C_BLUE = "#0072B2"
C_ORANGE = "#E69F00"
C_GREEN = "#009E73"
C_RED = "#D55E00"
C_GREY = "#999999"


def hr(title):
    print("\n" + "=" * 78)
    print(title)
    print("=" * 78)


def q(sql):
    with psycopg2.connect(CONN) as c:
        return pd.read_sql(sql, c)


def fit_hac(y, X, lag, label):
    """OLS with Newey-West (HAC) SEs. Returns fitted model; prints coef table."""
    X = sm.add_constant(X, has_constant="add")
    m = sm.OLS(y, X, missing="drop").fit(cov_type="HAC", cov_kwds={"maxlags": lag})
    print(f"\n[{label}]  n={int(m.nobs)}  R2={m.rsquared:.3f}  "
          f"adjR2={m.rsquared_adj:.3f}  HAC lag={lag}")
    ci = m.conf_int()
    tbl = pd.DataFrame({
        "coef": m.params, "se": m.bse, "t": m.tvalues,
        "p": m.pvalues, "ci_lo": ci[0], "ci_hi": ci[1],
    })
    with pd.option_context("display.float_format", lambda v: f"{v:11.4f}",
                           "display.width", 160):
        print(tbl)
    return m, tbl


def report_dark(m, tbl, key="dark_mw"):
    """Translate a per-MW coefficient into EUR/MWh per GW with 95% CI."""
    if key not in tbl.index:
        return
    b = tbl.loc[key, "coef"] * 1000.0
    lo = tbl.loc[key, "ci_lo"] * 1000.0
    hi = tbl.loc[key, "ci_hi"] * 1000.0
    p = tbl.loc[key, "p"]
    print(f"  >> {key}: {b:+.2f} EUR/MWh per GW dark  "
          f"(95% CI [{lo:+.2f}, {hi:+.2f}], p={p:.3f})")


# ===========================================================================
hr("LOAD DATA")
daily = q("SELECT * FROM simulations.phase_b_daily ORDER BY day")
daily["day"] = pd.to_datetime(daily["day"])
for col in daily.columns:
    if col not in ("day", "regulated_dummy"):
        daily[col] = pd.to_numeric(daily[col], errors="coerce")
daily["regulated_dummy"] = daily["regulated_dummy"].astype(int)
print(f"phase_b_daily: {len(daily)} rows, "
      f"{daily['residual'].notna().sum()} with residual")

hourly = q("SELECT * FROM simulations.rsi_hourly ORDER BY hour_utc")
hourly["hour_utc"] = pd.to_datetime(hourly["hour_utc"])
hourly["day"] = pd.to_datetime(hourly["day"])
for col in ("net_demand_mw", "net_import_mw", "total_available", "ppc_available",
            "rsi_ppc", "act_price", "sim_price", "residual"):
    hourly[col] = pd.to_numeric(hourly[col], errors="coerce")
print(f"rsi_hourly: {len(hourly)} rows, "
      f"{hourly['residual'].notna().sum()} with residual")

firm = q("SELECT * FROM simulations.phase_b_firm_dark ORDER BY firm, day")
firm["day"] = pd.to_datetime(firm["day"])
firm["dark_share"] = pd.to_numeric(firm["dark_share"], errors="coerce")

# year dummies (drop first) for FE
def year_fe(df):
    yrs = pd.get_dummies(df["year"].astype(int), prefix="yr", drop_first=True)
    return yrs.astype(float)

CONTROLS = ["peak_net_demand", "res_share", "ttf_change_5d",
            "reservoir_deviation", "outage_mw", "regulated_dummy"]

# ===========================================================================
hr("ANALYSIS A  (PRIMARY) — residual ~ dark_mw + controls + year FE")
# scale for numerical conditioning: keep MW as-is (coef reported per GW later)
dA = daily.dropna(subset=["residual", "dark_mw"] + CONTROLS).copy()
Xcols = ["dark_mw"] + CONTROLS
X = pd.concat([dA[Xcols].reset_index(drop=True),
               year_fe(dA).reset_index(drop=True)], axis=1)
y = dA["residual"].reset_index(drop=True)
mA, tA = fit_hac(y, X, HAC_LAG_DAILY, "A: with regulated window")
report_dark(mA, tA)

# without the regulated window (drop those days)
dA2 = dA[dA["regulated_dummy"] == 0].copy()
Xcols2 = ["dark_mw"] + [c for c in CONTROLS if c != "regulated_dummy"]
X2 = pd.concat([dA2[Xcols2].reset_index(drop=True),
                year_fe(dA2).reset_index(drop=True)], axis=1)
y2 = dA2["residual"].reset_index(drop=True)
mA2, tA2 = fit_hac(y2, X2, HAC_LAG_DAILY, "A: excluding regulated window (2022 H2)")
report_dark(mA2, tA2)

# robustness: dark_mw_all (strong not required)
dA3 = daily.dropna(subset=["residual", "dark_mw_all"] + CONTROLS).copy()
Xcols3 = ["dark_mw_all"] + CONTROLS
X3 = pd.concat([dA3[Xcols3].reset_index(drop=True),
                year_fe(dA3).reset_index(drop=True)], axis=1)
mA3, tA3 = fit_hac(dA3["residual"].reset_index(drop=True), X3, HAC_LAG_DAILY,
                   "A-robustness: dark_mw_all (strong not required)")
report_dark(mA3, tA3, key="dark_mw_all")

# --- Figure A: binned scatter, residual vs dark_mw deciles ---
dfig = dA.copy()
dfig["decile"] = pd.qcut(dfig["dark_mw"].rank(method="first"), 10,
                         labels=False, duplicates="drop")
g = dfig.groupby("decile").agg(
    dark_mid=("dark_mw", "mean"),
    resid_mean=("residual", "mean"),
    resid_sem=("residual", "sem"),
    n=("residual", "size")).reset_index()
g["ci"] = g["resid_sem"] * 1.96
print("\n[A] Binned scatter (dark_mw deciles):")
print(g.to_string(index=False))
fig, ax = plt.subplots(figsize=(7, 4.5))
ax.errorbar(g["dark_mid"] / 1000, g["resid_mean"], yerr=g["ci"], fmt="o-",
            color=C_BLUE, ecolor=C_GREY, capsize=3, lw=1.6, ms=6)
ax.axhline(0, color=C_GREY, lw=0.8, ls="--")
ax.set_xlabel("Unfiled dark capacity (GW, strong) — decile mean")
ax.set_ylabel("Mean daily residual  actual - counterfactual  (EUR/MWh)")
ax.set_title("A. GR daily residual vs unfiled dark capacity (deciles, 95% CI)")
fig.tight_layout()
fig.savefig(os.path.join(FIGDIR, "A_binned_scatter.png"), dpi=130)
plt.close(fig)

# ===========================================================================
hr("ANALYSIS B  (PRIMARY) — pivotality (RSI_PPC)")
# share of hours with RSI<1 by year
by_year = hourly.dropna(subset=["rsi_ppc"]).groupby(hourly["day"].dt.year)
shr = by_year["rsi_ppc"].apply(lambda s: (s < 1).mean() * 100)
print("\n[B] Share of hours with RSI_PPC < 1, by year (%):")
print(shr.round(1).to_string())

# residual grouped by RSI bins
hB = hourly.dropna(subset=["residual", "rsi_ppc"]).copy()
bins = [-np.inf, 0.8, 1.0, 1.2, np.inf]
labels = ["<0.8", "0.8-1.0", "1.0-1.2", ">1.2"]
hB["rsi_bin"] = pd.cut(hB["rsi_ppc"], bins=bins, labels=labels)
gb = hB.groupby("rsi_bin", observed=True).agg(
    resid_mean=("residual", "mean"),
    resid_sem=("residual", "sem"),
    n=("residual", "size")).reset_index()
gb["ci"] = gb["resid_sem"] * 1.96
print("\n[B] Hourly residual by RSI_PPC bin:")
print(gb.to_string(index=False))

fig, ax = plt.subplots(figsize=(7, 4.5))
ax.bar(gb["rsi_bin"].astype(str), gb["resid_mean"], yerr=gb["ci"],
       color=[C_RED, C_ORANGE, C_BLUE, C_GREEN], capsize=4)
ax.axhline(0, color=C_GREY, lw=0.8)
ax.set_xlabel("RSI_PPC bin  (< 1 = PPC pivotal)")
ax.set_ylabel("Mean hourly residual (EUR/MWh)")
ax.set_title("B. GR hourly residual by PPC pivotality (95% CI)")
fig.tight_layout()
fig.savefig(os.path.join(FIGDIR, "B_rsi_bars.png"), dpi=130)
plt.close(fig)

# hourly regression: same controls as A (daily signals merged) + rsi_lt1 dummy,
# hourly net_demand as the demand control instead of daily peak
hmerge = hourly.merge(
    daily[["day", "dark_mw", "res_share", "ttf_change_5d",
           "reservoir_deviation", "outage_mw", "regulated_dummy", "year"]],
    on="day", how="left")
hmerge["rsi_lt1"] = (hmerge["rsi_ppc"] < 1).astype(float)
hcols = ["dark_mw", "net_demand_mw", "res_share", "ttf_change_5d",
         "reservoir_deviation", "outage_mw", "regulated_dummy", "rsi_lt1"]
hB2 = hmerge.dropna(subset=["residual"] + hcols + ["year"]).copy()
Xh = pd.concat([hB2[hcols].reset_index(drop=True),
                year_fe(hB2).reset_index(drop=True)], axis=1)
mB, tB = fit_hac(hB2["residual"].reset_index(drop=True), Xh, HAC_LAG_HOURLY,
                 "B: hourly regression with RSI_PPC<1 dummy")
report_dark(mB, tB)
print(f"  >> rsi_lt1 dummy: {tB.loc['rsi_lt1','coef']:+.2f} EUR/MWh "
      f"(95% CI [{tB.loc['rsi_lt1','ci_lo']:+.2f}, "
      f"{tB.loc['rsi_lt1','ci_hi']:+.2f}], p={tB.loc['rsi_lt1','p']:.3f})")

# ===========================================================================
hr("ANALYSIS C  [EXPLORATORY] — signal-catalogue variants")

# daily min RSI_PPC
rsi_daily = (hourly.dropna(subset=["rsi_ppc"])
             .groupby("day")["rsi_ppc"].min().rename("rsi_ppc_min").reset_index())
dC = daily.merge(rsi_daily, on="day", how="left")

# C1: interaction dark_mw x (rsi_ppc_min < 1)
dC["rsi_min_lt1"] = (dC["rsi_ppc_min"] < 1).astype(float)
dC["dark_x_pivotal"] = dC["dark_mw"] * dC["rsi_min_lt1"]
c1cols = ["dark_mw", "dark_x_pivotal", "rsi_min_lt1"] + CONTROLS
dC1 = dC.dropna(subset=["residual"] + c1cols + ["year"]).copy()
Xc1 = pd.concat([dC1[c1cols].reset_index(drop=True),
                 year_fe(dC1).reset_index(drop=True)], axis=1)
mC1, tC1 = fit_hac(dC1["residual"].reset_index(drop=True), Xc1, HAC_LAG_DAILY,
                   "C1 [EXPLORATORY]: dark_mw x pivotal interaction")
report_dark(mC1, tC1)
print(f"  >> dark_x_pivotal: {tC1.loc['dark_x_pivotal','coef']*1000:+.2f} "
      f"EUR/MWh per GW extra when pivotal "
      f"(95% CI [{tC1.loc['dark_x_pivotal','ci_lo']*1000:+.2f}, "
      f"{tC1.loc['dark_x_pivotal','ci_hi']*1000:+.2f}], "
      f"p={tC1.loc['dark_x_pivotal','p']:.3f})")

# C2: dark_mw split by fuel group
darkfuel = q("""
    SELECT day,
      SUM(p_max) FILTER (WHERE fuel='Fossil Gas')                    AS dark_gas,
      SUM(p_max) FILTER (WHERE fuel='Fossil Brown coal/Lignite')     AS dark_lignite,
      SUM(p_max) FILTER (WHERE fuel LIKE 'Hydro%')                   AS dark_hydro
    FROM simulations.unfiled_dark_units
    WHERE zone='GR' AND strong GROUP BY day
""")
darkfuel["day"] = pd.to_datetime(darkfuel["day"])
for c in ("dark_gas", "dark_lignite", "dark_hydro"):
    darkfuel[c] = pd.to_numeric(darkfuel[c], errors="coerce")
dC2 = daily.merge(darkfuel, on="day", how="left")
for c in ("dark_gas", "dark_lignite", "dark_hydro"):
    dC2[c] = dC2[c].fillna(0.0)
c2cols = ["dark_gas", "dark_lignite", "dark_hydro"] + CONTROLS
dC2 = dC2.dropna(subset=["residual"] + c2cols + ["year"]).copy()
Xc2 = pd.concat([dC2[c2cols].reset_index(drop=True),
                 year_fe(dC2).reset_index(drop=True)], axis=1)
mC2, tC2 = fit_hac(dC2["residual"].reset_index(drop=True), Xc2, HAC_LAG_DAILY,
                   "C2 [EXPLORATORY]: dark_mw split by fuel")
for k in ("dark_gas", "dark_lignite", "dark_hydro"):
    print(f"  >> {k}: {tC2.loc[k,'coef']*1000:+.2f} EUR/MWh per GW "
          f"(95% CI [{tC2.loc[k,'ci_lo']*1000:+.2f}, "
          f"{tC2.loc[k,'ci_hi']*1000:+.2f}], p={tC2.loc[k,'p']:.3f})")

# C3: lead-lag cross-correlogram residual(t) vs dark_mw(t+k), k in -5..5
cc = daily.dropna(subset=["residual", "dark_mw"]).copy().sort_values("day")
r = cc["residual"].values
d = cc["dark_mw"].values
r = (r - r.mean()) / r.std()
d = (d - d.mean()) / d.std()
lags = range(-5, 6)
ccf = []
for k in lags:
    if k < 0:      # dark leads residual: corr(resid(t), dark(t+k)) k<0 -> dark earlier
        a, b = r[-k:], d[:len(d) + k]
    elif k > 0:
        a, b = r[:len(r) - k], d[k:]
    else:
        a, b = r, d
    ccf.append(np.corrcoef(a, b)[0, 1])
ccf = np.array(ccf)
print("\n[C3 EXPLORATORY] cross-correlogram corr(residual_t, dark_{t+k}):")
for k, v in zip(lags, ccf):
    tag = "  (dark leads)" if k < 0 else ("  (residual leads)" if k > 0 else "  (same day)")
    print(f"   k={k:+d}: {v:+.3f}{tag}")
n_cc = len(cc)
conf = 1.96 / np.sqrt(n_cc)
fig, ax = plt.subplots(figsize=(7, 4.5))
ax.stem(list(lags), ccf, basefmt=" ", linefmt=C_BLUE, markerfmt="o")
ax.axhline(conf, color=C_RED, ls="--", lw=0.8, label="95% band")
ax.axhline(-conf, color=C_RED, ls="--", lw=0.8)
ax.axhline(0, color=C_GREY, lw=0.8)
ax.set_xlabel("lag k (days):  k<0 dark leads residual,  k>0 residual leads dark")
ax.set_ylabel("cross-correlation")
ax.set_title("C. Lead-lag: daily residual vs unfiled dark capacity")
ax.legend()
fig.tight_layout()
fig.savefig(os.path.join(FIGDIR, "C_crosscorrelogram.png"), dpi=130)
plt.close(fig)

# ===========================================================================
hr("ANALYSIS D  (PRIMARY, first-pass) — cross-firm residualised dark-share corr")
# common signal set = same controls as A (no dark terms)
firms = sorted(firm["firm"].unique())
print(f"Firms (>=2 mapped units): {firms}")
sig = daily[["day"] + CONTROLS + ["year"]].copy()

resid_by_firm = {}
for f in firms:
    fd = firm[firm["firm"] == f].merge(sig, on="day", how="left")
    fd = fd.dropna(subset=["dark_share"] + CONTROLS + ["year"]).copy()
    Xf = pd.concat([fd[CONTROLS].reset_index(drop=True),
                    year_fe(fd).reset_index(drop=True)], axis=1)
    Xf = sm.add_constant(Xf, has_constant="add")
    mf = sm.OLS(fd["dark_share"].reset_index(drop=True), Xf).fit()
    res = pd.Series(mf.resid.values, index=fd["day"].values, name=f)
    resid_by_firm[f] = res
    print(f"  {f}: residualised dark_share, n={int(mf.nobs)}, "
          f"R2(signal model)={mf.rsquared:.3f}")

R = pd.DataFrame(resid_by_firm)
print(f"\n[D] Daily residualised-dark-share correlation matrix (n={len(R)} days):")
corr = R.corr()
print(corr.round(3).to_string())
print("\n[D] Pairwise Pearson r and p-values (daily):")
pairs = []
cols = list(R.columns)
for i in range(len(cols)):
    for j in range(i + 1, len(cols)):
        a = R[cols[i]]; b = R[cols[j]]
        m = a.notna() & b.notna()
        rr, pp = stats.pearsonr(a[m], b[m])
        pairs.append((cols[i], cols[j], rr, pp, int(m.sum())))
        print(f"   {cols[i]:16s} x {cols[j]:16s}: r={rr:+.3f}  p={pp:.4f}  n={int(m.sum())}")

# weekly-average robustness (mitigate autocorrelation)
Rw = R.copy()
Rw.index = pd.to_datetime(Rw.index)
Rw = Rw.resample("W").mean()
print(f"\n[D] Weekly-averaged residualised-dark-share correlation (n={len(Rw)} weeks):")
print(Rw.corr().round(3).to_string())
print("[D] Pairwise (weekly):")
for i in range(len(cols)):
    for j in range(i + 1, len(cols)):
        a = Rw[cols[i]]; b = Rw[cols[j]]
        m = a.notna() & b.notna()
        rr, pp = stats.pearsonr(a[m], b[m])
        print(f"   {cols[i]:16s} x {cols[j]:16s}: r={rr:+.3f}  p={pp:.4f}  n={int(m.sum())}")

# --- Figure D: heatmap ---
fig, ax = plt.subplots(figsize=(5.2, 4.6))
im = ax.imshow(corr.values, vmin=-1, vmax=1, cmap="RdBu_r")
ax.set_xticks(range(len(cols))); ax.set_xticklabels(cols, rotation=30, ha="right")
ax.set_yticks(range(len(cols))); ax.set_yticklabels(cols)
for i in range(len(cols)):
    for j in range(len(cols)):
        ax.text(j, i, f"{corr.values[i, j]:.2f}", ha="center", va="center",
                color="black", fontsize=10)
ax.set_title("D. Residualised dark-share correlation (daily)")
fig.colorbar(im, ax=ax, shrink=0.8, label="Pearson r")
fig.tight_layout()
fig.savefig(os.path.join(FIGDIR, "D_corr_heatmap.png"), dpi=130)
plt.close(fig)

hr("DONE")
print("Figures written to", FIGDIR)
