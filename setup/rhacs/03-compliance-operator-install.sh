#!/bin/bash

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
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Default values
COMPLIANCE_NAMESPACE="${COMPLIANCE_NAMESPACE:-openshift-compliance}"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# Function to check if a resource exists
check_resource_exists() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-}
    
    if [ -n "${namespace}" ]; then
        oc get "${resource_type}" "${resource_name}" -n "${namespace}" &>/dev/null
    else
        oc get "${resource_type}" "${resource_name}" &>/dev/null
    fi
}

# Function to check if compliance operator is installed
is_compliance_operator_installed() {
    if ! check_resource_exists "namespace" "${COMPLIANCE_NAMESPACE}"; then
        return 1
    fi
    
    if ! check_resource_exists "subscription" "compliance-operator" "${COMPLIANCE_NAMESPACE}"; then
        return 1
    fi
    
    # Check CSV status
    local csv_name=$(oc get subscription compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    if [ -z "${csv_name}" ]; then
        return 1
    fi
    
    local csv_phase=$(oc get csv "${csv_name}" -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${csv_phase}" != "Succeeded" ]; then
        return 1
    fi
    
    # Additional check: verify operator pods are running
    # Check if compliance-operator deployment exists and is available
    if check_resource_exists "deployment" "compliance-operator" "${COMPLIANCE_NAMESPACE}"; then
        local deployment_ready=$(oc get deployment compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
        if [ "${deployment_ready}" != "True" ]; then
            return 1
        fi
    else
        return 1
    fi
    
    return 0
}

# Function to get installed compliance operator version
get_compliance_operator_version() {
    local csv_name=$(oc get subscription compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    if [ -n "${csv_name}" ]; then
        echo "${csv_name}" | grep -oP 'v\K[0-9.]+' || echo "${csv_name}"
    fi
}

# Compliance Operator must watch openshift-compliance. An empty targetNamespaces
# list can leave ProfileBundles unreconciled (no ocp4/rhcos4 parser pods).
ensure_operatorgroup() {
    print_info "Ensuring OperatorGroup targets ${COMPLIANCE_NAMESPACE}..."
    local og_name
    og_name=$(oc get operatorgroup -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "${og_name}" ]; then
        if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: compliance-operator
  namespace: ${COMPLIANCE_NAMESPACE}
spec:
  targetNamespaces:
  - ${COMPLIANCE_NAMESPACE}
EOF
        then
            print_error "Failed to create OperatorGroup"
            return 1
        fi
        print_info "✓ OperatorGroup created"
        return 0
    fi

    local targets
    targets=$(oc get operatorgroup "${og_name}" -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.spec.targetNamespaces[*]}' 2>/dev/null || true)
    if echo " ${targets} " | grep -q " ${COMPLIANCE_NAMESPACE} "; then
        print_info "✓ OperatorGroup ${og_name} already targets ${COMPLIANCE_NAMESPACE}"
        return 0
    fi

    print_info "Patching OperatorGroup ${og_name} to include ${COMPLIANCE_NAMESPACE}..."
    if ! oc patch operatorgroup "${og_name}" -n "${COMPLIANCE_NAMESPACE}" --type merge \
        -p "{\"spec\":{\"targetNamespaces\":[\"${COMPLIANCE_NAMESPACE}\"]}}" >/dev/null; then
        print_error "Failed to patch OperatorGroup ${og_name}"
        return 1
    fi
    print_info "✓ OperatorGroup patched"
    return 0
}

wait_for_profile_parser_pods() {
    print_step "Waiting for Compliance Operator profile parser pods..."
    local required_pods=("ocp4-openshift-compliance-pp" "rhcos4-openshift-compliance-pp")
    local max_wait=180
    local interval=10
    local elapsed=0

    while [ ${elapsed} -lt ${max_wait} ]; do
        local all_ready=true
        local pod_prefix pod_count
        for pod_prefix in "${required_pods[@]}"; do
            pod_count=$(oc get pods -n "${COMPLIANCE_NAMESPACE}" --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c "${pod_prefix}" || true)
            pod_count=${pod_count:-0}
            if [ "${pod_count}" -eq 0 ]; then
                all_ready=false
                break
            fi
        done
        if [ "${all_ready}" = true ]; then
            print_info "✓ Profile parser pods are running"
            return 0
        fi
        if [ $((elapsed % 30)) -eq 0 ]; then
            print_info "Waiting for profile parser pods... (${elapsed}s/${max_wait}s)"
        fi
        sleep ${interval}
        elapsed=$((elapsed + interval))
    done

    print_warn "Profile parser pods not ready within ${max_wait}s (RHACS may need a few more minutes to list profiles)"
    return 0
}

# RHACS installed before the Compliance Operator does not pick up profiles until Sensor restarts.
restart_rhacs_sensor() {
    print_step "Restarting RHACS Sensor so it discovers the Compliance Operator..."
    if ! oc get pods -l app.kubernetes.io/component=sensor -n "${RHACS_NAMESPACE}" --no-headers 2>/dev/null | grep -q .; then
        print_warn "No Sensor pods found in ${RHACS_NAMESPACE}; skip restart"
        return 0
    fi
    oc delete pods -l app.kubernetes.io/component=sensor -n "${RHACS_NAMESPACE}" --wait=false >/dev/null 2>&1 || {
        print_warn "Could not delete Sensor pods"
        return 0
    }
    sleep 5
    oc wait --for=condition=Ready pod -l app.kubernetes.io/component=sensor -n "${RHACS_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || {
        print_warn "Sensor may still be restarting"
        return 0
    }
    print_info "✓ Sensor is ready"
    return 0
}

# Function to install compliance operator
install_compliance_operator() {
    print_step "Installing Compliance Operator..."
    
    # Create namespace
    print_info "Creating namespace ${COMPLIANCE_NAMESPACE}..."
    oc create ns "${COMPLIANCE_NAMESPACE}" --dry-run=client -o yaml | oc apply -f - || {
        print_error "Failed to create namespace"
        return 1
    }
    print_info "✓ Namespace ready"
    
    if ! ensure_operatorgroup; then
        return 1
    fi
    
    # Determine channel
    print_info "Determining operator channel..."
    local channel="stable"
    if oc get packagemanifest compliance-operator -n openshift-marketplace >/dev/null 2>&1; then
        local available_channels=$(oc get packagemanifest compliance-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
        if echo "${available_channels}" | grep -q "stable"; then
            channel="stable"
        elif [ -n "${available_channels}" ]; then
            channel=$(echo "${available_channels}" | awk '{print $1}')
        fi
    fi
    print_info "Using channel: ${channel}"
    
    # Create Subscription
    print_info "Creating Subscription..."
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: compliance-operator
  namespace: ${COMPLIANCE_NAMESPACE}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: compliance-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    then
        print_error "Failed to create Subscription"
        return 1
    fi
    print_info "✓ Subscription created"
    
    # Wait for CSV to be created
    print_info "Waiting for CSV to be created (max 120s)..."
    local wait_count=0
    local max_wait=120
    local csv_created=false
    
    while [ ${wait_count} -lt ${max_wait} ]; do
        if oc get csv -n "${COMPLIANCE_NAMESPACE}" 2>/dev/null | grep -q compliance-operator; then
            csv_created=true
            break
        fi
        sleep 2
        wait_count=$((wait_count + 2))
    done
    
    if [ "${csv_created}" = false ]; then
        print_error "CSV not created after ${max_wait} seconds"
        print_error "Check subscription status: oc get subscription compliance-operator -n ${COMPLIANCE_NAMESPACE}"
        return 1
    fi
    print_info "✓ CSV created"
    
    # Get CSV name and wait for it to be ready
    local csv_name=$(oc get csv -n "${COMPLIANCE_NAMESPACE}" -o name 2>/dev/null | grep compliance-operator | head -1 | cut -d'/' -f2)
    if [ -z "${csv_name}" ]; then
        print_error "Could not determine CSV name"
        return 1
    fi
    
    print_info "Waiting for CSV ${csv_name} to reach Succeeded phase..."
    oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/"${csv_name}" -n "${COMPLIANCE_NAMESPACE}" --timeout=300s || {
        print_error "CSV did not reach Succeeded phase"
        return 1
    }
    print_info "✓ CSV reached Succeeded phase"
    
    # Wait for pods to be ready
    print_info "Waiting for operator pods to be ready..."
    oc wait --for=condition=ready pod -l name=compliance-operator -n "${COMPLIANCE_NAMESPACE}" --timeout=120s || {
        print_warn "Pods may not be fully ready yet"
    }
    print_info "✓ Operator pods ready"
    
    return 0
}

# Main function
main() {
    print_info "=========================================="
    print_info "Compliance Operator Installation"
    print_info "=========================================="
    print_info ""
    
    # Check if already installed
    print_step "Checking Compliance Operator installation..."
    if is_compliance_operator_installed; then
        local version=$(get_compliance_operator_version)
        print_info "✓ Compliance Operator is already installed and ready"
        if [ -n "${version}" ]; then
            print_info "  Version: ${version}"
        fi
        
        # Show deployment status
        local deployment_status=$(oc get deployment compliance-operator -n "${COMPLIANCE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
        print_info "  Deployment status: Available=${deployment_status}"
        print_info ""
        print_info "✓ Skipping installation"
    else
        print_info "Compliance Operator not found or not ready, installing..."
        
        # Install compliance operator
        if ! install_compliance_operator; then
            print_error "Failed to install Compliance Operator"
            exit 1
        fi
        
        print_info "✓ Compliance Operator installed successfully"
    fi

    # Existing installs may still have an empty OperatorGroup from an older script.
    ensure_operatorgroup || true
    wait_for_profile_parser_pods
    restart_rhacs_sensor
    
    print_info ""
    print_info "=========================================="
    print_info "Compliance Operator Setup Complete"
    print_info "=========================================="
    print_info "Namespace: ${COMPLIANCE_NAMESPACE}"
    print_info ""
    print_info "Note: RHACS Sensor was restarted so Compliance Operator profiles can sync"
    print_info ""
}

# Run main function
main "$@"

