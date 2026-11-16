# TEMPORARY: prefer bin/da_target.py once PR C lands; remove this port then.
# Fixed API snapshot from 431/da-target-policy commit b70636b (2026-11-16).
# Pure repository settlement_view rule; source body hash is recorded in the
# target-helper parity output. No production paths are modified by this copy.
"""Day-ahead target policy: which settled auction an hourly "actual" is (#431, PR C).

Python twin of the Julia helper in test/scripts/eu_eval_metrics.jl
(`da_target_actuals`, `canonical_hourly_actuals`). The two share the fixtures in
test/fixtures/da_target_cases.json; change both or neither.

Policies, selected by EUPHEMIA_DA_TARGET (unset or empty = highest_seq):

* ``highest_seq`` (default, today's behaviour): latest numeric ``sequence`` per
  (zone, interval), tie-broken by latest ``update_time_utc``, then a plain mean
  of the sub-hourly prices in each hour. In AT and DE_LU this selects sequence 2,
  the early EXAA auction. Readers keep their own legacy SQL for this policy, so
  their frames stay byte-identical; ``highest_seq_hourly`` is the same rule as a
  pure function for offline comparisons.
* ``sdac``: the SDAC auction only, from an explicit zone -> sequence map
  (``SDAC_SEQUENCE``), ported from
  docs/experiments/cv40-review-fixes/scripts/settlement_view.py:
    1. a zone in the map keeps only its mapped sequence; a zone with one sequence
       in the window keeps it; a zone with several sequences and no map entry is
       AMBIGUOUS and fails closed: all its rows are excluded and the zone is listed;
    2. revisions: the latest ``update_time_utc`` per (zone, resolution, interval)
       wins (ties: higher price, so the choice is deterministic);
    3. intervals must start on their resolution's grid (else "misaligned interval");
       one resolution per (zone, hour): the finest with every aligned slot of the
       hour present; an hour no resolution covers is dropped ("incomplete hour");
    4. duration-weighted mean over the hour.
  There is no fallback to EXAA when SDAC is missing: the hour is simply absent.

Public API (stable; the 431E evaluator imports it):
  policy(env=os.environ) -> "highest_seq" | "sdac"
  SDAC_SEQUENCE, RES_MINUTES, RAW_SQL
  auction_map(raw, sequence_map=SDAC_SEQUENCE) -> DataFrame[z, seq, how, n_seq]
  raw_rows(con, start, end) -> DataFrame[z, seq, res, t, p, u]   (DuckDB, [start, end) UTC)
  highest_seq_hourly(raw) -> DataFrame[z, t, act]
  sdac_hourly(raw, sequence_map=SDAC_SEQUENCE) -> (act, excluded, smap)
  hourly_actuals(con, start, end, target=None) -> DataFrame[z, t, act]
"""
from __future__ import annotations

import os
import warnings

import numpy as np
import pandas as pd

ENV = "EUPHEMIA_DA_TARGET"
POLICIES = ("highest_seq", "sdac")

# Explicit zone -> SDAC sequence. AT/DE_LU sequence "2" is EXAA (the Julia
# Q15_NON_SDAC_SEQUENCE drops it from the 15-min target for the same reason);
# DK1/DK2 carry a secondary "2" series that copies SDAC to float noise, and the
# main series has a blank sequence. Every other zone publishes one series.
SDAC_SEQUENCE = {"AT": "1", "DE_LU": "1", "DK1": "", "DK2": ""}
RES_MINUTES = {"PT15M": 15, "PT30M": 30, "PT60M": 60}

RAW_SQL = """
SELECT map_code AS z, trim(coalesce(sequence, '')) AS seq, trim(resolution_code) AS res,
       date_time_utc AS t, price_currency_mwh AS p, update_time_utc AS u
FROM entsoe.energy_prices
WHERE contract_type = 'Day-ahead' AND area_type_code LIKE 'BZN%' AND currency = 'EUR'
  AND price_currency_mwh IS NOT NULL
  AND date_time_utc >= ?::TIMESTAMP AND date_time_utc < ?::TIMESTAMP"""

_EXCL_COLS = ["z", "t", "seq", "res", "p", "reason"]


def policy(env=os.environ) -> str:
    """The selected target policy; an unknown value raises (never a silent default)."""
    v = (env.get(ENV) or "highest_seq").strip().lower()
    if v not in POLICIES:
        raise ValueError(f"{ENV}={v!r}: expected one of {POLICIES}")
    return v


def raw_rows(con, start, end) -> pd.DataFrame:
    """Every day-ahead BZN row with sequence/resolution/update stamp, UTC [start, end)."""
    df = con.execute(RAW_SQL, [str(start), str(end)]).df()
    return _norm(df)


