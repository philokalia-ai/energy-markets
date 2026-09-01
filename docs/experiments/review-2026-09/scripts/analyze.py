import pandas as pd, numpy as np, os
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 200)
S=os.environ['S']
df = pd.read_parquet(S+'/cv37_joined.parquet')
df['r'] = df.sim - df.act          # residual: model - settled (positive = model over-prices)
df['ae'] = df.r.abs()
df['hr'] = df.h.dt.hour            # UTC
df['mon'] = df.h.dt.to_period('M')
df['ym'] = df.h.dt.year*100+df.h.dt.month
df['dow'] = df.h.dt.dayofweek
df['date'] = df.h.dt.date
df['load'] = df['load'].fillna(df.groupby('z')['load'].transform('median'))
GROUPS = {'Core':['DE_LU','FR','NL','BE','AT','CZ','SK','HU','SI','HR','RO','PL','CH'],
 'Nordic':['NO1','NO2','NO3','NO4','NO5','SE1','SE2','SE3','SE4','FI','DK1','DK2'],
 'Baltic':['EE','LV','LT'],'SEE':['GR','BG','RS','IT-SOUTH','IT-CSOUTH'],
 'IT':['IT-NORTH','IT-CNORTH','IT-CSOUTH','IT-SOUTH','IT-SICILY','IT-SARDINIA','IT-CALABRIA'],
 'Iberia':['ES','PT']}
def stats(g):
    w = g['load'].values
    r = g.r.values; a=g.act.values; s=g.sim.values
    corr = np.corrcoef(a,s)[0,1] if len(g)>2 and a.std()>0 and s.std()>0 else np.nan
    return pd.Series({'n':len(g),'MAE':np.abs(r).mean(),'wMAE':np.average(np.abs(r),weights=w),'bias':r.mean(),
        'RMSE':np.sqrt((r**2).mean()),'corr':corr,'act_mean':a.mean(),'act_sd':a.std(),'sim_sd':s.std(),
        'p90ae':np.quantile(np.abs(r),0.9)})
print("=== COVERAGE ===", len(df), 'cells', df.z.nunique(),'zones', df.date.nunique(),'days', df.h.min(), df.h.max())
print("\n=== FOOTPRINT (all cells, energy-weighted wMAE by actual load) ===")
print(stats(df).round(3).to_string())
print("\n=== PER ZONE (sorted by MAE) ===")
pz = df.groupby('z').apply(stats).sort_values('MAE', ascending=False)
print(pz.round(2).to_string())
# share of total absolute error by zone
tot = df.ae.sum(); pz['share_AE%'] = df.groupby('z').ae.sum()/tot*100
totw = (df.ae*df['load']).sum(); pz['share_wAE%'] = df.groupby('z').apply(lambda g:(g.ae*g['load']).sum())/totw*100
print("\n=== ZONE SHARE OF TOTAL |err| (unweighted, load-weighted) ===")
print(pz[['MAE','bias','corr','share_AE%','share_wAE%']].sort_values('share_wAE%',ascending=False).round(2).to_string())
print("\n=== PER HOUR (UTC), footprint ===")
print(df.groupby('hr').apply(stats)[['n','MAE','wMAE','bias','corr','act_mean']].round(2).to_string())
print("\n=== PER MONTH, footprint ===")
print(df.groupby('ym').apply(stats)[['n','MAE','wMAE','bias','corr','act_mean','act_sd','sim_sd']].round(2).to_string())
print("\n=== PER DOW (0=Mon) ===")
print(df.groupby('dow').apply(stats)[['n','MAE','bias','corr']].round(2).to_string())
# Regimes by settled price
bins=[-1000,0,5,30,60,100,150,200,300,5000]
df['regime']=pd.cut(df.act,bins)
print("\n=== BY SETTLED-PRICE REGIME (footprint) ===")
rg = df.groupby('regime',observed=True).apply(stats)[['n','MAE','bias','corr','act_mean']]
rg['share_AE%']=df.groupby('regime',observed=True).ae.sum()/tot*100
print(rg.round(2).to_string())
print("\n=== BY MODEL-PRICE REGIME (what the model says) ===")
df['mregime']=pd.cut(df.sim,bins)
mg = df.groupby('mregime',observed=True).apply(stats)[['n','MAE','bias','act_mean']]
mg['share_AE%']=df.groupby('mregime',observed=True).ae.sum()/tot*100
print(mg.round(2).to_string())
# Collapse / spike confusion
for name,cond_a,cond_s in [('COLLAPSE settled<=5 vs sim<=5', df.act<=5, df.sim<=5),
                            ('NEG settled<0 vs sim<0', df.act<0, df.sim<0),
                            ('SPIKE settled>=200 vs sim>=200', df.act>=200, df.sim>=200),
                            ('HIGH settled>=150 vs sim>=150', df.act>=150, df.sim>=150)]:
    tp=(cond_a&cond_s).sum(); fn=(cond_a&~cond_s).sum(); fp=(~cond_a&cond_s).sum()
    print(f"\n{name}: settled n={cond_a.sum()} model n={cond_s.sum()} TP={tp} recall={tp/max(1,cond_a.sum()):.2f} precision={tp/max(1,tp+fp):.2f}")
    print("  per-zone settled count / recall (top 12 by settled count):")
    t = pd.DataFrame({'settled':df[cond_a].groupby('z').size(),'model':df[cond_s].groupby('z').size(),'tp':df[cond_a&cond_s].groupby('z').size()}).fillna(0)
    t['recall']=t.tp/t.settled.clip(lower=1); t['prec']=t.tp/t.model.clip(lower=1)
    print(t.sort_values('settled',ascending=False).head(12).round(2).to_string())
    # error contribution of missed events
    print(f"  |err| share of FN cells: {df[cond_a&~cond_s].ae.sum()/tot*100:.1f}%  FP cells: {df[~cond_a&cond_s].ae.sum()/tot*100:.1f}%")
