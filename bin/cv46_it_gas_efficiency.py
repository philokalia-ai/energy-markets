#!/usr/bin/env python3
"""P3a crosswalk: ENTSO-E Italian gas generation units -> documented electrical efficiency (PyPSA powerplantmatching).

usage: python -I bin/cv46_it_gas_efficiency.py PPM_CSV EXTRACT_DUCKDB OUT_CSV [VINTAGE_LABEL]

Rows: PPM Country == Italy, Fueltype == Natural Gas. Codes per PPM row = its `EIC` set ∪ `projectID['ENTSOE']`; each code
is matched to entsoe.production_and_generation_units on production_unit_code OR generation_unit_code (PPM carries
production-unit EICs in some releases, unit EICs in others). The model reprices only units whose fuel is Fossil Gas
at run time.

Status per generation unit (the model applies only status == use):
  use                   PPM Set == PP, Efficiency present, inside the technology's plausibility band, dates OK
  excluded_chp          PPM Set == CHP: a cogeneration unit's electrical efficiency depends on the heat credit
                        (Astra review: "exclude ambiguous CHP"); keeps the fleet heat rate
  excluded_implausible  Efficiency outside the band (data error, e.g. 0.19 for a 2008 CCGT); keeps the fleet heat rate
  excluded_date         DateIn or DateRetrofit > 2024: the documented efficiency may describe a unit (re)built after the
                        first decision day (2025-07-03; PPM dates are years, so <= 2024 is strictly before it)
  excluded_ambiguous    the generation unit is matched by two PPM rows with different efficiencies or sets
  no_efficiency         no Efficiency in PPM; keeps the fleet heat rate
Vintage rule (cp-orch 2026-11-22): a documented plant efficiency is a static engineering characteristic, not
price-informed, so a later PPM release is acceptable provided it uses no post-gate information about the unit; that is
enforced by the date rule above (commissioning and retrofit years before the window).
Plausibility bands, net electrical efficiency (LHV), by PPM Technology: CCGT [0.45, 0.64]; Steam Turbine [0.30, 0.45];
OCGT / Combustion Engine [0.28, 0.45]; anything else -> excluded_implausible. Sources: IEA-ETSAP Technology Brief E02
"Gas-Fired Power" (2010): CCGT 52-60 %, OCGT 35-42 %, conventional steam 33-40 %; widened to admit older units; the
CCGT upper end is the best demonstrated CCGT (~63-64 % net LHV, Nishi-Nagoya 2017). Set from physics, not prices.
"""
import ast, csv, math, sys
from collections import Counter, defaultdict
import duckdb

PPM, EXTRACT, OUT = sys.argv[1:4]
LABEL = sys.argv[4] if len(sys.argv) > 4 else PPM
BANDS = {"CCGT": (0.45, 0.64), "Steam Turbine": (0.30, 0.45), "OCGT": (0.28, 0.45), "Combustion Engine": (0.28, 0.45)}
LAST_YEAR = 2024


def codes(r):
    out = set()
    for s in (r.get("EIC") or "",):
        try:
            v = ast.literal_eval(s) if s and s not in ("set()", "{nan}") else set()
        except (ValueError, SyntaxError):
            v = set()
        out |= {c for c in v if isinstance(c, str)}
    pid = ast.literal_eval(r["projectID"]) if r.get("projectID") else {}
    out |= set(pid.get("ENTSOE", ()))
    return out


def yr(s):
    try:
        x = float(s); return None if math.isnan(x) else x
    except ValueError:
        return None


ppm = [r for r in csv.DictReader(open(PPM, newline="")) if r["Country"] == "Italy" and r["Fueltype"] == "Natural Gas"]
by_code = defaultdict(list)
for r in ppm:
    for c in codes(r):
        by_code[c].append(r)