def _norm(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["seq"] = df.seq.fillna("").astype(str).str.strip()
    df["res"] = df.res.fillna("").astype(str).str.strip()
    # naive UTC, the extract's convention: through the postgres scanner `timestamptz`
    # columns arrive tz-aware (see naive_utc in emit_tsfm_overlay/collapse_probability)
    for c in ("t", "u"):
        x = pd.to_datetime(df[c])
        if isinstance(x.dtype, pd.DatetimeTZDtype):
            x = x.dt.tz_convert("UTC").dt.tz_localize(None)
        df[c] = x
    df["p"] = df.p.astype(float)
    return df


def highest_seq_hourly(raw: pd.DataFrame) -> pd.DataFrame:
    """The legacy rule (`resolution_aware_actuals`) as a pure function."""
    df = _norm(raw)
    df["seqn"] = pd.to_numeric(df.seq, errors="coerce")
    df = df.sort_values(["z", "t", "seqn", "u"], ascending=[True, True, False, False],
                        na_position="last", kind="mergesort")
    df = df.drop_duplicates(["z", "t"], keep="first")
    df["h"] = df.t.dt.floor("h")
    out = df.groupby(["z", "h"], as_index=False).p.mean().rename(columns={"h": "t", "p": "act"})
    return out.sort_values(["z", "t"]).reset_index(drop=True)


def auction_map(raw: pd.DataFrame, sequence_map=SDAC_SEQUENCE) -> pd.DataFrame:
    """Per zone: the chosen sequence and how ('mapped' / 'single' / 'ambiguous')."""
    rows = []
    for z, g in raw.groupby("z"):
        seqs = sorted(g.seq.unique())
        if z in sequence_map:
            rows.append((z, sequence_map[z], "mapped", len(seqs)))
        elif len(seqs) == 1:
            rows.append((z, seqs[0], "single", 1))
        else:
            rows.append((z, None, "ambiguous", len(seqs)))
    return pd.DataFrame(rows, columns=["z", "seq", "how", "n_seq"])


def sdac_hourly(raw: pd.DataFrame, sequence_map=SDAC_SEQUENCE):
    """SDAC hourly actuals. Returns (act[z, t, act], excluded[z, t, seq, res, p, reason], smap)."""
    df = _norm(raw)
    smap = auction_map(df, sequence_map)
    excl = []
    amb = smap[smap.how == "ambiguous"]
    if len(amb):
        warnings.warn(f"{ENV}=sdac: zones with several auctions and no SDAC mapping, "
                      f"excluded (fail closed): {sorted(amb.z)}")
    want = smap[smap.how != "ambiguous"][["z", "seq"]]
    m = df.merge(want, on=["z", "seq"], how="left", indicator=True)
    lost = m[m._merge == "left_only"].copy()
    lost["reason"] = np.where(lost.z.isin(amb.z), "ambiguous auction", "other auction")
    excl.append(lost[_EXCL_COLS])
    keep = m[m._merge == "both"].drop(columns="_merge")

    unk = ~keep.res.isin(RES_MINUTES)
    excl.append(keep[unk].assign(reason="unknown resolution")[_EXCL_COLS])
    keep = keep[~unk]

    # an interval must start on its own grid (PT30M at :00/:30, PT15M at :00/:15/...):
    # a summed-duration test alone would accept 00:15+00:45 PT30M and leave 00:00-00:15 empty
    step = keep.res.map(RES_MINUTES).astype("int64")
    mis = (keep.t.dt.minute % step != 0) | (keep.t.dt.second != 0) | (keep.t.dt.microsecond != 0)
    excl.append(keep[mis].assign(reason="misaligned interval")[_EXCL_COLS])
    keep = keep[~mis]

    keep = keep.sort_values(["z", "res", "t", "u", "p"], na_position="first", kind="mergesort")
    dup = keep.duplicated(["z", "res", "t"], keep="last")
    excl.append(keep[dup].assign(reason="superseded revision")[_EXCL_COLS])
    keep = keep[~dup].copy()

    keep["h"] = keep.t.dt.floor("h")
    keep["mins"] = keep.res.map(RES_MINUTES).astype("int64")
    cov = keep.groupby(["z", "h", "res"], as_index=False).mins.sum()
    # aligned + one row per (z, res, t): 60 covered minutes == every slot of the hour present
    cov = cov[cov.mins == 60].assign(rank=lambda x: x.res.map(RES_MINUTES))
    pick = cov.sort_values(["z", "h", "rank"]).drop_duplicates(["z", "h"])[["z", "h", "res"]]
    mm = keep.merge(pick, on=["z", "h", "res"], how="left", indicator=True)
    left = mm[mm._merge == "left_only"]
    full_h = set(map(tuple, pick[["z", "h"]].to_numpy()))
    reason = np.where([(z, h) in full_h for z, h in zip(left.z, left.h)],
                      "resolution not chosen for the hour", "incomplete hour")
    excl.append(left.assign(reason=reason)[_EXCL_COLS])
    keep = mm[mm._merge == "both"].copy()

    keep["pm"] = keep.p * keep.mins
    agg = keep.groupby(["z", "h"], as_index=False).agg(pm=("pm", "sum"), mins=("mins", "sum"))
    act = (agg.assign(act=agg.pm / agg.mins).rename(columns={"h": "t"})[["z", "t", "act"]]
              .sort_values(["z", "t"]).reset_index(drop=True))
    ex = pd.concat([e for e in excl if len(e)], ignore_index=True) if any(len(e) for e in excl) \
        else pd.DataFrame(columns=_EXCL_COLS)
    return act, ex, smap


def hourly_actuals(con, start, end, target=None) -> pd.DataFrame:
    """Hourly actuals under `target` (default: the env policy), naive-UTC hours in [start, end)."""
    target = target or policy()
    raw = raw_rows(con, start, end)
    if target == "sdac":
        return sdac_hourly(raw)[0]
    return highest_seq_hourly(raw)
