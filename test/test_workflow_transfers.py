"""Transfer placement in the fill -> run -> transfer workflows (#472 review #4, #5): the slices reach Postgres right
after the clears and again after scoring, every transfer runs after a failed step (!cancelled()), the step timeouts
fit inside the job timeout (a timed-out step FAILS, so the next transfer still runs), and retro-backfill never
writes inside a protected window."""
import unittest
from pathlib import Path

import yaml

WF = Path(__file__).resolve().parents[1] / ".github" / "workflows"


def steps(name, job):
    d = yaml.safe_load((WF / name).read_text())
    j = d["jobs"][job]
    return j, j["steps"]


def idx(st, prefix):
    hits = [i for i, s in enumerate(st) if s.get("name", "").startswith(prefix)]
    assert len(hits) == 1, (prefix, hits)
    return hits[0]


class DailyForecast(unittest.TestCase):
    def setUp(self):
        self.job, self.st = steps("daily-forecast.yml", "daily-forecast")

    def test_transfer_after_generate_and_after_scoring(self):
        g, t1 = idx(self.st, "Generate daily forecasts"), idx(self.st, "Transfer forecasts to Postgres")
        sc, t2 = idx(self.st, "Score realized forecasts"), idx(self.st, "Transfer scores to Postgres")
        self.assertTrue(g < t1 < sc < t2)
        for i in (t1, t2):
            self.assertIn("!cancelled()", self.st[i]["if"])
            self.assertIn("bin/transfer_run_results.jl", self.st[i]["run"])
            self.assertIn("ENERGY_CONN_STR", self.st[i]["env"])

    def test_postgres_credentials_only_in_fill_and_transfers(self):
        with_conn = [s["name"] for s in self.st if "ENERGY_CONN_STR" in (s.get("env") or {})]
        self.assertEqual(with_conn, ["Fill run-local DuckDB (the job's only Postgres read)",
                                     "Transfer forecasts to Postgres", "Transfer scores to Postgres"])

    def test_step_timeouts_fit_inside_the_job(self):
        names = ("Fill run-local", "Generate daily forecasts", "Transfer forecasts", "Score realized", "Transfer scores")
        total = 0
        for n in names:
            t = self.st[idx(self.st, n)].get("timeout-minutes")
            self.assertIsInstance(t, int, n)
            total += t
        self.assertLess(total, self.job["timeout-minutes"])


class RetroBackfill(unittest.TestCase):
    def setUp(self):
        self.job, self.st = steps("retro-backfill.yml", "backfill")

    def test_transfer_after_reconstruct_and_after_scoring(self):
        r, t1 = idx(self.st, "Reconstruct"), idx(self.st, "Transfer reconstructed slices")
        sc, t2 = idx(self.st, "Score the reconstructed rows"), idx(self.st, "Transfer scores to Postgres")
        self.assertTrue(r < t1 < sc < t2)
        self.assertIn("!cancelled()", self.st[t1]["if"])
        self.assertIn("!cancelled()", self.st[t2]["if"])

    def test_every_transfer_is_window_guarded_first(self):
        for i in (idx(self.st, "Transfer reconstructed slices"), idx(self.st, "Transfer scores to Postgres")):
            run = self.st[i]["run"]
            self.assertIn("bin/blackout_window.py", run)
            self.assertLess(run.index("bin/blackout_window.py"), run.index("bin/transfer_run_results.jl"))

    def test_scoring_budget_leaves_room_for_the_scores_transfer(self):
        run = self.st[idx(self.st, "Score the reconstructed rows")]["run"]
        self.assertIn("end + 15 * 60", run)          # 10 min before the blackout (deadline = blackout - 25 min)
        self.assertNotIn("end + 20 * 60", run)
        self.assertNotIn("Each zone-day is upserted on its own, so a cut-off run is safe", run)


if __name__ == "__main__":
    unittest.main()
