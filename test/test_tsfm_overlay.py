"""Information-set invariants of bin/emit_tsfm_overlay.py; runs without the extract or model weights."""
import importlib.util
import json
import os
import tempfile
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

    def test_postsim_only_vintage_after_gate_refuses_and_missing_sim(self):
        # D's only lead-1 vintage was made at 10:20 UTC D-1 (after the 10:00 gate): refuse.
        with self.assertRaisesRegex(ValueError, "made by the gate"):
            ov.overlay(StubModel(), prices(), ZONES, "2026-11-15", "postsim",
                       sim=self.sim_frame(made_d="2026-11-14 10:20"), ctx_hours=500)
        with self.assertRaisesRegex(ValueError, "no lead-1 sim"):
            ov.sim_known(self.sim_frame()[lambda s: s.t < pd.Timestamp("2026-11-14 22:00")], "2026-11-15")

    def test_postsim_picks_latest_vintage_made_by_the_gate(self):
        # Gate bug (phase 3): D's lead-1 sim has vintages 09:13 (sim 50) and a 10:06 re-run (sim 9999,
        # observed 10:04-10:06 on 7 days in Oct 2026). The 10:06 one must be ignored, not refuse the run.
        sim = self.sim_frame(made_d="2026-11-14 09:13")
        rerun = sim[sim.made == pd.Timestamp("2026-11-14 09:13")].assign(sim=9999.0,
                                                                         made=pd.Timestamp("2026-11-14 10:06"))
        sim = pd.concat([sim, rerun], ignore_index=True)
        self.assertEqual(ov.gate_utc("2026-11-15"), pd.Timestamp("2026-11-14 10:00"))
        rows, issue = ov.sim_known(sim, "2026-11-15")
        self.assertEqual(issue, pd.Timestamp("2026-11-14 09:13"))
        self.assertFalse((rows.sim == 9999.0).any())
        m = StubModel()
        hourly, day = ov.overlay(m, prices(), ZONES, "2026-11-15", "postsim", sim=sim, ctx_hours=500)
        self.assertTrue((hourly.issue_utc == issue).all())
        self.assertFalse(hourly.after_gate.any())
        self.assertFalse(np.any(m.known == 9999.0))
        self.assertTrue(np.isfinite(m.known[:, 0, -24:]).all())
        # ... and write_db accepts it (no after-gate refusal).
        hourly["p_le0_logit"] = np.nan; hourly["p_le0"] = hourly.p_le0_tsfm
        day["p_any_le0_logit"] = np.nan; day["p_any_le0"] = day.p_any_le0_tsfm
        self.assertEqual(ov.write_db(hourly, day, "timestral-209m", cx=FakeConn()), 2 * 24 * 6 + 2 * 3)
        # A vintage exactly at the gate counts as in time.
        at_gate = pd.concat([sim, rerun.assign(sim=70.0, made=pd.Timestamp("2026-11-14 10:00"))], ignore_index=True)
        self.assertEqual(ov.sim_known(at_gate, "2026-11-15")[1], pd.Timestamp("2026-11-14 10:00"))

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

    def test_physics_homogeneous_one_zone_frame_is_writable(self):
        # One zone and no RES columns: the residual-load frame is a single homogeneous block, whose
        # to_numpy() is a read-only view under pandas copy-on-write. The delivery fallback (t-168 h
        # where D's load was published after the gate) must still be assignable (#436 review P3).
        load, res, fuel = self.phys_frames(d_load=5850.0, d_load_upd=pd.Timestamp("2026-11-14 10:30"))
        load = load[load.zone == "DE_LU"]
        res = res[res.zone == "DE_LU"]                                # empty: DE_LU reports no RES
        hours = ov.market_day_hours("2026-11-15")
        grid = pd.date_range(hours[0] - pd.Timedelta(hours=400), periods=400, freq="h")
        known, pub = ov.physics_covariates(load, res, fuel, ["DE_LU"], grid, hours, ov.gate_utc("2026-11-15"))
        self.assertEqual(known.shape, (1, 2, 424))
        np.testing.assert_allclose(known[0, 0, -24:], 1000.0)          # persistence, not the 10:30 revision
        self.assertEqual(pub, self.EARLY)

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


TAG = "cv44-backfill-2026-11"


