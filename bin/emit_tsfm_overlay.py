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
    lead-1 sim AT OR BEFORE the D-1 gate (10:00 UTC). D's lead-1 sim was made 08:16-10:06 UTC D-1
    in Sep-Nov 2026; a vintage made after the gate is never used (an earlier one is, if it exists),
    and the run refuses (ValueError) only when no vintage of D's lead-1 sim was made by the gate.
    `after_gate` (issue_utc > D-1 10:00 UTC) therefore stays False in postsim.
  * input_mode in the output says which of the two a row is.
  * TSFM_ARM=timestral-209m-phys (opt-in, postsim only): the phase-2 physics arm C — known-future
    covariates [sim, residual load = ENTSO-E D-1 load - wind - solar forecasts, gas-CCGT SRMC =
    TTF/0.5 + 0.404*EUA + 2 from closes dated before D-1], 2048-h context. Backtest 2026-09-14..11-13
    (39 zones, 54,231 cells): MAE 22.8 vs 25.1 (sim only) / 28.0 (prices only), AUC<=0 0.972; see
    docs/experiments/tsfm-2026-11/physics.md.
    Publication control (`physics_covariates`): raw load/RES rows enter only if their publication
    stamp (update_time_utc) is set and <= the D-1 gate (10:00 UTC), filtered BEFORE hourly
    aggregation; a delivery-day hour left without a verified value falls back to the residual load
    of t-168 h (as arm C-pre), a context hour stays missing; a RES type that exists for the zone
    but is missing after the filter makes the hour missing (never "0 MW"). issue_utc = max(sim issue,
    latest publication stamp among the load/RES rows actually used), and `after_gate` / the write
    refusal are evaluated on that stamp. (The extract backtest used latest revisions: a gate-time
    proxy, see physics.md.)

Modes of operation
  default (dry run): read the offline DuckDB extract (read-only) + live JSON for sim, write CSVs
                     to --output. No database access at all.
  --write          : production — pregate0630 from .github/workflows/daily-forecast.yml (06:30 UTC),
                     postsim from bin/emit_tsfm_refresh.sh (owner's server, cron 10:40 UTC). Reads Postgres
                     (ENERGY_CONN_STR) through DuckDB's postgres scanner (`USE pg`, so the SQL is the
                     same as on the extract), creates the overlay table if absent (idempotent DDL)
                     and upserts ONE vintage — lines (tsfm_median/q10/q90) and probabilities —
                     into simulations.tsfm_overlay, keyed by (input_mode, arm) and stamped with
                     issue_utc; an older issue never overwrites a newer one. Refuses an
                     after-gate issue.
