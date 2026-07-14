#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../rhacs/lib/common.sh"
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
print_ok() { echo -e "  ${GREEN}✓${NC} $*"; }
print_fail() { echo -e "  ${RED}✗${NC} $*"; }

MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
MCP_DEPLOYMENT="${MCP_DEPLOYMENT:-stackrox-mcp}"
MCP_ROUTE_NAME="${MCP_ROUTE_NAME:-stackrox-mcp}"
MCP_HEALTH_PATH="${MCP_HEALTH_PATH:-/health}"
MCP_ROLLOUT_TIMEOUT="${MCP_ROLLOUT_TIMEOUT:-120s}"

# OpenShift Lightspeed OLSConfig (optional cluster resource — skipped when absent)
LIGHTSPEED_CHECK_OLSCONFIG="${LIGHTSPEED_CHECK_OLSCONFIG:-true}"
LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
LIGHTSPEED_OLSCONFIG_NAME="${LIGHTSPEED_OLSCONFIG_NAME:-cluster}"
LIGHTSPEED_MCP_SERVER_NAME="${LIGHTSPEED_MCP_SERVER_NAME:-stackrox-mcp}"

FAILURES=0

check_prereqs() {
    print_step "Checking prerequisites"
    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found in PATH"
        exit 1
    fi
    if ! command -v curl &>/dev/null; then
        print_error "curl not found in PATH"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_error "jq not found in PATH"
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi
    print_ok "Tools present and cluster session is active"
}

check_namespace_and_deployment() {
    print_step "Validating namespace and deployment"
    if oc get namespace "${MCP_NAMESPACE}" &>/dev/null; then
        print_ok "Namespace ${MCP_NAMESPACE} exists"
    else
        print_fail "Namespace ${MCP_NAMESPACE} not found"
        FAILURES=$((FAILURES + 1))
        return
    fi

    if oc get deployment "${MCP_DEPLOYMENT}" -n "${MCP_NAMESPACE}" &>/dev/null; then
        print_ok "Deployment ${MCP_DEPLOYMENT} exists"
    else
        print_fail "Deployment ${MCP_DEPLOYMENT} not found"
        FAILURES=$((FAILURES + 1))
        return
    fi

    if oc rollout status "deployment/${MCP_DEPLOYMENT}" -n "${MCP_NAMESPACE}" --timeout="${MCP_ROLLOUT_TIMEOUT}" &>/dev/null; then
        print_ok "Deployment rollout is complete"
    else
        print_fail "Deployment rollout did not complete within ${MCP_ROLLOUT_TIMEOUT}"
        FAILURES=$((FAILURES + 1))
    fi
}

check_route_health() {
    print_step "Validating MCP route and health endpoint"
    local route_host
    route_host="$(oc get route "${MCP_ROUTE_NAME}" -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [ -z "${route_host}" ]; then
        print_fail "Route ${MCP_ROUTE_NAME} not found or has no host"
        FAILURES=$((FAILURES + 1))
        return
    fi
    print_ok "Route host detected: ${route_host}"

    local health_url
    health_url="https://${route_host}${MCP_HEALTH_PATH}"

    local health_response
    health_response="$(curl -k -sS --max-time 15 "${health_url}" || true)"
    if [ -z "${health_response}" ]; then
        print_fail "Health endpoint returned an empty response: ${health_url}"
        FAILURES=$((FAILURES + 1))
        return
    fi

    if jq -e '.status == "ok"' >/dev/null 2>&1 <<< "${health_response}"; then
        print_ok "Health endpoint returned status=ok"
    else
        print_fail "Unexpected health response: ${health_response}"
        FAILURES=$((FAILURES + 1))
    fi
}

check_olsconfig_mcp() {
    if [ "${LIGHTSPEED_CHECK_OLSCONFIG}" != "true" ]; then
        print_warn "Skipping OLSConfig checks (LIGHTSPEED_CHECK_OLSCONFIG=${LIGHTSPEED_CHECK_OLSCONFIG})"
        return 0
    fi

    print_step "Validating OpenShift Lightspeed OLSConfig (MCP wiring)"

    local ols_json scope
    ols_json=""
    scope=""
    if oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -o json &>/dev/null; then
        ols_json="$(oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -o json)"
        scope="cluster"
    elif oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" -o json &>/dev/null; then
        ols_json="$(oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" -o json)"
        scope="namespace/${LIGHTSPEED_NAMESPACE}"
    else
        print_ok "OLSConfig not found (OpenShift Lightspeed may not be installed); skipping MCP wiring checks"
        return 0
    fi

    print_ok "OLSConfig present (${scope}: ${LIGHTSPEED_OLSCONFIG_NAME})"

    if jq -e '.spec.featureGates // [] | any(. == "MCPServer")' <<< "${ols_json}" >/dev/null 2>&1; then
        print_ok "spec.featureGates includes MCPServer"
    else
        print_fail "spec.featureGates does not include MCPServer (required for Lightspeed MCP)"
        FAILURES=$((FAILURES + 1))
    fi

    if jq -e --arg n "${LIGHTSPEED_MCP_SERVER_NAME}" '.spec.mcpServers // [] | any(.name == $n)' <<< "${ols_json}" >/dev/null 2>&1; then
        print_ok "spec.mcpServers includes \"${LIGHTSPEED_MCP_SERVER_NAME}\""
    else
        print_fail "spec.mcpServers has no entry named \"${LIGHTSPEED_MCP_SERVER_NAME}\""
        FAILURES=$((FAILURES + 1))
    fi

    local configured_url
    configured_url="$(jq -r --arg n "${LIGHTSPEED_MCP_SERVER_NAME}" \
        '.spec.mcpServers // [] | map(select(.name == $n)) | .[0] | (.streamableHTTP.url // .url // empty)' <<< "${ols_json}")"

    if [ -z "${configured_url}" ]; then
        print_fail "No MCP URL (.url / .streamableHTTP.url) for \"${LIGHTSPEED_MCP_SERVER_NAME}\""
        FAILURES=$((FAILURES + 1))
        return 0
    fi

    local expected_internal expected_route route_host
    expected_internal="http://stackrox-mcp.${MCP_NAMESPACE}:8080/mcp"
    route_host="$(oc get route "${MCP_ROUTE_NAME}" -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    expected_route=""
    if [ -n "${route_host}" ]; then
        expected_route="https://${route_host}/mcp"
    fi

    if [ "${configured_url}" = "${expected_internal}" ]; then
        print_ok "MCP URL matches in-cluster endpoint (${configured_url})"
    elif [ -n "${expected_route}" ] && [ "${configured_url}" = "${expected_route}" ]; then
        print_ok "MCP URL matches Route endpoint (${configured_url})"
    else
        print_warn "MCP URL is \"${configured_url}\" (expected ${expected_internal} or ${expected_route:-<no route>})"
    fi
}

main() {
    echo ""
    print_step "MCP server smoke test"
    echo ""

    check_prereqs
    check_namespace_and_deployment
    check_route_health
    check_olsconfig_mcp

    echo ""
    if [ "${FAILURES}" -eq 0 ]; then
        print_info "All MCP server checks passed"
        exit 0
    fi

    print_error "${FAILURES} check(s) failed"
    exit 1
}

main "$@"
