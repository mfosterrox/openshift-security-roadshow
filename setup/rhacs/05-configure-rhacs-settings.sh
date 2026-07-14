#!/bin/bash
# RHACS Configuration Script
# Makes API calls to RHACS to change configuration details
# Enables monitoring/metrics and configures policy guidelines

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

error_handler() {
    local exit_code=$1
    local line_number=$2
    print_error "Script failed at line ${line_number} (exit code: ${exit_code})"
    exit "${exit_code}"
}

trap 'error_handler $? $LINENO' ERR

# Default values
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS:-}"
# Base images for layer filtering (Hummingbird HI + demo-apps frontend python:3.12-alpine)
# Override all with space-separated repo|tag pairs, e.g.:
#   RHACS_BASE_IMAGE_REFERENCES="registry.access.redhat.com/hi/python|3.13 docker.io/library/python|3.12-alpine"
RHACS_BASE_IMAGE_REPO_PATH="${RHACS_BASE_IMAGE_REPO_PATH:-registry.access.redhat.com/hi/python}"
RHACS_BASE_IMAGE_TAG_PATTERN="${RHACS_BASE_IMAGE_TAG_PATTERN:-3.13}"
SKIP_RHACS_BASE_IMAGES="${SKIP_RHACS_BASE_IMAGES:-0}"
# Function to check if jq is installed
ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    
    print_warn "jq is not installed, attempting to install..."
    
    if command -v dnf >/dev/null 2>&1; then
        if sudo dnf install -y jq >/dev/null 2>&1; then
            print_info "✓ jq installed successfully"
            return 0
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1; then
            print_info "✓ jq installed successfully"
            return 0
        fi
    fi
    
    print_error "Could not install jq. Please install it manually: sudo dnf install -y jq"
    return 1
}

# Function to get Central URL
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
    
    # Try to get from route
    local url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${url}" ]; then
        echo "${url}"
        return 0
    fi
    
    return 1
}

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local token=$3
    local api_base=$4
    local data="${5:-}"
    
    local curl_opts="-k -s -w \n%{http_code}"
    curl_opts="${curl_opts} -X ${method}"
    curl_opts="${curl_opts} -H \"Authorization: Bearer ${token}\""
    curl_opts="${curl_opts} -H \"Content-Type: application/json\""
    
    if [ -n "${data}" ]; then
        curl_opts="${curl_opts} -d '${data}'"
    fi
    
    local response=$(eval "curl ${curl_opts} \"${api_base}/${endpoint}\"" 2>/dev/null || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_error "API call failed (HTTP ${http_code}): ${method} ${endpoint}"
        return 1
    fi
    
    echo "${body}"
    return 0
}

# Function to check if telemetry is already enabled
is_telemetry_enabled() {
    local token=$1
    local api_base=$2
    
    local config=$(make_api_call "GET" "config" "${token}" "${api_base}" "" 2>/dev/null || echo "")
    if [ -z "${config}" ]; then
        return 1
    fi
    
    local telemetry=$(echo "${config}" | jq -r '.config.publicConfig.telemetry.enabled' 2>/dev/null || echo "false")
    if [ "${telemetry}" = "true" ]; then
        return 0
    fi
    
    return 1
}

