#!/usr/bin/env python3
"""Replay saved-input market days through the real chunk launcher, without DB writes."""
import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import signal

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("retro_launcher", ROOT / "bin/run_retro_backfill.py")
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("start")
    parser.add_argument("end")
    parser.add_argument("--julia", default="julia")
    args = parser.parse_args()
    if not Path(os.environ.get("PERF_FIXTURE", "")).is_file():
        parser.error("PERF_FIXTURE must name the saved, trusted Julia input fixture")
    if not os.environ.get("RETRO_PERF_OUT"):
        parser.error("RETRO_PERF_OUT is required")
    env = dict(os.environ,
        PERF_LABEL="parallel2", PERF_DAYS_FROM_ENV="1", RETRO_PERF_PREPARE="0",
        EUPHEMIA_RETRO_ALONGSIDE="1", EUPHEMIA_FORECAST_RESET_TAG="perf-offline",
        INPUT_MODE="weather", MAX_LEAD_DAYS="1",
        EUPHEMIA_FORECAST_RETRO_START=args.start, EUPHEMIA_FORECAST_RETRO_ASOF=args.end,
        EUPHEMIA_RETRO_CHUNK_DAYS="1",
        EUPHEMIA_RETRO_DEADLINE_UTC=(datetime.now(timezone.utc) + timedelta(hours=2)).isoformat())
    cpus = sorted(os.sched_getaffinity(0))
    chunks, deadline = launcher.parallel_config(env, 2, cpus)
    command = [args.julia, "--startup-file=no", "--project=.",
               "test/scripts/benchmark_retro_backfill.jl"]

    async def run():
        loop = asyncio.get_running_loop()
        task = asyncio.current_task()
        loop.add_signal_handler(signal.SIGTERM, task.cancel)
        try:
            return await launcher.run_parallel(command, env, chunks, deadline, cpus)
        finally:
            loop.remove_signal_handler(signal.SIGTERM)

    return asyncio.run(run())


if __name__ == "__main__":
    raise SystemExit(main())
