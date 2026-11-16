# Julia lint and format

[eslint-plugin-julia](https://www.npmjs.com/package/eslint-plugin-julia) and
[prettier-plugin-julia](https://www.npmjs.com/package/prettier-plugin-julia), set up as their
docs describe (`package.json` + lockfile, `eslint.config.js`, a Prettier config). It lives in this
directory, not the repo root, because Cloudflare Workers Builds builds from the root and must not
pick up a Node package. Exact pins: Node 22.23.3, ESLint 10.15.0, Prettier 3.9.10, the plugins
0.3.1 / 0.2.1.

```sh
npm --prefix tools/julia-lint ci --ignore-scripts
npm --prefix tools/julia-lint run lint            # ESLint, every tracked *.jl
npm --prefix tools/julia-lint run format:check    # Prettier --check
npm --prefix tools/julia-lint run format          # Prettier --write
```

- **ESLint** uses the plugin's `strict` preset. Its 12 `recommended` error rules (likely bugs)
  fail CI; none fires on the current code. Every other rule is a warning: reported, never
  failing.
- **Prettier** uses the plugin's defaults (4-space indent, width 92). `juliaVerify` (on by
  default) re-parses every change and keeps code as written where formatting would change its
  meaning. The CI check is advisory until the repo has been formatted once.

Why JavaScript at all: ESLint 9+ reads its configuration only from `eslint.config.js` (flat
config; there is no JSON form), and both tools are npm packages, so pinning them needs a
`package.json` and lockfile. That is the whole setup; the Prettier config is plain JSON.
