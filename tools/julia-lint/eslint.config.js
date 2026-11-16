import julia from "eslint-plugin-julia";

// All 12 recommended error rules had zero diagnostics/false positives over the
// 241-file main baseline. Scope, style and performance rules remain warnings.
export const blockingRules = [
    "parse-errors",
    "no-duplicate-struct-fields",
    "no-duplicate-keyword-arguments",
    "no-dupe-args",
    "no-unreachable",
    "no-unsafe-finally",
    "no-import-assign",
    "use-isnan",
    "prefer-ismissing",
    "no-isdefined-local-call",
    "no-invalid-foreign-call-signature",
    "no-uninitialized-ref-read",
];
const blocking = new Set(blockingRules);
export default [
    {
        ...julia.configs.strict,
        name: "energy-markets/julia",
        rules: Object.fromEntries(
            Object.keys(julia.rules).map((name) => [
                `julia/${name}`,
                name === "no-undef"
                    ? ["warn", { fragments: "report" }]
                    : blocking.has(name)
                      ? "error"
                      : "warn",
            ]),
        ),
    },
];
