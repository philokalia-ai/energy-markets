"""bin/measure_windows.py: the windows measure-duckdb-path.yml's start guard and watchdog refuse (UTC, no DST)."""
import datetime as dt
import importlib.util
import io
import contextlib
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("measure_windows", Path(__file__).resolve().parent.parent / "bin" / "measure_windows.py")
W = importlib.util.module_from_spec(spec); spec.loader.exec_module(W)
UTC = dt.timezone.utc


def t(s):
    return dt.datetime.fromisoformat(s).replace(tzinfo=UTC)


def names(now, minutes):
    return sorted(n for n, _, _ in W.overlapping(t(now), minutes))


def run(*argv):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        rc = W.main(list(argv))
    return rc, out.getvalue()


class Windows(unittest.TestCase):
    def test_the_45392030610_start_is_refused(self):      # Tue 2026-11-24 12:17 + 120 min: the 12:30 ETL
        self.assertIn("ceres update_entsoe_data 12:30", names("2026-11-24T12:17", 120))

    def test_quiet_evening_is_allowed(self):
        self.assertEqual(names("2026-11-24T21:50", 120), [])
        self.assertEqual(names("2026-11-24T21:45", 135), [])           # ends exactly at the next window's start

    def test_window_edges_are_half_open(self):
        self.assertEqual(names("2026-11-24T14:35", 1), [])            # the 12:30 window ends at 14:35
        self.assertEqual(names("2026-11-24T14:34", 1), ["ceres update_entsoe_data 12:30"])
        self.assertEqual(names("2026-11-24T15:29", 1), [])
        self.assertEqual(names("2026-11-24T15:29", 2), ["ceres update_epias_data 15:30"])

    def test_weekday_sets(self):
        # yfinance 05:30 and gb_prices 06:00 run Tue-Sat only; entsog/gie 00:00 on Mondays only
        self.assertIn("ceres update_yfinance_data 05:30", names("2026-11-24T05:40", 1))      # Tuesday
        self.assertNotIn("ceres update_yfinance_data 05:30", names("2026-11-23T05:40", 1))   # Monday
        self.assertIn("ceres update_gie_only_data 00:00", names("2026-11-23T02:30", 1))      # Monday
        self.assertNotIn("ceres update_gie_only_data 00:00", names("2026-11-24T02:30", 1))   # Tuesday
        self.assertEqual(names("2026-11-23T03:35", 25), [])            # Monday 03:35-04:00 is free

    def test_midnight_wrap(self):
        # Sunday 23:00 + 120 min reaches Monday's 00:00 windows (entsoe, entsog, gie)
        self.assertEqual(names("2026-11-22T23:00", 120), ["ceres update_entsoe_data 00:00",
                                                          "ceres update_entsog_only_data 00:00",
                                                          "ceres update_gie_only_data 00:00"])
        self.assertEqual(names("2026-11-24T23:00", 120), ["ceres update_entsoe_data 00:00"])   # Tue -> Wed

    def test_a_window_started_the_previous_day_still_counts(self):
        saved = W.WINDOWS
        try:
            W.WINDOWS = [("late", "23:30", 120, W.ALL, "synthetic")]
            self.assertEqual(names("2026-11-25T00:30", 1), ["late"])
            self.assertEqual(names("2026-11-25T01:30", 1), [])
        finally:
            W.WINDOWS = saved

    def test_utc_conversion(self):
        # 14:17 in Athens (UTC+2) is 12:17 UTC
        self.assertEqual(W.parse_now("2026-11-24T14:17+02:00"), t("2026-11-24T12:17"))
        self.assertEqual(W.parse_now("2026-11-24T12:17"), t("2026-11-24T12:17"))

    def test_cli_exit_codes(self):
        rc, out = run("check-start", "--timeout-min", "120", "--now", "2026-11-24T12:17")
        self.assertEqual(rc, 1); self.assertIn("refused", out); self.assertIn("12:30", out)
        rc, out = run("check-start", "--timeout-min", "120", "--now", "2026-11-24T21:50")
        self.assertEqual(rc, 0); self.assertIn("windows OK", out)
        self.assertEqual(run("check-now", "--now", "2026-11-24T07:00")[0], 1)    # protected + yfinance + gb
        self.assertEqual(run("check-now", "--now", "2026-11-24T22:30")[0], 0)
        rc, out = run("table")
        self.assertEqual(rc, 0); self.assertEqual(out.count("\n| "), len(W.WINDOWS))   # one row per window

    def test_protected_windows_unchanged(self):
        self.assertIn("protected: live forecast", names("2026-11-24T08:29", 1))
        self.assertIn("protected: publish", names("2026-11-24T12:14", 1))


if __name__ == "__main__":
    unittest.main()
