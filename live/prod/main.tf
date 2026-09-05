terraform {
  required_version = ">= 1.9"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "__PRODUCT__/prod/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Project     = "__PRODUCT__"
      Environment = "production"
      ManagedBy   = "opentofu"
    }
  }
}

# Cloudflare provider — see develop stack for rationale. DNS record created
# only when cloudflare_zone_id is set, so this stack applies before DNS wiring.
provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}

data "aws_caller_identity" "current" {}

# ── Read shared layer outputs (ECR URLs, KMS ARN, artifacts bucket) ─────────────
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "__PRODUCT__/shared/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  env    = "production"
  name   = "__PRODUCT__-prod"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  kms_key_arn        = data.terraform_remote_state.shared.outputs.kms_key_arn
  cloudflare_zone_id = try(data.terraform_remote_state.shared.outputs.cloudflare_zone_id, "")

  # Deployment mode — coalesce empty (unset GitHub repo var) → app defaults.
  deployment_mode    = var.deployment_mode != "" ? var.deployment_mode : "saas"
  single_tenant_name = var.single_tenant_name != "" ? var.single_tenant_name : "Default Organization"
  single_tenant_slug = var.single_tenant_slug != "" ? var.single_tenant_slug : "default"

  ecr_base       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  ecr_api_url    = "${local.ecr_base}/__PRODUCT__-api:latest"
  ecr_worker_url = "${local.ecr_base}/__PRODUCT__-worker:latest"

  # Cloudflare IPv4 ranges — single source of truth in qnsc-infra bootstrap
  # (read via _shared remote state), so a CF range change is one edit there.
  cloudflare_ipv4 = data.terraform_remote_state.shared.outputs.cloudflare_ipv4

  # prod_tier switch (Option A): lean = single-AZ DB + 1 task/svc; ha = multi-AZ
  # DB + 2 tasks/svc. Cache is always a dedicated per-product node (below),
  # independent of tier.
  is_ha = var.prod_tier == "ha"

  # Cache endpoint: this product's own dedicated Valkey node (module.cache below).
  # The cache module enables in-transit encryption, so the client connects over
  # TLS (rediss://). REDIS_URL is an env var (not a secret) — the endpoint isn't
  # sensitive.
  cache_endpoint = module.cache.endpoint
  cache_port     = module.cache.port
  redis_url      = "rediss://${local.cache_endpoint}:${local.cache_port}"
}

# ── Shared runtime layer (VPC + NAT + ALB + WAF) ──────────────────────────────
# Option A: the prod VPC/NAT/ALB/WAF live once per env in
# qnsc-infra/live/runtime-prod and are consumed here via remote state. RDS +
# cache + Fargate stay per-product below.
data "terraform_remote_state" "runtime" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/runtime-prod/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# ── Secrets ───────────────────────────────────────────────────────────────────
module "secrets" {
  source               = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/secrets?ref=secrets-v2.1.1"
  prefix               = "__PRODUCT__/${local.env}"
  kms_key_arn          = local.kms_key_arn
  recovery_window_days = 30 # longer recovery in production

  secret_names = merge(var.otlp_endpoint == "" ? {} : {
    # The COMPLETE Authorization header the collector sidecar sends upstream,
    # e.g. `Basic base64(instanceID:token)` — not the bare token. See
    # modules/observability-agent's README for the exact
    # `aws secretsmanager put-secret-value` command, filled with
    # qnsc-infra/live/observability's otlp_stack_id + otlp_push_token outputs.
    "observability-token" = "Authorization header for the OTLP backend (e.g. 'Basic <base64>')"
    }, {
    "db-url"      = "PostgreSQL connection URL for the app"
    "jwt-private" = "EC P-256 (ES256) private key (PEM, base64-encoded)"
    "jwt-public"  = "EC P-256 (ES256) public key (PEM, base64-encoded)"
    "csrf-secret" = "CSRF token signing secret"
  })

  tags = { Environment = local.env }
}

