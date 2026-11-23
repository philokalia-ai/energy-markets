"""Score the strategic-block reclears. usage: python -I blocks_score.py  (all *_blk_*.out.csv in runs/st-impact/rc)
Per job: company volume q_t = accepted MW from the full reclear, price P_t = the reclear's zone price.
  sim             Σ P_t q_t − C_t(q_t)
  realised+impact Σ (P_t + p_real,t − p_base,t) q_t − C_t(q_t)   (volumes fixed at the reclear; the curve-based score of
                  Part A re-clears volumes on the shifted curve instead — both shown for arms a/b)
Blocks: accepted families; PRB = rejected, in the money at the reclear prices (surplus > 1 €) and eligible (child: parent
accepted; exclusive member: no member of its group accepted); PAB = accepted with value < −1 € (linked parent: own
surplus + accepted children's; child / exclusive member: own surplus).
Writes runs/st-impact/tables/blocks_days.csv and prints the table (Δ vs truthful hourly, day-block 90% CI)."""
import json
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import market_view as MV  # noqa: E402
import rdopt as R  # noqa: E402

RC = MV.ROOT / "runs/st-impact/rc"
T = MV.ROOT / "runs/st-impact/tables"
ARMS = ["a_truthful", "b_cournot", "c_linked_cost", "d_linked_cournot", "e_exclusive"]


def fam_attr(f, k):
    m = re.search(k + r"=([^:]+)", f)
    return m.group(1) if m else ""


def score(job):
    meta = json.loads((RC / f"{job}.meta.json").read_text())
    o = pd.read_csv(RC / f"{job}.out.csv")
    orders = pd.read_csv(RC / f"{job}.csv", keep_default_na=False)
    P = dict(zip(o.hour, o.zone_price))
    q = dict(zip(o.hour, o.accepted_mw))
    sim = imp = vol = 0.0
    dp = []
    for h, lad in meta["ladder"].items():
        h = int(h)
        g, m = zip(*lad)
        c = R.StepCost(np.array(m), np.array(g))
        qq = min(q.get(h, 0.0), c.S)
        cost = float(c.C(qq))
        e = meta["p_real"][str(h)] - meta["p_base"][str(h)]
        sim += P[h] * qq - cost
        imp += (P[h] + e) * qq - cost
        vol += qq
        dp.append(P[h] - meta["p_base"][str(h)])
    row = dict(job=job, day=meta["day"], zone=meta["zone"], S=meta["S"], arm=job.split("_blk_")[1],
               sim=sim, imp=imp, vol_mwh=vol, dp_mean=float(np.mean(dp)), status=o.status.iloc[0],
               window_h=len(meta["window"]))
    fpath = RC / f"{job}.fam.csv"
    if fpath.exists():
        fam = pd.read_csv(fpath)
        acc = dict(zip(fam.family, fam.accepted))
        bl = orders[orders.kind == "lho"]
        Sf = {f: float(sum((P[h] - p) * mw for h, p, mw in zip(g.hour, g.price, g.mw))) for f, g in bl.groupby("family")}
        name = {f: f.split(":")[2] for f in Sf}
        acc_names = {name[f] for f in Sf if acc.get(f, 0)}
        groups_acc = {fam_attr(f, "group") for f in Sf if acc.get(f, 0) and fam_attr(f, "group")}
        kids = {}
        for f in Sf:
            par = fam_attr(f, "parent")
            if par:
                kids.setdefault(par, []).append(f)
        prb = pab = 0
        prb_eur = 0.0
        for f, s in Sf.items():
            par, grp = fam_attr(f, "parent"), fam_attr(f, "group")
            if acc.get(f, 0):
                v = s + (sum(Sf[k] for k in kids.get(name[f], []) if acc.get(k, 0)) if not par and not grp else 0.0)
                pab += v < -1.0
            else:
                elig = (not par or par in acc_names) and (not grp or grp not in groups_acc)
                if s > 1.0 and elig:
                    prb += 1
                    prb_eur += s
        parent = [f for f in Sf if f.startswith("BLKL:") and not fam_attr(f, "parent")]
        row.update(n_fam=len(Sf), n_acc=int(sum(acc.values())), prb=prb, prb_eur=prb_eur, pab=pab,
                   parent_acc=int(acc.get(parent[0], 0)) if parent else -1,
                   x_member=next((f.split("-x")[1].split(":")[0] for f in Sf if f.startswith("BLKX:") and acc.get(f, 0)), ""))
    if row["arm"] in ("a_truthful", "b_cournot"):
        cp = meta["curve_pred"]["truthful" if row["arm"] == "a_truthful" else "cournot"]
        row["curve_dp_mae"] = float(np.mean([abs(P[int(h)] - v[0]) for h, v in cp.items()]))
    return row


if __name__ == "__main__":
    jobs = sorted(f.name[:-8] for f in RC.glob("*_blk_*.out.csv"))
    D = pd.DataFrame([score(j) for j in jobs])
    D.to_csv(T / "blocks_days.csv", index=False)
    lines = ["| zone | S | arm | days | Δ sim k€/d | Δ realised+impact k€/d | volume MWh/d | mean Δp vs base €/MWh | "
             "families / accepted per day | parent accepted (days) | PRB per day (k€) | PAB per day | exclusive member chosen |",
             "|" + "---|" * 13]
    for (z, S), g in D.groupby(["zone", "S"]):
        a = g[g.arm == "a_truthful"].set_index("day")
        for arm in ARMS:
            x = g[g.arm == arm].set_index("day")
            days = sorted(set(a.index) & set(x.index))
            if not days:
                continue
            ds = R.block_bootstrap_ci((x.sim.reindex(days) - a.sim.reindex(days)).values)
            di = R.block_bootstrap_ci((x.imp.reindex(days) - a.imp.reindex(days)).values)
            f = lambda t: f"{t[0]/1e3:+.1f} [{t[1]/1e3:+.1f}, {t[2]/1e3:+.1f}]"  # noqa: E731
            fam = (f"{x.n_fam.mean():.0f} / {x.n_acc.mean():.1f}" if "n_fam" in x and x.n_fam.notna().any() else "–")
            par = (f"{int((x.parent_acc == 1).sum())}/{len(x)}" if "parent_acc" in x and (x.parent_acc >= 0).any() else "–")
            prb = (f"{x.prb.mean():.1f} ({x.prb_eur.mean()/1e3:.1f})" if "prb" in x and x.prb.notna().any() else "–")
            pab = f"{x.pab.mean():.2f}" if "pab" in x and x.pab.notna().any() else "–"
            xm = (x.x_member.fillna("").astype(str).value_counts().to_dict() if arm == "e_exclusive" else "")
            lines.append(f"| {z} | {S} | {arm} | {len(days)} | {f(ds)} | {f(di)} | {x.vol_mwh.mean():.0f} | "
                         f"{x.dp_mean.mean():+.1f} | {fam} | {par} | {prb} | {pab} | {xm} |")
    print("\n".join(lines))
    if "curve_dp_mae" in D:
        print("\ncurve vs reclear (arms a/b): mean |Δp| per job, median", round(D.curve_dp_mae.median(), 2),
              "max", round(D.curve_dp_mae.max(), 2))
