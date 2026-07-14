#!/bin/bash
#
# RHACS Monitoring Setup - Main Installation Script
# Orchestrates the complete monitoring setup by calling individual setup scripts
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../rhacs/lib/common.sh"
# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get the script directory and ensure we're in it
cd "$SCRIPT_DIR"


#================================================================
# Utility Functions
#================================================================

# Strip https:// from ROX_CENTRAL_ADDRESS for roxctl -e flag
# roxctl expects host:port format and defaults to https
#
# Usage:
#   ROX_ENDPOINT=$(get_rox_endpoint)
#   roxctl -e "$ROX_ENDPOINT" --token "$ROX_API_TOKEN" central userpki list ...
#
# Example:
#   If ROX_CENTRAL_ADDRESS="https://central-stackrox.apps.cluster.com"
#   Then get_rox_endpoint returns "central-stackrox.apps.cluster.com"
get_rox_endpoint() {
    local url="${ROX_CENTRAL_ADDRESS:-}"
    # Remove https:// prefix if present
    url="${url#https://}"
    url="${url#http://}"
    echo "${url}"
}

# Load ROX_* from ~/.bashrc without executing $(...) (avoids hangs / surprises).
# Use || true on grep so missing lines do not abort under set -e + pipefail.
# Echo a copy-paste command to retry after a failed sub-script.
print_rerun() {
  log "To rerun this step: bash \"$1\""
}

load_rox_from_bashrc() {
    [ ! -f ~/.bashrc ] && return 0
    local var line
    for var in ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE; do
        line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1) || true
        [ -z "$line" ] && continue
        if grep -qE '\$\(|`' <<< "$line"; then
            warn "Skipping ${var} from ~/.bashrc (command substitution) — export ${var} in this shell or use a literal value."
            continue
        fi
        [[ "$line" =~ ^export[[:space:]]+ ]] || line="export $line"
        eval "$line" 2>/dev/null || true
    done
}

#================================================================
# Pre-flight Checks
#================================================================

echo ""
echo "=============================================="
echo "  RHACS Monitoring Setup"
echo "=============================================="
echo ""

log "Starting installation..."
echo ""

# Load ROX_* from ~/.bashrc if not already set (non-interactive shells do not source ~/.bashrc)
load_rox_from_bashrc

# Check required environment variables
MISSING_VARS=0

if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
  error "ROX_CENTRAL_ADDRESS is not set"
  MISSING_VARS=$((MISSING_VARS + 1))
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
  error "ROX_API_TOKEN is not set"
  MISSING_VARS=$((MISSING_VARS + 1))
fi

if [ $MISSING_VARS -gt 0 ]; then
  echo ""
  error "Missing required environment variables. Please set them and try again."
  echo ""
  echo "Example:"
  echo "  export ROX_CENTRAL_ADDRESS='https://central-stackrox.apps.cluster.com'"
  echo "  export ROX_API_TOKEN='your-api-token'"
  echo ""
  log "Then rerun: bash \"$SCRIPT_DIR/install.sh\""
  exit 1
fi

log "✓ Required environment variables are set"
# Roadshow persists host-only ROX_CENTRAL_ADDRESS; curl/API need https://
export ROX_CENTRAL_ADDRESS="$(rox_central_url)"
log "Using ROX_CENTRAL_ADDRESS=${ROX_CENTRAL_ADDRESS}"
echo ""

#================================================================
# Step 1: Setup Certificates
#================================================================

step "Step 1 of 3: Setting up certificates"
echo ""

if [ ! -x "$SCRIPT_DIR/01-setup-certificates.sh" ]; then
  chmod +x "$SCRIPT_DIR/01-setup-certificates.sh"
fi

if "$SCRIPT_DIR/01-setup-certificates.sh"; then
  log "✓ Certificate setup complete"
else
  error "Certificate setup failed"
  print_rerun "$SCRIPT_DIR/01-setup-certificates.sh"
  exit 1
fi

# Load certificate environment
if [ -f "$SCRIPT_DIR/.env.certs" ]; then
  source "$SCRIPT_DIR/.env.certs"
fi

#================================================================
# Step 2: Install Monitoring Stack
#================================================================

step "Step 2 of 3: Installing monitoring stack"
echo ""

if [ ! -x "$SCRIPT_DIR/02-install-monitoring.sh" ]; then
  chmod +x "$SCRIPT_DIR/02-install-monitoring.sh"
fi

if "$SCRIPT_DIR/02-install-monitoring.sh"; then
  log "✓ Monitoring stack installation complete"
else
  error "Monitoring stack installation failed"
  print_rerun "$SCRIPT_DIR/02-install-monitoring.sh"
  exit 1
fi

#================================================================
# Step 3: Configure RHACS Authentication
#================================================================

step "Step 3 of 3: Configuring RHACS authentication"
echo ""

if [ ! -x "$SCRIPT_DIR/03-configure-rhacs-auth.sh" ]; then
  chmod +x "$SCRIPT_DIR/03-configure-rhacs-auth.sh"
fi

if "$SCRIPT_DIR/03-configure-rhacs-auth.sh"; then
  log "✓ RHACS authentication configuration complete"
