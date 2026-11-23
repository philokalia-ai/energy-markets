"""Part B scoring. usage: python -I mv_score.py   (after mv_run.py)
Fit on calibration days only, score on evaluation days:
  M1 m-table   flat markup over SRMC on flexible thermal, m = median implied m by zone x band x marginal tech
               (>= 5 uncensored cal obs, else zone x band, else no change); price from the m-grid (coupled curve)
  M2 strategic p_base + theta_z (P_cournot(largest fossil firm) - p_base), theta_z in [0,1] by cal MAE
  REF bias     p_base + mean cal error by zone x band (a pure level correction, the yardstick a markup model must beat)
Share of the miss explained = 1 - MAE(model) / MAE(base) per zone, day-block bootstrap 90% (ratio of resampled sums).
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import mv_run as M  # noqa: E402

RUN = MV.ROOT / "runs/st-impact"
TAB = RUN / "tables"


def m_pred_price(r, m):
    cols = [c for c in r.index if c.startswith("p_m")]
    ms = np.array([float(c[3:]) for c in cols])
    ps = np.array([r[c] for c in cols], float)
    ok = ~np.isnan(ps)
    if np.isnan(m) or ok.sum() < 2 or m < ms[ok].min() or m > ms[ok].max():
        return np.nan
    return float(np.interp(m, ms[ok], ps[ok]))


def share_ci(g, col, n=5000, seed=7):
    d = g.groupby("day").apply(lambda x: pd.Series({"b": (x.p_real - x.p_base).abs().sum(),
                                                    "m": (x.p_real - x[col]).abs().sum()}))
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(d), size=(n, len(d)))
    b, m = d.b.values[idx].sum(1), d.m.values[idx].sum(1)
    s = 1 - m / b
    return 1 - d.m.sum() / d.b.sum(), np.quantile(s, 0.05), np.quantile(s, 0.95)


if __name__ == "__main__":
    H = pd.read_csv(RUN / "mv/hours.csv", keep_default_na=True)
    H["f_real"] = H.f_real.fillna("")
    cal, ev = H[H.day.isin(M.CAL)].copy(), H[~H.day.isin(M.CAL)].copy()
    t3, t2, mhat, theta = M.fit_and_score(H)
    bias = cal.assign(e=cal.p_real - cal.p_base).groupby(["zone", "band"]).e.mean()
    for D in (cal, ev):
        D["m_hat"] = [mhat(r) for r in D.itertuples()]
        D["p_M1"] = [m_pred_price(r, m) for (_, r), m in zip(D.iterrows(), D.m_hat)]
        D["M1_applied"] = D.p_M1.notna()
        D["p_M1"] = D.p_M1.fillna(D.p_base)
        D["p_M2"] = D.p_base + D.zone.map(theta).fillna(0) * (D.p_cournot_top - D.p_base).fillna(0)
        D["p_REF"] = D.p_base + [bias.get((z, b), 0.0) for z, b in zip(D.zone, D.band)]
    # tables
    desc = []
    for (st, D) in (("cal", cal), ("eval", ev)):
        for (z, b, t), g in D.groupby(["zone", "band", "tech"]):
            ok = g[(g.f_real == "") & g.m_real.notna()]
            desc.append(dict(set=st, zone=z, band=b, tech=t, n=len(g), uncensored=len(ok),
                             m_book_med=g.m_book.median(), m_real_med=ok.m_real.median() if len(ok) else np.nan,
                             m_real_p25=ok.m_real.quantile(.25) if len(ok) else np.nan,
                             m_real_p75=ok.m_real.quantile(.75) if len(ok) else np.nan,
                             cens_lo=(g.f_real == "lo").mean(), cens_hi=(g.f_real == "hi").mean()))
    desc = pd.DataFrame(desc)
    desc.to_csv(TAB / "mv_implied_markups.csv", index=False)
    sc = []
    for z, g in ev.groupby("zone"):
        row = dict(zone=z, days=g.day.nunique(), hours=len(g), mae_base=(g.p_real - g.p_base).abs().mean(),
                   bias_base=(g.p_real - g.p_base).mean(), theta=theta.get(z, np.nan),
                   M1_applied_share=g.M1_applied.mean())
        for c in ["p_M1", "p_M2", "p_REF"]:
            row[c[2:] + "_mae"] = (g.p_real - g[c]).abs().mean()
            row[c[2:] + "_share"] = "%+.3f [%+.3f, %+.3f]" % share_ci(g, c)
        sc.append(row)
    sc = pd.DataFrame(sc)
    sc.to_csv(TAB / "mv_share_explained.csv", index=False)
    pd.set_option("display.width", 250)
    print(sc.round(2).to_markdown(index=False))
    wide = desc[desc.set.isin(["cal", "eval"])].pivot_table(index=["zone", "tech"], columns="set",
                                                           values=["m_book_med", "m_real_med", "n"], aggfunc="median")
    print(wide.round(2).to_markdown())
    cal.to_csv(RUN / "mv/hours_cal_scored.csv", index=False)
    ev.to_csv(RUN / "mv/hours_eval_scored.csv", index=False)
