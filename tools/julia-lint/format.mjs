import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { repository, trackedJuliaFiles } from "./files.mjs";

const tools = path.dirname(fileURLToPath(import.meta.url));
const files = trackedJuliaFiles();
if (files.length === 0) {
    console.log("No tracked Julia files; skipping Prettier.");
    process.exit(0);
}
// Argument arrays and a NUL-delimited Git inventory preserve unusual filenames.
// --check never writes Julia source; CI treats its nonzero result as advisory.
const result = spawnSync(
    process.execPath,
    [
        path.join(tools, "node_modules/prettier/bin/prettier.cjs"),
        "--check",
        "--config",
        path.join(tools, "prettier.config.js"),
        "--",
        ...files,
    ],
    { cwd: repository, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 },
);
if (result.error) throw result.error;
process.stdout.write(result.stdout ?? "");
process.stderr.write(result.stderr ?? "");
if (process.env.GITHUB_STEP_SUMMARY) {
    const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.replaceAll("`", "\\`");
    await fs.appendFile(
        process.env.GITHUB_STEP_SUMMARY,
        `### Julia Prettier (advisory)\n\nChecked ${files.length} tracked Julia files with --check; exit ${result.status ?? "signal"}.\n\n<details><summary>Formatter report</summary>\n\n\`\`\`text\n${output}\n\`\`\`\n\n</details>\n`,
    );
}
process.exitCode = result.status ?? 2;
