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
Gate/physics/settled publication cutoffs default ON; MODEL_LINES_STRICT_ASOF=0
restores the pre-strict #439 path;
MODEL_LINES_REWRITE_PAST=1 allows an explicit backfill past the gate. Each run
records issue_utc and a source_manifest; these do not reconstruct old vintages.

Feature sources, in order: data/backfill_books_cv37/<F>.parquet, then
data/model_line_feats/<F>.csv (grown daily by bin/capture_book_features.jl),
where F = T-7 or T-14. Missing feature day => T is skipped (honest gap).

Usage: emit_model_lines.py [START END]   (ISO dates, inclusive)
Env: ENERGY_CONN_STR (from .env), MODEL_LINES_CV (default 37) for the book/artifact
version, MODEL_LINES_BASE_CV (default: MODEL_LINES_CV) for the PHYSICS BASE's record
version, MODEL_LINES_ALLOW_MIXED_BASE=1 to publish on whatever version is freshest.
First run trains and pickles the models to data/model_lines_train/models.joblib;
delete that file to retrain (e.g. after extending the training parquet).
"""
import os, sys, glob, datetime as dt, warnings, json, importlib
from zoneinfo import ZoneInfo
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
# The training dataset's own provenance decides the trained-on version: the
# file name carries it (probe2y<CV>_dataset.parquet) and TRAIN_MANIFEST, when
# present, overrides. Deriving it from the dataset — rather than from the
# requested CV — is what stops a fresh train on cv37 data being stamped cv40
# (review 2026-09-13, P1).
TRAIN_CV_DEFAULT = 37
TRAIN_MANIFEST = os.path.join(TRAIN, "manifest.json")


def training_dataset():
    """(path, book_cv) of the dataset the frozen models are fitted on."""
    if os.path.exists(TRAIN_MANIFEST):
        import json
        man = json.load(open(TRAIN_MANIFEST))
        path = os.path.join(TRAIN, man["dataset"])
        if not os.path.exists(path):
            raise SystemExit(f"model lines: manifest names {man['dataset']}, which is missing")
        return path, int(man["book_cv"])
    import glob as _glob, re as _re
    cands = sorted(_glob.glob(os.path.join(TRAIN, "probe2y*_dataset.parquet")))
    if len(cands) != 1:
        raise SystemExit(f"model lines: cannot identify the training dataset ({cands}); "
                         f"write {TRAIN_MANIFEST} with {{'dataset': ..., 'book_cv': N}}")
    m = _re.search(r"probe2y(\d+)_dataset", os.path.basename(cands[0]))
    if not m:
        raise SystemExit(f"model lines: {cands[0]} does not carry a book version in its name")
    return cands[0], int(m.group(1))
CV = int(os.environ.get("MODEL_LINES_CV", str(TRAIN_CV_DEFAULT)))
# The PHYSICS BASE's own version (#389). The residual model is fitted against
# the sim prices of ONE record version; adding it to a base of another version
# is the same mismatch PR #386 closed for the book features, one table over.
# `simulations.forecast_prices` carries cv32/34/35/37/38/39 rows side by side
# and the emitter used to take the freshest per (zone, hour) regardless, so a
# single emitted line could sit on a mixed base — and today it sits entirely on
# cv39 while the artifact is cv37.
#
# MODEL_LINES_BASE_CV pins it; unset it follows MODEL_LINES_CV, i.e. the version
# the artifact was trained against. A window with no row of that version emits
# no HYBRID line for those cells and warns loudly — the mismatch is the finding,
# not something to paper over. The stats line never reads the physics price and
# is emitted regardless (a pinned-empty window used to SystemExit and take it
# down too). MODEL_LINES_ALLOW_MIXED_BASE=1 restores the old
# freshest-wins behaviour, and even then the version mix is printed.
BASE_CV = int(os.environ.get("MODEL_LINES_BASE_CV", str(CV)))
ALLOW_MIXED_BASE = bool(os.environ.get("MODEL_LINES_ALLOW_MIXED_BASE", ""))
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


def _check_binding(models, book_cv=None):
    """Abort unless the books being read are the ones the models were fitted on."""
    if book_cv is None:
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
    ds_path, ds_cv = training_dataset()
    # validate BEFORE training: a fresh train must not silently relabel the
    # dataset's book version as the requested one.
    if ds_cv != CV:
        raise SystemExit(
            f"model lines: no cached models and the training dataset {os.path.basename(ds_path)} "
            f"is cv{ds_cv}, but MODEL_LINES_CV={CV}. Build a cv{CV} probe dataset "
            f"(and a manifest naming it) or set MODEL_LINES_CV={ds_cv}.")
    print(f"training frozen models from {os.path.basename(ds_path)} (book_cv={ds_cv}) ...", flush=True)
    hist = pd.read_parquet(ds_path).dropna(subset=["resid"])
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
    models = {"hybrid": hyb, "stats": sta, "book_cv": ds_cv,
              "dataset": os.path.basename(ds_path)}
    _check_binding(models, book_cv=ds_cv)   # validate again before writing
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


BASE_SQL = """
    SELECT bidding_zone, (date_time_utc AT TIME ZONE 'UTC'), price_eur_mwh,
           code_version, (prediction_made_utc AT TIME ZONE 'UTC')
    FROM (
      SELECT bidding_zone, date_time_utc, price_eur_mwh, code_version,
             prediction_made_utc,
             ROW_NUMBER() OVER (PARTITION BY bidding_zone, date_time_utc
                                ORDER BY lead_days ASC, prediction_made_utc DESC) rn
      FROM simulations.forecast_prices
      WHERE input_mode LIKE 'weather%%' AND date_time_utc >= %s::date
        AND NOT COALESCE(is_retro, FALSE)
        AND date_time_utc < %s::date + INTERVAL '1 day'
        AND (%s::int IS NULL OR code_version = %s::int)
        {cutoff}) x
    WHERE rn = 1"""


def utc_issue(value=None):
    """One timezone-aware issue instant for the whole run (injectable offline)."""
    t = pd.Timestamp.now(tz="UTC") if value is None else pd.Timestamp(value)
    if t.tzinfo is None:
        raise ValueError("issue_utc must include a timezone")
    return t.tz_convert("UTC")


def market_date(value):
    """Website delivery/issue date, independent of UTC batching and lag offsets."""
    return utc_issue(value).tz_convert("Europe/Athens").date()


def strict_asof(env=os.environ):
    """Owner-approved default: only explicit 0 disables the issuance guards."""
    return env.get("MODEL_LINES_STRICT_ASOF", "1") != "0"


def gate_utc(target):
    """Day-ahead noon Brussels gate before the Athens delivery date."""
    return pd.Timestamp(dt.datetime.combine(target - dt.timedelta(days=1),
                        dt.time(12), tzinfo=ZoneInfo("Europe/Brussels"))).tz_convert("UTC")


def may_emit(target, issue, strict=False, rewrite_past=False):
    return not strict or rewrite_past or utc_issue(issue) < gate_utc(target)


def gate_run_summary(base, issue, strict, rewrite_past=False):
    """One next-day gate line; counts the weather domain, not trained-model rows."""
    day = market_date(issue) + dt.timedelta(days=1)
    gate = gate_utc(day)
    delivery_days = pd.to_datetime(base.t, utc=True).dt.tz_convert("Europe/Athens").dt.date
    cells = int((delivery_days == day).sum())
    kept = cells if may_emit(day, issue, strict, rewrite_past) else 0
    return (f"model lines gate: delivery_day={day} gate_utc={gate.isoformat()} "
            f"issue_utc={utc_issue(issue).isoformat()} strict_asof={strict} "
            f"rewrite_past={rewrite_past} scope=next_day_weather_cells "
            f"cells_kept={kept} cells_dropped={cells-kept}")


def physics_base(cur, d0, d1, pin, issue=None):
    """Select the legacy base, optionally limiting vintages BEFORE ranking."""
    cutoff = "AND prediction_made_utc <= %s" if issue is not None else ""
    args = [d0.isoformat(), d1.isoformat(), pin, pin]
    if issue is not None:
        args.append(utc_issue(issue).to_pydatetime())
    cur.execute(BASE_SQL.format(cutoff=cutoff), args)
    base = pd.DataFrame(cur.fetchall(), columns=["zone", "t", "sim", "base_cv", "prediction_made_utc"])
    base["prediction_made_utc"] = pd.to_datetime(base.prediction_made_utc, utc=True)
    base["k"] = pd.to_datetime(base.t, utc=True).dt.strftime("%Y-%m-%dT%H")
    return base


def target_helper():
    # PR C owns this module. Keep the highest_seq fallback until it lands;
    # errors inside an installed helper must never silently select another target.
    bindir = os.path.join(ROOT, "bin")
    if bindir not in sys.path:
        sys.path.insert(0, bindir)
    try:
        return importlib.import_module("da_target")
    except ModuleNotFoundError as exc:
        if exc.name != "da_target":
            raise
        return None


def target_policy():
    helper = target_helper()
    if helper is not None:
        return helper.policy()
    policy = (os.environ.get("EUPHEMIA_DA_TARGET") or "highest_seq").strip().lower()
    if policy != "highest_seq":
        raise ValueError("EUPHEMIA_DA_TARGET requires bin/da_target.py for sdac; "
                         "fallback supports highest_seq only")
    return policy


def canonical_settled(raw, issue=None):
    """Single auction per interval, hourly lags; filter revisions before selection.

    raw has PR C's z/seq/res/t/p/u schema. NULL or absent publication stamps
    are unverifiable in strict mode, never treated as evidence of availability.
    """
    raw = raw.copy()
    raw["t"] = pd.to_datetime(raw.t, utc=True).dt.tz_localize(None)
    raw["u"] = pd.to_datetime(raw.u, utc=True).dt.tz_localize(None)
    if issue is not None:
        issue = utc_issue(issue).tz_localize(None)
        unverifiable = set(raw.loc[raw.u.isna(), "z"])
        available = raw.u.notna() & (raw.u <= issue) & ~raw.z.isin(unverifiable)
        for zone in sorted(unverifiable | (set(raw.z) - set(raw.loc[available, "z"]))):
            warn(f"strict as-of: {zone} settled vintages unavailable/unverifiable at {issue} UTC; fail closed")
        raw = raw[available].copy()
    helper = target_helper()
    policy = target_policy()
    if helper is not None:
        if policy == "sdac":
            act, excluded, _ = helper.sdac_hourly(raw)
            if len(excluded):
                print("model lines: target exclusions " + str(excluded.reason.value_counts().to_dict()), flush=True)
        else:
            act = helper.highest_seq_hourly(raw)
    else:
        # Same pure highest_seq contract as PR C. Never average auctions.
        raw["seq"] = raw.seq.fillna("").astype(str).str.strip()
        raw["seqn"] = pd.to_numeric(raw.seq, errors="coerce")
        raw = raw.sort_values(["z", "t", "seqn", "u"],
                              ascending=[True, True, False, False],
                              na_position="last", kind="mergesort")
        raw = raw.drop_duplicates(["z", "t"], keep="first")
        raw["h"] = raw.t.dt.floor("h")
        act = raw.groupby(["z", "h"], as_index=False).p.mean().rename(columns={"h": "t", "p": "act"})
    st = act.rename(columns={"z": "zone", "act": "p"})[["zone", "t", "p"]].copy()
    st["t"] = pd.to_datetime(st.t, utc=True)
    return st.sort_values(["zone", "t"]).reset_index(drop=True)


def settled_history(cur, d0, d1, issue=None):
    cur.execute("""SELECT column_name FROM information_schema.columns
        WHERE table_schema='entsoe' AND table_name='energy_prices'""")
    has_update = "update_time_utc" in {row[0] for row in cur.fetchall()}
    update = "(update_time_utc AT TIME ZONE 'UTC')" if has_update else "NULL"
    cur.execute(f"""SELECT map_code, trim(coalesce(sequence, '')), trim(resolution_code),
        (date_time_utc AT TIME ZONE 'UTC'), price_currency_mwh, {update}
        FROM entsoe.energy_prices
        WHERE contract_type='Day-ahead' AND currency='EUR' AND area_type_code LIKE 'BZN%%'
          AND price_currency_mwh IS NOT NULL
          AND date_time_utc >= %s::date - INTERVAL '10 days'
          AND date_time_utc < %s::date + INTERVAL '1 day'""", (d0.isoformat(), d1.isoformat()))
    raw = pd.DataFrame(cur.fetchall(), columns=["z", "seq", "res", "t", "p", "u"])
    return canonical_settled(raw, issue)


def zone_last_settled(st, issue):
    # Early EXAA for tomorrow must not authorize D+2, even in its own zone.
    cap = market_date(issue)
    return {z: min(market_date(g.t.max()), cap) for z, g in st.groupby("zone")}


MODEL_LINE_COLUMNS = {
    "base_code_version": "integer",
    "issue_utc": "timestamptz",
    "source_manifest": "jsonb",
}


def ensure_metadata_columns(cx):
    """Catalog-first additive DDL, bounded locks, no ALTER on normal runs (#424)."""
    cur = cx.cursor()
    cur.execute("""SELECT column_name FROM information_schema.columns
        WHERE table_schema='simulations' AND table_name='model_lines'""")
    have = {row[0] for row in cur.fetchall()}
    missing = [(c, t) for c, t in MODEL_LINE_COLUMNS.items() if c not in have]
    if not missing:
        return True
    cx.commit()  # end the read-only catalog/source transaction before the DDL
    try:
        cur.execute("BEGIN")
        cur.execute("SET LOCAL lock_timeout = '5s'")
        cur.execute("ALTER TABLE simulations.model_lines " + ", ".join(
            f"ADD COLUMN IF NOT EXISTS {c} {t}" for c, t in missing))
        cx.commit()
        return True
    except Exception as exc:
        cx.rollback()
        warn(f"model lines: metadata migration failed; no rows written: {exc}")
        return False


def provenance_rows(rows, base_h, issue, back, strict):
    """Append issuance/source metadata without changing model values."""
    vintages = {(r.zone, r.k): getattr(r, "prediction_made_utc", None)
                for r in base_h.itertuples()}
    out = []
    policy = target_policy()
    for row in rows:
        z, timestamp, model, _, _, base_cv = row
        vintage = vintages.get((z, timestamp[:13])) if model == "hybrid_gbm" else None
        manifest = {"physics_prediction_made_utc": None if pd.isna(vintage) else utc_issue(vintage).isoformat(),
                    "base_code_version": base_cv, "book_cv": CV, "feature_back_days": back,
                    "target_policy": policy, "strict_asof": strict}
        out.append((*row, utc_issue(issue).to_pydatetime(), json.dumps(manifest, sort_keys=True)))
    return out


UPSERT_SQL = """
    INSERT INTO simulations.model_lines
        (bidding_zone, date_time_utc, model, price_eur_mwh, code_version,
         base_code_version, issue_utc, source_manifest)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb)
    ON CONFLICT (bidding_zone, date_time_utc, model, code_version)
    DO UPDATE SET price_eur_mwh = EXCLUDED.price_eur_mwh,
                  base_code_version = EXCLUDED.base_code_version,
                  issue_utc = EXCLUDED.issue_utc,
                  source_manifest = EXCLUDED.source_manifest,
                  generated_at = now()
    WHERE (model_lines.price_eur_mwh, model_lines.base_code_version,
           model_lines.issue_utc, model_lines.source_manifest)
          IS DISTINCT FROM
          (EXCLUDED.price_eur_mwh, EXCLUDED.base_code_version,
           EXCLUDED.issue_utc, EXCLUDED.source_manifest)"""


# The source SELECT rejects late inserts. The conflict predicate is evaluated
# after obtaining the row lock, so it must recheck wall time as well: a writer
# can enter before gate and finish a conflicting-row lock wait after gate.
# clock_timestamp() is wall time; now() is frozen at transaction start.
UPSERT_STRICT_SQL = UPSERT_SQL.replace(
    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb)",
    "SELECT %s, %s, %s, %s, %s, %s, %s, %s::jsonb WHERE clock_timestamp() < %s"
) + "\n    AND clock_timestamp() < %s"


