#!/usr/bin/env python3
"""Stream-parse a GME MGP OffertePubbliche zip into a compact per-offer parquet,
keeping only the 7 Italian physical bidding zones.

GME field semantics (confirmed against the published XSD + data, 2026-07):
  PURPOSE_CD : 'OFF' = sell offer (SUPPLY),  'BID' = purchase bid (DEMAND)
  STATUS_CD  : 'ACC' accepted, 'REJ' rejected, 'INC' partially/incl.  The full
               supply/demand curve is ALL statuses (accepted + rejected).
  ZONE_CD    : NORD CNOR CSUD SUD CALA SICI SARD (+ foreign virtual zones we drop)
  UNIT_REFERENCE_NO : UP_* production unit, UC_* consumption unit,
                      UVZ*/UCV* zonal virtual unit (imports / aggregated units)
  QUANTITY_NO / ENERGY_PRICE_NO : offered MWh and price (EUR/MWh) for the period
  AWARDED_QUANTITY_NO : cleared MWh ; MERIT_ORDER_NO : GME merit rank
  AWARDED_PRICE_NO : zonal clearing price (same for every offer in a zone-hour)
  hour field : INTERVAL_NO (1..24 hourly, files up to 2024) OR PERIOD (1..96
               15-min, 2025+ when GRANULARITY says PT15). We normalise both to
               `period` and record `granularity`.

Output columns: date, zone (GME code), period, purpose, status, price, qty,
  awarded_qty, awarded_price, merit_order, unit_ref, unit_kind, operator, granularity.

USAGE:
  python3 parse_gme_offers.py <zip> <out.parquet>
"""
import sys
import zipfile
import xml.etree.ElementTree as ET

import pandas as pd

IT_ZONES = {"NORD", "CNOR", "CSUD", "SUD", "CALA", "SICI", "SARD"}
KEEP = ("PURPOSE_CD", "TYPE_CD", "STATUS_CD", "ZONE_CD", "UNIT_REFERENCE_NO",
        "OPERATORE", "PERIOD", "INTERVAL_NO", "GRANULARITY", "QUANTITY_NO",
        "AWARDED_QUANTITY_NO", "ENERGY_PRICE_NO", "AWARDED_PRICE_NO",
        "MERIT_ORDER_NO", "BID_OFFER_DATE_DT")


def unit_kind(ref):
    if not ref:
        return "other"
    for p in ("UPV", "UP_", "UCV", "UC_", "UVZ"):
        if ref.startswith(p):
            return p.rstrip("_")
    return "other"


def parse_zip(zip_path, out_path):
    zf = zipfile.ZipFile(zip_path)
    name = [n for n in zf.namelist() if n.lower().endswith(".xml")][0]
    rows = []
    cur = {}
    with zf.open(name) as fh:
        for _ev, el in ET.iterparse(fh, events=("end",)):
            tag = el.tag
            if tag == "OfferteOperatori":
                if cur.get("ZONE_CD") in IT_ZONES:
                    def f(k):
                        v = cur.get(k)
                        return v
                    def ff(k):
                        try:
                            return float(cur.get(k))
                        except (TypeError, ValueError):
                            return None
                    ref = f("UNIT_REFERENCE_NO")
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
    print(f"{zip_path}: {len(df):,} IT offers -> {out_path}")
    print("  purpose x status:")
    print(df.groupby(["purpose", "status"]).size().to_string())
    return df


if __name__ == "__main__":
    parse_zip(sys.argv[1], sys.argv[2])
