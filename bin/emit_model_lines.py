#!/usr/bin/env python3
"""emit_model_lines.py — daily emitter for the website's dashed model lines.

For each target day T (default: today-2 .. today+7, UTC):
  physics base = the freshest weather-track forecast for T (simulations.forecast_prices);
  hybrid_gbm   = base + per-zone GBM residual corrector (frozen models trained on
                 the 2024-07..2026-06 cv37 residuals; features = the zone's book
                 fundamentals taken from the same-weekday book 7 (or 14) days back
                 — weekly persistence of fundamentals, all ex-ante — plus fuels
                 and calendar);
  stats_gbm    = the pure-stats GBM (settled lags), emitted ONLY where its lags
                 legally exist (T no later than last-settled-day + 1).
Rows are UPSERTED into simulations.model_lines (overlay series, not a vintage).

Feature sources, in order: data/backfill_books_cv37/<F>.parquet, then
data/model_line_feats/<F>.csv (grown daily by bin/capture_book_features.jl),
where F = T-7 or T-14. Missing feature day => T is skipped (honest gap).

Usage: emit_model_lines.py [START END]   (ISO dates, inclusive)
Env: ENERGY_CONN_STR (from .env), MODEL_LINES_CV (default 37).
First run trains and pickles the models to data/model_lines_train/models.joblib;
delete that file to retrain (e.g. after extending the training parquet).
"""
import os, sys, glob, datetime as dt, warnings
warnings.filterwarnings("ignore")
import numpy as np, pandas as pd, duckdb, joblib, psycopg2
from sklearn.ensemble import HistGradientBoostingRegressor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRAIN = os.path.join(ROOT, "data", "model_lines_train")
# Book directory and record version are bound together (cv39 review §6): the
# emitter used to hard-code the cv37 books while the record had moved on, so
# the site's model lines were not the model being evaluated. MODEL_LINES_CV
# selects both; the run fails loudly if that book directory is absent rather
# than silently publishing a stale vintage.
# The frozen models in data/model_lines_train were fitted on the cv37 book
# features (probe2y37_dataset.parquet), so the book directory the emitter reads
# MUST be the one they were trained on — reading cv39 books with a cv37-trained
# residual model is the version mismatch the 2026-09-13 review flagged. The
# trained-on version travels with the artifact (models.joblib carries "book_cv"
# from the retrain onwards; a legacy artifact without it is assumed cv37) and
# the run aborts on a mismatch instead of quietly publishing.
TRAIN_CV_DEFAULT = 37
CV = int(os.environ.get("MODEL_LINES_CV", str(TRAIN_CV_DEFAULT)))
BOOKS = os.path.join(ROOT, "data", f"backfill_books_cv{CV}")
FEATS_DIR = os.path.join(ROOT, "data", "model_line_feats")
PHYS_FEATS = ["hour", "month", "D", "res_sh", "imp_sh", "bst_sh", "margin", "gas", "co2"]
STATS_FEATS = ["lag24", "lag48", "lag168", "roll7", "hour", "dow", "month", "gas", "co2", "D", "res_sh"]


def conn():
    return psycopg2.connect(os.environ["ENERGY_CONN_STR"])


def last_close(csv, day):
    df = pd.read_csv(csv, header=None, names=["date", "close"], parse_dates=["date"])
    s = df[df.date < pd.Timestamp(day) - pd.Timedelta(days=1)]
    return float(s.close.iloc[-1]) if len(s) else np.nan


def refresh_fuel_csvs(cx):
    """Rewrite probe_ttf.csv / probe_eua.csv from yfinance.* so `last_close`
    sees the latest D-2 closes (the CSVs were static snapshots ending
    2026-08-25 while TTF kept moving)."""
    for csv, table in (("probe_ttf.csv", "yfinance.ttf_f"), ("probe_eua.csv", "yfinance.eua_co2")):
        df = pd.read_sql(f"SELECT date, close FROM {table} WHERE close IS NOT NULL ORDER BY date", cx)
        if df.empty:
            continue
        df["date"] = pd.to_datetime(df.date).dt.strftime("%Y-%m-%d 00:00:00")
        df.to_csv(os.path.join(TRAIN, csv), header=False, index=False)
        print(f"fuel csv {csv}: {len(df)} rows through {df.date.iloc[-1][:10]}", flush=True)


