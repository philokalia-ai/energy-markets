# Julia lint and format CI

Tooling stays in this directory so the root Cloudflare Worker build does not gain a
Node package. Use Node **22.23.3** and the committed lockfile. The owner plugins are
pinned to `eslint-plugin-julia@0.3.1` and `prettier-plugin-julia@0.2.1`;
ESLint **10.15.0** and Prettier **3.9.10** are also exact pins.

From the repository root:

```sh
npm --prefix tools/julia-lint ci --ignore-scripts
npm --prefix tools/julia-lint test
npm --prefix tools/julia-lint run lint
npm --prefix tools/julia-lint run lint:changed -- origin/main HEAD
npm --prefix tools/julia-lint run format:check
```

`lint:changed` compares the PR head against the merge base, preserves filenames
using NUL-separated Git output, and skips deletions and an empty file list.
`lint` and `format:check` inspect tracked, existing regular `*.jl` files only.
Neither command rewrites source. No Julia runtime, package installation or database
is needed for the CI checks; the plugins use their vendored WASM parser.

## What blocks

On PRs, ESLint errors in changed Julia files block. The 12 conservative rules in
[`eslint.config.js`](eslint.config.js) had **zero diagnostics/false positives** in
the 241-file main baseline. All other rules remain warnings; warnings never fail
this check. Three positive-control cases verify that the error gate actually fires.
A full-tree ESLint report always runs as an advisory step and writes a job summary.

Prettier uses literal `--check`, also advisory. Existing code is not uniformly
formatted; making this blocking now would force unrelated file-wide reformatting.
A separate mass-format PR and an owner decision would precede any blocking change.
The workflow uses GitHub-hosted `ubuntu-latest`, a read-only token and no stored
checkout credentials, so fork PRs never execute on our self-hosted runner.

## Measured baseline and formatter safety

Main commit `d7590802d4085ef1808359dbc612a449962b0357`: **241 files**, no vendored or
generated Julia paths excluded. All 77 rules were measured via the strict preset:
**0 errors, 576 warnings**. Scope analysis accounts for 260 warnings and depends on
available package-export information; it is intentionally non-blocking.
Per-rule counts and affected filenames are in [baseline/rules.csv](baseline/rules.csv).

Prettier would change **240 files**: **21,694 lines added / 9,404 removed**.
Formatting twice was identical for all 241 files. All original/formatted files
passed Julia **1.13.4** `Meta.parseall` equivalence after removing LineNumberNodes:
**241 equal, 0 AST differences, 0 parse failures, 0 formatter crashes or warnings**.
No existing Julia file is reformatted in this PR. Counts are pinned-baseline
observations, not a guarantee for future code or package versions.

To repeat the audit, create formatted copies outside the source tree:

```sh
npm --prefix tools/julia-lint run baseline -- /tmp/julia-lint-baseline
JULIA_DEPOT_PATH=/tmp/private-julia-lint-depot /path/to/julia-1.13.4/bin/julia \
  --startup-file=no tools/julia-lint/check-ast.jl \
  /tmp/julia-lint-baseline/files.nul "$PWD" \
  /tmp/julia-lint-baseline/formatted /tmp/julia-lint-baseline/ast.toml
```

The AST helper parses only; it never includes or evaluates source. Use a private
depot, with no trailing colon; do not use the damaged shared `~/.julia` depot.
It deliberately checks structural AST identity, not just the formatter's own
verification. Line-number-sensitive macros/stack traces can still observe changed
locations, as with any formatter.

Follow-up proposal: rebase a dedicated mass-format branch on then-current main,
repeat the AST/idempotence audit, and review the estimated 240-file / 31,098-line
layout-only change separately. No mass-format PR or plugin issue is opened here.
