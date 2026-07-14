# D-n load-model experiment: fetch zone-city temperature/GHI history and
# honest lead-1..7 forecast vintages from the PUBLIC open-meteo APIs.
# Stdlib only. See docs/experiments/dn-load-model/README.md.
#
# Outputs (CSV, written to $DN_OUT or the default scratchpad dir):
#   era5_cities.csv    city_key,h,temperature_2m,shortwave_radiation   (truth, ERA5 archive)
#   prev_cities.csv    city_key,h,t2m_d1..t2m_d7,ghi_d1..ghi_d7        (honest GFS vintages)
#   prev_res_cells.csv cell_idx,h,v100_d1..v100_d7,ghi_d1..ghi_d7      (GR RES-pack cells)
#
# "previous_dayN" semantics (open-meteo Previous Runs API): the value for hour h
# as predicted by the model run N days earlier — i.e. an honest lead-N vintage.
# Coverage check (2026-07): gfs_seamless previous_day7 is dense from ~2024-07
# onward (a gap exists around 2024-01); ERA5 archive is dense for the whole
# training window.
import json, time, csv, os, sys, urllib.request, urllib.parse

OUT = os.environ.get("DN_OUT",
    "/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/b12b1e25-3bbc-44fb-b4b2-77f8400fd203/scratchpad/dn")
ERA5_START, ERA5_END = "2022-07-01", "2026-06-30"
PREV_START, PREV_END = "2025-07-01", "2026-06-30"   # OOS test year
ARCH = "https://archive-api.open-meteo.com/v1/archive"
PREV = "https://previous-runs-api.open-meteo.com/v1/forecast"

# (zone, city, lat, lon, population-weight in millions — metro, rough)
CITIES = [
    ("GR", "athens", 37.98, 23.73, 3.6), ("GR", "thessaloniki", 40.64, 22.94, 1.1),
    ("GR", "patras", 38.25, 21.73, 0.26), ("GR", "heraklion", 35.34, 25.13, 0.21),
    ("GR", "larissa", 39.64, 22.42, 0.16),
    ("DE_LU", "berlin", 52.52, 13.40, 3.7), ("DE_LU", "hamburg", 53.55, 10.00, 1.9),
    ("DE_LU", "munich", 48.14, 11.58, 1.5), ("DE_LU", "cologne", 50.94, 6.96, 1.1),
    ("DE_LU", "frankfurt", 50.11, 8.68, 0.77), ("DE_LU", "stuttgart", 48.78, 9.18, 0.63),
    ("DE_LU", "essen", 51.46, 7.01, 2.0), ("DE_LU", "leipzig", 51.34, 12.37, 0.6),
    ("DE_LU", "luxembourg", 49.61, 6.13, 0.66),
    ("FR", "paris", 48.86, 2.35, 11.0), ("FR", "lyon", 45.76, 4.84, 1.7),
    ("FR", "marseille", 43.30, 5.37, 1.6), ("FR", "toulouse", 43.60, 1.44, 1.0),
    ("FR", "lille", 50.63, 3.07, 1.2), ("FR", "bordeaux", 44.84, -0.58, 1.0),
    ("FR", "nantes", 47.22, -1.55, 0.7), ("FR", "strasbourg", 48.57, 7.75, 0.5),
    ("ES", "madrid", 40.42, -3.70, 6.7), ("ES", "barcelona", 41.39, 2.17, 5.6),
    ("ES", "valencia", 39.47, -0.38, 1.6), ("ES", "seville", 37.39, -5.99, 1.5),
    ("ES", "bilbao", 43.26, -2.93, 1.0), ("ES", "zaragoza", 41.65, -0.89, 0.7),
    ("ES", "malaga", 36.72, -4.42, 0.85),
    ("PL", "warsaw", 52.23, 21.01, 3.1), ("PL", "krakow", 50.06, 19.94, 1.0),
    ("PL", "lodz", 51.76, 19.46, 0.9), ("PL", "wroclaw", 51.11, 17.03, 0.8),
    ("PL", "poznan", 52.41, 16.93, 0.7), ("PL", "gdansk", 54.35, 18.65, 1.0),
    ("SE3", "stockholm", 59.33, 18.07, 2.4), ("SE3", "gothenburg", 57.71, 11.97, 1.0),
    ("SE3", "uppsala", 59.86, 17.64, 0.25), ("SE3", "orebro", 59.27, 15.21, 0.16),
    ("SE3", "linkoping", 58.41, 15.62, 0.17),
]

