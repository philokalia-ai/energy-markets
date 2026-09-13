# Build data/model_lines_train/probe2y39_dataset.parquet: the model-line
# training set bound to the cv39 record.
#
#   features : cv39 order books (data/backfill_books_cv39/*.parquet)
#   physics  : cv39 record prices (simulations.energy_prices, multi_zone_eu)
#   target   : the CANONICAL SDAC settlement view (not the blended average)
#   resid    : settled - sim39, what the hybrid line learns to add
#
# Writes the dataset plus manifest.json so the emitter can derive the
# trained-on version from provenance rather than from a requested constant.
import os, sys, json, datetime as dt
import duckdb, pandas as pd, psycopg2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from settlement_view import canonical_settlement

ROOT = "/home/pgeorgakopoulos/armada/energy-markets"
CV = int(os.environ.get("BUILD_CV", "39"))
BOOKS = os.path.join(ROOT, "data", f"backfill_books_cv{CV}")
TRAIN = os.path.join(ROOT, "data", "model_lines_train")
W0, W1 = os.environ.get("W0", "2024-07-01"), os.environ.get("W1", "2026-07-01")
OUT = os.path.join(TRAIN, f"probe2y{CV}_dataset.parquet")

print(f"books   {BOOKS} ({len(os.listdir(BOOKS))} files)", flush=True)
con = duckdb.connect()
feat = con.sql(f"""
    select zone,
           strftime(ts AT TIME ZONE 'UTC', '%Y-%m-%dT%H') as k,
           sum(case when side='demand' then mw else 0 end)                    as D,
           sum(case when side='supply' and owner='RES'      then mw else 0 end) as res_mw,
           sum(case when side='supply' and owner='IMPORT'   then mw else 0 end) as imp_mw,
           sum(case when side='supply' and owner='BACKSTOP' then mw else 0 end) as bst_mw,
           sum(case when side='supply' then mw else 0 end)                    as stot
    from read_parquet('{BOOKS}/*.parquet')
    where market_date >= DATE '{W0}' and market_date < DATE '{W1}'
    group by 1, 2
""").df()
print("book feature rows:", len(feat), flush=True)
feat = feat[feat.D > 0].copy()
for c, n in (("res_sh", "res_mw"), ("imp_sh", "imp_mw"), ("bst_sh", "bst_mw")):
    feat[c] = feat[n] / feat.D
feat["margin"] = feat.stot / feat.D

cx = psycopg2.connect(os.environ["ENERGY_CONN_STR"])
sim = pd.read_sql(f"""
    select bidding_zone zone, (date_time_utc at time zone 'UTC') t, price_eur_mwh sim{CV}
    from simulations.energy_prices
    where clearing_mode='multi_zone_eu' and code_version={CV}
      and date_time_utc >= (%s)::timestamp at time zone 'UTC'
      and date_time_utc <  (%s)::timestamp at time zone 'UTC'""", cx, params=(W0, W1))
sim["k"] = pd.to_datetime(sim.t, utc=True).dt.strftime("%Y-%m-%dT%H")
print(f"cv{CV} price rows:", len(sim), flush=True)

act = canonical_settlement(cx, W0, W1)
act["k"] = pd.to_datetime(act.t, utc=True).dt.strftime("%Y-%m-%dT%H")
act = act.rename(columns={"z": "zone", "a": "settled"})[["zone", "k", "settled"]]
print("canonical settled rows:", len(act), flush=True)


def closes(csv):
    d = pd.read_csv(os.path.join(TRAIN, csv), header=None, names=["date", "close"])
    d["day"] = pd.to_datetime(d.date).dt.normalize()
    return d.sort_values("day")[["day", "close"]]


ttf, eua = closes("probe_ttf.csv"), closes("probe_eua.csv")
df = feat.merge(sim[["zone", "k", f"sim{CV}"]], on=["zone", "k"]).merge(act, on=["zone", "k"])
df["day"] = pd.to_datetime(df.k.str[:10])
df["hour"] = df.k.str[11:13].astype(int)
df["month"] = pd.to_datetime(df.k.str[:10]).dt.month
# the close available at the gate: last trading day strictly before the market day
df = pd.merge_asof(df.sort_values("day"), ttf.rename(columns={"close": "gas"}),
                   on="day", direction="backward", allow_exact_matches=False)
df = pd.merge_asof(df.sort_values("day"), eua.rename(columns={"close": "co2"}),
                   on="day", direction="backward", allow_exact_matches=False)
df["resid"] = df.settled - df[f"sim{CV}"]
df = df.dropna(subset=["settled", f"sim{CV}", "gas", "co2"])
df["day"] = df.day.dt.date
cols = ["zone", "k", "day", "hour", "month", "D", "res_sh", "imp_sh", "bst_sh",
        "margin", "gas", "co2", "settled", f"sim{CV}", "resid"]
df = df[cols].sort_values(["zone", "k"]).reset_index(drop=True)
df.to_parquet(OUT, index=False)
json.dump({"dataset": os.path.basename(OUT), "book_cv": CV,
           "target": "canonical SDAC settlement view (settlement_view.py)",
           "window": [W0, W1], "rows": len(df), "zones": int(df.zone.nunique()),
           "built": dt.datetime.utcnow().isoformat() + "Z"},
          open(os.path.join(TRAIN, "manifest.json"), "w"), indent=2)
print(f"wrote {OUT}: {len(df)} rows, {df.zone.nunique()} zones, "
      f"{df.day.min()}..{df.day.max()}", flush=True)
print("resid mean/std:", round(df.resid.mean(), 2), round(df.resid.std(), 2))
