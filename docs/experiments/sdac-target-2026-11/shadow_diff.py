"""Legacy (highest_seq) vs SDAC hourly target: shadow diff, offline (#431 PR C).

usage: python shadow_diff.py --extract EXTRACT.duckdb --live-dir LIVE_JSON_DIR \
           --record-db RECORD.duckdb --out OUTDIR

* actuals: both policies from bin/da_target.py on the SAME raw rows of the read-only extract;
* live window: lead-1 physics ("weather*" input modes, the site's ex-ante track) from the saved
  live JSON (export_forecast_json output), Athens market days LIVE_START..LIVE_END;
* record window: the cv44 record backfill (simulations.energy_prices, multi_zone_eu, cv44) from a
  results DuckDB, UTC days REC_START..REC_END. It is the record clearing (entsoe inputs), not a
  lead-1 forecast; it is the "physics record" the site's record tables are built from.
Outputs (OUTDIR): shadow_live.csv, shadow_record.csv (per zone + FOOTPRINT), gap.csv,
q15_check.csv, exclusions.csv, summary.txt.
"""
import argparse
import glob
import json
import sys
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "bin"))
import da_target as dt  # noqa: E402

LIVE_START, LIVE_END = "2026-09-14", "2026-11-13"   # Fable's live window (plan-431-fable §1.1)
REC_START, REC_END = "2024-07-01", "2026-06-30"     # record window (plan-431-fable WS5)
# The Julia native-15 target's exclusion map (test/scripts/eu_eval_metrics.jl Q15_NON_SDAC_SEQUENCE)
Q15_NON_SDAC_SEQUENCE = {"AT": "2", "DE_LU": "2"}


def live_cells(live_dir):
    rows = []
    for f in sorted(glob.glob(f"{live_dir}/*.json")):
        d = json.loads(Path(f).read_text())
        for x in d["days"]:
            if x["lead_days"] != 1 or not x["input_mode"].startswith("weather"):
                continue
            if not (LIVE_START <= x["date"] <= LIVE_END):
                continue
            for h, s, a in zip(x["hours"], x["sim"], x["actual"]):
                rows.append((d["zone"], x["date"], x["code_version"], h, s, a))
    df = pd.DataFrame(rows, columns=["z", "date", "cv", "t", "sim", "json_act"])
    df["t"] = pd.to_datetime(df.t).dt.tz_localize(None)
    return df.dropna(subset=["sim"])


def record_cells(record_db):
    cx = duckdb.connect(record_db, read_only=True)
    df = cx.execute("""SELECT bidding_zone z, date_time_utc t, price_eur_mwh sim
        FROM simulations.energy_prices WHERE clearing_mode = 'multi_zone_eu' AND code_version = 44
          AND contract_type = 'Day-Ahead'
          AND date_time_utc >= ?::TIMESTAMP AND date_time_utc < ?::TIMESTAMP + INTERVAL 1 DAY""",
                    [REC_START, REC_END]).df()
    cx.close()
    return df


def score(cells, leg, sd):
    """Per zone: MAE vs each target on its own cells, and both on the common cells."""
    m = cells.merge(leg.rename(columns={"act": "leg"}), on=["z", "t"], how="left") \
             .merge(sd.rename(columns={"act": "sdac"}), on=["z", "t"], how="left")
    out = []
    for z, g in list(m.groupby("z")) + [("FOOTPRINT", m)]:
        gl, gs, gc = g.dropna(subset=["leg"]), g.dropna(subset=["sdac"]), g.dropna(subset=["leg", "sdac"])
        out.append(dict(zone=z, n_legacy=len(gl), mae_legacy=(gl.sim - gl.leg).abs().mean(),
                        n_sdac=len(gs), mae_sdac=(gs.sim - gs.sdac).abs().mean(),
                        n_common=len(gc), mae_legacy_common=(gc.sim - gc.leg).abs().mean(),
                        mae_sdac_common=(gc.sim - gc.sdac).abs().mean()))
    r = pd.DataFrame(out)
    r["d_mae_common"] = r.mae_sdac_common - r.mae_legacy_common
    r["d_n"] = r.n_sdac - r.n_legacy
    return r, m


def gap(leg, sd, lo, hi, label):
    w = lambda d: d[(d.t >= pd.Timestamp(lo)) & (d.t < pd.Timestamp(hi) + pd.Timedelta(days=1))]
    m = w(leg).merge(w(sd), on=["z", "t"], how="outer", suffixes=("_leg", "_sdac"), indicator=True)
    out = []
    for z, g in m.groupby("z"):
        c = g[g._merge == "both"]
        d = (c.act_leg - c.act_sdac).abs()
        out.append(dict(window=label, zone=z, hours_legacy=int(g.act_leg.notna().sum()),
                        hours_sdac=int(g.act_sdac.notna().sum()),
                        legacy_only=int((g._merge == "left_only").sum()),
                        sdac_only=int((g._merge == "right_only").sum()),
                        mean_abs_gap=d.mean(), max_abs_gap=d.max(), hours_gap_gt_1e6=int((d > 1e-6).sum())))
    return pd.DataFrame(out)


