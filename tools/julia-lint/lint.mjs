import fs from "node:fs/promises";
import path from "node:path";
import { ESLint } from "eslint";
import config from "./eslint.config.js";
import { changedJuliaFiles, repository, trackedJuliaFiles } from "./files.mjs";

const mode = process.argv[2] ?? "all";
if (!["all", "changed"].includes(mode))
    throw new Error("Usage: node lint.mjs all|changed [BASE HEAD]");
const files =
    mode === "changed"
        ? changedJuliaFiles(
              process.argv[3] ?? process.env.LINT_BASE_SHA,
              process.argv[4] ?? process.env.LINT_HEAD_SHA,
          )
        : trackedJuliaFiles();
async function summary(text) {
    if (process.env.GITHUB_STEP_SUMMARY)
        await fs.appendFile(process.env.GITHUB_STEP_SUMMARY, text);
}
if (files.length === 0) {
    console.log(
        `No ${mode === "changed" ? "changed" : "tracked"} Julia files; skipping ESLint.`,
    );
    await summary(`### Julia ESLint (${mode})\n\nNo Julia files selected; skipped.\n`);
    process.exit(0);
}
try {
    const eslint = new ESLint({
        cwd: repository,
        overrideConfigFile: true,
        overrideConfig: config,
    });
    const results = await eslint.lintFiles(files);
    console.log((await eslint.loadFormatter("stylish")).format(results));
    const counts = new Map();
    for (const result of results)
        for (const message of result.messages) {
            const key = message.ruleId ?? "fatal-parser";
            const row = counts.get(key) ?? { errors: 0, warnings: 0, files: new Set() };
            row[message.severity === 2 ? "errors" : "warnings"]++;
            row.files.add(path.relative(repository, result.filePath));
            counts.set(key, row);
        }
    const errors = results.reduce((sum, result) => sum + result.errorCount, 0);
    const warnings = results.reduce((sum, result) => sum + result.warningCount, 0);
    let markdown = `### Julia ESLint (${mode})\n\n${files.length} files; ${errors} errors, ${warnings} warnings.\n\n`;
    markdown += "| Rule | Errors | Warnings | Files |\n|---|---:|---:|---:|\n";
    for (const [rule, row] of [...counts].sort(([a], [b]) => a.localeCompare(b))) {
        markdown += `| ${rule} | ${row.errors} | ${row.warnings} | ${row.files.size} |\n`;
    }
    if (!counts.size) markdown += "| No findings | 0 | 0 | 0 |\n";
    await summary(markdown);
    const output = path.join(repository, "tools/julia-lint/reports");
    await fs.mkdir(output, { recursive: true });
    await fs.writeFile(
        path.join(output, `eslint-${mode}.json`),
        JSON.stringify(results, null, 2),
    );
    process.exitCode = errors ? 1 : 0;
} catch (error) {
    await summary(
        `### Julia ESLint (${mode}) failed\n\nThe tool failed; inspect the step log.\n`,
    );
    throw error;
}
