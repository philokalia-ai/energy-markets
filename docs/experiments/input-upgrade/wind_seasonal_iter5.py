#!/usr/bin/env python3
"""fit-iteration 5: seasonal wind-level calibration probe (R3). Measure the SHIPPED
wind prediction's relative volume bias per zone on the fit-iteration-4 VALID
(2026-06-15..07-27), split by month, and run a cross-month held-out test: fit a
multiplicative level term on one month, verify it reduces |bias| on the OTHER month
without hurting corr (scale-invariant). Ship a month-of-year multiplier only if it
verifies out-of-sample on >=15 zones; else NO-SHIP honestly."""
import json, numpy as np, pandas as pd, sys
SP=sys.argv[1] if len(sys.argv)>1 else \
  "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
vp=pd.read_parquet(f"{SP}/valid_preds39.parquet"); vp["h"]=pd.to_datetime(vp["h"])
win={tuple(k.split("|")):v for k,v in json.load(open(f"{SP}/winners39.json")).items()}
w=vp[vp.target=="wind"].copy(); w["mon"]=w["h"].dt.month
def relbias(p,t):
    st=t.sum(); return float((p.sum()-t.sum())/st) if st>0 else float("nan")
def corr(p,t):
    m=~(np.isnan(p)|np.isnan(t)); p,t=p[m],t[m]
    return float(np.corrcoef(p,t)[0,1]) if len(p)>5 and np.std(p)>0 and np.std(t)>0 else float("nan")

rows=[]; verify=[]
print("zone        ship  n     relbias_all  relbias_Jun  relbias_Jul   corr   |  xmonth-heldout dMAErel")
for z in sorted(w.zone.unique()):
    d=w[w.zone==z]
    if len(d)<200: continue
    ship_new=win.get((z,"wind"))
    pred = d.pred_new.values if ship_new else d.pred_pack.values
    tgt=d.tgt.values
    if np.all(np.isnan(pred)): pred=d.pred_pack.values   # safety
    jun=d[d.mon==6]; jul=d[d.mon==7]
    pj=(jun.pred_new.values if ship_new else jun.pred_pack.values); tj=jun.tgt.values
    pk=(jul.pred_new.values if ship_new else jul.pred_pack.values); tk=jul.tgt.values
    rb=relbias(pred,tgt); rbj=relbias(pj,tj); rbk=relbias(pk,tk)
    # cross-month held-out: multiplier fit on Jun, tested on Jul (and vice versa)
    def mae(p,t): return float(np.mean(np.abs(p-t)))
    dmae=float("nan")
    if len(tj)>20 and len(tk)>20 and pj.sum()>0 and pk.sum()>0:
        m_jun=tj.sum()/pj.sum()          # multiplier that zeroes Jun bias
        m_jul=tk.sum()/pk.sum()
        # apply Jun-fit multiplier to Jul (held out) and Jul-fit to Jun; avg rel dMAE
        d1=(mae(pk*m_jun,tk)-mae(pk,tk))/max(mae(pk,tk),1e-6)
        d2=(mae(pj*m_jul,tj)-mae(pj,tj))/max(mae(pj,tj),1e-6)
        dmae=0.5*(d1+d2)
        verify.append((z,dmae,m_jun,m_jul))
    print(f"  {z:10s} {'NEW ' if ship_new else 'pack'} {len(d):5d}  {rb:+10.3f}  {rbj:+10.3f}  {rbk:+10.3f}  {corr(pred,tgt):.3f}  |  {dmae:+.3f}")
    rows.append(dict(zone=z,ship='NEW' if ship_new else 'pack',relbias_all=rb,relbias_jun=rbj,relbias_jul=rbk,xmonth_dmae=dmae))

# decision
helped=[v for v in verify if v[1]<-1e-3]              # cross-month correction reduced MAE
consistent=[v for v in verify if abs(v[2]-v[3])<0.05] # Jun & Jul multipliers agree within 5%
print(f"\nzones with a cross-month test: {len(verify)}")
print(f"  cross-month multiplier REDUCES held-out MAE: {len(helped)}/{len(verify)}")
print(f"  Jun & Jul multipliers agree within 5%: {len(consistent)}/{len(verify)}")
print(f"  mean |relbias_all| over shipped wind zones: {np.nanmean([abs(r['relbias_all']) for r in rows]):.3f}")
ship = len(helped)>=15 and len(consistent)>=15
print(f"\nDECISION: {'SHIP month multiplier' if ship else 'NO-SHIP (does not verify out-of-sample)'}")
json.dump(dict(rows=rows,helped=len(helped),consistent=len(consistent),nverify=len(verify),ship=ship),
          open(f"{SP}/wind_seasonal_iter5.json","w"),indent=1)
print("WIND_SEASONAL_DONE")
