#!/usr/bin/env python3
"""Transfer the cv18 multi_zone_eu record from data/results.duckdb (offline
compute — bin/cv18_backfill_offline.jl) into Postgres simulations.energy_prices
in one transaction: DELETE existing cv18 multi_zone_eu rows, then COPY.

Provenance: computed on the DuckDB extract; extract<->Postgres parity is
documented at <=2e-12 EUR/MWh and the Postgres column is numeric(10,2), so the
stored record is identical to a live-Postgres compute after rounding.

  python3 bin/cv18_transfer.py           # dry-run (counts only)
  python3 bin/cv18_transfer.py --apply
"""
import duckdb, os, subprocess, sys, tempfile, csv

EM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CV, MODE = 18, "multi_zone_eu"

con = duckdb.connect(os.path.join(EM, "data", "results.duckdb"), read_only=True)
cols = {r[0] for r in con.execute(
    "SELECT column_name FROM information_schema.columns "
    "WHERE table_schema='simulations' AND table_name='energy_prices'").fetchall()}
need = ["date_time_utc", "resolution_code", "bidding_zone", "contract_type",
        "price_eur_mwh", "currency", "order_method", "code_version",
        "update_time_utc", "clearing_mode", "optimizer"]
sel = ", ".join(c if c in cols else
                {"currency": "'EUR' AS currency",
                 "optimizer": "NULL AS optimizer"}.get(c, f"NULL AS {c}")
                for c in need)
df = con.execute(f"""
    SELECT {sel} FROM simulations.energy_prices
    WHERE code_version={CV} AND clearing_mode='{MODE}'
    ORDER BY date_time_utc, bidding_zone""").df()
days = con.execute(f"""
    SELECT COUNT(DISTINCT CAST(date_time_utc AS DATE)) FROM simulations.energy_prices
    WHERE code_version={CV} AND clearing_mode='{MODE}'""").fetchone()[0]
print(f"results.duckdb: {len(df):,} rows, {days} days, "
      f"{df.bidding_zone.nunique()} zones for cv{CV}/{MODE}")

if "--apply" not in sys.argv:
    print("dry-run (pass --apply to transfer)"); sys.exit(0)

with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, newline="") as f:
    df.to_csv(f, index=False, header=False, quoting=csv.QUOTE_MINIMAL)
    path = f.name
sql = f"""
BEGIN;
DELETE FROM simulations.energy_prices WHERE code_version={CV} AND clearing_mode='{MODE}';
\\copy simulations.energy_prices (date_time_utc, resolution_code, bidding_zone, contract_type, price_eur_mwh, currency, order_method, code_version, update_time_utc, clearing_mode, optimizer) FROM '{path}' WITH (FORMAT csv);
COMMIT;
SELECT COUNT(*), COUNT(DISTINCT date_time_utc::date) FROM simulations.energy_prices
WHERE code_version={CV} AND clearing_mode='{MODE}';
"""
with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
    f.write(sql); spath = f.name
r = subprocess.run(f"set -a && . {EM}/.env >/dev/null 2>&1 && set +a && "
                   f"psql \"$ENERGY_CONN_STR\" -f {spath}",
                   shell=True, capture_output=True, text=True)
print(r.stdout[-600:]); r.returncode and print("STDERR:", r.stderr[-400:])
os.unlink(path); os.unlink(spath)
