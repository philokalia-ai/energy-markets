"""Prefer PR C's canonical API; keep a labelled local port until it lands."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "bin"))
try:
    import da_target as helper
except ModuleNotFoundError as error:
    if error.name != "da_target":
        raise
    import _target_fallback as helper
