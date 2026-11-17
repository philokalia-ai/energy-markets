#!/usr/bin/env python3
"""Opt-in, bounded process parallelism for the alongside retro campaign.

One worker execs the original command unchanged. Two workers run disjoint,
contiguous chunks with four CPUs and at most two PG connections each. No solver,
weather-vintage, write, resume, scoring or model-version logic is duplicated here.
The existing run_retro guards remain authoritative inside every child.
"""
from __future__ import annotations

import argparse
import asyncio
from collections import deque
from datetime import date, datetime, timedelta, timezone
import os
import signal
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRUTHY = {"1", "true", "yes", "on"}


def day_chunks(start: date, end: date, size: int):
    if start > end or size < 1:
        raise ValueError("require start <= end and a positive chunk size")
    while start <= end:
        stop = min(end, start + timedelta(days=size - 1))
        yield start, stop
        start = stop + timedelta(days=1)


def parallel_config(env, workers, cpus, today=None):
    """Validate before spawning; returns disjoint original-size chunks + deadline."""
    if workers != 2:
        raise ValueError("parallel mode is limited to two workers")
    if len(cpus) < workers * 4:
        raise ValueError("two workers require at least eight allowed CPUs")
    if env.get("EUPHEMIA_RETRO_ALONGSIDE", "").lower() not in TRUTHY:
        raise ValueError("parallel mode requires EUPHEMIA_RETRO_ALONGSIDE=1")
    if env.get("EUPHEMIA_RETRO_SUPERSEDE", "").lower() in TRUTHY:
        raise ValueError("parallel mode forbids supersede")
    if not env.get("EUPHEMIA_FORECAST_RESET_TAG", "").strip():
        raise ValueError("parallel mode requires an explicit reset tag")
    if env.get("INPUT_MODE") != "weather" or env.get("MAX_LEAD_DAYS") != "1":
        raise ValueError("parallel mode is restricted to weather lead 1")
    start = date.fromisoformat(env["EUPHEMIA_FORECAST_RETRO_START"])
    end = date.fromisoformat(env["EUPHEMIA_FORECAST_RETRO_ASOF"])
    if end >= (today or datetime.now(timezone.utc).date()):
        raise ValueError("retro end must be a past market day")
    size = int(env.get("EUPHEMIA_RETRO_CHUNK_DAYS", "14"))
    deadline = datetime.fromisoformat(env["EUPHEMIA_RETRO_DEADLINE_UTC"].replace("Z", "+00:00"))
    if deadline.tzinfo is None:
        deadline = deadline.replace(tzinfo=timezone.utc)
    deadline = deadline.astimezone(timezone.utc)
    return list(day_chunks(start, end, size)), deadline


def worker_env(env, start, end):
    result = dict(env)
    result.update(EUPHEMIA_FORECAST_RETRO_START=start.isoformat(),
                  EUPHEMIA_FORECAST_RETRO_ASOF=end.isoformat(),
                  JULIA_NUM_THREADS="4", EUPHEMIA_PG_POOL="2",
                  OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1")
    return result


async def terminate_owned(processes):
    """Only process groups created by this invocation; never runner processes."""
    for proc in processes:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if not processes:
        return
    try:
        await asyncio.wait_for(asyncio.gather(*(p.wait() for p in processes)), 10)
    except asyncio.TimeoutError:
        for proc in processes:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        await asyncio.gather(*(p.wait() for p in processes))


async def run_parallel(command, env, chunks, deadline, cpus, *, now=None):
    """Do not admit more work after failure or inside the preparation allowance."""
    now = now or (lambda: datetime.now(timezone.utc))
    pending = deque(enumerate(chunks, 1))
    active = set()
    failed = False

    async def worker(slot):
        nonlocal failed
        affinity = ",".join(map(str, cpus[4 * slot:4 * (slot + 1)]))
        while pending and not failed:
            # Same initial budget as run_retro: 10 min preparation + 600 s/day.
            # Children also check their measured slowest day before each clear.
            if now() + timedelta(seconds=1200) > deadline:
                print("🛑 parallel clean stop: no new chunk before deadline; resume with the same inputs", flush=True)
                return
            index, (start, end) = pending.popleft()
            prefix = f"[chunk {index} {start}..{end}] "
            print(prefix + f"starting on CPUs {affinity}; PG pool 2", flush=True)
            proc = await asyncio.create_subprocess_exec(
                "taskset", "-c", affinity, *command,
                cwd=ROOT, env=worker_env(env, start, end),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                start_new_session=True,
            )
            active.add(proc)
            completed = False
            try:
                async for line in proc.stdout:
                    print(prefix + line.decode("utf-8", errors="replace").rstrip("\n"), flush=True)
                rc = await proc.wait()
                if rc:
                    failed = True
                    print(prefix + f"FAILED (exit {rc}); no more chunks will start", flush=True)
                completed = True
            finally:
                if completed:
                    active.discard(proc)

    tasks = [asyncio.create_task(worker(slot)) for slot in range(2)]
    try:
        await asyncio.wait_for(
            asyncio.gather(*tasks), max(0, (deadline - now()).total_seconds())
        )
    except asyncio.TimeoutError:
        print("🛑 parallel deadline reached: stopping owned workers; completed days are preserved, re-dispatch to resume", flush=True)
    finally:
        # Stop sibling schedulers before taking the cleanup snapshot: a failed
        # spawn/read must not leave another coroutine admitting a new child.
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await terminate_owned(list(active))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, choices=(1, 2), default=1)
    args = parser.parse_args()
    command = ["julia", "--project=.", "bin/daily_forecast.jl"]
    if args.workers == 1:
        os.chdir(ROOT)
        os.execvpe(command[0], command, os.environ)
    cpus = sorted(os.sched_getaffinity(0))
    try:
        chunks, deadline = parallel_config(os.environ, args.workers, cpus)
    except (KeyError, ValueError) as exc:
        parser.error(str(exc))

    async def run():
        task = asyncio.current_task()
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGTERM, task.cancel)
        try:
            return await run_parallel(command, os.environ, chunks, deadline, cpus)
        finally:
            loop.remove_signal_handler(signal.SIGTERM)

    try:
        return asyncio.run(run())
    except (KeyboardInterrupt, asyncio.CancelledError):
        return 130


if __name__ == "__main__":
    sys.exit(main())
