#!/usr/bin/env python3
"""Firm-map wave 1: DE_LU + FR name-rule mapping into simulations.unit_firms.

Same discipline as the BG precedent: capacity-ranked name rules, source tag
'name-rule v1 (July 2026), verify before publication', fully reversible
(DELETE WHERE source LIKE 'name-rule wave1%'). Prints per-zone coverage of
registry MW. Emits CSVs here; --load inserts into Postgres (ENERGY_CONN_STR).

Ownership notes (public knowledge, plant level; JVs mapped to the operator):
DE lignite: RWE (Rhenish: Neurath/Niederaussem/Weisweiler), LEAG (Lusatian:
Boxberg/Schwarze Pumpe/Jaenschwalde; + Lippendorf both blocks operated LEAG).
DE hard coal: Uniper (Datteln/Heyden/Staudinger/Scholven/Wilhelmshaven-1),
STEAG-Iqony (Walsum/Bexbach/Weiher/Bergkamen/Herne), EnBW (RDK/Heilbronn/
Altbach), RWE (Ibbenbueren/Westfalen/Gersteinwerk), Trianel (Luenen),
Vattenfall (Moorburg/Reuter/Tiefstack), GKM (Mannheim). Gas: RWE (Emsland),
Uniper (Irsching), Statkraft (Knapsack), EnBW, Leipzig/municipal small.
Nuclear (closed 2021-23, mapped for completeness): PreussenElektra (Isar/
Brokdorf/Grohnde/Emsland-A), RWE (Gundremmingen), EnBW (Philippsburg/
Neckarwestheim). FR: EDF = all nuclear, nearly all hydro; Engie (DK6,
CyCoFos?); TotalEnergies/EDF CCGTs by name."""
import csv, os, re, sys, subprocess

EM = os.path.expanduser("~/armada/energy-markets")
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = "name-rule wave1 (July 2026), verify before publication"

RULES = {
"DE_LU": [
    (r"Neurath|Niederau|Weisweiler|Gundremmingen|Emsland [AD]|Ibbenb|Westfalen|Gersteinwerk|BoA", "RWE"),
    (r"Boxberg|Schwarze Pumpe|nschwalde|Lippendorf", "LEAG"),
    (r"Datteln|Heyden|Irsching|Staudinger|Scholven|^Wilhelmshaven$|Franken", "Uniper"),
    (r"WALSUM|BEXBACH|WEIHER|BERGKAMEN|Herne|Walsum", "STEAG/Iqony"),
    (r"RDK|Heilbronn|Altbach|Philippsburg|Neckarwestheim|Stuttgart|GKS ", "EnBW"),
    (r"Moorburg|Reuter|Tiefstack|Wedel|Moabit", "Vattenfall"),
    (r"nen Block|Trianel|Hamm-Uentrop", "Trianel"),
    (r"GKM|Mannheim", "GKM (Mannheim)"),
    (r"Knapsack", "Statkraft"),
    (r"Isar|Brokdorf|Grohnde|Emsland A", "PreussenElektra"),
    (r"DEWHV|Onyx|DEFARGE|Farge", "Onyx Power"),
    (r"GuD Dormagen|Dormagen", "RWE"),
    (r"Kraftwerk Rostock", "EnBW/Rostock (KNG)"),
    (r"Emsland [BC]", "RWE"),
    (r"DEZOLLI|Zolling", "Onyx Power"),
    (r"Wehr|Waldshut|Witznau|.ffingen|Schluchsee", "Schluchseewerk (RWE/EnBW)"),
    (r"Niehl", "RheinEnergie"),
    (r"Mittelsbueren|Mittelsb", "swb (Bremen)"),
    (r"Schkopau", "EPH/Saale Energie"),
    (r"HKW Mitte|Lichterfelde|Marzahn|Klingenberg", "Vattenfall (Berlin/BEW)"),
    (r"KMW_", "KMW Mainz-Wiesbaden"),
    (r"HERDECKE", "Cuno/Mark-E (Enervie)"),
    (r"Ingolstadt", "Uniper"),
    (r"Buschhaus", "MIBRAG/EPH"),
    (r"^Kiel$|Kiel ", "Stadtwerke Kiel"),
    (r"Huntorf", "Uniper"),
    (r"GK-WEST", "STEAG/Iqony"),
    (r"Hohenwarte|Markersbach|Goldisthal", "Vattenfall (PSW)"),
    (r"Huckingen", "HKM (Huettenwerke)"),
    (r"Nord 2 T|Volkswagen|VW ", "VW Kraftwerk"),
    (r"Block F$|Block 3$", "municipal/unresolved-block-name"),
    (r"Mehrum", "EPH"),
    (r"Bremen|Hastedt|Hafen", "swb (Bremen)"),
    (r"Lausward", "SW Duesseldorf"),
    (r"Franken 1", "Uniper"),
    (r"Leipheim|Biblis", "reserve/other"),
],
"FR": [
    (r".*", None),  # handled by type rule below: nuclear+hydro -> EDF
],
}
# FR type-based rules (name rules would be endless; ownership is concentrated)
FR_TYPE_FIRM = {
    "Nuclear": "EDF",
    "Hydro Water Reservoir": "EDF",
    "Hydro Run-of-river and pondage": "EDF (CNR/SHEM excepted)",
    "Hydro Pumped Storage": "EDF",
    "Fossil Oil": "EDF",
}
FR_NAME_RULES = [
    (r"DK6|Dunkerque", "Engie"),
    (r"Landivisiau", "TotalEnergies"),
    (r"Bayet|Pont sur Sambre", "TotalEnergies"),
    (r"Combigolfe|Cycofos", "Engie"),
    (r"Martigues|Provence", "EDF"),
    (r"Bouchain", "EDF"),
    (r"Emile Huchet|Saint-Avold", "GazelEnergie"),
    (r"Gennevilliers|Vaires|Arrighi|Montereau|Brennilis|Dirinon", "EDF"),
    (r"Blenod|Bl.nod", "EDF"),
    (r"SPEM|Grand-?Port", "TotalEnergies"),
]

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

