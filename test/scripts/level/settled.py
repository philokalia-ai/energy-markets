# Settled DA prices per (zone, UTC hour) from the live API JSONs (same source
# the analyst/leader use), written once to a CSV for the attribution scripts.
import json, glob, os, csv
out = "/home/pgeorgakopoulos/armada/em-team/results/level/settled.csv"
rows = {}
for f in glob.glob("/home/pgeorgakopoulos/armada/em-team/live/*.json"):
    z = os.path.basename(f)[:-5]
    d = json.load(open(f))
    for day in d["days"]:
        hrs, act = day.get("hours") or [], day.get("actual") or []
        for h, a in zip(hrs, act):
            if a is None: continue
            rows[(z, h[:13].replace("T", " ") + ":00")] = round(a, 8)
with open(out, "w") as io:
    w = csv.writer(io); w.writerow(["zone", "t", "act"])
    for (z, t), a in sorted(rows.items()): w.writerow([z, t, a])
print(len(rows))
