import { execFileSync } from "node:child_process";
import { existsSync, lstatSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const repository = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../..",
);
function git(root, args) {
    return execFileSync("git", args, { cwd: root }).toString("utf8");
}
function existingJulia(root, names) {
    return names.filter(
        (file) =>
            file.endsWith(".jl") &&
            existsSync(path.join(root, file)) &&
            lstatSync(path.join(root, file)).isFile(),
    );
}
export function trackedJuliaFiles(root = repository) {
    return existingJulia(
        root,
        git(root, ["ls-files", "-z", "*.jl"]).split("\0").filter(Boolean),
    );
}
export function changedJuliaFiles(base, head, root = repository) {
    if (!base || !head)
        throw new Error("Changed-file mode requires base and head commit references.");
    const resolve = (ref) =>
        git(root, ["rev-parse", "--verify", "--end-of-options", `${ref}^{commit}`]).trim();
    const range = `${resolve(base)}...${resolve(head)}`;
    // ACMRT includes additions, copies, modifications, renames and type changes;
    // deleted paths are excluded. NUL separation preserves spaces and newlines.
    const names = git(root, [
        "diff",
        "--name-only",
        "-z",
        "--diff-filter=ACMRT",
        range,
        "--",
        "*.jl",
    ])
        .split("\0")
        .filter(Boolean);
    return existingJulia(root, names);
}
