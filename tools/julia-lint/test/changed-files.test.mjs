import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { changedJuliaFiles } from "../files.mjs";

function fixture(t) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "julia-lint-files-"));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const git = (...args) => execFileSync("git", args, { cwd: root }).toString().trim();
    git("init", "-q");
    const commit = () => {
        git("add", ".");
        git(
            "-c",
            "user.name=CI test",
            "-c",
            "user.email=ci@example.invalid",
            "commit",
            "-qm",
            "fixture",
        );
        return git("rev-parse", "HEAD");
    };
    fs.writeFileSync(path.join(root, "untouched.jl"), "x = 1\n");
    fs.writeFileSync(path.join(root, "deleted.jl"), "y = 1\n");
    fs.writeFileSync(path.join(root, "README.md"), "baseline\n");
    return { root, git, commit, base: commit() };
}
test("a PR with no Julia changes selects nothing", (t) => {
    const f = fixture(t);
    fs.writeFileSync(path.join(f.root, "README.md"), "updated\n");
    assert.deepEqual(changedJuliaFiles(f.base, f.commit(), f.root), []);
});
test("one added Julia file, including spaces, is selected", (t) => {
    const f = fixture(t);
    fs.writeFileSync(path.join(f.root, "one file.jl"), "z = 2\n");
    assert.deepEqual(changedJuliaFiles(f.base, f.commit(), f.root), ["one file.jl"]);
});
test("deleted Julia files are skipped", (t) => {
    const f = fixture(t);
    fs.unlinkSync(path.join(f.root, "deleted.jl"));
    assert.deepEqual(changedJuliaFiles(f.base, f.commit(), f.root), []);
});
test("merge-base comparison excludes changes already on the base branch", (t) => {
    const f = fixture(t);
    f.git("branch", "pr");
    fs.writeFileSync(path.join(f.root, "base-only.jl"), "b = 1\n");
    const base = f.commit();
    f.git("checkout", "-q", "pr");
    fs.writeFileSync(path.join(f.root, "pr.jl"), "p = 1\n");
    assert.deepEqual(changedJuliaFiles(base, f.commit(), f.root), ["pr.jl"]);
});