# ── OpenTelemetry sidecars ────────────────────────────────────────────────────
# One per task, not one shared collector — each pushes straight out to
# Grafana Cloud over the task's own NAT egress. No ingress, no gateway, no
# tunnel needed: see qnsc-infra/live/observability's header comment for why.
# Both are a no-op until var.otlp_endpoint is set AND the observability-token
# secret holds a value — the module returns empty lists, and OTEL_ENABLED
# below is gated on the same flag, so the app is never told to export into a
# void. Turning telemetry on is then a one-line change per environment.
module "otel_agent_api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/observability-agent?ref=observability-agent-v1.0.0"

  product       = "__PRODUCT__"
  env           = local.env
  otlp_endpoint = var.otlp_endpoint
  # try(): the secret is not created while the OTel path is dormant, and this
  # module is a no-op in that state anyway — an absent ARN is correct input.
  token_secret_arn = try(module.secrets.secret_arns["observability-token"], "")
  log_group        = "/ecs/${local.name}-api"
  region           = local.region
}

module "otel_agent_worker" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/observability-agent?ref=observability-agent-v1.0.0"

  product          = "__PRODUCT__"
  env              = local.env
  otlp_endpoint    = var.otlp_endpoint
  token_secret_arn = try(module.secrets.secret_arns["observability-token"], "")
  log_group        = "/ecs/${local.name}-worker"
  region           = local.region
}

# ── RDS PostgreSQL 17 (Multi-AZ in ha tier) ──────────────────────────────────
module "rds" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/rds?ref=rds-v2.1.2"

  identifier        = local.name
  subnet_ids        = data.terraform_remote_state.runtime.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.runtime.outputs.sg_rds_id
  kms_key_arn       = local.kms_key_arn

  instance_class           = local.is_ha ? "db.t4g.large" : "db.t4g.micro"
  allocated_storage_gb     = 100
  max_allocated_storage_gb = 500
  multi_az                 = local.is_ha # HA tier only — lean is single-AZ
  deletion_protection      = true
  backup_retention_days    = 30
  monitoring_interval      = local.is_ha ? 60 : 0 # Enhanced Monitoring in ha only

  tags = { Environment = local.env }
}

# ── Cache (dedicated per-product Valkey node) ────────────────────────────────
# Each product owns its own single-node ElastiCache Valkey so one product's load
# or a node restart can't evict another product's BFF sessions. In-transit +
# at-rest encryption on (SOC 2); reuses the shared runtime-prod cache SG + data
# subnets. Endpoint feeds local.redis_url (rediss://) above.
module "cache" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cache?ref=cache-v1.0.0"

  name              = "${local.name}-cache"
  subnet_ids        = data.terraform_remote_state.runtime.outputs.data_subnet_ids
  security_group_id = data.terraform_remote_state.runtime.outputs.sg_cache_id
  kms_key_arn       = local.kms_key_arn

  mode      = "node" # single cache.t4g.micro (~$12/mo) — cheaper than serverless ~$90 floor
  node_type = "cache.t4g.micro"

  tags = { Environment = local.env }
}

# ── Messaging ─────────────────────────────────────────────────────────────────
module "messaging" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/messaging?ref=messaging-v1.0.0"

  prefix                = local.name
  dlq_max_receive_count = 3 # move to DLQ faster in production

  queues = {
    notifications = {}
    audit         = { visibility_timeout = 60 }
    reporting     = { visibility_timeout = 300 }
    search        = {}
  }

  topics = ["domain-events"]

  subscriptions = [
    {
      topic         = "domain-events"
      queue         = "notifications"
      filter_policy = jsonencode({ eventType = ["notification.created", "notification.updated"] })
    }
  ]

  tags = { Environment = local.env }
}

# ── ALB: shared, lives in runtime-prod (with access logs + WAF). This stack
# attaches host-header listener rules (module.api) to its HTTPS listener. ──────

