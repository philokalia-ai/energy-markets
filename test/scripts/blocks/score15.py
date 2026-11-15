"""15-min pilot scorer (planner-p3 protocol). usage: score15.py H60_LABEL Q15_LABEL [days...]

Arms: H60 = hourly cv44 clear (24 prices/day), Q15 = quarter-hourly clear (96/day).
Targets:
  act15 = native PT15M settled DA price from the read-only extract (SDAC; AT/DE_LU
          sequence 2, latest update), rounded to 8 decimals. Zone-quarters without a
          native PT15M price (CH before 11-03) are masked out of (a).
  act60 = live JSON `actual` (the current hourly metric; AT/DE_LU seq 2), rounded to 8.
(a) 15-min score on the SAME native-15 mask: Q15 vs act15, and H60 replicated x4 vs act15.
(b) hourly score: H60 vs act60, and mean-of-quarters(Q15) vs act60.
(c) shape floor: within-hour dispersion of the actuals, mean |act15 - hourmean(act15)|
    (the error a hourly-replicated forecast with a perfect hourly level would still make),
    and H60-replicated 15-min MAE split into level error and that dispersion.
<=0 hit/false alarm after 8-decimal rounding. Simulated prices rounded to 8 decimals."""
import sys, os, glob, json, pandas as pd, numpy as np, duckdb
R = "/home/pgeorgakopoulos/armada/em-team/results/blocks"
EXTRACT = "/home/pgeorgakopoulos/armada/em-data/euphemia-live-20261115.duckdb"
h60, q15 = sys.argv[1], sys.argv[2]

def load(label):
    out = []
    for f in sorted(glob.glob(f"{R}/{label}/2026-*-??.csv")):
        df = pd.read_csv(f)
        df["t"] = pd.to_datetime(df.period.astype(str), format="%Y%m%d-%H%M")
        df["day"] = os.path.basename(f)[:10]
        out.append(df[["zone", "t", "day", "price"]])
    df = pd.concat(out)
    dup = df.duplicated(["zone", "t"]).sum()
    if dup: sys.exit(f"{label}: {dup} duplicate (zone, period) keys — refusing to score")
    bad = ~np.isfinite(df.price)
    if bad.any(): print(f"{label}: dropped {int(bad.sum())} non-finite prices")
    df = df[~bad].copy()
    df["price"] = df.price.round(8)
    return df

H, Q = load(h60), load(q15)
days = sorted(set(H.day) & set(Q.day))
if len(sys.argv) > 3: days = [d for d in days if d in sys.argv[3:]]
H, Q = H[H.day.isin(days)], Q[Q.day.isin(days)]
zones = sorted(set(H.zone) & set(Q.zone))

con = duckdb.connect(EXTRACT, read_only=True)
dl = ",".join(f"'{d}'" for d in days)
a15 = con.execute(f"""
  select map_code zone, date_time_utc t, sequence, price_currency_mwh act, update_time_utc u
  from entsoe.energy_prices where resolution_code='PT15M' and contract_type='Day-ahead'
   and cast(date_time_utc as date) in ({dl})""").df()
a15["sequence"] = a15.sequence.astype(str).str.strip()
a15 = a15[~a15.zone.isin(["AT", "DE_LU"]) | (a15.sequence == "2")]
a15 = a15.sort_values("u").drop_duplicates(["zone", "t"], keep="last")[["zone", "t", "act"]]
a15 = a15[a15.zone.isin(zones)]
a15 = a15[np.isfinite(a15.act)]
a15["act"] = a15.act.round(8)

rows = []
for z in zones:
    f = f"/home/pgeorgakopoulos/armada/em-team/live/{z}.json"
    if not os.path.exists(f): continue
    for d in json.load(open(f))["days"]:
        for h, a in zip(d.get("hours", []), d.get("actual", []) or []):
            if a is not None: rows.append((z, h, a))
a60 = pd.DataFrame(rows, columns=["zone", "t", "act"])
a60["t"] = pd.to_datetime(a60.t, utc=True).dt.tz_localize(None)
a60 = a60[np.isfinite(a60.act.astype(float))].drop_duplicates(["zone", "t"])
a60["act"] = a60.act.astype(float).round(8)
a60 = a60[a60.t.dt.strftime("%Y-%m-%d").isin(days)]

