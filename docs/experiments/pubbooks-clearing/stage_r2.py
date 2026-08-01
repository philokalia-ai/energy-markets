#!/usr/bin/env python3
"""Stage the published-books validation DERIVED artifacts for the R2 upload.

Turns the experiment's git-ignored intermediates ($PUBBOOKS_DIR) into the
self-contained artifact tree the owner-dispatchable `upload-experiment-data.yml`
workflow pushes to  s3://euphemia-web-data/experiments/pubbooks/v1/ .

What ships (DERIVED only — NO raw GME/OMIE row ever leaves the scratch dir):
  converted/<ex>/<YYYY-MM-DD>.parquet   our SimpleOrder-format per exchange-day
                                        order book (zone, day, hour, side, price,
                                        mw, resolution_min) — the CLEARING input
  converted/<ex>_cells.parquet          per-cell reference row (official price,
                                        net position, awarded supply) — the
                                        clearing/analysis join key
  metrics/metrics_<ex>_<day>.tsv        per-day engine-vs-official metric rows
                                        (pubbooks_clear.jl output)
  outputs/analysis.txt                  frozen metric tables, both exchanges
                                        (pubbooks_analyze.py)
  MANIFEST.json + SHA256SUMS            coverage + integrity

With these a reproducer can re-run the CLEARING and ANALYSIS stages with NO
exchange download (Path B in REPRODUCE.md), and can re-derive the conversion
from source via fetch_gme.py / fetch_omie.py + pubbooks_prep.py (Path A).

USAGE:
  PUBBOOKS_DIR=/path/to/pubbooks \\
    python3 stage_r2.py --staging data/experiments/pubbooks/v1 \\
      [--exchanges gme omie] [--analyzer test/scripts/pubbooks_analyze.py]
Idempotent: re-run to refresh. Writes MANIFEST.json + SHA256SUMS over whatever
is present, so run it once BOTH exchanges are complete for the final push.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

CODE_VERSION = 26  # cv26 record books were the subject (protocol §1)
ORDER_COLS = ["exchange", "zone", "day", "hour", "side", "price", "mw"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dump_converted(pub, staging, ex):
    """intermediate/<ex>_orders.tsv -> converted/<ex>/<day>.parquet (per day);
    intermediate/<ex>_cells.tsv    -> converted/<ex>_cells.parquet."""
    intr = pub / "intermediate"
    orders_tsv = intr / f"{ex}_orders.tsv"
    cells_tsv = intr / f"{ex}_cells.tsv"
    if not orders_tsv.exists():
        print(f"  {ex}: no {orders_tsv.name} — skipped")
        return []
    conv_dir = staging / "converted" / ex
    conv_dir.mkdir(parents=True, exist_ok=True)
    od = pd.read_csv(orders_tsv, sep="\t")
    od = od[ORDER_COLS].copy()
    od["resolution_min"] = 60  # cells are cleared as one 60-min period (harness §)
    days = []
    for day, g in od.groupby("day"):
        out = conv_dir / f"{day}.parquet"
        g.reset_index(drop=True).to_parquet(out, index=False, compression="zstd")
        days.append(day)
    if cells_tsv.exists():
        pd.read_csv(cells_tsv, sep="\t").to_parquet(
            staging / "converted" / f"{ex}_cells.parquet", index=False, compression="zstd")
    print(f"  {ex}: {len(od):,} order rows -> {len(days)} per-day parquet(s) + cells")
    return sorted(days)


def copy_metrics(pub, staging, ex):
    dst = staging / "metrics"
    dst.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted((pub / "intermediate").glob(f"metrics_{ex}_*.tsv")):
        shutil.copy2(f, dst / f.name)
        n += 1
    print(f"  {ex}: copied {n} per-day metrics TSV(s)")
    return n


def run_analysis(pub, staging, analyzer):
    """Run pubbooks_analyze.py ONCE over all present metrics -> outputs/analysis.txt.
    The analyzer prints the GME then OMIE frozen tables; capture both verbatim."""
    if not analyzer:
        return None
    ap = Path(analyzer)
    if not ap.exists():
        print(f"  analyzer {analyzer} not found — outputs/ left as-is")
        return None
    outdir = staging / "outputs"
    outdir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PUBBOOKS_DIR=str(pub))
    res = subprocess.run([sys.executable, str(ap)], capture_output=True, text=True, env=env)
    (outdir / "analysis.txt").write_text(res.stdout)
    print(f"  wrote outputs/analysis.txt ({len(res.stdout.splitlines())} lines)")
    return "analysis.txt"


def build_manifest(staging, coverage):
    files = []
    for p in sorted(staging.rglob("*")):
        if p.is_file() and p.name not in ("MANIFEST.json", "SHA256SUMS"):
            files.append((str(p.relative_to(staging)), p.stat().st_size, sha256(p)))
    (staging / "SHA256SUMS").write_text(
        "".join(f"{h}  {rel}\n" for rel, _sz, h in files))
    manifest = {
        "artifact": "pubbooks-clearing-validation",
        "version": "v1",
        "prefix": "experiments/pubbooks/v1/",
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "code_version": CODE_VERSION,
        "protocol": "docs/experiments/pubbooks-clearing/protocol.md",
        "reproduce": "docs/experiments/pubbooks-clearing/REPRODUCE.md",
        "note": ("DERIVED artifacts only. Raw GME/OMIE downloads are NOT "
                 "redistributed — obtain them from source via fetch_gme.py / "
                 "fetch_omie.py. See REPRODUCE.md."),
        "coverage": coverage,
        "files": [{"path": rel, "bytes": sz, "sha256": h} for rel, sz, h in files],
    }
    (staging / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    total = sum(sz for _r, sz, _h in files)
    print(f"MANIFEST.json + SHA256SUMS over {len(files)} files ({total/1e6:.1f} MB)")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--staging", required=True, help="staging root (…/experiments/pubbooks/v1)")
    ap.add_argument("--exchanges", nargs="+", default=["gme", "omie"])
    ap.add_argument("--analyzer", default=None,
                    help="path to pubbooks_analyze.py (regenerate outputs/); omit to keep existing")
    args = ap.parse_args()
    pub = Path(os.environ["PUBBOOKS_DIR"])
    staging = Path(args.staging)
    staging.mkdir(parents=True, exist_ok=True)
    coverage = {}
    for ex in args.exchanges:
        print(f"[{ex}]")
        days = dump_converted(pub, staging, ex)
        nmetrics = copy_metrics(pub, staging, ex)
        if days or nmetrics:
            coverage[ex] = {"days": days, "metrics_files": nmetrics}
    run_analysis(pub, staging, args.analyzer)
    build_manifest(staging, coverage)


if __name__ == "__main__":
    main()
