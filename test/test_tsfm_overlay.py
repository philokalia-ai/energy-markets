"""Information-set invariants of bin/emit_tsfm_overlay.py; runs without the extract or model weights."""
import importlib.util
import os
import unittest
from pathlib import Path

import numpy as np
import pandas as pd

spec = importlib.util.spec_from_file_location(
    "emit_tsfm_overlay", Path(__file__).resolve().parents[1] / "bin" / "emit_tsfm_overlay.py")
ov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ov)

ZONES = ["GR", "DE_LU"]
LEVELS = np.array([0.01, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5,
                   0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.99])


class StubModel:
    """Quantiles = last context value (+ covariate mean if given) + fixed spread; records inputs."""
    name = "stub"

    def forecast(self, ctx, H, known=None):
        self.ctx, self.known = ctx, known
        last = np.nan_to_num(ctx[:, -1])
        if known is not None:
            last = last + np.nan_to_num(np.nanmean(known[:, 0, -H:], axis=1))
        spread = (LEVELS - 0.5) * 100
        return np.repeat((last[:, None] + spread[None, :])[:, None, :], H, axis=1), LEVELS


def prices(start="2026-01-01", end="2026-11-20", value=100.0):
    t = pd.date_range(start, end, freq="h", inclusive="left")
    return pd.concat([pd.DataFrame({"zone": z, "t": t, "price": value}) for z in ZONES], ignore_index=True)


class InformationSetTest(unittest.TestCase):
    def test_market_day_hours_dst(self):
        h = ov.market_day_hours("2026-10-25")
        self.assertEqual(len(h), 25)
        self.assertEqual(h[0], pd.Timestamp("2026-10-24 21:00"))
        self.assertEqual(len(ov.market_day_hours("2026-11-15")), 24)
        self.assertEqual(ov.market_day_hours("2026-11-15")[0], pd.Timestamp("2026-11-14 22:00"))

    def test_context_excludes_delivery_day_and_includes_d1(self):
        p = prices()
        ctx, cutoff, grid = ov.build_context(p, ZONES, "2026-11-15", ctx_hours=500)
        self.assertEqual(cutoff, pd.Timestamp("2026-11-14 22:00"))
        self.assertTrue(grid[-1] < cutoff)
        # Changing prices at/after the start of Athens D (incl. 22:00-23:59 UTC on D-1) changes nothing.
        p2 = p.copy(); p2.loc[p2.t >= cutoff, "price"] = -999.0
        np.testing.assert_array_equal(ctx, ov.build_context(p2, ZONES, "2026-11-15", ctx_hours=500)[0])
        # D-1 (public from the D-2 auction) is in the context.
        p3 = p.copy(); p3.loc[(p3.t >= cutoff - pd.Timedelta(hours=24)) & (p3.t < cutoff), "price"] = -999.0
        self.assertFalse(np.array_equal(ctx, ov.build_context(p3, ZONES, "2026-11-15", ctx_hours=500)[0]))

    def test_pregate_mode_never_reads_sim_and_issues_0630(self):
        m = StubModel()
        bad_sim = pd.DataFrame({"zone": ["GR"], "t": [pd.Timestamp("2026-11-15")], "sim": [1e6],
                                "made": [pd.Timestamp("2026-11-14 09:00")]})
        hourly, day = ov.overlay(m, prices(), ZONES, "2026-11-15", "pregate0630", sim=bad_sim, ctx_hours=500)
        self.assertIsNone(m.known)
        self.assertTrue((hourly.issue_utc == pd.Timestamp("2026-11-14 06:30")).all())
        self.assertTrue((hourly.input_mode == "pregate0630").all())
        self.assertEqual(len(hourly), 2 * 24)
        self.assertTrue((hourly.context_end_utc <= hourly.t_utc.min()).all())

    def sim_frame(self, made_d="2026-11-14 09:13", late_rerun=None):
        rows = []
        for d, made in (("2026-11-13", "2026-11-12 09:05"), ("2026-11-14", "2026-11-13 09:10"), ("2026-11-15", made_d)):
            for h in ov.market_day_hours(d):
                for z in ZONES:
                    rows.append((z, h, 50.0, pd.Timestamp(made)))
        if late_rerun:  # a later re-run of D-1's sim with a different value: must be ignored
            for h in ov.market_day_hours("2026-11-14"):
                rows.append(("GR", h, 9999.0, pd.Timestamp(late_rerun)))
        return pd.DataFrame(rows, columns=["zone", "t", "sim", "made"])

    def test_postsim_issue_is_latest_made_and_later_rows_excluded(self):
        sim = self.sim_frame(late_rerun="2026-11-14 15:00")
        rows, issue = ov.sim_known(sim, "2026-11-15")
        self.assertEqual(issue, pd.Timestamp("2026-11-14 09:13"))
        self.assertTrue((rows.made <= issue).all())
        self.assertFalse((rows.sim == 9999.0).any())
        m = StubModel()
        hourly, _ = ov.overlay(m, prices(), ZONES, "2026-11-15", "postsim", sim=sim, ctx_hours=500)
        self.assertTrue((hourly.input_mode == "postsim").all())
        self.assertTrue((hourly.issue_utc == issue).all())
        self.assertFalse(hourly.after_gate.any())
        self.assertEqual(m.known.shape, (2, 1, 500 + 24))
        self.assertFalse(np.any(m.known == 9999.0))

    def test_postsim_after_gate_flag_and_missing_sim(self):
        hourly, _ = ov.overlay(StubModel(), prices(), ZONES, "2026-11-15", "postsim",
                               sim=self.sim_frame(made_d="2026-11-14 10:20"), ctx_hours=500)
        self.assertTrue(hourly.after_gate.all())
        with self.assertRaises(ValueError):
            ov.sim_known(self.sim_frame()[lambda s: s.t < pd.Timestamp("2026-11-14 22:00")], "2026-11-15")

    def test_probabilities_and_blend(self):
        q = np.linspace(-10, 10, 21)[None]          # symmetric around 0 -> P(<=0) = median level
        self.assertAlmostEqual(ov.p_le(q, LEVELS, 0.0).item(), 0.5)
        self.assertAlmostEqual(ov.p_le(np.full((1, 21), 50.0) + np.arange(21), LEVELS, 0.0).item(), 0.005)
        self.assertAlmostEqual(ov.p_le(np.full((1, 21), -50.0) + np.arange(21), LEVELS, 0.0).item(), 0.995)
        np.testing.assert_allclose(ov.blend([0.2, 0.4], [0.6, np.nan]), [0.4, 0.4])

    def test_day_any_is_max_hour_and_logistic_join(self):
        hourly, day = ov.overlay(StubModel(), prices(value=10.0), ZONES, "2026-11-15", "pregate0630", ctx_hours=500)
        np.testing.assert_allclose(day.set_index("zone").p_any_le0_tsfm.sort_index(),
                                   hourly.groupby("zone").p_le0_tsfm.max().sort_index())
        lh = hourly[["zone", "t_utc"]].rename(columns={"t_utc": "t"}).assign(collapse_probability=0.9)
        ld = pd.DataFrame({"zone": ZONES, "market_date": ["2026-11-15"] * 2, "any_hour_collapse_probability": [0.5, 0.5]})
        h2, d2 = ov.add_logistic(hourly, day, lh, ld)
        np.testing.assert_allclose(h2.p_le0, 0.5 * (h2.p_le0_tsfm + 0.9))
        np.testing.assert_allclose(d2.p_any_le0, 0.5 * (d2.p_any_le0_tsfm + 0.5))
        h3, d3 = ov.add_logistic(hourly, day)
        np.testing.assert_allclose(h3.p_le0, h3.p_le0_tsfm)


