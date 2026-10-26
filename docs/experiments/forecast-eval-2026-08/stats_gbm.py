"""Pure-stats baseline: per-zone GBM predicting settled directly (NO physics).
Features legal at the D-1 gate: settled lags 24/48/168h + 7d rolling mean,
calendar, D-2 fuel closes, D-1 load & RES forecasts. GroupKFold(5) by day."""
import sys, warnings; warnings.filterwarnings('ignore')
import numpy as np, pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.model_selection import GroupKFold
S = sys.argv[1]
d = pd.read_parquet(f'{S}/probe2y37_dataset.parquet')[['zone','k','day','D','res_sh','gas','co2','settled']]
d['t'] = pd.to_datetime(d.k, format='%Y-%m-%dT%H', utc=True)
d = d.sort_values(['zone','t'])
g = d.groupby('zone').settled
d['lag24'] = g.shift(24); d['lag48'] = g.shift(48); d['lag168'] = g.shift(168)
d['roll7'] = g.shift(24).rolling(168).mean().reset_index(0, drop=True)
d['hour'] = d.t.dt.hour; d['dow'] = d.t.dt.dayofweek; d['month'] = d.t.dt.month
FEATS = ['lag24','lag48','lag168','roll7','hour','dow','month','gas','co2','D','res_sh']
out = []
for z, dz in d.groupby('zone'):
    dz = dz.dropna(subset=['lag168','settled'])
    if len(dz) < 800: continue
    X, y, grp = dz[FEATS].values, dz.settled.values, dz.day.values
    preds = np.full(len(y), np.nan)
    for tr, te in GroupKFold(n_splits=5).split(X, y, grp):
        m = HistGradientBoostingRegressor(max_depth=5, max_iter=250, learning_rate=0.06,
                                          l2_regularization=1.0, random_state=0)
        m.fit(X[tr], y[tr]); preds[te] = m.predict(X[te])
    out.append(pd.DataFrame({'zone': z, 'k': dz.k.values, 'stats_pred': preds}))
    mae = np.abs(preds - y).mean()
    print(f"{z:12} stats-GBM OOS MAE {mae:6.2f}", flush=True)
pd.concat(out).to_parquet(f'{S}/stats_oos.parquet')
print("STATS DONE")
