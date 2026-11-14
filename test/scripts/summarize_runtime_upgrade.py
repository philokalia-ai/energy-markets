"""Summarize benchmark_runtime_upgrade.jl JSON; optional read-only DuckDB scoring.

Usage: python summarize_runtime_upgrade.py RESULTS_DIR [EXTRACT.duckdb]
The optional scoring query selects the SDAC numeric sequence (descending,
then update timestamp), as used by live actuals. Hourly means are rounded to
8 decimals before nonpositive labels. This never opens a writable database.
"""
import csv
import datetime as dt
import json
import math
from pathlib import Path
import statistics as stats
import struct
import sys


def write_csv(path, rows):
    if rows:
        with path.open("w") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)


def cells(day):
    return {(zone, period): price for zone, periods in day.get("prices", {}).items()
            for period, price in periods.items()}


def period_time(date, period):
    if "-" in period:
        return dt.datetime.strptime(period, "%Y%m%d-%H%M")
    return dt.datetime.fromisoformat(date) + dt.timedelta(hours=int(period) - 1)


def selected_period_calls(solves):
    """Keep the last attempt per chronological period/pass, excluding retries.

    This benchmark's EU books use sorted YYYYMMDD-HHMM periods. A descending
    timestamp marks the next pass; an equal timestamp is the existing retry
    ladder. Non-decomposed calls are reported separately, without this inference.
    """
    if not solves or any(len(row["periods"]) != 1 for row in solves):
        return []
    selected = {}
    pass_number, previous = 1, None
    for row in solves:
        period = row["periods"][0]
        if previous is not None and period < previous:
            pass_number += 1
        selected[pass_number, period] = row
        previous = period
    return list(selected.values())


def metrics(pairs):
    actual = [a for _, a in pairs]
    sim = [s for s, _ in pairs]
    differences = [s - a for s, a in pairs]
    av, sv = stats.mean(actual), stats.mean(sim)
    cov = sum((s - sv) * (a - av) for s, a in pairs)
    denominator = math.sqrt(sum((s - sv)**2 for s in sim) * sum((a - av)**2 for a in actual))
    actual_zero = [round(a, 8) <= 0 for a in actual]
    sim_zero = [round(s, 8) <= 0 for s in sim]
    zeros = sum(actual_zero)
    hits = sum(s and a for s, a in zip(sim_zero, actual_zero))
    false_alarms = sum(s and not a for s, a in zip(sim_zero, actual_zero))
    return dict(n=len(pairs), mae=stats.mean(map(abs, differences)), bias=stats.mean(differences),
                corr=cov / denominator if denominator else None,
                actual_nonpositive=zeros, hits=hits, hit_rate=hits / zeros if zeros else None,
                false_alarms=false_alarms,
                false_alarm_rate=false_alarms / (len(pairs) - zeros) if len(pairs) > zeros else None)


