#!/usr/bin/env python3
"""Evaluate the coupled robustness runs for GR: gr_strat_eu_base vs
gr_strat_eu_topslice vs settled, paired per day — juxtaposed with the
single-zone metrics computed on the SAME days (results_coupled_fair.tsv from
run_corrected.jl part C), so the comparison is paired, not subset-mismatched.
Read-only on results.duckdb + extract.

Hygiene (review findings): rows are filtered to code_version=17 and the script
aborts if a (label, hour) carries more than one saved generation (a re-run
under the same label after a code change would silently blend prices)."""
import duckdb, os, sys, csv

EM = os.path.expanduser("~/armada/energy-markets")
CV = 17
c = duckdb.connect(); c.execute("SET TimeZone='UTC'")
c.execute(f"ATTACH '{EM}/data/results.duckdb' AS r (READ_ONLY)")
c.execute(f"ATTACH '{EM}/data/extracts/euphemia-live.duckdb' AS x (READ_ONLY)")

# duplicate-generation guard: at 15-min resolution an hour has <=4 rows per label
dup = c.execute(f"""
SELECT clearing_mode, date_trunc('hour',date_time_utc) h, COUNT(*) nrows
FROM r.simulations.energy_prices
WHERE bidding_zone='GR' AND code_version={CV}
  AND clearing_mode IN ('gr_strat_eu_base','gr_strat_eu_topslice')
GROUP BY 1,2 HAVING COUNT(*) > 4 LIMIT 5""").fetchall()
if dup:
    sys.exit(f"ABORT: duplicate generations under a label (>4 rows/hour): {dup}")

c.execute(f"""CREATE TEMP TABLE px AS
SELECT clearing_mode AS cm, date_trunc('hour',date_time_utc) AS h, AVG(price_eur_mwh) AS p
FROM r.simulations.energy_prices
WHERE bidding_zone='GR' AND code_version={CV}
  AND clearing_mode IN ('gr_strat_eu_base','gr_strat_eu_topslice')
GROUP BY 1,2""")
c.execute("""CREATE TEMP TABLE act AS
SELECT date_trunc('hour',date_time_utc) AS h, AVG(price_currency_mwh) AS p
FROM x.entsoe.energy_prices WHERE map_code='GR' AND contract_type='Day-ahead' GROUP BY 1""")

def per_label(label):
    return c.execute(f"""
    WITH j AS (SELECT CAST(p.h AS DATE) d, p.p sim, a.p act
               FROM px p JOIN act a ON a.h=p.h WHERE p.cm='{label}')
    SELECT d, corr(sim,act) cr, AVG(abs(act-sim)) mae, AVG(act-sim) resid, COUNT(*) n
    FROM j GROUP BY 1 HAVING COUNT(*)>=20""").df().set_index('d')

base = per_label('gr_strat_eu_base')
top  = per_label('gr_strat_eu_topslice')
days = base.index.intersection(top.index)
print(f"coupled days evaluated: {len(days)} (these are docs/.../coupled_days.json)")

def agg(df):
    d = df.loc[days]
    return dict(corr=d['cr'].mean(), mae=d['mae'].mean(), resid=d['resid'].mean())
b, t = agg(base), agg(top)
dmae = base.loc[days, 'mae'] - top.loc[days, 'mae']
better = int((dmae > 1e-6).sum())

print("\n=== COUPLED (39-zone, imports respond) — GR vs settled, paired days ===")
print(f"{'':26s}{'corr':>7s}{'MAE':>8s}{'resid':>8s}")
print(f"{'baseline (coupled)':26s}{b['corr']:7.2f}{b['mae']:8.2f}{b['resid']:8.2f}")
print(f"{'nearuniform 25% (coupled)':26s}{t['corr']:7.2f}{t['mae']:8.2f}{t['resid']:8.2f}")
print(f"{'ΔMAE gain':26s}{'':7s}{dmae.mean():8.2f}   better {better}/{len(days)}")

fair = os.path.join(EM, "docs/experiments/gr-strategic-bidding/results_coupled_fair.tsv")
if os.path.exists(fair):
    rows = {r['strategy']: r for r in csv.DictReader(open(fair), delimiter='\t')}
    print("\n=== SINGLE-ZONE on the SAME 24 days (results_coupled_fair.tsv) ===")
    for name in ("baseline", "nearuniform_25", "ts_true_25"):
        if name in rows:
            r = rows[name]
            print(f"{name:26s}{float(r['corr']):7.2f}{float(r['mae']):8.2f}"
                  f"{float(r['resid']):8.2f}   ΔMAE {float(r['mae_gain'] or 0):5.2f}"
                  f"  better {r['days_better']}/{r['n']}")
    print("\nReading: compare the coupled ΔMAE against the single-zone ΔMAE on these")
    print("same days. The shrink attributable to import response is the paired gap;")
    print("corr must still improve for the shape claim to hold under coupling.")
else:
    print("\n(no results_coupled_fair.tsv yet — run run_corrected.jl part C for the")
    print(" paired single-zone comparison; comparing against the 60-day aggregate")
    print(" numbers is NOT fair: different day subset.)")
