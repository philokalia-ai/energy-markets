# Fetch 100m wind + GHI from public open-meteo: ERA5 archive (truth-side
# features) and previous-runs (honest lead-1/2 GFS vintages), for the study
# year, at the selected cells. Stdlib only.
import json, time, csv, sys, urllib.request, urllib.parse

SP = "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/res"
START, END = "2025-07-01", "2026-06-30"

def get(url, params, tries=5):
    q = url + "?" + urllib.parse.urlencode(params)
    for i in range(tries):
        try:
            with urllib.request.urlopen(q, timeout=60) as r:
                return json.loads(r.read())
        except Exception as e:
            print(f"  retry {i+1}: {e}", flush=True)
            time.sleep(5 * (i + 1))
    raise RuntimeError(f"failed: {q[:120]}")

def cells(path, limit=None, step=1):
    out = []
    for ln in open(path):
        p = ln.strip().split("|")
        if len(p) >= 4:
            out.append((int(p[0]), float(p[2]), float(p[3])))
    out = out[::step]
    return out[:limit] if limit else out

wind = cells(f"{SP}/wind_cells40.txt")
solar_all = [ (int(p[0]), float(p[2]), float(p[3]))
              for p in (ln.strip().split("|") for ln in open(f"{SP}/solar_cells.txt")) if len(p) >= 4 ]
solar = solar_all[::7][:20]
print(f"wind cells: {len(wind)}, solar cells: {len(solar)}", flush=True)

def fetch(cs, endpoint, hourly, outfile, extra=None):
    with open(outfile, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["city_id", "h"] + hourly)
        for i, (cid, lat, lon) in enumerate(cs):
            params = {"latitude": lat, "longitude": lon, "hourly": ",".join(hourly),
                      "start_date": START, "end_date": END, "timezone": "UTC"}
            if extra: params.update(extra)
            d = get(endpoint, params)
            hh = d["hourly"]
            for j, t in enumerate(hh["time"]):
                w.writerow([cid, t] + [hh[v][j] for v in hourly])
            print(f"  [{i+1}/{len(cs)}] {cid}", flush=True)
            time.sleep(0.4)

ARCH = "https://archive-api.open-meteo.com/v1/archive"
PREV = "https://previous-runs-api.open-meteo.com/v1/forecast"

fetch(wind, ARCH, ["wind_speed_100m"], f"{SP}/wind_arch100.csv")
fetch(wind, PREV, ["wind_speed_100m_previous_day1", "wind_speed_100m_previous_day2"],
      f"{SP}/wind_prev100.csv", {"models": "gfs_seamless"})
fetch(solar, ARCH, ["shortwave_radiation"], f"{SP}/solar_arch.csv")
fetch(solar, PREV, ["shortwave_radiation_previous_day1", "shortwave_radiation_previous_day2"],
      f"{SP}/solar_prev.csv", {"models": "gfs_seamless"})
print("DONE", flush=True)
