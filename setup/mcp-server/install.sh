#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../rhacs/lib/common.sh"
# StackRox MCP Server Deployment for RHACS
# Deploys using Kubernetes manifests from https://github.com/stackrox/stackrox-mcp
# Commit: 779f4a0c1af4c4bfbe340a918f8f3c658e153538

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
LIGHTSPEED_OLSCONFIG_NAME="${LIGHTSPEED_OLSCONFIG_NAME:-cluster}"
LIGHTSPEED_MCP_SERVER_NAME="${LIGHTSPEED_MCP_SERVER_NAME:-stackrox-mcp}"
LIGHTSPEED_AUTH_SECRET_NAME="${LIGHTSPEED_AUTH_SECRET_NAME:-stackrox-mcp-authorization-header}"
LIGHTSPEED_VALIDATE="${LIGHTSPEED_VALIDATE:-true}"
# Merge-patch OLSConfig with MCPServer gate + StackRox MCP entry (idempotent; preserves other gates/servers).
LIGHTSPEED_PATCH_OLSCONFIG="${LIGHTSPEED_PATCH_OLSCONFIG:-true}"
# After a successful patch: restart Lightspeed so it picks up spec changes (set false to restart manually).
LIGHTSPEED_RESTART_AFTER_PATCH="${LIGHTSPEED_RESTART_AFTER_PATCH:-true}"
# MCP URL written into OLSConfig: internal (in-cluster) | route (OpenShift Route URL). Route matches typical workshop/docs examples.
LIGHTSPEED_MCP_URL_STYLE="${LIGHTSPEED_MCP_URL_STYLE:-internal}"
# Optional override for the MCP URL in OLSConfig (wins over LIGHTSPEED_MCP_URL_STYLE).
LIGHTSPEED_MCP_OLS_URL="${LIGHTSPEED_MCP_OLS_URL:-}"

declare -a OLS_CMD=()
OLS_SCOPE=""


# Default oc client timeout (0 = no timeout in oc, which can hang silently on API issues)
MCP_OC_REQUEST_TIMEOUT="${MCP_OC_REQUEST_TIMEOUT:-60s}"

# Use a timeout on every oc call so the script cannot hang forever
mcp_oc() {
    command oc --request-timeout="${MCP_OC_REQUEST_TIMEOUT}" "$@"
}

# Surface failures when running under set -e (e.g. sed/oc) — log files stay useful
# shellcheck disable=SC2154 # LINENO is dynamic when the trap runs
trap 'e=$?; print_error "mcp-server-setup: command failed (exit ${e}) at line ${LINENO}." >&2; exit "${e}"' ERR

# Namespace placeholder substitution (must be top-level; nested defs can break on older bash)
mcp_subs_namespace() {
    sed -e "s|__MCP_NAMESPACE__|${MCP_NAMESPACE}|g" "$@"
}

# Load variables from ~/.bashrc without eval'ing command substitutions (e.g. $(oc get ...))
# — those would run during install and can hang with no output when the API is slow.
export_bashrc_vars() {
    [ ! -f ~/.bashrc ] && return 0
    for var in ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE; do
        local line
        # grep exits 1 when no match; with pipefail that would kill the script under set -e
        line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1) || true
        if [ -z "$line" ]; then
            continue
        fi
        if grep -qE '\$\(|`' <<< "${line}"; then
            print_warn "Skipping ${var} from ~/.bashrc (contains command substitution — export ${var} in your shell first, or use a static URL/token)."
            continue
        fi
        [[ "${line}" =~ ^export[[:space:]]+ ]] || line="export ${line}"
        eval "${line}" 2>/dev/null || true
    done
}

# Convert ROX_CENTRAL_ADDRESS (https://host) to host:port for MCP config
get_central_host_port() {
    local url="${ROX_CENTRAL_ADDRESS:-}"
    url="${url#https://}"
    url="${url#http://}"
    if [[ ! "$url" =~ :[0-9]+$ ]]; then
        url="${url}:443"
    fi
    echo "$url"
}

# Use internal K8s service URL when possible (same cluster)
get_central_url_for_mcp() {
    if mcp_oc get svc central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        echo "central.${RHACS_NAMESPACE}.svc.cluster.local:443"
    else
        get_central_host_port
    fi
}