def native_q15(cx, lo, hi):
    """The Julia `native_q15_actuals` rule, PT15M only: drop the non-SDAC sequence, latest
    update per (zone, interval, resolution)."""
    excl = " OR ".join(f"(map_code = '{z}' AND trim(coalesce(sequence, '')) = '{q}')"
                       for z, q in sorted(Q15_NON_SDAC_SEQUENCE.items()))
    return cx.execute(f"""
        SELECT map_code z, date_time_utc t, price_currency_mwh act FROM entsoe.energy_prices
        WHERE contract_type = 'Day-ahead' AND area_type_code LIKE 'BZN%' AND price_currency_mwh IS NOT NULL
          AND trim(resolution_code) = 'PT15M' AND NOT ({excl})
          AND date_time_utc >= ?::TIMESTAMP AND date_time_utc < ?::TIMESTAMP
        QUALIFY row_number() OVER (PARTITION BY map_code, date_time_utc, resolution_code
                                   ORDER BY update_time_utc DESC) = 1""", [lo, hi]).df()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extract", required=True)
    ap.add_argument("--live-dir", required=True)
    ap.add_argument("--record-db", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    cx = duckdb.connect(a.extract, read_only=True)
    lo, hi = "2024-06-30", "2026-11-17"
    raw = dt.raw_rows(cx, lo, hi)
    leg = dt.highest_seq_hourly(raw)
    sd, excl, smap = dt.sdac_hourly(raw)
    log = [f"extract {a.extract}; raw rows {len(raw):,} over UTC [{lo}, {hi}); "
           f"hourly legacy {len(leg):,}, sdac {len(sd):,}",
           f"auction map: {smap[smap.how != 'single'].to_dict('records')}",
           f"ambiguous zones (fail closed): {sorted(smap[smap.how == 'ambiguous'].z)}"]

    # exclusion ledger
    ex = excl.groupby(["reason", "z"]).size().rename("rows").reset_index()
    ex.to_csv(out / "exclusions.csv", index=False)

    # live
    lc = live_cells(a.live_dir)
    live, lm = score(lc[["z", "t", "sim"]], leg, sd)
    live.to_csv(out / "shadow_live.csv", index=False)
    jc = lm.merge(lc[["z", "t", "json_act"]], on=["z", "t"]).dropna(subset=["json_act", "leg"])
    log.append(f"live: {len(lc):,} lead-1 weather* cells, {lc.date.min()}..{lc.date.max()}, "
               f"cv {sorted(lc.cv.unique())}; published JSON actual vs recomputed legacy on "
               f"{len(jc):,} cells: max |diff| {np.abs(jc.json_act - jc.leg).max():.4f} "
               f"(JSON rounds to 2 dp)")
    js = lc.dropna(subset=["json_act"])
    jm = js.assign(e=(js.sim - js.json_act).abs())
    log.append("live MAE vs the PUBLISHED JSON actual (Fable's source): " + ", ".join(
        f"{z} {jm[jm.z == z].e.mean():.2f} (n={int((jm.z == z).sum())})" for z in ["AT", "DE_LU"])
        + f", footprint {jm.e.mean():.2f} (n={len(jm):,})")

    # record
    rc = record_cells(a.record_db)
    rec, _ = score(rc, leg, sd)
    rec.to_csv(out / "shadow_record.csv", index=False)
    log.append(f"record: cv44 multi_zone_eu {len(rc):,} cells, UTC {REC_START}..{REC_END}")

    # actual-vs-actual gap and coverage per window
    g = pd.concat([gap(leg, sd, "2026-09-13", LIVE_END, "live (UTC 09-13..11-13)"),
                   gap(leg, sd, REC_START, REC_END, "record")], ignore_index=True)
    g.to_csv(out / "gap.csv", index=False)

    # native quarters vs SDAC hourly
    q = native_q15(cx, lo, hi)
    q["h"] = q.t.dt.floor("h")
    qh = q.groupby(["z", "h"]).act.agg(["mean", "size"]).reset_index().rename(columns={"h": "t"})
    qh = qh[qh["size"] == 4].merge(sd, on=["z", "t"], how="inner")
    qh["d"] = (qh["mean"] - qh.act).abs()
    qc = qh.groupby("z").agg(hours=("d", "size"), max_abs=("d", "max"), mean_abs=("d", "mean")).reset_index()
    qc.to_csv(out / "q15_check.csv", index=False)

    pd.set_option("display.width", 200)
    fmt = lambda df: df.round(4).to_string(index=False)
    changed = g[(g.max_abs_gap > 1e-6)].groupby("zone").max_abs_gap.max()
    txt = "\n".join(log) + "\n\n## Live window, lead-1 physics (weather*), per zone\n" + fmt(live) + \
        "\n\n## Record window, cv44 record clearing, per zone\n" + fmt(rec) + \
        "\n\n## Actual-vs-actual gap and coverage (legacy vs SDAC)\n" + fmt(g) + \
        "\n\n## Zones whose hourly actual changes by more than 1e-6\n" + changed.to_string() + \
        "\n\n## Native PT15M quarters (Q15 rule) mean vs SDAC hourly, hours with 4 quarters\n" + \
        fmt(qc[qc.max_abs > 1e-9]) + f"\n(all other {int((qc.max_abs <= 1e-9).sum())} PT15M zones: max |diff| <= 1e-9)" + \
        "\n\n## Exclusion ledger (sdac)\n" + fmt(ex.groupby("reason").rows.sum().reset_index()) + "\n"
    (out / "summary.txt").write_text(txt)
    print(txt)


if __name__ == "__main__":
    main()
