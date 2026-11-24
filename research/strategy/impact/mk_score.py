"""Score the markup-model re-clears (runs/st-impact/mk/<V>/<day>.prices.csv) against the baseline and realised prices,
evaluation days, per zone and per region. MAE and bias vs realised (bias = realised − predicted: > 0 means our price is too low); Δ MAE (model − baseline) with a day-block 90% CI;
share of the miss explained = 1 − MAE_model / MAE_base. Regions: the 6 study zones (markup applied), and the rest of the
39-zone footprint grouped (spill-over through coupling).
usage: python -I mk_score.py [A B ...]"""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R, strat as ST  # noqa: E402
MK = MV.ROOT / "runs/st-impact/mk"
EV = (MV.ROOT / "days_eval.txt").read_text().split()
real = ST.realised_table()
STUDY = ["GR", "IT-SOUTH", "DE_LU", "FR", "ES", "NO2"]
# region map of docs/experiments/cv31_scoreboard.py (the repo's scoreboard regions); unlisted zones -> OTHER
REG = {**{z: "NORDIC" for z in "NO1 NO2 NO3 NO4 NO5 SE1 SE2 SE3 SE4 FI DK1 DK2".split()},
       **{z: "BALTIC" for z in "EE LV LT".split()},
       **{z: "CWE" for z in "DE_LU FR NL BE AT CH CZ PL SK HU SI".split()},
       **{z: "SEE" for z in "GR BG RO RS".split()},
       **{z: "IBERIA" for z in "ES PT".split()},
       **{z: "ITALY" for z in "IT-NORTH IT-CNORTH IT-CSOUTH IT-SOUTH IT-Calabria IT-Sicily IT-Sardinia".split()}}


def region(z):
    return REG.get(z, "OTHER")


rows = []
for V in (sys.argv[1:] or ["A", "B"]):
    for d in EV:
        f = MK / V / f"{d}.prices.csv"
        if not f.exists():
            continue
        m = pd.read_csv(f)
        b = pd.read_csv(MV.BASE / f"{d}.prices.csv")
        x = m.merge(b, on=["zone", "hour_utc"], suffixes=("_m", "_b"))
        x["real"] = [real.get((z, d), {}).get(h, np.nan) for z, h in zip(x.zone, x.hour_utc)]
        x = x.dropna(subset=["real"])
        x["V"], x["day"] = V, d
        rows.append(x)
D = pd.concat(rows)
D["region"] = D.zone.map(region)
D["eb"], D["em"] = D.real - D.price_b, D.real - D.price_m
# shape error: the hourly error after removing each (zone, day)'s mean error = (model − mean) − (actual − mean) per
# (day, zone), the cv46 scorer's definition (cv46-blocks/cb-harness/score_cv46.py:24,174); level-independent
for c in ("eb", "em"):
    D[c + "_s"] = D[c] - D.groupby(["V", "zone", "day"])[c].transform("mean")
out = []
units = [("zone", z, D.zone == z) for z in STUDY] + [("region", r, D.region == r) for r in sorted(D.region.unique())] + \
        [("pooled", "ALL", D.zone.notna())]
for V in sorted(D.V.unique()):
    for kind, name, mask in units:
        g = D[mask & (D.V == V)]
        dd = g.groupby("day").apply(lambda x: pd.Series({"b": x.eb.abs().sum(), "m": x.em.abs().sum(), "n": len(x)}))
        dmae = R.block_bootstrap_ci(((dd.m - dd.b) / dd.n).values)
        ds = g.groupby("day").apply(lambda x: (x.em_s.abs().sum() - x.eb_s.abs().sum()) / len(x))
        dshape = R.block_bootstrap_ci(ds.values)
        rng = np.random.default_rng(7)
        idx = rng.integers(0, len(dd), (5000, len(dd)))
        sh = 1 - dd.m.values[idx].sum(1) / dd.b.values[idx].sum(1)
        out.append(dict(variant=V, kind=kind, unit=name, zones=g.zone.nunique(), days=len(dd), cells=int(dd.n.sum()),
                        mae_base=g.eb.abs().mean(), mae_model=g.em.abs().mean(), bias_base=g.eb.mean(), bias_model=g.em.mean(),
                        dmae=f"{dmae[0]:+.2f} [{dmae[1]:+.2f}, {dmae[2]:+.2f}]",
                        share=f"{1 - dd.m.sum() / dd.b.sum():+.3f} [{np.quantile(sh, .05):+.3f}, {np.quantile(sh, .95):+.3f}]",
                        shape_mae_base=g.eb_s.abs().mean(), shape_mae_model=g.em_s.abs().mean(),
                        dshape=f"{dshape[0]:+.2f} [{dshape[1]:+.2f}, {dshape[2]:+.2f}]",
                        mean_abs_shift=(g.price_m - g.price_b).abs().mean()))
T = pd.DataFrame(out).round(2)
T.to_csv(MV.ROOT / "runs/st-impact/tables/mk_score.csv", index=False)
print(MV.md(T, index=False))
