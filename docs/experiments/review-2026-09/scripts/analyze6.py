import pandas as pd, numpy as np, os
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 300)
S=os.environ['S']
df = pd.read_parquet(S+'/cv37_joined.parquet'); df['r']=df.sim-df.act; df['hr']=df.h.dt.hour
iso = df.h.dt.isocalendar(); df['year']=iso.year; df['week']=iso.week
hf = pd.read_parquet(S+'/hydro_fill.parquet')
# fill fraction relative to zone's max over 2022+ (proxy for "near full")
hf['frac']=hf.mwh/hf.groupby('z').mwh.transform('max')
# seasonal anomaly: vs same-week median over other years
hf['wk_med']=hf.groupby(['z','week']).mwh.transform('median'); hf['anom']=(hf.mwh-hf.wk_med)/hf.groupby('z').mwh.transform('max')
# lag by one week (ex-ante: latest week < D)
hf2=hf.copy(); hf2['week']=hf2.week+1; hf2.loc[hf2.week>52,'year']+=1; hf2.loc[hf2.week>52,'week']=1
m = df.merge(hf2[['z','year','week','frac','anom']], on=['z','year','week'], how='inner')
print("=== Nordic: collapse share (settled<=5) and model behaviour by reservoir-fill quintile (prev-week fill fraction of 2022+ max) ===")
for z in ['NO4','SE1','SE2','FI','NO3','SE3','NO1','NO5','NO2','ES','PT','CH','AT']:
    x=m[m.z==z].copy(); 
    if len(x)<1000: continue
    x['q']=pd.qcut(x.frac.rank(method='first'),5,labels=False)
    g=x.groupby('q').agg(fill=('frac','mean'),anom=('anom','mean'),n=('r','size'),settled_le5=('act',lambda s:(s<=5).mean()),model_le5=('sim',lambda s:(s<=5).mean()),bias=('r','mean'),act=('act','mean'),sim=('sim','mean'),sim_p10=('sim',lambda s:s.quantile(.1))).round(2)
    print(f"\n{z}:\n{g.to_string()}")
# Iberia spring profile
for z,ym in [('ES',202504),('ES',202505),('PT',202505),('ES',202604)]:
    x=df[(df.z==z)&(df.h.dt.year*100+df.h.dt.month==ym)].groupby('hr').agg(act=('act','mean'),sim=('sim','mean')).round(0)
    print(f"\n=== {z} {ym} hourly profile ===\n", x.T.to_string())
