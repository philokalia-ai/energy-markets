#!/usr/bin/env python3
"""cv44 BYOP-by-technology ledger (eu44_tech.jl arms) paired with the cv44
eu44_base / eu44_dc574 (and optionally eu44_byop_s*) arms of eu44_scenarios.jl.

Usage: scn_tech.py PROFILES_CSV EXTRACT_DB RESULTS_DB [RESULTS_DB ...]
  (every RESULTS_DB is ATTACHed read-only; arms are unioned by clearing_mode)

Per arm, on the days complete (39 zones, >= 23 h) in EVERY reported arm:
  - GR / EU load-weighted price Δ vs eu44_base (weights = ENTSO-E D-1 load
    forecast, the model's unmodified demand), and Δ in the GR evening peak
    (17-21 Athens local) vs midday (11-15 local)
  - extra cost to existing consumers Σ w·Δp (sample €; ×STEP for the window)
  - the plant: offered MWh on the sample, dispatched MWh inferred from the GR
    clearing price vs its bid (cleared when p > bid + 0.01, half when within
    ±0.01 — prices only are saved), curtailment = offered − dispatched,
    capture price = Σ p·dispatched / Σ dispatched.
    Energy-limited families (battery discharge, reservoir): the master's
    allocation is not saved, so dispatch is approximated as the daily budget
    placed in the day's highest-price GR hours of the arm (574 MW per hour).
    Battery charging (fixed load) is costed at the arm's GR price.
  - e* (energy share where GR LW Δ crosses 0), linear in e through
    (0, dc574), (100, e100), (200, e200) when bracketed.
"""
import sys, duckdb, pandas as pd, numpy as np

prof_csv, ext_db, res_dbs = sys.argv[1], sys.argv[2], sys.argv[3:]
STEP = 16
CF_PV, CF_WIND = 0.2075, 0.3607   # build_tech_profiles.py, mean CF 2024-07..2026-06 (proxy installed)
SRMC_FIRM, BID_RES, BID_FAM = 10.0, -0.01, 1.0
#  label: (e share of DC energy, nameplate MW, kind, params)
ARMS = {
    "eu44_dc574":           (0.0, 0, "none", {}),
    "eu44t_firm_e100":      (1.0, 574 / 0.9, "flat", {"mw": 574.0, "bid": SRMC_FIRM}),
    "eu44t_pv_e100":        (1.0, 574 / CF_PV, "prof", {"pv": 1.0}),
    "eu44t_pv_e200":        (2.0, 2 * 574 / CF_PV, "prof", {"pv": 2.0}),
    "eu44t_wind_e100":      (1.0, 574 / CF_WIND, "prof", {"wind": 1.0}),
    "eu44t_wind_e200":      (2.0, 2 * 574 / CF_WIND, "prof", {"wind": 2.0}),
    "eu44t_pvwind_e100":    (2.0, 574 / CF_PV + 574 / CF_WIND, "prof", {"pv": 1.0, "wind": 1.0}),
    "eu44t_pv_e100_batt4h": (1.0, 574 / CF_PV, "batt", {"pv": 1.0, "e_day": 2296.0}),
    "eu44t_hydro_res":      (0.30, 574, "fam", {"e_day": 0.30 * 574 * 24}),
    "eu44t_dc_flex10":      (0.0, 0, "flex", {}),
    "eu44_byop_s100":       (None, 574 / 0.9, "ccgt", {"mw": 574.0}),
    "eu44_byop_s150":       (None, 1.5 * 574 / 0.9, "ccgt", {"mw": 861.0}),
    "eu44_byop_s200":       (None, 2 * 574 / 0.9, "ccgt", {"mw": 1148.0}),
}

con = duckdb.connect()
con.execute("SET TimeZone='UTC'")
con.execute(f"ATTACH '{ext_db}' AS ext (READ_ONLY)")
parts = []
for i, db in enumerate(res_dbs):
    con.execute(f"ATTACH '{db}' AS r{i} (READ_ONLY)")
    parts.append(f"""SELECT clearing_mode arm, bidding_zone zone, date_trunc('hour', date_time_utc) h, AVG(price_eur_mwh) p
      FROM r{i}.simulations.energy_prices WHERE code_version = 44 AND clearing_mode LIKE 'eu44%' GROUP BY 1, 2, 3""")
