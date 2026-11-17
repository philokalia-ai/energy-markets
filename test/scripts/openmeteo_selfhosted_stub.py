#!/usr/bin/env python3
"""Stand-in for the self-hosted open-meteo previous-runs endpoint (#431 R3 repro).

Answers HTTP 200 in the open-meteo shape for the requested cells / hourly vars /
dates, with every value NULL before CUTOFF (ISO, UTC) and real values from the
public previous-runs API after it — the two shapes the production instance gave
the cv44 backfill: all-null (CUTOFF in the future) and partial (history starting
mid-window). Hours before the cutoff never hit the public API from here.

    python3 openmeteo_selfhosted_stub.py PORT CUTOFF
"""
import json, sys, urllib.parse, urllib.request
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PUBLIC = "https://previous-runs-api.open-meteo.com/v1/forecast"
PORT, CUTOFF = int(sys.argv[1]), datetime.fromisoformat(sys.argv[2])


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        sys.stderr.write("stub: " + (a[0] % a[1:]) + "\n")

    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        lats, lons = q["latitude"][0].split(","), q["longitude"][0].split(",")
        hvars = q["hourly"][0].split(",")
        d0, d1 = (datetime.fromisoformat(q[k][0]) for k in ("start_date", "end_date"))
        times = []
        t = d0
        while t < d1 + timedelta(days=1):
            times.append(t)
            t += timedelta(hours=1)
        real = None
        if times[-1] >= CUTOFF:   # some hours after the cutoff: take them from public
            with urllib.request.urlopen(PUBLIC + "?" + urllib.parse.urlparse(self.path).query, timeout=120) as r:
                real = json.load(r)
            real = real if isinstance(real, list) else [real]
        out = []
        for i, (la, lo) in enumerate(zip(lats, lons)):
            hourly = {"time": [x.strftime("%Y-%m-%dT%H:%M") for x in times]}
            for v in hvars:
                src = real[i]["hourly"][v] if real is not None else [None] * len(times)
                hourly[v] = [src[k] if times[k] >= CUTOFF else None for k in range(len(times))]
            out.append({"latitude": float(la), "longitude": float(lo), "hourly": hourly})
        body = json.dumps(out if len(out) > 1 else out[0]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
