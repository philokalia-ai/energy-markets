"""Realised SDAC prices for the strategy day sets -> CSV (scoring only; never an input to a strategy for day D).
Uses the cv46 scorer's actuals: da_target.hourly_actuals(target="sdac") and native PT15M quarters (same sequence map).
usage: python -I realised_prices.py OUTDIR DAYFILE [DAYFILE ...]
Writes OUTDIR/realised_hourly.csv (zone,t_utc,price) and OUTDIR/realised_quarter.csv (zone,t_utc,price)."""
import os, sys
from datetime import date, timedelta
import duckdb
sys.path.insert(0, os.path.expanduser("~/armada/em-team/worktrees/lead-offline/bin"))
import da_target  # noqa: E402

out = sys.argv[1]
days = sorted({date.fromisoformat(l.strip()) for f in sys.argv[2:] for l in open(f) if l.strip()})
con = duckdb.connect(os.path.expanduser("~/armada/em-data/euphemia-live-20261115.duckdb"), read_only=True)
H, Q = [], []
for d in days:
    t0, t1 = str(d), str(d + timedelta(days=1))
    a = da_target.hourly_actuals(con, t0, t1, target="sdac")
    zc = "z" if "z" in a.columns else "zone"
    a = a.rename(columns={zc: "zone", a.columns[-1]: "price"})[["zone", "t", "price"]]
    H.append(a)
    raw = da_target._norm(da_target.raw_rows(con, t0, t1))
    smap = da_target.auction_map(raw)
    want = smap[smap.how != "ambiguous"][["z", "seq"]]
    k = raw.merge(want, on=["z", "seq"])
    k = k[(k.res == "PT15M") & (k.t.dt.minute % 15 == 0) & (k.t.dt.second == 0)]
    k = k.sort_values(["z", "t", "u", "p"], na_position="first", kind="mergesort").drop_duplicates(["z", "t"], keep="last")
    Q.append(k.rename(columns={"z": "zone", "p": "price"})[["zone", "t", "price"]])
import pandas as pd
for name, L in (("realised_hourly.csv", H), ("realised_quarter.csv", Q)):
    df = pd.concat(L)
    df = df[(df.t >= pd.Timestamp(days[0])) ]
    df.rename(columns={"t": "t_utc"}).sort_values(["zone", "t_utc"]).to_csv(os.path.join(out, name), index=False)
    print(name, len(df), df.zone.nunique(), "zones")