con.execute("CREATE TEMP TABLE P0 AS " + " UNION ALL ".join(parts))
# an arm present in two DBs (the base match check) — keep one copy, report the max |diff|
dup = con.execute("""SELECT arm, COUNT(*) n, MAX(d) FROM (SELECT arm, zone, h, MAX(p) - MIN(p) d, COUNT(*) c FROM P0 GROUP BY 1, 2, 3 HAVING c > 1) GROUP BY 1""").fetchall()
for arm, n, d in dup:
    print(f"match check: {arm} present in >1 results DB on {n} zone-hours, max |Δp| = {d:.3g} €/MWh")
con.execute("CREATE TEMP TABLE P AS SELECT arm, zone, h, MIN(p) p FROM P0 GROUP BY 1, 2, 3")
con.execute("""CREATE TEMP TABLE LW AS SELECT area_map_code zone, date_trunc('hour', date_time_utc) h, AVG(total_load_mw) w
  FROM ext.entsoe.day_ahead_total_load_forecast
  WHERE date_time_utc >= (SELECT min(h) FROM P) AND date_time_utc <= (SELECT max(h) FROM P) GROUP BY 1, 2""")
# the model's day = the UTC date (stored hours 00-23 UTC)
con.execute("""CREATE TEMP TABLE CD AS SELECT arm, CAST(h AS DATE) d FROM P GROUP BY 1, 2
  HAVING COUNT(DISTINCT zone) >= 39 AND COUNT(DISTINCT h) >= 23""")
present = [a for (a,) in con.execute("SELECT DISTINCT arm FROM CD ORDER BY 1").fetchall()]
print("complete days per arm:", dict(con.execute("SELECT arm, COUNT(*) FROM CD GROUP BY 1 ORDER BY 1").fetchall()))
import os
MIN_DAYS = int(os.environ.get("MIN_DAYS", "44"))   # drop arms still running (fewer complete stride-16 days)
ncd = {a: n for a, n in con.execute(f"""SELECT arm, COUNT(*) FROM CD WHERE d IN ({','.join("DATE '" + str(d.date()) + "'" for d in pd.date_range('2024-07-01', '2026-06-30', freq='16D'))}) GROUP BY 1""").fetchall()}
arms = [a for a in ARMS if a in present and ncd.get(a, 0) >= MIN_DAYS]
print("arms skipped (< MIN_DAYS complete stride-16 days):", {a: ncd.get(a, 0) for a in ARMS if a in present and a not in arms})
assert "eu44_base" in present, "no eu44_base"
days = set(d for (d,) in con.execute("SELECT d FROM CD WHERE arm = 'eu44_base'").fetchall())
stride16 = set(pd.date_range("2024-07-01", "2026-06-30", freq="16D").date)
days &= stride16
for a in arms:
    days &= set(d for (d,) in con.execute(f"SELECT d FROM CD WHERE arm = '{a}'").fetchall())
days = sorted(days)
print(f"common complete stride-16 days across base + {len(arms)} arms: {len(days)}")
con.execute("CREATE TEMP TABLE DAYS (d DATE)")
con.executemany("INSERT INTO DAYS VALUES (?)", [(d,) for d in days])

j = con.execute("""SELECT x.arm, b.zone, b.h, b.p pb, x.p ps, LW.w,
    CAST(b.h AS DATE) d, hour(timezone('Europe/Athens', b.h::TIMESTAMPTZ)) lh
  FROM P b JOIN P x ON x.zone = b.zone AND x.h = b.h AND x.arm <> 'eu44_base'
  JOIN LW ON LW.zone = b.zone AND LW.h = b.h
  WHERE b.arm = 'eu44_base' AND CAST(b.h AS DATE) IN (SELECT d FROM DAYS)""").df()
