#!/usr/bin/env python3
"""Assemble the committed bin/input_models/ from the rollout-39 winners + the
unchanged pilot models, winners-only. Emits staging dir + Julia constants +
winners/losers tables. Idempotent."""
import json, os, shutil
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
WT="/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a534d70e414d18b80"
COMMITTED=f"{WT}/bin/input_models"          # existing pilot dir (source for pilot winners)
STAGE=f"{SP}/input_models_stage"
if os.path.exists(STAGE): shutil.rmtree(STAGE)
os.makedirs(STAGE)

TARGETS=["load","solar","wind"]
win39={tuple(k.split("|")):v for k,v in json.load(open(f"{SP}/winners39.json")).items()}
meta39=json.load(open(f"{SP}/models39/meta.json"))
geom39=json.load(open(f"{SP}/geom39.json"))
# unchanged pilots (shipped in #252) — preserved verbatim
PILOT_WIN={("ES","load"):True,("ES","solar"):False,("ES","wind"):False,
 ("DE_LU","load"):True,("DE_LU","solar"):True,("DE_LU","wind"):False,
 ("SE2","load"):True,("SE2","solar"):True,("SE2","wind"):False,
 ("NL","load"):True,("NL","solar"):True,("NL","wind"):True}
PILOTS_UNCHANGED=["ES","DE_LU","SE2","NL"]
committed_meta=json.load(open(f"{COMMITTED}/meta.json"))
committed_geom=json.load(open(f"{COMMITTED}/geom.json"))

# geom: pilot entries verbatim (schema: cells,cities,wind,solar,cdh_base) + 34 new
final_geom=dict(committed_geom)   # GR,ES,DE_LU,SE2,NL exactly as shipped
NEW_ZONES=[z for z in geom39 if z not in final_geom]
for z in NEW_ZONES:
    g=geom39[z]
    final_geom[z]={"cells":g["cells"],"cities":g["cities"],
                   "wind":g["wind"],"solar":g["solar"],"cdh_base":g["cdh_base"]}

# assemble winners: source txt + meta per (zone,target)
final_meta={}; use_new={}; skipped=[]
def all_zone_targets(z):
    # every (z,target); solar/wind absent -> skip (pack/zero); else per winner
    return TARGETS
def geom_flag(z,t):
    if t=="load": return True
    return bool(final_geom[z].get(t,True))

# GR + 34 new (retrained)
retrained=["GR"]+NEW_ZONES
for z in retrained:
    for t in TARGETS:
        if not geom_flag(z,t):
            use_new[(z,t)]=False; skipped.append((z,t,"skip:no-resource")); continue
        w=win39.get((z,t))
        if w is None:      # target not trained (e.g. too few rows) -> pack
            use_new[(z,t)]=False; skipped.append((z,t,"skip:untrained")); continue
        use_new[(z,t)]=bool(w)
        if w:
            shutil.copy(f"{SP}/models39/{z}_{t}.txt", f"{STAGE}/{z}_{t}.txt")
            final_meta[f"{z}_{t}"]=meta39[f"{z}_{t}"]
# unchanged pilots
for z in PILOTS_UNCHANGED:
    for t in TARGETS:
        w=PILOT_WIN[(z,t)]; use_new[(z,t)]=w
        if w:
            shutil.copy(f"{COMMITTED}/{z}_{t}.txt", f"{STAGE}/{z}_{t}.txt")
            final_meta[f"{z}_{t}"]=committed_meta[f"{z}_{t}"]

json.dump(final_meta,open(f"{STAGE}/meta.json","w"),indent=0)
json.dump(final_geom,open(f"{STAGE}/geom.json","w"))

# ML_PILOT_ZONES = zones with >=1 NEW winner
ml_zones=sorted({z for (z,t),w in use_new.items() if w})
# Julia constant emission
def jl_bool(b): return "true" if b else "false"
lines=[]
lines.append('const ML_PILOT_ZONES = ['+", ".join(f'"{z}"' for z in ml_zones)+']')
lines.append("const ML_USE_NEW = Dict{Tuple{String,Symbol},Bool}(")
for z in ml_zones:
    trip=", ".join(f'("{z}", :{t}) => {jl_bool(use_new[(z,t)])}' for t in TARGETS)
    lines.append(f"    {trip},")
lines.append(")")
open(f"{SP}/ml_use_new.jl.txt","w").write("\n".join(lines))

# winners table (markdown) + losers list
sc=None
import csv
rows=list(csv.DictReader(open(f"{SP}/scorecard39.csv")))
bykey={}
for r in rows:
    bykey.setdefault((r["zone"],r["target"]),{})[r["model"]]=r
def fmt(x):
    try: return f'{float(x):.1f}'
    except: return "-"
wtab=["| zone | target | NEW MAE | pack MAE | NEW corr | pack corr | ship |",
      "|---|---|--:|--:|--:|--:|---|"]
n_new=0; n_pack=0; n_skip=0
for z in ml_zones+[zz for zz in sorted(final_geom) if zz not in ml_zones]:
    for t in TARGETS:
        w=use_new.get((z,t))
        if (z,t) in bykey:
            nk=bykey[(z,t)].get("NEW",{}); pk=bykey[(z,t)].get("pack",{})
            ship="**NEW**" if w else "pack"
            wtab.append(f"| {z} | {t} | {fmt(nk.get('mae'))} | {fmt(pk.get('mae'))} | {fmt(nk.get('corr'))} | {fmt(pk.get('corr'))} | {ship} |")
        else:
            reason=next((rz[2] for rz in skipped if rz[0]==z and rz[1]==t),"pack(pilot/other)")
            wtab.append(f"| {z} | {t} | - | - | - | - | {reason} |")
        if w: n_new+=1
        elif (z,t) in use_new: n_pack+=1
open(f"{SP}/winners_table.md","w").write("\n".join(wtab))

print("ML zones (>=1 NEW winner):",len(ml_zones))
print("NEW winners:",sum(1 for v in use_new.values() if v),
      " pack:",sum(1 for v in use_new.values() if not v))
print("skipped (no-resource/untrained):",len(skipped))
for s in skipped: print("   skip",s)
print("staging:",STAGE,"->", len(os.listdir(STAGE)),"files")
print("WIRE_DONE")