ensure_lightspeed_auth_secret() {
    # Only required for static auth mode. In passthrough mode, users may rely on user token forwarding.
    [ "${USE_STATIC_AUTH}" = true ] || return 0

    if ! mcp_oc get namespace "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_warn "Lightspeed namespace ${LIGHTSPEED_NAMESPACE} not found; skipping auth secret creation."
        return 0
    fi

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_warn "ROX_API_TOKEN is empty; cannot create Lightspeed auth secret."
        return 0
    fi

    print_info "Ensuring Lightspeed auth header secret exists (${LIGHTSPEED_AUTH_SECRET_NAME})..."
    if mcp_oc get secret "${LIGHTSPEED_AUTH_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        mcp_oc patch secret "${LIGHTSPEED_AUTH_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" --type=merge \
            -p "{\"stringData\":{\"header\":\"Bearer ${ROX_API_TOKEN}\"}}" >/dev/null
    else
        mcp_oc create secret generic "${LIGHTSPEED_AUTH_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" \
            --from-literal=header="Bearer ${ROX_API_TOKEN}" >/dev/null
    fi

    local header_b64
    header_b64=$(mcp_oc get secret "${LIGHTSPEED_AUTH_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.data.header}' 2>/dev/null || true)
    if [ -z "${header_b64}" ]; then
        print_warn "Secret ${LIGHTSPEED_AUTH_SECRET_NAME} was applied but key 'header' is empty/missing."
        return 0
    fi
    print_info "✓ Lightspeed auth secret is present: ${LIGHTSPEED_NAMESPACE}/${LIGHTSPEED_AUTH_SECRET_NAME}"
}

# Sets global OLS_CMD (array) and OLS_SCOPE when OLSConfig exists; returns non-zero if not found / unreadable.
resolve_ols_cmd() {
    OLS_CMD=(mcp_oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}")
    if ! "${OLS_CMD[@]}" >/dev/null 2>&1; then
        OLS_CMD=(mcp_oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}")
        if ! "${OLS_CMD[@]}" >/dev/null 2>&1; then
            return 1
        fi
        OLS_SCOPE="namespaced"
    else
        OLS_SCOPE="cluster"
    fi
    return 0
}

patch_lightspeed_olsconfig() {
    [ "${LIGHTSPEED_PATCH_OLSCONFIG}" = "true" ] || return 0

    if ! command -v python3 >/dev/null 2>&1; then
        print_warn "python3 not found; skipping OLSConfig auto-patch (install python3 or patch olsconfig manually)."
        return 0
    fi

    print_step "OpenShift Lightspeed: updating OLSConfig for MCP (if needed)..."

    local route_host
    route_host=$(mcp_oc get route stackrox-mcp -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    local internal_url route_url mcp_url_for_ols
    internal_url="http://stackrox-mcp.${MCP_NAMESPACE}:8080/mcp"
    route_url=""
    if [ -n "${route_host}" ]; then
        route_url="https://${route_host}/mcp"
    fi

    if [ -n "${LIGHTSPEED_MCP_OLS_URL}" ]; then
        mcp_url_for_ols="${LIGHTSPEED_MCP_OLS_URL}"
    elif [ "${LIGHTSPEED_MCP_URL_STYLE}" = "route" ] && [ -n "${route_url}" ]; then
        mcp_url_for_ols="${route_url}"
    else
        mcp_url_for_ols="${internal_url}"
        if [ "${LIGHTSPEED_MCP_URL_STYLE}" = "route" ] && [ -z "${route_url}" ]; then
            print_warn "LIGHTSPEED_MCP_URL_STYLE=route but no Route host yet; using internal URL ${internal_url}"
        fi
    fi

    if ! resolve_ols_cmd; then
        print_warn "OLSConfig '${LIGHTSPEED_OLSCONFIG_NAME}' not readable; skipping auto-patch."
        print_warn "When Lightspeed is installed, enable MCP with: oc get olsconfig ${LIGHTSPEED_OLSCONFIG_NAME}"
        return 0
    fi
    print_info "Detected OLSConfig scope: ${OLS_SCOPE}"

    local tmpjson patched
    tmpjson=$(mktemp) || return 0
    patched=$(mktemp) || {
        rm -f "${tmpjson}"
        return 0
    }
    if ! "${OLS_CMD[@]}" -o json > "${tmpjson}" 2>/dev/null; then
        print_warn "Could not export OLSConfig JSON; skipping auto-patch."
        rm -f "${tmpjson}" "${patched}"
        return 0
    fi

    export _OLS_PATCH_JSON_IN="${tmpjson}"
    export _OLS_PATCH_JSON_OUT="${patched}"
    export _OLS_MCP_URL="${mcp_url_for_ols}"
    export _OLS_USE_STATIC="${USE_STATIC_AUTH}"
    export _OLS_AUTH_SECRET="${LIGHTSPEED_AUTH_SECRET_NAME}"
    export _OLS_MCP_NAME="${LIGHTSPEED_MCP_SERVER_NAME}"

    local change_hint py_stat
    set +e
    change_hint=$(python3 - <<'PY'
import copy, json, os, sys

inp_path = os.environ["_OLS_PATCH_JSON_IN"]
out_path = os.environ["_OLS_PATCH_JSON_OUT"]
mcp_url = os.environ["_OLS_MCP_URL"]
use_static = os.environ.get("_OLS_USE_STATIC") == "true"
auth_secret = os.environ["_OLS_AUTH_SECRET"]
mcp_name = os.environ["_OLS_MCP_NAME"]

try:
    with open(inp_path, encoding="utf-8") as f:
        doc = json.load(f)
except Exception as e:
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)

orig = copy.deepcopy(doc)
spec = doc.setdefault("spec", {})

orig_fg = list((orig.get("spec") or {}).get("featureGates") or [])
orig_srv = copy.deepcopy((orig.get("spec") or {}).get("mcpServers") or [])

fg = list(spec.get("featureGates") or [])
if "MCPServer" not in fg:
    fg.append("MCPServer")
spec["featureGates"] = fg

servers_in = list(spec.get("mcpServers") or [])
entry = {
    "name": mcp_name,
    "url": mcp_url,
    "timeout": 60,
}
if use_static:
    entry["headers"] = [
        {
            "name": "Authorization",
            "valueFrom": {
                "type": "secret",
                "secretRef": {"name": auth_secret},
            },
        }
    ]

servers_out = []
replaced = False
for s in servers_in:
    if isinstance(s, dict) and s.get("name") == mcp_name:
        merged = {**s, **entry}
        servers_out.append(merged)
        replaced = True
    else:
        servers_out.append(s)
if not replaced:
    servers_out.append(entry)
spec["mcpServers"] = servers_out

changed = orig_fg != fg or json.dumps(orig_srv, sort_keys=True) != json.dumps(servers_out, sort_keys=True)

fragment = {"spec": {"featureGates": spec["featureGates"], "mcpServers": spec["mcpServers"]}}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(fragment, f)

print("changed" if changed else "unchanged")
PY
)
    py_stat=$?
    set -euo pipefail

    if [ "${py_stat}" -ne 0 ] || [ -z "${change_hint}" ]; then
        print_warn "OLSConfig merge helper failed; skipping auto-patch."
        rm -f "${tmpjson}" "${patched}"
        return 0
    fi

    change_hint=$(printf '%s\n' "${change_hint}" | tail -n1)

    if [ "${change_hint}" = "changed" ]; then
        print_info "Applying OLSConfig merge patch (MCPServer gate + MCP server '${LIGHTSPEED_MCP_SERVER_NAME}' → ${mcp_url_for_ols})..."
        local patch_rc=0
        if [ "${OLS_SCOPE}" = "cluster" ]; then
            mcp_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" --type=merge -p "$(cat "${patched}")" || patch_rc=$?
        else
            mcp_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" --type=merge -p "$(cat "${patched}")" || patch_rc=$?
        fi
        if [ "${patch_rc}" -ne 0 ]; then
            print_warn "oc patch olsconfig failed (exit ${patch_rc}); apply the merge patch manually."
            rm -f "${tmpjson}" "${patched}"
            return 0
        fi
        print_info "✓ OLSConfig updated"
        if [ "${LIGHTSPEED_RESTART_AFTER_PATCH}" = "true" ]; then
            if mcp_oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
                print_info "Restarting lightspeed-app-server so Lightspeed reloads OLSConfig..."
                mcp_oc rollout restart deployment/lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" >/dev/null 2>&1 || true
            fi
        fi
    else
        print_info "OLSConfig already lists MCPServer and MCP entry '${LIGHTSPEED_MCP_SERVER_NAME}'; no merge patch needed."
    fi

    rm -f "${tmpjson}" "${patched}"
}

validate_lightspeed_mcp_integration() {
    [ "${LIGHTSPEED_VALIDATE}" = "true" ] || {
        print_warn "Skipping OpenShift Lightspeed validation (LIGHTSPEED_VALIDATE=${LIGHTSPEED_VALIDATE})"
        return 0
    }

    print_step "Validating OpenShift Lightspeed MCP integration..."
    local route_host
    route_host=$(mcp_oc get route stackrox-mcp -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    local expected_internal_url expected_route_url
    expected_internal_url="http://stackrox-mcp.${MCP_NAMESPACE}:8080/mcp"
    expected_route_url=""
    if [ -n "${route_host}" ]; then
        expected_route_url="https://${route_host}/mcp"
    fi

    # OLSConfig can be cluster-scoped (common) or namespaced (future/operator-specific).
    if ! resolve_ols_cmd; then
        local can_get_cluster can_get_ns
        can_get_cluster="$(mcp_oc auth can-i get olsconfig 2>/dev/null || true)"
        can_get_ns="$(mcp_oc auth can-i get olsconfig -n "${LIGHTSPEED_NAMESPACE}" 2>/dev/null || true)"
        print_warn "Could not read OLSConfig '${LIGHTSPEED_OLSCONFIG_NAME}' (cluster-scoped or namespace ${LIGHTSPEED_NAMESPACE})."
        print_warn "RBAC check: can-i get olsconfig (cluster)='${can_get_cluster:-unknown}', (ns ${LIGHTSPEED_NAMESPACE})='${can_get_ns:-unknown}'."
        print_warn "Verify with: oc get olsconfig ${LIGHTSPEED_OLSCONFIG_NAME} || oc get olsconfig ${LIGHTSPEED_OLSCONFIG_NAME} -n ${LIGHTSPEED_NAMESPACE}"
        return 0
    fi
    print_info "Detected OLSConfig scope: ${OLS_SCOPE}"

    # OLS MCP configuration lives at top-level spec.featureGates/spec.mcpServers.
    # If these are absent, Lightspeed may be installed but MCP integration is not configured.
    local has_featuregates_key has_mcpservers_key
    has_featuregates_key=$("${OLS_CMD[@]}" -o jsonpath='{.spec.featureGates}' 2>/dev/null || true)
    has_mcpservers_key=$("${OLS_CMD[@]}" -o jsonpath='{.spec.mcpServers}' 2>/dev/null || true)
    if [ -z "${has_featuregates_key}" ] && [ -z "${has_mcpservers_key}" ]; then
        print_warn "OLSConfig exists, but MCP integration fields are not configured yet."
        print_warn "Missing: spec.featureGates and spec.mcpServers."
        print_info "Apply MCP config to OLSConfig (example):"
        echo "  oc patch olsconfig ${LIGHTSPEED_OLSCONFIG_NAME} --type merge -p '{"
        echo "    \"spec\": {"
        echo "      \"featureGates\": [\"MCPServer\"],"
        echo "      \"mcpServers\": [{"
        echo "        \"name\": \"${LIGHTSPEED_MCP_SERVER_NAME}\","
        echo "        \"url\": \"http://stackrox-mcp.${MCP_NAMESPACE}:8080/mcp\","
        echo "        \"timeout\": 60,"
        echo "        \"headers\": [{"
        echo "          \"name\": \"Authorization\","
        echo "          \"valueFrom\": {"
        echo "            \"type\": \"secret\","
        echo "            \"secretRef\": {\"name\": \"${LIGHTSPEED_AUTH_SECRET_NAME}\"}"
        echo "          }"
        echo "        }]"
        echo "      }]"
        echo "    }"
        echo "  }'"
        print_info "Then restart Lightspeed API deployment:"
        print_info "  oc rollout restart deployment/lightspeed-app-server -n ${LIGHTSPEED_NAMESPACE}"
        return 0
    fi

    # 1) OLSConfig should include MCP server feature gate.
    local feature_gates
    feature_gates=$("${OLS_CMD[@]}" -o jsonpath='{.spec.featureGates[*]}' 2>/dev/null || true)
    if [ -z "${feature_gates}" ]; then
        print_warn "OLSConfig ${LIGHTSPEED_OLSCONFIG_NAME} found, but spec.featureGates is empty."
        print_warn "If you use OpenShift Lightspeed MCP integration, set spec.featureGates to include MCPServer."
        return 0
    fi
    if [[ " ${feature_gates} " =~ [[:space:]]MCPServer[[:space:]] ]]; then
        print_info "✓ OLSConfig feature gate MCPServer is enabled"
    else
        print_error "OLSConfig found, but MCPServer feature gate is not enabled."
        print_info "Add MCPServer to spec.featureGates in olsconfig/${LIGHTSPEED_OLSCONFIG_NAME}."
        return 1
    fi

    # 2) MCP server entry should exist and use streamableHTTP / URL.
    local has_server_entry server_url streamable_url
    has_server_entry=$("${OLS_CMD[@]}" \
        -o jsonpath="{range .spec.mcpServers[*]}{.name}{'\n'}{end}" 2>/dev/null | grep -x "${LIGHTSPEED_MCP_SERVER_NAME}" || true)
    if [ -z "${has_server_entry}" ]; then
        print_error "spec.mcpServers does not contain '${LIGHTSPEED_MCP_SERVER_NAME}' in olsconfig/${LIGHTSPEED_OLSCONFIG_NAME}."
        print_info "Add mcpServers entry name='${LIGHTSPEED_MCP_SERVER_NAME}' and point it at ${expected_internal_url}."
        return 1
    fi

    server_url=$("${OLS_CMD[@]}" \
        -o jsonpath="{range .spec.mcpServers[?(@.name=='${LIGHTSPEED_MCP_SERVER_NAME}')]}{.url}{end}" 2>/dev/null || true)
    streamable_url=$("${OLS_CMD[@]}" \
        -o jsonpath="{range .spec.mcpServers[?(@.name=='${LIGHTSPEED_MCP_SERVER_NAME}')]}{.streamableHTTP.url}{end}" 2>/dev/null || true)
    local configured_url
    configured_url="${streamable_url:-$server_url}"
    if [ -z "${configured_url}" ]; then
        print_error "No MCP URL configured for '${LIGHTSPEED_MCP_SERVER_NAME}' (expected .streamableHTTP.url or .url)."
        return 1
    fi
    if [[ "${configured_url}" = "${expected_internal_url}" || ( -n "${expected_route_url}" && "${configured_url}" = "${expected_route_url}" ) ]]; then
        print_info "✓ Lightspeed MCP URL matches expected endpoint: ${configured_url}"
    else
        if [ -n "${expected_route_url}" ]; then
            print_warn "Lightspeed MCP URL is '${configured_url}' (expected '${expected_internal_url}' or '${expected_route_url}')."
        else
            print_warn "Lightspeed MCP URL is '${configured_url}' (expected '${expected_internal_url}')."
        fi
    fi

    # 3) Auth consistency: static MCP auth should have header-based auth in OLSConfig.
    local has_auth_header
    has_auth_header=""
    has_auth_header=$("${OLS_CMD[@]}" \
        -o jsonpath="{range .spec.mcpServers[?(@.name=='${LIGHTSPEED_MCP_SERVER_NAME}')]}{.streamableHTTP.headers.authorization}{end}" 2>/dev/null || true)
    if [ -z "${has_auth_header}" ]; then
        has_auth_header=$("${OLS_CMD[@]}" \
            -o jsonpath="{range .spec.mcpServers[?(@.name=='${LIGHTSPEED_MCP_SERVER_NAME}')].headers[*]}{.name}:{.valueFrom.type}:{.valueFrom.secretRef.name}{'\n'}{end}" 2>/dev/null || true)
    fi
    if [ "${USE_STATIC_AUTH}" = true ] && [ -z "${has_auth_header}" ]; then
        print_error "MCP server uses static auth but no Lightspeed MCP auth header is configured."
        print_info "Add Authorization header in OLSConfig (secretRef or streamableHTTP.headers.authorization)."
        return 1
    fi
    if [ "${USE_STATIC_AUTH}" = false ] && [ -n "${has_auth_header}" ]; then
        print_warn "MCP server is in passthrough mode; verify Lightspeed auth header settings are intentional."
    else
        print_info "✓ Lightspeed auth/header configuration is present for current MCP auth mode"
    fi

    # 4) Connectivity check from OLS namespace to the endpoint style in use.
    if [ "${configured_url}" = "${expected_internal_url}" ]; then
        if mcp_oc run lightspeed-mcp-service-check -n "${LIGHTSPEED_NAMESPACE}" --rm -i --restart=Never \
            --image=curlimages/curl:8.8.0 --quiet -- \
            curl -sS --max-time 15 "http://stackrox-mcp.${MCP_NAMESPACE}:8080/health" >/dev/null 2>&1; then
            print_info "✓ Lightspeed namespace can reach MCP service health endpoint"
        else
            print_warn "Could not verify in-cluster MCP service reachability from ${LIGHTSPEED_NAMESPACE}."
            print_warn "Check NetworkPolicy / EgressFirewall / connectivity configuration."
        fi
    elif [ -n "${route_host}" ] && [ "${configured_url}" = "${expected_route_url}" ]; then
        if mcp_oc run lightspeed-mcp-route-check -n "${LIGHTSPEED_NAMESPACE}" --rm -i --restart=Never \
            --image=curlimages/curl:8.8.0 --quiet -- \
            curl -k -sS --max-time 15 "https://${route_host}/health" >/dev/null 2>&1; then
            print_info "✓ Lightspeed namespace can reach MCP route health endpoint"
        else
            print_warn "Could not verify route reachability from ${LIGHTSPEED_NAMESPACE}."
            print_warn "Check NetworkPolicy / EgressFirewall / connectivity configuration."
        fi
    else
        print_info "Skipping endpoint reachability probe for non-standard MCP URL: ${configured_url}"
    fi

    # 5) Ensure Lightspeed deployment is present and ready (restart if needed after config changes).
    if mcp_oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        local ls_ready ls_desired
        ls_ready=$(mcp_oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        ls_desired=$(mcp_oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "${ls_ready:-0}" -ge 1 ] 2>/dev/null; then
            print_info "✓ lightspeed-app-server is ready (${ls_ready}/${ls_desired})"
        else
            print_warn "lightspeed-app-server not ready (${ls_ready}/${ls_desired})."
        fi
        print_info "If OLSConfig (${OLS_SCOPE}-scoped) was updated, restart to pick up changes:"
        print_info "  oc rollout restart deployment/lightspeed-app-server -n ${LIGHTSPEED_NAMESPACE}"
    fi
}

main() {
    print_step "StackRox MCP Server Deployment (Kubernetes manifests)"
    echo "=========================================="
    echo ""

    print_info "Loading ROX_* from ~/.bashrc (safe mode; no \$(...) execution)..."
    export_bashrc_vars

    print_info "Checking OpenShift login (oc request timeout ${MCP_OC_REQUEST_TIMEOUT})..."
    local oc_user
    oc_user=$(mcp_oc whoami 2>/dev/null || true)
    if [ -z "${oc_user}" ]; then
        print_error "Not logged into OpenShift. Run: oc login"
        setup_rerun_hint_print
        exit 1
    fi
    print_info "Logged in as: ${oc_user}"

    if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
        print_info "Detecting ROX_CENTRAL_ADDRESS from route central..."
        ROX_CENTRAL_ADDRESS=$(mcp_oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || true)
    fi

    if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
        print_error "ROX_CENTRAL_ADDRESS not set and could not detect from cluster"
        print_info "Set it: export ROX_CENTRAL_ADDRESS='https://central-stackrox.apps.your-cluster.com'"
        setup_rerun_hint_print
        exit 1
    fi

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_warn "ROX_API_TOKEN not set - MCP server will use passthrough auth"
        print_info "For Cursor/CLI clients, use static auth: run setup/rhacs-configure.sh (or lab-environment.sh) first to generate ROX_API_TOKEN"
        AUTH_TYPE="passthrough"
        USE_STATIC_AUTH=false
    else
        AUTH_TYPE="static"
        USE_STATIC_AUTH=true
    fi

    print_info "Resolving Central URL for MCP config (cluster service vs route)..."
    CENTRAL_URL=$(get_central_url_for_mcp)
    print_info "Central URL for MCP: ${CENTRAL_URL}"
    echo ""

    if [ ! -d "${MANIFESTS_DIR}" ]; then
        print_error "Manifests directory not found: ${MANIFESTS_DIR}"
        setup_rerun_hint_print
        exit 1
    fi

    local required
    required=(
        namespace.yaml serviceaccount.yaml configmap.yaml.template
        service.yaml deployment.yaml route.yaml
    )
    local f
    for f in "${required[@]}"; do
        if [ ! -f "${MANIFESTS_DIR}/${f}" ]; then
            print_error "Missing manifest file: ${MANIFESTS_DIR}/${f}"
            setup_rerun_hint_print
            exit 1
        fi
    done

    # Process manifests (substitute placeholders)
    print_step "Processing manifests..."
    local tmpdir
    tmpdir=$(mktemp -d) || {
        print_error "mktemp -d failed (cannot build rendered manifests)"
        setup_rerun_hint_print
        exit 1
    }
    trap "rm -rf '${tmpdir}'" EXIT

    mcp_subs_namespace "${MANIFESTS_DIR}/namespace.yaml" > "${tmpdir}/namespace.yaml"
    mcp_subs_namespace "${MANIFESTS_DIR}/serviceaccount.yaml" > "${tmpdir}/serviceaccount.yaml"
    if ! mcp_subs_namespace "${MANIFESTS_DIR}/configmap.yaml.template" | \
        sed -e "s|CENTRAL_URL|${CENTRAL_URL}|g" -e "s|AUTH_TYPE|${AUTH_TYPE}|g" \
        > "${tmpdir}/configmap.yaml"; then
        print_error "Failed to render configmap (sed pipeline). Check CENTRAL_URL / AUTH_TYPE."
        setup_rerun_hint_print
        exit 1
    fi
    mcp_subs_namespace "${MANIFESTS_DIR}/service.yaml" > "${tmpdir}/service.yaml"
    mcp_subs_namespace "${MANIFESTS_DIR}/deployment.yaml" > "${tmpdir}/deployment.yaml"
    mcp_subs_namespace "${MANIFESTS_DIR}/route.yaml" > "${tmpdir}/route.yaml"
    print_info "✓ Manifests processed"
    echo ""

    # Apply manifests (stderr from oc is captured; ERR trap adds line number on failure)
    print_step "Deploying StackRox MCP server..."
    mcp_oc apply -f "${tmpdir}/namespace.yaml"
    mcp_oc apply -f "${tmpdir}/serviceaccount.yaml"
    mcp_oc apply -f "${tmpdir}/configmap.yaml"
    mcp_oc apply -f "${tmpdir}/service.yaml"
    mcp_oc apply -f "${tmpdir}/deployment.yaml"
    mcp_oc apply -f "${tmpdir}/route.yaml"

    # Inject API token as env var when using static auth
    if [ "${USE_STATIC_AUTH}" = true ]; then
        print_info "Configuring static auth with ROX_API_TOKEN..."
        mcp_oc set env deployment/stackrox-mcp -n "${MCP_NAMESPACE}" \
            STACKROX_MCP__CENTRAL__AUTH_TYPE=static \
            STACKROX_MCP__CENTRAL__API_TOKEN="${ROX_API_TOKEN}" \
            --overwrite
        ensure_lightspeed_auth_secret
    fi
    print_info "✓ StackRox MCP server deployed"
    echo ""

    patch_lightspeed_olsconfig
    validate_lightspeed_mcp_integration
    echo ""

    # Wait for rollout
    print_step "Waiting for deployment..."
    mcp_oc rollout status deployment/stackrox-mcp -n "${MCP_NAMESPACE}" --timeout=120s || true
    echo ""

    # Summary
    print_step "Deployment complete"
    echo "=========================================="
    print_info "Namespace: ${MCP_NAMESPACE}"
    print_info "Service: stackrox-mcp.${MCP_NAMESPACE}.svc:8080"
    local actual_route_host
    actual_route_host=$(mcp_oc get route stackrox-mcp -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "${actual_route_host}" ]; then
        print_info "Route: https://${actual_route_host}"
        echo ""
        print_info "MCP endpoint for client configuration (HTTP transport):"
        echo "  https://${actual_route_host}/mcp"
        echo ""
        print_info "Optional: use Claude CLI to query ACS via MCP"
        echo "  claude mcp add --transport http stackrox https://${actual_route_host}/mcp"
        echo "  claude mcp list"
        echo "  # In Claude, ask:"
        echo "  # Use MCP server stackrox-mcp and run list_clusters"
    else
        echo ""
        print_info "For external access, create a Route or check: oc get route -n ${MCP_NAMESPACE}"
    fi
    echo ""
    print_info "Documentation: https://github.com/stackrox/stackrox-mcp"
    echo ""
}

main "$@"
