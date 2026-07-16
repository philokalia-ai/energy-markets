#!/usr/bin/env python3
"""Build per-bidding-zone hourly OPS (cold-ironing) demand profiles from the
pan-European AIS port-call dataset (floor scenario: registry-confirmed >5000 GT
passenger ships). Output: long CSV (datetime_utc hour, zone, mw)."""
import duckdb, csv, sys, os

DATA = os.environ.get("PAN_EU_OPS_DATA", os.path.join(os.path.dirname(__file__), "..", "..", "..", "pan-european-cold-ironing-data"))
OUT = os.path.join(os.path.dirname(__file__), "ops_hourly_eu_floor_2023H2_2025H1.csv")
W0, W1 = "2023-07-01 00:00:00", "2025-06-30 23:59:59"

# --- port -> bidding zone (explicit for multi-zone countries; None = excluded)
IT = {
 "ITGOA":"IT-NORTH","ITSPE":"IT-NORTH","ITSVN":"IT-NORTH","ITVCE":"IT-NORTH",
 "ITTRS":"IT-NORTH","ITCHI":"IT-NORTH","ITMNF":"IT-NORTH","ITRAN":"IT-NORTH","ITPVT":"IT-NORTH",
 "ITLIV":"IT-CNORTH","ITPIO":"IT-CNORTH","ITPFE":"IT-CNORTH","ITMDC":"IT-CNORTH",
 "ITPSS":"IT-CNORTH","ITAOI":"IT-CNORTH",
 "ITCVV":"IT-CSOUTH","ITFCO":"IT-CSOUTH","ITGAE":"IT-CSOUTH","ITNAP":"IT-CSOUTH",
 "ITSAL":"IT-CSOUTH","ITISH":"IT-CSOUTH","ITPRJ":"IT-CSOUTH","ITPRO":"IT-CSOUTH","ITPNZ":"IT-CSOUTH",
 "ITBRI":"IT-SOUTH","ITBDS":"IT-SOUTH","ITTAR":"IT-SOUTH",
 "ITGIT":"IT-Calabria","ITREG":"IT-Calabria",
 "ITPMO":"IT-Sicily","ITMSN":"IT-Sicily","ITCTA":"IT-Sicily","ITAUG":"IT-Sicily",
 "ITSIR":"IT-Sicily","ITTPS":"IT-Sicily","ITMLZ":"IT-Sicily","ITPEM":"IT-Sicily","ITGEA":"IT-Sicily",
 "ITCAG":"IT-Sardinia","ITOLB":"IT-Sardinia","ITGAI":"IT-Sardinia","ITPTO":"IT-Sardinia",
 "ITMDA":"IT-Sardinia","ITCLF":"IT-Sardinia","ITPVE":"IT-Sardinia","ITPAU":"IT-Sardinia",
}
SE = {
 "SELLA":"SE1","SEPIT":"SE1",
 "SESDL":"SE2","SEUME":"SE2",
 "SESTO":"SE3","SEGOT":"SE3","SEKPS":"SE3","SEGRH":"SE3","SEVBY":"SE3","SEOSK":"SE3",
 "SENRK":"SE3","SEOXE":"SE3","SEVAG":"SE3","SESMD":"SE3","SESTE":"SE3","SEKOG":"SE3",
 "SEVST":"SE3","SEGVX":"SE3",
 "SEMMA":"SE4","SEHEL":"SE4","SETRG":"SE4","SEYST":"SE4","SEKAN":"SE4","SEKAA":"SE4","SEHAD":"SE4",
}
DK = {
 "DKAAB":"DK1","DKAAL":"DK1","DKAAR":"DK1","DKEBJ":"DK1","DKFDH":"DK1","DKFRC":"DK1",
 "DKHIR":"DK1","DKODE":"DK1","DKSPB":"DK1",
 "DKCPH":"DK2","DKGED":"DK2","DKHLS":"DK2","DKKOG":"DK2","DKRNN":"DK2","DKROF":"DK2","DKTRS":"DK2",
 "DK~Sjællands Odde Ferry":"DK2",
}
COUNTRY_ZONE = {"ES":"ES","FR":"FR","GR":"GR","PT":"PT","FI":"FI","EE":"EE","PL":"PL",
                "DE":"DE_LU","NL":"NL","BE":"BE","LT":"LT","LV":"LV","RO":"RO",
                "BG":"BG","SI":"SI"}
OUT_OF_FOOTPRINT = {"IE","HR","MT","CY"}
# island systems not in the country's bidding zone
EXCLUDED_PORTS = {"FRAJA","FRBIA","YTLON",                       # Corsica, Mayotte
                  "ES~Arrecife (Lanzarote)","ESLPG","ESLCR","ESFUE","ESSSG","ESSPC","ESSCT",  # Canaries
                  "ESCEU","ESMLN",                                # Ceuta, Melilla
                  "PTCNL","PTFNC","PTPXO",                        # Madeira
                  "PTVNC","PTHOR","PTLDP","PTPDL","PTVDP","PTPRV"}  # Azores