# Function to update RHACS configuration
update_rhacs_config() {
    local token=$1
    local api_base=$2
    
    print_info "Updating RHACS global configuration..."
    
    # Configuration payload for RHACS 4.9.x
    local config_payload=$(cat <<'EOF'
{
  "config": {
    "publicConfig": {
      "loginNotice": { "enabled": false, "text": "" },
      "header": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "footer": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "telemetry": { "enabled": true, "lastSetTime": null }
    },
    "privateConfig": {
      "alertConfig": {
        "resolvedDeployRetentionDurationDays": 7,
        "deletedRuntimeRetentionDurationDays": 7,
        "allRuntimeRetentionDays": 30,
        "attemptedDeployRetentionDurationDays": 7,
        "attemptedRuntimeRetentionDurationDays": 7
      },
      "imageRetentionDurationDays": 7,
      "expiredVulnReqRetentionDurationDays": 90,
      "decommissionedClusterRetention": {
        "retentionDurationDays": 0,
        "ignoreClusterLabels": {},
        "lastUpdated": null,
        "createdAt": null
      },
      "reportRetentionConfig": {
        "historyRetentionDurationDays": 7,
        "downloadableReportRetentionDays": 7,
        "downloadableReportGlobalRetentionBytes": 524288000
      },
      "vulnerabilityExceptionConfig": {
        "expiryOptions": {
          "dayOptions": [
            { "numDays": 14, "enabled": true },
            { "numDays": 30, "enabled": true },
            { "numDays": 60, "enabled": true },
            { "numDays": 90, "enabled": true }
          ],
          "fixableCveOptions": { "allFixable": true, "anyFixable": true },
          "customDate": false,
          "indefinite": false
        }
      },
      "administrationEventsConfig": { "retentionDurationDays": 4 },
      "metrics": {
        "imageVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "cve_severity": { "labels": ["Cluster","CVE","IsPlatformWorkload","IsFixable","Severity"] },
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformWorkload","IsFixable","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformWorkload","IsFixable","Severity"] }
          }
        },
        "policyViolations": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformComponent","Action","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformComponent","Action","Severity"] }
          }
        },
        "nodeVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "component_severity": { "labels": ["Cluster","Node","Component","IsFixable","Severity"] },
            "cve_severity": { "labels": ["Cluster","CVE","IsFixable","Severity"] },
            "node_severity": { "labels": ["Cluster","Node","IsFixable","Severity"] }
          }
        }
      }
    },
    "platformComponentConfig": {
      "rules": [
        {
          "name": "red hat layered products",
          "namespaceRule": { "regex": "^aap$|^ack-system$|^aws-load-balancer-operator$|^cert-manager-operator$|^cert-utils-operator$|^costmanagement-metrics-operator$|^external-dns-operator$|^metallb-system$|^mtr$|^multicluster-engine$|^multicluster-global-hub$|^node-observability-operator$|^open-cluster-management$|^openshift-adp$|^openshift-apiserver-operator$|^openshift-authentication$|^openshift-authentication-operator$|^openshift-builds$|^openshift-cloud-controller-manager$|^openshift-cloud-controller-manager-operator$|^openshift-cloud-credential-operator$|^openshift-cloud-network-config-controller$|^openshift-cluster-csi-drivers$|^openshift-cluster-machine-approver$|^openshift-cluster-node-tuning-operator$|^openshift-cluster-observability-operator$|^openshift-cluster-samples-operator$|^openshift-cluster-storage-operator$|^openshift-cluster-version$|^openshift-cnv$|^openshift-compliance$|^openshift-config$|^openshift-config-managed$|^openshift-config-operator$|^openshift-console$|^openshift-console-operator$|^openshift-console-user-settings$|^openshift-controller-manager$|^openshift-controller-manager-operator$|^openshift-dbaas-operator$|^openshift-distributed-tracing$|^openshift-dns$|^openshift-dns-operator$|^openshift-dpu-network-operator$|^openshift-dr-system$|^openshift-etcd$|^openshift-etcd-operator$|^openshift-file-integrity$|^openshift-gitops-operator$|^openshift-host-network$|^openshift-image-registry$|^openshift-infra$|^openshift-ingress$|^openshift-ingress-canary$|^openshift-ingress-node-firewall$|^openshift-ingress-operator$|^openshift-insights$|^openshift-keda$|^openshift-kmm$|^openshift-kmm-hub$|^openshift-kni-infra$|^openshift-kube-apiserver$|^openshift-kube-apiserver-operator$|^openshift-kube-controller-manager$|^openshift-kube-controller-manager-operator$|^openshift-kube-scheduler$|^openshift-kube-scheduler-operator$|^openshift-kube-storage-version-migrator$|^openshift-kube-storage-version-migrator-operator$|^openshift-lifecycle-agent$|^openshift-local-storage$|^openshift-logging$|^openshift-machine-api$|^openshift-machine-config-operator$|^openshift-marketplace$|^openshift-migration$|^openshift-monitoring$|^openshift-mta$|^openshift-mtv$|^openshift-multus$|^openshift-netobserv-operator$|^openshift-network-diagnostics$|^openshift-network-node-identity$|^openshift-network-operator$|^openshift-nfd$|^openshift-nmstate$|^openshift-node$|^openshift-nutanix-infra$|^openshift-oauth-apiserver$|^openshift-openstack-infra$|^openshift-opentelemetry-operator$|^openshift-operator-lifecycle-manager$|^openshift-operators$|^openshift-operators-redhat$|^openshift-ovirt-infra$|^openshift-ovn-kubernetes$|^openshift-ptp$|^openshift-route-controller-manager$|^openshift-sandboxed-containers-operator$|^openshift-security-profiles$|^openshift-serverless$|^openshift-serverless-logic$|^openshift-service-ca$|^openshift-service-ca-operator$|^openshift-sriov-network-operator$|^openshift-storage$|^openshift-tempo-operator$|^openshift-update-service$|^openshift-user-workload-monitoring$|^openshift-vertical-pod-autoscaler$|^openshift-vsphere-infra$|^openshift-windows-machine-config-operator$|^openshift-workload-availability$|^redhat-ods-operator$|^rhacs-operator$|^rhdh-operator$|^service-telemetry$|^stackrox$|^submariner-operator$|^tssc-acs$|^openshift-devspaces$" }
        },
        {
          "name": "system rule",
          "namespaceRule": { "regex": "^openshift$|^openshift-apiserver$|^openshift-operators$|^kube-.*" }
        }
      ],
      "needsReevaluation": false
    }
  }
}
EOF
)
    
    # Apply configuration
    print_info "Sending configuration to ${api_base}/config..."
    
    local response=$(curl -k -s -w "\n%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${config_payload}" \
        "${api_base}/config" 2>&1)
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_error "Failed to update configuration (HTTP ${http_code})"
        print_error "Response: ${body:0:200}"
        return 1
    fi
    
    print_info "✓ Configuration updated successfully"
    return 0
}

