"""LEAR pilot (#431, PR F part 2): DE_LU and GR, daily recalibration, prices + calendar only.

A clean-room reimplementation of the LEAR model of Lago, Marcjasz, De Schutter & Weron (2021,
arXiv 2008.08004; epftoolbox). epftoolbox is not imported or vendored. Per target day D and
delivery slot h, with 24 slots = Athens local hours:

  features  prices of days D-1, D-2, D-3 and D-7, all 24 slots (96), plus 7 weekday dummies of D
  scaling   "invariant" asinh: z = asinh((x - median) / MAD_n), MAD_n = MAD / 0.6745, fitted
            per column on the calibration rows only; dummies are not scaled
  model     one Lasso per slot; alpha from LassoLarsIC(AIC, noise variance = var(y) as in
            sklearn < 1.1) on the calibration rows, then Lasso(alpha) refit (the epftoolbox
            recipe); the forecast is inverse-transformed
  window    the W market days D-W .. D-1, with W a hyperparameter fixed on validation

Information set: the forecast for Athens market day D uses only settled prices of days before
D. The latest is D-1, auctioned on D-2. That matches the TSFM `*_L1` runs and the nominal
D-1 06:30 UTC issue. The second (exogenous) arm is dropped; see README.md.

Target: SDAC day-ahead prices only. DE_LU uses sequence 1; sequence 2 is EXAA and never used.
GR uses its single series. Revisions keep the latest update; each hour takes the finest
resolution that covers all 60 minutes, then a duration-weighted mean. This is the rule of PR C's
`sdac` policy, restricted to these two zones.

DST (Athens): on the 23-h day the missing local hour 03 is linearly interpolated, for features
and training targets only. On the 25-h day the repeated local hour 03 is averaged as a source,
and both target UTC hours get the slot-3 forecast. The benchmark contract uses the same policy.

CLI:
  python lear.py prices  --out DIR                 # SDAC hourly prices for DE_LU, GR (read-only extract)
  python lear.py run     --out DIR --start D --end D --windows 56,84,182,364 [--zones ..] [--procs N]
  python lear.py select  --out DIR                 # lock hyperparameters from the validation run
  python lear.py export  --out DIR                 # long-format forecasts for the 431E contract
"""
import argparse
import json
import os
import time
from datetime import datetime, timezone
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.linear_model import Lasso, LassoLarsIC

ATH = "Europe/Athens"
ZONES = ("DE_LU", "GR")
SDAC_SEQUENCE = {"DE_LU": "1", "GR": ""}
RES_MINUTES = {"PT15M": 15, "PT30M": 30, "PT60M": 60}
LAGS = (1, 2, 3, 7)
MAX_ITER = 2500
VALIDATION = ("2024-01-01", "2024-06-30")
TEST = ("2024-07-01", "2026-11-13")
WINDOWS = (56, 84, 182, 364)


# ----------------------------------------------------------------------------- data
def sdac_hourly(con, zones=ZONES, start="2022-12-01", end="2026-11-16"):
    """SDAC hourly prices (zone, t UTC, price) under the explicit zone -> sequence map."""
    raw = con.execute("""
        SELECT map_code z, trim(coalesce(sequence, '')) seq, trim(resolution_code) res,
               date_time_utc t, price_currency_mwh p, update_time_utc u
        FROM entsoe.energy_prices
        WHERE contract_type = 'Day-ahead' AND area_type_code LIKE 'BZN%' AND currency = 'EUR'
          AND price_currency_mwh IS NOT NULL AND map_code IN (SELECT unnest(?::VARCHAR[]))
          AND date_time_utc >= ?::TIMESTAMP AND date_time_utc < ?::TIMESTAMP""",
                      [list(zones), start, end]).df()
    return sdac_from_raw(raw)


