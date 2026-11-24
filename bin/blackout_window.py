#!/usr/bin/env python3
"""Protected-window check before a Postgres write (retro-backfill's transfers).

    python3 bin/blackout_window.py MARGIN_MIN      exit 0 = safe to start a write now; 1 = not

Refuses inside 06:00-08:30 UTC (the daily forecast) and 10:30-12:15 UTC (server refresh + publish), and within
MARGIN_MIN minutes BEFORE either window, so a write that starts now ends before it. GUARD_NOW_UTC=HHMM
overrides the clock (tests)."""
import os
import sys
from datetime import datetime, timezone

WINDOWS = ((6 * 60, 8 * 60 + 30, "06:00-08:30"), (10 * 60 + 30, 12 * 60 + 15, "10:30-12:15"))


def blocked(now_min: int, margin: int):
    """The window label that blocks a write starting at minute-of-day now_min, or None. Neither window crosses
    midnight, and a margin below 6 h cannot move 06:00 across it."""
    for start, end, label in WINDOWS:
        if start - margin <= now_min < end:
            return label
    return None


def main(argv):
    margin = int(argv[1]) if len(argv) > 1 else 0
    if not 0 <= margin < 360:
        sys.exit("margin must be in 0..359 minutes")
    hhmm = os.environ.get("GUARD_NOW_UTC") or datetime.now(timezone.utc).strftime("%H%M")
    now_min = int(hhmm[:2]) * 60 + int(hhmm[2:4])
    label = blocked(now_min, margin)
    if label:
        print(f"::error::{hhmm[:2]}:{hhmm[2:]} UTC is inside, or within {margin} min before, the protected window "
              f"{label} UTC — not writing to Postgres now")
        return 1
    print(f"window ok at {hhmm[:2]}:{hhmm[2:]} UTC (margin {margin} min)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
