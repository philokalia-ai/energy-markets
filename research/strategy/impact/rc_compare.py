"""Compare reclear results with the optimiser's predictions. usage: python -I rc_compare.py job1 job2 ..."""
import sys
import pandas as pd
from pathlib import Path
RC = Path.home() / "armada/em-team/strategy/runs/st-impact/rc"
out = []
for n in sys.argv[1:]:
    o = pd.read_csv(RC / f"{n}.out.csv"); p = pd.read_csv(RC / f"{n}.pred.csv"); m = p.merge(o, on="hour")
    m["dp"] = m.zone_price - m.pred_price; m["dq"] = m.accepted_mw - m.pred_q
    out.append(dict(job=n, hours=len(m), short=o.carve_short_mw.iloc[0], mae_p=m.dp.abs().mean(), max_p=m.dp.abs().max(),
                    n_gt5=(m.dp.abs() > 5).sum(), mae_q=m.dq.abs().mean(), pred_p=m.pred_price.mean(), rc_p=m.zone_price.mean()))
    if "-v" in sys.argv[0:1]:
        print(m.round(1).to_string())
print(pd.DataFrame(out).round(2).to_string())