def sdac_from_raw(raw, sequence_map=SDAC_SEQUENCE):
    out = []
    for z, g in raw.groupby("z"):
        seqs = sorted(g.seq.unique())
        want = sequence_map.get(z)
        if want is None:
            if len(seqs) != 1:
                raise ValueError(f"{z}: several sequences {seqs} and no SDAC mapping")
            want = seqs[0]
        g = g[g.seq == want]
        g = g.sort_values(["u", "p"]).drop_duplicates(["res", "t"], keep="last")   # latest revision
        g = g.assign(m=g.res.map(RES_MINUTES), h=g.t.dt.floor("h"))
        if g.m.isna().any():
            raise ValueError(f"{z}: unknown resolution {g.res[g.m.isna()].unique()}")
        cov = g.groupby(["h", "m"]).size().rename("k").reset_index()
        cov = cov[cov.k * cov.m == 60].sort_values("m").drop_duplicates("h")   # finest complete
        g = g.merge(cov[["h", "m"]], on=["h", "m"])
        out.append(g.groupby("h").p.mean().rename("price").reset_index().assign(zone=z))
    return pd.concat(out)[["zone", "h", "price"]].rename(columns={"h": "t"}).reset_index(drop=True)


def daily_matrix(hourly):
    """(zone) -> DataFrame indexed by Athens market date, 24 columns = local slots 0..23."""
    out = {}
    for z, g in hourly.groupby("zone"):
        loc = g.t.dt.tz_localize("UTC").dt.tz_convert(ATH)
        d = pd.DataFrame({"date": loc.dt.tz_localize(None).dt.normalize(), "slot": loc.dt.hour,
                          "price": g.price.to_numpy()})
        m = d.groupby(["date", "slot"]).price.mean().unstack("slot")     # repeated hour averaged
        m = m.reindex(columns=range(24))
        full = pd.date_range(m.index.min(), m.index.max(), freq="D")
        m = m.reindex(full)
        # 23-h day: interpolate the single missing slot along the day (features/targets only)
        gaps = m.isna().sum(axis=1)
        one = gaps == 1
        m.loc[one] = m.loc[one].interpolate(axis=1, limit_direction="both")
        out[z] = m
    return out


def target_slots(day):
    """UTC hours of Athens market day `day` and their local slot (23/24/25 rows)."""
    s = pd.Timestamp(day).tz_localize(ATH)
    e = (pd.Timestamp(day) + pd.Timedelta(days=1)).tz_localize(ATH)
    hrs = pd.date_range(s.tz_convert("UTC"), e.tz_convert("UTC"), freq="h", inclusive="left")
    return pd.DataFrame({"t": hrs.tz_localize(None), "slot": hrs.tz_convert(ATH).hour})


# ----------------------------------------------------------------------------- model
def features(M, days):
    """X rows for target days `days` from the daily matrix M (backward lags only) + weekday dummies."""
    idx = pd.DatetimeIndex(days)
    parts = [M.reindex(idx - pd.Timedelta(days=k)).to_numpy() for k in LAGS]
    dow = np.zeros((len(idx), 7))
    dow[np.arange(len(idx)), idx.dayofweek] = 1.0
    return np.hstack(parts + [dow])


def inv_fit(x):
    med = np.nanmedian(x, axis=0)
    mad = np.nanmedian(np.abs(x - med), axis=0) / 0.6745
    mad = np.where(mad > 1e-9, mad, 1.0)
    return med, mad


def inv_tf(x, med, mad):
    return np.arcsinh((x - med) / mad)


def inv_back(z, med, mad):
    return np.sinh(z) * mad + med


def train_days(D, W):
    """Calibration target days for forecast day D: D-W .. D-1 (strictly before D)."""
    D = pd.Timestamp(D)
    return pd.date_range(D - pd.Timedelta(days=W), D - pd.Timedelta(days=1), freq="D")


