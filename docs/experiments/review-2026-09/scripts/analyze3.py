import pandas as pd, numpy as np, os
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 200)
S=os.environ['S']
df = pd.read_parquet(S+'/cv37_joined.parquet'); df['hr']=df.h.dt.hour; df['ym']=df.h.dt.year*100+df.h.dt.month; df['date']=df.h.dt.date
ttf=pd.read_parquet(S+'/ttf.parquet'); ttf['date']=pd.to_datetime(ttf.date); eua=pd.read_parquet(S+'/eua.parquet'); eua['date']=pd.to_datetime(eua.date)
print("TTF rows per month 2026:", ttf[ttf.date>='2026-01-01'].groupby(ttf.date.dt.to_period('M')).size().to_dict())
print("TTF monthly mean 2026:", ttf[ttf.date>='2026-01-01'].groupby(ttf.date.dt.to_period('M')).close.mean().round(1).to_dict())
d = df[df.z=='DE_LU'].copy()
for ym in [202508, 202608]:
    x = d[d.ym==ym].groupby('hr').agg(act=('act','mean'),sim=('sim','mean'),sim_max=('sim','max'),act_max=('act','max')).round(0)
    print(f"\n=== DE_LU hourly profile {ym} ===\n", x.T.to_string())
# daily: max sim vs gas srmc from D-2 close
dd = d.groupby('date').agg(sim_max=('sim','max'),sim_p90=('sim',lambda s:s.quantile(.9)),act_max=('act','max'),sim_mean=('sim','mean'),act_mean=('act','mean'))
dd.index=pd.to_datetime(dd.index)
tt = ttf.set_index('date').close; ee=eua.set_index('date').close
# D-2 close: last close strictly before D-1
def lastclose(s, day): 
    v = s[s.index < day - pd.Timedelta(days=1)]
    return v.iloc[-1] if len(v) else np.nan
dd['ttf']=[lastclose(tt,x) for x in dd.index]; dd['eua']=[lastclose(ee,x) for x in dd.index]
dd['gas_srmc']=dd.ttf/0.55 + 0.367/0.55*dd.eua + 4; dd['coal_srmc']=37+0.9*dd.eua; dd['lig_srmc']=25+1.25*dd.eua
dd['ym']=dd.index.year*100+dd.index.month
m = dd.groupby('ym')[['sim_max','sim_p90','act_max','sim_mean','act_mean','ttf','eua','gas_srmc','coal_srmc']].mean().round(0)
m['corr_simmean_ttf']=dd.groupby('ym').apply(lambda g: g.sim_mean.corr(g.ttf)).round(2)
m['corr_actmean_ttf']=dd.groupby('ym').apply(lambda g: g.act_mean.corr(g.ttf)).round(2)
print("\n=== DE_LU monthly: daily-max/p90 model price vs gas/coal SRMC at D-2 close ===\n", m.to_string())
# regression over full record: daily mean act ~ gas_srmc, sim ~ gas_srmc (sensitivity)
for col in ['act_mean','sim_mean','act_max','sim_p90']:
    b = np.polyfit(dd.gas_srmc.dropna(), dd.loc[dd.gas_srmc.notna(),col], 1)[0]
    print(f"slope of DE_LU {col} on gas SRMC (full record): {b:.2f}")
x = dd[dd.ym>=202606]
for col in ['act_mean','sim_mean','act_max','sim_p90']:
    b = np.polyfit(x.gas_srmc.dropna(), x.loc[x.gas_srmc.notna(),col], 1)[0]
    print(f"slope of DE_LU {col} on gas SRMC (2026-06..08): {b:.2f}")
# Belt zones evening in Aug 2026
print("\n=== 2026-08 17-20 UTC: settled vs model, selected zones ===")
e = df[(df.ym==202608)&(df.hr>=17)&(df.hr<=20)].groupby('z').agg(act=('act','mean'),sim=('sim','mean'),act_max=('act','max'),sim_max=('sim','max')).round(0)
print(e.loc[['DE_LU','FR','NL','AT','CZ','PL','HU','SK','SI','RO','BG','GR','IT-NORTH','CH']].T.to_string())
# How often is the model's DE_LU price within +-10% of gas SRMC vs coal SRMC (which fuel is at the margin), by half-year
dh = d.merge(dd[['gas_srmc','coal_srmc','lig_srmc']], left_on=pd.to_datetime(d.date), right_index=True)
dh['half']=dh.h.dt.year*10+(dh.h.dt.month>6).astype(int)
dh['near_gas']=(dh.sim-dh.gas_srmc).abs()<0.15*dh.gas_srmc; dh['near_coal']=(dh.sim-dh.coal_srmc).abs()<0.15*dh.coal_srmc
dh['act_near_gas']=(dh.act-dh.gas_srmc).abs()<0.15*dh.gas_srmc; dh['act_above_gas']=dh.act>1.15*dh.gas_srmc; dh['sim_above_gas']=dh.sim>1.15*dh.gas_srmc
print("\n=== DE_LU: share of hours where price is within 15% of gas SRMC / coal SRMC / above 1.15x gas, model vs settled ===")
print(dh.groupby('half')[['near_gas','act_near_gas','near_coal','sim_above_gas','act_above_gas']].mean().round(2).to_string())
