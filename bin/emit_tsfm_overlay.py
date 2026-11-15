#!/usr/bin/env python3
"""emit_tsfm_overlay.py — DRAFT (owner decision): lead-1 TSFM price overlay + P(price <= 0).

A *prediction* overlay next to sim / gbm / stats. It reads settled prices, so it must never
feed the counterfactual. Experiment record: docs/experiments/tsfm-2026-11/README.md.

Per zone-hour of delivery day D (Europe/Athens market day):
  tsfm_median, tsfm_q10, tsfm_q90   zero-shot TSFM forecast (Chronos-2 default; Timestral selectable)
  p_le0_tsfm                        P(price <= 0) from the TSFM's 21 quantiles
  p_le0_logit                       agent collapse's D-1 logistic (bin/predict_collapse.py)
  p_le0                             unfitted 50/50 blend of the two (TSFM-only if the logistic is absent)
Per zone-day: p_any_le0_tsfm (max over hours: the Fréchet lower bound of P(any hour <= 0)),
p_any_le0_logit (collapse's direct day logistic) and their 50/50 blend p_any_le0.

Information set (enforced in `build_context` / `sim_known`, tested in test/test_tsfm_overlay.py):
  * settled prices strictly before the start of Athens day D (D-1's prices were auctioned on D-2);
  * --mode pregate0630: prices only, issue_utc = D-1 06:30 UTC;
  * --mode postsim: + the live lead-1 weather-track `sim` as a known-future covariate, using only
    sim rows with prediction_made_utc <= issue_utc, where issue_utc = the latest made time of D's
    lead-1 sim (08:16-10:06 UTC D-1 in Sep-Nov 2026); `after_gate` flags issue_utc > D-1 10:00 UTC.
  * input_mode in the output says which of the two a row is.

Modes of operation
  --dry-run (default): read the offline DuckDB extract (read-only) + live JSON for sim, write CSVs
                       to --output. No database access at all.
  --write            : read Postgres (ENERGY_CONN_STR), upsert tsfm lines into
                       simulations.model_lines and probabilities into
                       simulations.overlay_probabilities (DDL below; not created by this script).
Env: TSFM_MODEL = chronos2 (default, Apache-2.0) | timestral-209m | timestral-28m
     (Timestral weights: Modified-MIT with a revenue cap — see the README before using them).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

ATH = "Europe/Athens"
CTX_HOURS = 8192
GATE_UTC_HOUR = 10          # conservative: 12:00 CEST = 10:00 UTC; 11:00 UTC in winter
LINES_VERSION = 1           # code_version stamped on simulations.model_lines rows
MODELS = {"chronos2": "amazon/chronos-2",
          "timestral-209m": "mistralai/Timestral-209M",
          "timestral-28m": "mistralai/Timestral-28M"}
OVERLAY_DDL = """
CREATE TABLE IF NOT EXISTS simulations.overlay_probabilities (
    bidding_zone   text        NOT NULL,
    market_date    date        NOT NULL,
    date_time_utc  timestamptz,            -- NULL for the day-level row
    quantity       text        NOT NULL,   -- p_le0, p_le0_tsfm, p_le0_logit, p_any_le0, ...
    value          double precision,
    input_mode     text        NOT NULL,   -- pregate0630 | postsim
    issue_utc      timestamptz NOT NULL,
    model_version  text        NOT NULL,
    generated_at   timestamptz DEFAULT now(),
    UNIQUE (bidding_zone, market_date, date_time_utc, quantity, input_mode, model_version));
"""

PRICE_SQL = """
WITH d AS (
  SELECT map_code, date_time_utc, price_currency_mwh,
         row_number() OVER (PARTITION BY map_code, date_time_utc
            ORDER BY TRY_CAST(trim(sequence) AS INTEGER) DESC NULLS LAST, update_time_utc DESC) rn
  FROM entsoe.energy_prices
  WHERE contract_type='Day-ahead' AND area_type_code LIKE 'BZN%' AND price_currency_mwh IS NOT NULL
    AND date_time_utc >= ? AND date_time_utc < ?)
