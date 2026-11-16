"""Zero-shot / hybrid TSFM day-ahead price forecasts, lead-1, pre-gate information set.

Information-set rule (enforced in `build_inputs`): for delivery day D (Europe/Athens market day,
same hours as the live JSON), lead 1. `--settled-lag 1` (primary): the price context ends at
the start of Athens day D (D-1's prices were auctioned on D-2 and are public at a D-1 morning
issue); the model forecasts the 24 (23/25) hours of D. `--settled-lag 2` (conservative): the
context ends at the start of D-1; the model forecasts D-1 and D (48 h) and keeps D.

Variants
  uni    prices only                                                 -> label (a) 06:30
  cov    + ENTSO-E D-1 load / wind / solar forecasts as known-future  -> label (b) gate-time proxy
         covariates (latest revisions, no publication filter: availability by 10:00 not verified)
  sim    + the live lead-1 weather-track counterfactual `sim` as a     -> label (a') POST-SIM:
         known-future covariate (history + D-1 + D)                       sim is published 08:16-10:06
                                                                          UTC D-1, so ~10:15 UTC issue
  phys   + known-future [sim, residual load (ENTSO-E D-1 load-wind-solar), gas SRMC]
                                                                   -> label (b) gate-time proxy
                                                                      (ENTSO-E RES not provably pre-gate)
  physresid  target = settled - sim with the `phys` covariates; final = sim + forecast  -> (b)
  physfilt  = phys, but the residual-load row is publication-filtered exactly as the production
         emitter does (bin/emit_tsfm_overlay.py::physics_covariates, cutoff D-1 10:00 UTC; delivery
         hours without a verified value -> residual load at t-168 h)   -> label (b) honest gate time
  physpre  + known-future [lead-2 weather sim (latest issued before D-1 06:30 UTC), residual load
         persisted from t-168 h, gas SRMC]; same definitions in history and horizon -> label (a) 06:30
  resid  forecast the residual (settled - sim) through the context    -> label (a') post-sim
         end, add it to sim for D
`issued_utc` in the output is the nominal 06:30 stamp and is valid only for `uni`/`cov`;
for `sim`/`resid` the effective issue time is the live sim's `prediction_made_utc`.

Models: t209 / t28 = mistralai/Timestral-{209M,28M}; c2 = amazon/chronos-2.
Output: $TSFM_OUT/fc_<model>_<variant>.parquet, one row per (zone, hour of D).
"""
import sys
import argparse, os, time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import numpy as np, pandas as pd, torch

OUT = (os.environ.get('TSFM_OUT') or sys.exit("Set TSFM_OUT to the required local file or directory"))
ATH = ZoneInfo("Europe/Athens")
CTX = 8192  # hours of context (~341 days); Chronos-2 default context; Timestral max is 32768


def day_start_utc(d: date) -> pd.Timestamp:
    return pd.Timestamp(datetime(d.year, d.month, d.day, tzinfo=ATH).astimezone(timezone.utc)).tz_localize(None)


def p_le(q: np.ndarray, levels: np.ndarray, x: float = 0.0) -> np.ndarray:
    """P(Y <= x) from quantiles q[..., k] at `levels`, linear inside, tails clipped at half the
    outer level (0.005 / 0.995)."""
    out = np.empty(q.shape[:-1])
    flat_q = q.reshape(-1, q.shape[-1]); flat_o = out.reshape(-1)
    for i, row in enumerate(flat_q):
        row = np.maximum.accumulate(row)
        if x < row[0]:
            flat_o[i] = levels[0] / 2
        elif x >= row[-1]:
            flat_o[i] = 1 - (1 - levels[-1]) / 2
        else:
            flat_o[i] = np.interp(x, row, levels)
    return out


