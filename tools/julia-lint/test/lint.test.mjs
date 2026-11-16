import assert from "node:assert/strict";
import { test } from "node:test";
import { ESLint } from "eslint";
import config, { blockingRules } from "../eslint.config.js";
import { repository } from "../files.mjs";

const eslint = new ESLint({
    cwd: repository,
    overrideConfigFile: true,
    overrideConfig: config,
});
for (const [name, source] of [
    ["no-dupe-args", "f(x, x) = x\n"],
    ["no-duplicate-struct-fields", "struct Bad\n    x::Int\n    x::Int\nend\n"],
    ["use-isnan", "x == NaN\n"],
]) {
    test(`blocking rule julia/${name} detects its positive control`, async () => {
        const [result] = await eslint.lintText(source, { filePath: "__lint_fixture__.jl" });
        assert.ok(
            result.messages.some((m) => m.ruleId === `julia/${name}` && m.severity === 2),
        );
    });
}
test("ordinary Julia remains non-blocking", async () => {
    const [result] = await eslint.lintText("f(x) = x + 1\n", {
        filePath: "__lint_fixture__.jl",
    });
    assert.equal(result.errorCount, 0);
});
test("the remaining rules are advisory, including noisy scope analysis", async () => {
    const calculated = await eslint.calculateConfigForFile("__lint_fixture__.jl");
    assert.equal(blockingRules.length, 12);
    for (const [name, options] of Object.entries(calculated.rules)) {
        if (!blockingRules.includes(name.replace(/^julia\//, "")))
            assert.equal(options[0], 1);
    }
});