def get(url, params, tries=6):
    q = url + "?" + urllib.parse.urlencode(params)
    for i in range(tries):
        try:
            with urllib.request.urlopen(q, timeout=120) as r:
                return json.loads(r.read())
        except Exception as e:
            print(f"  retry {i+1}: {e}", flush=True)
            time.sleep(8 * (i + 1))
    raise RuntimeError(f"failed: {q[:140]}")

def fetch_to(outfile, rows_key, points, endpoint, hourly, start, end, extra=None):
    """points: list of (key, lat, lon). One API call per point; rows appended."""
    done = set()
    if os.path.exists(outfile):                      # resumable
        with open(outfile) as f:
            done = {r[0] for r in csv.reader(f)} - {rows_key}
    mode = "a" if done else "w"
    with open(outfile, mode, newline="") as f:
        w = csv.writer(f)
        if mode == "w":
            w.writerow([rows_key, "h"] + hourly)
        for i, (key, lat, lon) in enumerate(points):
            if str(key) in done:
                print(f"  [{i+1}/{len(points)}] {key} (cached)", flush=True)
                continue
            params = {"latitude": lat, "longitude": lon, "hourly": ",".join(hourly),
                      "start_date": start, "end_date": end, "timezone": "UTC"}
            if extra:
                params.update(extra)
            d = get(endpoint, params)
            hh = d["hourly"]
            for j, t in enumerate(hh["time"]):
                w.writerow([key, t] + [hh[v][j] for v in hourly])
            f.flush()
            print(f"  [{i+1}/{len(points)}] {key}", flush=True)
            time.sleep(1.0)

os.makedirs(OUT, exist_ok=True)
city_points = [(f"{z}:{c}", lat, lon) for (z, c, lat, lon, _w) in CITIES]

with open(os.path.join(OUT, "cities.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["zone", "city", "lat", "lon", "weight"])
    for row in CITIES:
        w.writerow(row)

stage = sys.argv[1] if len(sys.argv) > 1 else "all"

if stage in ("all", "era5"):
    print("ERA5 archive: temperature + GHI for load-model cities", flush=True)
    fetch_to(os.path.join(OUT, "era5_cities.csv"), "city_key", city_points, ARCH,
             ["temperature_2m", "shortwave_radiation"], ERA5_START, ERA5_END)

prev_vars_t = [f"temperature_2m_previous_day{n}" for n in range(1, 8)]
prev_vars_g = [f"shortwave_radiation_previous_day{n}" for n in range(1, 8)]
if stage in ("all", "prev"):
    print("Previous-runs: honest lead-1..7 temperature/GHI vintages", flush=True)
    fetch_to(os.path.join(OUT, "prev_cities.csv"), "city_key", city_points, PREV,
             prev_vars_t + prev_vars_g, PREV_START, PREV_END,
             {"models": "gfs_seamless"})

if stage in ("all", "res"):
    print("Previous-runs: GR RES-pack cells (wind 100m + GHI vintages)", flush=True)
    pack = json.load(open(os.path.join(os.path.dirname(__file__), "..", "..",
                                       "bin", "res_models_v1.json")))
    cells = pack["zones"]["GR"]["cells"]
    cell_points = [(i, c[0], c[1]) for i, c in enumerate(cells)]
    prev_vars_w = [f"wind_speed_100m_previous_day{n}" for n in range(1, 8)]
    fetch_to(os.path.join(OUT, "prev_res_cells.csv"), "cell_idx", cell_points, PREV,
             prev_vars_w + prev_vars_g, PREV_START, PREV_END,
             {"models": "gfs_seamless"})

print("DONE", flush=True)