else
  error "RHACS authentication configuration failed"
  print_rerun "$SCRIPT_DIR/03-configure-rhacs-auth.sh"
  exit 1
fi

#================================================================
# Verification
#================================================================

echo ""
echo "============================================"
echo "Verifying Configuration"
echo "============================================"
echo ""

# Non-login shells do not source ~/.bashrc; sub-scripts do not export back to this shell.
log "Loading ROX_CENTRAL_ADDRESS / ROX_API_TOKEN from ~/.bashrc before verification..."
load_rox_from_bashrc
if [ -n "${ROX_CENTRAL_ADDRESS:-}" ] && [ -n "${ROX_API_TOKEN:-}" ]; then
  export ROX_CENTRAL_ADDRESS ROX_API_TOKEN
fi

if [ -z "${ROX_CENTRAL_ADDRESS:-}" ] || [ -z "${ROX_API_TOKEN:-}" ]; then
  warn "Skipping API/metrics verification — ROX_CENTRAL_ADDRESS or ROX_API_TOKEN not set after reading ~/.bashrc."
  warn "Run: source ~/.bashrc   then export or re-run this script."
else
  # Give auth system time to propagate changes
  log "Waiting for auth configuration to propagate (10 seconds)..."
  sleep 10

# Extract auth provider ID (set by 03-configure-rhacs-auth.sh)
if [ -z "${AUTH_PROVIDER_ID:-}" ]; then
  # Try to get it from the API
  if command -v jq &>/dev/null; then
    AUTH_PROVIDER_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
      -H "Authorization: Bearer $ROX_API_TOKEN" | \
      jq -r '.authProviders[]? | select(.name=="Monitoring") | .id' 2>/dev/null)
  else
    AUTH_PROVIDER_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
      -H "Authorization: Bearer $ROX_API_TOKEN" | \
      grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)
  fi
fi

# Verify the group was created
log "Checking groups for auth provider..."
GROUPS_LIST=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/groups" | grep -A5 "$AUTH_PROVIDER_ID" || echo "")

if [ -n "$GROUPS_LIST" ]; then
  log "✓ Group mapping found for Monitoring auth provider"
  
  # Test client certificate authentication
  echo ""
  log "Testing client certificate authentication..."
  AUTH_TEST=$(curl -k -s --cert client.crt --key client.key "$ROX_CENTRAL_ADDRESS/v1/auth/status" 2>&1)
  
  if echo "$AUTH_TEST" | grep -q '"userId"'; then
    log "✓ Client certificate authentication successful!"
    
    # Also test metrics endpoint (disable set -e for this block - curl|head can cause SIGPIPE)
    echo ""
    log "Testing metrics endpoint access..."
    set +e
    METRICS_TEST=$(curl -k -s --max-time 30 --cert client.crt --key client.key "$ROX_CENTRAL_ADDRESS/metrics" 2>&1 | head -10)
    set -e

    if echo "$METRICS_TEST" | grep -q "access for this user is not authorized"; then
      error "✗ Metrics endpoint access denied: no valid role"
      echo ""
      error "The group mapping exists but the role assignment is incorrect."
      error "Run the troubleshooting script to fix:"
      echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
    elif echo "$METRICS_TEST" | grep -q '^curl:'; then
      warn "Metrics curl failed (bad URL or network). Ensure ROX_CENTRAL_ADDRESS is set: source ~/.bashrc"
      echo "$METRICS_TEST"
    elif echo "$METRICS_TEST" | grep -q '^#'; then
      log "✓ Metrics endpoint access successful!"
    else
      warn "Metrics endpoint returned unexpected response (first 10 lines):"
      echo "$METRICS_TEST"
    fi
  elif echo "$AUTH_TEST" | grep -q "credentials not found"; then
    warn "Authentication failed: credentials not found"
    echo ""
    warn "This may take 10-30 seconds to propagate. Wait a moment and try:"
    echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_ADDRESS/v1/auth/status"
    echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_ADDRESS/metrics"
    echo ""
    warn "If it continues to fail, run the troubleshooting script:"
    echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
  else
    warn "Unexpected response: $AUTH_TEST"
  fi
else
  warn "No group mapping found - authentication may fail!"
  echo ""
  warn "Run the troubleshooting script to diagnose and fix:"
  echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
fi

fi

#================================================================
# Installation Complete
#================================================================


echo ""
echo "============================================"
echo "Installation Complete!"
echo "============================================"
echo ""
echo "Certificates created in: $SCRIPT_DIR/"
echo "  - ca.crt / ca.key          (CA certificate - configured in auth provider)"
echo "  - client.crt / client.key  (Client certificate - use for API calls)"
echo ""
echo "Test authentication:"
echo "  cd $SCRIPT_DIR && curl --cert client.crt --key client.key -k \$ROX_CENTRAL_ADDRESS/metrics"
echo ""
echo ""
echo "Note: Auth changes may take 10-30 seconds to propagate."
echo ""

# Clean up temporary environment file
rm -f "$SCRIPT_DIR/.env.certs"