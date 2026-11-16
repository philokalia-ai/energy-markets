#!/usr/bin/env python3
"""Save a NEW, immutable public zone-JSON snapshot; no auth or production writes."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time
from urllib.request import Request, urlopen

ZONES = sorted('AT BE BG CH CZ DE_LU DK1 DK2 EE ES FI FR GR HU IT-NORTH IT-CNORTH IT-CSOUTH IT-SOUTH IT-Calabria IT-Sardinia IT-Sicily LT LV NL NO1 NO2 NO3 NO4 NO5 PL PT RO RS SE1 SE2 SE3 SE4 SI SK'.split())

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {'fetch_started_utc': datetime.now(timezone.utc).isoformat(),
                'source': 'https://api.philokalia.ai/api/v1/zones/', 'files': []}
    for zone in ZONES:
        url = manifest['source'] + zone
        request = Request(url, headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'})
        with urlopen(request, timeout=90) as response:
            payload = response.read()
        data = json.loads(payload)
        if data.get('zone') != zone or not isinstance(data.get('days'), list):
            raise ValueError('Unexpected zone payload: ' + zone)
        path = args.output / (zone + '.json')
        path.write_bytes(payload)
        manifest['files'].append({'zone': zone, 'filename': path.name, 'sha256': hashlib.sha256(payload).hexdigest(),
                                  'bytes': len(payload), 'fetched_utc': datetime.now(timezone.utc).isoformat()})
        (args.output / 'snapshot-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(zone, len(payload), flush=True)
        time.sleep(0.5)
    manifest['fetch_finished_utc'] = datetime.now(timezone.utc).isoformat()
    (args.output / 'snapshot-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    main()
