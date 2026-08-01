#!/usr/bin/env python3
"""Published-books clearing validation — CONVERTER (raw exchange books -> engine intermediate).

See docs/experiments/pubbooks-clearing/protocol.md (frozen). Reads the raw,
NON-redistributable GME/OMIE downloads from $PUBBOOKS_DIR and the read-only
DuckDB extract; writes a data-free-CODE-produced intermediate (per-cell order
lists + official price + net position) to $PUBBOOKS_DIR/intermediate/. NO raw
row is committed; the intermediate is derived data and stays in the scratchpad.

Outputs (TSV, per exchange):
  <ex>_orders.tsv : exchange zone day hour side price mw
  <ex>_cells.tsv  : exchange zone day hour p_off net_import_mw awarded_sup_mw espt_eq

Env:
  PUBBOOKS_DIR   dir holding raw/ (default: this file's ../../.. scratch is NOT
                 assumed; must be set to the pubbooks dir)
  EUPHEMIA_DUCKDB_PATH  read-only extract (for OMIE official ES/PT price + flows)
"""
import os, sys, zipfile
from pathlib import Path
import numpy as np
import pandas as pd

PUB = Path(os.environ["PUBBOOKS_DIR"])
RAW = PUB / "raw"
OUT = PUB / "intermediate"
OUT.mkdir(exist_ok=True)
EXTRACT = os.environ.get("EUPHEMIA_DUCKDB_PATH",
                         "/home/pgeorgakopoulos/armada/energy-markets/data/extracts/euphemia-live.duckdb")

GME_DAYS = ["2025-01-15", "2025-04-15", "2025-07-15", "2025-10-15",
            "2026-01-15", "2026-04-15", "2026-07-15"]
GME_ZONES = ["NORD", "CNOR", "CSUD", "SUD", "CALA", "SICI", "SARD"]
FINAL = {"ACC", "REJ", "INC"}

# OMIE: 5/15/25 of each month + 10th of 202501,202504  (20 days, protocol §2)
OMIE_MONTHS = ["202501", "202504", "202507", "202510", "202601", "202604"]
OMIE_DAYS = []
for ym in OMIE_MONTHS:
    for d in ("05", "15", "25"):
        OMIE_DAYS.append(f"{ym[:4]}-{ym[4:6]}-{d}")
OMIE_DAYS += ["2025-01-10", "2025-04-10"]
OMIE_DAYS = sorted(OMIE_DAYS)

PRICE_CEIL = 4000.0
PRICE_FLOOR = -500.0


def write_orders(orows, fname):
    """Merge steps at the identical (cell, side, price) by summing MW — exact for
    the uniform-price clearing price and cleared volume, shrinks the MIP ~4x.
    Disclosed in protocol/results as a performance-equivalent aggregation."""
    df = pd.DataFrame(orows, columns=["exchange", "zone", "day", "hour",
                                      "side", "price", "mw"])
    df = df.groupby(["exchange", "zone", "day", "hour", "side", "price"],
                    as_index=False).mw.sum()
    df.to_csv(OUT / fname, sep="\t", index=False)
    print(f"  {fname}: {len(df)} merged order rows")


# ------------------------------------------------------------------ GME
def prep_gme():
    orows, crows = [], []
    for day in GME_DAYS:
        pq = RAW / f"gme_{day.replace('-','')}.parquet"
        if not pq.exists():
            print(f"  GME {day}: no parquet — skipped", file=sys.stderr)
            continue
        g = pd.read_parquet(pq)
        for z in GME_ZONES:
            for per in range(1, 25):
                hour = per - 1
                gz = g[(g.zone == z) & (g.status.isin(FINAL)) & (g.period == per)]
                if not len(gz):
                    continue
                sup = gz[(gz.purpose == "OFF") & (gz.unit_kind.isin(["UP", "UPV"]))]
                dem = gz[gz.purpose == "BID"].copy()
                dem.loc[dem.price <= 0, "price"] = PRICE_CEIL  # price-taker -> ceiling
                ap = gz.awarded_price.dropna()
                ap = ap[ap > 0]
                if len(sup) == 0 or not len(ap):
                    continue
                pstar = float(ap.mode().iat[0])
                aw_sup = float(gz[gz.purpose == "OFF"].awarded_qty.fillna(0).sum())
                aw_dem = float(gz[gz.purpose == "BID"].awarded_qty.fillna(0).sum())
                net_import = aw_dem - aw_sup
                for p, q in zip(sup.price.values, sup.qty.values):
                    orows.append(("GME", z, day, hour, "supply", float(p), float(q)))
                for p, q in zip(dem.price.values, dem.qty.values):
                    orows.append(("GME", z, day, hour, "demand", float(p), float(q)))
                crows.append(("GME", z, day, hour, pstar, net_import, aw_sup, 1))
    write_orders(orows, "gme_orders.tsv")
    pd.DataFrame(crows, columns=["exchange", "zone", "day", "hour", "p_off",
                                 "net_import_mw", "awarded_sup_mw", "espt_eq"]) \
        .to_csv(OUT / "gme_cells.tsv", sep="\t", index=False)
    print(f"GME: {len(crows)} cells")