# ── ECS Cluster ───────────────────────────────────────────────────────────────
module "ecs_cluster" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecs-cluster?ref=ecs-cluster-v2.0.0"
  name   = local.name

  # STATED, never inherited. "enhanced" adds per-task and per-container metrics that
  # CloudWatch bills as CUSTOM metrics at $0.07 each — four clusters silently on that
  # default produced 606 metric-months (~$42) on the July 2026 bill, and the count grows
  # with task churn rather than with traffic.
  #
  # This template did not state it at all, so every product created from it inherited the
  # module default — which was "enhanced" until ecs-cluster v2.0.0 changed it to "enabled".
  # A new product should not have to discover that on a bill.
  #
  # "disabled" matches rally, qnsc-kb-backend and opshub, all of which audited their
  # consumers and found none: their alarms and dashboards read AWS/ECS, AWS/ApplicationELB
  # and AWS/RDS, which are free and published regardless. Raise to "enhanced" temporarily
  # while debugging a per-container resource problem, then put it back.
  container_insights = "disabled"

  tags = { Environment = local.env }
}

# ── ECS Service — API ─────────────────────────────────────────────────────────
module "api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecs-service?ref=ecs-service-v2.1.1"

  service_name = "api"
  cluster_name = module.ecs_cluster.cluster_name
  cluster_arn  = module.ecs_cluster.cluster_arn
  region       = local.region
  image_uri    = local.ecr_api_url

  cpu    = 1024
  memory = 2048

  vpc_id            = data.terraform_remote_state.runtime.outputs.vpc_id
  subnet_ids        = data.terraform_remote_state.runtime.outputs.private_subnet_ids
  security_group_id = data.terraform_remote_state.runtime.outputs.sg_app_id

  desired_count = local.is_ha ? 2 : 1 # ha: 2 for redundancy; lean: 1
  min_count     = local.is_ha ? 2 : 1
  max_count     = 10

  attach_alb        = true
  alb_listener_arn  = data.terraform_remote_state.runtime.outputs.https_listener_arn
  alb_priority      = 100
  alb_path_patterns = ["/*"]
  alb_host_headers  = ["__PRODUCT__-api.qnsc.vn"] # host-based routing on the shared prod ALB
  health_check_path = "/v1/healthz"

  # No-op ([]) until var.otlp_endpoint is set.
  additional_containers = module.otel_agent_api.container_definitions

  secret_arns = values(module.secrets.secret_arns)
  secrets = [
    { name = "DATABASE_URL", secret_arn = module.secrets.secret_arns["db-url"] },
    { name = "JWT_PRIVATE_KEY", secret_arn = module.secrets.secret_arns["jwt-private"] },
    { name = "JWT_PUBLIC_KEY", secret_arn = module.secrets.secret_arns["jwt-public"] },
    { name = "CSRF_SECRET", secret_arn = module.secrets.secret_arns["csrf-secret"] },
  ]

  environment_vars = [
    { name = "NODE_ENV", value = "production" },
    { name = "PORT", value = "3000" },
    { name = "REDIS_URL", value = local.redis_url }, # shared (lean) or per-product (ha) cache
    # Deployment mode — set per customer. 'saas' (default) = multi-tenant;
    # 'single' = one tenant, self-serve signup disabled.
    { name = "DEPLOYMENT_MODE", value = local.deployment_mode },
    { name = "SINGLE_TENANT_NAME", value = local.single_tenant_name },
    { name = "SINGLE_TENANT_SLUG", value = local.single_tenant_slug },
    # Observability. False until var.otlp_endpoint is set — the app must
    # never be told to export into a void.
    { name = "LOG_LEVEL", value = "info" },
    { name = "LOG_PRETTY", value = "false" },
    { name = "OTEL_ENABLED", value = tostring(module.otel_agent_api.enabled) },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = module.otel_agent_api.endpoint },
    { name = "OTEL_SERVICE_NAME", value = "__PRODUCT__-api" },
  ]

  sqs_queue_arns = values(module.messaging.queue_arns)
  sns_topic_arns = values(module.messaging.topic_arns)

  cpu_target_pct     = 60 # tighter target in prod
  memory_target_pct  = 70
  log_retention_days = 90 # 90 days — SOC 2 minimum for prod logs

  tags = { Environment = local.env, Service = "api" }
}