def main():
    root = Path(sys.argv[1])
    configs = {name: json.loads((root / (name + ".json")).read_text())
               for name in ("baseline", "old12", "source_old_new12", "new12", "new14", "stable13", "monolithic")
               if (root / (name + ".json")).is_file()}
    performance, parity, differences = [], [], []
    for name, data in configs.items():
        for day in data["days"]:
            solves = day.get("solver_calls", [])
            native = [r["native_solve_seconds"] for r in solves if r.get("native_solve_seconds") is not None]
            gaps = [float(r["relative_gap"]) for r in solves if r.get("relative_gap") is not None]
            gaps = [gap for gap in gaps if not math.isnan(gap)]
            selected = selected_period_calls(solves)
            selected_gaps = [float(row["relative_gap"]) for row in selected
                             if row.get("relative_gap") is not None]
            selected_gaps = [gap for gap in selected_gaps if not math.isnan(gap)]
            performance.append(dict(config=name, julia=data["julia"], highs=data["highs"],
                date=day["date"], status=day["status"], cells=day.get("cells", 0),
                cold_clear=day["first_clear_in_process"], wall_seconds=day["wall_seconds"],
                book_builds=len(day["book_seconds"]),
                book_seconds=sum(day["book_seconds"]),
                library_solve_seconds=sum(r["library_solve_seconds"] for r in solves),
                unattributed_wall_seconds=day["wall_seconds"] - sum(day["book_seconds"]) -
                    sum(r["library_solve_seconds"] for r in solves),
                native_solve_seconds=sum(native), native_calls=len(native),
                nonoptimal_calls=sum(r["status"] != "OPTIMAL" for r in solves),
                no_incumbent_calls=sum(not r["has_values"] for r in solves),
                max_relative_gap=max(gaps, default=None),
                selected_periods=len(selected),
                selected_nonoptimal=sum(row["status"] != "OPTIMAL" for row in selected),
                selected_no_incumbent=sum(not row["has_values"] for row in selected),
                selected_max_gap=max(selected_gaps, default=None),
                native_period_median=stats.median(native) if native else None,
                native_period_max=max(native, default=None),
                links=max((r["links"] for r in solves), default=None),
                sampled_rss_mib=day["peak_rss_sampled_mib"],
                process_hwm_mib=day["process_peak_rss_mib"],
                startup_seconds=day.get("process_startup_seconds", data["startup_to_ready_seconds"])))
    comparisons = [("baseline", name) for name in ("old12", "new12", "new14", "stable13")]
    comparisons += [("baseline", "source_old_new12"), ("source_old_new12", "new12"), ("old12", "new12"), ("old12", "stable13"), ("new12", "new14"), ("new12", "stable13"), ("new14", "stable13")]
    book_parity, objective_comparison = [], []
    for reference, name in comparisons:
        baseline = {day["date"]: day for day in configs.get(reference, {}).get("days", [])}
        for day in configs.get(name, {}).get("days", []):
            if day["date"] not in baseline:
                continue
            for index, (old_book, new_book) in enumerate(zip(
                    baseline[day["date"]].get("book_fingerprints", []),
                    day.get("book_fingerprints", [])), 1):
                book_parity.append(dict(reference=reference, config=name, date=day["date"],
                    pass_number=index, reference_orders=old_book["orders"],
                    treatment_orders=new_book["orders"],
                    order_sequence_identical=old_book["order_sequence_sha256"] == new_book["order_sequence_sha256"],
                    order_multiset_identical=old_book["order_multiset_sha256"] == new_book["order_multiset_sha256"],
                    capacities_identical=old_book["capacity_sha256"] == new_book["capacity_sha256"],
                    nodes_identical=old_book["nodes"] == new_book["nodes"],
                    periods_identical=old_book["periods"] == new_book["periods"]))
            old_calls = selected_period_calls(baseline[day["date"]].get("solver_calls", []))
            new_calls = selected_period_calls(day.get("solver_calls", []))
            for index, (old_call, new_call) in enumerate(zip(old_calls, new_calls)):
                old_objective, new_objective = old_call.get("objective_value"), new_call.get("objective_value")
                if isinstance(old_objective, (int, float)) and isinstance(new_objective, (int, float)):
                    objective_comparison.append(dict(reference=reference, config=name, date=day["date"],
                        pass_number=index // 24 + 1, period=old_call["periods"][0],
                        reference_status=old_call["status"], treatment_status=new_call["status"],
                        reference_objective=old_objective, treatment_objective=new_objective,
                        objective_delta=new_objective - old_objective,
                        relative_delta=abs(new_objective - old_objective) / max(1, abs(old_objective))))
            old, new = cells(baseline[day["date"]]), cells(day)
            common = old.keys() & new.keys()
            for zone_set in ("all39", "excluding_italy32"):
                selected = [key for key in common if zone_set == "all39" or not key[0].startswith("IT-")]
                changed = [key for key in selected if struct.pack("!d", old[key]) != struct.pack("!d", new[key])]
                parity.append(dict(reference=reference, config=name, date=day["date"], zones=zone_set,
                    common=len(selected), baseline_cells=len(old), treatment_cells=len(new),
                    reference_status=baseline[day["date"]]["status"], treatment_status=day["status"],
                    bit_differences=len(changed),
                    differences_gt_1e_8=sum(abs(new[key] - old[key]) > 1e-8 for key in selected),
                    max_abs_delta=max((abs(new[key] - old[key]) for key in selected), default=None)))
                if zone_set == "all39":
                    differences.extend(dict(reference=reference, config=name, date=day["date"], zone=z, period=p,
                        baseline=old[z, p], treatment=new[z, p], delta=new[z, p] - old[z, p])
                        for z, p in sorted(changed))
    write_csv(root / "objective_comparison.csv", objective_comparison)
    write_csv(root / "book_parity.csv", book_parity)
    write_csv(root / "performance.csv", performance)
    write_csv(root / "parity.csv", parity)
    write_csv(root / "price_differences.csv", differences)
    for row in performance:
        print(row)
    for row in parity:
        print(row)
    if len(sys.argv) < 3 or not configs:
        return
    import duckdb
    dates = sorted({day["date"] for data in configs.values() for day in data["days"]})
    connection = duckdb.connect(sys.argv[2], read_only=True, config={"threads": 2})
    rows = connection.execute("""
        WITH dedup AS (
            SELECT DISTINCT ON (map_code, date_time_utc)
                map_code, date_time_utc, price_currency_mwh
            FROM entsoe.energy_prices
            WHERE contract_type='Day-ahead' AND area_type_code LIKE 'BZN%'
                AND price_currency_mwh IS NOT NULL
                AND date_time_utc >= ?::DATE AND date_time_utc < ?::DATE + INTERVAL 1 DAY
            ORDER BY map_code, date_time_utc, try_cast(trim(sequence) AS INTEGER) DESC NULLS LAST,
                update_time_utc DESC
        ) SELECT map_code, date_trunc('hour', date_time_utc), avg(price_currency_mwh)
          FROM dedup GROUP BY 1,2
    """, [dates[0], dates[-1]]).fetchall()
    actuals = {(zone, time): round(price, 8) for zone, time, price in rows}
    scores = []
    for name, data in configs.items():
        pooled = {}
        for day in data["days"]:
            by_zone = {}
            for (zone, period), price in cells(day).items():
                key = zone, period_time(day["date"], period)
                if key in actuals:
                    by_zone.setdefault(zone, []).append((price, actuals[key]))
                    pooled.setdefault(zone, []).append((price, actuals[key]))
            for zone_set in ("all39", "excluding_italy32"):
                pairs = [pair for zone, pairs in by_zone.items() for pair in pairs
                         if zone_set == "all39" or not zone.startswith("IT-")]
                if pairs:
                    scores.append(dict(config=name, date=day["date"], zone=zone_set, **metrics(pairs)))
            scores.extend(dict(config=name, date=day["date"], zone=zone, **metrics(pairs))
                          for zone, pairs in sorted(by_zone.items()))
        for zone_set in ("all39", "excluding_italy32"):
            pairs = [pair for zone, pairs in pooled.items() for pair in pairs
                     if zone_set == "all39" or not zone.startswith("IT-")]
            if pairs:
                scores.append(dict(config=name, date="pooled", zone=zone_set, **metrics(pairs)))
        scores.extend(dict(config=name, date="pooled", zone=zone, **metrics(pairs))
                      for zone, pairs in sorted(pooled.items()))
    write_csv(root / "accuracy.csv", scores)
    indexed = {(r["config"], r["date"], r["zone"]): r for r in scores}
    score_deltas = []
    for reference, name in comparisons:
        for row in scores:
            key = reference, row["date"], row["zone"]
            if row["config"] == name and key in indexed:
                old = indexed[key]
                score_deltas.append(dict(reference=reference, config=name,
                    date=row["date"], zone=row["zone"], reference_n=old["n"], treatment_n=row["n"],
                    mae_delta=row["mae"] - old["mae"], bias_delta=row["bias"] - old["bias"],
                    hits_delta=row["hits"] - old["hits"],
                    false_alarms_delta=row["false_alarms"] - old["false_alarms"]))
    write_csv(root / "score_deltas.csv", score_deltas)
    acceptance = []
    for reference, name in comparisons:
        old_days = {d["date"]: d for d in configs.get(reference, {}).get("days", [])}
        for day in configs.get(name, {}).get("days", []):
            if day["date"] not in old_days:
                continue
            for scope in ("all39", "excluding_italy32"):
                old = indexed.get((reference, day["date"], scope))
                new = indexed.get((name, day["date"], scope))
                if not old or not new:
                    continue
                calls = old_days[day["date"]].get("solver_calls", []) + day.get("solver_calls", [])
                acceptance.append(dict(reference=reference, config=name, date=day["date"], zone=scope,
                    reference_mae_2dp=format(old["mae"], ".2f"), treatment_mae_2dp=format(new["mae"], ".2f"),
                    reference_bias_2dp=format(old["bias"], ".2f"), treatment_bias_2dp=format(new["bias"], ".2f"),
                    mae_identical_2dp=format(old["mae"], ".2f") == format(new["mae"], ".2f"),
                    bias_identical_2dp=format(old["bias"], ".2f") == format(new["bias"], ".2f"),
                    all_native_optimal=bool(calls) and all(c["status"] == "OPTIMAL" for c in calls),
                    coverage_identical=old["n"] == new["n"]))
    write_csv(root / "acceptance.csv", acceptance)
    for row in scores:
        if row["date"] == "pooled":
            print(row)


if __name__ == "__main__":
    main()