# Zone x hour-block bias heat
df['blk']=pd.cut(df.hr,[-1,5,9,13,16,20,23],labels=['00-05','06-09','10-13','14-16','17-20','21-23'])
print("\n=== ZONE x HOUR-BLOCK BIAS (UTC) ===")
print(df.pivot_table(index='z',columns='blk',values='r',aggfunc='mean',observed=True).round(1).to_string())
print("\n=== ZONE x HOUR-BLOCK MAE (UTC) ===")
print(df.pivot_table(index='z',columns='blk',values='ae',aggfunc='mean',observed=True).round(1).to_string())
# Season x zone bias
df['season']=df.h.dt.month.map(lambda m: 'DJF' if m in (12,1,2) else 'MAM' if m in (3,4,5) else 'JJA' if m in (6,7,8) else 'SON')
print("\n=== ZONE x SEASON BIAS ===")
print(df.pivot_table(index='z',columns='season',values='r',aggfunc='mean').round(1).to_string())
print("\n=== ZONE x SEASON MAE ===")
print(df.pivot_table(index='z',columns='season',values='ae',aggfunc='mean').round(1).to_string())
# Residual structure: daily mean residual persistence, and common factor
dm = df.groupby(['z','date']).r.mean().unstack(0)
print("\n=== DAILY-MEAN RESIDUAL: lag-1 autocorr per zone (persistence of day-level bias) ===")
ac = dm.apply(lambda s: s.autocorr(1)).sort_values(ascending=False)
print(ac.round(2).to_string())
print("\n=== DAILY-MEAN RESIDUAL: lag-7 autocorr per zone ===")
print(dm.apply(lambda s: s.autocorr(7)).sort_values(ascending=False).round(2).head(12).to_string())
# how much of hourly residual variance is explained by (zone,date) daily mean vs intraday shape
var_tot = df.r.var(); df['rd']=df.groupby(['z','date']).r.transform('mean'); var_day = df.rd.var()
print(f"\n=== VARIANCE DECOMP of residual: total {var_tot:.0f}; day-level component {var_day:.0f} ({var_day/var_tot*100:.0f}%), intraday {var_tot-var_day:.0f} ({(1-var_day/var_tot)*100:.0f}%)")
# common factor across zones (PCA on daily mean residual)
X = dm.fillna(0).values; X = X - X.mean(0)
u,s,vt = np.linalg.svd(X, full_matrices=False); ev = s**2/(s**2).sum()
print("PCA of zone x day residual matrix: explained var PC1..5 =", np.round(ev[:5],3))
print("PC1 loadings:", pd.Series(vt[0],index=dm.columns).round(2).sort_values().to_string())
# Hourly residual persistence: same hour, previous day
df = df.sort_values(['z','h'])
df['r_lag24'] = df.groupby('z').r.shift(24); df['r_lag168']=df.groupby('z').r.shift(168)
print("\n=== HOURLY residual corr with lag-24h / lag-168h (per zone, top) ===")
t = df.groupby('z').apply(lambda g: pd.Series({'lag24':g.r.corr(g.r_lag24),'lag168':g.r.corr(g.r_lag168)}))
print(t.sort_values('lag24',ascending=False).round(2).to_string())
# Persistence-corrected oracle: how much MAE would drop if we subtracted yesterday's same-hour residual? (an upper-ish bound for a lag-legal corrector)
for lag in ['r_lag24','r_lag168']:
    m = df[lag].notna()
    print(f"MAE if subtract {lag} residual (naive): {(df.r[m]-df[lag][m]).abs().mean():.2f} vs raw {df.ae[m].mean():.2f}; half-weight: {(df.r[m]-0.5*df[lag][m]).abs().mean():.2f}")
# Tightness: residual vs load quantile within zone
df['lq']=df.groupby('z')['load'].transform(lambda s: pd.qcut(s.rank(method='first'),5,labels=False))
print("\n=== BIAS by within-zone LOAD QUINTILE (0=low) x group ===")
df['grp']='other'
for k,v in GROUPS.items():
    df.loc[df.z.isin(v),'grp']=k
print(df.pivot_table(index='grp',columns='lq',values='r',aggfunc='mean').round(1).to_string())
print(df.pivot_table(index='grp',columns='lq',values='ae',aggfunc='mean').round(1).to_string())
# Extreme-day list: days with the highest footprint MAE
dd = df.groupby('date').apply(lambda g: pd.Series({'MAE':g.ae.mean(),'bias':g.r.mean(),'act':g.act.mean()}))
print("\n=== WORST 15 DAYS (footprint MAE) ===")
print(dd.sort_values('MAE',ascending=False).head(15).round(1).to_string())
print("\n=== DAILY MAE distribution: median", round(dd.MAE.median(),1), "p90", round(dd.MAE.quantile(.9),1), "share of |err| from worst 10% days:", round(df[df.date.isin(dd[dd.MAE>=dd.MAE.quantile(.9)].index)].ae.sum()/tot*100,1),'%')
