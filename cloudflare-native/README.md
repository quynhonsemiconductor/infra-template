# Cloudflare-native archetype

A minimal [Cloudflare Pages](https://developers.cloudflare.com/pages/) + [Pages
Functions](https://developers.cloudflare.com/pages/functions/) starter for
products that don't need the AWS full-stack (`../live/`). Zero egress, edge
compute, optional D1/KV/R2 — no VPC, no ECS, no OpenTofu.

## When to use this

- Marketing sites, docs, dashboards, or thin API-on-the-edge products.
- You want D1 (edge SQLite), KV, or R2 rather than RDS + Fargate.
- No long-running containers / background workers.

If you need Postgres, background workers (SQS/SNS), or a private VPC, use the
**AWS full-stack** archetype in [`../live/`](../live/) instead.

## Layout

```
cloudflare-native/
├── wrangler.toml              # project name + bindings (D1/KV/R2 examples)
├── package.json               # wrangler dev/build/deploy scripts
├── functions/
│   └── api/hello.ts           # example Pages Function → GET /api/hello
└── .github/workflows/
    └── security.yml           # thin caller of qnsc-ci security.yml@v1
```

## Quick start

1. `init.sh` (repo root) replaces `__PRODUCT__` with your product slug.
2. Wire your framework build into `package.json` → `build` (output to `dist/`).
3. Local dev: `pnpm dev` (serves `dist/` + Functions via `wrangler pages dev`).
4. Deploy: `pnpm deploy` (or let CI run `wrangler pages deploy`).
5. Add a database when needed: `wrangler d1 create __PRODUCT__`, then uncomment
   the `[[d1_databases]]` block in `wrangler.toml`.

## CI

`security.yml` calls the shared `quynhonsemiconductor/ci/.github/workflows/security.yml@v1`
with `scan_container: false` — the same Semgrep + Gitleaks + osv-scanner gate the
AWS products run, minus the container scan (there's no Dockerfile here). Add your
own build/deploy workflow alongside it.
