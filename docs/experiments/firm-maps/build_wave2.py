#!/usr/bin/env python3
"""Firm-map wave 2: ES, HU (re-map of 'unknown'), and the IT zones.

Same discipline as wave 1 (name rules, reversible source tag, coverage
report). Ownership notes (public knowledge; JVs -> operator/largest owner,
'verify before publication' stands):

ES nuclear: ANAV (Asco/Vandellos) -> Endesa; Cofrentes -> Iberdrola;
Almaraz/Trillo (CNAT JV) -> Iberdrola-led; coal Litoral/Barrios(ex-Viesgo,
now EPH?) -> Endesa/EPH; Meirama -> Naturgy; Abono/Soto -> EDP; CCGT:
Cartagena -> Engie, Besos (PBCN) -> Naturgy/Endesa mixed -> Naturgy,
Castejon -> EDP/Iberdrola mixed, Sagunto/Malaga -> Naturgy, Arcos ->
Iberdrola, Tarragona Power -> Iberdrola.

HU: PA_* -> MVM (Paks); MA2 (Matra lignite) -> Matra (Opus); DG* (Dunamenti)
-> MET; TI* (Tisza II) -> MET; GONYU -> MET (ex-Uniper); CSP (Csepel) ->
Alpiq/MET; LORIGT (Lorinci GT reserve) -> MVM.

IT (per zone; obfuscated UP_OE* codes stay unmapped): Enel (La Casella,
Fusina, Chiotas/Entracque, Roncovalgrande, Edolo, Presenzano, Torre Nord,
Montalto, Brindisi Sud, Federico II? -> Enel), EPH/EP Produzione (Piacenza?
no -> Levante is Piacenza Levante..., Chivasso, Tavazzano, Ostiglia,
Sermide? EPH bought EP Produzione fleet incl. Ostiglia/Tavazzano...,
Fiume Santo (Sardinia)), A2A (Cassano, Ponti sul Mincio, Monfalcone?,
San Filippo del Mela), Edison (Torviscosa, Marghera, Bussi, Simeri),
Tirreno Power (Vado Ligure, Torrevaldaliga Sud, Napoli Levante),
Sorgenia (Termoli, Modugno, Aprilia, Bertonico), Iren (Turbigo, Moncalieri),
EniPower (Ferrera Erbognone, Ravenna, Mantova, Brindisi Enipower)."""
import csv, os, re, sys, subprocess

EM = os.path.expanduser("~/armada/energy-markets")
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = "name-rule wave2 (July 2026), verify before publication"

ES_RULES = [
    (r"ASCO|VANDELLOS|LITORAL|COMPOSTILLA|TERUEL|BESOS 4|SAN ROQUE|AS PONTES|PONTES|CTN[12]|COLON", "Endesa"),
    (r"COFRENTES|ALMARAZ|TRILLO|ARCOS|TAPOWER|TARRAGONA|CASTELLON|SANTURCE|VELILLA|CTLN[123]|ACE3", "Iberdrola"),
    (r"MEIRAMA|SAGU|MALA[G12]|MALA1|PBCN|BESOS|PALOS|PUERTOLLANO GN|ACECA|FOIX|CTGN", "Naturgy"),
    (r"ABO.{1,2}O|SOTO|CASTEJON|CTJON|SRI[34]|LADA", "EDP"),
    (r"CARTAGENA", "Engie"),
    (r"BARRIOS", "EPH (ex-Viesgo)"),
    (r"S\.M\.GARO|GARO.A", "Nuclenor (closed)"),
    (r"PVENT|PdV", "Plana del Vent (verify owner)"),
    (r"JM\.ORIOL|MUELA|ALDEA|VILLARINO|SAUCELLE|CORTES|CEDILLO|RICOBAYO|VALDECAnAS|AZUTAN|TORREJON|GABRIEL|GALISTEO", "Iberdrola (hydro)"),
    (r"MEQUINENZA|RIBARROJA|MORALETS|SALLENTE|ESTANGENTO|TAVASCAN|MONTAMARA|TERRADETS|CAMARASA", "Endesa (hydro)"),
    (r"AGUAYO|EBRO", "Repsol/Viesgo (hydro)"),
    (r"ESCATRON|EL POZO", "Enel Green/other"),
]
HU_RULES = [
    (r"^PA_", "MVM (Paks)"),
    (r"^M.{1,3}2_|MATRA|M.TRA", "Matra (Opus)"),
    (r"^DG[23]_|DUNAMENTI", "MET (Dunamenti)"),
    (r"^TI[24]_|TISZA", "MET (Tisza II)"),
    (r"G.{1,3}NY|GONYU", "MET (Gonyu, ex-Uniper)"),
    (r"^CSP", "Alpiq/MET (Csepel)"),
    (r"LORIGT|L.RINCI|Saj.{1,3}_GT|Lit.{1,3}r_GT|KF_GT|KI_GT", "MVM (reserve/peaker GT)"),
    (r"KISPTae|UJPTae|KELETae|KOBTae", "Budapesti Eromu (Veolia)"),
    (r"DBRTae|DEBRECEN", "Alteo/other CHP"),
]
IT_RULES = [  # applied to every IT-* zone
    (r"LCSELLA|FUSINA|CHIOTAS|ETQCHIOTAS|RONCOVALG|EDOLO|PRESENZANO|MONTALTO|BRNDSISUD|BRINDISISUD|FEDERICO|TORREVAL.*NORD|TVN|PRIOLO.*EN|SULCIS|ASSEMINI|PREM-GROSIO", "Enel"),
    (r"CHIVASSO|TAVAZZANO|OSTIGLIA|SERMIDE|FIUMESANTO|FIUME.*SANTO|TRAPANI.*EP|SCANDALE", "EPH (EP Produzione)"),
    (r"CASSANO|PONTI.*MINCIO|SFILIPPOMELA|S\.?FILIPPO|MONFALCONE|BRESCIA|LAMARMORA", "A2A"),
    (r"TORVISCOSA|MARGHERA|BUSSI|SIMERI|CANDELA|ALTOMONTE|PIOMBINO.*ED|SELLA.*ED", "Edison"),
    (r"VADOTERM|VADO|TORREVAL.*SUD|TVS|NAPOLILEV|NAPOLI.*LEV", "Tirreno Power"),
    (r"TERMOLI|MODUGNO|APRILIA|BERTONICO|LODI", "Sorgenia"),
    (r"TURBIGO|MONCALIERI", "Iren"),
    (r"FERRERA|ERBOGNONE|RAVENNA.*ENI|ENIPOWER|MANTOVA|BRINDISI.*ENI", "EniPower"),
    (r"PIACENZA|LEVANTE", "EPH/other (Piacenza)"),
    (r"SPEZIA|BRNDS.?SUD|TERMINI_I|ANAPO|PRESENZAN|TORREVALN|SBARBARA|PIETRAFIT|BARGI|TALORO|ROSSANO|PORTO_SCU|MUCONE|S\.MASS", "Enel"),
    (r"SRGN|NRGAMOLISE", "Sorgenia"),
    (r"S\.F\._DEL", "A2A"),
    (r"TRRVLDLIGA", "Tirreno Power"),
    (r"CCGTPRILIA", "Sorgenia"),
    (r"FIUMESANT", "EPH (EP Produzione)"),
    (r"RIZZICONI", "EPH (Ergosud)"),
    (r"LEINI|MONCALIER", "Iren"),
    (r"SARLUX", "Saras (Sarlux)"),
    (r"ROSELECTRA|ROSEN", "Rosen/Roselectra (verify)"),
    (r"PRIOLO", "ERG/Enel (Priolo, verify)"),
    (r"CET[23]", "ILVA/Taranto CET (verify)"),
    (r"CNTRLDTRNL|NCTLVRNFRR|OEAEMAE|OEESDSN|OEEPSNL|CNTRLDSCND|SMRICRICHI|CNTRLFLVCR|RATINO", "unresolved-code"),
]
IT_ZONES = ["IT-NORTH", "IT-CNORTH", "IT-CSOUTH", "IT-SOUTH", "IT-Calabria",
            "IT-Sicily", "IT-Sardinia"]

