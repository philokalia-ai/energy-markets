"""Timing and scoring invariants; runs without the extract."""
import importlib.util
from pathlib import Path
import unittest
import sys
import json

import numpy as np
import pandas as pd
import duckdb

spec = importlib.util.spec_from_file_location("collapse_probability", Path(__file__).resolve().parents[1] / "bin" / "collapse_probability.py")
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import collapse_diagnostics as cd


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
        df, f = cp.build_features(actual, fc, "pregate_0630", settled_lag=2)
        market = cp.with_calendar(actual).market_date
        altered = actual.copy()
        altered.loc[market >= "2026-10-09", "actual"] = -1000
        df2, f2 = cp.build_features(altered, fc, "pregate_0630", settled_lag=2)
        target = df.market_date == "2026-10-10"
        np.testing.assert_allclose(f[target], f2[target], equal_nan=True)
        # Changes in D-2 must remain informative.
        altered.loc[market == "2026-10-08", "actual"] = -1000
        _, f3 = cp.build_features(altered, fc, "pregate_0630", settled_lag=2)
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
        # A feature never observed in training remains inactive at inference.
        np.testing.assert_array_equal(cp.predict_logistic(model, [[1., np.nan]]),
                                      cp.predict_logistic(model, [[1., 1e10]]))
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

    def test_serialized_model_is_directly_usable(self):
        x = np.array([[0., np.nan], [1., np.nan], [2., np.nan], [3., np.nan]])
        model = cp.fit_logistic(x, np.array([0, 0, 1, 1]))
        saved = json.loads(json.dumps({k: v.tolist() if isinstance(v, np.ndarray) else v for k, v in model.items()}))
        np.testing.assert_array_equal(cp.predict_logistic(model, x), cp.predict_logistic(saved, x))

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

    def test_daily_event_requires_complete_day(self):
        actual, fc = self.fixture()
        df, f = cp.build_features(actual, fc, "pregate_0630")
        day, day_features = cd.daily_dataset(df, f)
        complete = day[day.market_date == "2026-10-10"]
        self.assertEqual(len(complete), 1)
        self.assertEqual(complete.actual.iloc[0], 0)
        self.assertTrue(np.isnan(day.actual.iloc[0]))  # first local day partial
        df.loc[df.market_date == "2026-10-10", "actual"] = np.nan
        day2, _ = cd.daily_dataset(df, f)
        self.assertTrue(day2.loc[day2.market_date == "2026-10-10", "actual"].isna().all())

    def test_threshold_diagnostics(self):
        y, p = np.array([0, 0, 1, 1]), np.array([0.1, 0.6, 0.5, 0.9])
        threshold = cd.best_f1_threshold(y, p)
        self.assertEqual(threshold, 0.5)
        zero = cd.matched_fpr_threshold(y, p, 0)
        score = cd.detection(y, p, zero)
        self.assertEqual(score["false_alarms"], 0)
        self.assertEqual(score["hits"], 1)

    def test_decimal_hourly_zero_is_a_collapse(self):
        con = duckdb.connect(":memory:")
        con.execute("CREATE SCHEMA entsoe")
        con.execute("""CREATE TABLE entsoe.energy_prices AS SELECT
          'GR' AS map_code, TIMESTAMP '2026-09-20' + i*INTERVAL '15 minutes' AS date_time_utc,
          v AS price_currency_mwh, 'Day-ahead' AS contract_type, 'BZN' AS area_type_code,
          'EUR' AS currency, '1' AS sequence, TIMESTAMP '2026-09-19' AS update_time_utc,
          'PT15M' AS resolution_code, cast(i AS VARCHAR) AS instance_code
          FROM (VALUES (0,0.01::DOUBLE),(1,0.02::DOUBLE),(2,-0.01::DOUBLE),(3,-0.02::DOUBLE)) t(i,v)""")
        a = cp.hourly_actuals(con, "2026-09-20", "2026-09-21")
        self.assertEqual(a.actual.iloc[0], 0)
        self.assertTrue(a.actual.iloc[0] <= 0)

    def test_publication_filter_precedes_resolution_selection(self):
        con = duckdb.connect(":memory:")
        con.execute("CREATE SCHEMA entsoe")
        con.execute("""CREATE TABLE entsoe.day_ahead_total_load_forecast AS
          SELECT 'GR' AS area_map_code, TIMESTAMP '2026-09-20' AS date_time_utc,
          'PT60M' AS resolution_code, 50.::DOUBLE AS total_load_mw,
          TIMESTAMP '2026-09-19 05:00' AS update_time_utc, 'BZN' AS area_type_code""")
        # A later, more complete resolution must not suppress the early row.
        con.execute("""INSERT INTO entsoe.day_ahead_total_load_forecast
          SELECT 'GR',TIMESTAMP '2026-09-20'+i*INTERVAL '15 minutes','PT15M',200.,
          TIMESTAMP '2026-09-19 15:00','BZN' FROM range(96) t(i)""")
        con.execute("""CREATE TABLE entsoe.generation_forecasts_for_wind_and_solar
          (area_map_code VARCHAR,date_time_utc TIMESTAMP,resolution_code VARCHAR,
           production_type VARCHAR,day_ahead_generation_forecast_mw DOUBLE,
           update_time_utc TIMESTAMP,area_type_code VARCHAR)""")
        fc = cp.hourly_forecasts(con, "2026-09-20", "2026-09-21")
        row = fc[fc.t == pd.Timestamp("2026-09-20")].iloc[0]
        self.assertEqual(row.load, 200)
        self.assertEqual(row.load_pre0630, 50)

    def test_public_d1_price_history_still_excludes_target(self):
        actual, fc = self.fixture()
        df, f = cp.build_features(actual, fc, "pregate_0630", settled_lag=1)
        changed = actual.copy()
        market = cp.with_calendar(actual).market_date
        changed.loc[market >= "2026-10-10", "actual"] = -1000
        _, after = cp.build_features(changed, fc, "pregate_0630", settled_lag=1)
        target = df.market_date == "2026-10-10"
        np.testing.assert_allclose(f[target], after[target], equal_nan=True)
        self.assertIn("price_lag1", f)
        self.assertNotIn("price_lag2", f)
        _, default_features = cp.build_features(actual, fc, "pregate_0630")
        self.assertIn("price_lag1", default_features)
        changed.loc[market == "2026-10-09", "actual"] = -1000
        _, previous_day = cp.build_features(changed, fc, "pregate_0630", settled_lag=1)
        self.assertFalse(np.allclose(f.loc[target, "price_lag1"], previous_day.loc[target, "price_lag1"]))
        with self.assertRaises(ValueError):
            cp.build_features(actual, fc, "pregate_0630", settled_lag=0)



