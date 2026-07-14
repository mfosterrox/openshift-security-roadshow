#!/usr/bin/env bash
# One-time RHACS demo configuration for the OpenShift Security Roadshow.
# Ports rhacs-demo basic-setup 01–08 (skip 04 app deploy), plus monitoring,
# StackRox MCP, and OpenShift Lightspeed helpers — with no rhacs-demo dependency.
#
# Quiet by default (progress bar + current step). Use --verbose for full logs.
# Independent jobs run in parallel after sequential prerequisites.
#
# Usage (cluster-admin):
#   ./setup/rhacs-configure.sh
#   ./setup/rhacs-configure.sh --skip-monitoring --skip-mcp
#
# Invoked by setup/lab-environment.sh and setup/cluster-prerequisites.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/rhacs/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/rhacs/lib/progress.sh"

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

SKIP_UPGRADE=false
SKIP_COMPLIANCE=false
SKIP_411=false
SKIP_MONITORING=false
SKIP_MCP=false
SKIP_LIGHTSPEED=false
REQUIRE_LIGHTSPEED=false
VERBOSE=false

usage() {
  cat <<'EOF'
Usage: rhacs-configure.sh [options]

Phases:
  1) Sequential: API token, RHACS verify/upgrade
  2) Parallel:   collector networks + Compliance Operator install
  3) Parallel:   settings, scans, 4.11, monitoring, MCP (+ demo-apps check)
  4) Sequential: Lightspeed helpers (after MCP)

Options:
  --skip-upgrade       Skip RHACS operator channel upgrade in 01
  --skip-compliance    Skip Compliance Operator install + scan schedule/trigger (03,06,07)
  --skip-411           Skip 4.11 TP flags / Attach-to-Pod policy (08)
  --skip-monitoring    Skip setup/monitoring
  --skip-mcp           Skip setup/mcp-server
  --skip-lightspeed    Skip setup/lightspeed LLM helpers
  --require-lightspeed Fail if OpenShift Lightspeed OLSConfig is missing (MCP path)
  --verbose            Stream full child-script output for sequential steps
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
    --verbose|-v) VERBOSE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

PROGRESS_VERBOSE="${VERBOSE}"

require_cmd oc jq curl || exit 1
require_oc || exit 1

RHACS_DIR="${SCRIPT_DIR}/rhacs"

# Count progress units (each parallel job counts as one unit)
TOTAL=1 # resolve token
[[ "${SKIP_UPGRADE}" != true ]] && TOTAL=$((TOTAL + 1))
# phase 2 parallel units
PHASE2=1 # collector always
[[ "${SKIP_COMPLIANCE}" != true ]] && PHASE2=$((PHASE2 + 1))
TOTAL=$((TOTAL + PHASE2))
# phase 3 parallel units
PHASE3=1 # demo apps check always
PHASE3=$((PHASE3 + 1)) # settings always
[[ "${SKIP_COMPLIANCE}" != true ]] && PHASE3=$((PHASE3 + 2)) # 06 + 07
[[ "${SKIP_411}" != true ]] && PHASE3=$((PHASE3 + 1))
[[ "${SKIP_MONITORING}" != true ]] && PHASE3=$((PHASE3 + 1))
[[ "${SKIP_MCP}" != true ]] && PHASE3=$((PHASE3 + 1))
TOTAL=$((TOTAL + PHASE3))
[[ "${SKIP_LIGHTSPEED}" != true ]] && TOTAL=$((TOTAL + 1))

LOG_DIR="${HOME}/.acs-roadshow"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/rhacs-configure-$(date +%Y%m%d-%H%M%S).log"
progress_init "${TOTAL}" "${LOG_FILE}" "RHACS configure"

resolve_token_step() {
  resolve_rox_central_address || return 1
  ensure_rox_api_token || return 1
  export ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE
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
  export ROX_CENTRAL_ADDRESS="${HOST_ONLY}"
  echo "ROX_CENTRAL_ADDRESS=${HOST_ONLY}"
  echo "ROX_API_TOKEN set (${#ROX_API_TOKEN} chars)"
}

# ---- Phase 1: sequential prerequisites ----
progress_run "Resolve RHACS API access" resolve_token_step

if [[ "${SKIP_UPGRADE}" != true ]]; then
  progress_run "Verify and align RHACS install" \
    bash "${RHACS_DIR}/01-verify-rhacs-install.sh"
fi

# ---- Phase 2: collector + Compliance Operator in parallel ----
phase2_args=()
phase2_args+=("Collector networks" "bash '${RHACS_DIR}/02-configure-collector-networks.sh'")
if [[ "${SKIP_COMPLIANCE}" != true ]]; then
  phase2_args+=("Compliance Operator" "bash '${RHACS_DIR}/03-compliance-operator-install.sh'")
fi
progress_run_parallel "${phase2_args[@]}"

# ---- Phase 3: independent config jobs in parallel ----
phase3_args=()
phase3_args+=("Demo apps check" "oc get deployments -l demo=roadshow -A 2>/dev/null || echo 'No demo=roadshow deployments yet'")
phase3_args+=("RHACS settings" "bash '${RHACS_DIR}/05-configure-rhacs-settings.sh'")
if [[ "${SKIP_COMPLIANCE}" != true ]]; then
  phase3_args+=("Compliance schedule" "bash '${RHACS_DIR}/06-setup-co-scan-schedule.sh'")
  phase3_args+=("Compliance scans" "bash '${RHACS_DIR}/07-trigger-compliance-scan.sh'")
fi
if [[ "${SKIP_411}" != true ]]; then
  phase3_args+=("RHACS 4.11 features" "bash '${RHACS_DIR}/08-configure-rhacs-411-features.sh'")
fi
if [[ "${SKIP_MONITORING}" != true ]]; then
  phase3_args+=("Monitoring stack" "bash '${SCRIPT_DIR}/monitoring/install.sh'")
fi
if [[ "${SKIP_MCP}" != true ]]; then
  if [[ "${REQUIRE_LIGHTSPEED}" == true ]]; then
    export LIGHTSPEED_VALIDATE=true
  fi
  phase3_args+=("StackRox MCP" "bash '${SCRIPT_DIR}/mcp-server/install.sh'")
fi
progress_run_parallel "${phase3_args[@]}"

# ---- Phase 4: Lightspeed after MCP ----
if [[ "${SKIP_LIGHTSPEED}" != true ]]; then
  progress_run "Configure Lightspeed helpers" \
    bash "${SCRIPT_DIR}/lightspeed/configure-claude-default.sh"
fi

HOST_ONLY="$(rox_central_host)"
progress_done "RHACS configure complete"

progress_success_banner "RHACS configure completed successfully" \
  "Central API access configured" \
  "Compliance, monitoring, MCP, and Lightspeed helpers applied (per selected options)" \
  "Detailed log: ${LOG_FILE}"

cat <<EOF
  ROX_CENTRAL_ADDRESS=${HOST_ONLY}
  ROX_API_TOKEN=<in ~/.bashrc>
EOF