def fit_predict(M, D, W):
    """One LEAR forecast of the 24 slots of day D with window W. Returns (pred[24], info)."""
    tr = train_days(D, W)
    X, Y = features(M, tr), M.reindex(tr).to_numpy()
    ok = ~np.isnan(X).any(axis=1) & ~np.isnan(Y).any(axis=1)
    X, Y = X[ok], Y[ok]
    x_new = features(M, [pd.Timestamp(D)])
    if len(X) < 0.9 * W or np.isnan(x_new).any():
        return np.full(24, np.nan), dict(n=int(len(X)), fit_last=None, alphas=None)
    nx = 96
    mx, sx = inv_fit(X[:, :nx])
    my, sy = inv_fit(Y)
    Xs = np.hstack([inv_tf(X[:, :nx], mx, sx), X[:, nx:]])
    xs = np.hstack([inv_tf(x_new[:, :nx], mx, sx), x_new[:, nx:]])
    Ys = inv_tf(Y, my, sy)
    pred, alphas = np.empty(24), np.empty(24)
    for h in range(24):
        # noise_variance = var(y): the sklearn < 1.1 LassoLarsIC behaviour epftoolbox was built on
        # (newer sklearn estimates it by OLS, impossible when W < 103 features); same for every W
        a = LassoLarsIC(criterion="aic", max_iter=MAX_ITER,
                        noise_variance=float(np.var(Ys[:, h]))).fit(Xs, Ys[:, h]).alpha_
        m = Lasso(alpha=a, max_iter=MAX_ITER).fit(Xs, Ys[:, h])
        pred[h] = inv_back(m.predict(xs)[0], my[h], sy[h])
        alphas[h] = a
    return pred, dict(n=int(len(X)), fit_last=str(tr[ok][-1].date()), alphas=alphas.tolist())


# ----------------------------------------------------------------------------- runner
_M = None


def _init(mats):
    global _M
    _M = mats
    os.environ.setdefault("OMP_NUM_THREADS", "1")


def _task(args):
    z, D, W = args
    t0 = time.time()
    p, info = fit_predict(_M[z], D, W)
    return dict(zone=z, date=str(pd.Timestamp(D).date()), W=W, pred=p.tolist(), n_train=info["n"],
                fit_last=info["fit_last"], secs=time.time() - t0)


def run(out, start, end, windows, zones=ZONES, procs=8, tag=None):
    hourly = pd.read_parquet(f"{out}/sdac_hourly.parquet")
    mats = daily_matrix(hourly[hourly.zone.isin(zones)])
    days = pd.date_range(start, end, freq="D")
    tasks = [(z, D, W) for z in zones for D in days for W in windows]
    t0 = time.time()
    with Pool(procs, initializer=_init, initargs=(mats,)) as pool:
        res = pool.map(_task, tasks, chunksize=4)
    df = pd.DataFrame(res)
    tag = tag or f"{start}_{end}"
    df.to_parquet(f"{out}/lear_raw_{tag}.parquet")
    print(f"{len(tasks)} fits ({len(zones)} zones x {len(days)} days x {len(windows)} windows) in "
          f"{time.time() - t0:.0f} s on {procs} procs; median {df.secs.median():.2f} s/fit; "
          f"NaN forecasts {int(df.pred.map(lambda p: np.isnan(p).any()).sum())}")
    return df


def to_hourly(raw, models):
    """Map daily 24-slot forecasts to UTC hours. `models`: {model_name: (zone -> spec)}, where a spec
    is a window W or 'ens' (mean of all windows in raw)."""
    rows = []
    for (z, d), g in raw.groupby(["zone", "date"]):
        ts = target_slots(d)
        byW = {int(r.W): np.asarray(r.pred) for r in g.itertuples()}
        for name, spec in models.items():
            s = spec[z] if isinstance(spec, dict) else spec
            p = np.mean(np.vstack(list(byW.values())), axis=0) if s == "ens" else byW[int(s)]
            rows.append(pd.DataFrame({"zone": z, "date": d, "t": ts.t, "slot": ts.slot,
                                      "model": name, "prediction": p[ts.slot.to_numpy()]}))
    return pd.concat(rows, ignore_index=True)


