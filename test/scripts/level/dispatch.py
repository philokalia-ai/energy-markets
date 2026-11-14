# Model dispatch (supply blocks priced below the clearing price, + offered) by fuel vs ENTSO-E actual generation per type (ex-post diagnostic).
import sys, pandas as pd
run, day, zones = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
R = "/home/pgeorgakopoulos/armada/em-team/results/level"
B = pd.read_csv(f"{run}/{day}.book.csv", keep_default_na=False)
for pre in ("AGG-", "OUT-"):
    m = (B.fuel == "") & B.owner.str.startswith(pre)
    B.loc[m, "fuel"] = [o[len(pre) + len(z) + 1:].replace("_", " ") for o, z in zip(B.owner[m], B.zone[m])]
B.loc[B.fuel == "", "fuel"] = B.strategy
B["t"] = pd.to_datetime(B.ts).dt.floor("h")
P = pd.read_csv(f"{run}/{day}.csv"); P["t"] = pd.to_datetime(P.period.astype(str), format="%Y%m%d-%H%M")
P = P.groupby(["zone", "t"]).price.mean().rename("sim").reset_index()
B = B[B.side == "supply"].merge(P, on=["zone", "t"])
# hourly MW: books may be 15-min; average over the hour = sum / slots
nslot = B.groupby(["zone"]).ts.nunique() / 24
B["mwh"] = B.mw / B.zone.map(nslot)
acc = B[B.price < B.sim - 0.02].groupby(["zone", "fuel"]).mwh.sum() / 24
off = B.groupby(["zone", "fuel"]).mwh.sum() / 24
A = pd.read_csv(f"{R}/actual_gen.csv", parse_dates=["t"])
A = A[A.t.dt.date.astype(str) == day].groupby(["zone", "production_type"]).gen.mean()
A.index.names = ["zone", "fuel"]
T = pd.concat({"offered": off, "model_acc": acc, "actual": A}, axis=1).fillna(0).round(0)
pd.set_option("display.width", 200); pd.set_option("display.max_rows", 500)
for z in zones:
    t = T.loc[z]; t = t[(t.abs().sum(axis=1) > 50)]
    print(f"== {z} {day} (mean MW)"); print(t.sort_values("actual", ascending=False).to_string())
