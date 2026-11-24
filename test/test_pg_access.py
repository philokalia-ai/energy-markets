"""Static Postgres access guard (owner rule: DuckDB always sits between Postgres and Julia; Julia reads Postgres
only in the fill, bin/fill_run_duckdb.jl, and writes it only in the transfers). The runtime half is
src/db/postgres_core.jl `_postgres_guard` (test/test_pg_guard.jl).

Two checks, both against test/pg_access_allowlist.toml:
  1. Files: every tracked file under bin/ and src/ is scanned for Postgres-access lines (LibPQ, withdb,
     newconnection, preinit_pool, ENERGY_CONN_STR / WEATHER_CONN_STR, the DuckDB postgres extension, psycopg, psql,
     read_sql, a forced Postgres store). A file with such lines must be listed with its line count; the test fails
     on an unlisted file or a count above the listed one. A listed file whose count dropped must be lowered (so the
     list only shrinks); a listed file with no hits left must be removed.
  2. Workflows: a step whose env carries ENERGY_CONN_STR / WEATHER_CONN_STR may run only the allowed Postgres
     scripts (fill, transfers, extract refresh) or a listed known-gap step; a step that runs a Julia job script
     with Euphemia must use the DuckDB store (step env, or EUPHEMIA_DATA_STORE=duckdb exported to $GITHUB_ENV by an
     earlier step of the same job) unless the step is listed.

Run:  python3 -m unittest discover -s test -p test_pg_access.py      (repo-hygiene.yml)
      python3 test/test_pg_access.py --print                          (current counts, to update the TOML)
"""
import functools
import re
import subprocess
import sys
import tomllib
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "test" / "pg_access_allowlist.toml"

JULIA = [r"\bLibPQ\b", r"\b(?:withdb|newconnection|preinit_pool)\s*\(", r"\b(?:ENERGY|WEATHER)_CONN_STR\b",
         r"(?i:TYPE\s+postgres)", r"\bpostgres_(?:scan|query|execute|attach)\b", r"\battach_postgres!",
         r"(?i:\b(?:INSTALL|LOAD)\s+postgres\b)", r"EUPHEMIA_DATA_STORE.{0,6}postgres", r"backend\s*=\s*:postgres"]
SCRIPT = [r"psycopg", r"(?i:TYPE\s+postgres)", r"\bpsql\b", r"\bread_sql", r"EUPHEMIA_DATA_STORE=postgres",
          r"\b(?:ENERGY|WEATHER)_CONN_STR\b", r"\bpostgres_(?:scan|query|execute|attach)\b"]
RX = {".jl": re.compile("|".join(JULIA)), ".py": re.compile("|".join(SCRIPT)), ".sh": re.compile("|".join(SCRIPT))}

# Scripts a step with Postgres credentials may run (the allowed Postgres access) and scripts that do not load
# Euphemia (no data store involved).
PG_SCRIPTS = {"bin/fill_run_duckdb.jl", "bin/transfer_run_results.jl", "bin/transfer_results_to_postgres.jl",
              "bin/refresh_duckdb_extract.jl"}
NO_STORE = {"bin/capture_gfs_vintages.jl", "bin/export_prediction_scorecard.jl", "bin/transfer_run_results.jl",
            "bin/forecast_presence.jl"}
SCRIPT_RX = re.compile(r"\b(?:julia|python3?|\.venv[\w-]*/bin/python|bash)\b[^\n]*?\b(bin/[\w./-]+\.(?:jl|py|sh))(?:[ \t]+([a-z][\w-]*))?")
# bin/measure_duckdb_path.jl loads Euphemia (a data store) only for `clear`; its other subcommands read files.
STORELESS_SUBCMD = {"bin/measure_duckdb_path.jl": {"compare", "trace-diff", "fill-sums", "fill-diff"}}


def invocations(run):
    """(script, uses_euphemia) for each bin/ script a step's run text starts."""
    out = []
    for script, sub in SCRIPT_RX.findall(run):
        storeless = script in NO_STORE or sub in STORELESS_SUBCMD.get(script, ())
        out.append((script, not storeless))
    return out


@functools.lru_cache(maxsize=None)
def scan():
    files = subprocess.run(["git", "ls-files", "bin", "src"], cwd=ROOT, capture_output=True, text=True,
                           check=True).stdout.split()
    counts = {}
    for f in files:
        rx = RX.get(Path(f).suffix)
        if rx is None:
            continue
        n = sum(1 for line in (ROOT / f).read_text(errors="replace").splitlines()
                if rx.search(line) and not line.lstrip().startswith("#"))   # comment lines are not access
        if n:
            counts[f] = n
    return counts


def allowlist():
    t = tomllib.loads(ALLOWLIST.read_text())
    files = {}
    for section in ("allowed", "legacy", "known_gap"):
        for f, v in t.get(section, {}).items():
            files[f] = (section, v["lines"])
    return files, t.get("workflow_steps", {})


def workflow_steps():
    for wf in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        d = yaml.safe_load(wf.read_text())
        for job in (d.get("jobs") or {}).values():
            duck_env = (job.get("env") or {}).get("EUPHEMIA_DATA_STORE") == "duckdb"
            for st in job.get("steps") or []:
                run = st.get("run") or ""
                env = st.get("env") or {}
                yield wf.name, st.get("name", ""), run, env, duck_env
                if re.search(r"EUPHEMIA_DATA_STORE=duckdb", run) and "GITHUB_ENV" in run:
                    duck_env = True   # exported for every later step of this job