SELECT map_code zone, date_trunc('hour', date_time_utc) t, round(avg(price_currency_mwh), 8) price
FROM d WHERE rn = 1 GROUP BY 1, 2"""


# ----------------------------------------------------------------------------- information set
def day_start_utc(d) -> pd.Timestamp:
    """Start of Athens market day `d` as a naive UTC timestamp."""
    return pd.Timestamp(d).normalize().tz_localize(ATH).tz_convert("UTC").tz_localize(None)


def market_day_hours(d) -> pd.DatetimeIndex:
    """The 24 (23/25 on DST days) UTC hours of Athens market day `d`."""
    d = pd.Timestamp(d).normalize()
    return pd.date_range(day_start_utc(d), day_start_utc(d + pd.Timedelta(days=1)), freq="h", inclusive="left")


def build_context(prices: pd.DataFrame, zones, delivery, ctx_hours: int = CTX_HOURS):
    """(Z, ctx_hours) settled-price context ending strictly before the start of Athens day D."""
    cutoff = day_start_utc(delivery)
    grid = pd.date_range(cutoff - pd.Timedelta(hours=ctx_hours), cutoff, freq="h", inclusive="left")
    used = prices[(prices.t >= grid[0]) & (prices.t < cutoff)]
    wide = used.pivot_table(index="t", columns="zone", values="price").reindex(index=grid, columns=list(zones))
    assert grid[-1] < cutoff and (used.t < cutoff).all()
    return wide.to_numpy().T.astype(np.float32), cutoff, grid


def sim_known(sim: pd.DataFrame, delivery):
    """Lead-1 sim rows knowable at the post-sim issue time of D. Returns (rows, issue_utc).

    issue_utc = latest prediction_made_utc of D's lead-1 sim; history = all lead-1 sim rows made
    at or before it. Rows made later (including later re-runs) are dropped."""
    hours = market_day_hours(delivery)
    target = sim[(sim.t >= hours[0]) & (sim.t <= hours[-1])]
    if target.empty:
        raise ValueError(f"no lead-1 sim for {pd.Timestamp(delivery).date()}: use --mode pregate0630")
    issue = target.made.max()
    return sim[sim.made <= issue], issue


def sim_covariate(sim_rows, zones, grid, hours):
    """(Z, 1, T+H) known-future covariate on context grid + delivery hours; NaN where absent."""
    full = grid.append(hours)
    w = sim_rows.pivot_table(index="t", columns="zone", values="sim").reindex(index=full, columns=list(zones))
    return w.to_numpy().T[:, None, :].astype(np.float32)


# ----------------------------------------------------------------------------- probabilities
def p_le(q: np.ndarray, levels: np.ndarray, x: float = 0.0) -> np.ndarray:
    """P(Y <= x) from quantiles q[..., K] at `levels`; linear inside, tails at half the outer level."""
    flat = np.maximum.accumulate(q.reshape(-1, q.shape[-1]), axis=1)
    out = np.array([levels[0] / 2 if x < r[0] else (1 - (1 - levels[-1]) / 2 if x >= r[-1]
                    else np.interp(x, r, levels)) for r in flat])
    return out.reshape(q.shape[:-1])


def blend(a, b):
    """Unfitted equal-weight average; falls back to `a` where `b` is missing."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    return np.where(np.isnan(b), a, 0.5 * (a + b))


# ----------------------------------------------------------------------------- model
class TSFM:
    def __init__(self, name: str, threads: int = 16):
        import torch
        torch.set_num_threads(threads)
        self.name, repo = name, MODELS[name]
        if name.startswith("timestral"):
            from timestral import TimestralForecaster
            self.m = TimestralForecaster.from_pretrained(repo)
        else:
            from chronos import BaseChronosPipeline
            self.m = BaseChronosPipeline.from_pretrained(repo, device_map="cpu")

    def forecast(self, ctx, H, known=None):
        """ctx (Z, T); known (Z, C, T+H) or None -> quantiles (Z, H, K), levels (K,)."""
        if self.name.startswith("timestral"):
            f = self.m.forecast(ctx[:, None, :], prediction_length=H,
                                **({"known_covariates": known} if known is not None else {}))
            return np.asarray(f.quantiles)[:, 0], np.asarray(f.quantile_levels)
        T, items = ctx.shape[1], []
        for z in range(ctx.shape[0]):
            it = {"target": ctx[z]}
            if known is not None:
                it["past_covariates"] = {f"c{j}": known[z, j, :T] for j in range(known.shape[1])}
                it["future_covariates"] = {f"c{j}": known[z, j, T:] for j in range(known.shape[1])}
            items.append(it)
        preds = self.m.predict(items, prediction_length=H)
        return np.stack([p[0].numpy().T for p in preds]), np.asarray(self.m.quantiles)