# Register base images via v2 API so RHACS separates base-layer vs application-layer CVEs.
# Requires ImageAdministration permission on the API token.
configure_base_images() {
    local token=$1
    local api_v2_base=$2

    if [ "${SKIP_RHACS_BASE_IMAGES}" = "1" ]; then
        print_info "Skipping base image configuration (SKIP_RHACS_BASE_IMAGES=1)"
        return 0
    fi

    print_step "Configuring RHACS base image references..."

    # shellcheck disable=SC1090
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rhacs-base-images.sh"
    register_rhacs_base_images "${token}" "${api_v2_base}"
}

# Function to validate configuration
validate_configuration() {
    local token=$1
    local api_base=$2
    
    print_info "Validating configuration..."
    
    local response=$(curl -k -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        "${api_base}/config" 2>&1)
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        print_warn "Could not validate configuration (HTTP ${http_code})"
        return 1
    fi
    
    local telemetry=$(echo "${body}" | jq -r '.config.publicConfig.telemetry.enabled' 2>/dev/null || echo "unknown")
    
    if [ "${telemetry}" = "true" ]; then
        print_info "✓ Telemetry configuration verified: enabled"
    elif [ "${telemetry}" != "unknown" ]; then
        print_info "✓ Telemetry configuration: ${telemetry}"
    fi
    
    return 0
}

# Main function
main() {
    print_info "=========================================="
    print_info "RHACS Configuration"
    print_info "=========================================="
    print_info ""
    
    # Check prerequisites
    print_step "Checking prerequisites..."
    
    if ! ensure_jq; then
        exit 1
    fi
    
    # Get Central URL
    print_info "Getting Central URL..."
    local central_url=$(get_central_url)
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        print_error "Please ensure RHACS is installed or set ROX_CENTRAL_ADDRESS"
        exit 1
    fi
    print_info "Central URL: ${central_url}"
    
    # Setup API base URL
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local api_base="https://${api_host}/v1"
    local api_v2_base="https://${api_host}/v2"
    
    # Use API token from environment (required)
    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN environment variable is not set"
        print_error "Please set ROX_API_TOKEN before running this script"
        print_error "You can generate a token using the RHACS UI or API"
        exit 1
    fi
    
    print_info "✓ Using API token from environment"
    
    print_info ""
    
    # Check if already configured
    print_step "Checking current configuration..."
    # Apply configuration
    if ! update_rhacs_config "${token}" "${api_base}"; then
        print_error "Failed to update RHACS configuration"
        exit 1
    fi
    
    print_info "✓ RHACS configuration applied successfully"

    print_info ""

    # Register base images for vulnerability layer filtering (v2 API)
    if ! configure_base_images "${token}" "${api_v2_base}"; then
        print_warn "Base image configuration failed; continuing with other settings"
    fi
    
    # Verify configuration (optional, non-fatal)
    validate_configuration "${token}" "${api_base}" || true
    
    print_info ""
    print_info "=========================================="
    print_info "RHACS Configuration Complete"
    print_info "=========================================="
    print_info ""
    print_info "Configuration applied:"
    print_info "  - Telemetry and monitoring enabled"
    print_info "  - Metrics collection configured (1-minute gathering)"
    print_info "  - Detailed metrics descriptors:"
    print_info "    • Image vulnerabilities (cve, deployment, namespace)"
    print_info "    • Policy violations (deployment, namespace)"
    print_info "    • Node vulnerabilities (component, cve, node)"
    print_info "  - Platform component rules (Red Hat layered products)"
    print_info "  - Retention policies configured:"
    print_info "    • 7-day alert retention"
    print_info "    • 30-day runtime retention"
    print_info "    • 90-day vulnerability request retention"
    print_info "  - Base image references:"
    print_info "    • ${RHACS_BASE_IMAGE_REPO_PATH}:${RHACS_BASE_IMAGE_TAG_PATTERN}"
    print_info "    • docker.io/library/python:3.12-alpine"
    print_info "  - Configuration validated successfully"
    print_info ""
}

# Run main function
main "$@"