def select(out, tag):
    """Lock per-zone hyperparameters (W or ensemble) by validation MAE (SDAC actuals, all hours)."""
    raw = pd.read_parquet(f"{out}/lear_raw_{tag}.parquet")
    hourly = pd.read_parquet(f"{out}/sdac_hourly.parquet")
    Ws = sorted(raw.W.unique())
    cands = {f"W{w}": w for w in Ws} | {"ens": "ens"}
    fc = to_hourly(raw, cands).merge(hourly, on=["zone", "t"], how="inner")
    fc = fc.dropna(subset=["prediction", "price"])
    mae = fc.assign(ae=(fc.prediction - fc.price).abs()).groupby(["zone", "model"]).ae.agg(["mean", "size"])
    print(mae.round(3).to_string())
    choice = {}
    for z in mae.index.get_level_values(0).unique():
        best = mae.loc[z]["mean"].idxmin()
        choice[z] = cands[best]
    lock = dict(locked_utc=datetime.now(timezone.utc).isoformat(timespec="seconds"),
                rule="per zone, lowest validation MAE among single windows and their mean",
                validation=list(VALIDATION), windows=[int(w) for w in Ws],
                validation_mae={f"{z}/{m}": round(float(v), 4) for (z, m), v in mae["mean"].items()},
                choice={z: (c if c == "ens" else int(c)) for z, c in choice.items()})
    Path(f"{out}/hparams.json").write_text(json.dumps(lock, indent=1))
    print(json.dumps(lock["choice"]))
    return lock


def export(out, tag):
    """Long-format forecasts for the benchmark contract: zone, t, model, prediction, lead, issue_utc, fit_end."""
    lock = json.loads(Path(f"{out}/hparams.json").read_text())
    raw = pd.read_parquet(f"{out}/lear_raw_{tag}.parquet")
    fc = to_hourly(raw, {"lear_price": lock["choice"]})
    fl = raw.groupby(["zone", "date"]).fit_last.max().rename("fit_last").reset_index()
    fc = fc.merge(fl, on=["zone", "date"])
    fc["lead"] = 1
    fc["issue_utc"] = pd.to_datetime(fc.date) - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)
    # fit_end: the end (UTC) of the last calibration market day, i.e. the latest settled hour used
    fc["fit_end"] = (pd.to_datetime(fc.fit_last) + pd.Timedelta(days=1)).dt.tz_localize(ATH).dt.tz_convert("UTC").dt.tz_localize(None)
    fc = fc[["zone", "t", "model", "prediction", "lead", "issue_utc", "fit_end", "date"]]
    fc.to_parquet(f"{out}/lear_forecasts_{tag}.parquet")
    fc.to_csv(f"{out}/lear_forecasts_{tag}.csv.gz", index=False)
    print(f"exported {len(fc)} rows; {fc.zone.nunique()} zones; {fc.date.min()}..{fc.date.max()}")
    return fc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["prices", "run", "select", "export"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH"))
    ap.add_argument("--start"); ap.add_argument("--end")
    ap.add_argument("--windows", default=",".join(map(str, WINDOWS)))
    ap.add_argument("--zones", default=",".join(ZONES))
    ap.add_argument("--procs", type=int, default=8)
    ap.add_argument("--tag")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.cmd == "prices":
        import duckdb
        con = duckdb.connect(a.extract, read_only=True)
        h = sdac_hourly(con)
        h.to_parquet(f"{a.out}/sdac_hourly.parquet")
        print(h.groupby("zone").t.agg(["min", "max", "size"]))
    elif a.cmd == "run":
        run(a.out, a.start, a.end, [int(w) for w in a.windows.split(",")], a.zones.split(","), a.procs, a.tag)
    elif a.cmd == "select":
        select(a.out, a.tag)
    else:
        export(a.out, a.tag)


if __name__ == "__main__":
    main()