class Model:
    def __init__(self, name):
        self.name = name
        if name.startswith("t"):
            from timestral import TimestralForecaster
            repo = {"t209": "mistralai/Timestral-209M", "t28": "mistralai/Timestral-28M",
                    "t123": "mistralai/Timestral-123M", "t5": "mistralai/Timestral-5M"}[name]
            self.m = TimestralForecaster.from_pretrained(repo)
        else:
            from chronos import BaseChronosPipeline
            self.m = BaseChronosPipeline.from_pretrained("amazon/chronos-2", device_map="cpu")

    def forecast(self, ctx, H, known=None):
        """ctx (B, T) target; known (B, C, T+H) or None. Returns quantiles (B, H, K), levels."""
        if self.name.startswith("t"):
            kw = {}
            if known is not None:
                kw["known_covariates"] = known
            f = self.m.forecast(ctx[:, None, :], prediction_length=H, **kw)
            q = np.asarray(f.quantiles)[:, 0]  # (B, H, K)
            return q, np.asarray(f.quantile_levels)
        inputs = []
        for b in range(ctx.shape[0]):
            item = {"target": ctx[b]}
            if known is not None:
                T = ctx.shape[1]
                item["past_covariates"] = {f"c{j}": known[b, j, :T] for j in range(known.shape[1])}
                item["future_covariates"] = {f"c{j}": known[b, j, T:] for j in range(known.shape[1])}
            inputs.append(item)
        preds = self.m.predict(inputs, prediction_length=H, batch_size=256)
        q = np.stack([p[0].numpy().T for p in preds])  # p: (n_var, K, H) -> (H, K)
        return q, np.asarray(self.m.quantiles)


def load_inputs():
    panel = pd.read_parquet(f"{OUT}/panel.parquet")
    live = pd.read_parquet(f"{OUT}/live_lead1.parquet")
    live = live[live.input_mode == "weather"]
    zones = sorted(live.zone.unique())
    grid = pd.date_range("2022-12-01", "2026-11-17", freq="h")
    wide = {c: panel.pivot_table(index="t", columns="zone", values=c).reindex(index=grid, columns=zones)
            for c in ["price", "load_fc", "wind_fc", "solar_fc"]}
    wide["sim"] = live.pivot_table(index="t", columns="zone", values="sim").reindex(index=grid, columns=zones)
    # phase-2 physics covariates
    wide["resload"] = wide["load_fc"] - wide["wind_fc"].fillna(0) - wide["solar_fc"].fillna(0)
    wide["srmc"] = pd.DataFrame(np.repeat(srmc_series(grid).values[:, None], len(zones), axis=1),
                                index=grid, columns=zones)
    # pre-gate (06:30) physics: lead-2 sim and weekly-persisted residual load
    wide["sim2"] = lead2_sim(zones).reindex(index=grid, columns=zones)
    wide["resload7"] = wide["resload"].shift(168)
    return zones, grid, wide


def lead2_sim(zones):
    """Live weather-track sim at lead 2 for each Athens day D: the latest row issued before
    D-1 06:30 UTC (in practice the D-2 ~07:00 UTC daily run)."""
    import json
    live_dir = (os.environ.get('TSFM_LIVE') or sys.exit("Set TSFM_LIVE to the required local file or directory"))
    rows = []
    for z in zones:
        for day in json.load(open(f"{live_dir}/{z}.json"))["days"]:
            if day["lead_days"] != 2 or day["input_mode"] != "weather":
                continue
            made = pd.Timestamp(day["prediction_made_utc"]).tz_localize(None)
            gate = pd.Timestamp(day["date"]) - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)
            if made >= gate:
                continue
            for i, h in enumerate(day["hours"]):
                rows.append((z, made, pd.Timestamp(h).tz_localize(None), day["sim"][i]))
    df = pd.DataFrame(rows, columns=["zone", "made", "t", "sim"]).sort_values("made")
    df = df.drop_duplicates(["zone", "t"], keep="last")
    return df.pivot(index="t", columns="zone", values="sim")


