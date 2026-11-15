"""Gate 1 of the Timestral PS-budget pilot (planner-p2 idea #1): does a Timestral forecast of
daily pumped-storage generation, blended 50/50 with the cv44 14-day mean, predict delivery-day
PS generation better than E14 and D-7 persistence? No fitting, no price input.
usage: venv-tsfm/bin/python -I gate1_budget.py OUT.csv
Context ends at the lead-1 cutoff = D-1 00:00 UTC (complete days through D-2), the same
cutoff `_storage_cutoff_day` uses at lead 1 / on the record path."""
import sys, duckdb, numpy as np, pandas as pd, torch
torch.set_num_threads(16)
EXTRACT = "/home/pgeorgakopoulos/armada/em-data/euphemia-live-20261114.duckdb"
DAYS = ["2026-09-16", "2026-09-20", "2026-09-27", "2026-10-06", "2026-10-19", "2026-11-02", "2026-11-04", "2026-11-13"]
CTX = 2048
con = duckdb.connect(EXTRACT, read_only=True)
g = con.sql("""
  select area_map_code z, date_trunc('hour', date_time_utc) t, avg(actual_generation_output_mw) mw
  from entsoe.aggregated_generation_per_type
  where production_type='Hydro Pumped Storage' and area_type_code like 'BZN%'
    and actual_generation_output_mw is not null and date_time_utc >= '2025-12-01'
  group by 1,2""").df()
g["t"] = pd.to_datetime(g.t)
from timestral import TimestralForecaster
m = TimestralForecaster.from_pretrained("mistralai/Timestral-209M")
rows = []
for ds in DAYS:
    D = pd.Timestamp(ds); cutoff = D - pd.Timedelta(days=1)          # first excluded instant
    grid = pd.date_range(cutoff - pd.Timedelta(hours=CTX), cutoff - pd.Timedelta(hours=1), freq="h")
    zones, ctxs, meta = [], [], []
    for z, gz in g.groupby("z"):
        s = gz.set_index("t").mw
        hist = s[(s.index >= cutoff - pd.Timedelta(days=14)) & (s.index < cutoff)]
        daily = hist.groupby(hist.index.floor("D")).agg(["sum", "count"])
        daily = daily[daily["count"] >= 20]
        if daily.empty or daily["sum"].mean() < 10: continue          # no family (as in code)
        e14 = daily["sum"].mean()
        d7 = s[(s.index >= D - pd.Timedelta(days=7)) & (s.index < D - pd.Timedelta(days=6))]
        act = s[(s.index >= D) & (s.index < D + pd.Timedelta(days=1))]
        c = s.reindex(grid)
        miss = int(c.isna().sum())
        c = c.interpolate(limit_direction="both").fillna(0.0).to_numpy(dtype=np.float32)
        zones.append(z); ctxs.append(c)
        meta.append(dict(day=ds, zone=z, e14=e14, d7=d7.sum() if len(d7) == 24 else np.nan,
                         act=act.sum() if len(act) == 24 else np.nan, ctx_missing=miss,
                         p95x24=float(np.nanpercentile(s[(s.index >= cutoff - pd.Timedelta(days=30)) & (s.index < cutoff)], 95)) * 24))
    f = m.forecast(np.stack(ctxs)[:, None, :], prediction_length=48)
    q = np.asarray(f.quantiles)[:, 0]; lv = np.asarray(f.quantile_levels)
    med = q[:, :, int(np.argmin(np.abs(lv - 0.5)))]
    for i, mt in enumerate(meta):
        mt["ehat"] = float(np.clip(med[i, 24:48], 0, None).sum())       # delivery day D = hours 24..47
        rows.append(mt)
    print(ds, len(meta), "zones", flush=True)
df = pd.DataFrame(rows)
df["blend"] = np.minimum(0.5 * df.e14 + 0.5 * df.ehat, df.p95x24)
df.to_csv(sys.argv[1], index=False)
ok = df.dropna(subset=["act", "d7"])
print(f"fully observed zone-days: {len(ok)} of {len(df)}; zones {ok.zone.nunique()}")
for c in ["e14", "d7", "ehat", "blend"]:
    print(f"  MAE {c:6s} {np.mean(np.abs(ok[c] - ok.act)):9.1f} MWh/day   bias {np.mean(ok[c] - ok.act):+9.1f}")
mb = np.mean(np.abs(ok.blend - ok.act))
for c in ["e14", "d7"]:
    me = np.mean(np.abs(ok[c] - ok.act)); print(f"  blend vs {c}: {100*(me-mb)/me:+.1f}% (gate: >= +10%)")
