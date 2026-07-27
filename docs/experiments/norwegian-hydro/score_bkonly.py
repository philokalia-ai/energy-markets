import glob, pandas as pd, numpy as np
D="docs/experiments/norwegian-hydro/data"
def load(pat):
    fr=[pd.read_csv(f,sep='\t') for f in glob.glob(f"{D}/{pat}")]
    df=pd.concat(fr); df['slot']=pd.to_datetime(df.timeslot.astype(str),format='%Y%m%d-%H%M'); return df
base=load("out_base_*.tsv"); bk=load("out_bkonly_*.tsv")
ac=pd.read_csv(f"{D}/actual.csv"); ac['slot']=pd.to_datetime(ac['slot'])
# inert check on 2026-02-09 (guard day present in both base and bkonly)
gd='2026-02-09'
for z in ['NO1','NO3']:
    b=base[(base.zone==z)&(base.day==gd)].merge(bk[(bk.zone==z)&(bk.day==gd)],on='slot',suffixes=('_b','_k'))
    if len(b): print(f"inert-check {z} {gd}: max|base-bkonly| = {np.abs(b.price_b-b.price_k).max():.4f}")
# construct backstop-only arm = base(non-May) + bkonly(May)
may=[d for d in sorted(base.day.unique()) if d.startswith('2026-05')]
nonmay=[d for d in sorted(base.day.unique()) if not d.startswith('2026-05')]
bkmay=bk[bk.day.isin(may)]
arm=pd.concat([base[base.day.isin(nonmay)], bkmay])
common=sorted(set(arm.day.unique()))
print("\nbackstop-only arm days:",common, " (May from bkonly:",sorted(bkmay.day.unique()),")")
def sc(sim,z,days=None):
    m=sim[sim.zone==z].merge(ac[ac.zone==z],on='slot',suffixes=('_s','_a')).dropna()
    if days is not None: m=m[m.slot.dt.strftime('%Y-%m-%d').isin(days)]
    if len(m)<2: return (0,0,0)
    s=m.price_s.to_numpy(float);a=m.price_a.to_numpy(float);d=s-a
    cr=float(((s-s.mean())*(a-a.mean())).mean()/(s.std()*a.std())) if s.std()>1e-9 and a.std()>1e-9 else 0
    return (round(cr,3),round(np.abs(d).mean(),1),round(d.mean(),1))
print("\nbackstop-only vs base (all 13 common days):")
for z in ['NO1','NO3','NO2','NO5','DE_LU','NL','DK1','DK2','SE1','SE2','SE3','SE4']:
    print(f"  {z:6} base {sc(base[base.day.isin(common)],z)} -> bkonly {sc(arm,z)}")
print("\ndry-May bkonly:")
for z in ['NO1','NO3']:
    print(f"  {z}: base {sc(base,z,may)} -> bkonly {sc(bkmay,z,may)}")
