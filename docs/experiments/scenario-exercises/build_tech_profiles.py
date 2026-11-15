"""GR PV / wind hourly capacity-factor profiles + battery charge schedule for the
p3 technology arms. CF_h = GR actual (entsoe.aggregated_generation_per_type,
hourly mean) / installed proxy (trailing 365-day max of hourly actual).
cf_norm = CF_h / mean CF over 2024-07-01..2026-06-30 (all hours), so an arm of
energy share e offers e*574*cf_norm MW (annual energy e*5.03 TWh by construction).
Battery: charge 2296/0.88 MWh from the grid per UTC day, <= 574 MW/h, filled into
the day's highest-PV hours first. Extract opened read-only."""
import sys, duckdb, pandas as pd, numpy as np
EXT, OUT = sys.argv[1], sys.argv[2]
con = duckdb.connect(EXT, read_only=True); con.execute("SET TimeZone='UTC'")
df = con.execute("""select date_trunc('hour',date_time_utc) h, production_type pt, avg(actual_generation_output_mw) mw
 from entsoe.aggregated_generation_per_type where area_map_code='GR' and production_type in ('Solar','Wind Onshore')
 group by 1,2""").df()
w = df.pivot(index='h', columns='pt', values='mw').sort_index()
w = w.reindex(pd.date_range(w.index.min(), w.index.max(), freq='h')).interpolate(limit=3)
cf = pd.DataFrame({k: (w[c] / w[c].rolling('365D', min_periods=720).max()).clip(0, 1)
                   for k, c in [('pv', 'Solar'), ('wind', 'Wind Onshore')]})
win = cf.loc['2024-07-01':'2026-06-30 23:00']
m = win.mean()
print('mean CF 2024-07..2026-06 (proxy installed = trailing-365d max):', m.round(4).to_dict())
days = pd.date_range('2024-07-01', '2026-06-30', freq='16D')
rows = []
E_CH, PMAX = 2296 / 0.88, 574.0
for d in days:
    s = cf.loc[d - pd.Timedelta(hours=2): d + pd.Timedelta(hours=23)]   # covers the CET/CEST market day
    for h, r in s.iterrows():
        rows.append(dict(ts=h.strftime('%Y%m%d-%H'), day=d.date(), pv_cf=r.pv, wind_cf=r.wind,
                         pv_norm=r.pv / m.pv, wind_norm=r.wind / m.wind))
out = pd.DataFrame(rows).drop_duplicates('ts')
# battery charge per market day (CET): hours of market day d are d-1 22/23 UTC .. d 21/22 UTC; PV is ~0 there, so
# ranking PV within the UTC date d is equivalent.
out['charge_mw'] = 0.0
for d, g in out.groupby('day'):
    left = E_CH
    for i in g.sort_values('pv_cf', ascending=False).index:
        q = min(PMAX, left); out.loc[i, 'charge_mw'] = q; left -= q
        if left <= 0: break
out.to_csv(OUT, index=False)
print(len(days), 'days', len(out), 'hours ->', OUT)
pd.Series(m).to_csv(OUT.replace('.csv', '_meancf.csv'))
