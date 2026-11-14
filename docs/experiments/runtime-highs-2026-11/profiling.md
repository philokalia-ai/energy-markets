# Residual wall-time profile — 2026-11-14

Profiling began after the 22:42 acceptance report, within a separate 45-minute
budget. The completed replay used fixed source, Julia 1.12.7/new HiGHS, November
13, four Julia/four DuckDB threads on cores 0–7, and unchanged production solver
settings. All **48 native solves were optimal** and all **936 returned prices
were bit-identical** to the acceptance run (maximum difference zero).

The apparent overhead is principally **benchmark audit work**. In this replay,
wall was **698.36 s**, both books **37.49 s**, native optimization **232.12 s**,
and library timed scopes **244.37 s**. Residual outside books/library was
**416.50 s**; fingerprint auditing took **369.78 s**, or **88.8%** of that
residual. The remaining **46.73 s** is not assigned a precise wall-time cause.
Profiler/fresh-call overhead means these values are not a direct subtraction
from the earlier warm-day 316–330 s residual or a production speed ratio.

| Largest identified, non-overlapping sink | Measured wall | Fix idea / action |
|---|---:|---|
| Benchmark book fingerprints | 369.78 s (174.92 + 194.85) | Materialize SHA input as a UInt8 vector once; implemented and all 18 recorded hashes match. |
| Native HiGHS optimization | 232.12 s | Retain canonical decomposition; benchmark licensed Gurobi on identical books for prospective inter-temporal blocks. No solver tuning applied. |
| Book construction | 37.49 s (34.77 + 2.71) | Batch/cache repeated read-only lookbacks by backend, issuance and delivery day; requires separate vintage-correctness validation. Not implemented. |

These are the largest **identified scopes**, not three invented residual
components. Native optimization and book building were already attributed by
the benchmark. Model build took **6.42 s** inside the library scope; anchor
extraction **0.437 s**, price reconstruction **0.045 s**, and sampler join
**0.00043 s**. None of those small measured phases explains a 320 s residual.

CPU samples locate the audit path at
`fingerprint_book → SHA.update! → copyto! → unalias/mightalias → dataids →
objectid/MurmurHash3`. Julia 1.12's generic alias checks repeatedly identify the
immutable CodeUnits input during each SHA block copy. A mutable byte vector
uses constant-time buffer identity. The helper now uses:

```julia
sha256(Vector{UInt8}(codeunits(serialized_rows)))
```

The bytes and SHA-256 algorithm are unchanged. All **18** saved sequence,
multiset and capacity digests from **six** accepted books match exactly;
those byte-buffer hash evaluations took **0.376 s** total (not a full clearing
replay). The helper only observes books, so model inputs are unchanged. No
production clearing code or parameters were modified by this optimization,
and no post-fix full-clear speedup is claimed.

An initial hook parse error and a diagnostic post-timer initialization error
were corrected. The invalid replay was stopped and excluded; a one-zone smoke
returned the expected €100/MWh before the completed replay above. The accepted
benchmark matrix was unaffected. Failed diagnostic logs remain in the private
sprint results for audit.

Artifacts: [section counters](profile-sections.json), [CPU tree](profile-tree.txt),
[replay/parity summary](profile-summary.json),
[18-hash verification](hash-buffer-verification.json). Full flat samples and raw
JSON/logs remain in `em-team/results/ops/fixed/`.

Reproduce the measured pre-fix audit path with the optional reference flag;
omitting it uses the corrected buffer path:

```bash
OPS_PROFILE_REFERENCE_HASH=1 taskset -c 0-7 julia +1.12 --project=. \
  test/scripts/profile_runtime_residual.jl results/profile.json decomposed 2026-11-13
```

Use the same isolated-depot/read-only-source environment documented in the
[parent experiment note](README.md). No additional benchmark date was profiled.

Phase completed 2026-11-14 23:26:20 UTC, 43.83 minutes after the acceptance report, within the 45-minute ceiling.
