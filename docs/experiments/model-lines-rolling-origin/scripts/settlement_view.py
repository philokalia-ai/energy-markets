# Canonical day-ahead settlement view (cv39 review priority 1; revised after
# the 2026-09-13 cv40 review).
#
# `entsoe.energy_prices` stores more than one auction per delivery interval for
# some zones: DE_LU and AT carry the EXAA early auction (sequence '2',
# published ~11:10 CET on D-1) beside the SDAC auction (sequence '1', published
# ~14:15 CET, after the 12:00 CET gate). DK1/DK2 carry a secondary '2' series
# on 45 days beside their main blank-sequence series. Averaging them blends
# economically different products; the model targets SDAC.
#
# The mapping is EXPLICIT and dated (AUCTION_MAP) rather than inferred, because
# a coverage/publication heuristic can flip when the evaluation window or the
# ingestion history changes. Unknown multi-sequence zones FAIL CLOSED: they are
# reported, and excluded unless `strict=False`.
#
# Within the selected auction:
#   * revisions: the LATEST `update_time_utc` per (zone, interval) wins;
#   * resolution: ONE resolution per (zone, delivery hour) — the finest whose
#     intervals actually cover the hour — so an hourly row is never averaged
#     with quarter-hour rows of the same hour;
#   * aggregation to the hour is DURATION-WEIGHTED, and an hour is emitted only
#     if its coverage is complete (`require_full_hour`, the default).
#
# `canonical_settlement(cx, w0, w1)` returns z, t (naive UTC hour), a (EUR/MWh).
# `return_map=True` adds the per-zone auction choice; `return_excluded=True`
# adds the rows dropped and why — the exclusion ledger the review asked for.
import numpy as np
import pandas as pd

_BASE = """
select map_code z, sequence seq, resolution_code res,
       date_time_utc t, price_currency_mwh p, update_time_utc u
from entsoe.energy_prices
where contract_type = 'Day-ahead' and currency = 'EUR'
  and price_currency_mwh is not null
  and date_time_utc >= (%s)::timestamp at time zone 'UTC'
  and date_time_utc <  (%s)::timestamp at time zone 'UTC'
"""


def _raw(cx, w0, w1):
    # The window bounds are UTC. `date_time_utc` is timestamptz, so a bare date
    # string is resolved in the SESSION time zone — on this server Europe/Berlin,
    # which silently closed the window two hours early and dropped the last two
    # UTC hours of the final day (39 zones x 2 = the 78 cells the 2026-09-13
    # review found missing from the score). Qualify the bounds as UTC.
    df = pd.read_sql(_BASE, cx, params=(w0, w1))
    df["t"] = pd.to_datetime(df.t, utc=True).dt.tz_localize(None)
    df["u"] = pd.to_datetime(df.u, utc=True, errors="coerce").dt.tz_localize(None)
    df["seq"] = df.seq.fillna("").str.strip()
    return df


# Explicit zone → SDAC sequence, with the date from which it applies. Sequence
# '2' in DE_LU/AT is the EXAA early auction (E-Control identifies it as such);
# DK1/DK2's secondary '2' series is not the SDAC result either. Every other
# zone publishes one series, recorded here as "" meaning "whatever it has".
AUCTION_MAP = {"DE_LU": ("1", "1900-01-01"), "AT": ("1", "1900-01-01"),
               "DK1": ("", "1900-01-01"), "DK2": ("", "1900-01-01")}
_RES_MIN = {"PT15M": 15, "PT30M": 30, "PT60M": 60}


def sequence_map(cx, w0, w1, raw=None, strict=True):
    """Per-zone chosen sequence, and how it was chosen ('mapped' / 'single' / 'ambiguous')."""
    df = _raw(cx, w0, w1) if raw is None else raw
    rows = []
    for z, g in df.groupby("z"):
        seqs = sorted(g.seq.unique())
        if z in AUCTION_MAP:
            want, since = AUCTION_MAP[z]
            rows.append((z, want, "mapped", since, len(seqs)))
        elif len(seqs) == 1:
            rows.append((z, seqs[0], "single", "", 1))
        else:
            rows.append((z, seqs[0], "ambiguous", "", len(seqs)))
    out = pd.DataFrame(rows, columns=["z", "seq", "how", "since", "n_seq"]).set_index("z")
    bad = out[out.how == "ambiguous"]
    if len(bad) and strict:
        raise ValueError(f"settlement view: zones with several auctions and no mapping: "
                         f"{list(bad.index)} — add them to AUCTION_MAP")
    return out


def canonical_settlement(cx, w0, w1, return_map=False, return_excluded=False,
                         require_full_hour=True, strict=True):
    df = _raw(cx, w0, w1)
    smap = sequence_map(cx, w0, w1, raw=df, strict=strict)
    excluded = []

    keep = df.merge(smap.reset_index()[["z", "seq"]], on=["z", "seq"], how="inner")
    excluded.append(df.merge(smap.reset_index()[["z", "seq"]], on=["z", "seq"], how="left",
                             indicator=True).query("_merge == 'left_only'")
                    .assign(reason="other auction")[["z", "t", "seq", "res", "p", "reason"]])

    # revisions: latest publication per (zone, resolution, interval) wins
    keep = keep.sort_values(["z", "res", "t", "u"])
    dup = keep.duplicated(["z", "res", "t"], keep="last")
    excluded.append(keep[dup].assign(reason="superseded revision")[["z", "t", "seq", "res", "p", "reason"]])
    keep = keep[~dup]

    # one resolution per (zone, hour): the finest whose intervals cover the hour
    keep["h"] = keep.t.dt.floor("h")
    keep["mins"] = keep.res.map(_RES_MIN)
    cov = (keep.groupby(["z", "h", "res"]).mins.sum().rename("covered").reset_index())
    cov["rank"] = cov.res.map(_RES_MIN)
    full = cov[cov.covered >= 60] if require_full_hour else cov
    pick = (full.sort_values(["z", "h", "rank"]).drop_duplicates(["z", "h"], keep="first")
                [["z", "h", "res"]])
    merged = keep.merge(pick, on=["z", "h", "res"], how="left", indicator=True)
    excluded.append(merged.query("_merge == 'left_only'")
                    .assign(reason="resolution not chosen for the hour")[["z", "t", "seq", "res", "p", "reason"]])
    keep = merged.query("_merge == 'both'").drop(columns="_merge")

    # duration-weighted mean over the hour
    keep["pm"] = keep.p * keep.mins
    agg = keep.groupby(["z", "h"], as_index=False).agg(pm=("pm", "sum"), mins=("mins", "sum"))
    if require_full_hour:
        short = agg[agg.mins < 60]
        if len(short):
            excluded.append(short.assign(reason="incomplete hour", t=short.h, seq="", res="", p=np.nan)
                            [["z", "t", "seq", "res", "p", "reason"]])
        agg = agg[agg.mins >= 60]
    out = agg.assign(a=agg.pm / agg.mins).rename(columns={"h": "t"})[["z", "t", "a"]]

    if not (return_map or return_excluded):
        return out
    res = (out,)
    if return_map:
        res += (smap,)
    if return_excluded:
        res += (pd.concat(excluded, ignore_index=True) if excluded else pd.DataFrame(),)
    return res
