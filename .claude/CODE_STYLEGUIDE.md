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

## Product-surface rules (owner-ratified 2026-08)

- **No synthetic data at runtime, anywhere.** Views load live only; on
  failure an honest "Live data unavailable — retry" state. Fixture/sample
  data exists ONLY under workers/api/test/ and never ships in web/.
- **Never hand-author a number the site could compute** — decompositions
  render from the same constants the engine uses and SELF-CHECK that the
  parts reconcile (show ⚠, never silently disagree). Vocabularies (strategy
  labels, glossaries) have one generated source of truth — no hand-mirrored
  maps.
- Measured scores on pages are QUOTED from ledger/docs artifacts, never
  recomputed ad hoc; every number traces to a committed artifact.
- PR references to the owner always carry the full clickable URL.

## Long-running pipeline operations

- A multi-hour pipeline is ONE detached `setsid` script (survives harness
  task sweeps) with a status.log, per-stage pidfile, per-cell .err files and
  internal retries/resume-skip — never a chain of agent re-invocations
  (three silent multi-hour stalls taught this).
- Supervision is belt-and-braces: an external Monitor on a LINE-ANCHORED
  completion marker (^RETRO_DONE — substring markers false-fire on plan
  text) PLUS a ScheduleWakeup heartbeat that eyeballs progress; every
  watchdog gets a simulated-failure test before it is trusted, and no
  monitor may process-name-match a pattern it contains itself.
- Scheduled GitHub workflows fire late or skip; every cron carries a
  manual-dispatch recovery input replicating the scheduled profile.