def _mix(base):
    mix = base.base_cv.value_counts().sort_index()
    return ", ".join(f"cv{int(v)}={int(n)}" for v, n in mix.items()) if len(mix) else "NONE"


def warn(msg):
    """Loud: stderr, a GitHub Actions annotation when run there, and stdout."""
    print(f"WARNING: {msg}", file=sys.stderr, flush=True)
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::warning::{msg}", flush=True)
    print(f"WARNING: {msg}", flush=True)


def lines_for_day(T, feats, base_h, base_any, st, last_settled, models,
                  issue=None, strict=False, rewrite_past=False):
    """Rows for target day T: (rows, hybrid_status, stats_status).

    The two lines have different inputs, so they are gated independently:
      hybrid_gbm = pinned physics base + residual -> needs a base row of the
                   pinned version (base_h); without one the HYBRID line is
                   skipped for that cell and nothing else is.
      stats_gbm  = settled lags + book fundamentals; it never reads the physics
                   price, so a missing pinned base must not take it down (the
                   #392 SystemExit did exactly that: production on cv43 + a
                   cv37 artifact = zero pinned rows = both lines gone). Its
                   domain stays the cells that carry ANY weather-track
                   forecast (base_any), i.e. unchanged from before the pin, and
                   its rows record base_code_version NULL — it has no base.
    """
    if strict:
        if issue is None:
            raise ValueError("strict mode requires issue_utc")
        def asof_base(base):
            if "prediction_made_utc" not in base:
                return base.iloc[:0]
            stamp = pd.to_datetime(base.prediction_made_utc, utc=True)
            return base[stamp.notna() & (stamp <= utc_issue(issue))]
        base_h, base_any = asof_base(base_h), asof_base(base_any)
    feats = feats[feats.k.str[:10] == T.isoformat()].copy()
    if strict and len(feats):
        # A UTC batch straddles two Athens delivery dates. Gate each cell, too.
        feats = feats.loc[feats.k.map(lambda k: may_emit(
            market_date(k + ":00:00Z"), issue, True, rewrite_past))]
        if feats.empty:
            return [], "skipped (delivery gate passed)", "skipped (delivery gate passed)"
    feats["hour"] = feats.k.str[11:13].astype(int)
    feats["month"] = int(T.month)
    fuel_day = min(T, utc_issue(issue).date() + dt.timedelta(days=1)) if strict else T
    feats["gas"] = last_close(os.path.join(TRAIN, "probe_ttf.csv"), fuel_day)
    feats["co2"] = last_close(os.path.join(TRAIN, "probe_eua.csv"), fuel_day)
    out = []
    mh_df = feats.merge(base_h[base_h.k.str[:10] == T.isoformat()][["zone", "k", "sim", "base_cv"]],
                        on=["zone", "k"], how="inner")
    if len(mh_df):
        for z, gz in mh_df.groupby("zone"):
            mh = models["hybrid"].get(z)
            if mh is not None:
                pred = gz.sim.values + mh.predict(gz[PHYS_FEATS])
                out += [(z, k + ":00:00+00", "hybrid_gbm", float(p), CV, int(b))
                        for k, p, b in zip(gz.k, pred, gz.base_cv)]
        hyb = "emitted"
    else:
        hyb = "SKIPPED (no physics base at the pinned version)"
    sT = feats.merge(base_any[base_any.k.str[:10] == T.isoformat()][["zone", "k"]],
                     on=["zone", "k"], how="inner")
    due = last_settled if isinstance(last_settled, dict) else {z: last_settled for z in sT.zone.unique()}
    if issue is not None:
        due = {z: min(day, market_date(issue)) for z, day in due.items()}
    had_domain = len(sT)
    sT["t"] = pd.to_datetime(sT.k, format="%Y-%m-%dT%H", utc=True)
    delivery_days = sT.t.dt.tz_convert("Europe/Athens").dt.date
    allowed_days = sT.zone.map(lambda z: due[z] + dt.timedelta(days=1) if z in due else dt.date.min)
    sT = sT.loc[delivery_days <= allowed_days]
    if not had_domain:
        sta = "skipped (no physics forecast rows for any version)"
    elif not len(sT):
        sta = "not due (lag24 not settled yet)"
    else:
        for lag, col in ((24, "lag24"), (48, "lag48"), (168, "lag168")):
            lk = st.copy(); lk["t"] = lk.t + pd.Timedelta(hours=lag)
            sT = sT.merge(lk.rename(columns={"p": col})[["zone", "t", col]],
                          on=["zone", "t"], how="left")
        r7 = st.set_index("t").groupby("zone").p.rolling("168h").mean().reset_index()
        r7["t"] = r7.t + pd.Timedelta(hours=24)
        sT = sT.merge(r7.rename(columns={"p": "roll7"}), on=["zone", "t"], how="left")
        sT["dow"] = sT.t.dt.dayofweek
        sT = sT.dropna(subset=["lag24", "lag48", "lag168", "roll7"])
        n0 = len(out)
        for z, gz in sT.groupby("zone"):
            ms = models["stats"].get(z)
            if ms is not None and len(gz):
                pred = ms.predict(gz[STATS_FEATS])
                out += [(z, k + ":00:00+00", "stats_gbm", float(p), CV, None)
                        for k, p in zip(gz.k, pred)]
        sta = "emitted" if len(out) > n0 else "skipped (no settled lags)"
    return out, hyb, sta


