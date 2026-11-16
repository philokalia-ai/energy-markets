#!/usr/bin/env python3
"""Evaluate the six explicit saved-data contracts, without training a model."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import json
from pathlib import Path

import pandas as pd

from evaluate import evaluate, read_frame, sha256_file, validate_manifest, write_outputs


def run_one(arguments):
    path, output = map(Path, arguments)
    contract = validate_manifest(json.loads(path.read_text()))
    for key in ["actuals", "forecasts"]:
        item = contract["source"][key]
        if sha256_file(item["path"]) != item["sha256"]:
            raise ValueError("Prepared source changed: " + item["path"])
    forecasts = read_frame(contract["source"]["forecasts"]["path"])
    if set(forecasts.model) != {m["id"] for m in contract["models"]}:
        raise ValueError("Observed models differ from declared model IDs")
    tables = evaluate(read_frame(contract["source"]["actuals"]["path"]), forecasts,
                      **contract["window"], zones=contract["zones"],
                      timezone=contract["market_day_timezone"],
                      intersection=contract["all_model_intersection"])
    destination = output / (contract["name"] + "-" + contract["target_policy"])
    write_outputs(tables, contract, destination)
    return str(destination)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--pack", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--workers", type=int, choices=[1, 2, 3], default=1)
    args = p.parse_args()
    paths = json.loads(args.pack.read_text())
    jobs = [(path, str(args.output)) for path in paths]
    if args.workers == 1:
        destinations = [run_one(job) for job in jobs]
    else:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            destinations = list(pool.map(run_one, jobs))
    headlines, dm, masks = [], [], []
    for folder in map(Path, destinations):
        contract = json.loads((folder / "manifest.json").read_text())
        for file, target in [("metrics", headlines), ("dm", dm), ("masks", masks)]:
            table = pd.read_csv(folder / (file + ".csv"))
            if file != "masks":
                table = table[table.group.isin(["all", "excluding_italy"])]
            target.append(table.assign(window=contract["name"], target_policy=contract["target_policy"]))
    pd.concat(headlines, ignore_index=True).to_csv(args.output / "headlines.csv", index=False)
    pd.concat(dm, ignore_index=True).to_csv(args.output / "footprint-dm.csv", index=False)
    pd.concat(masks, ignore_index=True).to_csv(args.output / "mask-index.csv", index=False)
    (args.output / "pack-manifest.json").write_text(json.dumps({
        "contracts": [{"path": Path(d).name + "/manifest.json",
                       "sha256": sha256_file(Path(d) / "manifest.json")} for d in destinations],
        "headlines_sha256": sha256_file(args.output / "headlines.csv"),
        "dm_sha256": sha256_file(args.output / "footprint-dm.csv"),
        "mask_index_sha256": sha256_file(args.output / "mask-index.csv")}, indent=2) + "\n")
    print("Evaluated contracts:", *destinations, sep="\n", flush=True)


if __name__ == "__main__":
    main()
