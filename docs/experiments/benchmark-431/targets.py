"""Use the repository's canonical day-ahead target-policy API."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "bin"))
import da_target as helper