def main():
    issue = utc_issue()
    strict = strict_asof()
    rewrite_past = os.environ.get("MODEL_LINES_REWRITE_PAST") == "1"
    today = issue.date()
    if len(sys.argv) >= 3:
        d0, d1 = dt.date.fromisoformat(sys.argv[1]), dt.date.fromisoformat(sys.argv[2])
    else:
        d0, d1 = today - dt.timedelta(days=2), today + dt.timedelta(days=7)
    policy = target_policy()  # validate before any model/database work
    models = load_models()
    cx = conn(); cur = cx.cursor()
    refresh_fuel_csvs(cx)
    # physics base for the HYBRID line: freshest weather-track forecast per
    # (zone, hour), PINNED to one record version (#389) unless explicitly
    # allowed to mix. The stats line does not use it (see lines_for_day).
    base_any = physics_base(cur, d0, d1, None, issue if strict else None)
    base_h = base_any if ALLOW_MIXED_BASE else physics_base(cur, d0, d1, BASE_CV, issue if strict else None)
    print(gate_run_summary(base_any, issue, strict, rewrite_past), flush=True)
    print("model lines: physics base " +
          ("PINNED to cv%d" % BASE_CV if not ALLOW_MIXED_BASE else "UNPINNED (mixed base allowed)") +
          " — hybrid cells by version: " + _mix(base_h) +
          "; all weather-track cells: " + _mix(base_any), flush=True)
    if not len(base_h):
        warn(f"model lines: HYBRID LINE SKIPPED for the whole window {d0}..{d1} — no "
             f"weather-track forecast rows at code_version {BASE_CV} (rows present: "
             f"{_mix(base_any)}). The residual artifact is bound to cv{CV}; adding it to a "
             f"base of another version is not the model that was evaluated. The stats line "
             f"is still emitted. To restore the hybrid: retrain/rebind the artifact to the "
             f"version production runs, set MODEL_LINES_BASE_CV to a version that exists, "
             f"or MODEL_LINES_ALLOW_MIXED_BASE=1 to publish on a mixed base deliberately.")
    st = settled_history(cur, d0, d1, issue if strict else None)
    last_settled = zone_last_settled(st, issue)
    print(f"model lines: issue_utc={issue.isoformat()} strict_asof={strict} "
          f"rewrite_past={rewrite_past} target={policy}", flush=True)
    out, hyb_skipped = [], []
    for n in range((d1 - d0).days + 1):
        T = d0 + dt.timedelta(days=n)
        last_delivery_day = market_date(pd.Timestamp(T, tz="UTC") + pd.Timedelta(hours=23))
        if not may_emit(last_delivery_day, issue, strict, rewrite_past):
            print(f"{T}: delivery gate passed — skipped (strict as-of)", flush=True)
            continue
        feats, back = features_for(T)
        if feats is None:
            print(f"{T}: no feature source (T-7/T-14 book missing) — skipped", flush=True)
            continue
        rows, hyb, sta = lines_for_day(T, feats, base_h, base_any, st, last_settled, models,
                                       issue, strict, rewrite_past)
        out += provenance_rows(rows, base_h, issue, back, strict)
        if hyb.startswith("SKIPPED"):
            hyb_skipped.append(T)
        print(f"{T}: hybrid {hyb}; stats {sta} (features from T-{back})", flush=True)
    if hyb_skipped and len(base_h):
        warn(f"model lines: hybrid line skipped on {len(hyb_skipped)} day(s) "
             f"({', '.join(map(str, hyb_skipped))}) — no cv{BASE_CV} physics base")
    if out and strict and not rewrite_past:
        # Loading/training can cross the gate. Recheck at publication as well.
        write_time = utc_issue()
        before = len(out)
        out = [r for r in out if may_emit(market_date(r[1]), write_time, True)]
        if before != len(out):
            warn(f"strict as-of: gate passed during run; dropped {before - len(out)} rows before write")
    if out:
        if not ensure_metadata_columns(cx):
            raise RuntimeError("model lines: required metadata unavailable; no emission")
        if strict and not rewrite_past:
            guarded = []
            for row in out:
                gate = gate_utc(market_date(row[1])).to_pydatetime()
                guarded.append((*row, gate, gate))
            cur.executemany(UPSERT_STRICT_SQL, guarded)
        else:
            cur.executemany(UPSERT_SQL, out)
        cx.commit()
    nh = sum(r[2] == "hybrid_gbm" for r in out)
    print(f"EMITTED {len(out)} rows for {d0}..{d1} (hybrid_gbm {nh}, stats_gbm {len(out) - nh})")


if __name__ == "__main__":
    main()