prof = pd.read_csv(prof_csv)
prof["h"] = pd.to_datetime(prof.ts, format="%Y%m%d-%H")
prof = prof.set_index("h")
fuel = con.execute("""SELECT d,
    (SELECT close FROM ext.yfinance.ttf_f t WHERE t.date < d ORDER BY t.date DESC LIMIT 1) ttf,
    (SELECT close FROM ext.yfinance.eua_co2 e WHERE e.date < d ORDER BY e.date DESC LIMIT 1) eua FROM DAYS""").df()
fuel["srmc"] = fuel.ttf / 0.59 + 0.202 / 0.59 * fuel.eua + 2.0
fuel = fuel.set_index("d").srmc


def disp(p, bid):
    return np.where(p > bid + 0.01, 1.0, np.where(p >= bid - 0.01, 0.5, 0.0))


rows = []
for a in arms:
    e, npl, kind, par = ARMS[a]
    g = j[j.arm == a]
    gr = g[g.zone == "GR"].copy()
    gr["h"] = pd.to_datetime(gr.h)
    gr = gr.sort_values("h")
    w_gr = (gr.w * (gr.ps - gr.pb)).sum() / gr.w.sum()
    eu = (g.w * (g.ps - g.pb)).sum() / g.w.sum()
    pk = gr[gr.lh.between(17, 21)]; md = gr[gr.lh.between(11, 15)]
    r = dict(arm=a, e=e, nameplate_mw=npl, days=gr.d.nunique(), gr_h=len(gr), gr_lw=w_gr, eu_lw=eu,
             gr_peak=(pk.w * (pk.ps - pk.pb)).sum() / pk.w.sum(), gr_mid=(md.w * (md.ps - md.pb)).sum() / md.w.sum(),
             cost_eu=(g.w * (g.ps - g.pb)).sum() / 1e6, cost_gr=(gr.w * (gr.ps - gr.pb)).sum() / 1e6)
    r["cost_out"] = r["cost_eu"] - r["cost_gr"]
    offered = np.zeros(len(gr)); dsp = np.zeros(len(gr)); load_extra = np.zeros(len(gr))
    if kind == "prof":
        pmw = sum(f * 574.0 * prof.reindex(gr.h)[k + "_norm"].fillna(0).to_numpy() for k, f in par.items())
        offered = np.where(pmw > 0.1, pmw, 0); dsp = offered * disp(gr.ps.to_numpy(), BID_RES)
    elif kind == "flat":
        offered = np.full(len(gr), par["mw"]); dsp = offered * disp(gr.ps.to_numpy(), par["bid"])
    elif kind == "ccgt":
        sr = gr.d.map(fuel).to_numpy()
        offered = np.full(len(gr), par["mw"]); dsp = offered * disp(gr.ps.to_numpy(), sr)
    elif kind in ("batt", "fam"):
        if kind == "batt":
            pmw = 574.0 * prof.reindex(gr.h)["pv_norm"].fillna(0).to_numpy()
            pv_off = np.where(pmw > 0.1, pmw, 0); pv_d = pv_off * disp(gr.ps.to_numpy(), BID_RES)
            load_extra = prof.reindex(gr.h)["charge_mw"].fillna(0).to_numpy()
        fam = np.zeros(len(gr))
        for d, idx in gr.groupby("d").indices.items():
            left = par["e_day"]
            for i in idx[np.argsort(-gr.ps.to_numpy()[idx])]:
                if gr.ps.to_numpy()[i] <= BID_FAM or left <= 0: break
                q = min(574.0, left); fam[i] = q; left -= q
        r["fam_mwh"] = fam.sum(); r["fam_capture"] = (fam * gr.ps).sum() / max(fam.sum(), 1e-9)
        if kind == "batt":
            r["charge_mwh"] = load_extra.sum(); r["charge_price"] = (load_extra * gr.ps).sum() / max(load_extra.sum(), 1e-9)
            r["batt_margin_eur_m"] = ((fam - load_extra) * gr.ps).sum() / 1e6
            offered, dsp = pv_off + fam, pv_d + fam
        else:
            offered, dsp = fam, fam
    r["offered_twh"] = offered.sum() / 1e6; r["disp_twh"] = dsp.sum() / 1e6
    r["curtail_twh"] = (offered.sum() - dsp.sum()) / 1e6
    # GR at the fleet-RES floor (p <= 1.01): RES is marginal, so existing RES (bid 1.0) is being curtailed;
    # the new plant (bid −0.01) is dispatched first. Its output in those hours = curtailment exposure.
    r["res_floor_h"] = int((gr.ps.to_numpy() <= 1.01).sum())
    r["at_floor_twh"] = (offered * (gr.ps.to_numpy() <= 1.01)).sum() / 1e6
    r["e_real"] = dsp.sum() / (574.0 * len(gr))   # dispatched energy / DC energy on the sample
    r["capture"] = (dsp * gr.ps.to_numpy()).sum() / dsp.sum() if dsp.sum() > 0 else np.nan
    r["gr_base_lw"] = (gr.w * gr.pb).sum() / gr.w.sum()
    rows.append(r)

