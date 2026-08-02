#!/usr/bin/env python3
"""fit-iteration 4 before/after scorecard summary + solar collapse view."""
import json, numpy as np, pandas as pd, sys
SP=sys.argv[1] if len(sys.argv)>1 else \
  "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
vp=pd.read_parquet(f"{SP}/valid_preds39.parquet")
win={tuple(k.split("|")):v for k,v in json.load(open(f"{SP}/winners39.json")).items()}
def mae(p,t): return float(np.mean(np.abs(p-t)))
def bias(p,t): return float(np.mean(p-t))
def corr(p,t):
    m=~(np.isnan(p)|np.isnan(t)); p,t=p[m],t[m]
    return float(np.corrcoef(p,t)[0,1]) if len(p)>5 and np.std(p)>0 and np.std(t)>0 else float("nan")

print("="*72); print("HEADLINE ZONES — NEW vs old(committed) vs pack on the fresh VALID tail")
print("="*72)
for z in ["GR","PL","FR"]:
    for t in ["load","solar","wind"]:
        d=vp[(vp.zone==z)&(vp.target==t)]
        if d.empty: continue
        w="NEW" if win.get((z,t)) else "pack"
        on=(f"old {mae(d.pred_old.values,d.tgt.values):8.1f}/{corr(d.pred_old.values,d.tgt.values):.3f}"
            if not np.all(np.isnan(d.pred_old.values)) else "old      n/a")
        print(f"  {z:4s} {t:5s} ship={w:4s} | NEW {mae(d.pred_new.values,d.tgt.values):8.1f}/{corr(d.pred_new.values,d.tgt.values):.3f}"
              f" | {on} | pack {mae(d.pred_pack.values,d.tgt.values):8.1f}/{corr(d.pred_pack.values,d.tgt.values):.3f}")
print("  DE_LU — preserved pilot (not re-swept; geom/lineage differ from geom39)")

print("\n"+"="*72); print("STALENESS GAIN — NEW(iter4) vs old(committed) on the fresh VALID, per winner")
print("="*72)
rows=[]
for (z,t),wv in win.items():
    if not wv: continue
    d=vp[(vp.zone==z)&(vp.target==t)]
    if d.empty or np.all(np.isnan(d.pred_old.values)): continue
    nm=mae(d.pred_new.values,d.tgt.values); om=mae(d.pred_old.values,d.tgt.values)
    rows.append((z,t,nm,om,nm-om))
imp=[r for r in rows if r[4]<-1e-6]; wor=[r for r in rows if r[4]>1e-6]
print(f"  winners with a committed predecessor scored: {len(rows)}")
print(f"  NEW better than old (MAE):  {len(imp)}   NEW worse: {len(wor)}   ~equal: {len(rows)-len(imp)-len(wor)}")
print(f"  mean ΔMAE (new-old) over these winners: {np.mean([r[4] for r in rows]):+.2f} MW")
print("  biggest improvements:")
for z,t,nm,om,d in sorted(rows,key=lambda r:r[4])[:6]:
    print(f"     {z:12s} {t:5s} old {om:8.1f} -> new {nm:8.1f}  ({d:+.1f})")

print("\n"+"="*72); print("SOLAR COLLAPSE VIEW — continental-solar NEW winners (under-forecast = conservative)")
print("="*72)
CONT=["DE_LU","FR","PL","BE","CZ","CH"]
print("  zone   ship  NEW bias   old bias   NEW mae   old mae   NEW corr  (bias<0 helps crash-detection)")
for z in CONT:
    d=vp[(vp.zone==z)&(vp.target=="solar")]
    if d.empty:
        note = "pack (FR solar)" if z=="FR" else ("preserved pilot" if z=="DE_LU" else "no NEW solar")
        print(f"  {z:6s} {note}"); continue
    w="NEW" if win.get((z,"solar")) else "pack"
    nb=bias(d.pred_new.values,d.tgt.values); ob=bias(d.pred_old.values,d.tgt.values)
    nm=mae(d.pred_new.values,d.tgt.values); om=mae(d.pred_old.values,d.tgt.values)
    print(f"  {z:6s} {w:4s}  {nb:+8.1f}   {ob:+8.1f}   {nm:7.1f}   {om if not np.isnan(om) else float('nan'):7.1f}   {corr(d.pred_new.values,d.tgt.values):.3f}")
print("SUMMARY_DONE")
