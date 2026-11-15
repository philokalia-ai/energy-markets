"""Phase 2 dose-response: is a covariate arm's response monotone and roughly proportional to the shift?

On a few test days (same inputs as the backtest, D-1 context), perturb only the delivery-day covariates:
  gr_load_<MW>   residual load GR += MW (sim fixed), MW in {-574, 287, 574, 1148, 2296}
  sim_<x>        sim x (1 + x) for the ZONES subset, x in {-0.2, -0.1, +0.1, +0.2, +0.4}
  load_<x>       residual load x (1 + x) for the ZONES subset (sim fixed), same x
and record Δmedian forecast per zone-hour. For `physresid` the forecast adds back the (perturbed) sim.

Usage: python dose_response.py --arm phys|physresid [--days ...] [--threads 8]
       python dose_response.py --summary phys physresid
Output: $TSFM_OUT/dose_<arm>.parquet (arm, market_date, test, dose, zone, t, dsim, dload, dfc).
"""
import argparse, os, sys, time
from datetime import date
import numpy as np, pandas as pd, torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_tsfm as R

DAYS = ["2026-09-22", "2026-10-08", "2026-10-24", "2026-11-09"]
ZONES = ["GR", "DE_LU", "ES", "FR", "IT-NORTH", "PL", "SE3", "HU"]
GR_MW = [-574, 287, 574, 1148, 2296]
X = [-0.2, -0.1, 0.1, 0.2, 0.4]


def summary(arms):
    """Mean Δforecast per dose; response per unit dose (€/MWh per 100 MW, or pass-through for sim)."""
    for arm in arms:
        p = pd.read_parquet(f"{R.OUT}/dose_{arm}.parquet")
        g = p.groupby(["test", "dose"]).agg(dsim=("dsim", "mean"), dload=("dload", "mean"), dfc=("dfc", "mean"),
                                            frac_up=("dfc", lambda x: (x > 0).mean())).reset_index()
        g["per_unit"] = np.where(g.test == "sim", g.dfc / g.dsim, 100 * g.dfc / g.dload)
        print(f"== {arm}  (per_unit: sim -> pass-through; load tests -> EUR/MWh per 100 MW)")
        print(g.round(3).to_string(index=False))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--summary":
        return summary(sys.argv[2:])
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=["phys", "physresid"])
    ap.add_argument("--days", default=",".join(DAYS))
    ap.add_argument("--threads", type=int, default=8)
    a = ap.parse_args()
    torch.set_num_threads(a.threads)
    R.CTX = 2048
    zones, grid, wide = R.load_inputs()
    m = R.Model("t209")
    zi = np.array([zones.index(z) for z in ZONES])
    gi = zones.index("GR")
    rows = []
    for ds in a.days.split(","):
        d = date.fromisoformat(ds)
        ctx, known, H, nD, cutoff, s_D, simD = R.build_inputs(d, a.arm, zones, grid, wide, 1)
        hours = pd.date_range(s_D, periods=nD, freq="h")
        simH, loadH = np.nan_to_num(known[:, 0, -nD:]), np.nan_to_num(known[:, 1, -nD:])
        tests = [("base", 0, zi, 0.0, 0.0)]
        tests += [("gr_load", mw, np.array([gi]), 0.0, float(mw)) for mw in GR_MW]
        tests += [("sim", x, zi, x, 0.0) for x in X]
        tests += [("load", x, zi, 0.0, x) for x in X]
        cts, kns, meta = [], [], []
        for name, dose, sel, xs, xl in tests:
            k = known[sel].copy()
            dsim = xs * simH[sel]
            dload = np.full((len(sel), nD), xl) if name == "gr_load" else xl * loadH[sel]
            k[:, 0, -nD:] += dsim
            k[:, 1, -nD:] += dload
            cts.append(ctx[sel]); kns.append(k); meta.append((name, dose, sel, dsim, dload))
        t0 = time.time()
        q, lv = m.forecast(np.concatenate(cts).astype(np.float32), H, np.concatenate(kns).astype(np.float32))
        med = q[:, H - nD:, int(np.argmin(np.abs(lv - 0.5)))]
        if a.arm == "physresid":
            med = med + np.concatenate([np.nan_to_num(simD[sel]) + dsim for _, _, sel, dsim, _ in meta])
        off, base = 0, {}
        for name, dose, sel, dsim, dload in meta:
            blk = med[off:off + len(sel)]; off += len(sel)
            if name == "base":
                base = {z: blk[i] for i, z in enumerate(sel)}; continue
            for i, z in enumerate(sel):
                for h in range(nD):
                    rows.append((a.arm, ds, name, dose, zones[z], hours[h], float(dsim[i, h]), float(dload[i, h]),
                                 float(blk[i, h] - base[z][h])))
        print(f"{ds} batch={off} {time.time() - t0:.1f}s", flush=True)
    out = pd.DataFrame(rows, columns=["arm", "market_date", "test", "dose", "zone", "t", "dsim", "dload", "dfc"])
    out.to_parquet(f"{R.OUT}/dose_{a.arm}.parquet")
    print(f"wrote dose_{a.arm}.parquet rows={len(out)}")


if __name__ == "__main__":
    main()
