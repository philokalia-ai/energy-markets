"""Day-ahead target policy (#431 PR C): bin/da_target.py and the Python readers, on the
shared fixtures (test/fixtures/da_target_cases.json, also read by test/test_da_target.jl).
Runs without the extract: the fixtures are loaded into an in-memory DuckDB.

    python -m unittest test/test_da_target.py
"""
import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

import duckdb
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
import da_target as dt  # noqa: E402

FIX = json.loads((ROOT / "test" / "fixtures" / "da_target_cases.json").read_text())


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "bin" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def raw_frame(rows):
    df = pd.DataFrame(rows, columns=["z", "seq", "res", "t", "p", "u"])
    df["t"] = pd.to_datetime(df.t)
    df["u"] = pd.to_datetime(df.u)
    return df


def store(rows):
    con = duckdb.connect()
    con.execute("CREATE SCHEMA entsoe")
    con.execute("""CREATE TABLE entsoe.energy_prices(instance_code VARCHAR, date_time_utc TIMESTAMP,
        resolution_code VARCHAR, area_code VARCHAR, area_display_name VARCHAR, area_type_code VARCHAR,
        map_code VARCHAR, contract_type VARCHAR, sequence VARCHAR, price_currency_mwh DOUBLE,
        currency VARCHAR, update_time_utc TIMESTAMP, source VARCHAR)""")
    for i, (z, seq, res, t, p, u) in enumerate(rows):
        con.execute("INSERT INTO entsoe.energy_prices VALUES (?, ?, ?, ?, ?, 'BZN', ?, 'Day-ahead', ?, ?, 'EUR', ?, 'fx')",
                    [f"i{i}", t, res, z, z, z, seq, p, u])
    return con


def expect(lst):
    return {(z, pd.Timestamp(t)): v for z, t, v in lst}


def srt(df):
    return df.sort_values(list(df.columns[:2])).reset_index(drop=True)


def as_map(df, zc="z", vc="act"):
    return {(r[zc], pd.Timestamp(r["t"])): float(r[vc]) for _, r in df.iterrows()}