con = duckdb.connect(EXTRACT, read_only=True)
con.execute("SET memory_limit='768MB'")
# latest plausible row per Italian gas generation unit (denominator: any registry row typed Fossil Gas), plus every
# production-unit code the unit ever had (PPM may carry an older one), plus "active" = output > 0 in the decision
# window 2025-07-01..2026-11-14 (actual_generation_output_per_generation_unit) for the active-fleet share
fleet = con.execute("""
    WITH u AS (SELECT * FROM entsoe.production_and_generation_units
               WHERE generation_unit_type = 'Fossil Gas' AND area_map_code LIKE 'IT%'
                 AND generation_unit_installed_capacity_mw > 0 AND generation_unit_installed_capacity_mw < 5000),
         last AS (SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY generation_unit_code ORDER BY valid_from DESC) rn FROM u) WHERE rn = 1),
         prods AS (SELECT generation_unit_code, list(DISTINCT production_unit_code) pc
                   FROM entsoe.production_and_generation_units WHERE generation_unit_code IN (SELECT generation_unit_code FROM last)
                   GROUP BY 1),
         act AS (SELECT DISTINCT generation_unit_code FROM entsoe.actual_generation_output_per_generation_unit
                 WHERE date_time_utc >= '2025-07-01' AND date_time_utc < '2026-11-15' AND area_map_code LIKE 'IT%'
                   AND actual_generation_output_mw > 0)
    SELECT l.generation_unit_code, p.pc, l.generation_unit_name, l.area_map_code, l.generation_unit_installed_capacity_mw,
           a.generation_unit_code IS NOT NULL
    FROM last l JOIN prods p USING (generation_unit_code) LEFT JOIN act a USING (generation_unit_code)
    """).fetchall()
rows = []
for gen, prods, name, zone, mw, active in fleet:
    cand = {r["id"]: r for c in [gen] + [x for x in prods if x] for r in by_code.get(c, [])}
    rec = dict(generation_unit_code=gen, generation_unit_name=name, production_unit_code="|".join(sorted(x for x in prods if x)),
               zone=zone, registry_mw=mw, active_2025_07_2026_11=int(active),
               ppm_id="", ppm_name="", ppm_set="", ppm_technology="", ppm_efficiency="", ppm_date_in="",
               ppm_date_retrofit="", status="unmatched")
    if cand:
        effs = {(r["Set"], r["Efficiency"]) for r in cand.values()}
        r = sorted(cand.values(), key=lambda r: int(r["id"]))[0]
        tech, setp = r["Technology"] or "", r["Set"]
        eff = float(r["Efficiency"]) if r["Efficiency"] else None
        di, dr = yr(r["DateIn"]), yr(r["DateRetrofit"])
        if len(effs) > 1:
            st = "excluded_ambiguous"
        elif setp == "CHP":
            st = "excluded_chp"
        elif eff is None:
            st = "no_efficiency"
        elif not (tech in BANDS and BANDS[tech][0] <= eff <= BANDS[tech][1]):
            st = "excluded_implausible"
        elif (di is not None and di > LAST_YEAR) or (dr is not None and dr > LAST_YEAR):
            st = "excluded_date"
        else:
            st = "use"
        rec.update(ppm_id=";".join(sorted(cand)), ppm_name=r["Name"], ppm_set=setp, ppm_technology=tech,
                   ppm_efficiency="" if eff is None else round(eff, 4), ppm_date_in=r["DateIn"],
                   ppm_date_retrofit=r["DateRetrofit"], status=st)
    rows.append(rec)
rows.sort(key=lambda r: r["generation_unit_code"])
with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
    w.writeheader(); w.writerows(rows)
tot = sum(r["registry_mw"] for r in rows); tota = sum(r["registry_mw"] for r in rows if r["active_2025_07_2026_11"])
print(f"{LABEL}: PPM IT gas rows {len(ppm)} (with efficiency {sum(1 for r in ppm if r['Efficiency'])}); "
      f"registry IT gas units {len(rows)}, {tot:.0f} MW; active in window {sum(r['active_2025_07_2026_11'] for r in rows)} units, {tota:.0f} MW")
by = Counter(); mwb = Counter(); mwa = Counter(); na = Counter()
for r in rows:
    by[r["status"]] += 1; mwb[r["status"]] += r["registry_mw"]
    if r["active_2025_07_2026_11"]:
        na[r["status"]] += 1; mwa[r["status"]] += r["registry_mw"]
for s in sorted(by):
    print(f"  {s:21s} {by[s]:4d} units {mwb[s]:8.0f} MW {100 * mwb[s] / tot:5.1f} % of registry | active {na[s]:4d} units {mwa[s]:7.0f} MW {100 * mwa[s] / tota:5.1f} % of active")
for r in rows:
    if r["ppm_efficiency"] != "":
        print(f"  {r['status']:21s} {r['generation_unit_code']} {r['generation_unit_name']:18s} {r['zone']:11s} {r['registry_mw']:6.0f} MW "
              f"{r['ppm_name']} | {r['ppm_set']} {r['ppm_technology']} eff={r['ppm_efficiency']} in={r['ppm_date_in']} retro={r['ppm_date_retrofit']}")
