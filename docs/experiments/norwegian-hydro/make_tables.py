import pandas as pd, numpy as np
D="docs/experiments/norwegian-hydro/data"
sim=pd.read_csv(f"{D}/sim_cv22.csv"); act=pd.read_csv(f"{D}/actual.csv")
sim['slot']=pd.to_datetime(sim['slot']); act['slot']=pd.to_datetime(act['slot'])
sw=sim.pivot_table(index='slot',columns='zone',values='price')
aw=act.pivot_table(index='slot',columns='zone',values='price')
def stat(s,a):
    df=pd.DataFrame({'s':s,'a':a}).dropna(); d=df.s-df.a
    c=np.corrcoef(df.s,df.a)[0,1] if df.s.std()>1e-9 else 0.0
    return len(df),round(c,3),round(d.abs().mean(),1),round(d.mean(),1),round(df.a.mean(),1),round(df.s.mean(),1)
rows=[]
for z in ['NO1','NO2','NO3','NO4','NO5','SE1','SE2','SE3','SE4','DK1','DE_LU','NL']:
    n,c,mae,b,am,smn=stat(sw[z],aw[z]); rows.append([z,n,c,mae,b,am,smn])
pd.DataFrame(rows,columns=['zone','n','corr','mae','bias','act_mean','sim_mean']).to_csv(f"{D}/T1_zone_stats.tsv",sep='\t',index=False)
mrows=[]
for z in ['NO1','NO3','NO5']:
    j=pd.DataFrame({'s':sw[z],'a':aw[z]}).dropna(); j['m']=j.index.strftime('%Y-%m')
    for m,g in j.groupby('m'):
        d=g.s-g.a; c=np.corrcoef(g.s,g.a)[0,1] if g.s.std()>1e-9 else 0
        mrows.append([z,m,len(g),round(c,2),round(d.abs().mean(),1),round(d.mean(),1),round(g.a.mean(),1),round(g.s.mean(),1)])
pd.DataFrame(mrows,columns=['zone','month','n','corr','mae','bias','act_mean','sim_mean']).to_csv(f"{D}/T2_monthly.tsv",sep='\t',index=False)
crows=[]
for z in ['NO1','NO3','NO5']:
    crows.append([z,'own']+list(stat(sw[z],aw[z])))
    crows.append([z,'priced_as_NO2']+list(stat(sw['NO2'],aw[z])))
    crows.append([z,'realized_corr_with_NO2','',round(aw[z].corr(aw['NO2']),3),'','','',''])
pd.DataFrame(crows,columns=['zone','variant','n','corr','mae','bias','act_mean','sim_mean']).to_csv(f"{D}/T3_no2_counterfactual.tsv",sep='\t',index=False)
j=pd.DataFrame({'s':sw['NO1'],'a':aw['NO1']}).dropna(); nm=j[j.index.strftime('%Y-%m')!='2026-05']
with open(f"{D}/T4_may_and_reservoir.tsv",'w') as f:
    f.write("metric\tvalue\n")
    d=j.s-j.a; f.write(f"NO1_all_corr\t{np.corrcoef(j.s,j.a)[0,1]:.3f}\nNO1_all_mae\t{d.abs().mean():.1f}\nNO1_all_bias\t{d.mean():.1f}\n")
    dn=nm.s-nm.a; f.write(f"NO1_exclMay_corr\t{np.corrcoef(nm.s,nm.a)[0,1]:.3f}\nNO1_exclMay_mae\t{dn.abs().mean():.1f}\nNO1_exclMay_bias\t{dn.mean():.1f}\n")
    may=j[j.index.strftime('%Y-%m')=='2026-05']; f.write(f"NO1_May_sim_mean\t{may.s.mean():.0f}\nNO1_May_act_mean\t{may.a.mean():.0f}\n")
    f.write(f"NO1_May_capdays_sim_gt200\t{(may.groupby(may.index.date).s.mean()>200).sum()}\n")
    res=pd.read_csv(f"{D}/reservoir.csv"); r1=res[res.zone=='NO1'].copy()
    aw1=aw[['NO1']].copy(); aw1['year']=aw1.index.isocalendar().year; aw1['week']=aw1.index.isocalendar().week
    mm=aw1.reset_index().merge(r1[['year','week','stored_energy_mwh']],on=['year','week'],how='left')
    mm['lvl']=pd.cut(mm.stored_energy_mwh,3,labels=['low(drawn-down)','mid','high(full)'])
    for lv,g in mm.groupby('lvl',observed=True):
        f.write(f"NO1_realized_price_reservoir_{lv}\t{g.NO1.mean():.1f}\n")
print("tables written")