Backfill mode (#431 R2, offline reconstruction; never shown as live)
  --backfill-tag TAG --start D0 --end D1 [--write]: postsim arm over the retro physics rows of ONE
                     reset_tag (simulations.forecast_prices is_retro AND reset_tag = TAG, written by
                     daily_forecast.jl retro mode; #431 R1), day by day:
    * the sim covariate (history AND D) comes from that tag's retro rows only, never live rows;
      live mode, conversely, never reads retro rows (SIM_SQL filters is_retro = false);
    * issue_utc = the retro rows' `retro_of_utc` (the natural D-1 instant they stand in for), not
      their `prediction_made_utc` (the actual, later compute time);
    * the price context ends before D exactly as live, but it reads TODAY's store, not the archive
      as of D-1 (late price revisions, if any, are visible);
    * rows are written with input_mode = 'postsim_backfill' and model_version = '<arm>@<TAG>'; the
      exporters' live vintage selection drops that mode (forecast_common.jl tsfm_overlay_maps);
    * resumable: a day already written for the tag is skipped, a day whose retro physics is not
      complete for every zone is skipped (re-run later); per-day failures and timeouts are
      non-fatal; the loop stops cleanly inside the protected UTC windows or while daily-forecast /
      publish-web-data runs (`backfill_guard`). Rollback: DELETE ... WHERE input_mode =
      'postsim_backfill' AND model_version LIKE '%@TAG'.
Env: TSFM_ARM = timestral-209m (published default, owner decision 2026-11-15) | timestral-28m |
     chronos2 | any arm added to ARMS (e.g. a physics-anchored residual arm). TSFM_MODEL is the
     legacy name of the same switch. Timestral weights: Modified-MIT with a revenue cap — licence
     acknowledged by the owner for this deployment, see docs/experiments/tsfm-2026-11/overlay.md.
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
# Hourly quantities of one vintage: the TSFM lines and the probabilities live in the SAME table
# with the same vintage key, so a reader can never pair a line of one issue with risk of another.
HOUR_QUANTITIES = ("tsfm_median", "tsfm_q10", "tsfm_q90", "p_le0", "p_le0_tsfm", "p_le0_logit")
DAY_QUANTITIES = ("p_any_le0", "p_any_le0_tsfm", "p_any_le0_logit")
MODELS = {"chronos2": "amazon/chronos-2",
          "timestral-209m": "mistralai/Timestral-209M",
          "timestral-28m": "mistralai/Timestral-28M"}
# Pinned Hub revisions (the weights the 2026-11 backtest ran; a Hub update never changes the product).
MODEL_REVISIONS = {"timestral-209m": "9874d252ab0aae16f7f7c999f98f98d6ad7d8365",
                   "timestral-28m": "49b26409ac87b5935539a5d8ffe7f397b720db47"}
DEFAULT_ARM = "timestral-209m"
PHYS_CTX_HOURS = 2048       # covariate cost grows ~quadratically with context; the arm-C backtest ran 2048
# One row per (zone, market day, hour | day, quantity, vintage). A vintage = (input_mode, arm)
# with its issue_utc. Day-level quantities sit at date_time_utc = start of the Athens market day
# (NOT NULL: a NULL inside a Postgres UNIQUE key never conflicts, so a nullable key would
# duplicate the day rows on every re-run instead of upserting them).
OVERLAY_DDL = """
CREATE TABLE IF NOT EXISTS simulations.tsfm_overlay (
    bidding_zone   text        NOT NULL,
    market_date    date        NOT NULL,
    date_time_utc  timestamptz NOT NULL,   -- the hour; day-level rows: start of the market day
    level          text        NOT NULL,   -- 'hour' | 'day'
    quantity       text        NOT NULL,   -- tsfm_median/q10/q90 (EUR/MWh), p_le0*, p_any_le0*
    value          double precision,
    input_mode     text        NOT NULL,   -- pregate0630 | postsim
    issue_utc      timestamptz NOT NULL,   -- vintage issuance (information cutoff)
    model_version  text        NOT NULL,   -- the TSFM arm
    generated_at   timestamptz DEFAULT now(),
    UNIQUE (bidding_zone, market_date, date_time_utc, quantity, input_mode, model_version));
CREATE INDEX IF NOT EXISTS tsfm_overlay_date_idx ON simulations.tsfm_overlay (market_date);
"""
# LIVE covariate: genuine live rows only. Retro rows (is_retro, e.g. the cv44 backfill) are written
# later than the live issue of subsequent days, so without this filter they would enter later live
# runs' sim history and win the latest-made dedupe.
SIM_SQL = """
SELECT bidding_zone zone, date_time_utc t, price_eur_mwh sim, prediction_made_utc made
FROM simulations.forecast_prices
WHERE lead_days = 1 AND input_mode LIKE 'weather%' AND NOT coalesce(is_retro, false)
  AND date_time_utc >= ? AND date_time_utc < ?"""

# BACKFILL covariate: the retro rows of ONE reset_tag; `made` = retro_of_utc (the natural instant the
# row stands in for), `computed` = prediction_made_utc (when it was actually computed).
RETRO_SIM_SQL = """
SELECT bidding_zone zone, date_time_utc t, price_eur_mwh sim, retro_of_utc made,
       prediction_made_utc computed
FROM simulations.forecast_prices
WHERE lead_days = 1 AND input_mode LIKE 'weather%' AND coalesce(is_retro, false) AND reset_tag = ?
  AND date_time_utc >= ? AND date_time_utc < ?"""

BACKFILL_MODE = "postsim_backfill"

# Raw (sub-hourly) rows with their publication stamp: the publication filter must act before
# hourly aggregation, so these are aggregated in Python (`physics_covariates`).
LOAD_SQL = """
SELECT area_map_code zone, date_time_utc t, total_load_mw load_fc, update_time_utc upd
FROM entsoe.day_ahead_total_load_forecast
WHERE total_load_mw IS NOT NULL AND date_time_utc >= ? AND date_time_utc < ?"""

RES_SQL = """
SELECT area_map_code zone, date_time_utc t, production_type pt, day_ahead_generation_forecast_mw mw,
       update_time_utc upd
FROM entsoe.generation_forecasts_for_wind_and_solar
WHERE day_ahead_generation_forecast_mw IS NOT NULL AND date_time_utc >= ? AND date_time_utc < ?
  AND (production_type LIKE 'Wind%' OR production_type = 'Solar')"""

FUEL_SQL = """
SELECT 'ttf' fuel, date, close FROM yfinance.ttf_f WHERE close IS NOT NULL
UNION ALL SELECT 'eua' fuel, date, close FROM yfinance.eua_co2 WHERE close IS NOT NULL"""

# Model INPUT context: highest-sequence settled prices (EXAA in AT/DE_LU). Deliberately NOT
# routed through EUPHEMIA_DA_TARGET (#431 PR C): changing Timestral's context is a model-input
# change, evaluated and versioned separately.
# TODO(#431): decide whether the AT/DE_LU context should become SDAC (bin/da_target.py) once
# the owner flips the evaluation target; evaluate it as its own arm before switching.
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


def gate_utc(delivery) -> pd.Timestamp:
    """The (conservative) D-1 auction gate of Athens market day D, naive UTC: D-1 10:00 UTC."""
    return pd.Timestamp(delivery).normalize() - pd.Timedelta(days=1) + pd.Timedelta(hours=GATE_UTC_HOUR)


def sim_known(sim: pd.DataFrame, delivery):
    """Lead-1 sim rows knowable at the post-sim issue time of D. Returns (rows, issue_utc).

    issue_utc = the latest prediction_made_utc of D's lead-1 sim made at or before the D-1 gate
    (`gate_utc`); history = all lead-1 sim rows made at or before it. Rows made later (including
    later re-runs and a post-gate vintage of D itself) are dropped. Raises ValueError when D has
    no lead-1 sim at all, or none made by the gate."""
    hours = market_day_hours(delivery)
    target = sim[(sim.t >= hours[0]) & (sim.t <= hours[-1])]
    day = pd.Timestamp(delivery).date()
    if target.empty:
        raise ValueError(f"no lead-1 sim for {day}: use --mode pregate0630")
    gate = gate_utc(delivery)
    in_time = target[target.made <= gate]
    if in_time.empty:
        raise ValueError(f"no lead-1 sim vintage for {day} made by the gate {gate} UTC "
                         f"(earliest {target.made.min()}): refusing the post-sim overlay")
    issue = in_time.made.max()
    known = sim[sim.made <= issue].sort_values("made").drop_duplicates(["zone", "t"], keep="last")
    covered = known[(known.t >= hours[0]) & (known.t <= hours[-1])].zone.nunique()
    if covered < target.zone.nunique():
        print(f"WARNING: post-sim vintage {issue} covers {covered}/{target.zone.nunique()} zones of {day}; "
              f"the rest have no delivery-day sim covariate")
    return known, issue


def sim_covariate(sim_rows, zones, grid, hours):
    """(Z, 1, T+H) known-future covariate on context grid + delivery hours; NaN where absent."""
    full = grid.append(hours)
    w = sim_rows.pivot_table(index="t", columns="zone", values="sim").reindex(index=full, columns=list(zones))
    return w.to_numpy().T[:, None, :].astype(np.float32)


def srmc_hourly(fuel: pd.DataFrame, hours: pd.DatetimeIndex) -> np.ndarray:
    """Gas-CCGT SRMC (EUR/MWh) per UTC hour = TTF/0.5 + 0.202/0.5*EUA + 2, from the last closes dated
    strictly before D-1 of the hour's Athens market day (the close of D-1 itself is not yet known
    at a D-1 morning issue)."""
    known_by = (hours.tz_localize("UTC").tz_convert(ATH).tz_localize(None).normalize()
                - pd.Timedelta(days=1)).values
    out = {}
    for f in ("ttf", "eua"):
        s = fuel[fuel.fuel == f].sort_values("date")
        dates = pd.to_datetime(s.date).values
        idx = np.searchsorted(dates, known_by, side="left") - 1
        out[f] = np.where(idx >= 0, s.close.to_numpy(float)[np.clip(idx, 0, None)], np.nan)
    return out["ttf"] / 0.5 + 0.202 / 0.5 * out["eua"] + 2.0


def physics_covariates(load, res, fuel, zones, grid, hours, cutoff):
    """Known-future [residual load, SRMC] on context grid + delivery hours, publication-filtered.

    load: raw rows (zone, t, load_fc, upd); res: raw rows (zone, t, pt, mw, upd), pt = 'Wind ...' or
    'Solar'. Only rows with upd set and <= `cutoff` are used, before hourly aggregation. residual
    load = load - wind - solar; a RES type the zone never reports (in the window, before filtering)
    counts as 0, one it reports but whose hour did not survive the filter makes the hour NaN.
    Delivery hours still NaN take the residual load of t-168 h. Returns ((Z, 2, T+H) array,
    latest publication stamp among the rows used, NaT if none)."""
    full, zones = grid.append(hours), list(zones)
    ok = lambda df: df[df.upd.notna() & (df.upd <= cutoff) & (df.t >= full[0])
                       & (df.t < full[-1] + pd.Timedelta(hours=1))]
    hourly = lambda df, val, keys: (df.assign(t=df.t.dt.floor("h")).groupby(keys + ["t"])[val].mean())
    L, R = ok(load), ok(res)
    load_w = hourly(L, "load_fc", ["zone"]).unstack("zone").reindex(index=full, columns=zones)
    resload = load_w.copy()
    window = res[(res.t >= full[0]) & (res.t < full[-1] + pd.Timedelta(hours=1))]
    if len(window):
        rh = hourly(R, "mw", ["zone", "pt"]).unstack(["zone", "pt"]) if len(R) else pd.DataFrame(index=full)
        for (z, pt) in window[["zone", "pt"]].drop_duplicates().itertuples(index=False):
            if z in zones:   # reported type: subtract it, NaN where its hour was not verified
                col = rh[(z, pt)] if (z, pt) in rh.columns else pd.Series(np.nan, index=full)
                resload[z] = resload[z] - col.reindex(full)
    H = len(hours)
    rl = resload.to_numpy(copy=True).T                          # (Z, T+H); writable (a CoW view is read-only)
    persist = resload.shift(168).to_numpy().T
    rl[:, -H:] = np.where(np.isnan(rl[:, -H:]), persist[:, -H:], rl[:, -H:])
    srmc = np.repeat(srmc_hourly(fuel, full)[None, :], len(zones), axis=0)
    used = pd.concat([L.upd, R.upd]) if len(L) or len(R) else pd.Series([], dtype="datetime64[ns]")
    return np.stack([rl, srmc], axis=1).astype(np.float32), (used.max() if len(used) else pd.NaT)


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
def resolve_arm(env=os.environ) -> str:
    """TSFM_ARM (new) > TSFM_MODEL (legacy) > the published default."""
    arm = env.get("TSFM_ARM") or env.get("TSFM_MODEL") or DEFAULT_ARM
    if arm not in ARMS:
        raise SystemExit(f"unknown TSFM_ARM={arm!r}; known: {sorted(ARMS)}")
    return arm


class TSFM:
    def __init__(self, name: str, threads: int = 16):
        import torch
        torch.set_num_threads(threads)
        self.name, repo = name, MODELS[name]
        if name.startswith("timestral"):
            from timestral import TimestralForecaster
            self.m = TimestralForecaster.from_pretrained(repo, revision=MODEL_REVISIONS.get(name))
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


# Arm registry: name -> factory(threads) returning an object with .name and
# .forecast(ctx (Z,T), H, known (Z,C,T+H)|None) -> (quantiles (Z,H,K), levels (K,)).
# A new arm (e.g. the tsfm agent's physics-anchored residual) is one entry here.
ARMS = {name: (lambda threads, _n=name: TSFM(_n, threads)) for name in MODELS}


def _physics_arm(threads):
    m = TSFM("timestral-209m", threads)
    m.name, m.physics = "timestral-209m-phys", True
    return m


# Phase-2 arm C (opt-in): Timestral-209M + [sim, residual load, SRMC]; needs --mode postsim.
ARMS["timestral-209m-phys"] = _physics_arm


# ----------------------------------------------------------------------------- core
def overlay(model, prices, zones, delivery, mode, sim=None, ctx_hours=CTX_HOURS, phys=None):
    """Hourly + day-level TSFM overlay for Athens day `delivery` (logistic columns added later).

    A physics arm (model.physics) needs mode postsim and `phys` = (load, res, fuel) frames."""
    d = pd.Timestamp(delivery).normalize()
    physics = getattr(model, "physics", False)
    if physics:
        if mode != "postsim":
            raise ValueError(f"arm {model.name} needs the lead-1 sim: use --mode postsim")
        ctx_hours = min(ctx_hours, PHYS_CTX_HOURS)
    ctx, cutoff, grid = build_context(prices, zones, d, ctx_hours)
    hours = market_day_hours(d)
    known, sim_made, issue = None, pd.NaT, d - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)
    if mode == "postsim":
        rows, issue = sim_known(sim, d)
        known, sim_made = sim_covariate(rows, zones, grid, hours), issue
        if physics:
            gate = gate_utc(d)
            pk, pub = physics_covariates(*phys, zones, grid, hours, cutoff=gate)
            known = np.concatenate([known, pk], axis=1)
            if pd.notna(pub):
                issue = max(issue, pub)                         # information set = all inputs used
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
            "after_gate": bool(issue > gate_utc(d)),
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
def naive_utc(df: pd.DataFrame) -> pd.DataFrame:
    """Every tz-aware datetime column as naive UTC, the extract's convention.

    The extract stores each Postgres `timestamptz` column as naive UTC (bin/extract_common.jl);
    through the postgres scanner (`--backend postgres`) the same columns arrive tz-aware, and
    comparing them with this module's naive UTC grid raises. Naive columns are left alone."""
    for c in df.columns:
        if isinstance(df[c].dtype, pd.DatetimeTZDtype):
            df[c] = df[c].dt.tz_convert("UTC").dt.tz_localize(None)
    return df


def prices_duckdb(con, delivery, ctx_hours=CTX_HOURS):
    cutoff = day_start_utc(delivery)
    return naive_utc(con.execute(PRICE_SQL, [cutoff - pd.Timedelta(hours=ctx_hours + 24), cutoff]).df())


def eval_actuals_duckdb(con, start, end):
    """Hourly EVALUATION actuals (zone, t, price) over UTC [start, end), under EUPHEMIA_DA_TARGET.

    Unset/highest_seq: exactly PRICE_SQL's frame. sdac: the SDAC auction only (bin/da_target.py).
    Never feed this to the model context; that is `prices_duckdb`."""
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    import da_target
    if da_target.policy() != "sdac":
        return naive_utc(con.execute(PRICE_SQL, [start, end]).df())
    a = da_target.hourly_actuals(con, start, end, target="sdac")
    return a.rename(columns={"z": "zone", "act": "price"}).assign(price=lambda x: x.price.round(8))


def open_store(backend, extract=None):
    """DuckDB connection whose default catalog holds the entsoe.* / simulations.* tables.

    duckdb: the offline extract, read-only. postgres: an in-memory DuckDB with the live database
    ATTACHed read-only through the postgres scanner and made the default catalog (`USE pg`), so
    every reader here and in predict_collapse runs unchanged SQL. Writes go through psycopg2."""
    import duckdb
    if backend == "duckdb":
        if not extract:
            raise SystemExit("--backend duckdb needs --extract or EUPHEMIA_DUCKDB_PATH")
        return duckdb.connect(extract, read_only=True, config={"threads": 4, "memory_limit": "8GB"})
    if backend != "postgres":
        raise ValueError(backend)
    con = duckdb.connect(config={"threads": 4, "memory_limit": "8GB"})
    # UTC session: naive query parameters, date_trunc and timestamptz->timestamp casts then mean
    # UTC, as in the extract, whatever the host's local time zone is.
    con.execute("SET TimeZone = 'UTC'")
    con.execute("INSTALL postgres; LOAD postgres;")
    con.execute("ATTACH ? AS pg (TYPE postgres, READ_ONLY)", [os.environ["ENERGY_CONN_STR"]])
    con.execute("USE pg")
    return con


def physics_from_store(con, delivery, ctx_hours=PHYS_CTX_HOURS):
    """(load, res, fuel) frames for the physics arm: context window + delivery day."""
    start = day_start_utc(delivery) - pd.Timedelta(hours=ctx_hours + 24)
    end = day_start_utc(pd.Timestamp(delivery) + pd.Timedelta(days=1))
    load, res = (con.execute(q, [start, end]).df() for q in (LOAD_SQL, RES_SQL))
    for df in (load, res):
        for c in ("t", "upd"):
            df[c] = pd.to_datetime(df[c], utc=True).dt.tz_localize(None)
    return load, res, con.execute(FUEL_SQL).df()


def sim_from_db(con, delivery, days=60):
    """Lead-1 weather-track sim rows (all vintages) for the post-sim covariate, from the store."""
    end = day_start_utc(pd.Timestamp(delivery) + pd.Timedelta(days=1))
    df = con.execute(SIM_SQL, [end - pd.Timedelta(days=days + 1), end]).df()
    for c in ("t", "made"):
        df[c] = pd.to_datetime(df[c], utc=True).dt.tz_localize(None)
    return df


def sim_from_retro(con, tag, delivery, days=60):
    """Lead-1 retro sim rows of reset_tag `tag` (backfill covariate); `made` = retro_of_utc."""
    if not tag:
        raise ValueError("a backfill needs a reset_tag")
    end = day_start_utc(pd.Timestamp(delivery) + pd.Timedelta(days=1))
    df = con.execute(RETRO_SIM_SQL, [tag, end - pd.Timedelta(days=days + 1), end]).df()
    for c in ("t", "made", "computed"):
        df[c] = pd.to_datetime(df[c], utc=True).dt.tz_localize(None)
    if df.made.isna().any():
        raise ValueError(f"{int(df.made.isna().sum())} retro rows of {tag} lack retro_of_utc: refusing")
    return df


def backfill_label(arm, tag):
    """model_version of a backfill vintage: the arm plus the reset_tag it was built from."""
    return f"{arm}@{tag}"


def as_backfill(hourly, day, tag):
    """Relabel a postsim vintage built from retro rows as a backfill vintage (never live)."""
    if not (hourly.input_mode == "postsim").all():
        raise ValueError("a backfill vintage is a postsim vintage")
    hourly = hourly.assign(input_mode=BACKFILL_MODE, reset_tag=tag)
    day = day.assign(input_mode=BACKFILL_MODE, reset_tag=tag)
    return hourly, day


def sim_from_live_json(live_dir, zones):
    """Offline LIVE sim source: zone JSONs (lead-1 weather rows with prediction_made_utc). Days the export
    stamps is_retro (reconstructions) are skipped, as SIM_SQL skips retro rows."""
    rows = []
    for z in zones:
        p = Path(live_dir) / f"{z}.json"
        if not p.exists():
            continue
        for day in json.load(open(p))["days"]:
            if day.get("is_retro"):      # reconstructed day (#431 R1): never a live covariate
                continue
            if day["lead_days"] == 1 and day["input_mode"].startswith("weather"):
                made = pd.Timestamp(day["prediction_made_utc"]).tz_localize(None)
                rows += [(z, pd.Timestamp(h).tz_localize(None), s, made) for h, s in zip(day["hours"], day["sim"])]
    return pd.DataFrame(rows, columns=["zone", "t", "sim", "made"])


def db_rows(hourly, day, arm):
    """simulations.tsfm_overlay rows of one vintage (lines + probabilities) — pure, unit-tested."""
    ts = lambda x: pd.Timestamp(x).isoformat() + "+00"
    nn = lambda v: None if pd.isna(v) else float(v)
    rows = [(r.zone, r.market_date, ts(r.t_utc), "hour", qn, nn(getattr(r, qn)), r.input_mode,
             ts(r.issue_utc), arm)
            for r in hourly.itertuples() for qn in HOUR_QUANTITIES]
    rows += [(r.zone, r.market_date, ts(day_start_utc(r.market_date)), "day", qn, nn(getattr(r, qn)),
              r.input_mode, ts(r.issue_utc), arm)
             for r in day.itertuples() for qn in DAY_QUANTITIES]
    return rows


# The WHERE on DO UPDATE rejects an older issue overwriting a newer one of the same vintage key
# (e.g. a delayed retry of a run after a later re-issue); different modes/arms are different rows
# and the exporter picks the latest-issue vintage per zone-day.
OVERLAY_UPSERT = """INSERT INTO simulations.tsfm_overlay
    (bidding_zone, market_date, date_time_utc, level, quantity, value, input_mode, issue_utc, model_version)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON CONFLICT (bidding_zone, market_date, date_time_utc, quantity, input_mode, model_version)
    DO UPDATE SET value = EXCLUDED.value, issue_utc = EXCLUDED.issue_utc, level = EXCLUDED.level,
                  generated_at = now()
    WHERE simulations.tsfm_overlay.issue_utc <= EXCLUDED.issue_utc"""


def write_db(hourly, day, arm, cx=None, allow_after_gate=False):
    """Idempotent: CREATE ... IF NOT EXISTS, then upserts, one transaction."""
    if hourly.after_gate.any() and not allow_after_gate:
        raise SystemExit("refusing to publish an after-gate overlay (issue_utc > D-1 10:00 UTC); "
                         "use --mode pregate0630 or --allow-after-gate")
    rows = db_rows(hourly, day, arm)
    own = cx is None
    if own:  # pragma: no cover - needs Postgres
        import psycopg2
        cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
    try:
        cur = cx.cursor()
        cur.execute(OVERLAY_DDL)
        cur.executemany(OVERLAY_UPSERT, rows)
        cx.commit()
    finally:
        if own:
            cx.close()
    print(f"upserted {len(rows)} simulations.tsfm_overlay rows "
          f"(vintage {hourly.input_mode.iloc[0]}/{arm} issued {hourly.issue_utc.iloc[0]}; "
          f"rows of a newer issue are kept)")
    return len(rows)


# ----------------------------------------------------------------------------- backfill runner
# Protected UTC windows (#431 R1/R2): the 06:00-08:30 forecast/publish and 10:30-12:15 refresh/gate
# slots. A day is admitted only if its whole budget [now, now + reserve] (the per-day timeout, which
# bounds reads, inference and writes, plus GUARD_MARGIN_S) ends before the next window opens.
BACKFILL_BLOCKED_UTC = (((6, 0), (8, 30)), ((10, 30), (12, 15)))
GUARD_MARGIN_S = 60
BACKFILL_BLOCKING_WORKFLOWS = ("daily-forecast.yml", "publish-web-data.yml")


def in_blocked_window(now_utc, reserve_s: float = 0.0) -> bool:
    """Whether [now, now + reserve_s] overlaps a protected window (wrapping past midnight)."""
    t0 = now_utc.hour * 3600 + now_utc.minute * 60 + now_utc.second
    t1 = t0 + reserve_s
    for (a, b), (c, d) in BACKFILL_BLOCKED_UTC:
        ws, we = a * 3600 + b * 60, c * 3600 + d * 60
        for shift in (0, 86400):                       # tomorrow's occurrence, for late-evening starts
            ws_, we_ = ws + shift, we + shift
            if ws_ <= t0 < we_ or t0 < ws_ < t1:      # starts inside, or a window opens before it ends
                return True
    return False


def workflows_active(env=os.environ, workflows=BACKFILL_BLOCKING_WORKFLOWS):  # pragma: no cover - network
    """Names of blocking workflows with a queued/running run (GitHub API; needs GITHUB_TOKEN and
    GITHUB_REPOSITORY, i.e. inside Actions). Outside Actions the check is skipped (empty list);
    an API error counts as active (fail safe)."""
    tok, repo = env.get("GITHUB_TOKEN"), env.get("GITHUB_REPOSITORY")
    if not (tok and repo):
        return []
    import urllib.request
    active = []
    for wf in workflows:
        for st in ("queued", "in_progress", "waiting", "pending", "requested"):
            url = f"https://api.github.com/repos/{repo}/actions/workflows/{wf}/runs?status={st}&per_page=1"
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}",
                                                       "Accept": "application/vnd.github+json"})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    n = json.load(r)["total_count"]
            except Exception as e:
                print(f"WARNING: GitHub API check of {wf} failed ({e}); treating it as active")
                n = 1
            if n:
                active.append(wf)
                break
    return active


