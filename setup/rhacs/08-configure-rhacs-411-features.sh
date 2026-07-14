#!/bin/bash
# RHACS 4.11 demo configuration — Technology Preview flags and attach policy verification.
#
# Requires: ROX_API_TOKEN, oc logged in, jq
# Optional: SKIP_RHACS_411_TP_FLAGS=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS:-}"
ATTACH_POLICY_NAME="${ATTACH_POLICY_NAME:-Kubernetes Actions: Attach to Pod}"

get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS}" ]; then
        # Roadshow uses host-only; ensure https:// for curl/API
        if [[ "${ROX_CENTRAL_ADDRESS}" == https://* || "${ROX_CENTRAL_ADDRESS}" == http://* ]]; then
            echo "${ROX_CENTRAL_ADDRESS}"
        else
            echo "https://${ROX_CENTRAL_ADDRESS}"
        fi
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || return 1
}

# Set Central env vars for 4.11 TP features via deployment patch (idempotent).
configure_central_tp_flags() {
    if [ "${SKIP_RHACS_411_TP_FLAGS:-0}" = "1" ]; then
        print_info "Skipping TP feature flags (SKIP_RHACS_411_TP_FLAGS=1)"
        return 0
    fi

    print_step "Enabling RHACS 4.11 Technology Preview flags on Central..."

    if ! oc get deployment central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_warn "Central deployment not found; skipping TP flags"
        return 0
    fi

    local flags=("ROX_INIT_CONTAINER_SUPPORT=true" "ROX_POLICY_FILTERS_UI=enabled")
    local flag
    for flag in "${flags[@]}"; do
        local name="${flag%%=*}"
        local value="${flag#*=}"
        local current
        current=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o json 2>/dev/null | \
            jq -r --arg n "${name}" '.spec.template.spec.containers[0].env[]? | select(.name == $n) | .value' 2>/dev/null | head -1 || echo "")
        if [ "${current}" = "${value}" ]; then
            print_info "✓ Central env ${name}=${value} already set"
            continue
        fi
        if oc set env "deployment/central" -n "${RHACS_NAMESPACE}" "${name}=${value}" &>/dev/null; then
            print_info "✓ Set Central env ${name}=${value}"
        else
            print_warn "Could not set Central env ${name}; operator may reconcile — verify in RHACS UI"
        fi
    done

    oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=300s 2>/dev/null || \
        print_warn "Central rollout may still be in progress after TP flag update"
    return 0
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local token="$3"
    local api_base="$4"
    local data="${5:-}"

    local response http_code body
    if [ -n "${data}" ]; then
        response=$(curl -k -s -w "\n%{http_code}" -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "${api_base}/${endpoint}" 2>/dev/null || echo "")
    else
        response=$(curl -k -s -w "\n%{http_code}" -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            "${api_base}/${endpoint}" 2>/dev/null || echo "")
    fi
    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')
    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_warn "API ${method} ${endpoint} returned HTTP ${http_code}"
        echo "${body}" >&2
        return 1
    fi
    echo "${body}"
    return 0
}

ensure_attach_policy() {
    local token="$1"
    local api_base="$2"
    local enforce="${RHACS_ATTACH_POLICY_ENFORCE:-alert}"

    print_step "Verifying Attach to Pod policy (4.11)..."

    local policies policy_id policy_json
    policies=$(api_call "GET" "policies" "${token}" "${api_base}" "") || return 0

    policy_id=$(echo "${policies}" | jq -r --arg n "${ATTACH_POLICY_NAME}" '.policies[]? | select(.name == $n) | .id' 2>/dev/null | head -1)
    if [ -z "${policy_id}" ] || [ "${policy_id}" = "null" ]; then
        print_warn "Default policy '${ATTACH_POLICY_NAME}' not found; may appear after Central upgrade"
        return 0
    fi

    policy_json=$(echo "${policies}" | jq --arg id "${policy_id}" '.policies[] | select(.id == $id)' 2>/dev/null)
    if [ -z "${policy_json}" ]; then
        return 0
    fi

    if [ "${enforce}" = "enforce" ]; then
        policy_json=$(echo "${policy_json}" | jq '.disabled = false | .enforcementActions = ["UNSATISFIABLE"]' 2>/dev/null)
        if api_call "PUT" "policies/${policy_id}" "${token}" "${api_base}" "${policy_json}" >/dev/null 2>&1; then
            print_info "✓ Attach policy enabled with enforcement"
        else
            print_warn "Could not update Attach policy enforcement"
        fi
    else
        local disabled
        disabled=$(echo "${policy_json}" | jq -r '.disabled' 2>/dev/null)
        if [ "${disabled}" = "true" ]; then
            policy_json=$(echo "${policy_json}" | jq '.disabled = false' 2>/dev/null)
            api_call "PUT" "policies/${policy_id}" "${token}" "${api_base}" "${policy_json}" >/dev/null 2>&1 || true
        fi
        print_info "✓ Attach policy '${ATTACH_POLICY_NAME}' present (alert mode)"
    fi
    return 0
}

main() {
    print_info "=========================================="
    print_info "RHACS 4.11 Feature Configuration"
    print_info "=========================================="
    print_info ""

    if ! command -v jq &>/dev/null; then
        print_error "jq is required"
        exit 1
    fi

    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN is required"
        exit 1
    fi

    local central_url api_host api_base
    central_url=$(get_central_url) || {
        print_error "Could not determine Central URL"
        exit 1
    }
    api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    api_base="https://${api_host}/v1"

    configure_central_tp_flags

    print_info ""
    ensure_attach_policy "${token}" "${api_base}"

    print_info ""
    print_info "=========================================="
    print_info "RHACS 4.11 Feature Configuration Complete"
    print_info "=========================================="
    print_info "  - TP flags: ROX_INIT_CONTAINER_SUPPORT, ROX_POLICY_FILTERS_UI"
    print_info "  - Attach to Pod policy verified"
    print_info ""
    print_info "Configure label-scoped policies and scheduled vulnerability reports in the RHACS UI if needed."
    print_info ""
}

main "$@"
