"""Common complete days (39 zones, 24 h) across arms of two scenario runs.
usage: scn_common_days.py OUT_FILE DB43:arm,arm,... DB44:arm,arm,...   (labels without prefix)
Writes the ISO days present and complete in every listed arm of both runs."""
import sys, duckdb
out = sys.argv[1]
sets = []
for spec, pfx in zip(sys.argv[2:4], ("eu43", "eu44")):
    db, arms = spec.split(":")
    c = duckdb.connect(db, read_only=False)  # scratch snapshots (a .wal needs replay)
    for a in arms.split(","):
        rows = c.execute(f"""SELECT CAST(date_trunc('day', date_time_utc) AS DATE) d FROM simulations.energy_prices
            WHERE clearing_mode = '{pfx}_{a}' GROUP BY 1
            HAVING COUNT(DISTINCT bidding_zone) >= 39 AND COUNT(DISTINCT date_trunc('hour', date_time_utc)) >= 24""").fetchall()
        s = {str(r[0]) for r in rows}; print(f"{pfx}_{a}: {len(s)} complete days"); sets.append(s)
common = sorted(set.intersection(*sets))
open(out, "w").write("\n".join(common) + "\n")
print(f"common complete days: {len(common)} -> {out}")
