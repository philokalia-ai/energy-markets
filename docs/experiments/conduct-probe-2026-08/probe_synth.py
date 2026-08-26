"""Final conduct map: join GBM (feature probe) x book inversion (markup probe)."""
import sys, numpy as np, pandas as pd
S=sys.argv[1]
g = pd.read_csv(f'{S}/probe_verdicts.csv').set_index('zone')
m = pd.read_csv(f'{S}/probe_markup_structure.csv').set_index('zone')
t = g.join(m[['mk_pk_prem','mk_win_prem']])
# classification:
# tightness-marked: residual predictable from physics/tightness AND the book says
#   settled rises above the competitive curve at the peak (mk_pk_prem >> 0)
#   -> consistent with tightness-indexed markup OR missing scarcity mechanism (both probes agree something beyond the book happens in tight hours)
# concentration-linked: conduct features add real OOS dR2
# model-gap: physics-predictable but book inversion does NOT show a peak premium (mechanism missing in the model, market matches its own book)
# unexplained: neither
t['klass'] = np.where((t.d_r2 > 0.03), 'concentration-linked',
             np.where((t.r2_phys > 0.25) & (t.mk_pk_prem > 25), 'tightness-marked',
             np.where((t.r2_phys > 0.25), 'model-gap',
             np.where((t.mk_pk_prem > 40) & (t.resid_pk > 15), 'peak-premium (weak model signal)', 'unexplained'))))
cols = ['klass','r2_phys','d_r2','top_phys','top_cond','mk_pk_prem','mk_win_prem','resid_pk','piv_share','tier1']
t = t[cols].sort_values(['klass','r2_phys'], ascending=[True,False])
pd.set_option('display.width',200)
print(t.round(2).to_string())
t.to_csv(f'{S}/probe_conduct_map.csv')
print("\ncounts:", t.klass.value_counts().to_dict())
