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
TERMINATE_GRACE_SECONDS = 10


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


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False


async def finish_shielded(task):
    """Finish an owned task despite repeated cancellation; report interruption."""
    interrupted = False
    while not task.done():
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            interrupted = True
    return task.result(), interrupted


async def terminate_owned(processes):
    """Signal owned groups even when their leaders have already exited.

    Reap direct children; orphaned descendants are reaped by their adopter.
    Group existence, not leader returncode, controls TERM-to-KILL escalation.
    """
    groups = {p.pid for p in processes}
    for pgid in groups:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    loop = asyncio.get_running_loop()
    until = loop.time() + TERMINATE_GRACE_SECONDS
    while groups:
        groups = {pgid for pgid in groups if group_exists(pgid)}
        if not groups or loop.time() >= until:
            break
        await asyncio.sleep(min(.05, max(0, until - loop.time())))
    for pgid in groups:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    await asyncio.gather(*(p.wait() for p in processes))


class WorkerFailed(Exception):
    """A child failed; stop admission and terminate every owned group."""


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
            creation = asyncio.create_task(asyncio.create_subprocess_exec(
                "taskset", "-c", affinity, *command,
                cwd=ROOT, env=worker_env(env, start, end),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                start_new_session=True,
            ))
            try:
                proc = await asyncio.shield(creation)
            except asyncio.CancelledError:
                # Cancellation can arrive after fork but before subprocess
                # creation returns. Claim that child before global cleanup.
                proc, _ = await finish_shielded(creation)
                active.add(proc)
                raise
            active.add(proc)
            async def drain_output():
                async for line in proc.stdout:
                    print(prefix + line.decode("utf-8", errors="replace").rstrip("\n"), flush=True)

            reader = asyncio.create_task(drain_output())
            try:
                # Process.wait() can wait for inherited stdout to close even
                # after the leader exits. Observe returncode independently so
                # a descendant cannot conceal a failed leader by holding a pipe.
                while proc.returncode is None:
                    if reader.done():
                        reader.result()
                    await asyncio.sleep(.05)
                rc = proc.returncode
                if rc:
                    failed = True
                    print(prefix + f"FAILED (exit {rc}); stopping owned groups", flush=True)
                    raise WorkerFailed(prefix)
                # Successful leaders may also leave detached descendants.
                await terminate_owned([proc])
                await reader
                active.discard(proc)
            finally:
                reader.cancel()
                await asyncio.gather(reader, return_exceptions=True)

    tasks = [asyncio.create_task(worker(slot)) for slot in range(2)]
    try:
        await asyncio.wait_for(
            asyncio.gather(*tasks), max(0, (deadline - now()).total_seconds())
        )
    except WorkerFailed:
        failed = True
    except asyncio.TimeoutError:
        print("🛑 parallel deadline reached: stopping owned workers; completed days are preserved, re-dispatch to resume", flush=True)
    finally:
        async def stop_and_reap():
            # Claim in-flight spawns before taking the final group snapshot.
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await terminate_owned(list(active))

        _, interrupted = await finish_shielded(asyncio.create_task(stop_and_reap()))
        if interrupted:
            raise asyncio.CancelledError
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
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, task.cancel)
        try:
            return await run_parallel(command, os.environ, chunks, deadline, cpus)
        finally:
            for sig in (signal.SIGTERM, signal.SIGINT):
                loop.remove_signal_handler(sig)

    try:
        return asyncio.run(run())
    except (KeyboardInterrupt, asyncio.CancelledError):
        return 130


if __name__ == "__main__":
    sys.exit(main())
