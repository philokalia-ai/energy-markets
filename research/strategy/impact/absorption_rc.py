"""Reclear verification of competitive (cost-reflective) battery schedules.
  jobs:  python -I absorption_rc.py jobs  -> writes rc/<day>_<zone>_<S>_abs_competitive.csv (+ .pred.csv), prints names
  check: python -I absorption_rc.py check -> per job: curve vs reclear price, and the price-taker optimality gap at the
         reclear prices (value of the best price-taking schedule at those prices minus the competitive schedule's value,
         % of the latter): ~0 = the schedule is what legs priced at opportunity cost would clear to."""
import sys
from pathlib import Path
import numpy as np, pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV, rdopt as R, absorption as A  # noqa: E402
RC = MV.ROOT / "runs/st-impact/rc"
DAYS, ZONES, SIZES = ["2026-09-13", "2026-10-25"], A.ZONES, [1000, 4000]
names = [f"{d}_{z}_{S}_abs_competitive" for d in DAYS for z in ZONES for S in SIZES]
if sys.argv[1] == "jobs":
    for d in DAYS:
        for z in ZONES:
            cs, pbase = A.curves_for(d, z)
            for S in SIZES:
                u, _, _ = R.energy_dp(cs, 0.0, 2.0 * S, S, S, A.ETA, 0.0, de=S / 8.0, objective="welfare")
                n = f"{d}_{z}_{S}_abs_competitive"
                pd.DataFrame([(d, z, h, "inj", float(np.sign(x)), abs(float(x))) for h, x in enumerate(u)],
                             columns=["day", "zone", "hour", "kind", "price", "mw"]).to_csv(RC / f"{n}.csv", index=False)
                pd.DataFrame([(h, float(c.P(x)), float(x), pbase[h]) for h, (c, x) in enumerate(zip(cs, u))],
                             columns=["hour", "pred_price", "pred_q", "p_base"]).to_csv(RC / f"{n}.pred.csv", index=False)
    print(",".join(names))
else:
    rows = []
    for n in names:
        if not (RC / f"{n}.out.csv").exists():
            continue
        o = pd.read_csv(RC / f"{n}.out.csv"); p = pd.read_csv(RC / f"{n}.pred.csv")
        S = int(n.split("_abs_")[0].rsplit("_", 1)[1]); u = p.pred_q.values; Prc = o.zone_price.values
        cs = [R.ResidualDemand(np.array([-1e4, 1e4]), np.array([0.0, 0.0])) for _ in range(24)]  # dummy (price-taker)
        _, _, vbest = R.energy_dp(cs, 0.0, 2.0 * S, S, S, A.ETA, 0.0, de=S / 8.0, impact=False, pt_prices=Prc)
        v = float(Prc @ u)
        rows.append(dict(job=n, mae_p=float(np.abs(Prc - p.pred_price).mean()), max_p=float(np.abs(Prc - p.pred_price).max()),
                         value_rc=v, best_pt_value=float(vbest), opt_gap_pct=100 * (vbest - v) / max(abs(v), 1.0)))
    t = pd.DataFrame(rows).round(2)
    t.to_csv(MV.ROOT / "runs/st-impact/tables/rc_check_absorption.csv", index=False)
    print(t.to_string())
