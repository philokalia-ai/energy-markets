"""Timing and scoring invariants; runs without the extract."""
import importlib.util
from pathlib import Path
import unittest

import numpy as np
import pandas as pd

spec = importlib.util.spec_from_file_location("collapse_probability", Path(__file__).resolve().parents[1] / "bin" / "collapse_probability.py")
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)


class CollapseProbabilityTest(unittest.TestCase):
    def fixture(self):
        t = pd.date_range("2026-09-01", periods=50 * 24, freq="h")
        actual = pd.DataFrame({"zone": "GR", "t": t, "actual": np.where(t.hour < 8, 0., 100.)})
        forecast = pd.DataFrame({"zone": "GR", "t": t, "load": 100., "solar": 20., "wind": 10.,
                                 "load_stamp": t.floor("D") - pd.Timedelta(days=1) + pd.Timedelta(hours=5),
                                 "solar_stamp": t, "wind_stamp": t})
        return actual, forecast

    def test_labels_after_d2_do_not_change_target_features(self):
        actual, fc = self.fixture()
        df, f = cp.build_features(actual, fc, "pregate_0630")
        market = cp.with_calendar(actual).market_date
        altered = actual.copy()
        altered.loc[market >= "2026-10-09", "actual"] = -1000
        df2, f2 = cp.build_features(altered, fc, "pregate_0630")
        target = df.market_date == "2026-10-10"
        np.testing.assert_allclose(f[target], f2[target], equal_nan=True)
        # Changes in D-2 must remain informative.
        altered.loc[market == "2026-10-08", "actual"] = -1000
        _, f3 = cp.build_features(altered, fc, "pregate_0630")
        self.assertFalse(np.allclose(f.loc[target, "price_lag2"], f3.loc[target, "price_lag2"]))

    def test_post_issuance_forecasts_are_excluded(self):
        actual, fc = self.fixture()
        df, f = cp.build_features(actual, fc, "pregate_0630")
        changed = fc.copy()
        # Today's RES rows are unavailable at D-1, but their D-2 persistence
        # may be available; only change the target day's unavailable rows.
        changed.loc[(changed.t >= "2026-10-10") & (changed.t < "2026-10-11"), ["solar", "wind"]] = 10000
        _, f2 = cp.build_features(actual, changed, "pregate_0630")
        target = df.market_date == "2026-10-10"
        np.testing.assert_allclose(f[target], f2[target], equal_nan=True)
        # Even the D-2 persistence is rejected if its stored revision is late.
        changed[["solar_stamp", "wind_stamp"]] = pd.Timestamp("2027-01-01")
        _, f3 = cp.build_features(actual, changed, "pregate_0630")
        self.assertTrue(f3.res_share.isna().all())

    def test_probabilities_and_undefined_metrics(self):
        x = np.array([[0., np.nan], [1., np.nan], [2., np.nan], [3., np.nan]])
        model = cp.fit_logistic(x, np.array([0, 0, 1, 1]))
        p = cp.predict_logistic(model, x)
        self.assertTrue(np.all((p >= 0) & (p <= 1)))
        self.assertLess(p[0], p[-1])
        all_negative = cp.probability_metrics([0, 0], [0, 0])
        self.assertIsNone(all_negative["auc"])
        self.assertIsNone(all_negative["hit_rate"])
        self.assertEqual(cp.probability_metrics([0, 1], [0, 1])["brier"], 0)
        self.assertEqual(cp.probability_metrics([0, 1], [0, 1])["false_alarm_rate"], 0)

    def test_scaling_is_training_only(self):
        x = np.array([[0.], [1.], [2.], [3.]])
        model = cp.fit_logistic(x, np.array([0, 0, 1, 1]))
        before = cp.predict_logistic(model, [[1.5]])[0]
        after = cp.predict_logistic(model, [[1.5], [1e10]])[0]
        self.assertEqual(before, after)

    def test_dst_lag_is_market_day(self):
        actual, fc = self.fixture()
        actual.t += pd.Timedelta(days=22)
        fc.t += pd.Timedelta(days=22)
        df = cp.with_calendar(actual)
        source = df.copy()
        source["actual"] = source.market_date.dt.day.astype(float)
        lag = cp.lag_by_market_day(source, ["actual"], 2)
        target = source.market_date == "2026-10-26"
        self.assertTrue((lag.loc[target, "actual"] == 24).all())


if __name__ == "__main__":
    unittest.main()