# ----------------------------------------------------------------------------- core
def overlay(model, prices, zones, delivery, mode, sim=None, ctx_hours=CTX_HOURS):
    """Hourly + day-level TSFM overlay for Athens day `delivery` (logistic columns added later)."""
    d = pd.Timestamp(delivery).normalize()
    ctx, cutoff, grid = build_context(prices, zones, d, ctx_hours)
    hours = market_day_hours(d)
    known, sim_made, issue = None, pd.NaT, d - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)
    if mode == "postsim":
        rows, issue = sim_known(sim, d)
        known, sim_made = sim_covariate(rows, zones, grid, hours), issue
    elif mode != "pregate0630":
        raise ValueError(mode)
    q, lv = model.forecast(ctx, len(hours), known)
    k = lambda x: int(np.argmin(np.abs(lv - x)))
    p0 = p_le(q, lv, 0.0)
    out = []
    for zi, z in enumerate(zones):
        out.append(pd.DataFrame({
            "zone": z, "market_date": d.date().isoformat(), "t_utc": hours, "issue_utc": issue,
            "input_mode": mode, "model": model.name, "context_end_utc": cutoff, "sim_made_utc": sim_made,
            "after_gate": bool(issue > d - pd.Timedelta(days=1) + pd.Timedelta(hours=GATE_UTC_HOUR)),
            "tsfm_median": q[zi, :, k(0.5)], "tsfm_q10": q[zi, :, k(0.1)], "tsfm_q90": q[zi, :, k(0.9)],
            "p_le0_tsfm": p0[zi]}))
    hourly = pd.concat(out, ignore_index=True)
    day = (hourly.groupby(["zone", "market_date", "issue_utc", "input_mode", "model"], as_index=False)
           .p_le0_tsfm.max().rename(columns={"p_le0_tsfm": "p_any_le0_tsfm"}))
    return hourly, day


def add_logistic(hourly, day, logit_hourly=None, logit_day=None):
    """Attach collapse's D-1 logistic and the 50/50 blends (TSFM-only where it is absent)."""
    if logit_hourly is not None:
        lh = logit_hourly.rename(columns={"t": "t_utc", "collapse_probability": "p_le0_logit"})
        lh["t_utc"] = pd.to_datetime(lh.t_utc)
        hourly = hourly.merge(lh[["zone", "t_utc", "p_le0_logit"]], on=["zone", "t_utc"], how="left")
    else:
        hourly["p_le0_logit"] = np.nan
    hourly["p_le0"] = blend(hourly.p_le0_tsfm, hourly.p_le0_logit)
    if logit_day is not None:
        ld = logit_day.rename(columns={"any_hour_collapse_probability": "p_any_le0_logit"})
        ld["market_date"] = pd.to_datetime(ld.market_date).dt.date.astype(str)
        day = day.merge(ld[["zone", "market_date", "p_any_le0_logit"]], on=["zone", "market_date"], how="left")
    else:
        day["p_any_le0_logit"] = np.nan
    day["p_any_le0"] = blend(day.p_any_le0_tsfm, day.p_any_le0_logit)
    return hourly, day


# ----------------------------------------------------------------------------- I/O
def prices_duckdb(con, delivery, ctx_hours=CTX_HOURS):
    cutoff = day_start_utc(delivery)
    return con.execute(PRICE_SQL, [cutoff - pd.Timedelta(hours=ctx_hours + 24), cutoff]).df()


def sim_from_live_json(live_dir, zones):
    """Offline sim source: em-team/live/<ZONE>.json (lead-1 weather rows with prediction_made_utc)."""
    rows = []
    for z in zones:
        p = Path(live_dir) / f"{z}.json"
        if not p.exists():
            continue
        for day in json.load(open(p))["days"]:
            if day["lead_days"] == 1 and day["input_mode"].startswith("weather"):
                made = pd.Timestamp(day["prediction_made_utc"]).tz_localize(None)
                rows += [(z, pd.Timestamp(h).tz_localize(None), s, made) for h, s in zip(day["hours"], day["sim"])]
    return pd.DataFrame(rows, columns=["zone", "t", "sim", "made"])


