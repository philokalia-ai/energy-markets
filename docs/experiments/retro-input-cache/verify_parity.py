#!/usr/bin/env python3
"""Verify the complete, separately saved forecast outputs of both replay arms."""
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path

root = Path(__file__).resolve().parent
manifest = json.loads((root / "results.json").read_text())
for day, proof in manifest["parity"].items():
    outputs = []
    utc_outputs = []
    for arm in ("main", "cached"):
        data = gzip.decompress((root / f"{arm}-{day}.csv.gz").read_bytes())
        assert hashlib.sha256(data).hexdigest() == proof[f"{arm}_sha256"]
        rows = list(csv.DictReader(io.StringIO(data.decode())))
        assert len(rows) == proof["rows"] == 936
        assert len({r["zone"] for r in rows}) == 39
        assert len({(r["zone"], r["time"]) for r in rows}) == 936
        outputs.append(data)
        utc = gzip.decompress((root / f"{arm}-{day}-utc.csv.gz").read_bytes())
        assert hashlib.sha256(utc).hexdigest() == proof[f"{arm}_full_utc_sha256"]
        assert len(list(csv.DictReader(io.StringIO(utc.decode())))) == proof["full_utc_rows"] == 1872
        utc_outputs.append(utc)
    assert outputs[0] == outputs[1], day
    assert utc_outputs[0] == utc_outputs[1], day
    print(f"{day}: 936/936 rows byte-identical; SHA256 {proof['main_sha256']}")
print("PASS: both complete 39-zone market days match unmodified main")
