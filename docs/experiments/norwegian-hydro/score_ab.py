#!/usr/bin/env python3
# Score the cv23 gateway-anchor A/B: base (EUPHEMIA_DISABLE_CV23=1) vs cv23
# (gateway anchor NO1/NO3->NO2 + import backstop), on the COMMON completed days,
# vs realized DA prices (data/actual.csv). Writes data/ab_scored.tsv.
#   python3 docs/experiments/norwegian-hydro/score_ab.py
import glob, pandas as pd, numpy as np
D = "docs/experiments/norwegian-hydro/data"

def load(pat):
    fr = [pd.read_csv(f, sep='\t') for f in glob.glob(f"{D}/{pat}")]
    df = pd.concat(fr)
    df['slot'] = pd.to_datetime(df.timeslot.astype(str), format='%Y%m%d-%H%M')
    return df[['zone', 'slot', 'price', 'day']]

b = load("out_base_*.tsv"); c = load("out_cv23_*.tsv")
common = sorted(set(b.day.unique()) & set(c.day.unique()))
b = b[b.day.isin(common)]; c = c[c.day.isin(common)]
ac = pd.read_csv(f"{D}/actual.csv"); ac['slot'] = pd.to_datetime(ac['slot'])
print(f"common days ({len(common)}): {common}\n")

def sc(sim, z, days=None):
    m = sim[sim.zone == z].merge(ac[ac.zone == z], on='slot', suffixes=('_s', '_a')).dropna()
    if days is not None:
        m = m[m.slot.dt.strftime('%Y-%m-%d').isin(days)]
    if len(m) < 2: return (0.0, 0.0, 0.0, 0)
    s = m.price_s.to_numpy(float); a = m.price_a.to_numpy(float); d = s - a
    cr = float(((s - s.mean()) * (a - a.mean())).mean() / (s.std() * a.std())) \
        if s.std() > 1e-9 and a.std() > 1e-9 else 0.0
    return (round(cr, 3), round(np.abs(d).mean(), 1), round(d.mean(), 1), len(m))

zones = ['NO1','NO2','NO3','NO4','NO5','SE1','SE2','SE3','SE4','DE_LU','NL','DK1','DK2','FR','CZ','AT']
rows = []
for z in zones:
    bb = sc(b, z); cc = sc(c, z)
    rows.append([z, bb[0], bb[1], bb[2], cc[0], cc[1], cc[2],
                 round(cc[0]-bb[0], 3), round(cc[1]-bb[1], 1)])
tab = pd.DataFrame(rows, columns=['zone','corr_base','mae_base','bias_base',
    'corr_cv23','mae_cv23','bias_cv23','dcorr','dmae']).set_index('zone')
print("=== combined window (all common A/B days) ===")
print(tab.to_string())
tab.to_csv(f"{D}/ab_scored.tsv", sep='\t')

dry = [d for d in common if d.startswith('2026-05')]
print(f"\n=== dry-spring window {dry} ===")
for z in ['NO1','NO3','NO5']:
    bb = sc(b, z, dry); cc = sc(c, z, dry)
    print(f"  {z}: base corr {bb[0]} mae {bb[1]} bias {bb[2]} -> cv23 corr {cc[0]} mae {cc[1]} bias {cc[2]} (dMAE {round(cc[1]-bb[1],1)})")

print("\n=== GATE ===")
n1 = tab.loc['NO1']; no2 = tab.loc['NO2']
n1d_b = sc(b,'NO1',dry); n1d_c = sc(c,'NO1',dry)
g1 = n1.corr_cv23 >= 0.30 and (n1.mae_base - n1.mae_cv23) >= 15
g2 = (n1d_b[1] - n1d_c[1]) >= 30
g3 = no2.dcorr >= -0.03 and no2.dmae <= 1.5
leak = ['DE_LU','NL','DK1','DK2']
g4 = all(tab.loc[z].dcorr >= -0.03 and tab.loc[z].dmae <= 1.5 for z in leak)
print(f"1 NO1 corr>=0.30 & MAE-15 : {g1}  (corr {n1.corr_cv23}, dMAE {round(n1.mae_base-n1.mae_cv23,1)})")
print(f"2 dry NO1 MAE-30          : {g2}  (dMAE {round(n1d_b[1]-n1d_c[1],1)})")
print(f"3 NO2 no degrade          : {g3}  (dcorr {no2.dcorr}, dMAE {no2.dmae})")
print(f"4 no continental leakage  : {g4}")
for z in leak:
    print(f"     {z}: dcorr {tab.loc[z].dcorr}, dMAE {tab.loc[z].dmae}")
print(f"\nPASS: {g1 and g2 and g3 and g4}")
