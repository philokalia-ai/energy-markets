"""Phase 2 pass-through test: does a TSFM arm pass a structural physics shift through to its forecast?

For each test day D (D-1 context, same inputs as the backtest) and arm, one batch forecasts the base
inputs plus perturbed copies in which only the delivery-day (horizon) covariates change:
  dc574        sim += cv43 DC Δsim profile (zone x local hour), residual load GR += 574 MW
  dc_loadonly  residual load GR += 574 MW, sim unchanged          (arms with a resload row)
  ops          sim += cv43 cold-ironing Δsim profile, residual load += cold-ironing MW profile
  syn_sim10    sim x 1.10 (all zones)
  syn_load10   residual load x 1.10 (all zones)                  (arms with a resload row)
History is never perturbed: the change is new (off-support), as for a DC that is not yet built.
Pass-through = Σ Δforecast / Σ Δsim over the zone's delivery hours (median forecast; arm `physresid`
adds the perturbed sim to its residual forecast, so its pass-through is 1 + Δresidual/Δsim).
Arm `uni` (prices only) has pass-through 0 by construction.

Usage: python passthrough.py --arm sim|phys|physresid [--days ...] [--threads 8]
Output: $TSFM_OUT/passthrough_<arm>.parquet (one row per arm, day, scenario, zone, hour).
"""
import argparse, os, sys, time
from datetime import date
import numpy as np, pandas as pd, torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_tsfm as R

DAYS = ["2026-09-14", "2026-09-22", "2026-09-30", "2026-10-08", "2026-10-16", "2026-10-24",
        "2026-11-01", "2026-11-09"]
VARIANT = {"sim": "sim", "phys": "phys", "physresid": "physresid"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=list(VARIANT))
    ap.add_argument("--days", default=",".join(DAYS))
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--model", default="t209")
    a = ap.parse_args()
    torch.set_num_threads(a.threads)
    R.CTX = 2048
    zones, grid, wide = R.load_inputs()
    prof = pd.read_parquet(f"{R.OUT}/scenario_profiles.parquet")
    m = R.Model(a.model)
    has_load = a.arm in ("phys", "physresid")
    rows, times = [], []
    for ds in a.days.split(","):
        d = date.fromisoformat(ds)
        ctx, known, H, nD, cutoff, s_D, simD = R.build_inputs(d, VARIANT[a.arm], zones, grid, wide, 1)
        hours = pd.date_range(s_D, periods=nD, freq="h")
        lh = hours.tz_localize("UTC").tz_convert(R.ATH).hour.values
        Z = len(zones)
        batches = [("base", np.arange(Z), np.zeros((Z, nD)), np.zeros((Z, nD)))]
        for scen in ("dc574", "ops"):
            p = prof[prof.scenario == scen].set_index(["zone", "lh"])
            dsim = np.array([[p.dsim.get((z, h), 0.0) for h in lh] for z in zones])
            dload = np.array([[p.dload.get((z, h), 0.0) for h in lh] for z in zones])
            sel = np.where((np.abs(dsim).mean(1) > 0.1) | (dload.mean(1) > 0))[0]
            batches.append((scen, sel, dsim[sel], dload[sel] if has_load else np.zeros_like(dsim[sel])))
            if scen == "dc574" and has_load:
                gi = np.array([zones.index("GR")])
                batches.append(("dc_loadonly", gi, np.zeros((1, nD)), dload[gi]))
        simH = np.nan_to_num(known[:, 0, -nD:]) if known is not None else np.nan_to_num(simD)
        batches.append(("syn_sim10", np.arange(Z), 0.10 * simH, np.zeros((Z, nD))))
        if has_load:
            batches.append(("syn_load10", np.arange(Z), np.zeros((Z, nD)), 0.10 * np.nan_to_num(known[:, 1, -nD:])))
        cts, kns, meta = [], [], []
        for name, sel, dsim, dload in batches:
            k = known[sel].copy()
            k[:, 0, -nD:] += dsim
            if has_load:
                k[:, 1, -nD:] += dload
            cts.append(ctx[sel]); kns.append(k)
            meta.append((name, sel, dsim, dload))
        t0 = time.time()
        q, lv = m.forecast(np.concatenate(cts).astype(np.float32), H, np.concatenate(kns).astype(np.float32))
        times.append(time.time() - t0)
        med = q[:, H - nD:, int(np.argmin(np.abs(lv - 0.5)))]
        if a.arm == "physresid":
            simfull = np.concatenate([np.nan_to_num(simD[sel]) + dsim for _, sel, dsim, _ in meta])
            med = med + simfull
        off, base_med = 0, None
        for name, sel, dsim, dload in meta:
            blk = med[off:off + len(sel)]; off += len(sel)
            if name == "base":
                base_med = blk; continue
            dfc = blk - base_med[sel]
            for i, zi in enumerate(sel):
                for h in range(nD):
                    rows.append((a.arm, ds, name, zones[zi], hours[h], float(dsim[i, h]), float(dload[i, h]),
                                 float(dfc[i, h]), float(base_med[zi, h])))
        print(f"{ds} batch={sum(len(s) for _, s, _, _ in meta)} {times[-1]:.1f}s", flush=True)
    out = pd.DataFrame(rows, columns=["arm", "market_date", "scenario", "zone", "t", "dsim", "dload", "dfc", "base_fc"])
    out.to_parquet(f"{R.OUT}/passthrough_{a.arm}.parquet")
    print(f"wrote passthrough_{a.arm}.parquet rows={len(out)} mean batch {np.mean(times):.1f}s")


if __name__ == "__main__":
    main()
