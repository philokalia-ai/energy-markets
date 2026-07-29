# cv25 — plan

## Invariants

Five things do not change. Everything else is negotiable, and most of it should go.

1. **Ex-ante.** Only information available before the auction gate enters a price.
2. **No forward-looking bias.** Any query window that touches the delivery day is a
   defect, not a trade-off.
3. **Open data.** The published extract reproduces the published record.
4. **Open source.** The tool is meant to be read and run by other people.
5. **HiGHS.** The canonical solver is open-source. Gurobi stays a development option.

Everything below serves those five. Byte-identity with older records, historical
kill-switches, parked levers, and unused subsystems do not — git holds the history.

## What cv25 delivers

A corrected, genuinely ex-ante record on a smaller codebase.

- Four structural defects fixed (they change prices; that is the point).
- The calibration re-derived — not re-tuned — against the corrected physics.
- A materially smaller model: fewer modes, fewer knobs, fewer subsystems.
- A record whose headline number means what it says.

## Phase 0 — Free audits, no code change

**0.1 Which flow mode measured which calibration decision.** The scoped `:v3`
resolution lives only in `run_multi_zone_market_clearing`; `mz_build_books` (the
pipeline's entry) has none, so pipelined runs used `:d0`. Sequential A/B harnesses
resolved `:v3`. For every shipped treatment (cv17 backstops, cv21/22 boundary books,
cv23 FR/Norway), read its experiment doc and record which harness — therefore which
mode — measured it. **This sizes the real re-calibration surface.** Decisions
validated under `:v3` need no revisit on account of the flow defect.

**0.2 Restate cv24 honestly.** The published figures are not ex-ante figures. Say so
in the README and the ledger now, independently of cv25. This is invariant 1, not a
cv25 deliverable.

**0.3 Truncated-day policy.** 65 of 1,304 days carry fewer than 24 UTC hours. Decide
before the backfill whether the source data is genuinely missing (record explicit
holes) or recoverable (repair the extract). The headline denominator depends on it.

**0.4 Lookahead sweep.** Grep every date-bounded query in `src/` for day-inclusive
upper bounds. Two are known (`registry.jl:182,266`). Invariant 2 deserves a
systematic pass, not two point fixes.

## Phase 1 — Subtraction (price-inert, guarded bit-identical)

Ships before any physics change, so the fixes land on a small codebase.

| remove | evidence |
|---|---|
| **`:uc_based` + `:alternative` order methods** and the UC subsystem behind them — `src/uc/`, `UnitCommitment.jl`, `BiddingStrategy.jl`, `AlternativeOrderBook.jl`, `clearing/iterative.jl`, the `simulations.uc_*` tables, the two nightly workflows | **2,387 lines, 13% of `src/`**. Not reachable from the product: the EU footprint, the daily forecast and every backfill are `:merit_order`. Only the two legacy nightly workflows still name them. **Decision needed: does anything consume those two products?** If yes, keep the workflows and drop the rest; if no, all of it goes. |
| **Flow modes `:clim`, `:v2`, `:dlag`** | Experiment leftovers. Only `:v3` survives cv25. |
| **`:d0`** | Same-day *observed* flows are forward-looking. Under invariant 2 it cannot remain a default anywhere. Its removal ends SEE byte-identity — acceptable; byte-identity is not an invariant. |
| **cv18 parked levers** `unit_srmc_spread`, `export_absorption_steps` + their two `book_build.jl` sites + `EUPHEMIA_DISABLE_CV18` | Measured, documented, never activated. |
| **19 `ZoneProfile` fields that never vary** across 39 zones | They are constants wearing a parameter's clothes. Move to module constants; the struct keeps only what differs. |
| **22 of `create_merit_order_book`'s 39 kwargs** | Each shadows a profile field with a `x === nothing ? profile.x : x` line. `with_profile` already exists; one `overrides` argument replaces the lot. |
| **Duplicate profiles** | `ROMANIA_PROFILE`, `SERBIA_PROFILE`, `HUNGARY_PROFILE` are identical definitions; `IBERIA_PROFILE` equals `SEE_PROFILE`. 22 names describe 17 distinct vectors — name the 17. |
| **Kill-switches, at ship time** | Keep them through cv25 validation as ablation arms, then delete. cv24 reproduction is `git checkout` a tag, not a permanent runtime branch. |
| **`test/archive/`, stale `test/scripts/`** | 3 + 42 files; keep what a third party would run. |

Gate: the 39-zone EU + GR single-zone bit-identity guard, at every step. Prices do
not move in Phase 1.

## Phase 2 — The four fixes, with ablation

Each behind a switch so arms come from one binary.

1. **ATC canonicalisation** — one flow variable per unordered border
   (`exp/atc-canonicalisation`, measured).
2. **Flow-mode resolution** — `mz_build_books` takes the policy; better, both callers
   go through one `mz_resolve_policy` that owns flow mode, decomposition and the
   `:p95` fallback. After Phase 1 there is only `:v3` to resolve.
3. **ISO-year in the reservoir queries** — `year(day - Day(dayofweek(day) - 4))`.
4. **Delivery-day exclusion in the fleet probe** — both sites.

Plus the same-class stragglers, which are not optional here:

- `MAX_PLAUSIBLE_UNIT_MW` in `fleet_data.jl`'s `get_installed_capacity_by_type`
  (verified missing). It feeds the `:installed` fleet-truth denominators and FR's
  nuclear availability share — the flagship cv23 mechanism. Re-calibrating FR around
  a corrupt denominator would bake in a new absorbed defect.
- Price-provenance observability: the rent-sign check abandons the competitive
  reconstruction for a whole period with no warning and no field on the result.
  Make it countable before calibrating against those prices.
- `test/scripts/pipeline_identity.jl` compares a `:v3` arm against a `:d0` arm and
  calls the result identity. Fix it, or it certifies nothing.

**Measurement:** leave-one-out ablation on the seasonal windows. Fixes 3 and 4 fire on
few days and their arms are nearly free. The one interaction that needs a combined arm
is 1 × 2 — capacity halves while flow *information* changes.

## Phase 3 — The honest baseline

All fixes ON, **calibration untouched**. Score it on the full standing methodology.
Pre-register that number as what re-calibration must beat.

cv24's headline is not the target. Asking a re-calibration to recover a lost
information advantage and phantom transmission capacity through parameter choices is
the definition of fitting. Publish the decomposition — Δ from ex-ante honesty, Δ from
ATC physics, Δ from re-calibration — not a single cv24→cv25 delta.

## Phase 4 — Re-calibration, constrained

Scope: only zones on a pre-registered affected-border list, derived mechanically from
per-border Δcapacity and Δnet-transfer. The measured damage localizes to IT-*, SI, HU,
AT, CH.

Rules, in order:

1. **Recompute before retune.** Several mechanisms are formulas over quantities the
   ATC fix changes — the backstop quantity is demonstrated headroom *minus offered
   endogenous ATC*; boundary-book capability is ATC-capped. Rerun the derivations,
   touch no knob, measure. Only what fails after that earns a change.
2. **Deletion before addition.** `import_backstop` and `scarcity_import_credit` were
   introduced to fix phantom-scarcity caps diagnosed under the doubled-ATC solver. The
   first question per mechanism is whether it is still needed at all — answered by a
   switch-off arm.
3. **Pre-registration without the residual.** State the zone, the lever, the physical
   or institutional hypothesis, the expected direction and the falsifier — before the
   run, and without reference to the residual's sign. A treatment whose only
   justification is the residual it removes is rejected by rule.
4. **Held-out windows.** Calibrate on set A, accept only what holds on disjoint blind
   set B.
5. **Publish two audit numbers.** The distinct-parameter-vector count (17 today) and
   the number of zones whose treatment changed, each with its one-line justification.
   A calibration that shrinks is evidence of physics; one that grows is evidence of
   fitting, and the writeup says so.

## Phase 5 — Ship

1. **Full-record offline screening backfill** (~1,300 days, DuckDB extract, HiGHS).
   The canonicalisation makes the clear ~4× faster, so this is an overnight run — the
   thorough option is now the cheap one. Score with the regime table, per-year
   energy-weighted correlation shares, Nordic cap-hour counts, coverage checks, and
   the truncated-day denominator handled identically in both arms.
2. Only then the Postgres backfill, extract rebuild, book capture, record refresh.
3. **Ship gate:** cv25 beats the Phase-3 honest baseline, no pre-registered neighbour
   breach, no new cap hours, calibration no larger than it was.

**Rollback** is cheap and should be stated plainly: `code_version` is row provenance,
cv24 rows are never rewritten, the dashboard selects by cv, the product pins a
constant. Rollback = do not flip the default. One prerequisite to verify first: the
flow transfer's delete is not clearing-mode scoped, so confirm a cv25 transfer cannot
clobber the cv24 flow slice.

## Consequences to handle, not discover

- **Standing conduct hypotheses** in the affected zones (Italian evening tail,
  Alpine/Balkan import premium) were derived on a footprint that was more
  interconnected than the real grid. Each needs a re-derivation-or-withdrawal verdict.
- **The live product** stamps the library's `code_version`. Merging cv25 code starts
  emitting cv25 rows from a not-yet-validated model. Settle merge-vs-activate ordering
  before the merge.
- **The reproducibility recipe** is versioned: the published artifact reproduces cv24;
  after cv25 the docs must say which tag reproduces which record.
