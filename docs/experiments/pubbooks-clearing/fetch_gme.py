#!/usr/bin/env python3
"""Fetch + parse the GME MGP "Offerte Pubbliche" books for the FROZEN protocol days.

This is the raw-input fetcher for the published-books clearing validation
(see protocol.md / REPRODUCE.md). It downloads the real Italian day-ahead
bid/offer books DIRECTLY from GME's own public endpoint and stream-parses each
into the compact per-offer parquet the converter (pubbooks_prep.py) consumes.

We do NOT redistribute the raw GME files — this fetcher lets a reproducer obtain
them from the source under GME's own terms; the repo/R2 carry only our DERIVED
converted books (see REPRODUCE.md, "Path B").

SOURCE (reverse-engineered 2026-07 from the public download page; no login, but a
two-checkbox disclaimer must be accepted, modelled as an anti-forgery token +
`GmePolicy` cookie handshake reproduced below). Prior art, same recipe:
docs/experiments/gme-book-comparison/scripts/{fetch,parse}_gme_offers.py .

  Landing page (accept-terms gate; mints the tokens/cookies):
    GET https://www.mercatoelettrico.org/it-it/Home/Esiti/Elettricita/MGP/Download/OffertePubbliche
  Data endpoint (DNN ServicesFramework WebAPI; returns application/zip):
    GET https://www.mercatoelettrico.org/DesktopModules/GmeDownload/API/ExcelDownload/downloadzipfile
        ?DataInizio=YYYYMMDD&DataFine=YYYYMMDD&Date=YYYYMMDD
        &Mercato=MGP&Settore=OffertePubbliche&FiltroDate=InizioFine
    Headers read off the landing page: ModuleId, TabId,
      RequestVerificationToken (paired with the __RequestVerificationToken
      cookie), userid. Cookies: those set by the landing GET + GmePolicy=true.
  The zip holds one `YYYYMMDDMGPOffertePubbliche.xml` (a Microsoft DataSet dump).

EMBARGO: bid/offer data is confidential for 7 days after the session date
  (Ministerial Decree 29 April 2009). Every frozen protocol day is far older.

TERMS OF USE (mercatoelettrico.org "Condizioni di utilizzo"): data are provided
  free for consultation with a warranty exclusion; downstream users must accept
  the same terms. => we keep raw XML/zip in a git-ignored scratch dir and never
  commit or redistribute it. A raw public mirror is possible only if the project
  owner accepts these terms — flagged, not taken (see REPRODUCE.md).

USAGE:
  python3 fetch_gme.py --out /path/to/scratch/pubbooks/raw        # all 7 frozen days
  python3 fetch_gme.py --out ... --days 2025-01-15 2025-04-15     # a subset
Writes, per day, <out>/<YYYYMMDD>MGP_OffertePubbliche.zip and the parsed
<out>/gme_<YYYY-MM-DD>.parquet, then prints SHA256 and checks it against the
reference table below (mismatch => warning, not fatal: GME re-exports drift; the
authoritative check is the R2 SHA256SUMS on the DERIVED converted books).
"""
import argparse
import hashlib
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import pandas as pd
import requests

# --- frozen protocol day list (protocol.md §2) ---
GME_DAYS = ["2025-01-15", "2025-04-15", "2025-07-15", "2025-10-15",
            "2026-01-15", "2026-04-15", "2026-07-15"]

IT_ZONES = {"NORD", "CNOR", "CSUD", "SUD", "CALA", "SICI", "SARD"}
KEEP = ("PURPOSE_CD", "TYPE_CD", "STATUS_CD", "ZONE_CD", "UNIT_REFERENCE_NO",
        "OPERATORE", "PERIOD", "INTERVAL_NO", "GRANULARITY", "QUANTITY_NO",
        "AWARDED_QUANTITY_NO", "ENERGY_PRICE_NO", "AWARDED_PRICE_NO",
        "MERIT_ORDER_NO", "BID_OFFER_DATE_DT")

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
LANDING = ("https://www.mercatoelettrico.org/it-it/Home/Esiti/Elettricita/"
           "MGP/Download/OffertePubbliche")
API = ("https://www.mercatoelettrico.org/DesktopModules/GmeDownload/API/"
       "ExcelDownload/downloadzipfile")

