"""Offline fixtures for the actual hygiene workflow and block launchers.

    python3 -m unittest discover -s test -p test_repo_hygiene.py

Only temporary Git repositories and stub executables are used. No model,
extract, network or external launch environment is needed.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/repo-hygiene.yml"
PAIRS = [("2026-09-20", "2026-10-19"), ("2026-11-04", "2026-11-13"),
         ("2026-11-02", "2026-10-06"), ("2026-09-27", "2026-09-16")]


def workflow_script():
    # The detector is the final multiline run block; exercise that exact body.
    return textwrap.dedent(WORKFLOW.read_text().split("        run: |\n", 1)[1])


class HomePathDetectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def detect(self, text):
        (self.root / "fixture.txt").write_text(text + "\n")
        subprocess.run(["git", "add", "fixture.txt"], cwd=self.root, check=True)
        return subprocess.run(["bash", "-eu", "-c", workflow_script()],
                              cwd=self.root, capture_output=True, text=True)

    def test_any_nonempty_home_component(self):
        for root, user in [("home", "alice"), ("Users", "Alice"),
                           ("home", "δοκιμή"), ("home", "alice$"),
                           ("Users", "Alice Smith"), ("home", " "),
                           ("home", "dot.name-under_score")]:
            for suffix in ["", "project/x"]:
                with self.subTest(root=root, user=user, suffix=suffix):
                    path = "/" + "/".join([root, user, suffix])
                    result = self.detect('saved path: "' + path + '"')
                    self.assertEqual(result.returncode, 1, result.stderr)

    def test_bounding_slashes_are_required_without_a_runner_allowlist(self):
        # No special username exemption. A name without its closing slash is
        # outside the specified slash-bounded pattern, as is an empty root.
        for parts in [("home", ""), ("Users", ""), ("home", "", ""),
                      ("home", "runner")]:
            with self.subTest(parts=parts):
                result = self.detect("/" + "/".join(parts))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.detect("/" + "/".join(["home", "runner", "work/file"]))
        self.assertEqual(result.returncode, 1)  # runner receives no exception

    def test_symbolic_paths_are_clean(self):
        self.assertEqual(self.detect("$EM_DATA_DIR/input.duckdb").returncode, 0)

    def test_encoded_session_paths_are_rejected(self):
        path = "/" + "/".join(["tmp", "claude-1000", "-home-example-project", "session/file"])
        self.assertEqual(self.detect(path).returncode, 1)

    def test_git_errors_are_not_reported_as_clean(self):
        folder = self.root / "not-a-repository"
        folder.mkdir()
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(self.root))
        result = subprocess.run(["bash", "-eu", "-c", workflow_script()],
                                cwd=folder, env=env, capture_output=True, text=True)
        self.assertGreater(result.returncode, 1)


class BlockLauncherPathsTest(unittest.TestCase):
    def executable(self, path, source):
        path.write_text(source)
        path.chmod(0o755)

    def fixture(self, folder, spaces):
        results = folder / ("results with spaces" if spaces else "results")
        results.mkdir()
        repo = folder / "repo with spaces"
        repo.mkdir()
        tools = folder / "tools"
        tools.mkdir()
        capture = folder / "capture"
        capture.mkdir()
        julia = tools / "julia executable"
        record = (f"#!{sys.executable}\n"
                  "import json, os, pathlib, sys\n"
                  "if sys.argv[1:] == ['--version']:\n"
                  "    print('julia stub')\n"
                  "    sys.exit(int(os.environ.get('FAIL_JULIA_VERSION', '0')))\n"
                  "core = os.environ.get('TEST_CORE', sys.argv[1])\n"
                  "p = pathlib.Path(os.environ['CAPTURE_DIR']) / ('job-' + core + '.json')\n"
                  "tmp = p.with_suffix('.part')\n"
                  "tmp.write_text(json.dumps(sys.argv[1:]))\n"
                  "tmp.replace(p)\n")
        self.executable(julia, record)
        self.executable(results / "retry.sh", record)
        self.executable(tools / "git", "#!/bin/bash\nexit_code=${FAIL_GIT:-0}\necho stub-revision\nexit \"$exit_code\"\n")
        self.executable(tools / "nohup", '#!/bin/bash\nexec "$@"\n')
        self.executable(tools / "taskset", '#!/bin/bash\nexport TEST_CORE="$2"\nshift 2\nexec "$@"\n')
        (results / "env.sh").write_text("J=" + shlex.quote(str(julia)) + "\n")
        env = dict(os.environ, BLOCKS_RESULTS_DIR=str(results), REPO=str(repo),
                   CAPTURE_DIR=str(capture), PATH=str(tools) + os.pathsep + os.defpath)
        for key in ["EXTRA_ENV", "FAIL_GIT", "FAIL_JULIA_VERSION"]:
            env.pop(key, None)
        return results, capture, env

    def run_launcher(self, script, env, label="arm with spaces"):
        args = [label, "blocks", "36"] if script == "launch.sh" else [label, "36", "EUPHEMIA_COMPLEX_ORDERS=blocks"]
        return subprocess.run(["bash", str(ROOT / "test/scripts/blocks" / script), *args],
                              env=env, capture_output=True, text=True, timeout=10)

    def test_paths_with_spaces_and_no_space_control_preserve_all_date_pairs(self):
        for script in ["launch.sh", "launch_final.sh"]:
            for spaces in [False, True]:
                with self.subTest(script=script, spaces=spaces), tempfile.TemporaryDirectory() as temp:
                    results, capture, env = self.fixture(Path(temp), spaces)
                    result = self.run_launcher(script, env)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    deadline = time.monotonic() + 5
                    while len(list(capture.glob("job-*.json"))) < 4 and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertEqual(len(list(capture.glob("job-*.json"))), 4, result.stderr)
                    provenance = results / "arm with spaces/PROVENANCE"
                    self.assertIn("stub-revision", provenance.read_text())
                    for i, pair in enumerate(PAIRS):
                        core = str(36 + i)
                        args = json.loads((capture / ("job-" + core + ".json")).read_text())
                        log = results / f"arm with spaces.{i}.log"
                        self.assertTrue(log.is_file())
                        expected = (["--project=.", "test/scripts/blocks/clear_days.jl", "arm with spaces", *pair]
                                    if script == "launch.sh" else [core, str(log), "arm with spaces", *pair])
                        self.assertEqual(args, expected)

    def test_setup_failures_propagate_before_jobs_start(self):
        for script in ["launch.sh", "launch_final.sh"]:
            for failure in ["source", "cd", "mkdir", "provenance", "git", "julia", "log"]:
                with self.subTest(script=script, failure=failure), tempfile.TemporaryDirectory() as temp:
                    results, capture, env = self.fixture(Path(temp), True)
                    if failure == "source":
                        (results / "env.sh").write_text("return 21\n")
                    elif failure == "cd":
                        env["REPO"] = str(Path(temp) / "missing checkout")
                    elif failure == "mkdir":
                        (results / "arm with spaces").write_text("blocked")
                    elif failure == "provenance":
                        (results / "arm with spaces/PROVENANCE").mkdir(parents=True)
                    elif failure == "git":
                        env["FAIL_GIT"] = "22"
                    elif failure == "julia":
                        (results / "env.sh").write_text("J=" + shlex.quote(str(Path(temp) / "missing julia")) + "\n")
                    elif failure == "log":
                        (results / "arm with spaces.0.log").mkdir()
                    result = self.run_launcher(script, env)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(list(capture.glob("job-*.json")))

    def test_final_launcher_propagates_version_and_retry_setup_failures(self):
        for failure in ["version", "retry"]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                results, capture, env = self.fixture(Path(temp), True)
                if failure == "version":
                    env["FAIL_JULIA_VERSION"] = "23"
                else:
                    (results / "retry.sh").unlink()
                result = self.run_launcher("launch_final.sh", env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list(capture.glob("job-*.json")))


if __name__ == "__main__":
    unittest.main()