def fetch_units(zone):
    import duckdb
    c = duckdb.connect(f"{EM}/data/extracts/euphemia-live.duckdb", read_only=True)
    return c.execute(f"""
      SELECT DISTINCT ON (generation_unit_code) generation_unit_code uc,
             generation_unit_name nm, generation_unit_type t,
             generation_unit_installed_capacity_mw cap
      FROM entsoe.production_and_generation_units
      WHERE area_map_code='{zone}' AND generation_unit_installed_capacity_mw > 0
      ORDER BY generation_unit_code, valid_from DESC""").df()

def map_zone(zone, rules):
    df = fetch_units(zone)
    rows, mapped_mw, total_mw = [], 0.0, float(df.cap.sum())
    for _, r in df.iterrows():
        firm = None
        for pat, f in rules:
            if re.search(pat, str(r.nm), re.I): firm = f; break
        if firm and firm != "unresolved-code":
            rows.append((zone, r.uc, str(r.nm), firm, SOURCE))
            mapped_mw += r.cap
    pct = 100 * mapped_mw / total_mw if total_mw else 0
    print(f"{zone}: mapped {len(rows)}/{len(df)} units, {mapped_mw:,.0f}/{total_mw:,.0f} MW ({pct:.0f}%)")
    out = os.path.join(HERE, f"unit_firms_{zone}.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["zone","unit_code","unit_name","firm","source"])
        w.writerows(rows)
    return rows

def load_postgres(all_rows):
    import tempfile
    sql = ["BEGIN;", f"DELETE FROM simulations.unit_firms WHERE source = '{SOURCE}';"]
    for z, uc, nm, firm, src in all_rows:
        nm2, f2 = nm.replace("'", "''"), firm.replace("'", "''")
        sql.append("INSERT INTO simulations.unit_firms VALUES "
                   f"('{z}','{uc}','{nm2}','{f2}','{src}') "
                   "ON CONFLICT (zone, unit_code) DO UPDATE SET "
                   "firm=EXCLUDED.firm, unit_name=EXCLUDED.unit_name, source=EXCLUDED.source;")
    sql.append("COMMIT;")
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write("\n".join(sql)); path = f.name
    r = subprocess.run(f"set -a && . {EM}/.env >/dev/null 2>&1 && set +a && "
                       f"psql \"$ENERGY_CONN_STR\" -q -f {path}",
                       shell=True, capture_output=True, text=True)
    print(r.stdout[-300:] or "loaded", r.stderr[-300:] if r.returncode else "")
    os.unlink(path)

if __name__ == "__main__":
    rows = map_zone("ES", ES_RULES) + map_zone("HU", HU_RULES)
    for z in IT_ZONES:
        rows += map_zone(z, IT_RULES)
    if "--load" in sys.argv:
        load_postgres(rows)
        print("loaded into Postgres simulations.unit_firms")
