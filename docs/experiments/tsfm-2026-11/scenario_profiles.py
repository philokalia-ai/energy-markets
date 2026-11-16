"""Scenario shift profiles for the TSFM pass-through test (phase 2).

dsim  = mean (scenario - eu43_base) cv43 price per zone x Athens local hour over the sampled
        Sep-Nov days (results/scenarios-cv43.duckdb; DC: 2024+2025, cold ironing: 2024).
dload = scenario load added: DC +574 MW flat in GR; cold ironing = the eu37/eu43 FLOOR profile
        (docs/experiments/scenario-exercises/ops_hourly_eu_floor_2023H2_2025H1.csv.gz), SON mean.
"""
import os
import sys
import duckdb, pandas as pd
R = (os.environ.get('EM_RESULTS_DIR') or sys.exit("Set EM_RESULTS_DIR to the required local file or directory"))
c = duckdb.connect(R + '/scenarios-cv43.duckdb', read_only=True)
df = c.execute("""select clearing_mode m, bidding_zone zone, date_time_utc t, price_eur_mwh p
  from simulations.energy_prices where clearing_mode in ('eu43_base','eu43_dc574','eu43_ops_floor_paneu')""").df()
w = df.pivot_table(index=['zone', 't'], columns='m', values='p').reset_index()
loc = w.t.dt.tz_localize('UTC').dt.tz_convert('Europe/Athens')
w['lh'] = loc.dt.hour; w['month'] = loc.dt.month
son = w[w.month.isin([9, 10, 11])]
prof = []
for scen, col in (('dc574', 'eu43_dc574'), ('ops', 'eu43_ops_floor_paneu')):
    s = son.dropna(subset=[col, 'eu43_base']).assign(d=lambda x: x[col] - x.eu43_base)
    g = s.groupby(['zone', 'lh']).d.mean().rename('dsim').reset_index(); g['scenario'] = scen
    prof.append(g)
    print(scen, 'SON days', s.t.dt.date.nunique(), 'top zone mean dsim:',
          s.groupby('zone').d.mean().sort_values(ascending=False).head(8).round(2).to_dict())
prof = pd.concat(prof)
ops = pd.read_csv('docs/experiments/scenario-exercises/ops_hourly_eu_floor_2023H2_2025H1.csv.gz', parse_dates=['datetime_utc'])
l = ops.datetime_utc.dt.tz_convert('Europe/Athens'); ops['lh'] = l.dt.hour; ops['month'] = l.dt.month
om = ops[ops.month.isin([9, 10, 11])].groupby(['zone', 'lh']).mw.mean().rename('dload').reset_index(); om['scenario'] = 'ops'
print('ops SON mean MW, top:', ops[ops.month.isin([9, 10, 11])].groupby('zone').mw.mean().sort_values(ascending=False).round(1).head(10).to_dict(), 'zones', ops.zone.nunique())
dc = pd.DataFrame({'zone': 'GR', 'lh': range(24), 'dload': 574.0, 'scenario': 'dc574'})
prof = prof.merge(pd.concat([om, dc]), on=['scenario', 'zone', 'lh'], how='left').fillna({'dload': 0.0})
prof.to_parquet(R + '/tsfm/scenario_profiles.parquet'); print(prof.groupby('scenario').size().to_dict())
