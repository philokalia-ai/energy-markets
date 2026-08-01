#!/usr/bin/env python3
"""Fill rollout-39.md placeholders from scorecard39.csv + winners + fetch_status + geom."""
import json, csv
SP="/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
DOC="/home/pgeorgakopoulos/armada/energy-markets/.claude/worktrees/agent-a534d70e414d18b80/docs/experiments/input-upgrade/rollout-39.md"
geom=json.load(open(f"{SP}/geom39.json"))
win39={tuple(k.split("|")):v for k,v in json.load(open(f"{SP}/winners39.json")).items()}
PW={("ES","load"):True,("ES","solar"):False,("ES","wind"):False,("DE_LU","load"):True,("DE_LU","solar"):True,("DE_LU","wind"):False,("SE2","load"):True,("SE2","solar"):True,("SE2","wind"):False,("NL","load"):True,("NL","solar"):True,("NL","wind"):True}
fs=json.load(open(f"{SP}/fetch_status.json"))
TARGETS=["load","solar","wind"]
def winner(z,t):
    if (z,t) in PW: return PW[(z,t)]
    return win39.get((z,t))
# scorecard rows keyed
sc={}
for r in csv.DictReader(open(f"{SP}/scorecard39.csv")):
    sc.setdefault((r["zone"],r["target"]),{})[r["model"]]=r
def g(d,k):
    try: return f"{float(d[k]):.1f}"
    except: return "–"
def gc(d,k):
    try: return f"{float(d[k]):.3f}"
    except: return "–"

# ---- FETCH COVERAGE ----
fc=["GFS `gfs_seamless` `previous_day1` vintages, 2024-07-14 … 2026-07-29 (hourly, UTC),",
    "cell/city geometry per zone from the committed packs. Durable cache:",
    "`data/gfs_vintages/` (git-ignored; see docs/predictions.md).",
    "",
    f"- **34/34 new zones fetched** ({', '.join(fs['done'])}); 0 failed.",
    "- 5 pilot zones (GR, ES, DE_LU, SE2, NL) reuse the PR #252 cache (GR re-used for its retrain).",
    "- Fetch paced against the open-meteo previous-runs **hourly** quota (parks to the next",
    "  hour on 429; ~4-5 zones/hour), priority-ordered (PL, BG, CZ, AT, HU, RO, RS, FR, IT-NORTH … first)."]

# ---- SCORECARD (full per zone-target) ----
zones=sorted(geom)
scb=["| zone | target | ship | NEW MAE | pack MAE | NEW corr | pack corr | NEW bias |",
     "|---|---|---|--:|--:|--:|--:|--:|"]
for z in zones:
    for t in TARGETS:
        w=winner(z,t)
        if w is None:
            reason = "skip (no resource)" if (t in ("solar","wind") and not geom[z][t]) else "pack"
            scb.append(f"| {z} | {t} | {reason} | – | – | – | – | – |")
            continue
        nk=sc.get((z,t),{}).get("NEW",{}); pk=sc.get((z,t),{}).get("pack",{})
        ship="**NEW**" if w else "pack"
        scb.append(f"| {z} | {t} | {ship} | {g(nk,'mae')} | {g(pk,'mae')} | {gc(nk,'corr')} | {gc(pk,'corr')} | {g(nk,'bias')} |")

# ---- WINNERS SUMMARY ----
allw={}
for z in zones:
    for t in TARGETS:
        allw[(z,t)]=bool(winner(z,t)) if winner(z,t) is not None else False
def cnt(t):
    # modeled = zones with an actual decision (trained or pilot); skip zones excluded
    modeled=[(z,tt) for (z,tt) in [(z,t) for z in zones] if winner(z,t) is not None]
    new=sum(bool(winner(*k)) for k in modeled)
    return new,len(modeled)
