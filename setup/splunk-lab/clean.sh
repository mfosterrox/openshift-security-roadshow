#!/usr/bin/env bash
#
# Tear down resources created by splunk-setup/setup.sh.
#
# Usage:
#   ./clean.sh
#
# Optional environment variables:
#   SPLUNK_NAMESPACE            Namespace used by setup (default: splunk)
#   SPLUNK_NAME                 Base resource name (default: splunk)
#   SPLUNK_DELETE_NAMESPACE     Delete namespace entirely (default: true)
#   SPLUNK_FORCE_DELETE_NAMESPACE After requesting delete, remove namespace finalizers (stuck Terminating) (default: false)
#   SPLUNK_CLEAN_RHACS_NOTIFIER Delete RHACS notifier via API (default: true)
#   SPLUNK_NOTIFIER_NAME        RHACS notifier name (default: Splunk SIEM (local))
#   ROX_CENTRAL_ADDRESS         RHACS Central URL for notifier cleanup
#   ROX_API_TOKEN               RHACS API token for notifier cleanup
#

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        print_error "Required command not found: ${cmd}"
        exit 1
    fi
}

force_finalize_namespace() {
    local namespace="$1"
    if ! oc get namespace "${namespace}" >/dev/null 2>&1; then
        return 0
    fi
    print_warn "Removing finalizers on namespace '${namespace}' (Kubernetes force finalize)"
    if ! oc get namespace "${namespace}" -o json | jq '.spec.finalizers = []' | oc replace --raw "/api/v1/namespaces/${namespace}/finalize" -f - >/dev/null 2>&1; then
        print_error "Could not finalize namespace '${namespace}'."
        return 1
    fi
    return 0
}

delete_rhacs_notifier() {
    local notifier_name="$1"
    local rox_central="${ROX_CENTRAL_ADDRESS:-}"
    local rox_token="${ROX_API_TOKEN:-}"

    if [ "${SPLUNK_CLEAN_RHACS_NOTIFIER:-true}" != "true" ]; then
        print_info "Skipping RHACS notifier cleanup (SPLUNK_CLEAN_RHACS_NOTIFIER=${SPLUNK_CLEAN_RHACS_NOTIFIER})"
        return 0
    fi

    if [ -z "${rox_central}" ] || [ -z "${rox_token}" ]; then
        print_warn "ROX_CENTRAL_ADDRESS or ROX_API_TOKEN not set; skipping RHACS notifier cleanup."
        return 0
    fi

    print_step "Removing RHACS notifier '${notifier_name}' (if present)"
    local notifier_id
    notifier_id="$(
        curl -k -s -H "Authorization: Bearer ${rox_token}" "${rox_central}/v1/notifiers" 2>/dev/null | \
        jq -r --arg n "${notifier_name}" '.notifiers[]? | select(.name==$n) | .id' 2>/dev/null || true
    )"

    if [ -z "${notifier_id}" ]; then
        print_info "RHACS notifier not found; nothing to delete."
        return 0
    fi

    local code
    code="$(curl -k -s -o /tmp/rhacs-splunk-notifier-delete.out -w "%{http_code}" \
        -X DELETE "${rox_central}/v1/notifiers/${notifier_id}" \
        -H "Authorization: Bearer ${rox_token}")"

    if echo "${code}" | grep -qE "^(200|202|204)$"; then
        print_info "RHACS notifier deleted."
    else
        print_warn "RHACS notifier delete returned HTTP ${code}."
        print_warn "Response: $(cat /tmp/rhacs-splunk-notifier-delete.out 2>/dev/null || echo '<empty>')"
    fi
}

main() {
    require_cmd oc
    require_cmd curl
    require_cmd jq

    if ! oc whoami >/dev/null 2>&1; then
        print_error "You are not logged in to OpenShift. Run: oc login"
        exit 1
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "${script_dir}/cleanup-openshift-audit.sh" ]; then
        print_step "Removing OpenShift audit ClusterLogForwarder (if present)"
        bash "${script_dir}/cleanup-openshift-audit.sh" || print_warn "Audit forwarder cleanup returned non-zero."
    fi

    local namespace="${SPLUNK_NAMESPACE:-splunk}"
    local name="${SPLUNK_NAME:-splunk}"
    local delete_ns="${SPLUNK_DELETE_NAMESPACE:-true}"
    local notifier_name="${SPLUNK_NOTIFIER_NAME:-Splunk SIEM (local)}"

    delete_rhacs_notifier "${notifier_name}"

    if ! oc get namespace "${namespace}" >/dev/null 2>&1; then
        print_info "Namespace '${namespace}' not found; nothing to clean in cluster."
        exit 0
    fi

    if [ "${delete_ns}" = "true" ]; then
        print_step "Deleting namespace '${namespace}' (removes all Splunk resources)"
        oc delete namespace "${namespace}" --wait=false
        print_info "Namespace delete requested. Monitor with: oc get ns ${namespace}"
        if [ "${SPLUNK_FORCE_DELETE_NAMESPACE:-false}" = "true" ] || [ "${SPLUNK_FORCE_DELETE_NAMESPACE:-}" = "1" ]; then
            print_warn "SPLUNK_FORCE_DELETE_NAMESPACE is set: removing namespace finalizers after grace period."
            sleep 10
            force_finalize_namespace "${namespace}" || print_warn "Force finalize failed; you may need cluster-admin."
        fi
        exit 0
    fi

    print_step "Deleting Splunk resources in namespace '${namespace}'"
    oc -n "${namespace}" delete route "${name}-web" --ignore-not-found=true
    oc -n "${namespace}" delete service "${name}" --ignore-not-found=true
    oc -n "${namespace}" delete deployment "${name}" --ignore-not-found=true
    oc -n "${namespace}" delete pvc "${name}-var" --ignore-not-found=true
    oc -n "${namespace}" delete pvc "${name}-etc" --ignore-not-found=true
    oc -n "${namespace}" delete secret "${name}-auth" --ignore-not-found=true
    oc -n "${namespace}" delete serviceaccount "${name}-sa" --ignore-not-found=true
    print_info "Resource cleanup completed in namespace '${namespace}'."
}

main "$@"
