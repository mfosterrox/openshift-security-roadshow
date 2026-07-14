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

# Default values if not set
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
RHACS_ROUTE_NAME="${RHACS_ROUTE_NAME:-central}"
RHACS_OPERATOR_NAMESPACE="${RHACS_OPERATOR_NAMESPACE:-rhacs-operator}"

# Optional pin: export RHACS_VERSION="4.10.3" to override auto-detect from operator catalog.
# When unset, the script upgrades to the newest rhacs-X.Y channel in openshift-marketplace.

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

# Get RHACS version from central deployment label app.kubernetes.io/version (e.g. Helm-managed installs).
get_version_from_deployment_label() {
    oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo ""
}

# Function to get current image tag from deployment (e.g. 4.9.3 or 4.10.0)
get_current_image_tag() {
    oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':[^:]+$' | sed 's/^://'
}

# Function to get installed RHACS version.
# Prefers deployment label; falls back to image tag (operator-managed installs often don't set the label).
get_installed_version() {
    local label_version
    label_version=$(get_version_from_deployment_label)
    if [ -n "${label_version}" ]; then
        echo "${label_version}"
        return
    fi
    # Fallback: image tag reflects actual running version (e.g. 4.10.0, 4.9.3, 4.10)
    local image_tag
    image_tag=$(get_current_image_tag)
    if [ -n "${image_tag}" ] && [[ "${image_tag}" =~ ^[0-9]+\.[0-9]+ ]]; then
        echo "${image_tag}"
    else
        echo ""
    fi
}

# Newest RHACS minor release from the operator catalog (e.g. 4.11 from channel rhacs-4.11).
get_latest_catalog_minor_version() {
    local channels latest_channel=""
    if ! oc get packagemanifest rhacs-operator -n openshift-marketplace &>/dev/null; then
        echo ""
        return
    fi
    channels=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
    latest_channel=$(echo "${channels}" | tr ' ' '\n' | grep -E '^rhacs-[0-9]+\.[0-9]+$' | sort -V | tail -1)
    if [ -n "${latest_channel}" ]; then
        echo "${latest_channel#rhacs-}"
    fi
}

