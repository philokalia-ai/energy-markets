"""Offline orchestration tests: no Julia, weather, database or GitHub required."""
import asyncio
from datetime import date, datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("retro_parallel", Path(__file__).resolve().parents[1] / "bin/run_retro_backfill.py")
retro = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(retro)


def config():
    return dict(EUPHEMIA_RETRO_ALONGSIDE="1", EUPHEMIA_FORECAST_RESET_TAG="fixture",
                INPUT_MODE="weather", MAX_LEAD_DAYS="1",
                EUPHEMIA_FORECAST_RETRO_START="2026-09-14",
                EUPHEMIA_FORECAST_RETRO_ASOF="2026-11-15",
                EUPHEMIA_RETRO_CHUNK_DAYS="14",
                EUPHEMIA_RETRO_DEADLINE_UTC="2026-11-17T05:30:00")


class PlanTest(unittest.TestCase):
    def test_exact_partition(self):
        chunks, deadline = retro.parallel_config(config(), 2, range(8), date(2026, 11, 17))
        days = [s + timedelta(days=i) for s, e in chunks for i in range((e-s).days + 1)]
        self.assertEqual(len(days), 63)
        self.assertEqual(len(set(days)), 63)
        self.assertEqual(days, [date(2026, 9, 14) + timedelta(days=i) for i in range(63)])
        self.assertEqual(len(chunks), 5)
        self.assertEqual(deadline.utcoffset(), timedelta(0))

    def test_fail_closed(self):
        for key, value in (("EUPHEMIA_RETRO_ALONGSIDE", "0"),
                           ("EUPHEMIA_RETRO_SUPERSEDE", "true"),
                           ("EUPHEMIA_FORECAST_RESET_TAG", ""),
                           ("INPUT_MODE", "entsoe"), ("MAX_LEAD_DAYS", "2"),
                           ("EUPHEMIA_FORECAST_RETRO_START", "2027-01-01"),
                           ("EUPHEMIA_FORECAST_RETRO_ASOF", "2026-11-17"),
                           ("EUPHEMIA_RETRO_CHUNK_DAYS", "0"),
                           ("EUPHEMIA_RETRO_DEADLINE_UTC", "")):
            with self.subTest(key=key), self.assertRaises((ValueError, KeyError)):
                retro.parallel_config(config() | {key: value}, 2, range(8), date(2026, 11, 17))
        with self.assertRaises(ValueError):
            retro.parallel_config(config(), 2, range(7), date(2026, 11, 17))
        with self.assertRaises(ValueError):
            retro.parallel_config(config(), 3, range(80), date(2026, 11, 17))

    def test_serial_is_original_exec(self):
        with patch.object(sys, "argv", ["run_retro_backfill.py"]), patch.object(retro.os, "chdir"), patch.object(retro.os, "execvpe", side_effect=SystemExit) as execute:
            with self.assertRaises(SystemExit):
                retro.main()
            self.assertEqual(execute.call_args.args[:2], ("julia", ["julia", "--project=.", "bin/daily_forecast.jl"]))
            self.assertIs(execute.call_args.args[2], os.environ)

    def test_only_runtime_and_slice_environment_changes(self):
        original = config() | {"MODEL_SETTING": "preserve", "EUPHEMIA_PG_POOL": "5"}
        actual = retro.worker_env(original, date(2026, 9, 15), date(2026, 9, 16))
        for key in ("EUPHEMIA_FORECAST_RESET_TAG", "EUPHEMIA_RETRO_DEADLINE_UTC", "MODEL_SETTING", "EUPHEMIA_RETRO_CHUNK_DAYS"):
            self.assertEqual(actual[key], original[key])
        self.assertEqual(actual["JULIA_NUM_THREADS"], "4")
        self.assertEqual(actual["EUPHEMIA_PG_POOL"], "2")
        self.assertEqual(original["EUPHEMIA_FORECAST_RETRO_START"], "2026-09-14")


class ProcessTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, **config(), PERF_TEST_DIR=self.tmp.name)
        self.cpus = sorted(os.sched_getaffinity(0))[:8]
        if len(self.cpus) < 8:
            self.skipTest("process tests need eight allowed CPUs")
        self.deadline = datetime.now(timezone.utc) + timedelta(hours=1)
        self.chunks = list(retro.day_chunks(date(2026, 9, 14), date(2026, 9, 17), 1))

    async def test_disjoint_processes_and_affinity(self):
        code = """
import json, os, pathlib, time
s = os.environ['EUPHEMIA_FORECAST_RETRO_START']
p = pathlib.Path(os.environ['PERF_TEST_DIR']) / (s+'.json')
p.write_text(json.dumps({'start':s, 'end':os.environ['EUPHEMIA_FORECAST_RETRO_ASOF'], 'pid':os.getpid(), 'cpus':sorted(os.sched_getaffinity(0)), 'pool':os.environ['EUPHEMIA_PG_POOL']}))
time.sleep(.1)
print('⏱ fixture complete')
"""
        rc = await retro.run_parallel([sys.executable, "-c", code], self.env, self.chunks, self.deadline, self.cpus)
        rows = [json.loads(p.read_text()) for p in Path(self.tmp.name).glob("*.json")]
        self.assertEqual(rc, 0)
        self.assertEqual(len(rows), 4)
        self.assertEqual(len({r['pid'] for r in rows}), 4)
        for r in rows:
            self.assertEqual(r['start'], r['end'])
            self.assertIn(r['cpus'], [self.cpus[:4], self.cpus[4:]])
            self.assertEqual(r['pool'], '2')

    async def test_deadline_starts_nothing(self):
        with patch.object(retro.asyncio, "create_subprocess_exec", side_effect=AssertionError("must not spawn")):
            rc = await retro.run_parallel(["unused"], self.env, self.chunks,
                                          datetime.now(timezone.utc) + timedelta(seconds=1190), self.cpus)
        self.assertEqual(rc, 0)

    async def test_deadline_terminates_inflight_workers(self):
        code = """
import os, pathlib, time
p=pathlib.Path(os.environ['PERF_TEST_DIR'])/os.environ['EUPHEMIA_FORECAST_RETRO_START']
p.write_text(str(os.getpid()))
time.sleep(60)
"""
        original = asyncio.wait_for
        async def short_campaign_wait(awaitable, timeout):
            return await original(awaitable, .3 if timeout > 1000 else timeout)
        with patch.object(retro.asyncio, "wait_for", side_effect=short_campaign_wait):
            rc = await retro.run_parallel([sys.executable, "-c", code], self.env, self.chunks, self.deadline, self.cpus)
        self.assertEqual(rc, 0)
        files = list(Path(self.tmp.name).iterdir())
        self.assertEqual(len(files), 2)
        for f in files:
            self.assertFalse(Path('/proc/'+f.read_text()).exists())

    async def test_failure_stops_pending_chunks(self):
        code = """
import os, pathlib, sys, time
s=os.environ['EUPHEMIA_FORECAST_RETRO_START']
(pathlib.Path(os.environ['PERF_TEST_DIR'])/s).write_text('started')
if s.endswith('14'): sys.exit(7)
time.sleep(.5)
"""
        rc = await retro.run_parallel([sys.executable, "-c", code], self.env, self.chunks, self.deadline, self.cpus)
        self.assertEqual(rc, 1)
        self.assertLessEqual(len(list(Path(self.tmp.name).iterdir())), 2)

    async def test_spawn_failure_does_not_leave_sibling_work(self):
        original = retro.asyncio.create_subprocess_exec
        spawned = []
        async def spawn(*args, **kwargs):
            if len(spawned) == 1:
                raise OSError("fixture spawn failure")
            spawned.append(None)
            proc = await original(*args, **kwargs)
            spawned[0] = proc
            return proc
        with patch.object(retro.asyncio, "create_subprocess_exec", side_effect=spawn):
            with self.assertRaises(OSError):
                await retro.run_parallel([sys.executable, "-c", "import time; time.sleep(60)"], self.env, self.chunks, self.deadline, self.cpus)
        for proc in spawned:
            if proc is not None:
                self.assertIsNotNone(proc.returncode)

    async def test_cancellation_reaps_owned_child_groups(self):
        code = """
import os, pathlib, subprocess, sys, time
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
p=pathlib.Path(os.environ['PERF_TEST_DIR'])/os.environ['EUPHEMIA_FORECAST_RETRO_START']
p.write_text(str(os.getpid())+','+str(child.pid))
time.sleep(60)
"""
        task = asyncio.create_task(retro.run_parallel([sys.executable, "-c", code], self.env, self.chunks, self.deadline, self.cpus))
        for _ in range(100):
            if len(list(Path(self.tmp.name).iterdir())) == 2:
                break
            await asyncio.sleep(.02)
        files = list(Path(self.tmp.name).iterdir())
        self.assertEqual(len(files), 2)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        for f in files:
            for pid in map(int, f.read_text().split(',')):
                status = Path(f'/proc/{pid}/status')
                # An orphan may briefly be a zombie until PID 1 reaps it; it cannot compute.
                self.assertTrue(not status.exists() or '\nState:\tZ' in status.read_text())


if __name__ == "__main__":
    unittest.main()
