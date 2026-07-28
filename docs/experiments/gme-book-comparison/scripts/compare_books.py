#!/usr/bin/env python3
"""Compare our synthetic Euphemia order book against the real GME MGP book.

Per Italian zone-hour we build the SUPPLY staircase (cumulative offered MW vs
price) for both books and measure where and how they differ. The physical
apples-to-apples curve is our DOMESTIC stack (unit ladders + AGG aggregates +
RES) against GME's domestic production offers (UNIT_REFERENCE_NO starting UP_,
STATUS in ACC/REJ/INC — the final valid submissions; REP/REV are superseded
prior versions of the same unit and are dropped). GME's UVZ virtual-zonal
offers (imports / aggregated non-relevant units) are reported separately: our
per-zone book has no IMPORT layer here, so mixing them would not be comparable.

Zone map:  IT-NORTH=NORD  IT-CNORTH=CNOR  IT-CSOUTH=CSUD  IT-SOUTH=SUD
           IT-Calabria=CALA  IT-Sicily=SICI  IT-Sardinia=SARD
Hour map:  our ts hour H  <->  GME INTERVAL_NO / PERIOD = H+1

Outputs (TSV, derived aggregates only — no raw GME rows):
  quantiles_<date>.tsv   shape + absolute-depth price quantiles, per zone-hour
  summary_<date>.tsv     one row per zone-hour: volumes, clearing prices, markup
  staircase_<date>.tsv   downsampled (cum_mw, price) points for plotting
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

ZMAP = {"IT-NORTH": "NORD", "IT-CNORTH": "CNOR", "IT-CSOUTH": "CSUD",
        "IT-SOUTH": "SUD", "IT-Calabria": "CALA", "IT-Sicily": "SICI",
        "IT-Sardinia": "SARD"}
HOURS = [4, 12, 19]
FINAL = {"ACC", "REJ", "INC"}          # valid final submissions (drop REP/REV)
# No single Italian generation-unit tranche exceeds a few GW; larger rows are
# corrupt registry capacities (e.g. BUSSI19 = 13,068,005 MW). Drop + count them.
MW_OUTLIER = 5000.0


def staircase(price, mw):
    """Return sorted (price_asc) cumulative-MW staircase as (cum, price) arrays."""
    o = np.argsort(price, kind="stable")
    p = np.asarray(price)[o]
    q = np.asarray(mw)[o]
    return np.cumsum(q), p


def price_at_depth(cum, price, depth_mw):
    """Marginal offer price at a given cumulative MW depth (step function)."""
    i = np.searchsorted(cum, depth_mw, side="left")
    if i >= len(price):
        return np.nan
    return float(price[i])


def load_our(book_path, our_zone, hour):
    df = pd.read_parquet(book_path, columns=["zone", "ts", "side", "price", "mw", "owner"])
    ts = pd.Timestamp(f"{Path(book_path).stem} {hour:02d}:00:00")
    sub = df[(df.zone == our_zone) & (df.ts == ts)]
    sup = sub[sub.side == "supply"]
    dem = sub[sub.side == "demand"]
    bad = sup[sup.mw > MW_OUTLIER]
    dropped = float(bad.mw.sum())
    sup = sup[sup.mw <= MW_OUTLIER]
    return sup, dem, dropped


def load_gme(gme_df, gme_zone, hour):
    interval = hour + 1
    z = gme_df[(gme_df.zone == gme_zone) & (gme_df.period == interval)]
    off = z[(z.purpose == "OFF") & (z.status.isin(FINAL))]
    up = off[off.unit_kind == "UP"]          # domestic production
    uvz = off[off.unit_kind == "UVZ"]        # virtual / import layer
    bid = z[(z.purpose == "BID") & (z.status.isin(FINAL))]
    cprice = off.loc[off.status == "ACC", "awarded_price"].max()
    dem_cleared = bid.loc[bid.status == "ACC", "awarded_qty"].sum()
    sup_cleared = off.loc[off.status == "ACC", "awarded_qty"].sum()
    return off, up, uvz, bid, cprice, dem_cleared, sup_cleared


def main():
    date = sys.argv[1]                          # YYYY-MM-DD
    book_path = sys.argv[2]                      # data/books_cv23/<date>.parquet
    gme_parquet = sys.argv[3]                    # scratch gme_<YYYYMMDD>.parquet
    out_dir = Path(sys.argv[4]); out_dir.mkdir(parents=True, exist_ok=True)
    gme_df = pd.read_parquet(gme_parquet)

    q_rows, s_rows, stair_rows = [], [], []
    shape_pctls = [10, 25, 50, 75, 90]
    depths = [2000, 5000, 10000, 15000, 20000]

    for oz, gz in ZMAP.items():
        for h in HOURS:
            sup, dem, dropped_mw = load_our(book_path, oz, h)
            if len(sup) == 0:
                continue
            off, up, uvz, bid, cprice, dem_cl, sup_cl = load_gme(gme_df, gz, h)
            if len(up) == 0:
                continue

            our_cum, our_p = staircase(sup.price.values, sup.mw.values)
            up_cum, up_p = staircase(up.price.values, up.qty.values)
            our_tot, up_tot = our_cum[-1], up_cum[-1]
            uvz_tot = float(uvz.qty.sum())

            # shape: price at pctl of own offered volume
            for pc in shape_pctls:
                op = price_at_depth(our_cum, our_p, pc / 100 * our_tot)
                gp = price_at_depth(up_cum, up_p, pc / 100 * up_tot)
                q_rows.append([date, oz, h, "shape_pctl", pc, round(op, 2),
                               round(gp, 2), round(gp - op, 2)])
            # absolute depth
            for d in depths:
                op = price_at_depth(our_cum, our_p, d)
                gp = price_at_depth(up_cum, up_p, d)
                q_rows.append([date, oz, h, "abs_depth_mw", d,
                               None if np.isnan(op) else round(op, 2),
                               None if np.isnan(gp) else round(gp, 2),
                               None if (np.isnan(op) or np.isnan(gp)) else round(gp - op, 2)])

            # implied clearing on our book (supply meets our demand qty)
            our_dem_mw = float(dem.mw.sum())
            our_clear = price_at_depth(our_cum, our_p, our_dem_mw)
            # our supply price at the depth GME actually cleared domestically
            our_at_gme_cleared = price_at_depth(our_cum, our_p, sup_cl)

            # composition: share of offered supply MW by price band
            def bands(cum, price, tot):
                pr = np.asarray(price)
                q = np.diff(np.concatenate([[0], cum]))
                le0 = q[pr <= 0].sum() / tot
                mid = q[(pr > 0) & (pr <= 150)].sum() / tot
                hi = q[(pr > 150) & (pr <= 300)].sum() / tot
                cap = q[pr > 300].sum() / tot
                return le0, mid, hi, cap
            o_le0, o_mid, o_hi, o_cap = bands(our_cum, our_p, our_tot)
            g_le0, g_mid, g_hi, g_cap = bands(up_cum, up_p, up_tot)

            # marginal-region markup: avg offer price in the 80-100% depth of the
            # domestic quantity the real market actually cleared
            def marg(cum, price, q0, q1):
                m = (cum >= q0) & (cum <= q1)
                return float(np.mean(price[m])) if m.any() else np.nan
            lo, hi_ = 0.8 * sup_cl, sup_cl
            our_marg = marg(our_cum, our_p, lo, hi_)
            gme_marg = marg(up_cum, up_p, lo, hi_)

            # supply offered at or below the REAL clearing price P* (residual
            # direction): if ours >> GME, our book has more cheap supply and
            # would under-price the zone at the same net demand.
            def mw_below(price, mw, thr):
                pr = np.asarray(price)
                return float(np.asarray(mw)[pr <= thr].sum())
            if pd.notna(cprice):
                our_below = mw_below(sup.price.values, sup.mw.values, cprice)
                gme_below = mw_below(up.price.values, up.qty.values, cprice)
            else:
                our_below = gme_below = np.nan

            s_rows.append([date, oz, gz, h,
                           round(our_tot, 0), round(up_tot, 0), round(uvz_tot, 0),
                           round(dropped_mw, 0),
                           round(our_dem_mw, 0), round(dem_cl, 0), round(sup_cl, 0),
                           round(cprice, 2) if pd.notna(cprice) else None,
                           round(our_clear, 2) if pd.notna(our_clear) else None,
                           round(our_at_gme_cleared, 2) if pd.notna(our_at_gme_cleared) else None,
                           round(our_below, 0) if pd.notna(our_below) else None,
                           round(gme_below, 0) if pd.notna(gme_below) else None,
                           round(our_marg, 2) if pd.notna(our_marg) else None,
                           round(gme_marg, 2) if pd.notna(gme_marg) else None,
                           round((gme_marg - our_marg), 2) if pd.notna(gme_marg) and pd.notna(our_marg) else None,
                           f"{o_le0:.2f}/{o_mid:.2f}/{o_hi:.2f}/{o_cap:.2f}",
                           f"{g_le0:.2f}/{g_mid:.2f}/{g_hi:.2f}/{g_cap:.2f}"])

            # staircase sample (~50 pts each) for plotting
            for label, cum, pr in [("ours", our_cum, our_p), ("gme_up", up_cum, up_p)]:
                idx = np.linspace(0, len(pr) - 1, min(50, len(pr))).astype(int)
                for i in idx:
                    stair_rows.append([date, oz, h, label, round(float(cum[i]), 1),
                                       round(float(pr[i]), 2)])

    qcols = ["date", "zone", "hour", "kind", "level", "our_price", "gme_price", "gme_minus_our"]
    scols = ["date", "zone", "gme_zone", "hour", "our_sup_mw", "gme_up_mw",
             "gme_uvz_mw", "our_dropped_badMW", "our_dem_mw", "gme_dem_cleared",
             "gme_sup_cleared", "gme_clear_price", "our_implied_clear",
             "our_price_at_gme_clearedQ", "our_mw_below_P*", "gme_up_mw_below_P*",
             "our_marg_price", "gme_marg_price", "marg_markup_gme_minus_our",
             "our_comp_le0/mid/hi/cap", "gme_comp_le0/mid/hi/cap"]
    ymd = date.replace("-", "")
    pd.DataFrame(q_rows, columns=qcols).to_csv(out_dir / f"quantiles_{ymd}.tsv", sep="\t", index=False)
    pd.DataFrame(s_rows, columns=scols).to_csv(out_dir / f"summary_{ymd}.tsv", sep="\t", index=False)
    pd.DataFrame(stair_rows, columns=["date", "zone", "hour", "book", "cum_mw", "price"]
                 ).to_csv(out_dir / f"staircase_{ymd}.tsv", sep="\t", index=False)
    print(f"wrote quantiles/summary/staircase for {date} -> {out_dir}")
    print(pd.DataFrame(s_rows, columns=scols).to_string())


if __name__ == "__main__":
    main()