# Full semver for the newest catalog channel (e.g. 4.11.0 from currentCSV on rhacs-4.11).
get_latest_catalog_version() {
    local latest_minor latest_channel csv_name
    latest_minor=$(get_latest_catalog_minor_version)
    if [ -z "${latest_minor}" ]; then
        echo ""
        return
    fi
    latest_channel="rhacs-${latest_minor}"
    if command -v jq &>/dev/null; then
        csv_name=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o json 2>/dev/null | \
            jq -r --arg ch "${latest_channel}" '.status.channels[] | select(.name == $ch) | .currentCSV' 2>/dev/null || echo "")
    else
        csv_name=$(oc get packagemanifest rhacs-operator -n openshift-marketplace -o jsonpath="{.status.channels[?(@.name==\"${latest_channel}\")].currentCSV}" 2>/dev/null || echo "")
    fi
    if [[ "${csv_name}" =~ \.v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [ -n "${latest_minor}" ]; then
        echo "${latest_minor}"
    fi
}

# Resolve target version: explicit RHACS_VERSION, else newest catalog minor, else installed CSV.
resolve_target_version() {
    if [ -n "${RHACS_VERSION:-}" ]; then
        echo "${RHACS_VERSION}"
        return
    fi
    local catalog_minor
    catalog_minor=$(get_latest_catalog_minor_version)
    if [ -n "${catalog_minor}" ]; then
        echo "${catalog_minor}"
        return
    fi
    get_latest_available_version
}

# Version from the installed operator CSV (reflects current channel, not necessarily catalog latest).
get_latest_available_version() {
    local csv_name
    csv_name=$(get_rhacs_csv_name)
    if [ -z "${csv_name}" ]; then
        get_version_from_deployment_label
        return
    fi
    local csv_ns
    csv_ns=$(get_rhacs_csv_namespace)
    # CSV name format: rhacs-operator.v4.10.0 or similar
    if [[ "${csv_name}" =~ \.v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        # Try spec.version from CSV
        oc get csv "${csv_name}" -n "${csv_ns}" -o jsonpath='{.spec.version}' 2>/dev/null || get_version_from_deployment_label
    fi
}



# Function to verify RHACS installation
verify_rhacs_installation() {
    print_step "Verifying RHACS installation..."
    
    # Check if namespace exists
    if ! check_resource_exists "namespace" "${RHACS_NAMESPACE}"; then
        print_error "RHACS namespace '${RHACS_NAMESPACE}' does not exist"
        return 1
    fi
    print_info "✓ Namespace '${RHACS_NAMESPACE}' exists"
    
    # Check for Central deployment
    if ! check_resource_exists "deployment" "central" "${RHACS_NAMESPACE}"; then
        print_error "Central deployment not found in namespace '${RHACS_NAMESPACE}'"
        return 1
    fi
    print_info "✓ Central deployment exists"
    
    # Check if Central is ready
    local central_ready=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
    if [ "${central_ready}" != "True" ]; then
        print_warn "Central deployment is not yet ready"
        print_info "Waiting for Central to become ready..."
        oc wait --for=condition=available --timeout=300s deployment/central -n "${RHACS_NAMESPACE}" || {
            print_error "Central deployment did not become ready within timeout"
            return 1
        }
    fi
    print_info "✓ Central deployment is ready"
    
    # Check for SecuredCluster resources
    print_step "Checking SecuredCluster services..."
    local secured_clusters=$(oc get securedcluster -A -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
    if [ "${secured_clusters}" -eq 0 ]; then
        print_warn "No SecuredCluster resources found"
    else
        print_info "✓ Found ${secured_clusters} SecuredCluster resource(s)"
        
        # Verify each SecuredCluster by checking its pods
        while IFS= read -r sc; do
            if [ -n "${sc}" ]; then
                local sc_namespace=$(echo "${sc}" | awk '{print $1}')
                local sc_name=$(echo "${sc}" | awk '{print $2}')
                
                # Check if sensor, admission-control, and collector pods are running
                local sensor_ready=$(oc get deployment sensor -n "${sc_namespace}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
                local admission_ready=$(oc get deployment admission-control -n "${sc_namespace}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
                local collector_count=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
                local collector_desired=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
                
                if [ "${sensor_ready}" = "True" ] && [ "${admission_ready}" = "True" ] && [ "${collector_count}" -eq "${collector_desired}" ] && [ "${collector_count}" -gt 0 ]; then
                    print_info "  ✓ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' is ready (sensor, admission-control, and ${collector_count}/${collector_desired} collectors running)"
                else
                    print_warn "  ⚠ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' components: sensor=${sensor_ready}, admission-control=${admission_ready}, collectors=${collector_count}/${collector_desired}"
                fi
            fi
        done < <(oc get securedcluster -A --no-headers 2>/dev/null || true)
    fi
    
    return 0
}

# Function to verify route encryption
verify_route_encryption() {
    print_step "Verifying RHACS route encryption..."
    
    # Check if route exists
    if ! check_resource_exists "route" "${RHACS_ROUTE_NAME}" "${RHACS_NAMESPACE}"; then
        print_error "Route '${RHACS_ROUTE_NAME}' not found in namespace '${RHACS_NAMESPACE}'"
        return 1
    fi
    print_info "✓ Route '${RHACS_ROUTE_NAME}' exists"
    
    # Check if route has TLS termination
    local tls_term=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ -z "${tls_term}" ] || [ "${tls_term}" = "None" ]; then
        print_error "Route '${RHACS_ROUTE_NAME}' does not have TLS termination configured"
        print_info "Updating route to use edge TLS termination..."
        
        # Patch the route to add TLS termination
        oc patch route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" --type=json -p='[
            {
                "op": "add",
                "path": "/spec/tls",
                "value": {
                    "termination": "edge",
                    "insecureEdgeTerminationPolicy": "Redirect"
                }
            }
        ]' || {
            print_error "Failed to update route TLS configuration"
            return 1
        }
        
        print_info "✓ Route updated with TLS termination"
    else
        print_info "✓ Route has TLS termination: ${tls_term}"
    fi
    
    # Verify route is accessible via HTTPS
    local route_url=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${route_url}" ]; then
        print_info "Route URL: ${route_url}"
        
        # Check if route responds (with a timeout)
        if curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "${route_url}" | grep -q "200\|302\|401\|403"; then
            print_info "✓ Route is accessible via HTTPS"
        else
            print_warn "Route may not be fully accessible yet (this is normal if RHACS is still initializing)"
        fi
    fi
    
    return 0
}

# Get the RHACS CSV name. Checks operator namespace first, then RHACS namespace.
# Returns e.g. rhacs-operator.v4.9.3. Empty if not found.
get_rhacs_csv_name() {
    local csv
    csv=$(oc get csv -n "${RHACS_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep rhacs-operator | head -1 | sed 's|.*/||')
    if [ -n "${csv}" ]; then
        echo "${csv}"
        return
    fi
    oc get csv -n "${RHACS_NAMESPACE}" -o name 2>/dev/null | grep rhacs-operator | head -1 | sed 's|.*/||' || echo ""
}

# Get the namespace where the RHACS CSV is installed (for patching).
get_rhacs_csv_namespace() {
    if oc get csv -n "${RHACS_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep -q rhacs-operator; then
        echo "${RHACS_OPERATOR_NAMESPACE}"
    elif oc get csv -n "${RHACS_NAMESPACE}" -o name 2>/dev/null | grep -q rhacs-operator; then
        echo "${RHACS_NAMESPACE}"
    else
        echo "${RHACS_NAMESPACE}"
    fi
}

# Ensure CSV deploy details are updated to target version (no subscriptions).
# Patches only deployment container images in the CSV to the target version tag.
ensure_csv_deploy_version() {
    local target_version=$1
    local csv_name
    csv_name=$(get_rhacs_csv_name)
    local csv_ns
    csv_ns=$(get_rhacs_csv_namespace)
    if [ -z "${csv_name}" ]; then
        print_warn "No RHACS CSV found; skipping CSV deploy update"
        return 0
    fi
    print_step "Updating CSV ${csv_name} deploy details to version ${target_version}..."
    if ! command -v jq &>/dev/null; then
        print_warn "jq not found; cannot patch CSV deploy details. Install jq or update the CSV manually."
        return 1
    fi
    local csv_json
    csv_json=$(oc get csv "${csv_name}" -n "${csv_ns}" -o json 2>/dev/null) || true
    if [ -z "${csv_json}" ]; then
        print_error "Failed to get CSV ${csv_name}"
        return 1
    fi
    local patched
    patched=$(echo "${csv_json}" | jq --arg tv "${target_version}" '
        del(.status) |
        .spec.install.spec.deployments |= (map(
            .spec.template.spec.containers |= (map(
                if .image then .image = ((.image | split(":")[0]) + ":" + $tv) else . end
            ))
        ))
    ')
    if echo "${patched}" | oc apply -f - -n "${csv_ns}" 2>/dev/null; then
        print_info "CSV deploy details updated; waiting 45s for rollout..."
        sleep 45
        return 0
    fi
    print_warn "Could not apply CSV patch"
    return 1
}

# Function to check and update RHACS version
# Uses RHACS_VERSION when set; otherwise newest rhacs-X.Y channel from the operator catalog.
# Uses subscription channel update when subscription exists; otherwise falls back to CSV deploy-details.
check_and_update_version() {
    print_step "Checking RHACS version..."
    
    local target_version
    target_version=$(resolve_target_version)
    if [ -z "${target_version}" ]; then
        print_warn "Could not determine a target RHACS version (catalog unavailable and no RHACS_VERSION set); skipping version update"
        return 0
    fi
    if [ -n "${RHACS_VERSION:-}" ]; then
        print_info "Target version (RHACS_VERSION): ${target_version}"
    else
        local catalog_version
        catalog_version=$(get_latest_catalog_version)
        if [ -n "${catalog_version}" ]; then
            print_info "Target version (newest catalog): ${target_version} (catalog CSV: ${catalog_version})"
        else
            print_info "Target version (auto-detect): ${target_version}"
        fi
    fi
    
    # Prefer subscription channel update (subscriptions.operators.coreos.com); fall back to CSV when no subscription
    if [ -n "$(get_rhacs_subscription_name)" ]; then
        ensure_subscription_channel_for_version "${target_version}" || true
    else
        ensure_csv_deploy_version "${target_version}" || true
    fi
    
    # Get current installed version (after possible channel switch)
    local installed_version=$(get_installed_version)
    local current_image_tag=$(get_current_image_tag)
    
    if [ -z "${installed_version}" ]; then
        print_warn "Could not determine installed RHACS version from semantic version pattern"
        if [ -n "${current_image_tag}" ]; then
            print_info "Current image tag: ${current_image_tag}"
        fi
        installed_version="unknown"
    else
        print_info "Installed RHACS version: ${installed_version}"
    fi
    
    # Catalog vs installed CSV (informational)
    local catalog_version installed_csv_version
    catalog_version=$(get_latest_catalog_version)
    installed_csv_version=$(get_latest_available_version)
    if [ -n "${catalog_version}" ]; then
        print_info "Newest version in operator catalog: ${catalog_version}"
    fi
    if [ -n "${installed_csv_version}" ]; then
        print_info "Installed operator CSV version: ${installed_csv_version}"
    fi
    
    # Extract major.minor for comparison (4.10 and 4.10.0 are same minor = stable)
    local target_major_minor="${target_version}"
    [[ "${target_version}" =~ ^([0-9]+\.[0-9]+) ]] && target_major_minor="${BASH_REMATCH[1]}"
    local installed_major_minor="${installed_version}"
    [[ "${installed_version}" =~ ^([0-9]+\.[0-9]+) ]] && installed_major_minor="${BASH_REMATCH[1]}"
    
    # Already at target: same minor = stable (4.10.x follows 4.10 channel)
    if [ "${installed_version}" != "unknown" ] && [ "${target_major_minor}" = "${installed_major_minor}" ]; then
        print_info "✓ RHACS is already on ${target_version} channel (installed: ${installed_version})"
        return 0
    fi
    
    # Downgrade check: only when target minor < installed minor (e.g. 4.9 vs 4.10.0)
    if [ "${installed_version}" != "unknown" ] && [ "${target_version}" != "unknown" ]; then
        if [ "$(printf '%s\n' "${target_major_minor}" "${installed_major_minor}" | sort -V | head -n1)" = "${target_major_minor}" ] && \
           [ "${target_major_minor}" != "${installed_major_minor}" ]; then
            print_warn "⚠️  Warning: Target version ${target_version} is older than installed version ${installed_version}"
            print_warn "This would be a DOWNGRADE!"
            if [ "${RHACS_FORCE_DOWNGRADE:-false}" != "true" ]; then
                print_error "Refusing to downgrade. To force: export RHACS_FORCE_DOWNGRADE=true"
                print_info "Keeping current version: ${installed_version}"
                return 0
            fi
            print_warn "RHACS_FORCE_DOWNGRADE=true - proceeding with downgrade..."
        fi
    fi
    
    # Proceed with update to target
    print_info "Current version ${installed_version} -> Target version ${target_version}"
    update_rhacs_version "${target_version}"
}

# Map target minor version to operator channel (e.g. 4.11 -> rhacs-4.11)
# Red Hat catalog uses rhacs-4.x channel names.
get_channel_for_version() {
    local ver=$1
    local major_minor=""
    if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
        major_minor="${BASH_REMATCH[1]}"
        echo "rhacs-${major_minor}"
    else
        local catalog_minor
        catalog_minor=$(get_latest_catalog_minor_version)
        if [ -n "${catalog_minor}" ]; then
            echo "rhacs-${catalog_minor}"
        else
            print_warn "Could not map version '${ver}' to a channel; using rhacs-${ver}"
            echo "rhacs-${ver}"
        fi
    fi
}

# Get RHACS subscription name using subscriptions.operators.coreos.com (required for oc to find it).
# Returns subscription name (e.g. rhacs-operator) or empty if not found.
get_rhacs_subscription_name() {
    oc get subscriptions.operators.coreos.com -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].metadata.name}' 2>/dev/null || echo ""
}

# Ensure operator subscription channel is set for target version (e.g. 4.10 -> rhacs-4.10).
# Uses subscriptions.operators.coreos.com - the correct resource name for oc.
ensure_subscription_channel_for_version() {
    local target_version=$1
    local desired_channel
    desired_channel=$(get_channel_for_version "${target_version}")
    local sub_name
    sub_name=$(get_rhacs_subscription_name)
    if [ -z "${sub_name}" ]; then
        print_info "No RHACS subscription found in ${RHACS_OPERATOR_NAMESPACE}; skipping subscription channel update"
        return 0
    fi
    local current_channel
    current_channel=$(oc get subscriptions.operators.coreos.com "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    if [ "${current_channel}" = "${desired_channel}" ]; then
        print_info "Subscription already on channel: ${desired_channel}"
        return 0
    fi
    print_step "Setting subscription channel: ${current_channel:-unknown} -> ${desired_channel} for version ${target_version}..."
    if ! oc patch subscriptions.operators.coreos.com "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/channel\",\"value\":\"${desired_channel}\"}]" 2>/dev/null; then
        print_warn "Could not set subscription channel to ${desired_channel}"
        return 1
    fi
    print_info "Waiting for operator to reconcile to ${desired_channel}, 60s..."
    sleep 60
    return 0
}

# Get the name of the Central CR in RHACS_NAMESPACE (e.g. "central" or "stackrox-central-services").
# Empty if no Central CR exists.
get_central_cr_name() {
    oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Function to update RHACS version
update_rhacs_version() {
    local target_version=$1
    
    print_info "Updating RHACS to version ${target_version}..."
    
    # Discover Central CR name (operator may use "central" or "stackrox-central-services")
    local central_cr_name
    central_cr_name=$(get_central_cr_name)
    
    if [ -n "${central_cr_name}" ]; then
        print_info "Updating Central resource (${central_cr_name})..."
        
        # Ensure subscription channel is set for target version (so operator can provide it)
        ensure_subscription_channel_for_version "${target_version}" || true
        
        # Get current Central spec
        local current_image
        current_image=$(oc get central "${central_cr_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.image}' 2>/dev/null || echo "")
        
        if [ -n "${current_image}" ]; then
            # Update image tag
            local image_repo
            image_repo=$(echo "${current_image}" | sed 's/:.*//')
            oc patch central "${central_cr_name}" -n "${RHACS_NAMESPACE}" --type=json -p="[
                {\"op\": \"replace\", \"path\": \"/spec/central/image\", \"value\": \"${image_repo}:${target_version}\"}
            ]" || {
                print_error "Failed to update Central image"
                return 1
            }
        else
            # No image in spec: operator manages rollout via subscription/CSV channel
            print_info "Central has no custom image; operator will rollout from channel/CSV"
        fi
        
        print_info "Waiting for update to complete..."
        # Poll until deployment reaches target version and rollout completes
        local target_major_minor="${target_version}"
        [[ "${target_version}" =~ ^([0-9]+\.[0-9]+) ]] && target_major_minor="${BASH_REMATCH[1]}"
        local max_wait=600
        local elapsed=0
        local current_ver=""
        while [ $elapsed -lt $max_wait ]; do
            current_ver=$(get_installed_version)
            if [ -n "${current_ver}" ]; then
                local current_major_minor="${current_ver}"
                [[ "${current_ver}" =~ ^([0-9]+\.[0-9]+) ]] && current_major_minor="${BASH_REMATCH[1]}"
                if [ "${current_major_minor}" = "${target_major_minor}" ]; then
                    # Version matches; ensure rollout is complete
                    if oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=60s 2>/dev/null; then
                        print_info "✓ Central at target version ${current_ver}, rollout complete"
                        break
                    fi
                fi
            fi
            oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=30s 2>/dev/null || true
            sleep 15
            ((elapsed+=15))
        done
        if [ $elapsed -ge $max_wait ]; then
            print_warn "Timeout waiting for version ${target_version}. Current: $(get_installed_version). Check: oc get central -n ${RHACS_NAMESPACE} && oc get pods -n ${RHACS_NAMESPACE}"
        fi
        
        print_info "✓ RHACS update initiated"
    else
        # No Central CR: try subscription channel first, then CSV deploy details
        if [ -n "$(get_rhacs_subscription_name)" ]; then
            print_info "Central CR not found; updating subscription channel to ${target_version}..."
            if ! ensure_subscription_channel_for_version "${target_version}"; then
                print_error "Failed to update subscription channel"
                return 1
            fi
        else
            print_info "Central CR not found; updating CSV deploy details to ${target_version}..."
            if ! ensure_csv_deploy_version "${target_version}"; then
                print_error "Failed to update CSV deploy details"
                return 1
            fi
        fi
        print_info "Waiting for deployment rollout to complete..."
        oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=600s || {
            print_warn "Rollout may still be in progress. Check: oc get pods -n ${RHACS_NAMESPACE}"
        }
        print_info "✓ RHACS update initiated"
    fi
    
    # Verify new version
    sleep 10
    local new_version=$(get_installed_version)
    if [ -n "${new_version}" ] && [ "${new_version}" != "unknown" ]; then
        print_info "Current version after update: ${new_version}"
    fi
}

# Function to ensure RHACS OpenShift Console plugin is enabled
# On the Install Operator page, the Console plugin option should be set to Enable.
# This function ensures the plugin is enabled in the Console operator config (idempotent).
ensure_rhacs_console_plugin_enabled() {
    print_step "Ensuring RHACS Console plugin is enabled..."

    if ! oc get consoles.operator.openshift.io cluster &>/dev/null; then
        print_warn "Console operator resource not found; skipping Console plugin enablement"
        return 0
    fi

    # Find the RHACS ConsolePlugin name (operator may create "acs" or similar)
    local plugin_name=""
    if command -v jq &>/dev/null && oc get consoleplugins -o json &>/dev/null; then
        plugin_name=$(oc get consoleplugins -o json 2>/dev/null | jq -r '
            .items[] | select(
                .metadata.name == "acs" or
                .metadata.name == "rhacs" or
                (.spec.displayName != null and (
                    (.spec.displayName | ascii_downcase | test("advanced cluster security")) or
                    (.spec.displayName | ascii_downcase | test("rhacs"))
                ))
            ) | .metadata.name
        ' 2>/dev/null | head -1)
    fi

    if [ -z "${plugin_name}" ]; then
        # Fallback: try common name used by RHACS operator
        if oc get consoleplugin acs &>/dev/null; then
            plugin_name="acs"
        fi
    fi

    if [ -z "${plugin_name}" ]; then
        print_warn "RHACS ConsolePlugin not found; operator may not register a console plugin in this version; skipping"
        return 0
    fi

    local current_plugins
    current_plugins=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
    if echo "${current_plugins}" | tr ' ' '\n' | grep -q "^${plugin_name}$"; then
        print_info "✓ RHACS Console plugin '${plugin_name}' is already enabled"
        return 0
    fi

    # Build new plugins array: existing + RHACS plugin
    local new_plugins_json
    local current_json
    current_json=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
    if [ -z "${current_json}" ] || [ "${current_json}" = "[]" ]; then
        new_plugins_json="[\"${plugin_name}\"]"
    elif command -v jq &>/dev/null; then
        new_plugins_json=$(echo "${current_json}" | jq --arg p "${plugin_name}" '. + [$p] | unique' -c 2>/dev/null || echo "[\"${plugin_name}\"]")
    else
        # Without jq: append to existing JSON array (e.g. ["a","b"] -> ["a","b","acs"])
        new_plugins_json="${current_json%]},\"${plugin_name}\"]"
    fi

    if oc patch consoles.operator.openshift.io cluster --type=merge -p '{"spec":{"plugins":'"${new_plugins_json}"'}}' 2>/dev/null; then
        print_info "✓ RHACS Console plugin '${plugin_name}' enabled in OpenShift Console"
    else
        print_warn "Could not patch Console to enable plugin '${plugin_name}'; may require cluster-admin"
    fi
}

# Verify RHACS 4.11+ operand images use rhel9 base (release notes 1.10).
verify_rhel9_operand_images() {
    print_step "Verifying RHACS operand images (rhel9)..."

    if ! command -v jq &>/dev/null; then
        print_warn "jq not found; skipping rhel9 image validation"
        return 0
    fi

    local installed_version
    installed_version=$(get_installed_version)
    local installed_minor="${installed_version}"
    [[ "${installed_version}" =~ ^([0-9]+\.[0-9]+) ]] && installed_minor="${BASH_REMATCH[1]}"

    if [ -n "${installed_minor}" ] && [ "$(printf '%s\n' "4.11" "${installed_minor}" | sort -V | head -n1)" != "4.11" ]; then
        print_info "Installed RHACS ${installed_version} is below 4.11; skipping rhel9 image tag check"
        return 0
    fi

    local deployments=("central" "sensor" "admission-control")
    local missing_rhel9=0
    local dep image

    for dep in "${deployments[@]}"; do
        if ! oc get deployment "${dep}" -n "${RHACS_NAMESPACE}" &>/dev/null; then
            continue
        fi
        image=$(oc get deployment "${dep}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
        if [ -z "${image}" ]; then
            continue
        fi
        if echo "${image}" | grep -qE 'rhel9|rhacs-.*-rhel9'; then
            print_info "✓ ${dep} image uses rhel9: ${image}"
        else
            print_warn "⚠ ${dep} image may not be rhel9-based: ${image}"
            missing_rhel9=$((missing_rhel9 + 1))
        fi
    done

    if [ "${missing_rhel9}" -gt 0 ]; then
        print_warn "Some deployments are not on rhel9 image tags; expected for RHACS 4.11+ (see release notes 1.10)"
    fi
    return 0
}

# Main function
main() {
    print_info "RHACS Installation Verification"
    print_info "================================="
    
    # Verify RHACS installation
    if ! verify_rhacs_installation; then
        print_error "RHACS installation verification failed"
        exit 1
    fi
    
    print_info ""
    
    # Verify route encryption
    if ! verify_route_encryption; then
        print_error "Route encryption verification failed"
        exit 1
    fi
    
    print_info ""
    
    # Check and update version to newest catalog release (or RHACS_VERSION pin) before Console plugin
    check_and_update_version
    
    print_info ""
    
    # Ensure Console plugin is enabled after version update (Install Operator page: Console plugin = Enable)
    ensure_rhacs_console_plugin_enabled

    print_info ""

    verify_rhel9_operand_images

    print_info ""
    print_info "================================="
    print_info "✓ RHACS verification complete!"
    print_info "================================="
}

# Run main function
main "$@"
