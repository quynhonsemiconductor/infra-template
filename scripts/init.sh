#!/usr/bin/env bash
# Initialize a new product infra repo from this template.
# Replaces the __PRODUCT__ placeholder with the real product name everywhere.
#
# Usage:  ./scripts/init.sh <product-name>
#   e.g.  ./scripts/init.sh fleet
set -euo pipefail

PRODUCT="${1:-}"
if [[ -z "$PRODUCT" ]]; then
  echo "Usage: $0 <product-name>   (lowercase, e.g. 'fleet')" >&2
  exit 1
fi
if [[ ! "$PRODUCT" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "Product name must be lowercase letters/digits/hyphens, starting with a letter." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── No VPC reservation (Option A) ────────────────────────────────────────────
# Products no longer reserve a VPC /16 — AWS full-stack consumes the shared
# runtime VPC from qnsc-infra (platform/runtime-dev + runtime-prod) via remote
# state; Cloudflare-native has no VPC. NET is accepted for back-compat but ignored.
NET="${NET:-}"
if [[ -n "$NET" ]]; then
  echo "note: NET is obsolete under Option A — products consume the shared runtime" >&2
  echo "      VPC from qnsc-infra; ignoring NET." >&2
fi

# Replace placeholders in every tracked text file (skip .git and this script).
grep -rlE '__PRODUCT__' "$ROOT" \
  --exclude-dir=.git \
  --exclude="init.sh" \
  | while read -r f; do
      sed -i.bak -e "s/__PRODUCT__/${PRODUCT}/g" "$f" && rm -f "$f.bak"
      echo "  updated $f"
    done

echo
echo "✓ Initialized infra for product '${PRODUCT}'."
echo
echo "Pick ONE archetype and delete the other:"
echo "  • AWS full-stack     → keep live/ (shared runtime; per-product RDS + Fargate); delete cloudflare-native/"
echo "  • Cloudflare-native  → keep cloudflare-native/ (Pages + Functions); delete live/"
echo
echo "Next steps (AWS full-stack):"
echo "  1. Prereq: shared runtime stacks must exist in qnsc-infra (platform/runtime-dev, platform/runtime-prod)."
echo "  2. Review live/_shared/main.tf — adjust ECR repo names, drop the web block if no SPA."
echo "  3. Fill live/develop and live/prod with the modules this product needs."
echo "  4. Set GitHub secrets: AWS_ACCOUNT_ID, etc. (see README)."
echo "  5. Create the '${PRODUCT}-github-infra-apply' IAM role (see README)."
echo "  6. Instrumentation standard (product-docs platform/adr/INSTRUMENTATION-STANDARD.md): your own code uses the"
echo "     OpenTelemetry SDK (platform-runtime / @quynhonsemiconductor/observability, OTLP to the platform Alloy)."
echo "     eBPF (OBI) is only for third-party/uninstrumented services, added in the gitops discovery list, never"
echo "     as a substitute for the SDK. Infrastructure components keep their exporters."
echo "  7. Delete scripts/ once done."
