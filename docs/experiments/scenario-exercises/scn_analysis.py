#!/usr/bin/env python3
"""Scenario ledger analysis: per-zone LW price delta, the additional load's own
bill, and the extra cost to everyone else (GR / outside / EU-wide).

Usage:
  scn_analysis.py RESULTS_DB EXTRACT_DB BASE_LABEL[:CV] SCN_LABEL[:CV] D0 D1 \
      (dc574 | ops CSV_PATH)

The baseline label may carry a code_version filter (e.g. multi_zone_eu:31).
Load weights = the hourly ENTSO-E D-1 load forecast from the extract (the
model's own demand series, unmodified). All joins are inner (paired hours).
"""
import sys, duckdb

def parse_label(s):
    if ":" in s:
        lab, cv = s.rsplit(":", 1)
        return lab, int(cv)
    return s, None

def main():
    res_db, ext_db = sys.argv[1], sys.argv[2]
    base_lab, base_cv = parse_label(sys.argv[3])
    scn_lab, scn_cv = parse_label(sys.argv[4])
    d0, d1 = sys.argv[5], sys.argv[6]
    mode = sys.argv[7]
    ops_csv = sys.argv[8] if mode == "ops" else None

    con = duckdb.connect(res_db, read_only=True)
    con.execute(f"ATTACH '{ext_db}' AS ext (READ_ONLY)")
    con.execute("SET TimeZone='UTC'")

    def cvf(alias, cv):
        return f"AND {alias}.code_version = {cv}" if cv is not None else ""

    # paired hourly prices per zone
    con.execute(f"""
    CREATE TEMP TABLE px AS
    WITH b AS (
      SELECT bidding_zone AS zone, date_trunc('hour', date_time_utc) AS h,
             AVG(price_eur_mwh) AS p
      FROM simulations.energy_prices e
      WHERE clearing_mode = ? {cvf('e', base_cv)}
        AND date_time_utc >= TIMESTAMP '{d0}' AND date_time_utc < TIMESTAMP '{d1}'
      GROUP BY 1, 2),
    s AS (
      SELECT bidding_zone AS zone, date_trunc('hour', date_time_utc) AS h,
             AVG(price_eur_mwh) AS p
      FROM simulations.energy_prices e
      WHERE clearing_mode = ? {cvf('e', scn_cv)}
        AND date_time_utc >= TIMESTAMP '{d0}' AND date_time_utc < TIMESTAMP '{d1}'
      GROUP BY 1, 2)
    SELECT b.zone, b.h, b.p AS pb, s.p AS ps
    FROM b JOIN s ON s.zone = b.zone AND s.h = b.h
    """, [base_lab, scn_lab])

    # hourly load forecast weights from the extract
    con.execute(f"""
    CREATE TEMP TABLE lw AS
    SELECT area_map_code AS zone, date_trunc('hour', date_time_utc) AS h,
           AVG(total_load_mw) AS mw
    FROM ext.entsoe.day_ahead_total_load_forecast
    WHERE date_time_utc >= TIMESTAMP '{d0}' AND date_time_utc < TIMESTAMP '{d1}'
      AND area_type_code LIKE 'BZN%'
    GROUP BY 1, 2
    """)

    print(f"== {scn_lab} vs {base_lab}  [{d0} .. {d1}) ==")
    tot = con.execute("""
    SELECT COUNT(DISTINCT px.h), COUNT(*),
           SUM(lw.mw*(px.ps-px.pb))/SUM(lw.mw),
           SUM(lw.mw*px.pb)/SUM(lw.mw),
           SUM(lw.mw*(px.ps-px.pb))/1e6,
           SUM(CASE WHEN px.zone='GR' THEN lw.mw*(px.ps-px.pb) ELSE 0 END)/1e6
    FROM px JOIN lw ON lw.zone=px.zone AND lw.h=px.h""").fetchone()
    hours, cells, lw_delta, lw_base, eu_meur, gr_meur = tot
    print(f"paired hours={hours} zone-hour cells={cells}")
    print(f"EU-wide LW delta = {lw_delta:+.3f} EUR/MWh  (LW base {lw_base:.2f}, {100*lw_delta/lw_base:+.2f}%)")
    print(f"EXTRA COST to everyone else: EU {eu_meur:.1f} mEUR | GR {gr_meur:.1f} | outside GR {eu_meur-gr_meur:.1f}")

    # the additional load's own bill
    if mode == "dc574":
        bill = con.execute("""
        SELECT 574.0*COUNT(*)/1e6, 574.0*SUM(ps)/1e6, 574.0*SUM(pb)/1e6,
               AVG(ps), AVG(pb)
        FROM px WHERE zone='GR'""").fetchone()
        twh, b_s, b_b, avg_s, avg_b = bill
        print(f"DC BILL: energy {twh:.3f} TWh | at scenario prices {b_s:.1f} mEUR "
              f"(avg {avg_s:.2f}) | at baseline prices {b_b:.1f} mEUR (avg {avg_b:.2f})")
    else:
        con.execute(f"""
        CREATE TEMP TABLE ops AS
        SELECT zone, CAST(datetime_utc AS TIMESTAMP) AS h, mw
        FROM read_csv_auto('{ops_csv}') WHERE mw > 0""")
        bill = con.execute("""
        SELECT SUM(o.mw)/1e6, SUM(o.mw*px.ps)/1e6, SUM(o.mw*px.pb)/1e6,
               SUM(o.mw*px.ps)/SUM(o.mw)
        FROM ops o JOIN px ON px.zone=o.zone AND px.h=o.h""").fetchone()
        twh, b_s, b_b, wavg = bill
        print(f"OPS BILL: energy {twh:.3f} TWh | at scenario prices {b_s:.1f} mEUR "
              f"(OPS-weighted {wavg:.2f}) | at baseline prices {b_b:.1f} mEUR")

    print("\nPER-ZONE (LW delta EUR/MWh, extra cost mEUR):")
    rows = con.execute("""
    SELECT px.zone, SUM(lw.mw*(px.ps-px.pb))/SUM(lw.mw) AS d,
           SUM(lw.mw*px.pb)/SUM(lw.mw) AS pb, SUM(lw.mw*(px.ps-px.pb))/1e6 AS meur
    FROM px JOIN lw ON lw.zone=px.zone AND lw.h=px.h
    GROUP BY 1 ORDER BY d DESC""").fetchall()
    for z, d, pb, meur in rows:
        print(f"  {z:12s} {d:+8.3f}  (base {pb:7.2f})  {meur:+9.2f} mEUR")

if __name__ == "__main__":
    main()
