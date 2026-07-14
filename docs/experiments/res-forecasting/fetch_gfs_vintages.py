# Fetch honest lead-1 GFS vintages (wind_speed_100m_previous_day1) for all
# cells of the 37 wind zones in bin/res_models_v1.json, from the public
# open-meteo previous-runs API. Batched (50 locations/call), date-chunked
# (2 months), cached per (chunk,batch) JSON in raw/ -> fully resumable.
import json, os, sys, time, urllib.request, urllib.parse

SP = os.environ.get("GFS_OUT", os.path.expanduser("~/.cache/euphemia-gfs-refit"))
RAW = os.path.join(SP, "raw")
os.makedirs(RAW, exist_ok=True)
PACK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "bin", "res_models_v1.json")
PREV = "https://previous-runs-api.open-meteo.com/v1/forecast"
VAR = "wind_speed_100m_previous_day1"
BATCH = 50

pack = json.load(open(PACK))
zones = sorted(z for z, v in pack["zones"].items() if "wind" in v)
cells = []
seen = set()
for z in zones:
    for c in pack["zones"][z]["cells"]:
        t = (float(c[0]), float(c[1]))
        if t not in seen:
            seen.add(t)
            cells.append(t)
print(f"{len(zones)} wind zones, {len(cells)} distinct cells", flush=True)
json.dump(cells, open(os.path.join(SP, "cells.json"), "w"))

# date chunks: 2-month windows 2024-07-01 .. 2026-06-30
chunks = []
for y, m in [(y, m) for y in (2024, 2025, 2026) for m in (1, 3, 5, 7, 9, 11)]:
    if (y, m) < (2024, 7) or (y, m) > (2026, 5):
        continue
    m2, y2 = (m + 2, y) if m + 2 <= 12 else (m + 2 - 12, y + 1)
    from datetime import date, timedelta
    end = date(y2, m2, 1) - timedelta(days=1)
    chunks.append((f"{y}-{m:02d}-01", end.isoformat()))
print("chunks:", chunks, flush=True)

def get(url, tries=12):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "philokalia-energy/1.0 (contact: p.georgakopoulos@silentech.gr)"})
            with urllib.request.urlopen(req, timeout=180) as r:
                return json.loads(r.read())
        except Exception as e:
            body = ""
            try:
                body = e.read().decode()[:200]
            except Exception:
                pass
            if "429" in str(e):
                if "Daily" in body:
                    print(f"  DAILY limit hit: {body} — sleeping 30 min", flush=True)
                    time.sleep(1800)
                else:
                    # hourly cap: sleep to the next UTC hour boundary + 90s
                    import datetime
                    now = datetime.datetime.utcnow()
                    wait = (60 - now.minute) * 60 - now.second + 90
                    print(f"  hourly limit: sleeping {wait}s to next hour", flush=True)
                    time.sleep(wait)
            else:
                wait = 8 * (i + 1)
                print(f"  retry {i+1}: {e} (sleep {wait}s)", flush=True)
                time.sleep(wait)
    raise RuntimeError("failed: " + url[:140])

nb = (len(cells) + BATCH - 1) // BATCH
total = nb * len(chunks)
done = 0
chunk_iter = list(enumerate(chunks))
if os.environ.get("REVERSE"):
    chunk_iter = chunk_iter[::-1]
elif os.environ.get("PRIORITY"):
    # holdout first (c11, c10), then remaining train newest-first
    order = [11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
    chunk_iter = [chunk_iter[i] for i in order]
PACE = float(os.environ.get("PACE", "1.5"))
for ci, (d0, d1) in chunk_iter:
    for bi in range(nb):
        done += 1
        out = os.path.join(RAW, f"c{ci:02d}_b{bi:02d}.json")
        if os.path.exists(out) and os.path.getsize(out) > 1000:
            continue
        batch = cells[bi * BATCH:(bi + 1) * BATCH]
        lats = ",".join(str(c[0]) for c in batch)
        lons = ",".join(str(c[1]) for c in batch)
        url = (PREV + "?latitude=" + lats + "&longitude=" + lons +
               "&hourly=" + VAR + "&models=gfs_seamless" +
               "&start_date=" + d0 + "&end_date=" + d1 + "&timezone=UTC")
        d = get(url)
        locs = d if isinstance(d, list) else [d]
        assert len(locs) == len(batch), f"{len(locs)} != {len(batch)}"
        tmp = out + ".tmp"
        json.dump(locs, open(tmp, "w"))
        os.replace(tmp, out)
        print(f"[{done}/{total}] chunk {d0}..{d1} batch {bi} ok", flush=True)
        time.sleep(PACE)
print("DONE", flush=True)