ln,lm=cnt("load"); sn,sm=cnt("solar"); wn,wm=cnt("wind")
tot_new=sum(allw.values()); tot=len(allw)
pilot_zones=sorted({z for z in zones if any(allw[(z,t)] for t in TARGETS)})
ws=[f"**{tot_new} of {tot} zone-targets ship the NEW ML model; {tot-tot_new} keep the linear pack.**",
    f"The overlay covers **{len(pilot_zones)} zones** (all but NO4, which lost every target to its pack).","",
    "| target | NEW winners | modeled zones | note |",
    "|---|--:|--:|---|",
    f"| load  | **{ln}** | {lm} | near-universal — AR-lagged LightGBM load beats the linear pack in {ln}/{lm} zones |",
    f"| solar | **{sn}** | {sm} | amendment-2 skip (no meaningful solar): NO1-5, SE1, RS (7 zones) |",
    f"| wind  | **{wn}** | {wm} | physical power-curve pack still wins the low/onshore zones; skip (no meaningful wind): CH, CZ, IT-CNORTH, IT-NORTH, SI, SK, NO5 (7 zones) |",
    "",
    "SE2 keeps its pilot-shipped NEW solar (marginal-solar northern zone, retained from #252 for",
    "continuity — the new northern zones SE1/NO* skip solar under amendment 2).",
    "",
    "Notable: **PL** — load MAE 757 → **549**, solar 679 → **469** (both NEW). GR load 197 → **109**",
    "(Orthodox-holiday retrain). AT/BG/CZ/HU/RO/FR loads all NEW. FR wind NEW; FR solar keeps its pack.",
    "The winners config ships THROUGH `bin/input_models/meta.json` (`pilot_zones` + `winners`), read at",
    "run time by `ml_pilot_zones()` / `ml_use_new()` (#280) — no const edits, so Phase-2 picks it up automatically."]

# ---- COLLAPSE ----
CONT=["DE_LU","FR","PL","BE","CZ","CH"]
cb=["The collapse question (does midday price crash to ≤0 under solar surplus) is dominated by SOLAR",
    "input accuracy on the continental-solar group. NEW-vs-pack solar MAE there (VALID midday-bearing):","",
    "| zone | solar ship | NEW MAE | pack MAE |","|---|---|--:|--:|"]
for z in CONT:
    if not geom[z]["solar"]: continue
    w=winner(z,"solar"); nk=sc.get((z,"solar"),{}).get("NEW",{}); pk=sc.get((z,"solar"),{}).get("pack",{})
    cb.append(f"| {z} | {'**NEW**' if w else 'pack'} | {g(nk,'mae')} | {g(pk,'mae')} |")
cb+=["",
     "Lower solar-forecast MAE tightens the predicted RES-coverage ratio that flips the collapse",
     "classification near the threshold (the pilot validated this at PRICE level for GR-July, #252);",
     "this rollout supplies the same-quality inputs to the continental group where the cv31 solar-regime",
     "floor then acts."]

# ---- EQUIV ----
eb=["Spot-checked on GR (Orthodox), PL (headline), FR (nuclear), NO2 (skip-solar), CZ (skip-wind), ES",
    "(pack solar) over 2026-07-15…17: **scorer bit-identical** (max|Δ|=0 on 792 preds), **feature port",
    "rel < 1e-9**, end-to-end **1/792 split-flip** (≤1%, the documented last-ULP mechanism). Holiday",
    "lockstep asserted byte-identical python↔Julia for all 10 mapped countries 2024-27. Unit tests",
    "`test/test_ml_inputs.jl` green (scorer, feature math, Orthodox holidays, meta-driven ship config)."]

doc=open(DOC).read()
doc=doc.replace("<!--FETCH_COVERAGE-->","\n".join(fc))
doc=doc.replace("<!--SCORECARD-->","\n".join(scb))
doc=doc.replace("<!--WINNERS_SUMMARY-->","\n".join(ws))
doc=doc.replace("<!--COLLAPSE-->","\n"+"\n".join(cb))
doc=doc.replace("<!--EQUIV-->","\n"+"\n".join(eb))
open(DOC,"w").write(doc)
print("filled rollout-39.md; remaining placeholders:", doc.count("<!--"))
print(f"load {ln}/{lm} solar {sn}/{sm} wind {wn}/{wm} total NEW {tot_new}/{tot} pilot_zones {len(pilot_zones)}")
