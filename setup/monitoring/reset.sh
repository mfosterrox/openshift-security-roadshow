#!/bin/bash
#
# RHACS Monitoring Reset Script
# Removes all monitoring resources created by install.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../rhacs/lib/common.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
NAMESPACE="${NAMESPACE:-stackrox}"
EXAMPLES_DIR="$SCRIPT_DIR/monitoring-examples"

# Detect kubectl/oc
if command -v oc &>/dev/null; then
    KUBE_CMD="oc"
else
    KUBE_CMD="kubectl"
fi

echo ""
step "RHACS Monitoring Cleanup"
echo "=========================================="
echo "This will remove all monitoring resources from namespace: $NAMESPACE"
echo "=========================================="
echo ""

# Confirm with user
read -p "Are you sure you want to proceed? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
    log "Cleanup cancelled."
    exit 0
fi

echo ""

#================================================================
# 1. Remove Perses Resources
#================================================================
step "Step 1: Removing Perses resources"
echo ""

# Delete using the exact YAML files used during installation
log "Deleting Perses Dashboard..."
if [ -f "$EXAMPLES_DIR/perses/dashboard.yaml" ]; then
    $KUBE_CMD delete -f "$EXAMPLES_DIR/perses/dashboard.yaml" 2>/dev/null && log "✓ Perses Dashboard deleted" || log "✓ Perses Dashboard not found"
else
    warning "dashboard.yaml not found at $EXAMPLES_DIR/perses/"
fi

log "Deleting Perses Datasource..."
if [ -f "$EXAMPLES_DIR/perses/datasource.yaml" ]; then
    $KUBE_CMD delete -f "$EXAMPLES_DIR/perses/datasource.yaml" 2>/dev/null && log "✓ Perses Datasource deleted" || log "✓ Perses Datasource not found"
else
    warning "datasource.yaml not found at $EXAMPLES_DIR/perses/"
fi

log "Deleting Perses UI Plugin..."
if [ -f "$EXAMPLES_DIR/perses/ui-plugin.yaml" ]; then
    $KUBE_CMD delete -f "$EXAMPLES_DIR/perses/ui-plugin.yaml" 2>/dev/null && log "✓ Perses UI Plugin deleted" || log "✓ Perses UI Plugin not found"
else
    warning "ui-plugin.yaml not found at $EXAMPLES_DIR/perses/"
fi

echo ""

#================================================================
# 2. Remove ScrapeConfig
#================================================================
step "Step 2: Removing ScrapeConfig"
echo ""

log "Deleting ScrapeConfig..."
if [ -f "$EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml" ]; then
    $KUBE_CMD delete -f "$EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml" 2>/dev/null && \
        log "✓ ScrapeConfig deleted" || log "✓ ScrapeConfig not found"
else
    warning "scrape-config.yaml not found at $EXAMPLES_DIR/cluster-observability-operator/"
fi

echo ""

#================================================================
# 3. Remove MonitoringStack
#================================================================
step "Step 3: Removing MonitoringStack"
echo ""

log "Deleting MonitoringStack..."
if [ -f "$EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml" ]; then
    $KUBE_CMD delete -f "$EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml" 2>/dev/null && {
        log "✓ MonitoringStack deleted"
        log "Waiting for Prometheus pods to terminate..."
        sleep 10
    } || log "✓ MonitoringStack not found"
else
    warning "monitoring-stack.yaml not found at $EXAMPLES_DIR/cluster-observability-operator/"
fi

echo ""

#================================================================
# 4. Remove Secrets
#================================================================
step "Step 4: Removing monitoring secrets"
echo ""

# TLS secret (created by install.sh via kubectl create secret)
SECRET_NAME="sample-$NAMESPACE-prometheus-tls"
if $KUBE_CMD get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Deleting TLS secret: $SECRET_NAME"
    $KUBE_CMD delete secret "$SECRET_NAME" -n "$NAMESPACE" 2>/dev/null && \
        log "✓ TLS secret deleted" || warning "Failed to delete TLS secret"
else
    log "✓ TLS secret not found"
fi

# API token secret (if exists - not created by current install.sh)
TOKEN_SECRET_NAME="$NAMESPACE-prometheus-api-token"
if $KUBE_CMD get secret "$TOKEN_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Deleting API token secret: $TOKEN_SECRET_NAME"
    $KUBE_CMD delete secret "$TOKEN_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null && \
        log "✓ API token secret deleted" || warning "Failed to delete API token secret"
else
    log "✓ API token secret not found"
fi

echo ""

#================================================================
# 5. Remove RHACS Declarative Configuration
#================================================================
step "Step 5: Removing RHACS declarative configuration"
echo ""

log "Deleting declarative configuration ConfigMap..."
if [ -f "$EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml" ]; then
    $KUBE_CMD delete -f "$EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml" 2>/dev/null && \
        log "✓ Declarative configuration deleted" || log "✓ Declarative configuration not found"
else
    warning "declarative-configuration-configmap.yaml not found at $EXAMPLES_DIR/rhacs/"
fi

echo ""

#================================================================
# 6. Remove Auth Provider and Groups (requires API access)
#================================================================
step "Step 6: Removing User-Certificate auth provider and groups"
echo ""