# ---- coverage contract (planner-p3): primary = complete paired zone-days only.
# UTC-day windows: expected 24 hourly / 96 quarter periods per zone-day.
Q["h"] = Q.t.dt.floor("h"); H = H.rename(columns={"t": "h"})
Q["nqh"] = Q.groupby(["zone", "h"]).t.transform("nunique")
qm = Q[Q.nqh == 4].groupby(["zone", "h", "day"], as_index=False).price.mean()   # Qbar: 4 quarters required
# ---- (a) quarter-hour frame on the native-15 mask
qa = Q.merge(H[["zone", "h", "price"]], on=["zone", "h"], suffixes=("_q", "_h")).merge(a15, on=["zone", "t"])
qa["hm_act"] = qa.groupby(["zone", "h"]).act.transform("mean")
qa["nq"] = qa.groupby(["zone", "h"]).act.transform("size")
qa["qday"] = qa.t.dt.strftime("%Y-%m-%d")
# ---- (b) hourly frame
ha = H.merge(qm, on=["zone", "h", "day"], suffixes=("_h", "_q")).merge(
    a60.rename(columns={"t": "h"}), on=["zone", "h"])
nq_zd = qa.groupby(["zone", "qday"]).size().rename("n").reset_index()
nh_zd = ha.groupby(["zone", "day"]).size().rename("n").reset_index()
qa = qa.merge(nq_zd, on=["zone", "qday"]); ha = ha.merge(nh_zd, on=["zone", "day"])
qa["complete"] = qa.n == 96; ha["complete"] = ha.n == 24
native_zd = a15.assign(qday=a15.t.dt.strftime("%Y-%m-%d")).groupby(["zone", "qday"]).size()
cov = (f"coverage (UTC days, expected {len(zones)}x{len(days)} = {len(zones)*len(days)} zone-days): "
       f"(b) hourly complete {int((nh_zd.n == 24).sum())}, partial {int((nh_zd.n < 24).sum())}; "
       f"(a) native-15 zone-days {len(native_zd)}, complete {int((nq_zd.n == 96).sum())}, partial {int((nq_zd.n < 96).sum())}")
part_a = nq_zd[nq_zd.n < 96].assign(expected=96); part_b = nh_zd[nh_zd.n < 24].assign(expected=24)
qa_all, ha_all = qa, ha
qa, ha = qa_all[qa_all.complete].copy(), ha_all[ha_all.complete].copy()
qa_p, ha_p = qa_all[~qa_all.complete].copy(), ha_all[~ha_all.complete].copy()

def st(sim, act):
    e = sim - act
    c = np.corrcoef(sim, act)[0, 1] if len(sim) >= 3 and sim.std() > 1e-9 and act.std() > 1e-9 else np.nan
    p, a = sim.round(8) <= 0, act.round(8) <= 0
    tp, fp, fn, tn = int((p & a).sum()), int((p & ~a).sum()), int((~p & a).sum()), int((~p & ~a).sum())
    return dict(mae=e.abs().mean(), bias=e.mean(), corr=c, tp=tp, fp=fp, fn=fn,
                rec=tp / (tp + fn) if tp + fn else np.nan, far=fp / (fp + tn) if fp + tn else np.nan)

def mdr(g, col, day):
    """site convention: mean over zone-days of the per-zone-day Pearson r"""
    keys = [k for k in ("zone", day) if k in g.columns]
    if not keys: return st(g[col], g.act)["corr"]
    return g.groupby(keys).apply(lambda x: st(x[col], x.act)["corr"]).mean()

def tab_a(g):
    a, b = st(g.price_h, g.act), st(g.price_q, g.act)
    full = g[g.nq == 4]
    med = full.groupby(["zone", "h"]).act.transform("median")
    qbar = full.groupby(["zone", "h"]).price_q.transform("mean")
    return pd.Series({"n": len(g), "act<=0": int((g.act <= 0).sum()),
        "mae_Hrep": a["mae"], "mae_Q": b["mae"], "d%": 100 * (b["mae"] / a["mae"] - 1),
        "bias_H": a["bias"], "bias_Q": b["bias"], "r_H": a["corr"], "r_Q": b["corr"],
        "mdr_H": mdr(g, "price_h", "qday"), "mdr_Q": mdr(g, "price_q", "qday"),
        "tp_H": a["tp"], "tp_Q": b["tp"], "fp_H": a["fp"], "fp_Q": b["fp"], "fn_H": a["fn"], "fn_Q": b["fn"],
        # hindsight shape floors (full hours only)
        "Smean": (full.act - full.hm_act).abs().mean(), "Smed": (full.act - med).abs().mean(),
        # centred shape error: Q's intra-hour deviations vs the actual's; H-rep's is Smean
        "shape_Q": ((full.price_q - qbar) - (full.act - full.hm_act)).abs().mean(),
        "sim_disp_Q": (full.price_q - qbar).abs().mean(),
        # MSE decomposition for replicated H: hourly sq. error + intra-hour variance
        "mse_Hrep": ((full.price_h - full.act) ** 2).mean(),
        "mse_Hlvl": ((full.price_h - full.hm_act) ** 2).mean(), "var_in": ((full.act - full.hm_act) ** 2).mean()})

