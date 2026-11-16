import julia from "eslint-plugin-julia";

// The plugin's `strict` preset: its 12 `recommended` error rules (likely bugs; none fires on this
// repo) fail CI; every other rule is a warning that is reported but never fails.
export default [julia.configs.strict];
