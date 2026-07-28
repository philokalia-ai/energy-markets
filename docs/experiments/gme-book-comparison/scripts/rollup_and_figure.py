#!/usr/bin/env python3
"""Roll the per-day summary TSVs into a cross-day headline table and draw one
illustrative supply-staircase figure (ours vs GME domestic production).

USAGE:
  python3 rollup_and_figure.py <data_dir>   # reads summary_*.tsv, staircase_*.tsv
"""
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


def parse_comp(s):
    a = [float(x) for x in s.split("/")]
    return pd.Series({"le0": a[0], "mid": a[1], "hi": a[2], "cap": a[3]})


def main():
    d = Path(sys.argv[1])
    summ = pd.concat([pd.read_csv(f, sep="\t") for f in sorted(d.glob("summary_*.tsv"))],
                     ignore_index=True)
    oc = summ["our_comp_le0/mid/hi/cap"].apply(parse_comp).add_prefix("our_")
    gc = summ["gme_comp_le0/mid/hi/cap"].apply(parse_comp).add_prefix("gme_")
    S = pd.concat([summ, oc, gc], axis=1)
    S["vol_ratio"] = S.our_sup_mw / S.gme_up_mw

    # headline rollup across all zone-hours
    roll = pd.DataFrame({
        "metric": ["offered supply MW (our / GME-UP)  ratio",
                   "share of supply offered at price <= 0",
                   "share of supply offered above 300 EUR/MWh (cap tail)",
                   "share of supply in mid band 0-150 EUR/MWh",
                   "GME real zonal clearing price (EUR/MWh)",
                   "our thermal SRMC marginal price at cleared depth (EUR/MWh)"],
        "ours": [round(S.vol_ratio.mean(), 2), round(S.our_le0.mean(), 2),
                 round(S.our_cap.mean(), 2), round(S.our_mid.mean(), 2),
                 "-", round(S.our_price_at_gme_clearedQ.mean(), 1)],
        "gme_real": ["1.00", round(S.gme_le0.mean(), 2), round(S.gme_cap.mean(), 2),
                     round(S.gme_mid.mean(), 2), round(S.gme_clear_price.mean(), 1), "-"],
    })
    roll.to_csv(d / "rollup.tsv", sep="\t", index=False)
    print(roll.to_string(index=False))

    # per-zone composition table (mean over days/hours)
    comp = S.groupby("zone")[["our_le0", "gme_le0", "our_mid", "gme_mid",
                              "our_hi", "gme_hi", "our_cap", "gme_cap",
                              "vol_ratio"]].mean().round(2)
    comp.to_csv(d / "composition_by_zone.tsv", sep="\t")

    # illustrative figure: NORD supply staircase, 2023-01-17, hours 4/12/19
    st = pd.read_csv(d / "staircase_20230117.tsv", sep="\t")
    nz = st[st.zone == "IT-NORTH"]
    fig, axes = plt.subplots(1, 3, figsize=(13, 4.2), sharey=True)
    for ax, h in zip(axes, [4, 12, 19]):
        for book, col, lab in [("ours", "#1f77b4", "Euphemia (synthetic)"),
                               ("gme_up", "#d62728", "GME real (UP_ prod.)")]:
            g = nz[(nz.hour == h) & (nz.book == book)].sort_values("cum_mw")
            ax.step(g.cum_mw / 1000, g.price, where="post", color=col, label=lab, lw=1.6)
        cp = summ[(summ.zone == "IT-NORTH") & (summ.hour == h) &
                  (summ.date == "2023-01-17")].gme_clear_price.iloc[0]
        ax.axhline(cp, ls="--", color="grey", lw=1)
        ax.set_title(f"NORD  {h:02d}:00  (real clears {cp:.0f})")
        ax.set_xlabel("cumulative offered GW")
        ax.set_ylim(-50, 700)
        if h == 4:
            ax.set_ylabel("offer price EUR/MWh")
            ax.legend(fontsize=8, loc="upper left")
        ax.grid(alpha=.3)
    fig.suptitle("Supply staircase: synthetic vs real GME book  (IT-NORTH, 2023-01-17)")
    fig.tight_layout()
    fig.savefig(d / "staircase_NORD_20230117.png", dpi=110)
    print(f"\nwrote rollup.tsv, composition_by_zone.tsv, staircase_NORD_20230117.png -> {d}")


if __name__ == "__main__":
    main()
