# CODE STYLEGUIDE — the house rules

**Code reads like the zone-strategies table.** Calibration lives in plain
structs of named parameters (`ZoneProfile`, `BoundaryBook`, `DemandProfile`)
with a `FIELD_DESCRIPTIONS` map BESIDE the struct, and the published table is
GENERATED from the running code (`bin/export_zone_strategies.jl`) — a reader
sees the struct and understands the zone's behaviour; the table can never
drift from the model. New mechanisms follow this shape: few named fields,
simple logic over them, peer-reviewable. No opaque fitted curves in code.

**Switch gating (house style)**: every behaviour change ships behind
`isempty(get(ENV, "EUPHEMIA_DISABLE_X", ""))` (on by default) or an explicit
`EUPHEMIA_ENABLE_X` opt-in when it did NOT ship. Per-treatment sub-switches
(`_T1..`) so leave-one-out arms exist. Switches are read at call time; caches
must never memoize across a switch flip (fresh process per arm is the rule).

**Identity guards**: refactors and default-off changes prove bit-identity
(the GR single-zone + 39-zone EU 1032-row harness) BEFORE merging; shipped
defaults prove identity to the measured winning arm. Ledger every
price-affecting change in CLAUDE.md's code_version entry and bump the cv on
the activating branch only.

**File layout**: large concerns split into per-topic files `include`d by a
thin parent in definition order (see docs/code-map.md). Comments state
constraints the code can't show — never narrate the diff.

**Assertions everywhere**: harnesses assert their own preconditions (row
counts, file existence, env absence); silent fallbacks and `2>/dev/null` on
verification paths are how measurements get faked by accident. A watcher that
can miss a failure mode is a watcher that lies.

**Ex-ante SQL discipline**: trailing windows end strictly before the delivery
day; vintages via previous-runs (per-timestamp semantics, constant lag 1 for
past days); lagged public data is fine, same-day observed data is lookahead.