class BackfillTest(unittest.TestCase):
    """#431 R2: backfill vintages from retro physics rows; never live, resumable, guarded."""
    DAYS = ["2026-11-14", "2026-11-15"]

    def retro_sim(self, skip_zone_on=None):
        """Retro rows: made = retro_of_utc (D-1 06:30), computed = the actual run (2026-11-17, after any gate)."""
        rows = []
        for d in ["2026-11-12", "2026-11-13"] + self.DAYS:
            retro_of = pd.Timestamp(d) - pd.Timedelta(days=1) + pd.Timedelta(hours=6, minutes=30)
            for h in ov.market_day_hours(d):
                for z in ZONES:
                    if d == skip_zone_on and z == "DE_LU":
                        continue
                    rows.append((z, h, 40.0, retro_of, pd.Timestamp("2026-11-17 01:00")))
        return pd.DataFrame(rows, columns=["zone", "t", "sim", "made", "computed"])

    def go(self, sim=None, done=lambda d, label: False, guard=lambda: None, load_sim=None):
        written = []
        res = ov.run_backfill(self.DAYS, TAG, "stub", ZONES,
                              load_sim=load_sim or (lambda d: sim if sim is not None else self.retro_sim()),
                              load_prices=lambda d: prices(), model=StubModel(),
                              emit=lambda h, dd, label: written.append((h, dd, label)), done=done,
                              guard=guard, timeout_s=60)
        return res, written

    def test_issue_time_is_retro_of_utc_and_rows_are_backfill_labelled(self):
        res, written = self.go()
        self.assertEqual([r["status"] for r in res], ["done", "done"])
        h, d, label = written[1]
        self.assertEqual(label, "stub@" + TAG)
        self.assertTrue((h.issue_utc == pd.Timestamp("2026-11-14 06:30")).all())    # not 2026-11-17 01:00
        self.assertFalse(h.after_gate.any())
        self.assertTrue((h.input_mode == ov.BACKFILL_MODE).all() and (d.input_mode == ov.BACKFILL_MODE).all())
        rows = ov.db_rows(h, d, label)
        self.assertTrue(all(r[6] == ov.BACKFILL_MODE and r[8] == label for r in rows))

    def test_resume_missing_physics_failure_and_guard(self):
        res, written = self.go(done=lambda d, label: d == "2026-11-14")
        self.assertEqual([r["status"] for r in res], ["exists", "done"])
        res, _ = self.go(sim=self.retro_sim(skip_zone_on="2026-11-15"))
        self.assertEqual([r["status"] for r in res], ["done", "no_physics"])
        self.assertIn("DE_LU", res[1]["detail"])

        def boom(d):
            if d == "2026-11-14":
                raise RuntimeError("db hiccup")
            return self.retro_sim()
        res, written = self.go(load_sim=boom)
        self.assertEqual([r["status"] for r in res], ["failed", "done"])   # non-fatal per day
        calls = iter([None, "inside a protected UTC window at 05:55"])
        res, written = self.go(guard=lambda: next(calls))
        self.assertEqual([r["status"] for r in res], ["done", "stopped"])
        self.assertEqual(len(written), 1)

    def test_blocked_windows_and_reservation(self):
        t = lambda hms: pd.Timestamp(f"2026-11-20 {hms}")
        for hm in ("06:00:00", "08:29:59", "10:30:00", "12:14:59"):
            self.assertTrue(ov.in_blocked_window(t(hm)), hm)
        for hm in ("05:59:59", "08:30:00", "10:29:59", "12:15:00", "23:00:00"):
            self.assertFalse(ov.in_blocked_window(t(hm)), hm)
        R = 900 + ov.GUARD_MARGIN_S                                   # the default day reservation
        self.assertTrue(ov.in_blocked_window(t("05:49:00"), R))      # review: 05:49 + 900 s -> 06:04
        self.assertTrue(ov.in_blocked_window(t("10:19:00"), R))      # review: 10:19 + 900 s -> 10:34
        self.assertFalse(ov.in_blocked_window(t("05:44:00"), R))     # ends 06:00:00, the window's start
        self.assertTrue(ov.in_blocked_window(t("05:44:01"), R))
        self.assertTrue(ov.in_blocked_window(t("23:59:00"), 7 * 3600))   # wraps into tomorrow 06:00

    def test_guard_admits_only_days_that_end_before_the_next_window(self):
        R = 900 + ov.GUARD_MARGIN_S
        windows = [(6 * 3600, 8 * 3600 + 1800), (10 * 3600 + 1800, 12 * 3600 + 900)]
        for sec in range(0, 86400, 37):                               # every 37 s of the day
            now = pd.Timestamp("2026-11-20") + pd.Timedelta(seconds=sec)
            ok = ov.backfill_guard(now, active=lambda: [], reserve_s=R, clock=lambda: now) is None
            end = sec + R
            hits = any(ws + sh <= sec < we + sh or sec < ws + sh < end for ws, we in windows for sh in (0, 86400))
            self.assertEqual(ok, not hits, f"{now:%H:%M:%S}")
            if ok:   # independent statement of the guarantee: outside every window, and the next opening
                     # (today's or tomorrow's) is no earlier than the end of the whole day budget
                self.assertFalse(any(ws <= sec < we for ws, we in windows))
                nxt = min(ws + sh for ws, _ in windows for sh in (0, 86400) if ws + sh > sec)
                self.assertLessEqual(sec + R, nxt, f"{now:%H:%M:%S}")
        # the GitHub checks take time: the clock is read again after them
        start = pd.Timestamp("2026-11-20 05:40:00")
        clock = iter([start, start + pd.Timedelta(minutes=5)])        # 05:40 ok, 05:45 + 960 s is not
        why = ov.backfill_guard(None, active=lambda: [], reserve_s=R, clock=lambda: next(clock))
        self.assertIn("after the workflow checks", why)
        self.assertIn("blocking", ov.backfill_guard(pd.Timestamp("2026-11-20 14:00"),
                                                     active=lambda: ["daily-forecast.yml"], reserve_s=R))

    def test_logistic_timeout_is_the_day_timeout(self):
        written = []

        def slow_logistic(d):
            raise ov.DayTimeout("day exceeded 60 s")
        res = ov.run_backfill(self.DAYS[:1], TAG, "stub", ZONES, load_sim=lambda d: self.retro_sim(),
                              load_prices=lambda d: prices(), model=StubModel(),
                              emit=lambda h, dd, label: written.append(label), done=lambda d, label: False,
                              logistic=slow_logistic, guard=lambda: None, timeout_s=60)
        self.assertEqual(res[0]["status"], "failed")
        self.assertIn("DayTimeout", res[0]["detail"])
        self.assertEqual(written, [])                                 # nothing emitted after the bound
        # an ordinary logistic failure still falls back to TSFM-only p_le0
        res = ov.run_backfill(self.DAYS[:1], TAG, "stub", ZONES, load_sim=lambda d: self.retro_sim(),
                              load_prices=lambda d: prices(), model=StubModel(),
                              emit=lambda h, dd, label: written.append(label), done=lambda d, label: False,
                              logistic=lambda d: 1 / 0, guard=lambda: None, timeout_s=60)
        self.assertEqual(res[0]["status"], "done")
        self.assertEqual(len(written), 1)

    def test_resume_check_runs_under_the_day_alarm(self):
        def slow_done(d, label):
            raise ov.DayTimeout("day exceeded 60 s")                  # e.g. a hung DB read
        res, written = self.go(done=slow_done)
        self.assertEqual([r["status"] for r in res], ["failed", "failed"])

    def test_live_json_reader_skips_retro_days(self):
        # review fixture: a reconstructed history day (is_retro, value 900) next to live days
        with tempfile.TemporaryDirectory() as dd:
            days = []
            for d, made, val, retro in (("2026-11-16", "2026-11-17T00:00:00Z", 900.0, True),
                                        ("2026-11-17", "2026-11-16T09:10:00Z", 50.0, False),
                                        ("2026-11-18", "2026-11-17T06:30:00Z", 60.0, False)):
                hrs = [h.isoformat() + "Z" for h in ov.market_day_hours(d)]
                day = dict(date=d, lead_days=1, input_mode="weather", prediction_made_utc=made,
                           hours=hrs, sim=[val] * len(hrs))
                if retro:
                    day.update(is_retro=True, reset_tag=TAG)
                days.append(day)
            Path(dd, "GR.json").write_text(json.dumps({"zone": "GR", "days": days}))
            sim = ov.sim_from_live_json(dd, ["GR"])
            self.assertNotIn(900.0, sim.sim.tolist())
            known, issue = ov.sim_known(sim, "2026-11-18")
            self.assertNotIn(900.0, known.sim.tolist())
            self.assertEqual(issue, pd.Timestamp("2026-11-17 06:30"))

    def test_live_vintages_cannot_be_relabelled_and_live_sim_never_feeds_backfill(self):
        hourly, day = ov.overlay(StubModel(), prices(), ZONES, "2026-11-15", "pregate0630")
        with self.assertRaises(ValueError):
            ov.as_backfill(hourly, day, TAG)
        # a backfill with live-shaped rows only (no retro rows for D) is "no_physics", never built from live
        res, written = self.go(load_sim=lambda d: self.retro_sim().iloc[0:0])
        self.assertEqual([r["status"] for r in res], ["no_physics", "no_physics"])
        self.assertEqual(written, [])
        self.assertIn("NOT coalesce(is_retro, false)", ov.SIM_SQL)
        self.assertIn("reset_tag = ?", ov.RETRO_SIM_SQL)


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
                         55.0 price_eur_mwh, TIMESTAMPTZ '2026-11-14 09:00+00' prediction_made_utc, 1 lead_days, 'weather' input_mode,
                         false is_retro, NULL::VARCHAR reset_tag, NULL::TIMESTAMPTZ retro_of_utc""")
            # retro rows of the same slice (#431 R1): computed later, must never reach the LIVE reader
            c.execute("""INSERT INTO simulations.forecast_prices VALUES
                         ('GR', TIMESTAMPTZ '2026-11-14 22:00+00', 77.0, TIMESTAMPTZ '2026-11-17 01:00+00', 1, 'weather',
                          true, 'cv44-backfill-2026-11', TIMESTAMPTZ '2026-11-14 06:30+00'),
                         ('GR', TIMESTAMPTZ '2026-11-14 22:00+00', 88.0, TIMESTAMPTZ '2026-11-17 02:00+00', 1, 'weather',
                          true, 'other-tag', TIMESTAMPTZ '2026-11-14 06:30+00')""")
            c.close()
            con = duckdb.connect()
            con.execute(f"ATTACH '{f}' AS pg (READ_ONLY)"); con.execute("USE pg")
            p = ov.prices_duckdb(con, "2026-11-15", ctx_hours=48)
            self.assertEqual(len(p), 2)                      # two hours of 15-min prices
            self.assertAlmostEqual(p.sort_values("t").price.iloc[0], 101.5)
            s = ov.sim_from_db(con, "2026-11-15")
            self.assertEqual(len(s), 1)                      # live row only: retro rows never read live
            self.assertEqual(s.sim.iloc[0], 55.0)
            self.assertEqual(s.t.iloc[0], pd.Timestamp("2026-11-14 22:00"))
            self.assertEqual(s.made.iloc[0], pd.Timestamp("2026-11-14 09:00"))
            r = ov.sim_from_retro(con, "cv44-backfill-2026-11", "2026-11-15")
            self.assertEqual(r.sim.tolist(), [77.0])         # that tag's retro row only: no live, no other tag
            self.assertEqual(r.made.iloc[0], pd.Timestamp("2026-11-14 06:30"))       # made = retro_of_utc
            self.assertEqual(r.computed.iloc[0], pd.Timestamp("2026-11-17 01:00"))
            with self.assertRaises(ValueError):
                ov.sim_from_retro(con, "", "2026-11-15")

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

    # ---- 2026-11-16 production failure: the postgres scanner returns timestamptz tz-aware ----------
    @staticmethod
    def _mini_store(path, ts):
        """Tiny entsoe store; `ts` = 'TIMESTAMP' (extract) or 'TIMESTAMPTZ' (live Postgres)."""
        import duckdb
        c = duckdb.connect(path)
        c.execute("SET TimeZone = 'UTC'; CREATE SCHEMA entsoe;")
        c.execute(f"""CREATE TABLE entsoe.energy_prices AS SELECT z map_code,
                      (TIMESTAMP '2026-11-10 00:00' + i * INTERVAL 15 MINUTE)::{ts} date_time_utc,
                      50.0 + (i % 96) price_currency_mwh, 'Day-ahead' contract_type, 'BZN' area_type_code,
                      'EUR' currency, '1' sequence, 'PT15M' resolution_code, 'x' instance_code,
                      (TIMESTAMP '2026-11-09 12:00' + (i // 96) * INTERVAL 1 DAY)::{ts} update_time_utc
                      FROM range(96 * 6) t(i), (VALUES ('GR'), ('DE_LU')) v(z)""")
        for table, col, kind in (("day_ahead_total_load_forecast", "total_load_mw", "NULL::VARCHAR"),
                                 ("generation_forecasts_for_wind_and_solar", "day_ahead_generation_forecast_mw",
                                  "'Solar'")):
            c.execute(f"""CREATE TABLE entsoe.{table} AS SELECT z area_map_code, 'BZN' area_type_code,
                          (TIMESTAMP '2026-11-10 00:00' + i * INTERVAL 1 HOUR)::{ts} date_time_utc,
                          {kind} production_type, 'PT60M' resolution_code, 1000.0 + i {col},
                          (TIMESTAMP '2026-11-09 05:00' + (i // 24) * INTERVAL 1 DAY)::{ts} update_time_utc
                          FROM range(24 * 6) t(i), (VALUES ('GR'), ('DE_LU')) v(z)""")
        c.close()

    def test_tz_aware_store_matches_naive_extract(self):
        """Live Postgres (timestamptz, tz-aware frames) and the extract (naive UTC) must give the
        same prices, context and collapse inputs. Before the fix build_context raised
        'Invalid comparison between dtype=datetime64[us, UTC] and Timestamp'."""
        import duckdb, tempfile, importlib.util
        spec = importlib.util.spec_from_file_location(
            "collapse_probability", Path(__file__).resolve().parents[1] / "bin" / "collapse_probability.py")
        cp = importlib.util.module_from_spec(spec); spec.loader.exec_module(cp)
        with tempfile.TemporaryDirectory() as tmp:
            out = {}
            for ts in ("TIMESTAMP", "TIMESTAMPTZ"):
                f = os.path.join(tmp, f"{ts}.duckdb")
                self._mini_store(f, ts)
                con = duckdb.connect()
                # the session open_store('postgres') sets; a non-UTC host zone must not leak in
                con.execute("SET TimeZone = 'UTC'")
                con.execute(f"ATTACH '{f}' AS pg (READ_ONLY)"); con.execute("USE pg")
                p = ov.prices_duckdb(con, "2026-11-15", ctx_hours=72)
                self.assertFalse(isinstance(p.t.dtype, pd.DatetimeTZDtype))
                ctx, _, _ = ov.build_context(p, ZONES, "2026-11-15", ctx_hours=72)
                act = cp.hourly_actuals(con, "2026-11-10", "2026-11-16")
                fc = cp.hourly_forecasts(con, "2026-11-10", "2026-11-16")
                for frame in (act, fc):
                    self.assertFalse(any(isinstance(frame[c].dtype, pd.DatetimeTZDtype) for c in frame))
                out[ts] = (p.sort_values(["zone", "t"]).reset_index(drop=True), ctx,
                           act.sort_values(["zone", "t"]).reset_index(drop=True),
                           fc.sort_values(["zone", "t"]).reset_index(drop=True))
                con.close()
            naive, aware = out["TIMESTAMP"], out["TIMESTAMPTZ"]
            pd.testing.assert_frame_equal(naive[0], aware[0])
            np.testing.assert_array_equal(naive[1], aware[1])
            self.assertTrue(np.isfinite(naive[1][:, -24:]).all())          # D-1 is in the context
            pd.testing.assert_frame_equal(naive[2], aware[2])
            pd.testing.assert_frame_equal(naive[3], aware[3])                # incl. the pre-06:30 snapshots
            self.assertTrue(naive[3].load_pre0630.notna().any())

    def test_naive_utc_converts_only_aware_columns(self):
        df = pd.DataFrame({"a": pd.to_datetime(["2026-11-14 22:00"]).tz_localize("UTC").tz_convert("Europe/Athens"),
                           "b": pd.to_datetime(["2026-11-14 22:00"]), "v": [1.0]})
        got = ov.naive_utc(df.copy())
        self.assertEqual(got.a.iloc[0], pd.Timestamp("2026-11-14 22:00"))
        self.assertEqual(got.b.iloc[0], pd.Timestamp("2026-11-14 22:00"))

    @unittest.skipUnless(os.environ.get("OVERLAY_TEST_PG"), "set OVERLAY_TEST_PG=<libpq conn> for the Postgres test")
    def test_postgres_write_is_utc_whatever_the_server_zone(self):
        """Rows must land as UTC instants even when the session TimeZone is not UTC: db_rows writes
        explicit '+00' offsets (guard for the 2026-11-16 tz audit)."""
        cx, cur = self._pg()
        cur.execute("SET TIME ZONE 'Europe/Athens'"); cx.commit()
        ov.write_db(*self._vintage("postsim", "2026-11-14 09:13", 60), "timestral-209m", cx=cx)
        cur.execute("""SELECT DISTINCT issue_utc AT TIME ZONE 'UTC' FROM simulations.tsfm_overlay""")
        self.assertEqual([str(r[0]) for r in cur.fetchall()], ["2026-11-14 09:13:00"])
        cur.execute("""SELECT min(date_time_utc AT TIME ZONE 'UTC') FROM simulations.tsfm_overlay WHERE level='hour'""")
        self.assertEqual(str(cur.fetchone()[0]), "2026-11-14 22:00:00")
        cx.close()


if __name__ == "__main__":
    unittest.main()
