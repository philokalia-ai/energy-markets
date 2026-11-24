"""bin/blackout_window.py: the protected-window guard of retro-backfill's transfers (#472 review #5)."""
import os
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "bin" / "blackout_window.py"


def run(hhmm, margin):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GUARD_NOW_UTC": hhmm}
    return subprocess.run([sys.executable, "-I", str(SCRIPT), str(margin)], env=env, capture_output=True).returncode


class BlackoutWindow(unittest.TestCase):
    def test_inside_windows_refused(self):
        for t in ("0600", "0700", "0829", "1030", "1200", "1214"):
            self.assertEqual(run(t, 0), 1, t)

    def test_outside_windows_allowed(self):
        for t in ("0000", "0559", "0830", "1029", "1215", "1500", "2359"):
            self.assertEqual(run(t, 0), 0, t)

    def test_margin_before_a_window(self):
        self.assertEqual(run("0555", 5), 1)    # a write starting 5 min before 06:00 is refused with margin 5
        self.assertEqual(run("0554", 5), 0)
        self.assertEqual(run("1027", 3), 1)
        self.assertEqual(run("1026", 3), 0)
        self.assertEqual(run("0830", 5), 0)    # the margin applies BEFORE a window, not after it

    def test_bad_margin(self):
        self.assertNotEqual(run("1200", -1), 0)
        self.assertNotEqual(run("1200", 400), 0)


if __name__ == "__main__":
    unittest.main()