def backfill_guard(now_utc=None, active=workflows_active, reserve_s: float = 0.0,
                   clock=lambda: pd.Timestamp.utcnow().tz_localize(None)):
    """None when a backfill day may start, else the reason to stop (the loop stops cleanly).

    The day's full budget `reserve_s` must end before the next protected window; the clock is
    read again AFTER the (slow) GitHub API checks, so their latency cannot eat the reservation."""
    now_utc = now_utc or clock()
    if in_blocked_window(now_utc, reserve_s):
        return f"a {reserve_s:.0f} s day starting {now_utc:%H:%M:%S} would reach a protected UTC window"
    busy = active()
    if busy:
        return f"blocking workflow(s) active: {', '.join(busy)}"
    later = clock()
    if in_blocked_window(later, reserve_s):
        return f"after the workflow checks, a {reserve_s:.0f} s day starting {later:%H:%M:%S} would reach a protected UTC window"
    return None


def retro_ready(sim, delivery, zones):
    """Zones of `zones` WITHOUT a complete retro lead-1 day for D (empty = ready)."""
    hours = market_day_hours(delivery)
    d = sim[(sim.t >= hours[0]) & (sim.t <= hours[-1])]
    have = d.groupby("zone").t.nunique()
    return sorted(z for z in zones if have.get(z, 0) < len(hours))


