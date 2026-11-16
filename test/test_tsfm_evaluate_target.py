"""TSFM evaluator target routing (#431 PR C review P2): docs/experiments/tsfm-2026-11/evaluate.py
`load` must take its labels and naives from EUPHEMIA_DA_TARGET, while the forecasts (built from the
frozen highest-sequence panel) stay untouched. Synthetic TSFM_OUT + a temp DuckDB extract.

    python test/test_tsfm_evaluate_target.py
"""
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import duckdb
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
import da_target as dt  # noqa: E402

DAYS = pd.date_range("2026-11-02", "2026-11-10", freq="D")   # Athens market days; D = 11-10


def utc_hours(d):
    """UTC hours of Athens market day d (UTC+2 in November)."""
    return pd.date_range(d - pd.Timedelta(hours=2), periods=24, freq="h")


def build(tmp):
    rows = []   # map_code, sequence, t, price  (PT60M)
    for i, d in enumerate(DAYS):
        for h, t in enumerate(utc_hours(d)):
            rows += [("AT", "1", t, 80.0 + i + h / 100), ("AT", "2", t, 50.0 + i + h / 100),
                     ("GR", None, t, 30.0 + i + h / 100)]
    ext = os.path.join(tmp, "extract.duckdb")
    con = duckdb.connect(ext)
    con.execute("CREATE SCHEMA entsoe")
    con.execute("""CREATE TABLE entsoe.energy_prices(date_time_utc TIMESTAMP, resolution_code VARCHAR,
        area_type_code VARCHAR, map_code VARCHAR, contract_type VARCHAR, sequence VARCHAR,
        price_currency_mwh DOUBLE, currency VARCHAR, update_time_utc TIMESTAMP)""")
    con.executemany("INSERT INTO entsoe.energy_prices VALUES (?, 'PT60M', 'BZN', ?, 'Day-ahead', ?, ?, 'EUR', ?)",
                    [(t, z, s, p, t - pd.Timedelta(hours=12)) for z, s, t, p in rows])
    raw = dt.raw_rows(con, "2026-10-01", "2026-12-01")
    con.close()
    # the frozen panel: highest sequence (build_panel.py's rule), as the models were fed
    panel = dt.highest_seq_hourly(raw).rename(columns={"z": "zone", "act": "price"})
    panel.to_parquet(os.path.join(tmp, "panel.parquet"))
    hrs = utc_hours(DAYS[-1])
    live = pd.DataFrame([dict(zone=z, date="2026-11-10", t=t, sim=60.0, gbm=np.nan, stats=np.nan,
                              code_version=44, made="2026-11-09T09:00:00Z", input_mode="weather")
                         for z in ("AT", "GR") for t in hrs])
    live.to_parquet(os.path.join(tmp, "live_lead1.parquet"))
    fc = pd.DataFrame([dict(zone=z, t=t, median=55.0 + k, p_le0=0.1, p_le5=0.2, q10=40.0, q90=70.0)
                       for z in ("AT", "GR") for k, t in enumerate(hrs)])
    fc.to_parquet(os.path.join(tmp, "fc_x.parquet"))
    sdac = dt.sdac_hourly(raw)[0].rename(columns={"z": "zone", "act": "price"})
    sdac.to_parquet(os.path.join(tmp, "target_sdac.parquet"))
    return ext, panel, sdac


class EvaluateTargetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.ext, cls.panel, cls.sdac = build(cls.tmp)
        env = {"TSFM_OUT": cls.tmp, "EVAL_START": "2026-11-10", "EVAL_END": "2026-11-10"}
        with mock.patch.dict(os.environ, env):
            spec = importlib.util.spec_from_file_location(
                "tsfm_evaluate", ROOT / "docs" / "experiments" / "tsfm-2026-11" / "evaluate.py")
            cls.ev = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.ev)

    def load(self, **env):
        with mock.patch.dict(os.environ, env):   # restores the whole environment afterwards
            for k in {"EUPHEMIA_DA_TARGET", "EVAL_TARGET_PANEL", "EVAL_EXTRACT",
                      "EUPHEMIA_DUCKDB_PATH"} - env.keys():
                os.environ.pop(k, None)
            return self.ev.load(["fc_x"])[0].sort_values(["zone", "t"]).reset_index(drop=True)

    def expect(self, src, zone, day_offset):
        d = DAYS[-1] - pd.Timedelta(days=day_offset)
        s = src[(src.zone == zone) & src.t.isin(utc_hours(d))].sort_values("t")
        return s.price.to_numpy()

    def test_kill_switch_is_frozen_panel(self):
        df = self.load(EUPHEMIA_DA_TARGET="highest_seq")
        at = df[df.zone == "AT"]
        np.testing.assert_allclose(at.actual, self.expect(self.panel, "AT", 0))      # EXAA (seq 2)
        np.testing.assert_allclose(at.actual, self.expect(self.sdac, "AT", 0) - 30)  # sanity: 30 below SDAC
        np.testing.assert_allclose(at.naive_D1, self.expect(self.panel, "AT", 1))
        np.testing.assert_allclose(at.naive_D7, self.expect(self.panel, "AT", 7))

    def test_sdac_routes_labels_and_naives_not_forecasts(self):
        base = self.load(EUPHEMIA_DA_TARGET="highest_seq")
        for env in ({"EVAL_EXTRACT": self.ext},                       # the default target (#431 C2)
                    {"EUPHEMIA_DUCKDB_PATH": self.ext},
                    {"EUPHEMIA_DA_TARGET": "sdac", "EVAL_EXTRACT": self.ext},
                    {"EUPHEMIA_DA_TARGET": "sdac", "EVAL_TARGET_PANEL": f"{self.tmp}/target_sdac.parquet"}):
            with self.subTest(env=sorted(env)):
                df = self.load(**env)
                at, gr = df[df.zone == "AT"], df[df.zone == "GR"]
                np.testing.assert_allclose(at.actual, self.expect(self.sdac, "AT", 0))
                np.testing.assert_allclose(at.naive_D1, self.expect(self.sdac, "AT", 1))
                np.testing.assert_allclose(at.naive_D2, self.expect(self.sdac, "AT", 2))
                np.testing.assert_allclose(at.naive_D7, self.expect(self.sdac, "AT", 7))
                # single-auction zone and every forecast/sim column unchanged
                pd.testing.assert_frame_equal(gr.reset_index(drop=True),
                                              base[base.zone == "GR"].reset_index(drop=True))
                for c in ("x", "x_p0", "x_q10", "x_q90", "sim"):
                    pd.testing.assert_series_equal(df[c], base[c])

    def test_sdac_without_artifact_fails(self):
        with mock.patch.object(self.ev, "default_extract", return_value=None), self.assertRaises(ValueError):
            self.load()

    def test_bad_target_override_rejected(self):
        con = duckdb.connect(self.ext, read_only=True)
        with mock.patch.dict(os.environ, {"EUPHEMIA_DA_TARGET": "sdac"}):
            for bad in ("sadc", "exaa", ""):
                with self.assertRaises(ValueError):
                    dt.hourly_actuals(con, "2026-11-09", "2026-11-10", target=bad)
            a = dt.hourly_actuals(con, "2026-11-09", "2026-11-10", target=" SDAC ")
            self.assertTrue((a[a.z == "AT"].act >= 80).all())
        con.close()


if __name__ == "__main__":
    unittest.main()
