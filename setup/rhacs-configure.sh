#!/usr/bin/env bash
# One-time RHACS demo configuration for the OpenShift Security Roadshow.
# Ports rhacs-demo basic-setup 01–08 (skip 04 app deploy), plus monitoring,
# StackRox MCP, and OpenShift Lightspeed helpers — with no rhacs-demo dependency.
#
# Usage (cluster-admin):
#   ./setup/rhacs-configure.sh
#   ./setup/rhacs-configure.sh --skip-monitoring --skip-mcp
#
# Invoked automatically at the end of setup/cluster-prerequisites.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/rhacs/lib/common.sh"

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

SKIP_UPGRADE=false
SKIP_COMPLIANCE=false
SKIP_411=false
SKIP_MONITORING=false
SKIP_MCP=false
SKIP_LIGHTSPEED=false
REQUIRE_LIGHTSPEED=false

usage() {
  cat <<'EOF'
Usage: rhacs-configure.sh [options]

Options:
  --skip-upgrade       Skip RHACS operator channel upgrade in 01
  --skip-compliance    Skip Compliance Operator install + scan schedule/trigger (03,06,07)
  --skip-411           Skip 4.11 TP flags / Attach-to-Pod policy (08)
  --skip-monitoring    Skip setup/monitoring
  --skip-mcp           Skip setup/mcp-server
  --skip-lightspeed    Skip setup/lightspeed LLM helpers
  --require-lightspeed Fail if OpenShift Lightspeed OLSConfig is missing (MCP path)
  -h, --help           Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-upgrade) SKIP_UPGRADE=true; shift ;;
    --skip-compliance) SKIP_COMPLIANCE=true; shift ;;
    --skip-411) SKIP_411=true; shift ;;
    --skip-monitoring) SKIP_MONITORING=true; shift ;;
    --skip-mcp) SKIP_MCP=true; shift ;;
    --skip-lightspeed) SKIP_LIGHTSPEED=true; shift ;;
    --require-lightspeed) REQUIRE_LIGHTSPEED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

run_step() {
  local label="$1"
  shift
  print_step "${label}"
  echo "------------------------------------------------------------------------"
  "$@"
}

require_cmd oc jq curl || exit 1
require_oc || exit 1

print_step "Resolving RHACS Central + API token"
resolve_rox_central_address || exit 1
ensure_rox_api_token || exit 1
export ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE
# Persist host-only for bastion/lab compatibility
HOST_ONLY="$(rox_central_host)"
if [[ -f "${HOME}/.bashrc" ]]; then
  for name in ROX_CENTRAL_ADDRESS ROX_API_TOKEN; do
    if grep -qE "^(export[[:space:]]+)?${name}=" "${HOME}/.bashrc" 2>/dev/null; then
      sed -i.bak "/^export ${name}=/d;/^${name}=/d" "${HOME}/.bashrc" 2>/dev/null || \
        sed -i '' "/^export ${name}=/d;/^${name}=/d" "${HOME}/.bashrc" 2>/dev/null || true
    fi
  done
  {
    printf 'export ROX_CENTRAL_ADDRESS=%q\n' "${HOST_ONLY}"
    printf 'export ROX_API_TOKEN=%q\n' "${ROX_API_TOKEN}"
  } >> "${HOME}/.bashrc"
fi
print_info "ROX_CENTRAL_ADDRESS=${HOST_ONLY} (host-only in ~/.bashrc)"
print_info "ROX_API_TOKEN set (${#ROX_API_TOKEN} chars)"

# Child scripts that call get_central_url tolerate host-only; monitoring normalize to https://
export ROX_CENTRAL_ADDRESS="${HOST_ONLY}"

RHACS_DIR="${SCRIPT_DIR}/rhacs"

if [[ "${SKIP_UPGRADE}" == true ]]; then
  print_warn "Skipping RHACS verify/upgrade (01) — --skip-upgrade"
else
  run_step "01 Verify / align RHACS install" bash "${RHACS_DIR}/01-verify-rhacs-install.sh"
fi

run_step "02 Configure collector non-aggregated networks" \
  bash "${RHACS_DIR}/02-configure-collector-networks.sh"

if [[ "${SKIP_COMPLIANCE}" == true ]]; then
  print_warn "Skipping Compliance Operator + scans (03/06/07)"
else
  run_step "03 Install Compliance Operator" \
    bash "${RHACS_DIR}/03-compliance-operator-install.sh"
fi

# 04: demo apps are owned by lab-environment.sh (demo-apps), not demo-applications
print_step "04 Demo applications (verify only)"
echo "------------------------------------------------------------------------"
if oc get deployments -l demo=roadshow -A --no-headers 2>/dev/null | grep -q .; then
  print_info "✓ Found deployments with label demo=roadshow"
  oc get deployments -l demo=roadshow -A
else
  print_warn "No demo=roadshow deployments yet. Attendees deploy via setup/lab-environment.sh."
fi

run_step "05 Configure RHACS settings + base images" \
  bash "${RHACS_DIR}/05-configure-rhacs-settings.sh"

if [[ "${SKIP_COMPLIANCE}" != true ]]; then
  run_step "06 Compliance Operator scan schedule" \
    bash "${RHACS_DIR}/06-setup-co-scan-schedule.sh"
  run_step "07 Trigger classic compliance scans" \
    bash "${RHACS_DIR}/07-trigger-compliance-scan.sh"
fi

if [[ "${SKIP_411}" == true ]]; then
  print_warn "Skipping 4.11 features (08)"
else
  run_step "08 Configure RHACS 4.11 features" \
    bash "${RHACS_DIR}/08-configure-rhacs-411-features.sh"
fi

if [[ "${SKIP_MONITORING}" == true ]]; then
  print_warn "Skipping monitoring setup"
else
  run_step "Monitoring (certs + COO + RHACS auth)" \
    bash "${SCRIPT_DIR}/monitoring/install.sh"
fi

if [[ "${SKIP_MCP}" == true ]]; then
  print_warn "Skipping MCP server setup"
else
  if [[ "${REQUIRE_LIGHTSPEED}" == true ]]; then
    export LIGHTSPEED_VALIDATE=true
  fi
  run_step "StackRox MCP server (+ Lightspeed OLSConfig MCP wiring)" \
    bash "${SCRIPT_DIR}/mcp-server/install.sh"
fi

if [[ "${SKIP_LIGHTSPEED}" == true ]]; then
  print_warn "Skipping Lightspeed LLM helpers"
else
  run_step "Lightspeed LLM helpers (non-interactive; skip if no credentials)" \
    bash "${SCRIPT_DIR}/lightspeed/configure-claude-default.sh"
fi

print_step "RHACS configure complete"
cat <<EOF

Demo-ready RHACS configuration applied.

  ROX_CENTRAL_ADDRESS=${HOST_ONLY}
  ROX_API_TOKEN=<in ~/.bashrc>

Attendee bastion next:
  bash setup/lab-environment.sh --quay-user USER --quay-password 'secret'

Optional Lightspeed LLM (if not already set):
  export LIGHTSPEED_DEFAULT_PROVIDER=... LIGHTSPEED_DEFAULT_MODEL=...
  # or LIGHTSPEED_BACKEND=bam LIGHTSPEED_BAM_URL=... ANTHROPIC_API_KEY=...
  bash setup/lightspeed/configure-claude-default.sh

EOF