def write_db(hourly, day):  # pragma: no cover - needs Postgres; untested in this draft
    import psycopg2
    cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"]); cur = cx.cursor()
    lines = []
    for col, suf in (("tsfm_median", ""), ("tsfm_q10", "_q10"), ("tsfm_q90", "_q90")):
        lines += [(r.zone, r.t_utc.isoformat() + "+00", f"tsfm_{r.input_mode}{suf}", float(getattr(r, col)), LINES_VERSION)
                  for r in hourly.itertuples()]
    cur.executemany("""INSERT INTO simulations.model_lines (bidding_zone, date_time_utc, model, price_eur_mwh, code_version)
        VALUES (%s, %s, %s, %s, %s) ON CONFLICT (bidding_zone, date_time_utc, model, code_version)
        DO UPDATE SET price_eur_mwh = EXCLUDED.price_eur_mwh, generated_at = now()""", lines)
    probs = []
    for r in hourly.itertuples():
        for qn in ("p_le0", "p_le0_tsfm", "p_le0_logit"):
            v = getattr(r, qn)
            probs.append((r.zone, r.market_date, r.t_utc.isoformat() + "+00", qn, None if pd.isna(v) else float(v),
                          r.input_mode, r.issue_utc.isoformat() + "+00", r.model))
    for r in day.itertuples():
        for qn in ("p_any_le0", "p_any_le0_tsfm", "p_any_le0_logit"):
            v = getattr(r, qn)
            probs.append((r.zone, r.market_date, None, qn, None if pd.isna(v) else float(v),
                          r.input_mode, r.issue_utc.isoformat() + "+00", r.model))
    cur.executemany("""INSERT INTO simulations.overlay_probabilities
        (bidding_zone, market_date, date_time_utc, quantity, value, input_mode, issue_utc, model_version)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (bidding_zone, market_date, date_time_utc, quantity, input_mode, model_version)
        DO UPDATE SET value = EXCLUDED.value, issue_utc = EXCLUDED.issue_utc, generated_at = now()""", probs)
    cx.commit()
    print(f"wrote {len(lines)} model_lines rows, {len(probs)} overlay_probabilities rows")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--delivery", required=True, help="Athens market day D (lead 1)")
    ap.add_argument("--mode", choices=["pregate0630", "postsim"], default="pregate0630")
    ap.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH"))
    ap.add_argument("--live-json", default="/home/pgeorgakopoulos/armada/em-team/live",
                    help="dry-run sim source (postsim mode)")
    ap.add_argument("--output", default="data/tsfm_overlay")
    ap.add_argument("--no-logistic", action="store_true", help="skip collapse's logistic (TSFM-only p_le0)")
    ap.add_argument("--write", action="store_true", help="write to Postgres instead of CSV (not a dry run)")
    ap.add_argument("--threads", type=int, default=int(os.environ.get("TSFM_THREADS", "16")))
    a = ap.parse_args()
    if a.write:
        raise SystemExit("--write: Postgres readers are not wired in this draft (owner decision pending); "
                         "use the dry run. write_db() shows the intended upsert.")
    import duckdb
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from collapse_probability import ZONES
    con = duckdb.connect(a.extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    t0 = time.time()
    prices = prices_duckdb(con, a.delivery)
    sim = sim_from_live_json(a.live_json, ZONES) if a.mode == "postsim" else None
    model = TSFM(os.environ.get("TSFM_MODEL", "chronos2"), a.threads)
    hourly, day = overlay(model, prices, ZONES, a.delivery, a.mode, sim)
    t_tsfm = time.time() - t0
    lh = ld = None
    if not a.no_logistic:
        from predict_collapse import forecast_date
        lh, ld, _ = forecast_date(con, a.delivery, settled_lag=1)
    hourly, day = add_logistic(hourly, day, lh, ld)
    out = Path(a.output); out.mkdir(parents=True, exist_ok=True)
    stem = f"{a.delivery}-{a.mode}-{model.name}"
    hourly.to_csv(out / f"{stem}-hourly.csv", index=False)
    day.to_csv(out / f"{stem}-day.csv", index=False)
    print(f"DRY RUN (no DB): wrote {out}/{stem}-hourly.csv ({len(hourly)} rows) and -day.csv ({len(day)} rows); "
          f"tsfm {t_tsfm:.1f}s total {time.time() - t0:.1f}s; issue_utc {hourly.issue_utc.iloc[0]} "
          f"after_gate={bool(hourly.after_gate.iloc[0])}")
    print(day.sort_values("p_any_le0", ascending=False).head(10).to_string(index=False))


if __name__ == "__main__":
    main()
