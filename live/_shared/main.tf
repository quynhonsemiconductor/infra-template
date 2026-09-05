terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "__PRODUCT__/shared/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Project   = "__PRODUCT__"
      Scope     = "shared"
      ManagedBy = "opentofu"
    }
  }
}

# ── Platform remote state (OIDC provider ARN, KMS, artifacts bucket) ──────────
# Provided by qnsc-infra/live/bootstrap (the account-level singletons).
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

data "aws_caller_identity" "current" {}

# ── Container registries ──────────────────────────────────────────────────────
# Add/remove repos to match what this product builds.
module "ecr" {
  source               = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecr?ref=ecr-v2.0.0"
  repository_names     = ["__PRODUCT__-api", "__PRODUCT__-worker"]
  image_tag_mutability = "MUTABLE"
  kms_key_arn          = data.terraform_remote_state.platform.outputs.kms_key_arn
  tags                 = { Scope = "shared" }
}

# ── GitHub OIDC deploy roles (deploy per-env, ecr-push, infra plan/apply) ─────
module "iam_oidc" {
  source            = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/iam-oidc?ref=iam-oidc-v3.0.1"
  product           = "__PRODUCT__"
  github_org        = var.github_org
  oidc_provider_arn = data.terraform_remote_state.platform.outputs.oidc_provider_arn

  environments = {
    develop = {
      allowed_subjects = [
        "repo:${var.github_org}/__PRODUCT__-api:ref:refs/heads/main",
        "repo:${var.github_org}/__PRODUCT__-api:environment:develop",
      ]
    }
    production = {
      allowed_subjects = [
        "repo:${var.github_org}/__PRODUCT__-api:ref:refs/heads/main",
        "repo:${var.github_org}/__PRODUCT__-api:ref:refs/tags/v*",
      ]
    }
  }

  app_repo_names         = ["__PRODUCT__-api"]
  infra_repo_name        = "__PRODUCT__-infra"
  ecr_repository_pattern = "__PRODUCT__-*"
  ecs_passrole_pattern   = "__PRODUCT__-*"
  tags                   = { Scope = "shared" }

  # Blast-radius guardrail: explicit-Deny on this product's infra-apply role so a
  # buggy product apply cannot destroy the platform's own foundations (state bucket,
  # lock table, OIDC provider, CMK) or mint IAM users — all owned by qnsc-infra
  # bootstrap, never by a product. (The platform stack itself omits this.)
  infra_apply_guardrail = {
    state_bucket_arn     = "arn:aws:s3:::qnsc-tofu-state"
    lock_table_arn       = "arn:aws:dynamodb:ap-southeast-1:${data.aws_caller_identity.current.account_id}:table/qnsc-tofu-locks"
    oidc_provider_arn    = data.terraform_remote_state.platform.outputs.oidc_provider_arn
    kms_key_arn          = data.terraform_remote_state.platform.outputs.kms_key_arn
    artifacts_bucket_arn = data.terraform_remote_state.platform.outputs.artifacts_bucket_arn
  }
}

# ── Web SPA deploy ────────────────────────────────────────────
# The web SPA deploys to Cloudflare Pages (wrangler pages deploy) using a Cloudflare
# API token, so it needs no AWS deploy role. If a product ever hosts its web build on
# S3+CloudFront instead, add a dedicated deploy role here — but the standard is
# Cloudflare Pages (see rally / opshub web-deploy.yml).
