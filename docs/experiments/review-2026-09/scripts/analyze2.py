import pandas as pd, numpy as np, os
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 200)
S=os.environ['S']
df = pd.read_parquet(S+'/cv37_joined.parquet')
df['r']=df.sim-df.act; df['ae']=df.r.abs(); df['hr']=df.h.dt.hour; df['date']=df.h.dt.date; df['ym']=df.h.dt.year*100+df.h.dt.month
df['dow']=df.h.dt.dayofweek; df['wk']=(df.dow>=5)
# A. Jul/Aug 2026 per zone
print("=== A. 2026-07 / 2026-08 per-zone bias / MAE (vs whole record) ===")
t = df[df.ym.isin([202607,202608])].groupby(['z','ym']).agg(bias=('r','mean'),MAE=('ae','mean'),act=('act','mean'),sim=('sim','mean')).unstack(1).round(1)
t[('all','bias')]=df.groupby('z').r.mean().round(1)
print(t.sort_values(('bias',202608)).to_string())
# TTF/EUA monthly and implied gas SRMC vs DE_LU settled/model monthly
ttf=pd.read_parquet(S+'/ttf.parquet'); eua=pd.read_parquet(S+'/eua.parquet')
ttf['ym']=pd.to_datetime(ttf.date).dt.year*100+pd.to_datetime(ttf.date).dt.month; eua['ym']=pd.to_datetime(eua.date).dt.year*100+pd.to_datetime(eua.date).dt.month
m = df[df.z=='DE_LU'].groupby('ym').agg(act=('act','mean'),sim=('sim','mean'),bias=('r','mean'),MAE=('ae','mean'))
m['ttf']=ttf.groupby('ym').close.mean(); m['eua']=eua.groupby('ym').close.mean()
m['ccgt_srmc']=m.ttf/0.55+0.37*m.eua+4   # rough CCGT 55%, 0.37 tCO2/MWh_el
m['act_minus_srmc']=m.act-m.ccgt_srmc; m['sim_minus_srmc']=m.sim-m.ccgt_srmc
print("\n=== A2. DE_LU monthly vs rough CCGT SRMC (TTF/0.55 + 0.37*EUA + 4) ===")
print(m.round(1).to_string())
# B. weekday/weekend bias per zone
print("\n=== B. weekday vs weekend bias per zone (diff = weekday - weekend) ===")
b = df.pivot_table(index='z',columns='wk',values='r',aggfunc='mean'); b.columns=['weekday','weekend']; b['diff']=b.weekday-b.weekend
print(b.sort_values('diff').round(1).to_string())
# C. dispersion & slope per zone
print("\n=== C. dispersion ratio sim_sd/act_sd, OLS slope act~sim, and intraday-range ratio ===")
def disp(g):
    sl = np.polyfit(g.sim, g.act, 1)[0]
    rng_a = g.groupby('date').act.agg(lambda s: s.max()-s.min()).mean(); rng_s = g.groupby('date').sim.agg(lambda s: s.max()-s.min()).mean()
    return pd.Series({'sd_ratio':g.sim.std()/g.act.std(),'slope_act_on_sim':sl,'range_act':rng_a,'range_sim':rng_s,'range_ratio':rng_s/rng_a})