def map_zone(zone):
    df = fetch_units(zone)
    rows, mapped_mw, total_mw = [], 0.0, float(df.cap.sum())
    for _, r in df.iterrows():
        firm = None
        if zone == "FR":
            for pat, f in FR_NAME_RULES:
                if re.search(pat, r.nm, re.I): firm = f; break
            if firm is None:
                firm = FR_TYPE_FIRM.get(r.t)
        else:
            for pat, f in RULES[zone]:
                if f and re.search(pat, r.nm, re.I): firm = f; break
        if firm:
            rows.append((zone, r.uc, r.nm, firm, SOURCE))
            mapped_mw += r.cap
    print(f"{zone}: mapped {len(rows)}/{len(df)} units, "
          f"{mapped_mw:,.0f}/{total_mw:,.0f} MW ({100*mapped_mw/total_mw:.0f}%)")
    out = os.path.join(HERE, f"unit_firms_{zone}.csv")
    with open(out, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["zone","unit_code","unit_name","firm","source"])
        w.writerows(rows)
    return rows

def load_postgres(all_rows):
    """Idempotent upsert via psql (ENERGY_CONN_STR from .env; never printed)."""
    import tempfile
    sql = ["BEGIN;",
           f"DELETE FROM simulations.unit_firms WHERE source = '{SOURCE}';"]
    for z, uc, nm, firm, src in all_rows:
        nm2, f2 = nm.replace("'", "''"), firm.replace("'", "''")
        sql.append("INSERT INTO simulations.unit_firms VALUES "
                   f"('{z}','{uc}','{nm2}','{f2}','{src}') "
                   "ON CONFLICT (zone, unit_code) DO UPDATE SET "
                   "firm=EXCLUDED.firm, unit_name=EXCLUDED.unit_name, source=EXCLUDED.source;")
    sql.append("COMMIT;")
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write("\n".join(sql)); path = f.name
    env = os.environ.copy()
    r = subprocess.run(f"set -a && . {EM}/.env >/dev/null 2>&1 && set +a && "
                       f"psql \"$ENERGY_CONN_STR\" -q -f {path}",
                       shell=True, capture_output=True, text=True)
    print(r.stdout[-500:] or "loaded", r.stderr[-500:] if r.returncode else "")
    os.unlink(path)

if __name__ == "__main__":
    rows = []
    for z in ("DE_LU", "FR"):
        rows += map_zone(z)
    if "--load" in sys.argv:
        load_postgres(rows)
        print("loaded into Postgres simulations.unit_firms")