# ------------------------------------------------------------------ OMIE
def parse_omie_day(day):
    ym = day[:4] + day[5:7]
    z = zipfile.ZipFile(RAW / f"curva_pbc_uof_{ym}.zip")
    cands = [n for n in z.namelist() if day.replace("-", "") in n]
    if not cands:
        return None
    txt = z.read(cands[0]).decode("latin-1")
    rows = []
    for ln in txt.splitlines():
        p = ln.split(";")
        if len(p) < 8:
            continue
        raw = p[0].strip()
        if raw.isdigit():
            key = f"P{int(raw)}"
        elif raw.startswith("H") and "Q" in raw:
            key = raw
        else:
            continue
        q = float(p[5].replace(".", "").replace(",", "."))
        pr = float(p[6].replace(".", "").replace(",", "."))
        rows.append((key, p[4].strip(), q, pr, p[7].strip()))
    return pd.DataFrame(rows, columns=["period", "tipo", "mw", "price", "oc"])


def prep_omie():
    import duckdb
    con = duckdb.connect(EXTRACT, read_only=True)
    orows, crows = [], []
    for day in OMIE_DAYS:
        od = parse_omie_day(day)
        if od is None:
            print(f"  OMIE {day}: no curve file — skipped", file=sys.stderr)
            continue
        nxt = (pd.Timestamp(day) + pd.Timedelta(days=1)).strftime("%Y-%m-%d")
        # Take the minute-0 price of each hour — the hourly PT60M row before
        # 2025-10-01 and the first quarter (Q1, matching the first-MTU curve)
        # of the PT15M rows after Spain's 15-min settlement go-live.
        esp = con.execute(f"""select extract(hour from date_time_utc) h, price_currency_mwh p
            from entsoe.energy_prices where map_code='ES' and extract(minute from date_time_utc)=0
            and date_time_utc>='{day}' and date_time_utc<'{nxt}' order by 1""").df()
        ptp = con.execute(f"""select extract(hour from date_time_utc) h, price_currency_mwh p
            from entsoe.energy_prices where map_code='PT' and extract(minute from date_time_utc)=0
            and date_time_utc>='{day}' and date_time_utc<'{nxt}' order by 1""").df()
        es = dict(zip(esp.h.astype(int), esp.p)); pt = dict(zip(ptp.h.astype(int), ptp.p))
        # net Iberian export per UTC hour from physical flows (PT15M -> hourly mean)
        nf = con.execute(f"""
          with f as (select date_time_utc, out_area_map_code o, in_area_map_code i, flow_mw
             from entsoe.physical_flows where date_time_utc>='{day}' and date_time_utc<'{nxt}'
             and resolution_code='PT15M'
             and (out_area_map_code in ('ES','PT') or in_area_map_code in ('ES','PT')))
          select extract(hour from date_time_utc) h,
            avg(case when o in ('ES','PT') and i not in ('ES','PT') then flow_mw else 0 end)
          - avg(case when i in ('ES','PT') and o not in ('ES','PT') then flow_mw else 0 end) net_exp
          from f group by 1 order by 1""").df()
        net = dict(zip(nf.h.astype(int), nf.net_exp))
        per15 = od.period.str.startswith("H").any()
        for hl in range(24):
            per = f"H{hl+1}Q1" if per15 else f"P{hl+1}"
            oh = od[(od.period == per) & (od.oc == "O")]
            sup = oh[oh.tipo == "V"]; dem = oh[oh.tipo == "C"]
            if len(sup) == 0 or len(dem) == 0:
                continue
            utc = (hl - 1) % 24               # local CET/CEST -> UTC (all sample days honour -1/-2? use -1 winter)
            # Both sample-month offsets: Jan/Oct winter -1, Apr/Jul summer -2.
            month = int(day[5:7]); utc = (hl - (2 if 4 <= month <= 10 else 1)) % 24
            p_off = es.get(utc, np.nan)
            espt = 1 if (utc in es and utc in pt and abs(es[utc] - pt[utc]) < 0.01) else 0
            net_exp = net.get(utc, 0.0)
            for p, q in zip(sup.price.values, sup.mw.values):
                orows.append(("OMIE", "IBERIA", day, hl, "supply", float(p), float(q)))
            for p, q in zip(dem.price.values, dem.mw.values):
                orows.append(("OMIE", "IBERIA", day, hl, "demand", float(p), float(q)))
            # net export -> price-taker DEMAND at ceiling; net import -> supply at floor
            crows.append(("OMIE", "IBERIA", day, hl, p_off, -net_exp, np.nan, espt))
    write_orders(orows, "omie_orders.tsv")
    pd.DataFrame(crows, columns=["exchange", "zone", "day", "hour", "p_off",
                                 "net_import_mw", "awarded_sup_mw", "espt_eq"]) \
        .to_csv(OUT / "omie_cells.tsv", sep="\t", index=False)
    print(f"OMIE: {len(crows)} cells")


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "both"
    if which in ("gme", "both"):
        prep_gme()
    if which in ("omie", "both"):
        prep_omie()