t = pd.DataFrame(rows)
pd.set_option("display.width", 250); pd.set_option("display.max_columns", 40)
print(f"\n== {len(days)} common complete days; € sums are sample-only (×{STEP} ≈ full 2-yr window)")
print(t.round(3).to_string(index=False))


def estar(names):
    pts = [(0.0, t.loc[t.arm == "eu44_dc574", "gr_lw"].item())] if "eu44_dc574" in t.arm.values else []
    pts += [(ARMS[n][0], t.loc[t.arm == n, "gr_lw"].item()) for n in names if n in t.arm.values]
    pts.sort()
    for (e0, g0), (e1, g1) in zip(pts, pts[1:]):
        if g0 > 0 >= g1:
            return e0 + (e1 - e0) * g0 / (g0 - g1), pts
    return None, pts


for tech, names in [("PV", ["eu44t_pv_e100", "eu44t_pv_e200"]), ("wind", ["eu44t_wind_e100", "eu44t_wind_e200"])]:
    es, pts = estar(names)
    print(f"e* {tech}: {'not bracketed' if es is None else f'{es*100:.0f} %'}  points (e, GR LWΔ) = "
          + ", ".join(f"({p[0]*100:.0f}%, {p[1]:+.2f})" for p in pts))
t.to_csv("scn_tech_summary.csv", index=False)
print("wrote scn_tech_summary.csv (cwd)")

# ---- mechanism tables -------------------------------------------------------
jj = j[j.arm.isin(arms)].copy()
jj["dp"] = jj.ps - jj.pb
hourly = jj[jj.zone == "GR"].pivot_table(index="lh", columns="arm", values="dp", aggfunc="mean")
print("\n== GR mean Δp vs base by Athens local hour (€/MWh)")
print(hourly.round(1).to_string())
spill = jj.pivot_table(index="zone", columns="arm", values="dp", aggfunc="mean")
spill = spill.loc[spill.abs().max(axis=1).sort_values(ascending=False).index[:8]]
print("\n== mean Δp vs base, top-8 moving zones (€/MWh)")
print(spill.round(2).to_string())
if "eu44_dc574" in arms:
    dc = jj[(jj.zone == "GR") & (jj.arm == "eu44_dc574")].copy()
    dc["h"] = pd.to_datetime(dc.h)
    pr = prof.reindex(dc.h)
    print("\n== correlation of the plant profile with the paired DC-arm GR price (hourly, sample days)")
    for k in ["pv_norm", "wind_norm"]:
        print(f"  {k}: r = {np.corrcoef(pr[k].fillna(0), dc.ps)[0, 1]:+.3f}; "
              f"profile-weighted DC-arm price {np.average(dc.ps, weights=pr[k].fillna(0) + 1e-12):.1f} vs time-average {dc.ps.mean():.1f}")
hourly.to_csv("scn_tech_hourly.csv"); spill.to_csv("scn_tech_spill.csv")
