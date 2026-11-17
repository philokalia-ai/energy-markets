"""Extract phase intervals from an existing GitHub Actions log; no network/DB access."""
import argparse
import datetime as dt
import hashlib
import json
import re
from pathlib import Path


def analyze(path):
    raw = path.read_bytes()
    clears, days, weather = [], [], []
    current = None
    for line in raw.decode().splitlines():
        match = re.search(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z (.*)', line)
        if not match:
            continue
        stamp = dt.datetime.fromisoformat(match[1])
        msg = match[2]
        start = re.search(r'clearing UTC day (\d{4}-\d\d-\d\d)', msg)
        if start:
            current = {'utc_day': start[1], 'start': stamp}
        if current is not None:
            markers = {
                'Creating multi-zone order book...': 'book1_start',
                'Running multi-zone market clearing optimization...': 'solve1_start',
                'PASS 2: opportunity-anchored re-clear': 'book2_start',
                'Running pass-2 market clearing optimization...': 'solve2_start',
                'Pass 2 accepted (status=': 'solve2_end',
            }
            for phrase, key in markers.items():
                if phrase in msg:
                    current[key] = stamp
            accepted = re.search(r'solve=([\d.]+)s; pass 1 was ([\d.]+)s', msg)
            if accepted:
                current['reported_pass1_s'] = float(accepted[2])
                current['reported_pass2_s'] = float(accepted[1])
            done = re.search(r'UTC day .* cleared in ([\d.]+)s', msg)
            if done:
                current['reported_clear_s'] = float(done[1])
                for label, a, b in [
                    ('book1_s', 'book1_start', 'solve1_start'),
                    ('solve1_scope_s', 'solve1_start', 'book2_start'),
                    ('book2_s', 'book2_start', 'solve2_start'),
                    ('solve2_scope_s', 'solve2_start', 'solve2_end'),
                ]:
                    current[label] = (current[b] - current[a]).total_seconds()
                clears.append({k: v.isoformat() if isinstance(v, dt.datetime) else v
                               for k, v in current.items()})
                current = None
        day = re.search(r'⏱\s+(\d{4}-\d\d-\d\d) lead=1: ([\d.]+) s \(written\)', msg)
        if day:
            pair = clears[-2:]
            days.append({
                'market_day': day[1], 'wall_s': float(day[2]),
                'clear_s': sum(c['reported_clear_s'] for c in pair),
                'book_s': sum(c['book1_s'] + c['book2_s'] for c in pair),
                'solve_scope_s': sum(c['solve1_scope_s'] + c['solve2_scope_s'] for c in pair),
                'outside_clears_s_rounded': float(day[2]) - sum(c['reported_clear_s'] for c in pair),
            })
        if 'chunk ' in msg or 'ready in' in msg or 'rate-limited' in msg:
            weather.append({'utc': stamp.isoformat(), 'message': msg})
    assert len(clears) == 2 * len(days), 'incomplete run or unexpected clear/day pairing'
    return {'run_id': 43990408427, 'log_sha256': hashlib.sha256(raw).hexdigest(),
            'method': 'Timestamp differences from existing log markers; solver scopes include model/backend work; books include network enrichment and assembly, not SQL-only timings.',
            'market_days': days, 'clears': clears, 'weather_events': weather}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    args.out.write_text(json.dumps(analyze(args.log), indent=2) + '\n')
