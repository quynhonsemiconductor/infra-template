# qnsc-infra-template

Starting skeleton for a **new QNSC product infrastructure repo**. Clone this,
run the init script, and you get the correct `live/{_shared,develop,prod}`
structure, state backend wiring, OIDC roles, and CI — consistent with every
other product.

> This template exists so 10 new projects don't hand-copy structure and drift.

---

## Choose your archetype

Two shapes ship in this template. Pick one; delete the other.

| Archetype | Use when | Where | Provisions |
| :-------- | :------- | :---- | :--------- |
| **AWS full-stack** | Postgres + background workers (SQS/SNS), private VPC, container services. | [`live/`](./live/) | Per-product **RDS + Fargate** (api/worker/migrator). Shares the **VPC / NAT / ALB / WAF** from `qnsc-infra`'s `runtime-dev` / `runtime-prod` (Option A) via remote state — it does **not** create its own network. |
| **Cloudflare-native** | Static site or thin API-on-the-edge, D1/KV/R2 instead of RDS. No long-running containers. | [`cloudflare-native/`](./cloudflare-native/) | A **Cloudflare Pages** project + **Pages Functions**. Zero egress, no OpenTofu, no AWS. |

> **AWS full-stack prerequisite (Option A):** the shared runtime layer must exist
> first — `qnsc-infra/live/runtime-dev` (key `platform/runtime-dev/...`) and
> `runtime-prod` (key `platform/runtime-prod/...`). The env stacks read the
> VPC/subnets/ALB/SGs from those via `terraform_remote_state "runtime"`. See
> [`live/README`](./live/) below.

The rest of this README covers the **AWS full-stack** archetype. For
Cloudflare-native, see [`cloudflare-native/README.md`](./cloudflare-native/README.md).

---

## The QNSC platform model (read this first)

"Shared infra" does **not** mean every product runs the same infrastructure. It
means three distinct things:

| Layer | Repo | What it is | Can it differ per product? |
| :---- | :--- | :--------- | :------------------------- |
| **Singletons** | `qnsc-infra` | The one-per-account resources: GitHub OIDC provider, KMS CMK, Tofu state bucket + lock table, artifacts bucket. | **No** — physically one per AWS account. Every product references them. |
| **Building blocks** | `qnsc-tf-modules` | Versioned, reusable Terraform modules (network, rds, ecs-cluster, cdn, …). A **menu**, not a mandate. | **Yes** — pick what fits. An EKS product ignores `ecs-cluster`. A Lambda product uses almost none. |
| **Composition** | *this template* → `<product>-infra` | Each product's `live/` wires the modules it needs with its own values. | **Yes** — this is where products differ. |

So an **ECS product** and an **EKS product** both "use the shared platform":
they share OIDC/KMS/state/conventions, but compose different modules. Different
infra is expected and supported.

### When do I add a new shared module?

**Rule of two.** Build infra **local** to your product first (in `./modules/`).
The moment a **second** product needs the same thing, promote it to
`qnsc-tf-modules` (versioned, tagged) and have both reference it. Used by one
product → keep it local. This avoids premature abstraction *and* copy-paste drift.

- Need EKS and no shared `eks` module exists? Build it locally. When product #2
  needs EKS, promote it.
- Need something only this product will ever use? Keep it local forever. Fine.

---

## Using this template

```bash
# 1. Create the repo from this template (GitHub "Use this template", or clone)
git clone git@github.com:quynhonsemiconductor/qnsc-infra-template.git myproduct-infra
cd myproduct-infra

# 2. Replace the __PRODUCT__ placeholder everywhere
./scripts/init.sh myproduct

# 3. Review and fill in (see init.sh output for the checklist)
```

After init you have:

```
live/
  _shared/   ECR repos + GitHub OIDC deploy roles (api/worker + web). Run once.
  develop/   Develop environment stack. Provisions this product's own RDS +
             Fargate (api/worker/migrator); consumes the shared VPC/NAT/ALB
             from qnsc-infra runtime-dev via remote state (does NOT create its
             own network). See live/develop/main.tf for the wiring.
  prod/      Production stack. Same shape as develop (per-product RDS + Fargate,
             shared VPC/NAT/ALB from runtime-prod) plus a prod_tier switch
             (lean | ha) for RDS Multi-AZ, per-product cache, and task counts.
.github/workflows/
  plan.yml   tofu plan on PRs (per changed env), posts comment.
  apply.yml  tofu apply on merge: _shared → develop → prod (prod gated).
```

Then **compose the modules this product needs** in `live/develop` and
`live/prod`. See `rally-infra` / `opshub-infra` for full worked examples — they
follow the same Option A shape (shared runtime layer + per-product RDS/Fargate).

---

## Prerequisites for a new product

1. **`qnsc-infra` bootstrap AND the shared runtime layer applied** — the
   platform singletons (`bootstrap`) plus `runtime-dev` and `runtime-prod`
   (shared VPC / NAT / ALB / WAF) must exist first. The env stacks read them
   via `terraform_remote_state "runtime"`.
2. **GitHub secrets** on the new repo: `AWS_ACCOUNT_ID`, plus the Cloudflare
   wiring for the web SPA + API DNS — `CLOUDFLARE_ACCOUNT_ID` (→
   `TF_VAR_cloudflare_account_id`) and `CLOUDFLARE_API_TOKEN` (→
   `TF_VAR_cloudflare_api_token`, Zone:DNS:Edit on `qnsc.vn`). The Cloudflare
   zone ID and IP ranges are read from `qnsc-infra` bootstrap via `_shared`
   remote state — not repo secrets. (`ACM_CERT_ARN_*` is vestigial: the ALB now
   lives in the shared runtime layer; the var is kept for CI compatibility.)
3. **GitHub Environments** `shared`, `develop`, `production` (add required
   reviewers on `production` for the apply gate).
4. **Infra OIDC role** `<product>-github-infra-apply` — created once (broad
   `AdministratorAccess` initially, then tighten). It can't bootstrap itself
   because the apply pipeline assumes it.

---

## Conventions baked in

- State key: `<product>/<env>/terraform.tfstate` in `qnsc-tofu-state`.
- OIDC-only auth (no static AWS keys) via `qnsc-ci/actions/setup-tofu-aws@v1`.
- Modules referenced by pinned tag: `?ref=<module>-vX.Y.Z`.
- Apply order `_shared → develop → prod`; prod requires manual approval.

## License

Proprietary and confidential. © QNSC — Quy Nhon Semiconductor. See [`LICENSE`](./LICENSE).
