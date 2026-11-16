# Model-lines issuance audit (#431D)

Default changes fix the emitter's lag inputs: settlement eligibility is per zone,
never later than the UTC issue day, and one canonical auction supplies each
settled interval via PR C's `bin/da_target.py`. Until that module lands, an explicit
`highest_seq` fallback implements its pure function; requesting SDAC without it is
an error. `EUPHEMIA_DA_TARGET` still defaults to `highest_seq`. The helper's hourly
aggregation also replaces the former use of a single native quarter at each UTC
hour: input changes can therefore extend beyond AT/DE_LU. Hybrid predictions do
not use settled prices and remain numerically unchanged with strict mode off.

Every emitted row gains nullable additive `issue_utc` and JSONB `source_manifest`
metadata (physics `prediction_made_utc`, base cv, book cv, feature back-days,
target policy, strict-mode flag). Old rows are not relabelled. Migration checks
the catalog first, uses a five-second local lock timeout only when columns are
missing, and rolls back/fails emission if it cannot add them. It never executes
an unconditional ALTER on routine runs. Exact reruns with the same issue/source
are no-op upserts, including `generated_at`.

`MODEL_LINES_STRICT_ASOF=1` is **opt-in**, default off. It skips UTC target dates
whose previous-day noon Europe/Brussels gate has passed, checks that again before
writing (including an atomic wall-clock gate in each upsert statement), limits physics vintages before choosing the winning base, and selects
settled revisions only when their non-null `update_time_utc` is <= issue. Missing
publication evidence fails closed for the affected zone; it is not guessed from delivery timestamps.
Per-cell lag24/48/168/roll7 checks still apply. `MODEL_LINES_REWRITE_PAST=1` permits
past-gate backfills but retains the strict input cutoffs. Fuel closes in strict
mode cannot come from a date after issue. The default -2..+7 refresh window stays
unchanged; strict mode filters it. No code-version bump or schedule change.

Dates and lag offsets remain the emitter's existing UTC convention (24/48/168
elapsed hours). This does not migrate the trained artifact to market-local/DST
lag semantics. Book snapshots, trained artifact and fuel revision histories are
not retrospectively authenticated by this flag. Issue/source columns describe
this run; the mutable table is not an append-only archive of historical issues.

Run tests without DB access:

```sh
python test/test_emit_model_lines_pin.py
```

The offline audit needs duckdb, pandas, numpy, pytz, scikit-learn, joblib and
psycopg2-binary (emitter imports). It opens the extract with `read_only=True`, reads
saved live JSONs for physics vintages, and writes only its own output/private
in-memory tables. No database credentials or model downloads are needed:

```sh
python docs/experiments/model-lines-asof-431/audit.py \
  --extract /path/to/euphemia-live-20261115.duckdb \
  --live /path/to/em-team/live --output /tmp/model-lines-asof.json
# Optional unmerged PR C API, without copying its source into this branch:
# --target-helper /path/to/blocks/bin/da_target.py
```

Three fixed issue instants: 2026-09-19, 10-24, 11-13 at 10:40 UTC. Output has counts
by zone/model/lead, dropped coverage, next-day lag24 deltas, source hashes, and
assertions for no strict past rows/no AT-DE D+2 stats/issue metadata/idempotent
upserts. `--base-cv` defaults to the emitter's production pin (37); another pin is
an explicitly labelled diagnostic. Strict mode is not enabled in production by
this change. In summer 10:40 UTC is past the SDAC gate: tomorrow is excluded.

**Limits:** the extract has no forecast/model-lines tables. Saved JSON vintages
fill the physics table in memory. Frozen production GBM artifacts and book
features are unavailable locally: coverage assumes a book/model for every
forecast cell, using synthetic fundamentals, a zero residual and lag24 probe.
Probe values measure changed inputs, not the trained GBM price response or
forecast accuracy. The source-coverage loss is an upper-bound panel, not a claim
that all cells were/would be published. Actual model price deltas require the
owner's saved artifact and features; no retrospective training substitutes for
that validation. See the ops report for measured results and the enablement
recommendation.

Measured on the saved panel, production pin37 / highest_seq:

| Issue (10:40 UTC) | Default cells | Strict cells | Future lead1 retained |
|---|---:|---:|---:|
| 2026-09-19 | 3,744 | 0 | 0/936 |
| 2026-10-24 | 3,744 | 0 | 0/936 |
| 2026-11-13 | 3,744 | 898 | 898/936 |

All default cells here are stats; the saved window has no cv37 physics base.
Default includes four UTC days (-2,-1,0,+1); strict excludes the first three.
The two summer issues also exclude lead1 because the gate passed at10:00 UTC.
The winter issue drops one lead1 cell in38 zones and retains all24 in RS.
These are input-coverage counts under the stated probe assumptions.
[measured-summary.json](measured-summary.json) records the losses and lag deltas.

Fallback and unmerged PR C highest_seq audit outputs agree across all three
panels; a separate real-data SDAC integration check agrees on1,872 hourly cells
across39 zones. Keep strict off pending owner review of coverage and the missing
trained-artifact price replay. The emitter defect fix remains default-on.
