#!/bin/bash

# Script: 07-trigger-compliance-scan.sh
# Description: Trigger an on-demand RHACS Compliance Coverage (v2) scan for the
#              acs-catch-all schedule created by 06-setup-co-scan-schedule.sh.
#
# RHACS 4.11 removed Compliance V1 (classic dashboard and /v1/compliance/standards).
# This script must not fail cluster setup if the scan cannot be started yet —
# attendees can still click Run scan under Compliance → Schedules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
readonly SCAN_NAME="${SCAN_NAME:-acs-catch-all}"

http_status_code() {
    local code="${1:-0}"
    code="$(printf '%s' "${code}" | tr -cd '0-9')"
    printf '%s' "$((10#${code:-0}))"
}

curl_json() {
    local method=$1
    local url=$2
    local data="${3:-}"
    local response
    if [ -n "${data}" ]; then
        response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
            -X "${method}" \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "${url}" 2>/dev/null || echo "")
    else
        response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
            -X "${method}" \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            "${url}" 2>/dev/null || echo "")
    fi
    local http_code body
    http_code=$(http_status_code "$(echo "${response}" | tail -n1)")
    body=$(echo "${response}" | sed '$d')
    printf '%s\n' "${http_code}"
    printf '%s' "${body}"
}

get_scan_config_id() {
    local api_base=$1
    local scan_name=$2
    local http_code body
    local raw
    raw=$(curl_json "GET" "${api_base}/v2/compliance/scan/configurations")
    http_code=$(printf '%s\n' "${raw}" | head -n1)
    body=$(printf '%s\n' "${raw}" | tail -n +2)
    if [ "${http_code}" != "200" ]; then
        print_warn "List scan configurations returned HTTP ${http_code}" >&2
        return 1
    fi
    local scan_id
    scan_id=$(echo "${body}" | jq -r --arg n "${scan_name}" \
        '.configurations[]? | select(.scanName == $n) | .id' 2>/dev/null | head -1)
    if [ -z "${scan_id}" ] || [ "${scan_id}" = "null" ]; then
        return 1
    fi
    printf '%s' "${scan_id}"
}

wait_for_scan_config() {
    local api_base=$1
    local scan_name=$2
    local max_wait=180
    local interval=10
    local elapsed=0
    local scan_id=""

    print_step "Waiting for scan configuration '${scan_name}'..." >&2
    while [ ${elapsed} -lt ${max_wait} ]; do
        scan_id=$(get_scan_config_id "${api_base}" "${scan_name}" 2>/dev/null || true)
        if [ -n "${scan_id}" ]; then
            print_info "✓ Found scan configuration ${scan_name} (ID: ${scan_id})" >&2
            printf '%s' "${scan_id}"
            return 0
        fi
        if [ $((elapsed % 30)) -eq 0 ]; then
            print_info "Scan configuration not ready yet... (${elapsed}s/${max_wait}s)" >&2
        fi
        sleep ${interval}
        elapsed=$((elapsed + interval))
    done
    return 1
}

run_scan_config() {
    local api_base=$1
    local scan_id=$2
    local http_code body raw
    print_step "Triggering Coverage scan (POST /v2/compliance/scan/configurations/${scan_id}/run)..."
    raw=$(curl_json "POST" "${api_base}/v2/compliance/scan/configurations/${scan_id}/run")
    http_code=$(printf '%s\n' "${raw}" | head -n1)
    body=$(printf '%s\n' "${raw}" | tail -n +2)
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "202" ]; then
        print_info "✓ Coverage scan triggered (HTTP ${http_code})"
        return 0
    fi
    print_warn "Could not trigger Coverage scan (HTTP ${http_code})"
    if [ -n "${body}" ]; then
        print_warn "  ${body:0:200}"
    fi
    return 1
}

# Best-effort leftover for RHACS < 4.11. Never fail setup if V1 is gone.
try_classic_v1_scans() {
    local api_base=$1
    local http_code body raw
    print_step "Checking whether classic Compliance V1 APIs are still present..."
    raw=$(curl_json "GET" "${api_base}/v1/compliance/standards")
    http_code=$(printf '%s\n' "${raw}" | head -n1)
    body=$(printf '%s\n' "${raw}" | tail -n +2)
    if [ "${http_code}" != "200" ] || [ -z "${body}" ]; then
        print_info "Classic Compliance V1 is not available (HTTP ${http_code}; removed in RHACS 4.11). Skipping."
        return 0
    fi
    print_info "V1 standards endpoint responded; skipping extra classic runs (Coverage v2 is the roadshow path)"
    return 0
}

main() {
    set +e
    print_info "=========================================="
    print_info "Compliance Coverage Scan Trigger"
    print_info "=========================================="
    print_info ""

    if ! oc whoami &>/dev/null; then
        print_warn "Not connected to OpenShift cluster; skipping scan trigger"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        print_warn "jq not found; skipping scan trigger"
        return 0
    fi

    local central_url
    central_url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -z "${central_url}" ]; then
        print_warn "Could not determine Central URL; skipping scan trigger"
        return 0
    fi
    print_info "Central URL: ${central_url}"

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_warn "ROX_API_TOKEN is not set; skipping scan trigger"
        return 0
    fi
    print_info "✓ Using API token from environment"

    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local api_base="https://${api_host}"

    print_info ""

    local scan_id=""
    scan_id=$(wait_for_scan_config "${api_base}" "${SCAN_NAME}" || true)
    if [ -z "${scan_id}" ]; then
        print_warn "Scan configuration '${SCAN_NAME}' was not found. Run 06-setup-co-scan-schedule.sh first, or create a schedule in RHACS → Compliance → Schedules."
        try_classic_v1_scans "${api_base}" || true
        print_info "Setup will continue; attendees can start a scan from the UI."
        return 0
    fi

    run_scan_config "${api_base}" "${scan_id}" || true

    print_info ""
    print_info "=========================================="
    print_info "Compliance Coverage Scan Trigger Complete"
    print_info "=========================================="
    print_info ""
    print_info "Scans may take several minutes. Monitor: RHACS UI → Compliance → Coverage"
    print_info ""
}

main "$@"
exit 0
