import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ESLint } from "eslint";
import julia from "eslint-plugin-julia";
import * as prettier from "prettier";
import prettierConfig from "./prettier.config.js";

const tools = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(tools, "../..");
const output = path.resolve(process.argv[2] ?? path.join(tools, "reports/baseline"));
await fs.mkdir(output, { recursive: true });
const files = execFileSync("git", ["ls-files", "-z", "*.jl"], { cwd: root })
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
await fs.writeFile(path.join(output, "files.nul"), files.join("\0") + "\0");
const eslint = new ESLint({
    cwd: root,
    overrideConfigFile: true,
    overrideConfig: [julia.configs.strict],
});
const results = await eslint.lintFiles(files);
await fs.writeFile(path.join(output, "eslint.json"), JSON.stringify(results, null, 2));
const rules = Object.fromEntries(
    Object.keys(julia.rules).map((name) => [
        `julia/${name}`,
        { errors: 0, warnings: 0, files: [] },
    ]),
);
for (const result of results) {
    for (const message of result.messages) {
        const key = message.ruleId ?? "fatal-parser";
        const rule = (rules[key] ??= { errors: 0, warnings: 0, files: [] });
        rule[message.severity === 2 ? "errors" : "warnings"]++;
        const relative = path.relative(root, result.filePath);
        if (!rule.files.includes(relative)) rule.files.push(relative);
    }
}
await fs.writeFile(path.join(output, "eslint-rules.json"), JSON.stringify(rules, null, 2));
const formatting = [];
let inspected = 0;
for (const file of files) {
    const original = await fs.readFile(path.join(root, file), "utf8");
    const warnings = [];
    const warn = console.warn;
    console.warn = (...args) => warnings.push(args.join(" "));
    let entry;
    try {
        const options = {
            ...prettierConfig,
            filepath: path.join(root, file),
            parser: "julia",
        };
        const formatted = await prettier.format(original, options);
        const again = await prettier.format(formatted, options);
        const target = path.join(output, "formatted", file);
        await fs.mkdir(path.dirname(target), { recursive: true });
        await fs.writeFile(target, formatted);
        entry = {
            file,
            changed: original !== formatted,
            idempotent: formatted === again,
            originalBytes: Buffer.byteLength(original),
            formattedBytes: Buffer.byteLength(formatted),
            warnings,
        };
    } catch (error) {
        entry = { file, error: error.stack ?? String(error), warnings };
        const target = path.join(output, "formatted", file);
        await fs.mkdir(path.dirname(target), { recursive: true });
        await fs.writeFile(target, original);
    } finally {
        console.warn = warn;
    }
    formatting.push(entry);
    if (++inspected % 20 === 0) console.log(`formatted ${inspected}/${files.length}`);
}
await fs.writeFile(path.join(output, "prettier.json"), JSON.stringify(formatting, null, 2));
console.log(
    JSON.stringify({
        files: files.length,
        errors: results.reduce((s, r) => s + r.errorCount, 0),
        warnings: results.reduce((s, r) => s + r.warningCount, 0),
        changed: formatting.filter((r) => r.changed).length,
        nonidempotent: formatting.filter((r) => r.idempotent === false).length,
        formatterErrors: formatting.filter((r) => r.error).length,
    }),
);
