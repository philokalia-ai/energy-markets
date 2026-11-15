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

    D_START = pd.Timestamp("2026-11-14 22:00")      # Athens day 2026-11-15 in UTC
    EARLY = pd.Timestamp("2026-11-14 08:00")        # published before the sim issue (09:13)

    def phys_frames(self, d_load=1100.0, d_load_upd=None, d_wind_upd=None, d_wind=100.0):
        """Raw quarter-hourly rows with publication stamps. History load 1000, delivery-day load 1100;
        GR wind 100 + solar 50 (DE_LU reports no RES). Delivery-day rows may carry another stamp."""
        t = pd.date_range("2026-08-01", "2026-11-16", freq="15min")
        D = (t >= self.D_START) & (t < self.D_START + pd.Timedelta(hours=24))
        load = pd.concat([pd.DataFrame({"zone": z, "t": t, "load_fc": np.where(D, d_load, 1000.0),
                                        "upd": self.EARLY}) for z in ZONES], ignore_index=True)
        if d_load_upd is not None:
            load.loc[load.t.isin(t[D]), "upd"] = d_load_upd
        res = pd.concat([pd.DataFrame({"zone": "GR", "t": t, "pt": "Wind Onshore",
                                       "mw": np.where(D, d_wind, 100.0), "upd": self.EARLY}),
                         pd.DataFrame({"zone": "GR", "t": t, "pt": "Solar", "mw": 50.0, "upd": self.EARLY})],
                        ignore_index=True)
        if d_wind_upd is not None:
            res.loc[res.t.isin(t[D]) & (res.pt == "Wind Onshore"), "upd"] = d_wind_upd
        days = pd.date_range("2026-08-01", "2026-11-14", freq="D")
        fuel = pd.concat([pd.DataFrame({"fuel": "ttf", "date": days.date, "close": 30.0}),
                          pd.DataFrame({"fuel": "eua", "date": days.date, "close": 70.0})])
        # the D-1 (2026-11-14) close is published after a D-1 morning issue: must not be used for D
        fuel.loc[(fuel.fuel == "ttf") & (fuel.date == pd.Timestamp("2026-11-14").date()), "close"] = 1e6
        return load, res, fuel

    def run_phys(self, **kw):
        m = StubModel(); m.physics = True
        hourly, _ = ov.overlay(m, prices(), ZONES, "2026-11-15", "postsim", sim=self.sim_frame(),
                               phys=self.phys_frames(**kw))
        return m, hourly

    def test_physics_arm_covariates_and_postsim_only(self):
        m = StubModel(); m.physics = True
        with self.assertRaises(ValueError):
            ov.overlay(m, prices(), ZONES, "2026-11-15", "pregate0630", phys=self.phys_frames())
        m, hourly = self.run_phys()
        self.assertEqual(m.ctx.shape, (2, ov.PHYS_CTX_HOURS))         # context capped at 2048 h
        self.assertEqual(m.known.shape, (2, 3, ov.PHYS_CTX_HOURS + 24))
        H = 24
        np.testing.assert_allclose(m.known[0, 1, -H:], 950.0)        # GR: 1100 - 100 - 50
        np.testing.assert_allclose(m.known[1, 1, -H:], 1100.0)       # DE_LU: no RES -> load only
        np.testing.assert_allclose(m.known[0, 1, :-H], 850.0)        # history 1000 - 150
        np.testing.assert_allclose(m.known[:, 2, -H:], 30 / 0.5 + 0.202 / 0.5 * 70 + 2)  # D-2 closes
        self.assertTrue(np.all(m.known[:, 2, :] < 1e5))              # D-1 close never enters
        self.assertTrue((hourly.input_mode == "postsim").all())
        self.assertTrue((hourly.issue_utc == pd.Timestamp("2026-11-14 09:13")).all())  # all inputs earlier
        self.assertFalse(hourly.after_gate.any())

    def test_physics_load_published_after_gate_never_enters(self):
        # The store holds only a 10:30 revision (5,850 MW) of D's load: it must not enter, D falls
        # back to t-168 h, and the stamp stays at the sim issue (the reviewer's counterexample).
        m, hourly = self.run_phys(d_load=5850.0, d_load_upd=pd.Timestamp("2026-11-14 10:30"))
        np.testing.assert_allclose(m.known[0, 1, -24:], 850.0)       # persistence, GR
        np.testing.assert_allclose(m.known[1, 1, -24:], 1000.0)      # persistence, DE_LU
        self.assertFalse(np.any(np.isin(m.known[:, 1, :], [5850.0, 5700.0])))
        self.assertTrue((hourly.issue_utc == pd.Timestamp("2026-11-14 09:13")).all())
        self.assertFalse(hourly.after_gate.any())
        # an unstamped row is unverifiable and is treated the same way
        m2, _ = self.run_phys(d_load=5850.0, d_load_upd=pd.NaT)
        np.testing.assert_allclose(m2.known[:, 1, -24:], m.known[:, 1, -24:])

    def test_physics_res_published_after_gate_never_enters(self):
        # GR wind for D only as a 10:30 revision: neither its value nor "0 MW wind" may be used.
        m, hourly = self.run_phys(d_wind=1e5, d_wind_upd=pd.Timestamp("2026-11-14 10:30"))
        np.testing.assert_allclose(m.known[0, 1, -24:], 850.0)       # persistence, not 1100 - 0 - 50
        np.testing.assert_allclose(m.known[1, 1, -24:], 1100.0)      # DE_LU unaffected
        self.assertTrue(np.all(np.abs(m.known[0, 1, :]) < 5e4))
        self.assertTrue((hourly.issue_utc == pd.Timestamp("2026-11-14 09:13")).all())

    def test_physics_pre_gate_revision_enters_and_moves_the_stamp(self):
        # A 09:40 load revision (after the 09:13 sim, before the 10:00 gate) is used, and the vintage
        # is stamped 09:40 so its information set covers every input actually read.
        m, hourly = self.run_phys(d_load=1200.0, d_load_upd=pd.Timestamp("2026-11-14 09:40"))
        np.testing.assert_allclose(m.known[0, 1, -24:], 1050.0)
        self.assertTrue((hourly.issue_utc == pd.Timestamp("2026-11-14 09:40")).all())
        self.assertTrue((hourly.sim_made_utc == pd.Timestamp("2026-11-14 09:13")).all())
        self.assertFalse(hourly.after_gate.any())

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

    def test_db_rows_one_vintage_lines_and_probabilities(self):
        hourly, day = overlay_rows()
        rows = ov.db_rows(hourly, day, "timestral-209m")
        hour_q = {r[4] for r in rows if r[3] == "hour"}
        self.assertEqual(hour_q, set(ov.HOUR_QUANTITIES))           # lines live with the probabilities
        self.assertEqual(len(rows), len(ov.HOUR_QUANTITIES) * len(hourly) + len(ov.DAY_QUANTITIES) * len(day))
        self.assertEqual({(r[6], r[7], r[8]) for r in rows},        # every row carries the same vintage
                         {("pregate0630", "2026-11-14T06:30:00+00", "timestral-209m")})
        day_rows = [r for r in rows if r[3] == "day"]
        self.assertTrue(all(r[2] == "2026-11-14T22:00:00+00" for r in day_rows))   # market-day start, never NULL
        self.assertTrue(all(r[5] is None for r in rows if r[4].endswith("_logit")))  # no logistic: NULL, not NaN

    def test_write_db_ddl_first_one_commit_and_after_gate_guard(self):
        hourly, day = overlay_rows()
        cx = FakeConn()
        ov.write_db(hourly, day, "timestral-209m", cx=cx)
        self.assertEqual(cx.log[0][0], "execute")
        self.assertIn("CREATE TABLE IF NOT EXISTS simulations.tsfm_overlay", cx.log[0][1])
        self.assertIn("date_time_utc  timestamptz NOT NULL", cx.log[0][1])
        self.assertEqual([e[0] for e in cx.log[1:]], ["executemany"])
        self.assertIn("WHERE simulations.tsfm_overlay.issue_utc <= EXCLUDED.issue_utc", cx.log[1][1])
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

    def _pg(self):
        import psycopg2
        cx = psycopg2.connect(os.environ["OVERLAY_TEST_PG"]); cur = cx.cursor()
        cur.execute("CREATE SCHEMA IF NOT EXISTS simulations; DROP TABLE IF EXISTS simulations.tsfm_overlay;")
        cx.commit()
        return cx, cur

    @staticmethod
    def _vintage(mode, issue, median):
        hourly, day = overlay_rows()
        hourly = hourly.assign(input_mode=mode, issue_utc=pd.Timestamp(issue), tsfm_median=float(median),
                               tsfm_q10=float(median) - 5, tsfm_q90=float(median) + 5)
        return hourly, day.assign(input_mode=mode, issue_utc=pd.Timestamp(issue))

    @unittest.skipUnless(os.environ.get("OVERLAY_TEST_PG"), "set OVERLAY_TEST_PG=<libpq conn> for the Postgres test")
    def test_postgres_upsert_idempotent(self):
        cx, cur = self._pg()
        hourly, day = overlay_rows()
        for _ in range(2):                                     # second run must upsert, not duplicate
            ov.write_db(hourly, day, "timestral-209m", cx=cx)
        cur.execute("SELECT level, count(*) FROM simulations.tsfm_overlay GROUP BY 1 ORDER BY 1")
        self.assertEqual(cur.fetchall(), [("day", len(ov.DAY_QUANTITIES) * len(day)),
                                          ("hour", len(ov.HOUR_QUANTITIES) * len(hourly))])
        cx.close()

    @unittest.skipUnless(os.environ.get("OVERLAY_TEST_PG"), "set OVERLAY_TEST_PG=<libpq conn> for the Postgres test")
    def test_postgres_newer_then_older_writes(self):
        """Review P2 repro: post-sim 09:13 (median 60), then a delayed pre-gate 06:30 (median 10).
        The post-sim vintage must survive intact, and a same-key older re-issue must be rejected."""
        cx, cur = self._pg()
        ov.write_db(*self._vintage("postsim", "2026-11-14 09:13", 60), "timestral-209m", cx=cx)
        ov.write_db(*self._vintage("pregate0630", "2026-11-14 06:30", 10), "timestral-209m", cx=cx)
        cur.execute("""SELECT input_mode, issue_utc AT TIME ZONE 'UTC', avg(value) FROM simulations.tsfm_overlay
                       WHERE quantity = 'tsfm_median' GROUP BY 1, 2 ORDER BY 1""")
        got = {m: (str(i), v) for m, i, v in cur.fetchall()}
        self.assertEqual(got["postsim"], ("2026-11-14 09:13:00", 60.0))      # newer vintage untouched
        self.assertEqual(got["pregate0630"], ("2026-11-14 06:30:00", 10.0))  # kept as its own vintage
        # same vintage key, OLDER issue (a delayed retry): rejected row by row
        ov.write_db(*self._vintage("postsim", "2026-11-14 08:00", 99), "timestral-209m", cx=cx)
        cur.execute("""SELECT DISTINCT issue_utc AT TIME ZONE 'UTC', value FROM simulations.tsfm_overlay
                       WHERE quantity = 'tsfm_median' AND input_mode = 'postsim'""")
        self.assertEqual([(str(i), v) for i, v in cur.fetchall()], [("2026-11-14 09:13:00", 60.0)])
        # same key, NEWER issue: accepted
        ov.write_db(*self._vintage("postsim", "2026-11-14 09:40", 70), "timestral-209m", cx=cx)
        cur.execute("""SELECT DISTINCT value FROM simulations.tsfm_overlay
                       WHERE quantity = 'tsfm_median' AND input_mode = 'postsim'""")
        self.assertEqual(cur.fetchall(), [(70.0,)])
        cx.close()

if __name__ == "__main__":
    unittest.main()
