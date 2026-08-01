#!/usr/bin/env python3
"""Add the #280 meta-driven wiring keys ('pilot_zones' + 'winners') to the staged
meta.json, so bin/ml_inputs.jl's ml_pilot_zones()/ml_use_new() resolve the whole
39-zone rollout at run time (no const edits)."""
import json
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
STAGE=f"{SP}/input_models_stage"
geom=json.load(open(f"{SP}/geom39.json"))
win39={tuple(k.split("|")):v for k,v in json.load(open(f"{SP}/winners39.json")).items()}
PILOT_WIN={("ES","load"):True,("ES","solar"):False,("ES","wind"):False,
 ("DE_LU","load"):True,("DE_LU","solar"):True,("DE_LU","wind"):False,
 ("SE2","load"):True,("SE2","solar"):True,("SE2","wind"):False,
 ("NL","load"):True,("NL","solar"):True,("NL","wind"):True}
TARGETS=["load","solar","wind"]
winners={}
for z in sorted(geom):
    for t in TARGETS:
        if (z,t) in PILOT_WIN: v=PILOT_WIN[(z,t)]
        elif (z,t) in win39: v=win39[(z,t)]
        else: v=False   # skip (no-resource) or untrained -> pack
        winners[f"{z}_{t}"]=bool(v)
pilot_zones=sorted({z for z in geom if any(winners[f"{z}_{t}"] for t in TARGETS)})

meta=json.load(open(f"{STAGE}/meta.json"))
# sanity: every committed model entry must be a winner
model_keys=[k for k in meta if "_" in k and k.split("_")[-1] in TARGETS and isinstance(meta[k],dict) and "feat_cols" in meta[k]]
for k in model_keys:
    assert winners.get(k) is True, f"committed model {k} but winners says {winners.get(k)}"
for k,v in winners.items():
    if v: assert k in meta, f"winner {k} but no committed model entry"
meta["pilot_zones"]=pilot_zones
meta["winners"]=winners
json.dump(meta,open(f"{STAGE}/meta.json","w"),indent=0)
nn=sum(winners.values())
print(f"pilot_zones ({len(pilot_zones)}):",pilot_zones)
print(f"winners: {nn} NEW / {len(winners)} total ; committed model entries: {len(model_keys)}")
print("AUGMENT_OK")
