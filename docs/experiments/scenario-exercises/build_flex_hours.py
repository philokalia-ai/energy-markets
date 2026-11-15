#!/usr/bin/env python3
"""dc_flex10 curtailment hours for eu44_tech.jl (TECH_FLEX_HOURS).

Usage: build_flex_hours.py RESULTS_DB_WITH_eu44_dc574 OUT_CSV [STEP=16]

For each stride-STEP day d: threshold = 90th percentile of the eu44_dc574 GR
hourly prices on the arm's days in [d-56, d-1] (stride 8 ⇒ ~7 days); if fewer
than 3 such days, d's own 90th percentile. The DC is curtailed (0 MW) in d's
hours whose eu44_dc574 GR price >= threshold. The threshold is ex-ante; picking
the hours uses the paired DC arm's own day-d prices (foresight of its own
day-ahead price, i.e. a price-responsive DC), stated in the report.
"""
import sys, duckdb, pandas as pd
db, out = sys.argv[1], sys.argv[2]
step = int(sys.argv[3]) if len(sys.argv) > 3 else 16
con = duckdb.connect(db, read_only=True); con.execute("SET TimeZone='UTC'")
p = con.execute("""SELECT date_trunc('hour', date_time_utc) h, AVG(price_eur_mwh) p FROM simulations.energy_prices
  WHERE clearing_mode = 'eu44_dc574' AND code_version = 44 AND bidding_zone = 'GR' GROUP BY 1 ORDER BY 1""").df()
p["d"] = p.h.dt.date   # model day = UTC date
rows, stats = [], []
for d in pd.date_range("2024-07-01", "2026-06-30", freq=f"{step}D").date:
    today = p[p.d == d]
    if today.empty: continue
    past = p[(p.d < d) & (p.d >= d - pd.Timedelta(days=56))]
    thr = past.p.quantile(0.9) if past.d.nunique() >= 3 else today.p.quantile(0.9)
    sel = today[today.p >= thr]
    rows += [dict(ts=h.strftime("%Y%m%d-%H")) for h in sel.h]
    stats.append((d, len(today), len(sel), thr, past.d.nunique()))
pd.DataFrame(rows).to_csv(out, index=False)
s = pd.DataFrame(stats, columns=["d", "hours", "curtailed", "thr", "past_days"])
print(s.to_string(index=False))
print(f"curtailed {s.curtailed.sum()} of {s.hours.sum()} hours = {s.curtailed.sum()/s.hours.sum():.1%}; -> {out}")
