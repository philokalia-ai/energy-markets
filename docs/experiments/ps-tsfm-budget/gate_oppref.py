"""Gates for planner-p2 idea #2 (PS opportunity reference): CH/AT hourly PS-generation MAE
(master allocation vs ENTSO-E actual), CH/AT price MAE, footprint MAE, new cap prints."""
import glob, os, json, duckdb, numpy as np, pandas as pd
R = "/home/pgeorgakopoulos/armada/em-team/results/blocks"; Z = ["CH", "AT"]
def prices(label):
    out = []
    for f in glob.glob(f"{R}/{label}/2026-*-??.csv"):
        d = pd.read_csv(f); d["t"] = pd.to_datetime(d.period.astype(str), format="%Y%m%d-%H%M"); d["day"] = os.path.basename(f)[:10]; out.append(d)
    return pd.concat(out)
def alloc(label):
    out = []
    for f in glob.glob(f"{R}/{label}/2026-*.alloc.csv"):
        d = pd.read_csv(f); d["day"] = os.path.basename(f)[:10]; out.append(d)
    a = pd.concat(out); a["zone"] = a.family.str.split(":").str[1]; a["t"] = pd.to_datetime(a.date_time)
    return a[a.zone.isin(Z)].groupby(["zone", "t", "day"]).alloc_mw.sum().reset_index()
rows = []
for f in glob.glob("/home/pgeorgakopoulos/armada/em-team/live/*.json"):
    z = os.path.basename(f)[:-5]
    for d in json.load(open(f))["days"]:
        for h, a in zip(d.get("hours", []), d.get("actual", []) or []):
            if a is not None: rows.append((z, h, a))
act = pd.DataFrame(rows, columns=["zone", "t", "act"]); act["t"] = pd.to_datetime(act.t, utc=True).dt.tz_localize(None)
act = act.drop_duplicates(["zone", "t"]); act["act"] = act.act.round(8)
B, T = prices("o_base"), prices("o_treat")
m = B.merge(T, on=["zone", "t", "day"], suffixes=("_b", "_t")).merge(act, on=["zone", "t"])
mae = lambda g, c: float(np.mean(np.abs(g[c] - g.act)))
loc = m[m.zone.isin(Z)]
print(f"days {sorted(m.day.unique())}  cells {len(m)}  local cells {len(loc)}")
print(f"footprint MAE {mae(m,'price_b'):.2f} -> {mae(m,'price_t'):.2f} ({mae(m,'price_t')-mae(m,'price_b'):+.2f})  [gate: degradation <= +0.5]")
print(f"CH/AT price MAE {mae(loc,'price_b'):.2f} -> {mae(loc,'price_t'):.2f} ({mae(loc,'price_t')-mae(loc,'price_b'):+.2f})  [gate: <= -0.5]")
for z in Z:
    g = loc[loc.zone == z]; print(f"   {z}: {mae(g,'price_b'):.2f} -> {mae(g,'price_t'):.2f}  bias {np.mean(g.price_b-g.act):+.1f} -> {np.mean(g.price_t-g.act):+.1f}")
capb = int(((m.price_b >= 2999) | (m.price_b <= -499)).sum()); capt = int(((m.price_t >= 2999) | (m.price_t <= -499)).sum())
print(f"cap/floor prints base {capb} treat {capt}  [gate: no new]")
print(f"cells moved (|d|>0.5): all {int((abs(m.price_t-m.price_b)>0.5).sum())}, CH/AT {int((abs(loc.price_t-loc.price_b)>0.5).sum())}")
con = duckdb.connect("/home/pgeorgakopoulos/armada/em-data/euphemia-live-20261114.duckdb", read_only=True)
g = con.sql("""select area_map_code zone, date_trunc('hour', date_time_utc) t, avg(actual_generation_output_mw) gen
  from entsoe.aggregated_generation_per_type where production_type='Hydro Pumped Storage' and area_type_code like 'BZN%'
  and area_map_code in ('CH','AT') and date_time_utc >= '2026-09-15' and date_time_utc < '2026-11-15' group by 1,2""").df()
g["t"] = pd.to_datetime(g.t)
ab, at = alloc("o_base"), alloc("o_treat")
pg = ab.merge(at, on=["zone", "t", "day"], suffixes=("_b", "_t")).merge(g, on=["zone", "t"])
print(f"PS-generation hours with actuals: {len(pg)} ({pg.groupby('zone').size().to_dict()})")
for z in Z + ["CH+AT"]:
    q = pg if z == "CH+AT" else pg[pg.zone == z]
    eb, et = np.mean(np.abs(q.alloc_mw_b - q.gen)), np.mean(np.abs(q.alloc_mw_t - q.gen))
    print(f"   PS gen MAE {z}: {eb:.0f} -> {et:.0f} MW ({100*(eb-et)/eb:+.1f}%)  [gate: >= +10%]   mean gen {q.gen.mean():.0f}, model {q.alloc_mw_b.mean():.0f} -> {q.alloc_mw_t.mean():.0f}")
