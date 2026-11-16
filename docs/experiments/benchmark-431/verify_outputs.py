#!/usr/bin/env python3
"""Check saved output identities and hashes, without re-scoring or source access."""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from evaluate import sha256_file


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--outputs", type=Path, required=True)
    args = p.parse_args()
    root = args.outputs
    pack = json.loads((root / "pack-manifest.json").read_text())
    for source in pack["contracts"]:
        path = root / source["path"]
        assert sha256_file(path) == source["sha256"], path
        manifest = json.loads(path.read_text())
        for key, digest in manifest["output_sha256"].items():
            assert sha256_file(path.parent / (key + ".csv")) == digest
        assert sha256_file(path.parent / "masks.csv") == manifest["mask_sha256"]
        metrics = pd.read_csv(path.parent / "metrics.csv")
        masks = pd.read_csv(path.parent / "masks.csv")
        dm = pd.read_csv(path.parent / "dm.csv")
        assert metrics.loc[metrics.lead > 1, "naive"].eq("d7").all()
        assert (masks.complete_day_n + masks.partial_day_n).eq(masks.n).all()
        assert masks.excluded_union.eq(masks.expected - masks.n).all()
        assert metrics.n.ge(0).all() and metrics.share_le_zero.dropna().between(0, 1).all()
        available = metrics.naive_mae.gt(0) & metrics.n.gt(0)
        np.testing.assert_allclose(metrics.loc[available, "rmae"],
                                   metrics.loc[available, "mae"] / metrics.loc[available, "naive_mae"],
                                   rtol=1e-12, atol=1e-12)
        assert metrics.loc[metrics.naive_mae.eq(0), "rmae"].isna().all()
        assert dm.loc[dm.n_days < 30, "status"].eq("insufficient data").all()
        assert dm.loc[dm.n_days < 30, "p_model_better"].isna().all()
        identity = ["model", "lead", "naive", "mask_family", "coverage", "aggregation"]
        for _, group in metrics.groupby(identity):
            footprint = group[group.group == "all"].iloc[0]
            zones = group[~group.group.isin(["all", "excluding_italy"])]
            assert zones.n.sum() == footprint.n
            if footprint.n == 0:
                continue
            weight = zones.n if footprint.aggregation == "pooled_cell" else zones.n_zone_days
            valid = weight.gt(0)
            for col in ["mae", "bias", "naive_mae", "mean_price", "share_le_zero"]:
                expected = np.average(zones.loc[valid, col], weights=weight[valid])
                np.testing.assert_allclose(expected, footprint[col], rtol=1e-11, atol=1e-10)
        print(path.parent.name, "OK", len(metrics), "metric rows", len(masks), "comparison masks", flush=True)
    for name, key in [("headlines.csv", "headlines_sha256"), ("footprint-dm.csv", "dm_sha256"),
                      ("mask-index.csv", "mask_index_sha256")]:
        assert sha256_file(root / name) == pack[key]
    print("All source-independent output checks passed.")


if __name__ == "__main__":
    main()