def tab_b(g):
    a, b = st(g.price_h, g.act), st(g.price_q, g.act)
    return pd.Series({"n": len(g), "act<=0": int((g.act <= 0).sum()),
        "mae_H": a["mae"], "mae_Qbar": b["mae"], "d": b["mae"] - a["mae"],
        "bias_H": a["bias"], "bias_Q": b["bias"], "r_H": a["corr"], "r_Q": b["corr"],
        "mdr_H": mdr(g, "price_h", "day"), "mdr_Q": mdr(g, "price_q", "day"),
        "tp_H": a["tp"], "tp_Q": b["tp"], "fp_H": a["fp"], "fp_Q": b["fp"], "fn_H": a["fn"], "fn_Q": b["fn"],
        "moved>0.5": int(((g.price_q - g.price_h).abs() > 0.5).sum()),
        "cap_H": int(((g.price_h >= 2999) | (g.price_h <= -499)).sum()),
        "cap_Q": int(((g.price_q >= 2999) | (g.price_q <= -499)).sum())})

pd.set_option("display.width", 300); pd.set_option("display.max_rows", 200); pd.set_option("display.max_columns", 40)
f = lambda df: df.round(2).to_string()
by = lambda df, key, fn: pd.DataFrame({k: fn(g) for k, g in df.groupby(key)}).T   # full frames per group
for fr in (qa, ha, qa_p, ha_p): fr["IT"] = fr.zone.str.startswith("IT-")
print(f"days {days}  zones {len(zones)}   UTC-day windows (both arms identical)")
print("inputs: legacy D-1 path (not the 06:30 issuance context); UTC-day windows, not stitched Athens days")
print(cov)
print(f"PRIMARY cohort = complete paired zone-days: (a) {len(qa)} quarter cells   (b) {len(ha)} hourly cells")
print("partial zone-days (n/expected), reported separately:")
for _, r in part_b.iterrows(): print(f"   (b) {r.zone} {r.day}: {r.n}/{r.expected}")
for _, r in part_a.iterrows(): print(f"   (a) {r.zone} {r.qday}: {r.n}/{r.expected}")
print("\n== (b) HOURLY score (current metric): H vs Qbar (mean of 4 quarters) ==")
print(f(pd.DataFrame({"all": tab_b(ha), "exIT": tab_b(ha[~ha.IT])}).T))
print("\n== (a) 15-MIN score, same native-15 mask: Q vs H replicated x4 ==")
print(f(pd.DataFrame({"all": tab_a(qa), "exIT": tab_a(qa[~qa.IT])}).T))
print("\n== per day (b hourly) ==")
print(f(by(ha, "day", tab_b)))
print("== per day (a 15-min) ==")
print(f(by(qa, "qday", tab_a)))
print("\n== per zone (b) hourly ==")
print(f(by(ha, "zone", tab_b).sort_values("d")))
print("\n== per zone (a) 15-min ==")
print(f(by(qa, "zone", tab_a).sort_values("d%")))
# replicated-only control: zones whose load AND RES inputs are hourly-only on that day
ctrl = {"BG", "CH", "PT", "RS"}
qa["ctrl"] = qa.zone.isin(ctrl) | ((qa.zone == "EE") & (qa.qday < "2026-11-02"))
print("\n== (a) replicated-only-input control zones (BG, CH, PT, RS, EE<11-02) vs native-input zones ==")
print(f(pd.DataFrame({"ctrl": tab_a(qa[qa.ctrl]), "native": tab_a(qa[~qa.ctrl])}).T))
ramp = ha.h.dt.hour.isin([5, 6, 7, 8, 14, 15, 16, 17])
print("\n== (b) hourly, ramp hours 05-08 & 14-17 UTC vs rest ==")
print(f(pd.DataFrame({"ramp": tab_b(ha[ramp]), "rest": tab_b(ha[~ramp])}).T))
print("\n== PARTIAL cohort (not in the primary numbers above) ==")
if len(ha_p): print("(b) hourly\n" + f(pd.DataFrame({"partial": tab_b(ha_p)}).T))
if len(qa_p): print("(a) 15-min\n" + f(pd.DataFrame({"partial": tab_a(qa_p)}).T))
out = os.environ.get("SCORE15_OUT")
if out:
    qa.to_parquet(out + "_q.parquet"); ha.to_parquet(out + "_h.parquet")
