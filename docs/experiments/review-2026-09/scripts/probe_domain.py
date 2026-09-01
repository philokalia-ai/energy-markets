import os, psycopg2, pandas as pd, numpy as np
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 100)
c = psycopg2.connect(os.environ['ENERGY_CONN_STR']); S=os.environ['S']
def q(s): return pd.read_sql(s,c)
CORE=['AT','BE','CZ','DE_LU','FR','HR','HU','NL','PL','RO','SI','SK']
col={'AT':'ptdf_at','BE':'ptdf_be','CZ':'ptdf_cz','DE_LU':'ptdf_de','FR':'ptdf_fr','HR':'ptdf_hr','HU':'ptdf_hu','NL':'ptdf_nl','PL':'ptdf_pl','RO':'ptdf_ro','SI':'ptdf_si','SK':'ptdf_sk'}
days=['2024-12-12','2025-01-20','2025-02-12','2025-11-25','2025-07-16','2025-10-08','2026-01-14','2025-04-09','2024-09-03','2025-12-03']
hours=[17,18,12,3]
rows=[]
for d in days:
    for hh in hours:
        mtu=f"{d} {hh:02d}:00:00+00"
        dom=q(f"select cne_name,cont_name,direction,tso,ram,fmax,presolved,{','.join(col.values())} from jao.final_domain where mtu='{mtu}' and presolved")
        fl=q(f"""select source_zone s, sink_zone k, flow_mw f from simulations.transmission_flows where code_version=37 and clearing_mode='multi_zone_eu' and date_time_utc='{d} {hh:02d}:00:00'""")
        if len(dom)==0 or len(fl)==0: rows.append((d,hh,len(dom),len(fl),None,None,None,None)); continue
        fl=fl[fl.s.isin(CORE)&fl.k.isin(CORE)]
        np_={z:0.0 for z in CORE}
        for r in fl.itertuples(): np_[r.s]+=r.f; np_[r.k]-=r.f
        npv=np.array([np_[z] for z in CORE]); P=dom[[col[z] for z in CORE]].values
        flow=P@npv; viol=flow-dom.ram.values; 
        nviol=(viol>0).sum(); worst=viol.max(); share=nviol/len(dom)
        top=dom.iloc[viol.argmax()]
        rows.append((d,hh,len(dom),len(fl),nviol,round(share,3),round(worst),f"{top.tso}:{top.cne_name[:28]}|{top.cont_name[:20]} ram={top.ram:.0f}"))
        if hh==17: print(d,hh,'NP model:',{z:round(v) for z,v in np_.items()})
out=pd.DataFrame(rows,columns=['day','hr','n_presolved_cnec','n_flows','n_violated','share_violated','worst_MW','worst_cnec'])
print(out.to_string())
