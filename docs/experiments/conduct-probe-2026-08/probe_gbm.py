"""Conduct probe: per-zone GBM. R2(physics) vs R2(physics+conduct), GroupKFold by day.
NaN-tolerant (HGB handles NaN features); per-zone guard; incremental cache."""
import sys, os, warnings; warnings.filterwarnings('ignore')
import numpy as np, pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.model_selection import GroupKFold
from sklearn.inspection import permutation_importance
S = sys.argv[1]
TAG = sys.argv[2] if len(sys.argv) > 2 else ''
df = pd.read_parquet(f'{S}/probe{TAG}_dataset.parquet').dropna(subset=['resid'])
PHYS = ['hour','month','D','res_sh','imp_sh','bst_sh','margin','gas','co2','nx','np_head_exp']
COND = ['top1_sh','hhi','rsi','piv']
def hgb():
    return HistGradientBoostingRegressor(max_depth=4, max_iter=150, learning_rate=0.06,
                                         l2_regularization=1.0, random_state=0)
def cv_r2(d, feats):
    X, y, g = d[feats].values, d.resid.values, d.day.values
    preds = np.full(len(y), np.nan)
    for tr, te in GroupKFold(n_splits=5).split(X, y, g):
        m = hgb(); m.fit(X[tr], y[tr]); preds[te] = m.predict(X[te])
    return 1 - np.nansum((y-preds)**2)/np.nansum((y-y.mean())**2)
CACHE = f'{S}/probe{TAG}_verdicts_partial.csv'
rows, done = [], set()
if os.path.exists(CACHE):
    c = pd.read_csv(CACHE); rows = c.to_dict('records'); done = set(c.zone)
    print('cache:', len(done), 'zones', flush=True)
for z, d in df.groupby('zone'):
    if z in done: continue
    d = d.dropna(subset=['margin','rsi'])
    if len(d) < 800: continue
    print(z, len(d), flush=True)
    ph = [f for f in PHYS if d[f].notna().any()]   # all-NaN columns crash HGB
    cn = [f for f in COND if d[f].notna().any()]
    try:
        r2p = cv_r2(d, ph)
        r2f = cv_r2(d, ph+cn)
        m = hgb().fit(d[ph+cn], d.resid)
        try:
            pi = permutation_importance(m, d[ph+cn], d.resid, n_repeats=2,
                                        random_state=0, n_jobs=1)
            imp = pd.Series(pi.importances_mean, index=ph+cn)
        except Exception as e:
            print(f'  perm-imp failed ({type(e).__name__}), zeros', flush=True)
            imp = pd.Series(0.0, index=ph+cn)
        topc, topcv, topp = imp[cn].idxmax(), imp[cn].max(), imp[ph].idxmax()
        d = d.assign(mq=pd.qcut(d.margin, 4, labels=False, duplicates='drop'))
        pp = [d[(d.mq==q)&(d.piv==1)].resid.mean() - d[(d.mq==q)&(d.piv==0)].resid.mean()
              for q in d.mq.unique()
              if d[(d.mq==q)&(d.piv==1)].shape[0]>30 and d[(d.mq==q)&(d.piv==0)].shape[0]>30]
        rows.append(dict(zone=z, n=len(d), r2_phys=r2p, d_r2=r2f-r2p, top_cond=topc,
                         top_cond_imp=topcv, top_phys=topp, piv_share=d.piv.mean(),
                         piv_prem=np.nanmean(pp) if pp else np.nan,
                         resid_pk=d[d.hour.between(16,19)].resid.mean(), tier1=int(d.tier1.iloc[0])))
        pd.DataFrame(rows).to_csv(CACHE, index=False)
    except Exception as e:
        print(f'ZONE-FAIL {z}: {type(e).__name__} {e}', flush=True); continue
r = pd.DataFrame(rows).set_index('zone')
r['verdict'] = np.where((r.d_r2>0.03)&(r.piv_prem.abs()>3), 'CONDUCT?',
               np.where(r.r2_phys>0.25, 'physics', 'noise/unexplained'))
r = r.sort_values('d_r2', ascending=False)
pd.set_option('display.width', 200)
print(r.round(3).to_string())
r.to_csv(f'{S}/probe{TAG}_verdicts.csv')
print("\nfootprint: mean R2 phys %.3f, mean dR2 conduct %.3f" % (r.r2_phys.mean(), r.d_r2.mean()))