def srmc_series(grid):
    """Gas-CCGT SRMC per hour (EUR/MWh) = TTF/0.5 + 0.202/0.5*EUA + 2, using the last closes dated
    strictly before D-1 of the hour's Athens market day (known at a D-1 morning issue)."""
    import duckdb
    db = (os.environ.get('EUPHEMIA_DUCKDB_PATH') or sys.exit("Set EUPHEMIA_DUCKDB_PATH to the required local file or directory"))
    c = duckdb.connect(db, read_only=True)
    f = {t: c.execute(f"SELECT date, close FROM yfinance.{t} WHERE close IS NOT NULL ORDER BY date").df()
         for t in ("ttf_f", "eua_co2")}
    day = grid.tz_localize("UTC").tz_convert(ATH).tz_localize(None).normalize()
    known_by = day - pd.Timedelta(days=1)              # closes dated < D-1
    out = {}
    for t, df in f.items():
        idx = np.searchsorted(df.date.values, known_by.values, side="left") - 1
        out[t] = np.where(idx >= 0, df.close.values[np.clip(idx, 0, None)], np.nan)
    return pd.Series(out["ttf_f"] / 0.5 + 0.202 / 0.5 * out["eua_co2"] + 2.0, index=grid)


_RAW = {}


def _emitter():
    if "ov" not in _RAW:
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "bin", "emit_tsfm_overlay.py")
        spec = importlib.util.spec_from_file_location("emit_tsfm_overlay", path)
        _RAW["ov"] = importlib.util.module_from_spec(spec); spec.loader.exec_module(_RAW["ov"])
    return _RAW["ov"]


def filtered_resload(d, zones, ctx_grid, hours):
    """Residual load on context + delivery hours as the production emitter builds it at the D-1 gate."""
    ov = _emitter()
    if "phys" not in _RAW:   # raw rows with publication stamps for the whole backtest span, read once
        db = (os.environ.get('EUPHEMIA_DUCKDB_PATH') or sys.exit("Set EUPHEMIA_DUCKDB_PATH to the required local file or directory"))
        con = ov.open_store("duckdb", db)
        _RAW["phys"] = ov.physics_from_store(con, "2026-11-13", ctx_hours=CTX + 70 * 24)
        _RAW["fallback"] = []
    load, res, fuel = _RAW["phys"]
    gate = pd.Timestamp(d) - pd.Timedelta(days=1) + pd.Timedelta(hours=ov.GATE_UTC_HOUR)
    k, pub = ov.physics_covariates(load, res, fuel, zones, ctx_grid, hours, cutoff=gate)
    return k[:, 0, :]