# ── ECS Service — Worker ──────────────────────────────────────────────────────
module "worker" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/ecs-service?ref=ecs-service-v2.1.1"

  service_name = "worker"
  cluster_name = module.ecs_cluster.cluster_name
  cluster_arn  = module.ecs_cluster.cluster_arn
  region       = local.region
  image_uri    = local.ecr_worker_url

  cpu    = 512
  memory = 1024

  vpc_id            = data.terraform_remote_state.runtime.outputs.vpc_id
  subnet_ids        = data.terraform_remote_state.runtime.outputs.private_subnet_ids
  security_group_id = data.terraform_remote_state.runtime.outputs.sg_app_id

  desired_count = local.is_ha ? 2 : 1
  min_count     = local.is_ha ? 2 : 1
  max_count     = 6

  attach_alb = false

  health_check_command = "curl -f http://localhost:3001/v1/healthz || exit 1"
  container_port       = 3001

  # No-op ([]) until var.otlp_endpoint is set.
  additional_containers = module.otel_agent_worker.container_definitions

  secret_arns = values(module.secrets.secret_arns)
  secrets = [
    { name = "DATABASE_URL", secret_arn = module.secrets.secret_arns["db-url"] },
    { name = "JWT_PRIVATE_KEY", secret_arn = module.secrets.secret_arns["jwt-private"] },
    { name = "JWT_PUBLIC_KEY", secret_arn = module.secrets.secret_arns["jwt-public"] },
  ]

  environment_vars = [
    { name = "NODE_ENV", value = "production" },
    { name = "REDIS_URL", value = local.redis_url },
    { name = "LOG_LEVEL", value = "info" },
    { name = "LOG_PRETTY", value = "false" },
    { name = "OTEL_ENABLED", value = tostring(module.otel_agent_worker.enabled) },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = module.otel_agent_worker.endpoint },
    { name = "OTEL_SERVICE_NAME", value = "__PRODUCT__-worker" },
  ]

  sqs_queue_arns     = values(module.messaging.queue_arns)
  sns_topic_arns     = values(module.messaging.topic_arns)
  log_retention_days = 90

  tags = { Environment = local.env, Service = "worker" }
}

# ── CloudWatch alarms + dashboard ────────────────────────────────────────────
# SNS-backed golden-signal alarms (ECS CPU/mem, ALB 5xx/latency, RDS
# CPU/storage/connections). Independent of the OTel path above — these fire
# from native CloudWatch metrics regardless of whether var.otlp_endpoint is
# set. ~$0.10/mo alarms, ~$3/mo dashboard.
module "observability" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/observability?ref=observability-v4.1.0"

  name              = local.name
  region            = local.region
  ecs_cluster_name  = module.ecs_cluster.cluster_name
  ecs_service_names = [module.api.service_name, module.worker.service_name]
  alb_arn           = data.terraform_remote_state.runtime.outputs.alb_arn
  rds_instance_id   = module.rds.instance_id

  # worker carries no target group (attach_alb = false above), so it has
  # nothing to alarm on here — only api's.
  target_group_arns = { api = module.api.target_group_arn }

  alarm_emails = var.alarm_emails
  tags         = { Environment = local.env }
}

# ── WAF: lives in runtime-prod and is associated with the shared ALB there. ──

# ── Web SPA — Cloudflare Pages (zero-egress, native SPA routing) ─────────────
# Cloudflare's global edge replaces the CloudFront PriceClass_All coverage. The
# custom domain (web_domain, e.g. "__PRODUCT__.qnsc.vn") is a prod product
# decision — the web module (Pages project + custom domain + DNS) is created
# only when cloudflare_account_id AND web_domain are both set, so prod applies
# cleanly before the public hostname is chosen.
module "web" {
  count  = var.cloudflare_account_id != "" && var.web_domain != "" ? 1 : 0
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/pages-web?ref=pages-web-v1.0.1"

  account_id  = var.cloudflare_account_id
  name        = "__PRODUCT__-prod-web"
  zone_id     = local.cloudflare_zone_id
  domain      = var.web_domain
  record_name = var.web_domain
  comment     = "__PRODUCT__-prod web SPA → Cloudflare Pages (managed by __PRODUCT__-infra prod)"
}
