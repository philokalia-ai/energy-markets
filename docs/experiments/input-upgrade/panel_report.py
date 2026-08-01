#!/usr/bin/env python3
"""Panel aggregator (Validation B): read the per-(day,arm) cleared pilot prices
written by panel_cell.jl and the settled DA prices from the extract; print the
GR+NL midday panel (UTC 09-15) vs settled and the collapse (<=EUR5 / <0)
hit / false-alarm counts per arm. Arms: old (committed packs) | ml (LightGBM)."""
import json, glob, duckdb, numpy as np, pandas as pd
SP = "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/input_upgrade"
EXT = "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb"
DAYS = ["2026-07-24", "2026-07-25", "2026-07-26", "2026-07-27"]
PILOTS = ["GR", "ES", "DE_LU", "SE2", "NL"]
ARMS = ["old", "ml"]

# arm -> zone -> ts -> price
cell = {a: {} for a in ARMS}
for a in ARMS:
    for d in DAYS:
        fn = f"{SP}/panel_{d}_{a}.json"
        try:
            j = json.load(open(fn))
        except FileNotFoundError:
            print(f"  MISSING {fn}"); continue
        for z, series in j.items():
            cell[a].setdefault(z, {}).update(series)

con = duckdb.connect(EXT, read_only=True)
s = con.execute(f"""SELECT map_code z, date_trunc('hour',date_time_utc) h, avg(price_currency_mwh) p
 FROM entsoe.energy_prices WHERE contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
 AND price_currency_mwh IS NOT NULL AND map_code IN ({','.join(chr(39)+z+chr(39) for z in PILOTS)})
 AND date_time_utc>=TIMESTAMP '2026-07-24' AND date_time_utc<TIMESTAMP '2026-07-28'
 GROUP BY 1,2""").df()
settled = {(r.z, pd.Timestamp(r.h).strftime("%Y%m%d-%H%M")): r.p for r in s.itertuples()}


def midday(series):
    v = [p for ts, p in series.items() if 9 <= int(ts[9:11]) <= 15]
    return np.mean(v) if v else np.nan


print("=" * 64)
print("MIDDAY PRICE (EUR/MWh, UTC 09-15) — settled vs arms")
print(f"{'day':10s} {'zone':6s} {'settled':>8s} {'old(pack)':>10s} {'ML':>8s}")
for d in DAYS:
    for z in ["GR", "NL"]:
        dk = d.replace("-", "")
        st = midday({k: settled[(z, k)] for k in (f"{dk}-{h:02d}00" for h in range(9, 16)) if (z, k) in settled})
        om = midday({k: v for k, v in cell["old"].get(z, {}).items() if k.startswith(dk)})
        ml = midday({k: v for k, v in cell["ml"].get(z, {}).items() if k.startswith(dk)})
        print(f"{d:10s} {z:6s} {st:8.1f} {om:10.1f} {ml:8.1f}")

print("\nCONTROLS (ES / DE_LU / SE2) midday:")
for d in DAYS:
    for z in ["ES", "DE_LU", "SE2"]:
        dk = d.replace("-", "")
        st = midday({k: settled[(z, k)] for k in (f"{dk}-{h:02d}00" for h in range(9, 16)) if (z, k) in settled})
        om = midday({k: v for k, v in cell["old"].get(z, {}).items() if k.startswith(dk)})
        ml = midday({k: v for k, v in cell["ml"].get(z, {}).items() if k.startswith(dk)})
        print(f"{d:10s} {z:6s} settled={st:6.1f}  old={om:6.1f}  ml={ml:6.1f}")


def confusion(pred, truth, thr):
    pt = pred <= thr; tt = truth <= thr
    hit = int((pt & tt).sum()); miss = int((~pt & tt).sum()); fa = int((pt & ~tt).sum())
    return dict(pos=int(tt.sum()), hit=hit, miss=miss, fa=fa)


# long frame over all pilot zone-hours
rows = []
for z in PILOTS:
    for ts, st in ((k[1], v) for k, v in settled.items() if k[0] == z):
        o = cell["old"].get(z, {}).get(ts); m = cell["ml"].get(z, {}).get(ts)
        if o is None or m is None: continue
        rows.append(dict(zone=z, ts=ts, settled=st, old=o, ml=m))
df = pd.DataFrame(rows)

print("\n" + "=" * 64)
print("COLLAPSE CLASSIFICATION vs settled (all pilot zone-hours, 07-24..27)")
for label, thr in [("<=EUR5", 5.0), ("<0 negative", 0.0)]:
    tp = int((df.settled <= thr).sum())
    print(f"\n-- {label}: settled positives = {tp}/{len(df)} --")
    for arm in ARMS:
        c = confusion(df[arm].values, df.settled.values, thr)
        print(f"  {arm:4s} hit={c['hit']:3d} miss={c['miss']:3d} FA={c['fa']:3d}")

print("\nPER-ZONE all-hour MAE vs settled + collapse(<=5) hit/FA:")
for z in PILOTS:
    dz = df[df.zone == z]
    if len(dz) == 0:
        print(f"  {z}: no data"); continue
    line = f"  {z:6s} (n={len(dz)}): "
    for arm in ARMS:
        mae = np.mean(np.abs(dz[arm] - dz.settled))
        c = confusion(dz[arm].values, dz.settled.values, 5.0)
        line += f"{arm} MAE={mae:5.1f} hit={c['hit']}/{c['pos']} FA={c['fa']}   "
    print(line)
print("\nPANEL_REPORT_DONE")
