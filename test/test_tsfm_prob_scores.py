"""Unit tests for docs/experiments/tsfm-2026-11/prob_scores.py (no extract, no saved forecasts)."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

spec = importlib.util.spec_from_file_location(
    "prob_scores", Path(__file__).resolve().parents[1] / "docs" / "experiments" / "tsfm-2026-11" / "prob_scores.py")
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)


class PinballTest(unittest.TestCase):
    def test_analytic_examples(self):
        # y above q: tau * (y - q); y below q: (1 - tau) * (q - y); y == q: 0
        self.assertAlmostEqual(float(ps.pinball(10.0, 4.0, 0.9)), 5.4)
        self.assertAlmostEqual(float(ps.pinball(10.0, 4.0, 0.1)), 0.6)
        self.assertAlmostEqual(float(ps.pinball(4.0, 10.0, 0.9)), 0.6)
        self.assertAlmostEqual(float(ps.pinball(4.0, 10.0, 0.1)), 5.4)
        self.assertEqual(float(ps.pinball(7.0, 7.0, 0.3)), 0.0)
        # tau = 0.5 is half the absolute error
        self.assertAlmostEqual(float(ps.pinball(3.0, -1.0, 0.5)), 2.0)

    def test_grid_weights_sum_to_one(self):
        w = ps.grid_weights(ps.LEVELS)
        self.assertAlmostEqual(w.sum(), 1.0)
        self.assertTrue((w > 0).all())
        self.assertAlmostEqual(w[0], 0.03)     # [0, (0.01+0.05)/2]

    def test_crps_grid_approximates_normal(self):
        # closed form for N(mu, s): s * [z(2F(z)-1) + 2f(z) - 1/sqrt(pi)]
        mu, s = 50.0, 20.0
        y = np.array([10.0, 50.0, 75.0, 130.0])
        z = (y - mu) / s
        exact = s * (z * (2 * stats.norm.cdf(z) - 1) + 2 * stats.norm.pdf(z) - 1 / np.sqrt(np.pi))
        dense = np.linspace(0.0025, 0.9975, 399)
        Qd = np.tile(stats.norm.ppf(dense, mu, s), (len(y), 1))
        np.testing.assert_allclose(ps.crps_from_grid(y, Qd, dense), exact, rtol=0.01)
        Q21 = np.tile(stats.norm.ppf(ps.LEVELS, mu, s), (len(y), 1))
        np.testing.assert_allclose(ps.crps_from_grid(y, Q21, ps.LEVELS), exact, rtol=0.08)


class GuardTest(unittest.TestCase):
    def frame(self, rows):
        return pd.DataFrame(rows, columns=ps.QCOLS)

    def test_missing_level_rejected(self):
        r = list(np.arange(21.0)); r[5] = np.nan
        with self.assertRaises(ValueError):
            ps.check_grid(self.frame([r]), ps.QCOLS)

    def test_crossed_quantiles_counted_and_sorted(self):
        ok = list(np.arange(21.0)); bad = list(np.arange(21.0)); bad[3], bad[4] = bad[4], bad[3]
        out, crossed = ps.check_grid(self.frame([ok, bad]), ps.QCOLS)
        self.assertEqual(crossed, 1)
        self.assertTrue((np.diff(out[ps.QCOLS].to_numpy(), axis=1) >= 0).all())

    def test_inclusive_endpoints(self):
        y = np.array([1.0, 2.0, 3.0, 0.999, 3.001])
        self.assertEqual(ps.covered(y, 1.0, 3.0).tolist(), [True, True, True, False, False])

    def test_interval_score(self):
        # inside: width only; below by 1 at alpha 0.2: width + 2/0.2 * 1
        self.assertAlmostEqual(float(ps.interval_score(5.0, 0.0, 10.0, 0.2)), 10.0)
        self.assertAlmostEqual(float(ps.interval_score(-1.0, 0.0, 10.0, 0.2)), 20.0)


class ReliabilityTest(unittest.TestCase):
    def test_perfect_calibration_has_zero_rel(self):
        p = np.r_[np.full(100, 0.005), np.full(100, 0.5)]
        y = np.r_[np.zeros(100), np.r_[np.ones(50), np.zeros(50)]]
        # the low bin's mean p is 0.005 but freq 0 -> tiny REL; the 0.5 bin is exact
        tab, s = ps.reliability(p, y)
        self.assertLess(s["REL"], 1e-4)
        self.assertAlmostEqual(s["Brier"], np.mean((p - y) ** 2))
        self.assertEqual(int(tab.n.sum()), 200)

    def test_alarms(self):
        t = ps.alarm_table(np.array([0.05, 0.35, 0.6, 0.9]), np.array([0, 0, 1, 1]), thresholds=(0.3, 0.5))
        self.assertEqual(t.alarms.tolist(), [3, 2])
        self.assertEqual(t.hits.tolist(), [2, 2])
        self.assertAlmostEqual(t.precision.iloc[0], 2 / 3)


class ConformalTest(unittest.TestCase):
    def data(self, days=40, zones=("A", "B"), seed=0):
        rng = np.random.default_rng(seed)
        rows = []
        for z in zones:
            for d in pd.date_range("2026-09-01", periods=days):
                for h in range(24):
                    y = rng.normal(0, 10 if z == "A" else 1)
                    rows.append(dict(zone=z, date=d.date().isoformat(), actual=y, q10=-1.0, q90=1.0))
        return pd.DataFrame(rows)

    def test_no_overlap_and_full_window_only(self):
        df = self.data()
        before = df[["q10", "q90"]].copy()
        o = ps.conformal_offsets(df, "q10", "q90", 80, days=28)
        self.assertTrue(df[["q10", "q90"]].equals(before))          # raw quantiles unchanged
        self.assertTrue((o.cal_last < o.eval_day).all())            # strictly before D
        self.assertTrue((o.cal_first >= o.eval_day - pd.Timedelta(days=28)).all())
        self.assertEqual(o.eval_day.min(), pd.Timestamp("2026-09-29"))   # first day with 28 prior days
        self.assertEqual(int(o.n_cal.iloc[0]), 28 * 24)

    def test_future_rows_do_not_change_offsets(self):
        df = self.data()
        o1 = ps.conformal_offsets(df, "q10", "q90", 80).set_index(["zone", "eval_day"]).offset
        df2 = df.copy()
        df2.loc[df2.date >= "2026-10-05", "actual"] += 1000.0      # perturb the future
        o2 = ps.conformal_offsets(df2, "q10", "q90", 80).set_index(["zone", "eval_day"]).offset
        early = o1.index.get_level_values("eval_day") <= pd.Timestamp("2026-10-05")
        np.testing.assert_allclose(o1[early], o2[early])

    def test_coverage_recovered_per_zone(self):
        df = self.data(days=80, seed=1)
        o = ps.conformal_offsets(df, "q10", "q90", 80)
        df["day"] = pd.to_datetime(df.date)
        ev = df.merge(o, left_on=["zone", "day"], right_on=["zone", "eval_day"])
        cov = ps.covered(ev.actual, ev.q10 - ev.offset, ev.q90 + ev.offset)
        for z in ("A", "B"):
            self.assertAlmostEqual(cov[ev.zone == z].mean(), 0.8, delta=0.04)
        # zone B's raw interval is too wide (y ~ N(0,1) vs [-1,1] ~ 68 %): offset is small; A's large
        self.assertGreater(o[o.zone == "A"].offset.median(), 5 * abs(o[o.zone == "B"].offset.median()))


class LiveLoaderTest(unittest.TestCase):
    def test_dedup_and_disagreement(self):
        day = dict(date="2026-11-16", hours=["2026-11-15T22:00:00Z", "2026-11-15T23:00:00Z"],
                   actual=[10.0, None], tsfm=[12.0, 11.0], tsfm_q10=[5.0, 4.0], tsfm_q90=[20.0, 18.0],
                   p_le0=[0.01, 0.02], p_any_le0=0.03, tsfm_issue_utc="2026-11-15T06:30:00Z",
                   tsfm_arm="timestral-209m", tsfm_input_mode="pregate0630")
        empty = dict(day, date="2026-11-17", tsfm=[None, None])
        with tempfile.TemporaryDirectory() as d:
            js = {"zone": "GR", "days": [dict(day, lead_days=1, input_mode="weather"),
                                         dict(day, lead_days=2, input_mode="entsoe_persist"), empty]}
            Path(d, "GR.json").write_text(json.dumps(js))
            h, dd = ps.load_live(d)
            self.assertEqual(len(h), 2)
            self.assertEqual(len(dd), 1)
            js["days"][1] = dict(day, tsfm=[99.0, 11.0], lead_days=2, input_mode="entsoe_persist")
            Path(d, "GR.json").write_text(json.dumps(js))
            with self.assertRaises(ValueError):
                ps.load_live(d)


if __name__ == "__main__":
    unittest.main()
