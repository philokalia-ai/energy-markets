"""Temporal-leakage and data-rule tests for docs/experiments/lear-431/lear.py (no extract needed)."""
import importlib.util
import unittest
from pathlib import Path

import numpy as np
import pandas as pd

spec = importlib.util.spec_from_file_location(
    "lear", Path(__file__).resolve().parents[1] / "docs" / "experiments" / "lear-431" / "lear.py")
lear = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lear)


def synthetic_matrix(start="2023-01-01", days=500, seed=0):
    rng = np.random.default_rng(seed)
    idx = pd.date_range(start, periods=days, freq="D")
    base = 80 + 20 * np.sin(np.arange(days) / 30)[:, None] + 15 * np.sin(np.arange(24) / 24 * 2 * np.pi)[None, :]
    return pd.DataFrame(base + rng.normal(0, 5, (days, 24)), index=idx, columns=range(24))


class LeakageTest(unittest.TestCase):
    def test_train_days_strictly_before_target(self):
        for W in (56, 364):
            tr = lear.train_days("2024-07-01", W)
            self.assertEqual(len(tr), W)
            self.assertEqual(tr.max(), pd.Timestamp("2024-06-30"))
            self.assertEqual(tr.min(), pd.Timestamp("2024-07-01") - pd.Timedelta(days=W))

    def test_features_use_backward_lags_only(self):
        M = synthetic_matrix()
        D = pd.Timestamp("2024-03-01")
        x = lear.features(M, [D])[0]
        for i, k in enumerate(lear.LAGS):
            np.testing.assert_array_equal(x[24 * i:24 * (i + 1)], M.loc[D - pd.Timedelta(days=k)].to_numpy())
        self.assertTrue(all(k >= 1 for k in lear.LAGS))
        self.assertEqual(x[96:].sum(), 1.0)
        self.assertEqual(int(np.argmax(x[96:])), D.dayofweek)

    def test_future_rows_cannot_change_a_forecast(self):
        M = synthetic_matrix()
        D = pd.Timestamp("2024-03-01")
        p1, i1 = lear.fit_predict(M, D, 84)
        M2 = M.copy()
        M2.loc[M2.index >= D] += 1e4          # the target day and everything after it
        p2, i2 = lear.fit_predict(M2, D, 84)
        np.testing.assert_allclose(p1, p2)
        self.assertEqual(i1["fit_last"], "2024-02-29")
        self.assertLess(pd.Timestamp(i1["fit_last"]), D)

    def test_past_rows_do_change_a_forecast(self):
        # control for the test above: the model does read the calibration window
        M = synthetic_matrix()
        D = pd.Timestamp("2024-03-01")
        p1, _ = lear.fit_predict(M, D, 84)
        M2 = M.copy()
        M2.loc[D - pd.Timedelta(days=1)] += 50.0
        p2, _ = lear.fit_predict(M2, D, 84)
        self.assertGreater(np.abs(p1 - p2).max(), 1e-6)

    def test_insufficient_history_refuses(self):
        M = synthetic_matrix(days=60)
        p, info = lear.fit_predict(M, M.index[50], 364)
        self.assertTrue(np.isnan(p).all())


class TransformTest(unittest.TestCase):
    def test_invariant_roundtrip(self):
        x = np.array([[-50.0, 10.0], [0.0, 20.0], [100.0, 30.0], [3000.0, 40.0]])
        med, mad = lear.inv_fit(x)
        np.testing.assert_allclose(lear.inv_back(lear.inv_tf(x, med, mad), med, mad), x)


class DataRuleTest(unittest.TestCase):
    def raw(self):
        t15 = pd.date_range("2025-10-01 00:00", periods=8, freq="15min")
        rows = []
        for t in t15:   # SDAC seq 1 at 100, EXAA seq 2 at 500 (must never be used)
            rows.append(dict(z="DE_LU", seq="1", res="PT15M", t=t, p=100.0, u=pd.Timestamp("2025-09-30 12:00")))
            rows.append(dict(z="DE_LU", seq="2", res="PT15M", t=t, p=500.0, u=pd.Timestamp("2025-09-30 13:00")))
        # a later revision of one SDAC quarter
        rows.append(dict(z="DE_LU", seq="1", res="PT15M", t=t15[0], p=140.0, u=pd.Timestamp("2025-09-30 14:00")))
        # GR: one series, hourly 01:00 plus an incomplete 15-min hour at 02:00 (3 quarters)
        rows.append(dict(z="GR", seq="", res="PT60M", t=pd.Timestamp("2025-10-01 01:00"), p=70.0, u=pd.Timestamp("2025-09-30 12:00")))
        for m in (0, 15, 30):
            rows.append(dict(z="GR", seq="", res="PT15M", t=pd.Timestamp("2025-10-01 02:00") + pd.Timedelta(minutes=m), p=1.0, u=pd.Timestamp("2025-09-30 12:00")))
        return pd.DataFrame(rows)

    def test_sdac_not_exaa_latest_revision_complete_hours(self):
        h = lear.sdac_from_raw(self.raw()).set_index(["zone", "t"]).price
        self.assertAlmostEqual(h[("DE_LU", pd.Timestamp("2025-10-01 00:00"))], (140 + 100 * 3) / 4)
        self.assertAlmostEqual(h[("DE_LU", pd.Timestamp("2025-10-01 01:00"))], 100.0)
        self.assertAlmostEqual(h[("GR", pd.Timestamp("2025-10-01 01:00"))], 70.0)
        self.assertNotIn(("GR", pd.Timestamp("2025-10-01 02:00")), h.index)    # incomplete hour dropped

    def test_unmapped_multi_sequence_zone_fails_closed(self):
        r = self.raw().assign(z=lambda d: d.z.replace({"DE_LU": "AT"}))
        with self.assertRaises(ValueError):
            lear.sdac_from_raw(r, sequence_map={"GR": ""})


class DstTest(unittest.TestCase):
    def test_target_slots(self):
        self.assertEqual(len(lear.target_slots("2026-03-29")), 23)
        f = lear.target_slots("2026-10-25")
        self.assertEqual(len(f), 25)
        self.assertEqual(int((f.slot == 3).sum()), 2)
        self.assertEqual(len(lear.target_slots("2026-11-13")), 24)

    def test_daily_matrix_dst(self):
        t = pd.date_range("2026-03-27 22:00", "2026-10-26 22:00", freq="h", inclusive="left")
        h = pd.DataFrame({"zone": "GR", "t": t, "price": np.arange(len(t), dtype=float)})
        M = lear.daily_matrix(h)["GR"]
        spring = M.loc["2026-03-29"]
        self.assertFalse(spring.isna().any())                           # slot 3 interpolated
        self.assertAlmostEqual(spring[3], (spring[2] + spring[4]) / 2)
        fall = M.loc["2026-10-25"]
        # repeated local 03:00 = UTC 00:00 and 01:00 -> mean of the two source values
        i0 = int(np.where(t == pd.Timestamp("2026-10-25 00:00"))[0][0])
        self.assertAlmostEqual(fall[3], (i0 + i0 + 1) / 2)


if __name__ == "__main__":
    unittest.main()
