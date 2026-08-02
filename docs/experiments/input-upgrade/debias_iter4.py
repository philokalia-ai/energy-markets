#!/usr/bin/env python3
"""fit-iteration 3 re-fit on the fit-iteration-4 VALID tail (2026-06-15..07-27).
Level debias (b=1, a=-mean bias) for the R2 high-bias NEW-load zones. Fit on the
first 2/3 of VALID, verify on the last 1/3: ship only zones that are (a) a NEW load
winner after the retrain AND (b) improve (or do not worsen) holdout MAE with |bias|
reduced. Emits the LOAD_BIAS_CORRECTION entries + a decision table."""
import json, numpy as np, pandas as pd, sys
SP=sys.argv[1] if len(sys.argv)>1 else \
  "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
CANDIDATES=["FR","IT-NORTH","HU","RO","NO3"]   # R2 named zones
vp=pd.read_parquet(f"{SP}/valid_preds39.parquet"); vp["h"]=pd.to_datetime(vp["h"])
win=json.load(open(f"{SP}/winners39.json")); win={tuple(k.split("|")):v for k,v in win.items()}

def mae(p,t): return float(np.mean(np.abs(p-t)))
def bias(p,t): return float(np.mean(p-t))

ship={}; rows=[]
# report bias for ALL NEW-load winners (transparency) ...
load=vp[vp.target=="load"].copy()
allbias=[]
for z in sorted(load.zone.unique()):
    if not win.get((z,"load")): continue
    d=load[load.zone==z]
    allbias.append((z,bias(d.pred_new.values,d.tgt.values),mae(d.pred_new.values,d.tgt.values),len(d)))
allbias.sort(key=lambda r:-r[1])
print("NEW-load winners VALID bias (top by +bias):")
for z,b,m,n in allbias[:12]: print(f"   {z:12s} bias={b:+8.1f} mae={m:8.1f} n={n}")

print("\n=== affine debias re-fit (candidates, out-of-sample gate) ===")
for z in CANDIDATES:
    if not win.get((z,"load")):
        print(f"  {z:12s} SKIP (not a NEW load winner after retrain -> pack path)"); continue
    d=load[load.zone==z].sort_values("h")
    if len(d)<100: print(f"  {z:12s} SKIP (too few VALID rows {len(d)})"); continue
    cut=d["h"].quantile(0.667)
    fit=d[d["h"]<=cut]; hold=d[d["h"]>cut]
    a=-bias(fit.pred_new.values,fit.tgt.values)   # level-only (b=1)
    raw_mae=mae(hold.pred_new.values,hold.tgt.values)
    cor=np.maximum(hold.pred_new.values+a,0.0)
    cor_mae=mae(cor,hold.tgt.values)
    raw_b=bias(hold.pred_new.values,hold.tgt.values); cor_b=bias(cor,hold.tgt.values)
    ok = (cor_mae<=raw_mae+1e-9) and (abs(cor_b)<abs(raw_b))
    # ship 'a' fit on the FULL VALID (best level estimate) once the holdout gate passes
    a_full=-bias(d.pred_new.values,d.tgt.values)
    print(f"  {z:12s} a_fit={a:+8.1f} holdout raw_mae={raw_mae:8.1f} cor_mae={cor_mae:8.1f} "
          f"dMAE={cor_mae-raw_mae:+6.1f} bias {raw_b:+.1f}->{cor_b:+.1f}  a_ship={a_full:+.1f}  {'SHIP' if ok else 'no-ship'}")
    rows.append(dict(zone=z,a_fit=a,raw_mae=raw_mae,cor_mae=cor_mae,dmae=cor_mae-raw_mae,
                     raw_bias=raw_b,cor_bias=cor_b,a_ship=a_full,ship=bool(ok)))
    if ok: ship[z]=round(a_full,2)

json.dump(dict(ship=ship,rows=rows),open(f"{SP}/debias_iter4.json","w"),indent=1)
print("\nLOAD_BIAS_CORRECTION (Julia):")
for z,a in ship.items(): print(f'    "{z}" => (a = {a}, b = 1.0),')
print("DEBIAS_DONE")
