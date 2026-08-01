#!/usr/bin/env python3
"""Fetch the OMIE aggregate supply/demand curve files for the FROZEN protocol months.

Raw-input fetcher for the published-books clearing validation (see protocol.md /
REPRODUCE.md). Downloads the real Iberian (MIBEL) day-ahead aggregate curves
DIRECTLY from OMIE's own public file-download endpoint. The converter
(pubbooks_prep.py) reads the per-MONTH zip and slices the day it needs, so this
fetcher pulls the six monthly `curva_pbc_uof_YYYYMM.zip` archives that cover the
protocol's OMIE sample days.

We do NOT redistribute the raw OMIE files — the repo/R2 carry only our DERIVED
converted books (see REPRODUCE.md, "Path B"). This fetcher obtains them from the
source under OMIE's terms.

SOURCE (OMIE public "file-access" download center; no login, no handshake):
  GET https://www.omie.es/es/file-download?parents=curva_pbc_uof&filename=<name>
    monthly archive:  curva_pbc_uof_YYYYMM.zip  (all days of the month; ~20-95 MB)
    single day (alt): curva_pbc_uof_YYYYMMDD.1   (one day, semicolon text)
  Each in-zip file `curva_pbc_uof_YYYYMMDD.N` is a latin-1, ';'-delimited table:
  period; date; ...; unit; Tipo (V=sell/supply, C=buy/demand); Energia/Potencia
  (MWh or MW); Precio (EUR/MWh); Ofertada/Casada flag (O=offered, C=matched).
  Verified live 2026-08-01: HTTP 200, content-type application/zip.

TERMS OF USE (omie.es legal notice): the public market results are provided for
  consultation; OMIE is cited as the source. We keep raw files git-ignored and
  never commit/redistribute them; a raw public mirror is the owner's call
  (flagged, not taken — see REPRODUCE.md).

USAGE:
  python3 fetch_omie.py --out /path/to/scratch/pubbooks/raw       # all 6 frozen months
  python3 fetch_omie.py --out ... --months 202501 202504          # a subset
Writes <out>/curva_pbc_uof_<YYYYMM>.zip, prints SHA256 and checks it against the
reference table (mismatch => warning: OMIE may re-publish; the authoritative
check is the R2 SHA256SUMS on the DERIVED converted books).
"""
import argparse
import hashlib
import sys
from pathlib import Path

import requests

# --- frozen protocol months (pubbooks_prep.py OMIE_MONTHS; cover the OMIE sample days) ---
OMIE_MONTHS = ["202501", "202504", "202507", "202510", "202601", "202604"]

BASE = "https://www.omie.es/es/file-download?parents=curva_pbc_uof&filename="
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"

# Reference SHA256 of the monthly zips AS DOWNLOADED 2026-07-30 (informational).
REF_RAW_SHA256 = {
    "202501": "aecc71a4d355c0af4a2fa99c16b9b06272d2bf4bd2f228e46542c278e779b908",
    "202504": "74cc871fedb6a4f61135bf2daabe4ad08fc6d8893ecd28be8a78b87dd39ec38e",
    "202507": "9be49005b8468b3e337cfce68a0305cfaeca4e2e6bbcaf5d5e92e2795adbde4f",
    "202510": "83009ab346bd1a6ec60447e91bd8b06e3bbbffcd5dd862099dc34e8f7e471ac0",
    "202601": "01e580f40e7bd850150e5f387819a4c40d1d97564415105883cc9ddf1b374b5d",
    "202604": "a41f2b45b02c53f903c72cbe0198c79ace97f954081df54d5d55130a6e0539f7",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_month(session, ym, out_dir):
    name = f"curva_pbc_uof_{ym}.zip"
    r = session.get(BASE + name, timeout=600)
    if r.status_code != 200 or "zip" not in r.headers.get("Content-Type", ""):
        raise RuntimeError(f"{ym}: unexpected response {r.status_code} "
                           f"{r.headers.get('Content-Type')} {r.content[:120]!r}")
    dest = Path(out_dir) / name
    dest.write_bytes(r.content)
    return dest, len(r.content)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="git-ignored raw/ scratch dir")
    ap.add_argument("--months", nargs="+", default=OMIE_MONTHS,
                    help="YYYYMM (default: the 6 frozen protocol months)")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    s = requests.Session()
    s.headers["User-Agent"] = UA
    rc = 0
    for ym in args.months:
        try:
            dest, n = fetch_month(s, ym, out)
            got = sha256(dest)
            ref = REF_RAW_SHA256.get(ym)
            tag = "OK" if ref == got else ("no-ref" if ref is None else "DRIFT")
            print(f"{tag} {ym}: {n/1e6:.1f} MB  sha256={got[:16]}…")
            if ref and ref != got:
                print(f"  ::warning:: {ym} zip sha256 differs from reference "
                      f"({ref[:16]}…) — OMIE re-publish; converted-book check is authoritative",
                      file=sys.stderr)
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {ym}: {e}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