def zone_of(cc, unlocode):
    if unlocode in EXCLUDED_PORTS: return None
    if cc == "IT": return IT.get(unlocode)
    if cc == "SE": return SE.get(unlocode)
    if cc == "DK": return DK.get(unlocode)
    if cc in OUT_OF_FOOTPRINT: return None
    return COUNTRY_ZONE.get(cc)

con = duckdb.connect()
ports = con.execute(f"SELECT unlocode, country_code FROM read_csv_auto('{DATA}/ports.csv')").fetchall()
unmapped = [(u,c) for u,c in ports if zone_of(c,u) is None and c not in OUT_OF_FOOTPRINT and u not in EXCLUDED_PORTS]
if unmapped:
    print("UNMAPPED PORTS (in-footprint country but no zone):", unmapped); sys.exit(1)

con.execute("CREATE TABLE zone_map (unlocode TEXT, zone TEXT)")
con.executemany("INSERT INTO zone_map VALUES (?,?)",
                [(u, zone_of(c,u)) for u,c in ports if zone_of(c,u)])

con.execute(f"""
CREATE TABLE calls AS
SELECT p.zone, c.country_code,
       GREATEST(c.arrival_ts, TIMESTAMP '{W0}') AS a,
       LEAST(c.departure_ts, TIMESTAMP '{W1}')  AS d,
       CASE WHEN v.gross_tonnage >= 50000 THEN 12.0
            WHEN v.gross_tonnage >= 20000 THEN 5.0
            ELSE 2.5 END AS mw
FROM read_csv_auto('{DATA}/port_calls.csv.gz') c
JOIN read_csv_auto('{DATA}/vessels.csv') v USING (mmsi)
JOIN zone_map p USING (unlocode)
WHERE v.ship_type_group IN ('ropax','highspeed','cruise')
  AND v.gross_tonnage >= 5000
  AND c.dwell_hours BETWEEN 2 AND 336
  AND c.departure_ts > TIMESTAMP '{W0}' AND c.arrival_ts < TIMESTAMP '{W1}'
""")
n = con.execute("SELECT COUNT(*), COUNT(DISTINCT zone) FROM calls").fetchone()
print(f"in-scope in-footprint calls: {n[0]:,} across {n[1]} zones")

# hourly overlap-weighted MW per zone
con.execute("""
CREATE TABLE hourly AS
WITH hours AS (
  SELECT zone, mw, a, d, unnest(generate_series(date_trunc('hour', a), d, INTERVAL 1 HOUR)) AS h
  FROM calls)
SELECT h AS datetime_utc, zone,
       ROUND(SUM(mw * (epoch(LEAST(d, h + INTERVAL 1 HOUR)) - epoch(GREATEST(a, h))) / 3600.0), 3) AS mw
FROM hours
WHERE LEAST(d, h + INTERVAL 1 HOUR) > GREATEST(a, h)
GROUP BY 1,2 ORDER BY 1,2
""")

print("\n--- per-zone annual energy (GWh/yr, 2-year window / 2):")
print(con.execute("""SELECT zone, ROUND(SUM(mw)/1000/2, 1) AS gwh_yr, ROUND(MAX(mw),0) AS peak_mw
                     FROM hourly GROUP BY 1 ORDER BY 2 DESC""").df().to_string(index=False))

print("\n--- validation vs eu_cold_ironing_by_country.csv (my country GWh/yr incl. zone split):")
mycc = con.execute("""SELECT country_code, ROUND(SUM(mw)/1000/2,1) g
                      FROM (SELECT c.country_code, h AS hh, SUM(c.mw * (epoch(LEAST(d, h + INTERVAL 1 HOUR)) - epoch(GREATEST(a, h)))/3600.0) mw
                            FROM (SELECT *, unnest(generate_series(date_trunc('hour', a), d, INTERVAL 1 HOUR)) AS h FROM calls) c
                            WHERE LEAST(d, h + INTERVAL 1 HOUR) > GREATEST(a, h) GROUP BY 1,2) t
                      GROUP BY 1 ORDER BY 2 DESC""").df()
ref = {r['country_code']: float(r['annual_gwh']) for r in csv.DictReader(open(f"{DATA}/eu_cold_ironing_by_country.csv"))}
for _, r in mycc.iterrows():
    print(f"  {r['country_code']:6s} mine={r['g']:7.1f}  ref={ref.get(r['country_code'],float('nan')):7.1f}")

con.execute(f"COPY hourly TO '{OUT}' (FORMAT CSV, HEADER)")
print(f"\nwrote {OUT}")
print(con.execute("SELECT COUNT(*) FROM hourly").fetchone()[0], "rows")
