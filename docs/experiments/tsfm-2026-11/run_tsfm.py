"""Zero-shot / hybrid TSFM day-ahead price forecasts, lead-1, pre-gate information set.

Information-set rule (enforced in `build_inputs`): for delivery day D (Europe/Athens market day,
same hours as the live JSON), the forecast is issued nominally at D-1 06:30 UTC. The last
settled day known then is **D-2** (BRIEF addendum), so the price context ends at the start of
Athens day D-1 and the model forecasts D-1 and D (48 h, 47/49 on DST days); only D is kept.

Variants
  uni    prices only                                                 -> label (a) pre-gate 06:30
  cov    + ENTSO-E D-1 load / wind / solar forecasts as known-future  -> label (b) gate-time ~10:00
         covariates (latest vintage in the extract; RES update stamps are not provably pre-gate)
  sim    + the live lead-1 weather-track counterfactual `sim` as a     -> label (a) (sim is the
         known-future covariate (history + D-1 + D)                       pre-gate live product)
  resid  forecast the residual (settled - sim) through D-2, add it     -> label (a)
         to sim for D

Models: t209 / t28 = mistralai/Timestral-{209M,28M}; c2 = amazon/chronos-2.
Output: $TSFM_OUT/fc_<model>_<variant>.parquet, one row per (zone, hour of D).
"""
import argparse, os, time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import numpy as np, pandas as pd, torch

OUT = os.environ.get("TSFM_OUT", "/home/pgeorgakopoulos/armada/em-team/results/tsfm")
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
    return zones, grid, wide


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
    ap.add_argument("--settled-lag", type=int, default=2, choices=[1, 2])
    a = ap.parse_args()
    torch.set_num_threads(a.threads)
    globals()["CTX"] = a.ctx
    zones, grid, wide = load_inputs()
    t0 = time.time(); m = Model(a.model); t_load = time.time() - t0
    rows, times = [], []
    d, end = date.fromisoformat(a.start), date.fromisoformat(a.end)
    while d <= end:
        ctx, known, H, nD, cutoff, s_D, simD = build_inputs(d, a.variant, zones, grid, wide, a.settled_lag)
        t1 = time.time()
        q, lv = m.forecast(ctx.astype(np.float32), H, None if known is None else known.astype(np.float32))
        dt = time.time() - t1; times.append(dt)
        q = q[:, H - nD:, :]                                 # keep delivery day D only
        if a.variant == "resid":
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
        d += timedelta(days=1)
    df = pd.DataFrame(rows)
    fn = f"{OUT}/fc_{a.model}_{a.variant}{a.tag}.parquet"
    df.to_parquet(fn)
    print(f"wrote {fn} rows={len(df)} load={t_load:.1f}s per-day mean={np.mean(times):.1f}s "
          f"median={np.median(times):.1f}s total={sum(times):.0f}s threads={a.threads} ctx={a.ctx}")


if __name__ == "__main__":
    main()
