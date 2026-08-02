#!/usr/bin/env python3
"""fit-iteration 4 assembly: build the committed bin/input_models/ from the freshly
retrained (GR + 34 new) winners plus the 4 preserved pilots (ES/DE_LU/SE2/NL, kept
verbatim from the current commit — their geom/lineage differs from geom39 so they are
not re-swept, exactly the train39+wire design). Winners-only .txt; emits a staging dir,
the ML_USE_NEW Julia constant, and a winner-churn diff vs the currently-committed map.
Replaces the stale wire_ml.py (its PILOT_WIN predated iteration 1's NL_solar demotion)."""
import json, os, shutil, sys
SP=sys.argv[1] if len(sys.argv)>1 else \
  "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
BIN="/home/pgeorgakopoulos/armada/energy-markets/bin"
COMMITTED=f"{BIN}/input_models"
STAGE=f"{SP}/input_models_stage"
TARGETS=["load","solar","wind"]
PILOTS=["ES","DE_LU","SE2","NL"]

win39={tuple(k.split("|")):v for k,v in json.load(open(f"{SP}/winners39.json")).items()}
meta39=json.load(open(f"{SP}/models39/meta.json"))
geom39=json.load(open(f"{SP}/geom39.json"))
cmeta=json.load(open(f"{COMMITTED}/meta.json")); cwin=cmeta["winners"]

if os.path.exists(STAGE): shutil.rmtree(STAGE)
os.makedirs(STAGE)

ZONES=sorted(geom39)                       # all 39
retrained=[z for z in ZONES if z not in PILOTS]
final_meta={}; winners={}; use_new={}

def geom_flag(z,t):
    return True if t=="load" else bool(geom39[z].get(t,True))

# retrained (GR + 34 new)
for z in retrained:
    for t in TARGETS:
        w=win39.get((z,t))
        if not geom_flag(z,t) or w is None:      # no-resource or untrained -> pack
            winners[f"{z}_{t}"]=False; use_new[(z,t)]=False; continue
        winners[f"{z}_{t}"]=bool(w); use_new[(z,t)]=bool(w)
        if w:
            shutil.copy(f"{SP}/models39/{z}_{t}.txt", f"{STAGE}/{z}_{t}.txt")
            final_meta[f"{z}_{t}"]=meta39[f"{z}_{t}"]
# preserved pilots (verbatim from the current commit)
for z in PILOTS:
    for t in TARGETS:
        w=bool(cwin.get(f"{z}_{t}",False)); winners[f"{z}_{t}"]=w; use_new[(z,t)]=w
        if w:
            shutil.copy(f"{COMMITTED}/{z}_{t}.txt", f"{STAGE}/{z}_{t}.txt")
            final_meta[f"{z}_{t}"]=cmeta[f"{z}_{t}"]

ml_zones=sorted({z for (z,t),v in use_new.items() if v})
final_meta["pilot_zones"]=ml_zones
final_meta["winners"]=winners
json.dump(final_meta,open(f"{STAGE}/meta.json","w"),indent=0)

# ML_USE_NEW Julia constant (pilot zones only, all 3 targets)
def jb(b): return "true" if b else "false"
lines=["const ML_USE_NEW = Dict{Tuple{String,Symbol},Bool}("]
for z in ml_zones:
    trip=", ".join(f'("{z}", :{t}) => {jb(use_new[(z,t)])}' for t in TARGETS)
    lines.append(f"    {trip},")
lines.append(")")
open(f"{SP}/ml_use_new_iter4.jl.txt","w").write("\n".join(lines))

# churn vs currently-committed winners
flips=[]
for z in ZONES:
    for t in TARGETS:
        old=bool(cwin.get(f"{z}_{t}",False)); new=winners[f"{z}_{t}"]
        if old!=new: flips.append((z,t,old,new))
json.dump([dict(zone=z,target=t,old=o,new=n) for z,t,o,n in flips],
          open(f"{SP}/winner_flips_iter4.json","w"),indent=1)

print(f"retrained zones={len(retrained)} pilots preserved={len(PILOTS)}")
print(f"ML zones (>=1 NEW winner)={len(ml_zones)}")
print(f"NEW winners={sum(1 for v in winners.values() if v)} / {len(winners)} targets")
print(f"committed NEW winners={sum(1 for v in cwin.values() if v)}")
print(f"winner FLIPS vs commit={len(flips)}:")
for z,t,o,n in flips: print(f"   {z:12s} {t:5s} {'NEW' if o else 'pack'} -> {'NEW' if n else 'pack'}")
print(f"staging {STAGE}: {len([f for f in os.listdir(STAGE) if f.endswith('.txt')])} txt")
print("ASSEMBLE_DONE")
