#!/usr/bin/env python3
"""measure_windows.py — the time windows measure-duckdb-path.yml must not overlap (one source for its start guard,
its watchdog and test/test_measure_windows.py). All times UTC (the crons are UTC; no DST).

Two kinds of window:
  - protected: the live forecast (06:00–08:30) and publish (10:30–12:15) windows;
  - ceres ETL: every scheduled ceres workflow that writes the energy database. A measurement that overlaps one reads
    Postgres while it changes (run 45392030610: the 12:30 update_entsoe_data reloaded November ENTSO-E files between
    fill 1 and fill 2). Each window runs from the slot to its typical end: the p90 of (run end − slot time) over the
    ceres Actions history of 2026-11-24 (start lag + duration), rounded up to 5 min, plus a 15 min margin.

usage:  measure_windows.py check-start --timeout-min N [--now 2026-11-24T12:17]   exit 1 if [now, now+N) overlaps a window
        measure_windows.py check-now [--now ...]                                    exit 1 if now lies inside a window
        measure_windows.py table                                                    the windows (markdown)
"""
import argparse
import datetime as dt
import sys

ALL = frozenset(range(7))            # Monday = 0
TUE_SAT = frozenset({1, 2, 3, 4, 5})
MON = frozenset({0})

# (name, start HH:MM UTC, length in minutes, weekdays of the start, evidence)
WINDOWS = [
    ("protected: live forecast", "06:00", 150, ALL, "tasks/431-common.md"),
    ("protected: publish", "10:30", 105, ALL, "tasks/431-common.md"),
    ("ceres update_entsoe_data 00:00", "00:00", 215, ALL, "p90 end +197 min (n=10, max 215)"),
    ("ceres update_entsoe_data 08:00", "08:00", 170, ALL, "p90 end +155 min (n=21, max 210)"),
    ("ceres update_entsoe_data 12:30", "12:30", 125, ALL, "p90 end +110 min (n=9, max 112)"),
    ("ceres update_entsoe_data 17:30", "17:30", 205, ALL, "p90 end +186 min (n=23, max 194)"),
    ("ceres update_entsoe_data 19:30", "19:30", 135, ALL, "p90 end +116 min (n=22, max 136)"),
    ("ceres jao_pregate_forecast 08:55", "08:55", 110, ALL, "p90 end +92 min (n=32, max 94)"),
    ("ceres jao_pregate_forecast 09:55", "09:55", 65, ALL, "p90 end +47 min (n=34, max 96)"),
    ("ceres update_yfinance_data 05:30", "05:30", 100, TUE_SAT, "p90 end +80 min (n=20, max 83; late start)"),
    ("ceres update_gb_prices_data 06:00", "06:00", 100, TUE_SAT, "p90 end +83 min (n=19, max 86; late start)"),
    ("ceres update_elexon_data 07:30", "07:30", 20, ALL, "p90 end +3 min (n=8, max 3)"),
    ("ceres update_elexon_data 17:30", "17:30", 25, ALL, "p90 end +6 min (n=9, max 13)"),
    ("ceres update_epias_data 15:30", "15:30", 50, ALL, "p90 end +33 min (n=21, max 66)"),
    ("ceres update_entsog_only_data 00:00", "00:00", 130, MON, "p90 end +112 min (n=30, max 181)"),
    ("ceres update_gie_only_data 00:00", "00:00", 185, MON, "p90 end +165 min (n=25, max 178)"),
]


def instances(day0, day1):
    """Every window occurrence [start, end) whose start falls on a date in day0..day1."""
    d = day0
    while d <= day1:
        for name, hhmm, length, days, _ in WINDOWS:
            if d.weekday() in days:
                h, m = map(int, hhmm.split(":"))
                s = dt.datetime(d.year, d.month, d.day, h, m, tzinfo=dt.timezone.utc)
                yield name, s, s + dt.timedelta(minutes=length)
        d += dt.timedelta(days=1)


def overlapping(now, minutes):
    """Windows that intersect [now, now + minutes)."""
    end = now + dt.timedelta(minutes=minutes)
    span = (now - dt.timedelta(days=1)).date(), end.date()
    return [(n, s, e) for n, s, e in instances(*span) if s < end and now < e]


def parse_now(s):
    if not s:
        return dt.datetime.now(dt.timezone.utc).replace(second=0, microsecond=0)
    t = dt.datetime.fromisoformat(s)
    return t.replace(tzinfo=dt.timezone.utc) if t.tzinfo is None else t.astimezone(dt.timezone.utc)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check-start", "check-now", "table"])
    ap.add_argument("--timeout-min", type=int, default=0)
    ap.add_argument("--now", default="")
    a = ap.parse_args(argv)
    if a.cmd == "table":
        print("| window | UTC | days | evidence |\n|---|---|---|---|")
        for name, hhmm, length, days, ev in WINDOWS:
            h, m = map(int, hhmm.split(":")); e = (h * 60 + m + length) % 1440
            dl = "daily" if days == ALL else "Tue–Sat" if days == TUE_SAT else "Mon"
            print(f"| {name} | {hhmm}–{e // 60:02d}:{e % 60:02d} | {dl} | {ev} |")
        return 0
    now = parse_now(a.now)
    hits = overlapping(now, a.timeout_min if a.cmd == "check-start" else 1)
    for name, s, e in hits:
        what = "overlaps" if a.cmd == "check-start" else "is inside"
        print(f"::error::refused: {now:%Y-%m-%d %H:%M} UTC" + (f" + {a.timeout_min} min" if a.cmd == "check-start" else "") +
              f" {what} {name} ({s:%a %H:%M}–{e:%H:%M} UTC)")
    if not hits:
        print(f"windows OK at {now:%Y-%m-%d %H:%M} UTC" + (f" for the next {a.timeout_min} min" if a.cmd == "check-start" else ""))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
