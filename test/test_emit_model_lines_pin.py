"""#392 supersede: a pinned physics base with no rows skips ONLY the hybrid line.

Runs without Postgres or data/: the emitter module is loaded with stubbed heavy
imports where missing, and `lines_for_day` is fed synthetic frames.
Standalone:  python3 test/test_emit_model_lines_pin.py
"""
import datetime as dt
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

import numpy as np
import pandas as pd

for mod in ("psycopg2", "joblib", "duckdb"):           # not needed by lines_for_day
    if importlib.util.find_spec(mod) is None:
        sys.modules[mod] = types.ModuleType(mod)
if importlib.util.find_spec("sklearn") is None:
    sk = types.ModuleType("sklearn"); ens = types.ModuleType("sklearn.ensemble")
    ens.HistGradientBoostingRegressor = object
    sys.modules["sklearn"] = sk; sys.modules["sklearn.ensemble"] = ens

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("emit_model_lines", ROOT / "bin" / "emit_model_lines.py")
eml = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eml)


class Const:
    def __init__(self, v): self.v = v
    def predict(self, X): return np.full(len(X), self.v)


T = dt.date(2026, 11, 14)


def frames(base_versions):
    """feats for GR/BG on T; physics base rows at the given versions (freshest wins)."""
    ks = [f"{T}T{h:02d}" for h in range(24)]
    feats = pd.DataFrame([dict(zone=z, k=k, D=5000., res_sh=.3, imp_sh=.1, bst_sh=0., margin=1.4)
                          for z in ("GR", "BG") for k in ks])
    base = pd.DataFrame([dict(zone=z, t=pd.Timestamp(k + ":00", tz="UTC"), sim=100., base_cv=cv, k=k)
                         for cv in base_versions for z in ("GR", "BG") for k in ks],
                        columns=["zone", "t", "sim", "base_cv", "k"])
    t = pd.date_range(pd.Timestamp(T) - pd.Timedelta(days=10), pd.Timestamp(T), freq="h",
                      tz="UTC", inclusive="left")
    st = pd.concat([pd.DataFrame(dict(zone=z, t=t, p=90.)) for z in ("GR", "BG")], ignore_index=True)
    return feats, base, st


class PinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        for f in ("probe_ttf.csv", "probe_eua.csv"):
            with open(os.path.join(self.tmp.name, f), "w") as fh:
                fh.write("2026-11-01 00:00:00,30.0\n")
        self._train = eml.TRAIN; eml.TRAIN = self.tmp.name
        self.models = {"hybrid": {"GR": Const(5.), "BG": Const(5.)},
                       "stats": {"GR": Const(77.), "BG": Const(77.)}}

    def tearDown(self):
        eml.TRAIN = self._train; self.tmp.cleanup()

    def run_day(self, base_h, base_any, st, feats, last_settled=T - dt.timedelta(days=1)):
        return eml.lines_for_day(T, feats, base_h, base_any, st, last_settled, self.models)

    def test_pinned_base_empty_keeps_stats(self):
        # production today: only cv43 forecasts, artifact pinned to cv37
        feats, base_any, st = frames([43])
        base_h = base_any[base_any.base_cv == 37]
        rows, hyb, sta = self.run_day(base_h, base_any, st, feats)
        self.assertTrue(hyb.startswith("SKIPPED"))
        self.assertEqual(sta, "emitted")
        self.assertEqual({r[2] for r in rows}, {"stats_gbm"})
        self.assertEqual(len(rows), 48)
        self.assertTrue(all(r[5] is None for r in rows))       # stats has no base
        self.assertTrue(all(r[3] == 77. for r in rows))

    def test_pinned_base_present_emits_both(self):
        feats, base_any, st = frames([37])
        rows, hyb, sta = self.run_day(base_any, base_any, st, feats)
        self.assertEqual((hyb, sta), ("emitted", "emitted"))
        h = [r for r in rows if r[2] == "hybrid_gbm"]
        self.assertEqual(len(h), 48)
        self.assertTrue(all(r[3] == 105. and r[5] == 37 for r in h))

    def test_no_forecast_at_all_emits_nothing(self):
        feats, base_any, st = frames([])
        rows, hyb, sta = self.run_day(base_any, base_any, st, feats)
        self.assertEqual(rows, [])
        self.assertTrue(hyb.startswith("SKIPPED"))
        self.assertTrue(sta.startswith("skipped"))

    def test_stats_not_due_beyond_lag24(self):
        feats, base_any, st = frames([43])
        rows, hyb, sta = self.run_day(base_any[base_any.base_cv == 37], base_any, st, feats,
                                      last_settled=T - dt.timedelta(days=3))
        self.assertEqual(rows, [])
        self.assertTrue(sta.startswith("not due"))

    def test_main_does_not_systemexit_on_empty_pin(self):
        src = (ROOT / "bin" / "emit_model_lines.py").read_text()
        body = src[src.index("def main():"):]
        self.assertNotIn("SystemExit", body)


if __name__ == "__main__":
    unittest.main()