class FakeCursor:
    def __init__(self, log): self.log = log
    def execute(self, sql, *a): self.log.append(("execute", sql))
    def executemany(self, sql, rows): self.log.append(("executemany", sql, list(rows)))


class FakeConn:
    def __init__(self): self.log, self.commits = [], 0
    def cursor(self): return FakeCursor(self.log)
    def commit(self): self.commits += 1


def overlay_rows(day="2026-11-15"):
    hourly, d = ov.overlay(StubModel(), prices(value=10.0), ZONES, day, "pregate0630", ctx_hours=500)
    return ov.add_logistic(hourly, d)


class ProductionPathTest(unittest.TestCase):
    """The --write path: arm switch, row shaping, after-gate guard, store SQL resolution."""

    def test_resolve_arm(self):
        self.assertEqual(ov.resolve_arm({}), "timestral-209m")
        self.assertEqual(ov.resolve_arm({"TSFM_MODEL": "chronos2"}), "chronos2")
        self.assertEqual(ov.resolve_arm({"TSFM_ARM": "timestral-28m", "TSFM_MODEL": "chronos2"}), "timestral-28m")
        with self.assertRaises(SystemExit):
            ov.resolve_arm({"TSFM_ARM": "nope"})

    def test_db_rows_published_names_and_not_null_day_rows(self):
        hourly, day = overlay_rows()
        lines, probs = ov.db_rows(hourly, day, "timestral-209m")
        self.assertEqual(sorted({r[2] for r in lines}), ["tsfm", "tsfm_q10", "tsfm_q90"])
        self.assertEqual(len(lines), 3 * len(hourly))
        self.assertTrue(all(r[4] == ov.LINES_VERSION for r in lines))
        day_rows = [r for r in probs if r[3] == "day"]
        self.assertEqual(len(day_rows), 3 * len(day))
        # day rows sit at the start of the Athens market day (2026-11-14 22:00 UTC), never NULL
        self.assertTrue(all(r[2] == "2026-11-14T22:00:00+00" for r in day_rows))
        self.assertTrue(all(r[2] is not None and r[8] == "timestral-209m" for r in probs))
        self.assertTrue(all(r[5] is None for r in probs if r[4].endswith("_logit")))  # no logistic: NULL, not NaN

    def test_write_db_ddl_first_one_commit_and_after_gate_guard(self):
        hourly, day = overlay_rows()
        cx = FakeConn()
        n_lines, n_probs = ov.write_db(hourly, day, "timestral-209m", cx=cx)
        self.assertEqual(cx.log[0][0], "execute")
        self.assertIn("CREATE TABLE IF NOT EXISTS simulations.overlay_probabilities", cx.log[0][1])
        self.assertIn("date_time_utc  timestamptz NOT NULL", cx.log[0][1])
        self.assertEqual([e[0] for e in cx.log[1:]], ["executemany", "executemany"])
        self.assertEqual(cx.commits, 1)
        late = hourly.assign(after_gate=True)
        with self.assertRaises(SystemExit):
            ov.write_db(late, day, "timestral-209m", cx=FakeConn())
        ov.write_db(late, day, "timestral-209m", cx=FakeConn(), allow_after_gate=True)

    def test_store_sql_resolves_under_use_catalog(self):
        """--backend postgres runs the extract SQL against `USE pg`; check the same resolution with a
        DuckDB file attached as `pg` (no Postgres needed)."""
        import duckdb, tempfile, os
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "mini.duckdb")
            c = duckdb.connect(f)
            c.execute("CREATE SCHEMA entsoe; CREATE SCHEMA simulations;")
            c.execute("""CREATE TABLE entsoe.energy_prices AS SELECT 'GR' map_code, TIMESTAMP '2026-11-14 10:00' + i * INTERVAL 15 MINUTE date_time_utc,
                         100.0 + i price_currency_mwh, 'Day-ahead' contract_type, 'BZN' area_type_code, '1' sequence,
                         TIMESTAMP '2026-11-13 12:00' update_time_utc FROM range(8) t(i)""")
            c.execute("""CREATE TABLE simulations.forecast_prices AS SELECT 'GR' bidding_zone, TIMESTAMPTZ '2026-11-14 22:00+00' date_time_utc,
                         55.0 price_eur_mwh, TIMESTAMPTZ '2026-11-14 09:00+00' prediction_made_utc, 1 lead_days, 'weather' input_mode""")
            c.close()
            con = duckdb.connect()
            con.execute(f"ATTACH '{f}' AS pg (READ_ONLY)"); con.execute("USE pg")
            p = ov.prices_duckdb(con, "2026-11-15", ctx_hours=48)
            self.assertEqual(len(p), 2)                      # two hours of 15-min prices
            self.assertAlmostEqual(p.sort_values("t").price.iloc[0], 101.5)
            s = ov.sim_from_db(con, "2026-11-15")
            self.assertEqual(s.t.iloc[0], pd.Timestamp("2026-11-14 22:00"))
            self.assertEqual(s.made.iloc[0], pd.Timestamp("2026-11-14 09:00"))

    @unittest.skipUnless(os.environ.get("OVERLAY_TEST_PG"), "set OVERLAY_TEST_PG=<libpq conn> for the Postgres test")
    def test_postgres_upsert_idempotent(self):
        import psycopg2
        cx = psycopg2.connect(os.environ["OVERLAY_TEST_PG"]); cur = cx.cursor()
        cur.execute("""CREATE SCHEMA IF NOT EXISTS simulations;
            DROP TABLE IF EXISTS simulations.overlay_probabilities;
            CREATE TABLE IF NOT EXISTS simulations.model_lines (bidding_zone text, date_time_utc timestamptz,
              model text, price_eur_mwh double precision, code_version int, generated_at timestamptz DEFAULT now(),
              UNIQUE (bidding_zone, date_time_utc, model, code_version));
            DELETE FROM simulations.model_lines WHERE model LIKE 'tsfm%';""")
        cx.commit()
        hourly, day = overlay_rows()
        for _ in range(2):                                     # second run must upsert, not duplicate
            ov.write_db(hourly, day, "timestral-209m", cx=cx)
        cur.execute("SELECT count(*) FROM simulations.model_lines WHERE model LIKE 'tsfm%'")
        self.assertEqual(cur.fetchone()[0], 3 * len(hourly))
        cur.execute("SELECT level, count(*) FROM simulations.overlay_probabilities GROUP BY 1 ORDER BY 1")
        self.assertEqual(cur.fetchall(), [("day", 3 * len(day)), ("hour", 3 * len(hourly))])
        cx.close()


if __name__ == "__main__":
    unittest.main()
