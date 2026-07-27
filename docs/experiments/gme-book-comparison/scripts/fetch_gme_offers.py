#!/usr/bin/env python3
"""Download GME MGP "Offerte Pubbliche" (public bid/offer books) for a date range.

SOURCE (reverse-engineered 2026-07 from the public download page — no login required,
but a two-checkbox disclaimer must be accepted, which the site models as an
anti-forgery-token + `GmePolicy` cookie handshake that this script reproduces):

  Landing page (accept-terms gate, mints the tokens/cookies):
    GET https://www.mercatoelettrico.org/it-it/Home/Esiti/Elettricita/MGP/Download/OffertePubbliche
  Data endpoint (DNN ServicesFramework WebAPI, returns application/zip):
    GET https://www.mercatoelettrico.org/DesktopModules/GmeDownload/API/ExcelDownload/downloadzipfile
        ?DataInizio=YYYYMMDD&DataFine=YYYYMMDD&Date=YYYYMMDD
        &Mercato=MGP&Settore=OffertePubbliche&FiltroDate=InizioFine
    Required headers (all read off the landing page):
        ModuleId, TabId, RequestVerificationToken (paired with the
        __RequestVerificationToken cookie), userid
    Required cookies: those set by the landing GET + GmePolicy=true.
  The zip contains one file `YYYYMMDDMGPOffertePubbliche.xml` per requested day
  (a Microsoft DataSet dump; ~600 MB uncompressed for a full 39-zone day in 2026).

EMBARGO: bid/offer data is confidential for 7 days after the session date
  (Ministerial Decree 29 April 2009). Request only dates older than 7 days.

TERMS OF USE (mercatoelettrico.org "Condizioni di utilizzo"): data are provided
  free for consultation with a warranty exclusion; any use in violation of the
  General Conditions is prohibited, and downstream users must accept the same
  terms. => We do NOT commit or redistribute raw GME files; this repo carries
  only derived aggregate statistics. Keep the raw XML/zip in a git-ignored
  scratch directory.

USAGE:
  python3 fetch_gme_offers.py 2023-01-17 2023-07-19 --out /path/to/scratch
Each date is downloaded as <out>/<YYYYMMDD>MGP_OffertePubbliche.zip .
"""
import argparse
import re
import sys
from pathlib import Path

import requests

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
LANDING = ("https://www.mercatoelettrico.org/it-it/Home/Esiti/Elettricita/"
           "MGP/Download/OffertePubbliche")
API = ("https://www.mercatoelettrico.org/DesktopModules/GmeDownload/API/"
       "ExcelDownload/downloadzipfile")


def make_session():
    """Open a session, accept the disclaimer, return (session, headers)."""
    s = requests.Session()
    s.headers["User-Agent"] = UA
    r = s.get(LANDING, timeout=60)
    r.raise_for_status()
    html = r.text
    # Anti-forgery field value (paired with the __RequestVerificationToken cookie
    # that the GET above already dropped into the session jar).
    m = re.search(r'name="__RequestVerificationToken"[^>]*value="([^"]*)"', html)
    if not m:
        raise RuntimeError("could not find __RequestVerificationToken on landing page")
    rvt = m.group(1)
    module_id = (re.search(r'"ModuleId":(\d+)', html) or [None, "12067"])[1]
    tab_id = (re.search(r'"TabId":(\d+)', html) or [None, "1706"])[1]
    # Accept the two-checkbox disclaimer (the page sets this cookie client-side).
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
        raise RuntimeError(f"{yyyymmdd}: unexpected response "
                           f"{r.status_code} {r.headers.get('Content-Type')} "
                           f"{r.content[:200]!r}")
    dest = Path(out_dir) / f"{yyyymmdd}MGP_OffertePubbliche.zip"
    dest.write_bytes(r.content)
    return dest, len(r.content)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dates", nargs="+", help="market dates YYYY-MM-DD (>7 days old)")
    ap.add_argument("--out", required=True, help="git-ignored scratch dir")
    args = ap.parse_args()
    Path(args.out).mkdir(parents=True, exist_ok=True)
    session, headers = make_session()
    for d in args.dates:
        ymd = d.replace("-", "")
        try:
            dest, n = fetch_day(session, headers, ymd, args.out)
            print(f"OK {d}: {n/1e6:.1f} MB -> {dest}")
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {d}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
