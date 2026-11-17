"""Summarize offline SQL timings and optional parameter/zone traces."""
import argparse
import collections
import csv
import hashlib
import json
from pathlib import Path


def family(sql):
    if 'SELECT MAX(date_time_utc) AS last_obs' in sql:
        return 'feed_anchor'
    if 'WITH active_outages AS' in sql or 'WITH recent_generation AS' in sql:
        return 'generator_registry'
    if 'AVG(flow_mw) AS avg_flow' in sql:
        return 'analogue_flow_day_relation'
    if 'AS capacity_mw' in sql and 'SELECT DISTINCT generation_unit_code' in sql:
        return 'registry_quarantine_warnings'
    for phrase, label in [
        ('FROM entsoe.day_ahead_total_load_forecast', 'day_ahead_load'),
        ('FROM entsoe.generation_forecasts_for_wind_and_solar', 'day_ahead_res'),
        ('FROM entsoe.aggregated_hydro_storage_filling_rate', 'reservoir'),
        ('FROM entsoe.actual_total_load', 'analogue_load_history'),
        ('FROM entsoe.unavailability_in_the_transmission_grid', 'transmission_outages'),
        ('FROM jao.', 'jao'), ('offered_transfer_capacities', 'offered_atc'),
    ]:
        if phrase in sql:
            return label
    if 'percentile_cont(0.95)' in sql and 'FROM entsoe.aggregated_generation_per_type' in sql:
        return 'fleet_hydro_batch'
    return 'other'


def summarize(directory, label, days):
    out = {}
    all_trace = []
    for day in days:
        path = directory / f'queries-{label}-{day}.tsv'
        groups = collections.defaultdict(lambda: {'calls': 0, 'execute_s': 0.0})
        for line in path.read_text().splitlines():
            n, secs, sql = line.split('\t', 2)
            group = groups[family(sql)]
            group['calls'] += int(n)
            group['execute_s'] += float(secs)
        record = {'families': dict(groups), 'query_summary_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        prices = directory / f'{label}-{day}.csv'
        if prices.exists():
            record['forecast_sha256'] = hashlib.sha256(prices.read_bytes()).hexdigest()
            record['forecast_rows'] = len(prices.read_text().splitlines()) - 1
        trace = directory / f'query-trace-{label}-{day}.tsv'
        if trace.exists():
            with trace.open() as handle:
                rows = list(csv.DictReader(handle, delimiter='\t'))
            all_trace.extend(rows)
            record['trace_sha256'] = hashlib.sha256(trace.read_bytes()).hexdigest()
            record['reuse'] = reuse_summary(rows)
            zones = collections.defaultdict(lambda: {'calls': 0, 'execute_s': 0.0, 'duckdb_lock_wait_s': 0.0})
            for row in rows:
                group = zones[row['zone']]
                group['calls'] += 1
                group['execute_s'] += float(row['execute_s'])
                group['duckdb_lock_wait_s'] += float(row['lock_wait_s'])
            record['zone_queries'] = dict(sorted(zones.items()))
            zone_path = directory / f'zone-trace-{label}-{day}.tsv'
            with zone_path.open() as handle:
                zone_rows = list(csv.DictReader(handle, delimiter='\t'))
            durations = [float(row['wall_s']) for row in zone_rows]
            record['zone_builds_summary'] = {
                'count': len(durations), 'min_task_wall_s': min(durations),
                'max_task_wall_s': max(durations),
                'sum_overlapping_task_wall_s': sum(durations),
            }
        out[day] = record
    if all_trace:
        out['combined_reuse'] = reuse_summary(all_trace)
    return out


def reuse_summary(rows):
    out = {}
    for label in sorted({family(row['sql']) for row in rows}):
        subset = [row for row in rows if family(row['sql']) == label]
        same_issue = {(r['issuance'], r['query_sha256'], r['args_sha256']) for r in subset}
        raw = {(r['query_sha256'], r['args_sha256']) for r in subset}
        out[label] = {'calls': len(subset), 'distinct_query_args_issuance': len(same_issue),
                      'distinct_query_args': len(raw)}
    return out


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('label')
    parser.add_argument('out', type=Path)
    parser.add_argument('days', nargs='+')
    args = parser.parse_args()
    args.out.write_text(json.dumps(summarize(args.directory, args.label, args.days), indent=2) + '\n')