def _check_binding(models):
    """Abort unless the books being read are the ones the models were fitted on."""
    book_cv = models.get("book_cv", TRAIN_CV_DEFAULT) if isinstance(models, dict) else TRAIN_CV_DEFAULT
    if int(book_cv) != CV:
        raise SystemExit(
            f"model lines: models.joblib was trained on cv{book_cv} book features but "
            f"MODEL_LINES_CV={CV} selects {BOOKS}. Retrain on the new books "
            f"(delete models.joblib with a cv{CV} probe dataset in place) or set "
            f"MODEL_LINES_CV={book_cv}.")
    if not os.path.isdir(BOOKS):
        have = sorted(d for d in os.listdir(os.path.join(ROOT, "data")) if d.startswith("backfill_books_"))
        raise SystemExit(f"model lines: book directory {BOOKS} is missing (have: {have})")
    print(f"model lines: book_cv={book_cv} books={os.path.basename(BOOKS)}", flush=True)
    return models


def load_models():
    path = os.path.join(TRAIN, "models.joblib")
    if os.path.exists(path):
        return _check_binding(joblib.load(path))
    print("training frozen models ...", flush=True)
    hist = pd.read_parquet(os.path.join(TRAIN, "probe2y37_dataset.parquet")).dropna(subset=["resid"])
    hyb = {}
    for z, d in hist.groupby("zone"):
        if len(d) < 800:
            continue
        m = HistGradientBoostingRegressor(max_depth=4, max_iter=150, learning_rate=0.06,
                                          l2_regularization=1.0, random_state=0)
        hyb[z] = m.fit(d[PHYS_FEATS], d.resid)
    st = hist[["zone", "k", "D", "res_sh", "gas", "co2", "settled"]].copy()
    st["t"] = pd.to_datetime(st.k, format="%Y-%m-%dT%H", utc=True)
    st = st.sort_values(["zone", "t"])
    g = st.groupby("zone").settled
    st["lag24"] = g.shift(24); st["lag48"] = g.shift(48); st["lag168"] = g.shift(168)
    st["roll7"] = g.shift(24).rolling(168).mean().reset_index(0, drop=True)
    st["hour"] = st.t.dt.hour; st["dow"] = st.t.dt.dayofweek; st["month"] = st.t.dt.month
    sta = {}
    for z, d in st.groupby("zone"):
        d = d.dropna(subset=["lag168", "settled"])
        if len(d) < 800:
            continue
        m = HistGradientBoostingRegressor(max_depth=5, max_iter=250, learning_rate=0.06,
                                          l2_regularization=1.0, random_state=0)
        sta[z] = m.fit(d[STATS_FEATS], d.settled)
    models = {"hybrid": hyb, "stats": sta, "book_cv": CV}
    joblib.dump(models, path)
    print(f"pickled {len(hyb)}/{len(sta)} models -> {path}", flush=True)
    return models


def features_for(target):
    """Book fundamentals for target day via T-7 / T-14 weekly persistence."""
    con = duckdb.connect()
    for back in (7, 14):
        f = target - dt.timedelta(days=back)
        pq = os.path.join(BOOKS, f"{f}.parquet")
        csv = os.path.join(FEATS_DIR, f"{f}.csv")
        if os.path.exists(pq):
            b = con.sql(f"select zone, ts, side, mw, owner from '{pq}'").df()
            b["k"] = pd.to_datetime(b.ts, utc=True).dt.strftime("%Y-%m-%dT%H")
            rows = []
            for (z, k), g in b.groupby(["zone", "k"]):
                sup = g[g.side == "supply"]; D = g[g.side == "demand"].mw.sum()
                if D <= 0:
                    continue
                rows.append(dict(zone=z, k=k, D=D,
                                 res_sh=sup[sup.owner == "RES"].mw.sum() / D,
                                 imp_sh=sup[sup.owner == "IMPORT"].mw.sum() / D,
                                 bst_sh=sup[sup.owner == "BACKSTOP"].mw.sum() / D,
                                 margin=sup.mw.sum() / D))
            f_df = pd.DataFrame(rows)
        elif os.path.exists(csv):
            t = pd.read_csv(csv)
            t["res_sh"] = t.res_mw / t.D; t["imp_sh"] = t.imp_mw / t.D
            t["bst_sh"] = t.bst_mw / t.D; t["margin"] = t.stot / t.D
            f_df = t[["zone", "k", "D", "res_sh", "imp_sh", "bst_sh", "margin"]]
        else:
            continue
        kt = pd.to_datetime(f_df.k, format="%Y-%m-%dT%H") + pd.Timedelta(days=back)
        f_df = f_df.copy(); f_df["k"] = kt.dt.strftime("%Y-%m-%dT%H")
        return f_df, back
    return None, None