if [ -n "${ROX_CENTRAL_ADDRESS:-}" ] && [ -n "${ROX_API_TOKEN:-}" ]; then
    log "Searching for 'Monitoring' auth provider..."
    
    # Get list of auth providers
    AUTH_PROVIDERS=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
        "$ROX_CENTRAL_ADDRESS/v1/authProviders" 2>/dev/null || echo "")
    
    if echo "$AUTH_PROVIDERS" | grep -q '"name":"Monitoring"'; then
        PROVIDER_ID=$(echo "$AUTH_PROVIDERS" | jq -r '.authProviders[] | select(.name=="Monitoring") | .id' 2>/dev/null || \
            echo "$AUTH_PROVIDERS" | grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)
        
        if [ -n "$PROVIDER_ID" ]; then
            log "Found auth provider 'Monitoring' (ID: $PROVIDER_ID)"
            
            # First, delete associated groups
            log "Searching for groups associated with this auth provider..."
            GROUPS=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
                "$ROX_CENTRAL_ADDRESS/v1/groups" 2>/dev/null || echo "")
            
            if echo "$GROUPS" | grep -q "$PROVIDER_ID"; then
                log "Found associated groups, deleting..."
                # Extract group IDs and delete them
                GROUP_IDS=$(echo "$GROUPS" | jq -r ".groups[] | select(.props.authProviderId==\"$PROVIDER_ID\") | .props.id" 2>/dev/null || echo "")
                if [ -n "$GROUP_IDS" ]; then
                    echo "$GROUP_IDS" | while read -r group_id; do
                        if [ -n "$group_id" ]; then
                            log "  Deleting group: $group_id"
                            curl -k -s -X DELETE \
                                -H "Authorization: Bearer $ROX_API_TOKEN" \
                                "$ROX_CENTRAL_ADDRESS/v1/groups/$group_id" >/dev/null 2>&1
                        fi
                    done
                    log "✓ Associated groups deleted"
                fi
            else
                log "✓ No associated groups found"
            fi
            
            # Now delete the auth provider
            log "Deleting auth provider..."
            DELETE_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X DELETE \
                -H "Authorization: Bearer $ROX_API_TOKEN" \
                "$ROX_CENTRAL_ADDRESS/v1/authProviders/$PROVIDER_ID" 2>&1)
            
            HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -1)
            if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
                log "✓ Auth provider deleted"
            else
                warning "Failed to delete auth provider (HTTP $HTTP_CODE)"
                warning "You may need to delete it manually in RHACS UI:"
                warning "  Platform Configuration → Access Control → Auth Providers"
            fi
        else
            log "✓ Auth provider 'Monitoring' not found"
        fi
    else
        log "✓ Auth provider 'Monitoring' not found"
    fi
else
    warning "ROX_CENTRAL_ADDRESS or ROX_API_TOKEN not set"
    warning "Skipping auth provider and groups deletion"
    warning "You may need to delete them manually in RHACS UI:"
    warning "  Platform Configuration → Access Control → Auth Providers → Delete 'Monitoring'"
    warning "  Platform Configuration → Access Control → Groups → Delete groups for 'Monitoring'"
fi

echo ""

#================================================================
# 7. Clean up local files
#================================================================
step "Step 7: Cleaning up local certificate files"
echo ""

cd "$SCRIPT_DIR"

# List of certificate files to remove
CERT_FILES=(
    "ca.crt"
    "ca.key"
    "ca.srl"
    "client.crt"
    "client.key"
    "client.csr"
    "tls.crt"      # Legacy files from older install script
    "tls.key"      # Legacy files from older install script
)

FILES_REMOVED=0
for cert_file in "${CERT_FILES[@]}"; do
    if [ -f "$cert_file" ]; then
        log "Removing $cert_file..."
        rm -f "$cert_file"
        FILES_REMOVED=$((FILES_REMOVED + 1))
    fi
done

if [ $FILES_REMOVED -gt 0 ]; then
    log "✓ $FILES_REMOVED certificate file(s) removed"
else
    log "✓ No certificate files found"
fi

echo ""

#================================================================
# 8. Optional: Remove Cluster Observability Operator
#================================================================
step "Step 8: Cluster Observability Operator (optional)"
echo ""

warning "The Cluster Observability Operator is still installed."
warning "This is intentional as it may be used by other monitoring stacks."
echo ""
warning "To COMPLETELY remove the operator (if you're sure), run:"
echo ""
echo "  oc delete -f $EXAMPLES_DIR/cluster-observability-operator/subscription.yaml"
echo "  oc delete namespace openshift-cluster-observability-operator"
echo ""
log "Operator will continue running but will not manage any resources in $NAMESPACE"

echo ""

#================================================================
# Summary
#================================================================
step "Cleanup Complete!"
echo "=========================================="
echo ""
echo "✓ Perses resources removed (dashboard, datasource, UI plugin)"
echo "✓ ScrapeConfig removed"
echo "✓ MonitoringStack removed"
echo "✓ Secrets removed (TLS, API tokens)"
echo "✓ Declarative configuration removed"
echo "✓ Auth provider and groups removed (if ROX_API_TOKEN was set)"
echo "✓ Local certificate files removed (CA and client certs)"
echo ""
echo "⚠️  Cluster Observability Operator still installed (see above to remove)"
echo ""
echo "Namespace '$NAMESPACE' is now clean of monitoring resources."
echo ""
echo "To reinstall monitoring, run:"
echo "  cd $SCRIPT_DIR"
echo "  ./install.sh"
echo ""
log "Reset completed successfully!"
echo ""
