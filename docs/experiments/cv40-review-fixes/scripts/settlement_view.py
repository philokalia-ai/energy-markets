# Canonical day-ahead settlement view (cv39 review, priority 1).
#
# `entsoe.energy_prices` stores more than one auction per delivery interval for
# some zones: DE_LU and AT carry the EXAA early auction as `sequence = '2'`
# (published ~11:10 CET on D-1) beside the SDAC auction as `sequence = '1'`
# (published ~14:15 CET, after the 12:00 CET gate); DK1/DK2 carry a secondary
# `'2'` series on 45 days beside their main blank-sequence series. Averaging
# them blends economically different products — the model targets SDAC.
#
# Selection rule, per zone, derived from the data rather than hard-coded:
#   1. keep EUR rows of contract_type 'Day-ahead';
#   2. per zone pick the sequence covering the most delivery days
#      (SDAC is the complete series; a secondary auction is partial);
#   3. ties (DE_LU/AT: both cover every day) go to the LATER median
#      publication time — the post-gate publication is SDAC, the pre-gate one
#      is the early auction;
#   4. within the chosen sequence keep one resolution per delivery interval
#      (the finest available), then average sub-hourly values into the hour.
#
# `canonical_settlement(cx, w0, w1)` returns a DataFrame z, t (naive UTC hour),
# a (EUR/MWh); `sequence_map(cx, w0, w1)` returns the chosen sequence per zone
# so a run can record which auction it was scored against.
import pandas as pd

_BASE = """
select map_code z, sequence seq, resolution_code res,
       date_time_utc t, price_currency_mwh p, update_time_utc u
from entsoe.energy_prices
where contract_type = 'Day-ahead' and currency = 'EUR'
  and price_currency_mwh is not null
  and date_time_utc >= %s and date_time_utc < %s
"""


def _raw(cx, w0, w1):
    df = pd.read_sql(_BASE, cx, params=(w0, w1))
    df["t"] = pd.to_datetime(df.t, utc=True).dt.tz_localize(None)
    df["u"] = pd.to_datetime(df.u, utc=True, errors="coerce").dt.tz_localize(None)
    df["seq"] = df.seq.fillna("").str.strip()
    return df


def sequence_map(cx, w0, w1, raw=None):
    df = _raw(cx, w0, w1) if raw is None else raw
    g = df.groupby(["z", "seq"]).agg(days=("t", lambda s: s.dt.normalize().nunique()),
                                     pub=("u", "median")).reset_index()
    g["pub"] = g.pub.fillna(pd.Timestamp.min)
    g = g.sort_values(["z", "days", "pub"], ascending=[True, False, False])
    return g.groupby("z").first()[["seq", "days"]]


def canonical_settlement(cx, w0, w1, return_map=False):
    df = _raw(cx, w0, w1)
    smap = sequence_map(cx, w0, w1, raw=df)
    keep = df.merge(smap.reset_index()[["z", "seq"]], on=["z", "seq"], how="inner")
    # one resolution per (zone, delivery interval): the finest published
    order = {"PT15M": 0, "PT30M": 1, "PT60M": 2}
    keep = keep.assign(_o=keep.res.map(order).fillna(9)).sort_values(["z", "t", "_o", "u"])
    keep = keep.drop_duplicates(["z", "t"], keep="first")
    keep["h"] = keep.t.dt.floor("h")
    out = keep.groupby(["z", "h"], as_index=False).p.mean().rename(columns={"h": "t", "p": "a"})
    return (out, smap) if return_map else out