print(df.groupby('z').apply(disp).sort_values('sd_ratio').round(2).to_string())
# D. common day-level factor vs fuel / dow / load
dm = df.groupby(['z','date']).r.mean().unstack(0)
X = dm.fillna(0).values; Xc = X - X.mean(0); u,s,vt = np.linalg.svd(Xc, full_matrices=False)
pc1 = pd.Series(u[:,0]*s[0], index=dm.index)
dd = pd.DataFrame({'pc1':pc1}); dd.index=pd.to_datetime(dd.index)
dd['dow']=dd.index.dayofweek; tt=ttf.set_index(pd.to_datetime(ttf.date)).close; ee=eua.set_index(pd.to_datetime(eua.date)).close
dd['ttf']=tt.reindex(dd.index).ffill(); dd['eua']=ee.reindex(dd.index).ffill()
dd['ttf_chg5']=dd.ttf.diff(5); dd['load']=df.groupby('date')['load'].sum().reindex(dd.index.date).values
dd['act']=df.groupby('date').act.mean().reindex(dd.index.date).values; dd['pc1_lag1']=dd.pc1.shift(1)
print("\n=== D. day-level common residual factor (PC1, 31% var): correlations ===")
print(dd.corr().pc1.round(2).to_string()); print("PC1 mean by dow:", dd.groupby('dow').pc1.mean().round(1).to_dict())
# E. Nordic collapse: what does the model do when settled<=5?
print("\n=== E. When settled<=5: model price distribution per zone (n, sim mean, p10, p50, p90) ===")
e = df[df.act<=5].groupby('z').sim.describe(percentiles=[.1,.5,.9])[['count','mean','10%','50%','90%']]
print(e[e['count']>500].sort_values('count',ascending=False).round(1).to_string())
print("\n=== E2. settled<=5 hours: by month (footprint count) and Nordic share ===")
nord=['NO1','NO2','NO3','NO4','NO5','SE1','SE2','SE3','SE4','FI','DK1','DK2']
c5 = df[df.act<=5].groupby('ym').size(); cn = df[(df.act<=5)&df.z.isin(nord)].groupby('ym').size()
print(pd.DataFrame({'all':c5,'nordic':cn,'nordic_hit':df[(df.act<=5)&df.z.isin(nord)&(df.sim<=5)].groupby('ym').size()}).fillna(0).astype(int).T.to_string())
# F. Spread to DE_LU: settled vs model by hour block, Core satellites
print("\n=== F. Spread vs DE_LU (zone - DE_LU), settled vs model, by hour block ===")
hub = df[df.z=='DE_LU'][['h','act','sim']].rename(columns={'act':'hact','sim':'hsim'})
sp = df.merge(hub,on='h'); sp['sa']=sp.act-sp.hact; sp['ss']=sp.sim-sp.hsim
sp['blk']=pd.cut(sp.hr,[-1,5,9,13,16,20,23],labels=['00-05','06-09','10-13','14-16','17-20','21-23'])
sat=['AT','CZ','SK','HU','SI','PL','NL','BE','FR','CH','RO','HR','DK1','DK2','SE4','LT','LV','EE','NO2','IT-NORTH']
f = sp[sp.z.isin(sat)].pivot_table(index='z',columns='blk',values=['sa','ss'],aggfunc='mean',observed=True).round(1)
f.columns=[f"{a}_{b}" for a,b in f.columns]; print(f.to_string())
print("\n=== F2. hub-level vs spread error decomposition (17-20 UTC): r_zone = r_hub + (spread error) ===")
ev = sp[(sp.hr>=17)&(sp.hr<=20)&sp.z.isin(sat)].groupby('z').apply(lambda g: pd.Series({'r_zone':(g.sim-g.act).mean(),'r_hub':(g.hsim-g.hact).mean(),'spread_err':(g.ss-g.sa).mean(),'corr_spread':g.sa.corr(g.ss)}))
print(ev.round(1).to_string())
# G. negative-price hours: what does the model say
print("\n=== G. settled<0 hours: model mean and settled mean by zone (n>300) ===")
g = df[df.act<0].groupby('z').agg(n=('r','size'),act=('act','mean'),sim=('sim','mean'),act_p10=('act',lambda s:s.quantile(.1)))
print(g[g.n>300].sort_values('n',ascending=False).round(1).to_string())
# H. Spike days: HU settled>=200: what fraction of those hours have DE_LU>=150? (is the spike imported or local)
print("\n=== H. Spike anatomy (settled>=200): hub DE_LU settled at the same hour, and model ===")
hs = sp[sp.act>=200].groupby('z').agg(n=('act','size'),act=('act','mean'),sim=('sim','mean'),hub_act=('hact','mean'),hub_sim=('hsim','mean'),hr=('hr','median'))
print(hs[hs.n>200].sort_values('n',ascending=False).round(1).to_string())
# I. tightness proxy: residual vs within-zone-hour load anomaly (load relative to same zone-hour-dow median in trailing 8 weeks) -> per hour block bias in tight decile
df=df.sort_values(['z','h'])
df['ld_med']=df.groupby(['z','hr','dow'])['load'].transform(lambda s: s.rolling(8,min_periods=3).median().shift(1))
df['lanom']=(df['load']-df.ld_med)/df.ld_med
df['ldec']=pd.qcut(df.lanom.rank(method='first'),10,labels=False)
print("\n=== I. bias/MAE by decile of LOAD ANOMALY vs trailing-8-week same zone/hour/dow median (0=lowest) ===")
print(df.groupby('ldec').agg(bias=('r','mean'),MAE=('ae','mean'),n=('r','size'),anom=('lanom','mean')).round(2).T.to_string())
