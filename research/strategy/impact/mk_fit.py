"""Fit the ex-ante markup models on CALIBRATION days (runs/st-impact/mv/hours.csv) and write per-eval-day markups.
  A: m(zone, band)          = median implied flat markup over SRMC (uncensored calibration hours), fallback zone
  B: m(zone, band, tech)    = median by marginal technology of the hour (our baseline's, ex-ante), >= 5 uncensored
                              calibration hours, else A
NO2 has no flexible thermal set: no markup. m is bounded to [-0.5, +1.0] (the m-grid range of Part B; chosen before any
evaluation result — the calibration medians reach -0.98 in ES solar hours, where the "markup" absorbs RES error). Output runs/st-impact/mk/<A|B>/<day>.json {zone: {hour: m}} + params.csv."""
import json, sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
MK = MV.ROOT / "runs/st-impact/mk"
H = pd.read_csv(MV.ROOT / "runs/st-impact/mv/hours.csv")
H["f_real"] = H.f_real.fillna("")
CAL = set((MV.ROOT / "days_cal.txt").read_text().split())
cal = H[H.day.isin(CAL) & (H.f_real == "") & H.m_real.notna() & (H.zone != "NO2")]
A2 = cal.groupby(["zone", "band"]).m_real.agg(["median", "size"])
A1 = cal.groupby("zone").m_real.median()
B3 = cal.groupby(["zone", "band", "tech"]).m_real.agg(["median", "size"])
params = []
for (z, b), r in A2.iterrows():
    params.append(dict(model="A", zone=z, band=b, tech="*", m=r["median"] if r["size"] >= 5 else A1[z], n=int(r["size"])))
for (z, b, t), r in B3.iterrows():
    if r["size"] >= 5:
        params.append(dict(model="B", zone=z, band=b, tech=t, m=r["median"], n=int(r["size"])))
P = pd.DataFrame(params)
P["m_raw"] = P.m
P["m"] = P.m.clip(-0.5, 1.0)
MK.mkdir(parents=True, exist_ok=True)
P.to_csv(MK / "params.csv", index=False)
mA = {(r.zone, r.band): r.m for r in P[P.model == "A"].itertuples()}
mB = {(r.zone, r.band, r.tech): r.m for r in P[P.model == "B"].itertuples()}
ev = H[~H.day.isin(CAL)]
for v in "AB":
    (MK / v).mkdir(exist_ok=True)
for d, g in ev.groupby("day"):
    out = {"A": {}, "B": {}}
    for r in g.itertuples():
        if r.zone == "NO2":
            continue
        a = mA.get((r.zone, r.band), A1.get(r.zone, np.nan))
        bb = mB.get((r.zone, r.band, r.tech), a)
        if not np.isnan(a):
            out["A"].setdefault(r.zone, {})[int(r.hour)] = float(a)
        if not np.isnan(bb):
            out["B"].setdefault(r.zone, {})[int(r.hour)] = float(bb)
    for v in "AB":
        (MK / v / f"{d}.json").write_text(json.dumps(out[v]))
print(P[P.model == "A"].pivot(index="zone", columns="band", values="m").round(2).to_string())
print("B cells:", int((P.model == "B").sum()), "| eval days written:", ev.day.nunique())