def credential_violation(run, env, known=frozenset(), key=""):
    """Scripts a step with Postgres credentials runs beyond the allowed ones (empty = fine)."""
    if not ({"ENERGY_CONN_STR", "WEATHER_CONN_STR"} & set(env)) or key in known:
        return set()
    have = scan()
    # allowed: the Postgres scripts, storeless invocations, and .py/.sh helpers with no Postgres access
    # (clock guards such as bin/blackout_window.py, bin/rescore_guard.sh)
    return {sc for sc, euph in invocations(run) if sc not in PG_SCRIPTS
            and (euph if sc.endswith(".jl") else sc in have)}


def store_violation(run, env, duck_env, exempt=frozenset(), key=""):
    """Julia job scripts a step runs without the DuckDB store (empty = fine)."""
    jobs = {sc for sc, euph in invocations(run) if sc.endswith(".jl") and euph} - PG_SCRIPTS
    if not jobs or key in exempt:
        return set()
    inline = re.search(r"(?:^|\s)EUPHEMIA_DATA_STORE=duckdb\b", run)   # VAR=value prefix on the command
    return set() if (env.get("EUPHEMIA_DATA_STORE") == "duckdb" or duck_env or inline) else jobs


class PgAccess(unittest.TestCase):
    def test_files_match_the_allowlist(self):
        have, (listed, _) = scan(), allowlist()
        new = {f: n for f, n in have.items() if f not in listed}
        grew = {f: (n, listed[f][1]) for f, n in have.items() if f in listed and n > listed[f][1]}
        self.assertFalse(new, "Postgres access in files not on test/pg_access_allowlist.toml (Julia reads Postgres "
                              f"only in the fill and writes it only in the transfers): {new}")
        self.assertFalse(grew, f"more Postgres-access lines than allowed (now, allowed): {grew}")

    def test_allowlist_only_shrinks(self):
        have, (listed, _) = scan(), allowlist()
        stale = {f: (have.get(f, 0), n) for f, (_, n) in listed.items() if have.get(f, 0) < n}
        self.assertFalse(stale, "lower these counts (or remove the entry) in test/pg_access_allowlist.toml "
                                f"(now, listed): {stale}")

    def test_workflow_steps_with_postgres_credentials(self):
        _, ws = allowlist()
        known = frozenset(ws.get("known_gap", [])) | frozenset(ws.get("postgres_store", []))
        bad = [f"{wf}::{name} runs {sorted(v)} with Postgres credentials" for wf, name, run, env, _ in workflow_steps()
               if (v := credential_violation(run, env, known, f"{wf}::{name}"))]
        self.assertFalse(bad, "\n".join(bad))

    def test_julia_job_steps_use_the_duckdb_store(self):
        _, ws = allowlist()
        exempt = frozenset(ws.get("postgres_store", []))
        bad = [f"{wf}::{name} runs {sorted(v)} without EUPHEMIA_DATA_STORE=duckdb"
               for wf, name, run, env, duck in workflow_steps() if (v := store_violation(run, env, duck, exempt, f"{wf}::{name}"))]
        self.assertFalse(bad, "\n".join(bad))

    def test_the_workflow_rules_catch_violations(self):   # synthetic steps
        pg = {"ENERGY_CONN_STR": "x"}
        self.assertEqual(credential_violation("julia --project=. bin/daily_forecast.jl", pg), {"bin/daily_forecast.jl"})
        self.assertEqual(credential_violation(".venv-overlay/bin/python bin/emit_tsfm_overlay.py --write", pg),
                         {"bin/emit_tsfm_overlay.py"})
        self.assertEqual(credential_violation("julia --project=. bin/fill_run_duckdb.jl --profile record", pg), set())
        self.assertEqual(credential_violation("python3 bin/blackout_window.py 5 && julia --project=. "
                                              "bin/transfer_run_results.jl --results-db x", pg), set())
        self.assertEqual(credential_violation("julia --project=. bin/measure_duckdb_path.jl fill-sums a b", pg), set())
        self.assertEqual(credential_violation("julia --project=. bin/measure_duckdb_path.jl clear --days x", pg),
                         {"bin/measure_duckdb_path.jl"})
        self.assertEqual(store_violation("julia --project=. bin/score_forecasts.jl", {}, False), {"bin/score_forecasts.jl"})
        self.assertEqual(store_violation("julia --project=. bin/score_forecasts.jl", {}, True), set())
        self.assertEqual(store_violation("julia --project=. bin/score_forecasts.jl",
                                         {"EUPHEMIA_DATA_STORE": "duckdb"}, False), set())
        self.assertEqual(store_violation("EUPHEMIA_DATA_STORE=duckdb \\\n  julia --project=. bin/physics_audit.jl", {}, False),
                         set())
        self.assertEqual(store_violation("julia --project=. bin/capture_gfs_vintages.jl", {}, False), set())

    def test_patterns_catch_the_primitives(self):   # the scanner itself
        for line in ('Euphemia.withdb() do cnx', 'cnx = LibPQ.Connection(s)', 'get(ENV, "ENERGY_CONN_STR", "")',
                     'ATTACH x AS pg (TYPE postgres, READ_ONLY)', 'ENV["EUPHEMIA_DATA_STORE"] = "postgres"'):
            self.assertTrue(RX[".jl"].search(line), line)
        for line in ("import psycopg2", 'psql "$ENERGY_CONN_STR" -c', "pd.read_sql(q, con)"):
            self.assertTrue(RX[".py"].search(line), line)
        self.assertFalse(RX[".jl"].search("df = sql2df(q)  # dispatches on the store"))


if __name__ == "__main__":
    if "--print" in sys.argv:
        listed, _ = allowlist() if ALLOWLIST.exists() else ({}, {})
        for f, n in sorted(scan().items()):
            print(f'"{f}" = {{ lines = {n} }}  # {listed.get(f, ("NEW",))[0]}')
    else:
        unittest.main()
