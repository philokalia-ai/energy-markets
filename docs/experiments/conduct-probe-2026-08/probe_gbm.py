"""Conduct probe: per-zone GBM. R2(physics) vs R2(physics+conduct), GroupKFold by day.
Also the model-free pivotal-premium split."""
import sys, warnings; warnings.filterwarnings('ignore')
import numpy as np, pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.model_selection import GroupKFold
from sklearn.inspection import permutation_importance
S = sys.argv[1]
df = pd.read_parquet(f'{S}/probe_dataset.parquet').dropna(subset=['resid'])
PHYS = ['hour','month','D','res_sh','imp_sh','bst_sh','margin','gas','co2','nx','np_head_exp']
COND = ['top1_sh','hhi','rsi','piv']
def cv_r2(d, feats):
    X, y, g = d[feats].values, d.resid.values, d.day.values
    gk = GroupKFold(n_splits=5); preds = np.full(len(y), np.nan)
    for tr, te in gk.split(X, y, g):
        m = HistGradientBoostingRegressor(max_depth=4, max_iter=150, learning_rate=0.06,
                                          l2_regularization=1.0, random_state=0)
        m.fit(X[tr], y[tr]); preds[te] = m.predict(X[te])
    ss = 1 - np.nansum((y-preds)**2)/np.nansum((y-y.mean())**2)
    return ss, preds
rows = []
for z, d in df.groupby('zone'):
    d = d.dropna(subset=PHYS+COND, how='any')
    if len(d) < 800: continue
    print(z, len(d), flush=True)
    r2p, _ = cv_r2(d, PHYS)
    r2f, _ = cv_r2(d, PHYS+COND)
    # top conduct feature by permutation on a full fit
    m = HistGradientBoostingRegressor(max_depth=4, max_iter=150, learning_rate=0.06,
                                      l2_regularization=1.0, random_state=0).fit(d[PHYS+COND], d.resid)
    pi = permutation_importance(m, d[PHYS+COND], d.resid, n_repeats=2, random_state=0)
    imp = pd.Series(pi.importances_mean, index=PHYS+COND)
    topc = imp[COND].idxmax(); topcv = imp[COND].max(); topp = imp[PHYS].idxmax()
    # model-free: pivotal premium at similar tightness (control by margin quartile)
    d = d.assign(mq=pd.qcut(d.margin, 4, labels=False, duplicates='drop'))
    piv_prem = np.nanmean([d[(d.mq==q)&(d.piv==1)].resid.mean() - d[(d.mq==q)&(d.piv==0)].resid.mean()
                           for q in d.mq.unique()
                           if (d[(d.mq==q)&(d.piv==1)].shape[0]>30 and d[(d.mq==q)&(d.piv==0)].shape[0]>30)] or [np.nan])
    rows.append(dict(zone=z, n=len(d), r2_phys=r2p, d_r2=r2f-r2p, top_cond=topc, top_cond_imp=topcv,
                     top_phys=topp, piv_share=d.piv.mean(), piv_prem=piv_prem,
                     resid_pk=d[d.hour.between(16,19)].resid.mean(), tier1=int(d.tier1.iloc[0])))
r = pd.DataFrame(rows).set_index('zone')
r['verdict'] = np.where((r.d_r2>0.03)&(r.piv_prem.abs()>3), 'CONDUCT?',
               np.where(r.r2_phys>0.25, 'physics', 'noise/unexplained'))
r = r.sort_values('d_r2', ascending=False)
pd.set_option('display.width', 200)
print(r.round(3).to_string())
r.to_csv(f'{S}/probe_verdicts.csv')
print("\nfootprint: mean R2 phys %.3f, mean dR2 conduct %.3f" % (r.r2_phys.mean(), r.d_r2.mean()))