def build_inputs(d, variant, zones, grid, wide, settled_lag=2):
    # settled_lag=2 (default, BRIEF rule): context ends with Athens day D-2.
    # settled_lag=1 (sensitivity): context includes D-1 (its prices were auctioned on D-2 ~12:45 CET).
    cutoff = day_start_utc(d - timedelta(days=settled_lag - 1))
    s_D, e_D = day_start_utc(d), day_start_utc(d + timedelta(days=1))
    H = int((e_D - cutoff) / pd.Timedelta(hours=1))
    nD = int((e_D - s_D) / pd.Timedelta(hours=1))
    i0 = grid.get_loc(cutoff)
    ctx_idx = slice(i0 - CTX, i0)
    price = wide["price"].values.T                          # (Z, T)
    ctx = price[:, ctx_idx].copy()
    assert grid[i0 - 1] < cutoff  # no settled price at/after the start of D-1 enters the context
    known = None
    sim = wide["sim"].values.T
    if variant == "cov":
        rows = []
        for c in ["load_fc", "wind_fc", "solar_fc"]:
            a = wide[c].values.T[:, i0 - CTX:i0 + H].copy()
            a[np.all(np.isnan(a), axis=1)] = 0.0             # zone without that RES type
            rows.append(a)
        known = np.stack(rows, axis=1)
    elif variant == "sim":
        known = sim[:, i0 - CTX:i0 + H][:, None, :].copy()
    elif variant == "physpre":
        known = np.stack([wide[c].values.T[:, i0 - CTX:i0 + H] for c in ("sim2", "resload7", "srmc")], axis=1).copy()
    elif variant in ("phys", "physresid", "physfilt"):
        known = np.stack([wide[c].values.T[:, i0 - CTX:i0 + H] for c in ("sim", "resload", "srmc")], axis=1).copy()
        if variant == "physfilt":
            known[:, 1, :] = filtered_resload(d, zones, grid[i0 - CTX:i0], grid[i0:i0 + H])
        if variant == "physresid":
            ctx = ctx - sim[:, ctx_idx]
            first = np.where(~np.all(np.isnan(ctx), axis=0))[0][0]
            ctx, known = ctx[:, first:], known[:, :, first:]
    elif variant == "resid":
        ctx = ctx - sim[:, ctx_idx]
        # keep it compact: trim to the span where sim exists (live lead-1 from 2026-07-25)
        first = np.where(~np.all(np.isnan(ctx), axis=0))[0][0]
        ctx = ctx[:, first:]
    return ctx, known, H, nD, cutoff, s_D, sim[:, i0 + H - nD:i0 + H]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="t209")
    ap.add_argument("--variant", default="uni")
    ap.add_argument("--start", default="2026-09-14")
    ap.add_argument("--end", default="2026-11-13")
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument("--tag", default="")
    ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--dates", default="", help="comma-separated ISO dates; overrides --start/--end")
    ap.add_argument("--settled-lag", type=int, default=2, choices=[1, 2])
    a = ap.parse_args()
    torch.set_num_threads(a.threads)
    globals()["CTX"] = a.ctx
    zones, grid, wide = load_inputs()
    t0 = time.time(); m = Model(a.model); t_load = time.time() - t0
    rows, times = [], []
    if a.dates:
        days = [date.fromisoformat(x) for x in a.dates.split(",")]
    else:
        d0, end = date.fromisoformat(a.start), date.fromisoformat(a.end)
        days = [d0 + timedelta(days=i) for i in range((end - d0).days + 1)]
    for d in days:
        ctx, known, H, nD, cutoff, s_D, simD = build_inputs(d, a.variant, zones, grid, wide, a.settled_lag)
        t1 = time.time()
        q, lv = m.forecast(ctx.astype(np.float32), H, None if known is None else known.astype(np.float32))
        dt = time.time() - t1; times.append(dt)
        q = q[:, H - nD:, :]                                 # keep delivery day D only
        if a.variant in ("resid", "physresid"):
            q = q + np.nan_to_num(simD)[:, :, None]          # sim + residual quantiles
        med = q[:, :, np.argmin(np.abs(lv - 0.5))]
        p0 = p_le(q, lv, 0.0)
        p5 = p_le(q, lv, 5.0)
        issued = pd.Timestamp(datetime(d.year, d.month, d.day) - timedelta(days=1)) + pd.Timedelta(hours=6, minutes=30)
        for zi, z in enumerate(zones):
            for h in range(nD):
                r = dict(model=a.model, variant=a.variant, zone=z, market_date=d.isoformat(),
                         t=s_D + pd.Timedelta(hours=h), lead_days=1, issued_utc=issued, settled_lag=a.settled_lag,
                         context_end_utc=cutoff, median=float(med[zi, h]),
                         p_le0=float(p0[zi, h]), p_le5=float(p5[zi, h]))
                for k, l in enumerate(lv):
                    r[f"q{int(round(l * 100)):02d}"] = float(q[zi, h, k])
                rows.append(r)
        print(f"{d} H={H} ctx={ctx.shape} {dt:.1f}s", flush=True)
    df = pd.DataFrame(rows)
    fn = f"{OUT}/fc_{a.model}_{a.variant}{a.tag}.parquet"
    df.to_parquet(fn)
    print(f"wrote {fn} rows={len(df)} load={t_load:.1f}s per-day mean={np.mean(times):.1f}s "
          f"median={np.median(times):.1f}s total={sum(times):.0f}s threads={a.threads} ctx={a.ctx}")


if __name__ == "__main__":
    main()