class LiveBaselineResolutionTest(unittest.TestCase):
    """cv46 (review of #476 #6): a quarter-hour live day weighs like an hourly one (per hour, not 4x)."""

    def write(self, tmp, days):
        Path(tmp, "GR.json").write_text(json.dumps({"zone": "GR", "days": days}))

    def day(self, date, stamps, sims, acts):
        return {"date": date, "lead_days": 1, "input_mode": "weather", "code_version": 46,
                "prediction_made_utc": f"{date}T06:30:00Z", "hours": stamps, "sim": sims, "actual": acts}

    def test_hourly_unchanged_and_quarters_averaged(self):
        import tempfile
        hs = [f"2026-11-01T{h:02d}:00:00Z" for h in range(24)]
        qs = [f"2026-11-02T{h:02d}:{m:02d}:00Z" for h in range(24) for m in (0, 15, 30, 45)]
        with tempfile.TemporaryDirectory() as tmp:
            self.write(tmp, [self.day("2026-11-01", hs, [float(h) for h in range(24)], [0.5 + h for h in range(24)]),
                             self.day("2026-11-02", qs, [float(k) for k in range(96)], [1.0] * 96)])
            df = cp.live_baseline(tmp, "2026-11-01", "2026-11-02")
        self.assertEqual(list(df.columns), ["zone", "t", "market_date", "sim", "actual_live", "issued", "code_version"])
        self.assertEqual(df.groupby("market_date").size().to_dict(), {"2026-11-01": 24, "2026-11-02": 24})
        h = df[df.market_date == "2026-11-01"]
        self.assertEqual(h.sim.tolist(), [float(x) for x in range(24)])          # hourly: values as published
        self.assertEqual(h.actual_live.tolist(), [0.5 + x for x in range(24)])
        q = df[df.market_date == "2026-11-02"]
        self.assertEqual(q.sim.tolist(), [4 * x + 1.5 for x in range(24)])      # mean of the hour's 4 quarters
        self.assertTrue((q.t.dt.minute == 0).all())


if __name__ == "__main__":
    unittest.main()
