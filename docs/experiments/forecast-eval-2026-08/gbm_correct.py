"""Ex-ante GBM corrector: train on cv37 residuals (ex-ante features only),
CV-score honestly, predict tomorrow's residual, emit the corrected table."""
import sys, warnings; warnings.filterwarnings('ignore')
import numpy as np, pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.model_selection import GroupKFold
S = sys.argv[1]
FEATS = ['hour','month','D','res_sh','imp_sh','bst_sh','margin','gas','co2']
hist = pd.read_parquet(f'{S}/probe2y37_dataset.parquet').dropna(subset=['resid'])
tom = pd.read_csv(f'{S}/features_tomorrow.csv')
tom['hour'] = tom.k.str[11:13].astype(int); tom['month'] = tom.k.str[5:7].astype(int)
tom['res_sh'] = tom.res_mw/tom.D; tom['imp_sh'] = tom.imp_mw/tom.D
tom['bst_sh'] = tom.bst_mw/tom.D; tom['margin'] = tom.stot/tom.D
# fuels: last closes strictly before D-1 (same convention)
ttf = pd.read_csv(f'{S}/probe_ttf.csv', header=None, names=['date','close'], parse_dates=['date'])
eua = pd.read_csv(f'{S}/probe_eua.csv', header=None, names=['date','close'], parse_dates=['date'])
import datetime as dt
cut = pd.Timestamp('2026-08-28')
tom['gas'] = float(ttf[ttf.date < cut].close.iloc[-1]); tom['co2'] = float(eua[eua.date < cut].close.iloc[-1])
lead1 = pd.read_csv(f'{S}/lead1_tomorrow.csv', header=None, names=['zone','ts','p'])
lead1['k'] = pd.to_datetime(lead1.ts, utc=True, format='mixed').dt.strftime('%Y-%m-%dT%H')
lead1 = lead1.groupby(['zone','k']).p.mean().rename('phys').reset_index()
import os
OOS_CACHE = pd.read_parquet(f'{S}/gbm_oos.parquet') if os.path.exists(f'{S}/gbm_oos.parquet') else None
out = []; oos = []
def hgb(): return HistGradientBoostingRegressor(max_depth=4, max_iter=150, learning_rate=0.06,
                                                l2_regularization=1.0, random_state=0)
for z, d in hist.groupby('zone'):
    if len(d)<800: continue
    tz = tom[tom.zone==z]
    X, y, g = d[FEATS].values, d.resid.values, d.day.values
    if OOS_CACHE is not None and z in set(OOS_CACHE.zone):
        prev = d[['k']].merge(OOS_CACHE[OOS_CACHE.zone==z], on='k', how='left')
        preds = prev.resid_hat_oos.values
    else:
        preds = np.full(len(y), np.nan)
        for tr, te in GroupKFold(n_splits=5).split(X, y, g):
            m = hgb(); m.fit(X[tr], y[tr]); preds[te] = m.predict(X[te])
    r2 = 1 - np.nansum((y-preds)**2)/np.nansum((y-y.mean())**2)
    oos.append(pd.DataFrame({'zone': z, 'k': d.k.values, 'resid_hat_oos': preds}))
    mae_gain = np.mean(np.abs(y)) - np.mean(np.abs(y-preds))   # honest OOS MAE reduction of the residual
    if len(tz):
        m = hgb().fit(X, y)
        tzz = tz[['zone','k']].copy(); tzz['resid_hat'] = m.predict(tz[FEATS].values)
        out.append((z, r2, mae_gain, tzz))
    else:
        out.append((z, r2, mae_gain, pd.DataFrame(columns=['zone','k','resid_hat'])))
    print(f"{z:12} exante-R2 {r2:+.3f}  OOS |resid| gain {mae_gain:+5.2f}", flush=True)
pd.concat(oos).to_parquet(f'{S}/gbm_oos.parquet')
print("OOS predictions dumped:", sum(len(x) for x in oos))
allp = pd.concat([t for _,_,_,t in out])
final = lead1.merge(allp, on=['zone','k'], how='left')
final['best'] = final.phys + final.resid_hat.fillna(0.0)
final['pk'] = final.k.str[11:13].astype(int).between(16,19)
summ = final.groupby('zone').agg(phys_avg=('phys','mean'), best_avg=('best','mean'),
    phys_pk=('phys', lambda s: s[final.loc[s.index,'pk']].mean()),
    best_pk=('best', lambda s: s[final.loc[s.index,'pk']].mean())).round(1)
r2map = {z: r for z, r, _, _ in out}
summ['exante_R2'] = [round(r2map.get(z, np.nan),2) for z in summ.index]
print(summ.sort_values('best_avg', ascending=False).to_string())
summ.to_csv(f'{S}/minister_corrected.csv')