# Reference SHA256 of the raw zip AS DOWNLOADED 2026-07-30 (informational; GME
# may re-export byte-differently — a mismatch is a WARNING, not an error).
REF_RAW_SHA256 = {
    "2025-01-15": "a86833e720c9b116a0d7990e977364dc3d03c4dd8252af0b9b2c2b87d65a8acd",
    "2025-04-15": "d0a71882f6502bd70d0356159186db968c0c1dfc0d9411b96edf78793d36c685",
    "2025-07-15": "54dc7639ec99f0d069e2f0826f33d410ea38973508290e53e81a897f0219b69f",
    "2025-10-15": "7643d63a9c3b6e2364f330162cd67c90288d289457e4424f7ad00b41932db1b9",
    "2026-01-15": "b851bf851d18d0419c2a4cbacff433cc6c3c62e058526ee0ac6c166561de1b34",
    "2026-04-15": "1f94c871d9d6f205796d6506b2ae46087ed048a48763472814723cee48bbdba3",
    "2026-07-15": "6f9b7f434107cb25c6301254b7ff212859e9e726ce54c3694c0ee132116d989b",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_session():
    """Open a session, accept the disclaimer, return (session, headers)."""
    s = requests.Session()
    s.headers["User-Agent"] = UA
    r = s.get(LANDING, timeout=60)
    r.raise_for_status()
    html = r.text
    m = re.search(r'name="__RequestVerificationToken"[^>]*value="([^"]*)"', html)
    if not m:
        raise RuntimeError("could not find __RequestVerificationToken on landing page")
    rvt = m.group(1)
    module_id = (re.search(r'"ModuleId":(\d+)', html) or [None, "12067"])[1]
    tab_id = (re.search(r'"TabId":(\d+)', html) or [None, "1706"])[1]
    s.cookies.set("GmePolicy", "true", domain="www.mercatoelettrico.org")
    headers = {
        "ModuleId": str(module_id),
        "TabId": str(tab_id),
        "RequestVerificationToken": rvt,
        "userid": "-1",
        "X-Requested-With": "XMLHttpRequest",
        "Referer": LANDING,
    }
    return s, headers


def fetch_day(session, headers, yyyymmdd, out_dir):
    params = {
        "DataInizio": yyyymmdd, "DataFine": yyyymmdd, "Date": yyyymmdd,
        "Mercato": "MGP", "Settore": "OffertePubbliche", "FiltroDate": "InizioFine",
    }
    r = session.get(API, params=params, headers=headers, timeout=600)
    if r.status_code != 200 or "zip" not in r.headers.get("Content-Type", ""):
        raise RuntimeError(f"{yyyymmdd}: unexpected response {r.status_code} "
                           f"{r.headers.get('Content-Type')} {r.content[:200]!r}")
    dest = Path(out_dir) / f"{yyyymmdd}MGP_OffertePubbliche.zip"
    dest.write_bytes(r.content)
    return dest, len(r.content)


def unit_kind(ref):
    if not ref:
        return "other"
    for p in ("UPV", "UP_", "UCV", "UC_", "UVZ"):
        if ref.startswith(p):
            return p.rstrip("_")
    return "other"


def parse_zip(zip_path, out_path):
    """Stream-parse a GME OffertePubbliche zip -> compact per-offer parquet,
    keeping only the 7 Italian physical bidding zones (matches the committed
    parse_gme_offers.py exactly)."""
    zf = zipfile.ZipFile(zip_path)
    name = [n for n in zf.namelist() if n.lower().endswith(".xml")][0]
    rows, cur = [], {}
    with zf.open(name) as fh:
        for _ev, el in ET.iterparse(fh, events=("end",)):
            tag = el.tag
            if tag == "OfferteOperatori":
                if cur.get("ZONE_CD") in IT_ZONES:
                    def ff(k):
                        try:
                            return float(cur.get(k))
                        except (TypeError, ValueError):
                            return None
                    ref = cur.get("UNIT_REFERENCE_NO")
                    hr = cur.get("PERIOD") or cur.get("INTERVAL_NO")
                    rows.append((
                        cur.get("BID_OFFER_DATE_DT"), cur.get("ZONE_CD"),
                        int(hr) if hr else None,
                        cur.get("PURPOSE_CD"), cur.get("STATUS_CD"),
                        ff("ENERGY_PRICE_NO"), ff("QUANTITY_NO"),
                        ff("AWARDED_QUANTITY_NO"), ff("AWARDED_PRICE_NO"),
                        ff("MERIT_ORDER_NO"),
                        ref, unit_kind(ref), cur.get("OPERATORE"),
                        cur.get("GRANULARITY") or "PT60",
                    ))
                cur = {}
                el.clear()
            elif tag in KEEP:
                cur[tag] = el.text
    df = pd.DataFrame(rows, columns=[
        "date", "zone", "period", "purpose", "status", "price", "qty",
        "awarded_qty", "awarded_price", "merit_order", "unit_ref", "unit_kind",
        "operator", "granularity"])
    df.to_parquet(out_path, index=False)
    print(f"  parsed {len(df):,} IT offers -> {out_path.name}")
    return df


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="git-ignored raw/ scratch dir")
    ap.add_argument("--days", nargs="+", default=GME_DAYS,
                    help="market dates YYYY-MM-DD (default: the 7 frozen protocol days)")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    session, headers = make_session()
    rc = 0
    for d in args.days:
        ymd = d.replace("-", "")
        try:
            dest, n = fetch_day(session, headers, ymd, out)
            got = sha256(dest)
            ref = REF_RAW_SHA256.get(d)
            tag = "OK" if ref == got else ("no-ref" if ref is None else "DRIFT")
            print(f"{tag} {d}: {n/1e6:.1f} MB  sha256={got[:16]}…")
            if ref and ref != got:
                print(f"  ::warning:: raw zip sha256 differs from reference "
                      f"({ref[:16]}…) — GME re-export; parse output is what matters",
                      file=sys.stderr)
            parse_zip(dest, out / f"gme_{d}.parquet")
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {d}: {e}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
