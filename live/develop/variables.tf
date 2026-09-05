variable "acm_cert_arn" {
  type        = string
  default     = ""
  description = "ACM certificate ARN for the ALB HTTPS listener (ap-southeast-1). The ALB is shared and lives in runtime-dev — kept for compatibility with the CI var wiring."
}

variable "cloudflare_account_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Cloudflare account ID that owns the Pages project (account-level input, not
    a secret). Pass via TF_VAR_cloudflare_account_id in CI. Leave empty to skip
    the web module while the Cloudflare account is not yet wired.
  EOT
}

variable "entra_tenant_id" {
  type        = string
  description = "Microsoft Entra (Azure AD) tenant ID — leave empty to disable SSO"
  default     = ""
}

variable "entra_client_id" {
  type        = string
  description = "Microsoft Entra (Azure AD) app client ID — leave empty to disable SSO"
  default     = ""
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    Cloudflare API token (Zone:DNS:Edit on qnsc.vn). Supplied via
    TF_VAR_cloudflare_api_token in CI. Leave empty to skip Cloudflare provider
    auth. The zone ID itself is NOT an input here — it's read from qnsc-infra
    bootstrap via _shared remote state (one source of truth, like kms_key_arn).
  EOT
}

# Empty-string is treated as "unset" (an unset GitHub Actions `vars.*` renders as
# ""), falling back to the saas default — so develop applies cleanly without the
# repo variables configured.
variable "deployment_mode" {
  type    = string
  default = ""
  validation {
    condition     = contains(["", "saas", "single"], var.deployment_mode)
    error_message = "deployment_mode must be 'saas' or 'single'."
  }
  description = <<-EOT
    'saas'   = one deployment serves many tenants; self-serve signup on. (default)
    'single' = packaged for one customer; exactly one tenant, signup off.
    Develop is the shared multi-tenant dev environment — normally 'saas'.
  EOT
}

variable "single_tenant_name" {
  type        = string
  default     = ""
  description = "single mode only: display name of the one tenant."
}

variable "single_tenant_slug" {
  type        = string
  default     = ""
  description = "single mode only: url-safe slug of the one tenant."
}

variable "otlp_endpoint" {
  type        = string
  default     = ""
  description = <<-EOT
    Grafana Cloud's unified OTLP endpoint (qnsc-infra/live/observability's
    otlp_endpoint output). Empty (the default) makes every otel_agent module
    below a no-op — OTEL_ENABLED stays "false" and no sidecar container is
    created, so the app is never told to export into a void.
  EOT
}