def backfill_done(con, delivery, label):
    """Whether this backfill vintage (label) already has day rows for D (resume)."""
    try:
        n = con.execute("SELECT count(*) FROM simulations.tsfm_overlay WHERE market_date = ? "
                        "AND input_mode = ? AND model_version = ? AND level = 'day'",
                        [pd.Timestamp(delivery).date(), BACKFILL_MODE, label]).fetchone()[0]
    except Exception as e:  # table absent before the first write
        if "does not exist" in str(e) or "Catalog Error" in str(e):
            return False
        raise
    return n > 0


class DayTimeout(Exception):
    pass


def _run_with_timeout(fn, seconds):
    import signal

    def handler(*_):
        raise DayTimeout(f"day exceeded {seconds} s")
    old = signal.signal(signal.SIGALRM, handler)
    signal.alarm(int(seconds))
    try:
        return fn()
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


def run_backfill(days, tag, arm, zones, *, load_sim, load_prices, model, emit, done,
                 logistic=None, guard=None, timeout_s=900):
    """Backfill vintages for `days` (Athens market days) from reset_tag `tag`. Pure orchestration;
    the I/O is injected (load_sim(d), load_prices(d), done(d, label), emit(hourly, day, label)).
    Returns one status row per day: done | exists | no_physics | failed | stopped."""
    label, out = backfill_label(arm, tag), []
    if guard is None:   # reserve the whole day budget before every admission
        guard = lambda: backfill_guard(reserve_s=timeout_s + GUARD_MARGIN_S)
    for i, d in enumerate(days):
        d = pd.Timestamp(d).date().isoformat()
        why = guard()
        if why:
            out += [dict(day=x, status="stopped", detail=why)
                    for x in (pd.Timestamp(y).date().isoformat() for y in days[i:])]
            print(f"backfill stopped before {d}: {why} (resumable: re-dispatch later)")
            break
        t0 = time.time()
        try:
            def one():                       # everything of the day, reads included, under the alarm
                if done(d, label):
                    return dict(status="exists", detail=label)
                sim = load_sim(d)
                missing = retro_ready(sim, d, zones)
                if missing:
                    return dict(status="no_physics", detail=f"retro physics incomplete for {len(missing)} zone(s): "
                                                            f"{','.join(missing[:6])}")
                hourly, day = overlay(model, load_prices(d), zones, d, "postsim", sim)
                lh = ld = None
                if logistic is not None:
                    try:
                        lh, ld = logistic(d)
                    except DayTimeout:       # the day's bound, not a logistic failure
                        raise
                    except Exception as e:
                        print(f"WARNING {d}: collapse logistic failed ({type(e).__name__}: {e}); TSFM-only p_le0")
                hourly, day = as_backfill(*add_logistic(hourly, day, lh, ld), tag)
                emit(hourly, day, label)
                return dict(status="done", detail=f"issue_utc {hourly.issue_utc.iloc[0]}")
            r = _run_with_timeout(one, timeout_s)
        except Exception as e:   # non-fatal per day (incl. DayTimeout)
            r = dict(status="failed", detail=f"{type(e).__name__}: {e}")
        out.append(dict(day=d, secs=round(time.time() - t0, 1), **r))
        print(f"backfill {d}: {r['status']} ({out[-1]['secs']} s) {r['detail']}", flush=True)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--delivery", required=True, help="Athens market day D (lead 1); 'tomorrow' = UTC today + 1")
    ap.add_argument("--mode", choices=["pregate0630", "postsim"], default="pregate0630")
    ap.add_argument("--backend", choices=["duckdb", "postgres"], default=None,
                    help="data store (default: postgres with --write, else duckdb)")
    ap.add_argument("--extract", default=os.environ.get("EUPHEMIA_DUCKDB_PATH"))
    ap.add_argument("--live-json", "--sim-dir", dest="live_json", default=None,
                    help="dry-run sim source for postsim (dir of api zone JSONs, e.g. em-team/live; "
                         "only each day's final vintage); default: the store")
    ap.add_argument("--output", default="data/tsfm_overlay")
    ap.add_argument("--no-logistic", action="store_true", help="skip collapse's logistic (TSFM-only p_le0)")
    ap.add_argument("--write", action="store_true", help="upsert into Postgres (production)")
    ap.add_argument("--allow-after-gate", action="store_true")
    ap.add_argument("--threads", type=int, default=int(os.environ.get("TSFM_THREADS", "16")))
    ap.add_argument("--backfill-tag", default=None,
                    help="backfill mode: build postsim vintages from the retro rows of this reset_tag "
                         "(with --start/--end; --delivery is then ignored)")
    ap.add_argument("--start"); ap.add_argument("--end")
    ap.add_argument("--day-timeout", type=int, default=int(os.environ.get("TSFM_BACKFILL_DAY_TIMEOUT", "900")))
    ap.add_argument("--no-guard", action="store_true", help="backfill: skip the time-window/workflow guard")
    argv = sys.argv[1:]
    if "--backfill-tag" in argv and "--delivery" not in argv:
        argv = argv + ["--delivery", "backfill"]
    a = ap.parse_args(argv)
    if a.backfill_tag:
        return main_backfill(a)
    delivery = (pd.Timestamp.utcnow().tz_localize(None).normalize() + pd.Timedelta(days=1)).date().isoformat() \
        if a.delivery == "tomorrow" else a.delivery
    backend = a.backend or ("postgres" if a.write else "duckdb")
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from collapse_probability import ZONES
    arm = resolve_arm()
    con = open_store(backend, a.extract)
    t0 = time.time()
    prices = prices_duckdb(con, delivery)
    sim = None
    if a.mode == "postsim":
        sim = (sim_from_live_json(a.live_json, ZONES) if a.live_json
               else sim_from_db(con, delivery, days=PHYS_CTX_HOURS // 24 + 2 if arm.endswith("-phys") else 60))
        sim_known(sim, delivery)   # fail fast (no vintage by the gate) before loading the weights
    model = ARMS[arm](a.threads)
    phys = physics_from_store(con, delivery) if getattr(model, "physics", False) else None
    hourly, day = overlay(model, prices, ZONES, delivery, a.mode, sim, phys=phys)
    t_tsfm = time.time() - t0
    lh = ld = None
    if not a.no_logistic:
        try:
            from predict_collapse import forecast_date
            lh, ld, _ = forecast_date(con, delivery, settled_lag=1)
        except Exception as e:  # the TSFM half still publishes; p_le0 falls back to TSFM-only
            print(f"WARNING: collapse logistic failed ({type(e).__name__}: {e}); publishing TSFM-only p_le0")
    hourly, day = add_logistic(hourly, day, lh, ld)
    print(f"{arm} {a.mode} D={delivery}: {len(hourly)} hourly / {len(day)} day rows; tsfm {t_tsfm:.1f}s "
          f"total {time.time() - t0:.1f}s; issue_utc {hourly.issue_utc.iloc[0]} "
          f"after_gate={bool(hourly.after_gate.iloc[0])} logistic={'yes' if lh is not None else 'no'}")
    if a.write:
        write_db(hourly, day, arm, allow_after_gate=a.allow_after_gate)
    else:
        out = Path(a.output); out.mkdir(parents=True, exist_ok=True)
        stem = f"{delivery}-{a.mode}-{arm}"
        hourly.to_csv(out / f"{stem}-hourly.csv", index=False)
        day.to_csv(out / f"{stem}-day.csv", index=False)
        print(f"DRY RUN (no DB writes): {out}/{stem}-hourly.csv, -day.csv")
    print(day.sort_values("p_any_le0", ascending=False).head(10).to_string(index=False))


def main_backfill(a):
    """--backfill-tag: resumable day loop (see run_backfill); prints a JSON status summary."""
    if not (a.start and a.end):
        raise SystemExit("--backfill-tag needs --start and --end")
    arm = resolve_arm()
    if arm.endswith("-phys"):
        raise SystemExit("backfill supports the sim-covariate arms only (not the physics arm)")
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from collapse_probability import ZONES
    backend = a.backend or ("postgres" if a.write else "duckdb")
    con = open_store(backend, a.extract)
    days = pd.date_range(a.start, a.end, freq="D")
    model = ARMS[arm](a.threads)
    logistic = None
    if not a.no_logistic:
        from predict_collapse import forecast_date
        logistic = lambda d: forecast_date(con, d, settled_lag=1)[:2]
    out_dir = Path(a.output)

    def emit(hourly, day, label):
        if a.write:
            write_db(hourly, day, label)
        else:
            out_dir.mkdir(parents=True, exist_ok=True)
            stem = f"{hourly.market_date.iloc[0]}-{BACKFILL_MODE}-{label.replace('@', '_')}"
            hourly.to_csv(out_dir / f"{stem}-hourly.csv", index=False)
            day.to_csv(out_dir / f"{stem}-day.csv", index=False)

    done = (lambda d, label: backfill_done(con, d, label)) if a.write else \
        (lambda d, label: (out_dir / f"{d}-{BACKFILL_MODE}-{label.replace('@', '_')}-day.csv").exists())
    res = run_backfill(days, a.backfill_tag, arm, ZONES,
                       load_sim=lambda d: sim_from_retro(con, a.backfill_tag, d),
                       load_prices=lambda d: prices_duckdb(con, d), model=model, emit=emit, done=done,
                       logistic=logistic, guard=(lambda: None) if a.no_guard else None,
                       timeout_s=a.day_timeout)
    counts = pd.Series([r["status"] for r in res]).value_counts().to_dict()
    secs = [r["secs"] for r in res if r.get("status") == "done"]
    print("BACKFILL SUMMARY " + json.dumps({"tag": a.backfill_tag, "arm": arm, "write": a.write,
                                            "counts": counts, "median_secs_per_done_day":
                                            float(np.median(secs)) if secs else None}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
