# Local files for offline experiments

Experiment scripts find checked-in code and model packs relative to their own
location. Run them from any checkout; no personal checkout path is assumed.
External inputs and results are not distributed with the scripts. Set the
variables used by the script before running it. An unset or empty required
Python/shell variable stops with a message naming it; Julia scripts report a
missing required variable before using that path.

| Variable | Local resource |
| --- | --- |
| `EUPHEMIA_DUCKDB_PATH` | Read-only input DuckDB extract |
| `EUPHEMIA_RESULTS_DB` | Results DuckDB file; read-only for scoring, a separate writable scratch store for experiment runners |
| `EM_LIVE_DIR` | Saved per-zone public JSON snapshot directory |
| `EM_RESULTS_DIR` | Experiment results root, including scenario stores |
| `BLOCKS_RESULTS_DIR` | Blocks experiment results directory, including its existing `env.sh`/`retry.sh` launch helpers |
| `INPUT_UPGRADE_DIR` | Input-upgrade intermediate data, weather files and fitted artifacts |
| `EM_SCRATCH_DIR` | Older diagnosis scratch root, including saved model CSV files |
| `TSFM_OUT` | Saved TSFM forecast/panel directory (existing override retained) |
| `TSFM_LIVE` | TSFM input public JSON snapshot directory (existing override retained) |
| `TEAM_RESULTS` | Saved collapse probability/diagnostic results for the probabilistic scorer |
| `DN_OUT` | DN experiment intermediate/output directory (existing override retained) |
| `RESULTS` | Iteration-six harness output directory (existing override retained) |

Existing positional arguments and other explicit path overrides are retained.
`REPO`, where supported by shell launchers, still selects another checkout;
otherwise they locate the repository from their script location. Block launchers
quote results, log and executable paths (including spaces), and return nonzero
for setup failures. Their existing `env.sh` supplies `J`, a Julia executable
path or command name. Pure scoring
functions remain importable without external data; their readers require the
variables when called.

Saved public manifests/logs use symbolic provenance: `$REPO_ROOT` for the
checkout, `$EM_DATA_DIR` for external extracts, `$EM_RESULTS_DIR` for saved
results, `$EM_SCRATCH_DIR` for session scratch roots and `$PYTHON_ENV` for the
Python environment. `em-team/live*/` identifies the saved public snapshots.
These record locations, not new scientific inputs. Content hashes retain the
identity of the original external files. Manifest-container hashes and the
hash of the path-sanitized historical text source are updated consistently;
scientific tables are not regenerated.

The repository hygiene workflow rejects any nonempty slash-bounded home
component, including Unicode, spaces and dollar signs, and
session scratch paths that encode usernames. Bare roots have no user component;
a component without its terminating slash is outside the bounded pattern. No
username, including `runner`, is allowlisted. The workflow also runs retained
offline detector/launcher fixtures (`test/test_repo_hygiene.py`). This
cleanup changes the current tree only: old commits retain their original paths.
