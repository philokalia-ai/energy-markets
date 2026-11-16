#!/usr/bin/env python3
"""Native Postgres gate-crossing regression; creates/stops its OWN local cluster.

Run: python test/scripts/test_emit_model_lines_pg.py --pg-bin /usr/lib/postgresql/16/bin
No external DSN, production configuration or credentials are read.
"""
import argparse
import datetime as dt
import getpass
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import psycopg2

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'bin'))
import emit_model_lines as eml


def contention_case(dsn, sql, guards, expected_price):
    blocker = psycopg2.connect(**dsn)
    observer = psycopg2.connect(**dsn)
    observer.autocommit = True
    cur = blocker.cursor()
    stamp = dt.datetime.now(dt.timezone.utc)
    row = ('GR', '2026-11-18 00:00+00', 'stats_gbm', 80., 37, None, stamp, '{}')
    cur.execute('TRUNCATE simulations.model_lines')
    cur.execute(eml.UPSERT_SQL, row)
    blocker.commit()
    cur.execute('SELECT * FROM simulations.model_lines FOR UPDATE')
    original = cur.fetchone()
    gate = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=2)
    result = {}
    started = threading.Event()

    def emit():
        try:
            with psycopg2.connect(**dsn) as writer:
                result['pid'] = writer.get_backend_pid()
                q = writer.cursor()
                q.execute("SET statement_timeout = '10s'")
                result['start'] = dt.datetime.now(dt.timezone.utc)
                started.set()
                q.execute(sql, (*row[:3], 999., *row[4:], *([gate] * guards)))
                result['rowcount'] = q.rowcount
            result['end'] = dt.datetime.now(dt.timezone.utc)
        except BaseException as exc:
            result['error'] = exc
            started.set()

    thread = threading.Thread(target=emit, daemon=True)
    try:
        thread.start()
        assert started.wait(3), 'writer did not connect'
        if 'error' in result:
            raise result['error']
        q = observer.cursor()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            q.execute("SELECT wait_event_type FROM pg_stat_activity WHERE pid=%s", (result['pid'],))
            if q.fetchone() == ('Lock',):
                break
            time.sleep(.02)
        else:
            raise AssertionError('writer never reached the conflicting-row lock')
        assert dt.datetime.now(dt.timezone.utc) < gate, 'writer reached lock after gate'
        # Keep the conflicting row locked until wall time has passed the gate.
        time.sleep(max(0, (gate-dt.datetime.now(dt.timezone.utc)).total_seconds()) + .25)
        blocker.commit()
        thread.join(5)
        assert not thread.is_alive(), 'writer did not finish'
        if 'error' in result:
            raise result['error']
        cur.execute('SELECT * FROM simulations.model_lines')
        persisted = cur.fetchone()
        assert result['start'] < gate < result['end'], (result, gate)
        assert persisted[3] == expected_price, (result, persisted)
        assert result['rowcount'] == (0 if expected_price == 80. else 1), result
        if expected_price == 80.:
            assert persisted == original, 'rejected update changed values or provenance/generated_at'
        print(f"guards={guards}: blocked before gate, released after; "
              f"rowcount={result['rowcount']}, price={persisted[3]}", flush=True)
    finally:
        blocker.rollback()  # unblock the writer even if an assertion failed
        thread.join(11)
        blocker.close()
        observer.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--pg-bin', required=True, type=Path)
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='ops439-pg-') as temp:
        root = Path(temp)
        data, sock = root/'data', root/'sock'
        sock.mkdir()
        subprocess.run([str(args.pg_bin/'initdb'), '-D', str(data), '-A', 'trust',
                        '--no-locale', '-E', 'UTF8'], check=True, stdout=subprocess.DEVNULL)
        pgctl = str(args.pg_bin/'pg_ctl')
        subprocess.run([pgctl, '-D', str(data), '-l', str(root/'server.log'), '-w',
                        '-o', f"-F -k {sock} -p 55439 -c listen_addresses=''", 'start'],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            dsn = dict(host=str(sock), port=55439, dbname='postgres', user=getpass.getuser())
            with psycopg2.connect(**dsn) as cx:
                cur = cx.cursor()
                cur.execute('CREATE SCHEMA simulations')
                cur.execute('''CREATE TABLE simulations.model_lines (
                    bidding_zone TEXT, date_time_utc TIMESTAMPTZ, model TEXT,
                    price_eur_mwh DOUBLE PRECISION, code_version INTEGER,
                    base_code_version INTEGER, issue_utc TIMESTAMPTZ, source_manifest JSONB,
                    generated_at TIMESTAMPTZ DEFAULT now(),
                    UNIQUE(bidding_zone,date_time_utc,model,code_version))''')
            # Positive control reproduces the review finding with the old SELECT-only guard.
            old_sql = eml.UPSERT_SQL.replace(
                'VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb)',
                'SELECT %s, %s, %s, %s, %s, %s, %s, %s::jsonb WHERE clock_timestamp() < %s')
            contention_case(dsn, old_sql, 1, 999.)
            contention_case(dsn, eml.UPSERT_STRICT_SQL, 2, 80.)
            print('PASS: native Postgres conflict predicate rechecks gate after lock wait', flush=True)
        finally:
            subprocess.run([pgctl, '-D', str(data), '-m', 'immediate', '-w', 'stop'],
                           check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