def main():
    today = dt.date.today()
    if len(sys.argv) >= 3:
        d0, d1 = dt.date.fromisoformat(sys.argv[1]), dt.date.fromisoformat(sys.argv[2])
    else:
        d0, d1 = today - dt.timedelta(days=2), today + dt.timedelta(days=7)
    models = load_models()
    cx = conn(); cur = cx.cursor()
    refresh_fuel_csvs(cx)
    # physics base: freshest weather-track forecast per (zone, hour) in window
    cur.execute("""
        SELECT bidding_zone, (date_time_utc AT TIME ZONE 'UTC'), price_eur_mwh
        FROM (
          SELECT bidding_zone, date_time_utc, price_eur_mwh,
                 ROW_NUMBER() OVER (PARTITION BY bidding_zone, date_time_utc
                                    ORDER BY lead_days ASC, prediction_made_utc DESC) rn
          FROM simulations.forecast_prices
          WHERE input_mode LIKE 'weather%%' AND date_time_utc >= %s::date
            AND date_time_utc < %s::date + INTERVAL '1 day') x
        WHERE rn = 1""", (d0.isoformat(), d1.isoformat()))
    base = pd.DataFrame(cur.fetchall(), columns=["zone", "t", "sim"])
    base["k"] = pd.to_datetime(base.t, utc=True).dt.strftime("%Y-%m-%dT%H")
    # settled (for stats lags): everything available before the window's end
    cur.execute("""
        SELECT map_code, (date_time_utc AT TIME ZONE 'UTC'), AVG(price_currency_mwh)
        FROM entsoe.energy_prices
        WHERE contract_type='Day-ahead' AND currency='EUR'
          AND date_time_utc >= %s::date - INTERVAL '10 days'
        GROUP BY 1, 2""", (d0.isoformat(),))
    st = pd.DataFrame(cur.fetchall(), columns=["zone", "t", "p"])
    st["t"] = pd.to_datetime(st.t, utc=True)
    last_settled = st.t.max().date() if len(st) else d0 - dt.timedelta(days=10)
    out = []
    for n in range((d1 - d0).days + 1):
        T = d0 + dt.timedelta(days=n)
        feats, back = features_for(T)
        if feats is None:
            print(f"{T}: no feature source (T-7/T-14 book missing) — skipped", flush=True)
            continue
        feats = feats[feats.k.str[:10] == T.isoformat()].copy()
        feats["hour"] = feats.k.str[11:13].astype(int)
        feats["month"] = int(T.month)
        feats["gas"] = last_close(os.path.join(TRAIN, "probe_ttf.csv"), T)
        feats["co2"] = last_close(os.path.join(TRAIN, "probe_eua.csv"), T)
        bT = base[base.k.str[:10] == T.isoformat()]
        m = feats.merge(bT[["zone", "k", "sim"]], on=["zone", "k"], how="inner")
        if not len(m):
            print(f"{T}: no physics forecast rows — skipped", flush=True)
            continue
        for z, gz in m.groupby("zone"):
            mh = models["hybrid"].get(z)
            if mh is not None:
                pred = gz.sim.values + mh.predict(gz[PHYS_FEATS])
                out += [(z, k + ":00:00+00", "hybrid_gbm", float(p), CV)
                        for k, p in zip(gz.k, pred)]
        # stats: only if lag24 exists (T <= last settled + 1)
        if T <= last_settled + dt.timedelta(days=1):
            sT = m.copy()
            sT["t"] = pd.to_datetime(sT.k, format="%Y-%m-%dT%H", utc=True)
            for lag, col in ((24, "lag24"), (48, "lag48"), (168, "lag168")):
                lk = st.copy(); lk["t"] = lk.t + pd.Timedelta(hours=lag)
                sT = sT.merge(lk.rename(columns={"p": col})[["zone", "t", col]],
                              on=["zone", "t"], how="left")
            r7 = st.set_index("t").groupby("zone").p.rolling("168h").mean().reset_index()
            r7["t"] = r7.t + pd.Timedelta(hours=24)
            sT = sT.merge(r7.rename(columns={"p": "roll7"}), on=["zone", "t"], how="left")
            sT["dow"] = sT.t.dt.dayofweek
            sT = sT.dropna(subset=["lag24", "lag48", "lag168", "roll7"])
            for z, gz in sT.groupby("zone"):
                ms = models["stats"].get(z)
                if ms is not None and len(gz):
                    pred = ms.predict(gz[STATS_FEATS])
                    out += [(z, k + ":00:00+00", "stats_gbm", float(p), CV)
                            for k, p in zip(gz.k, pred)]
        print(f"{T}: emitted (features from T-{back})", flush=True)
    if out:
        cur.executemany("""
            INSERT INTO simulations.model_lines
                (bidding_zone, date_time_utc, model, price_eur_mwh, code_version)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (bidding_zone, date_time_utc, model, code_version)
            DO UPDATE SET price_eur_mwh = EXCLUDED.price_eur_mwh,
                          generated_at = now()""", out)
        cx.commit()
    print(f"EMITTED {len(out)} rows for {d0}..{d1}")


if __name__ == "__main__":
    main()
