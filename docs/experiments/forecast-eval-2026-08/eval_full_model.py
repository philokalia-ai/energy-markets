"""Full-model (physics + ex-ante GBM, OOS) vs physics alone, as a time-series
forecaster: MAE, RMSE, bias, corr, rMAE vs naive-week, sMAPE, directional
accuracy, spike/collapse recall+precision."""
import sys, numpy as np, pandas as pd
S = sys.argv[1]
d = pd.read_parquet(f'{S}/probe2y37_dataset.parquet')[['zone','k','D','settled','sim37']]
oos = pd.read_parquet(f'{S}/gbm_oos.parquet')
d = d.merge(oos, on=['zone','k'], how='inner')
d['full'] = d.sim37 + d.resid_hat_oos
import os
HAVE_STATS = os.path.exists(f'{S}/stats_oos.parquet')
if HAVE_STATS:
    d = d.merge(pd.read_parquet(f'{S}/stats_oos.parquet'), on=['zone','k'], how='left')
d['t'] = pd.to_datetime(d.k, format='%Y-%m-%dT%H', utc=True)
d = d.sort_values(['zone','t'])
d['naive'] = d.groupby('zone').settled.shift(168)          # same hour last week
d['ds'] = d.groupby('zone').settled.diff()                 # hourly delta, actual
rows = []
for z, g in d.groupby('zone'):
    g = g.dropna(subset=['naive'])
    p90 = np.quantile(g.settled.values, 0.9)
    r = {'zone': z}
    arms = [('phys', g.sim37.values), ('full', g.full.values)]
    if HAVE_STATS and g.stats_pred.notna().sum() > 100:
        gs = g.dropna(subset=['stats_pred'])
        arms.append(('stats', None))
    for name, f in arms:
        if name == 'stats':
            f = gs.stats_pred.values; a = gs.settled.values
        else:
            a = g.settled.values
        e = f - a
        r[f'MAE_{name}'] = np.abs(e).mean()
        r[f'RMSE_{name}'] = np.sqrt((e**2).mean())
        r[f'bias_{name}'] = e.mean()
        r[f'corr_{name}'] = np.corrcoef(f, a)[0,1]
        nv = (gs if name=='stats' else g).naive.values
        r[f'rMAE_{name}'] = np.abs(e).mean() / np.abs(nv - a).mean()
        r[f'sMAPE_{name}'] = 100*np.mean(2*np.abs(e)/np.maximum(np.abs(f)+np.abs(a), 1.0))
        df_ = np.diff(f); da = np.diff(a)
        r[f'dir_{name}'] = np.mean(np.sign(df_[da!=0]) == np.sign(da[da!=0]))
        spike_a = a >= p90; spike_f = f >= p90
        r[f'spkR_{name}'] = spike_f[spike_a].mean() if spike_a.any() else np.nan
        r[f'spkP_{name}'] = spike_a[spike_f].mean() if spike_f.any() else np.nan
        col_a = a <= 5; col_f = f <= 5
        r[f'colR_{name}'] = col_f[col_a].mean() if col_a.any() else np.nan
    r['energy'] = g.D.sum()
    rows.append(r)
t = pd.DataFrame(rows).set_index('zone')
w = t.energy/t.energy.sum()
pd.set_option('display.width', 250)
cols = ['MAE','RMSE','bias','corr','rMAE','sMAPE','dir','spkR','spkP','colR']
arm_names = ['phys','full'] + (['stats'] if HAVE_STATS and 'MAE_stats' in t else [])
print("FOOTPRINT (energy-weighted):")
print(f"{'metric':8}" + "".join(f"{n:>10}" for n in arm_names))
for c in cols:
    print(f"{c:8}" + "".join(f"{(t[f'{c}_{n}']*w).sum():10.3f}" for n in arm_names))
ms = ['phys','full'] + (['stats'] if HAVE_STATS and 'MAE_stats' in t else [])
show = t[[f'{c}_{m}' for c in ('MAE','rMAE','corr','dir') for m in ms]].round(3)
print("\nper zone (MAE, rMAE-vs-naive-week, corr, directional, spike recall):")
print(show.sort_values('MAE_full').to_string())
t.round(4).to_csv(f'{S}/full_model_metrics.csv')