class DaTargetTest(unittest.TestCase):
    def assert_frame(self, got, want):
        self.assertEqual(set(got), set(want))
        for k, v in want.items():
            if v is not None:
                self.assertAlmostEqual(got[k], v, places=9, msg=str(k))

    def test_map_matches_shared_fixture(self):
        self.assertEqual(dt.SDAC_SEQUENCE, FIX["sdac_sequence"])

    def test_policy_parsing(self):
        # #431 C2: evaluation target defaults to sdac; model inputs stay pinned to highest_seq
        self.assertEqual(dt.policy({}), "sdac")
        self.assertEqual(dt.policy({dt.ENV: ""}), "sdac")
        self.assertEqual(dt.policy({dt.ENV: " HIGHEST_SEQ "}), "highest_seq")
        with self.assertRaises(ValueError):
            dt.policy({dt.ENV: "exaa"})
        self.assertEqual(dt.input_policy({}), "highest_seq")
        self.assertEqual(dt.input_policy({dt.ENV: "sdac"}), "highest_seq")   # target never leaks
        self.assertEqual(dt.input_policy({dt.INPUT_ENV: "sdac"}), "sdac")
        with self.assertRaises(ValueError):
            dt.input_policy({dt.INPUT_ENV: "exaa"})

    def test_cases_pure(self):
        for c in FIX["cases"]:
            with self.subTest(c["name"]):
                raw = raw_frame(c["rows"])
                act, excl, smap = dt.sdac_hourly(raw)
                self.assert_frame(as_map(act), expect(c["sdac"]))
                self.assertEqual(sorted(smap[smap.how == "ambiguous"].z), c["ambiguous"])
                if c["ambiguous"]:
                    self.assertTrue((excl[excl.z.isin(c["ambiguous"])].reason == "ambiguous auction").all())
                self.assert_frame(as_map(dt.highest_seq_hourly(raw)), expect(c["legacy"]))

    def test_tz_aware_input_is_naive_utc(self):
        # the postgres scanner returns timestamptz tz-aware; results must match the naive path
        c = FIX["cases"][0]
        raw = raw_frame(c["rows"])
        aware = raw.assign(t=raw.t.dt.tz_localize("UTC").dt.tz_convert("Europe/Berlin"),
                           u=raw.u.dt.tz_localize("UTC"))
        pd.testing.assert_frame_equal(dt.sdac_hourly(aware)[0], dt.sdac_hourly(raw)[0])
        pd.testing.assert_frame_equal(dt.highest_seq_hourly(aware), dt.highest_seq_hourly(raw))

    def test_exclusion_ledger_reasons(self):
        rows = [r for c in FIX["cases"] for r in c["rows"]]
        _, excl, _ = dt.sdac_hourly(raw_frame(rows))
        by = excl.groupby("reason").z.apply(lambda s: sorted(set(s))).to_dict()
        self.assertEqual(by["other auction"], ["AT", "DE_LU", "DK1"])
        self.assertEqual(by["superseded revision"], ["GR"])
        self.assertEqual(by["incomplete hour"], ["FR"])
        self.assertEqual(by["resolution not chosen for the hour"], ["ES", "PT"])
        self.assertEqual(by["ambiguous auction"], ["HU"])
        self.assertEqual(by["misaligned interval"], ["SE3"])

    def test_sql_paths_on_store(self):
        rows = [r for c in FIX["cases"] for r in c["rows"]]
        want_s = expect([x for c in FIX["cases"] for x in c["sdac"]])
        want_l = expect([x for c in FIX["cases"] for x in c["legacy"]])
        con = store(rows)
        lo, hi = "2026-11-10", "2026-11-11"
        self.assert_frame(as_map(dt.hourly_actuals(con, lo, hi, target="sdac")), want_s)
        self.assert_frame(as_map(dt.hourly_actuals(con, lo, hi, target="highest_seq")), want_l)
        cp, ov = load("collapse_probability"), load("emit_tsfm_overlay")
        with mock.patch.dict(os.environ, {dt.ENV: "highest_seq"}):   # the kill switch
            legacy_cp = cp.hourly_actuals(con, lo, hi, role="target")
            legacy_ov = ov.eval_actuals_duckdb(con, lo, hi)
            pd.testing.assert_frame_equal(srt(legacy_ov), srt(con.execute(ov.PRICE_SQL, [lo, hi]).df()))
            self.assert_frame(as_map(legacy_cp, "zone", "actual"), want_l)
            self.assert_frame(as_map(legacy_ov, "zone", "price"), want_l)
        cut = ov.day_start_utc("2026-11-11")
        ctx_legacy = srt(con.execute(ov.PRICE_SQL, [cut - pd.Timedelta(hours=48), cut]).df())
        for env in ({}, {dt.ENV: "sdac"}):   # the default target, and explicit
            with mock.patch.dict(os.environ, env):
                os.environ.pop(dt.INPUT_ENV, None)
                if not env:
                    os.environ.pop(dt.ENV, None)
                self.assert_frame(as_map(cp.hourly_actuals(con, lo, hi, role="target"), "zone", "actual"), want_s)
                self.assert_frame(as_map(ov.eval_actuals_duckdb(con, lo, hi), "zone", "price"), want_s)
                # model inputs stay pinned: collapse's training actuals and Timestral's context
                self.assert_frame(as_map(cp.hourly_actuals(con, lo, hi), "zone", "actual"), want_l)
                pd.testing.assert_frame_equal(srt(ov.prices_duckdb(con, "2026-11-11", ctx_hours=24)), ctx_legacy)
        with mock.patch.dict(os.environ, {dt.INPUT_ENV: "sdac"}):   # explicit opt-in only
            self.assert_frame(as_map(cp.hourly_actuals(con, lo, hi), "zone", "actual"), want_s)
        with mock.patch.dict(os.environ, {dt.ENV: "bogus"}), self.assertRaises(ValueError):
            cp.hourly_actuals(con, lo, hi, role="target")
        with mock.patch.dict(os.environ, {dt.INPUT_ENV: "bogus"}), self.assertRaises(ValueError):
            cp.hourly_actuals(con, lo, hi)
        with self.assertRaises(ValueError):
            cp.hourly_actuals(con, lo, hi, role="label")

    def test_collapse_relabel_uses_target(self):
        cp = load("collapse_probability")
        pred = pd.DataFrame({"zone": ["AT", "AT", "GR"], "t": pd.to_datetime(["2026-11-10 00:00", "2026-11-10 01:00", "2026-11-10 00:00"]),
                             "y": [0, 0, 1], "probability": [.1, .2, .9]})
        target = pd.DataFrame({"zone": ["AT", "GR"], "t": pd.to_datetime(["2026-11-10 00:00", "2026-11-10 00:00"]),
                               "actual": [-1.0, 5.0]})
        out, dropped = cp.retarget_labels(pred, target)
        self.assertEqual(dropped, 1)                       # AT 01:00 has no target actual
        self.assertEqual(out.y.tolist(), [1, 0])           # labels from the target, not the input
        self.assertEqual(out.probability.tolist(), [.1, .9])


if __name__ == "__main__":
    unittest.main()
