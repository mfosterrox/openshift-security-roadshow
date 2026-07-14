#!/bin/bash
#
# RHACS Monitoring Setup - RHACS Authentication Configuration
# Configures declarative configuration and creates auth provider with groups
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

# True if RHACS rejected the group because the declarative role is not loaded yet (wording varies by version)
is_role_not_ready_error() {
  echo "$1" | grep -qiE 'role.*(does not exist|not found)|unknown role|invalid role|no role named|could not find role|cannot find role|invalid.*roleName|roleName.*(invalid|unknown)'
}

# Poll until GET /v1/roles includes "Prometheus Server" (declarative config processed)
wait_for_prometheus_server_role() {
  local max_s="${1:-600}"
  local slept=0
  local interval=15
  log "Waiting for declarative role 'Prometheus Server' in RHACS API (GET /v1/roles, up to ${max_s}s)..."
  while [ "$slept" -lt "$max_s" ]; do
    local roles_json http_code
    roles_json=$(curl -k -s -w "\n%{http_code}" --max-time 30 \
      -H "Authorization: Bearer $ROX_API_TOKEN" \
      "$ROX_CENTRAL_ADDRESS/v1/roles" 2>/dev/null) || true
    http_code=$(echo "$roles_json" | tail -n1)
    roles_json=$(echo "$roles_json" | sed '$d')
    if ! echo "$http_code" | grep -qE '^2'; then
      warn "  /v1/roles HTTP ${http_code} — retrying..."
    elif command -v jq &>/dev/null; then
      if echo "$roles_json" | jq -e '.roles[]? | select(.name == "Prometheus Server")' &>/dev/null; then
        log "✓ Role 'Prometheus Server' is available"
        return 0
      fi
    elif echo "$roles_json" | grep -q '"name"[[:space:]]*:[[:space:]]*"Prometheus Server"'; then
      log "✓ Role 'Prometheus Server' is available (grep fallback)"
      return 0
    fi
    log "  Declarative role not visible yet... (${slept}s / ${max_s}s)"
    sleep "$interval"
    slept=$((slept + interval))
  done
  warn "Timed out waiting for 'Prometheus Server' role — proceeding with group POST retries only"
  return 1
}

# Strip last line (curl http_code); portable (no GNU head -n -1)
strip_curl_http_line() {
  sed '$d'
}

# Get the script directory
cd "$SCRIPT_DIR"

step "RHACS Authentication Configuration"
echo "=========================================="
echo ""

# Check required environment variables
if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
  error "ROX_CENTRAL_ADDRESS is not set"
  exit 1
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
  error "ROX_API_TOKEN is not set"
  exit 1
fi

# Roadshow persists host-only ROX_CENTRAL_ADDRESS; curl/API need https://
export ROX_CENTRAL_ADDRESS="$(rox_central_url)"

# Load TLS_CERT from certificate generation script
if [ -f "$SCRIPT_DIR/.env.certs" ]; then
  source "$SCRIPT_DIR/.env.certs"
else
  warn ".env.certs not found, loading TLS_CERT from ca.crt..."
  if [ -f "$SCRIPT_DIR/ca.crt" ]; then
    export TLS_CERT=$(awk '{printf "%s\\n", $0}' ca.crt)
  else
    error "ca.crt not found. Run 01-setup-certificates.sh first."
    exit 1
  fi
fi

log "Declaring a permission set and a role in RHACS..."

# First, create the declarative configuration ConfigMap
oc apply -f monitoring-examples/rhacs/declarative-configuration-configmap.yaml
log "✓ Declarative configuration ConfigMap created"

echo ""
log "Checking if declarative configuration is enabled on Central..."
if oc get deployment central -n stackrox -o yaml | grep -q "declarative-config"; then
  log "✓ Declarative configuration is already enabled"
else
  warn "Declarative configuration mount not found on Central deployment"
  log "Enabling declarative configuration on Central..."
  
  # Check if Central is managed by operator or deployed directly
  if oc get central stackrox-central-services -n stackrox &>/dev/null; then
    log "Using RHACS Operator to enable declarative configuration..."
    oc patch central stackrox-central-services -n stackrox --type=merge -p='
spec:
  central:
    declarativeConfiguration:
      configMaps:
      - name: sample-stackrox-prometheus-declarative-configuration
'
    log "Waiting for Central to update..."
    sleep 10
  else
    log "Directly patching Central deployment..."
    # For non-operator deployments, manually add volume and mount
    oc set volume deployment/central -n stackrox \
      --add --name=declarative-config \
      --type=configmap \
      --configmap-name=sample-stackrox-prometheus-declarative-configuration \
      --mount-path=/run/secrets/stackrox.io/declarative-config \
      --read-only=true
  fi
  
  log "Waiting for Central to restart..."
  oc rollout status deployment/central -n stackrox --timeout=300s
  log "✓ Declarative configuration enabled"
fi

# Give Central time to process declarative config (roles) after startup
log "Waiting for declarative config to be processed (30s)..."
sleep 30

# Wait for Central API to be ready (may take a moment after restart)
log "Checking Central API readiness..."
for i in $(seq 1 30); do
  if code=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "$ROX_CENTRAL_ADDRESS/v1/auth/status" -H "Authorization: Bearer $ROX_API_TOKEN") && echo "$code" | grep -qE "^[234][0-9]{2}$"; then
    log "Central API is ready"
    break
  fi
  [ $i -lt 30 ] && sleep 2
done

echo ""
log "Checking for existing 'Monitoring' auth provider..."

# Get all auth providers and extract the ID for "Monitoring"
if command -v jq &>/dev/null; then
  EXISTING_AUTH_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" | \
    jq -r '.authProviders[]? | select(.name=="Monitoring") | .id' 2>/dev/null) || EXISTING_AUTH_ID=""
else
  EXISTING_AUTH_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" | \
    grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4) || EXISTING_AUTH_ID=""
fi

# Delete if exists
if [ -n "$EXISTING_AUTH_ID" ] && [ "$EXISTING_AUTH_ID" != "null" ]; then
  log "Deleting existing 'Monitoring' auth provider (ID: $EXISTING_AUTH_ID)..."
  curl -k -s -X DELETE "$ROX_CENTRAL_ADDRESS/v1/authProviders/$EXISTING_AUTH_ID" \
    -H "Authorization: Bearer $ROX_API_TOKEN" > /dev/null
  log "✓ Deleted existing auth provider"
  sleep 2
fi

echo ""
log "Creating User-Certificate auth provider..."
# Central may need a moment after restart - retry auth provider creation if it fails
AUTH_PROVIDER_ID=""
max_auth_retries=4
auth_retry_delay=20
for auth_attempt in $(seq 1 $max_auth_retries); do
  AUTH_PROVIDER_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$(envsubst < monitoring-examples/rhacs/auth-provider.json.tpl)")

  HTTP_CODE=$(echo "$AUTH_PROVIDER_RESPONSE" | tail -1)
  AUTH_RESPONSE_BODY=$(echo "$AUTH_PROVIDER_RESPONSE" | strip_curl_http_line)

  # Extract the auth provider ID from the response (try multiple patterns)
  AUTH_PROVIDER_ID=$(echo "$AUTH_RESPONSE_BODY" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' 2>/dev/null) || true

  if [ -z "$AUTH_PROVIDER_ID" ] && command -v jq &>/dev/null; then
    AUTH_PROVIDER_ID=$(echo "$AUTH_RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null)
  fi

  if [ -n "$AUTH_PROVIDER_ID" ] && [ "$AUTH_PROVIDER_ID" != "null" ]; then
    export AUTH_PROVIDER_ID
    break
  fi
  if [ $auth_attempt -lt $max_auth_retries ]; then
    warn "Auth provider creation failed or API not ready (HTTP $HTTP_CODE) - retrying in ${auth_retry_delay}s (attempt $auth_attempt/$max_auth_retries)..."
    [ -n "$AUTH_RESPONSE_BODY" ] && warn "Response: $AUTH_RESPONSE_BODY"
    sleep $auth_retry_delay
  else
    error "Failed to create auth provider after $max_auth_retries attempts"
    error "Last response (HTTP $HTTP_CODE): $AUTH_RESPONSE_BODY"
    exit 1
  fi
done

if [ -n "$AUTH_PROVIDER_ID" ]; then
  log "✓ Auth provider created with ID: $AUTH_PROVIDER_ID"
  
  # Wait a moment for auth provider to fully initialize
  sleep 2

  # Declarative roles can take minutes to appear after Central rollout; poll API before POST /groups
  wait_for_prometheus_server_role 600 || true
  
  # Create group mapping with Prometheus Server role (retry if role not yet available)
  log "Creating 'Prometheus Server' role group mapping..."
  GROUP_PAYLOAD=$(envsubst < monitoring-examples/rhacs/admin-group.json.tpl)
  log "Group payload: $GROUP_PAYLOAD"
  
  max_retries=15
  retry_delay=20
  group_created=false
  
  for attempt in $(seq 1 $max_retries); do
    GROUP_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_ADDRESS/v1/groups" \
      -H "Authorization: Bearer $ROX_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data-raw "$GROUP_PAYLOAD")
    
    HTTP_CODE=$(echo "$GROUP_RESPONSE" | tail -1)
    RESPONSE_BODY=$(echo "$GROUP_RESPONSE" | strip_curl_http_line)
    
    if [ "$HTTP_CODE" = "200" ]; then
      if echo "$RESPONSE_BODY" | grep -q '"props"'; then
        log "✓ Group created successfully (HTTP $HTTP_CODE)"
        log "Role 'Prometheus Server' assigned to Monitoring auth provider"
      else
        log "✓ API returned success (HTTP $HTTP_CODE)"
      fi
      warn "Auth changes may take 10-30 seconds to propagate"
      group_created=true
      break
    elif [ "$HTTP_CODE" = "409" ]; then
      log "✓ Group already exists for Monitoring auth provider"
      group_created=true
      break
    elif echo "$HTTP_CODE" | grep -qE '^(502|503|504)$'; then
      if [ "$attempt" -lt "$max_retries" ]; then
        warn "Transient HTTP $HTTP_CODE from Central — retrying in ${retry_delay}s ($attempt/$max_retries)..."
        sleep "$retry_delay"
      else
        error "Group creation failed after retries (HTTP $HTTP_CODE)"
        error "Response: $RESPONSE_BODY"
        break
      fi
    elif is_role_not_ready_error "$RESPONSE_BODY"; then
      if [ "$attempt" -lt "$max_retries" ]; then
        warn "Role 'Prometheus Server' not yet accepted by API (declarative config still syncing)"
        log "  Retrying in ${retry_delay}s (attempt $attempt/$max_retries)..."
        sleep "$retry_delay"
      else
        error "Group creation failed (HTTP $HTTP_CODE) after $max_retries attempts"
        error "Response: $RESPONSE_BODY"
        break
      fi
    else
      error "Group creation failed (HTTP $HTTP_CODE)"
      error "Response: $RESPONSE_BODY"
      break
    fi
  done
  
  if [ "$group_created" != "true" ]; then
    echo ""
    warn "Attempting to verify if group exists..."
    EXISTING_GROUPS=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/groups" | \
      grep -A10 "$AUTH_PROVIDER_ID" 2>/dev/null) || EXISTING_GROUPS=""
    
    if [ -n "$EXISTING_GROUPS" ]; then
      log "✓ Found existing group for this auth provider"
    else
      error "No groups found for auth provider ID: $AUTH_PROVIDER_ID"
      error ""
      error "The 'Prometheus Server' role is defined in declarative config. Ensure:"
      error "1. Declarative config ConfigMap is applied and mounted on Central"
      error "2. Central has restarted to pick up the declarative config"
      error ""
      error "Manual fix required:"
      error "1. Via RHACS UI:"
      error "   Platform Configuration → Access Control → Groups → Create Group"
      error "   - Auth Provider: Monitoring"
      error "   - Key: (leave empty)"
      error "   - Value: (leave empty)"
      error "   - Role: Prometheus Server"
      error ""
      error "2. Via API:"
      error "   curl -k -X POST \"\$ROX_CENTRAL_ADDRESS/v1/groups\" \\"
      error "     -H \"Authorization: Bearer \$ROX_API_TOKEN\" \\"
      error "     -H \"Content-Type: application/json\" \\"
      error "     -d '{\"props\":{\"authProviderId\":\"$AUTH_PROVIDER_ID\",\"key\":\"\",\"value\":\"\"},\"roleName\":\"Prometheus Server\"}'"
      error ""
      error "3. Run troubleshoot script:"
      error "   cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
      exit 1
    fi
  fi
else
  error "Failed to extract auth provider ID from API response"
  error "API response: $AUTH_PROVIDER_RESPONSE"
  error "You may need to configure the group manually"
  exit 1
fi

echo ""
log "✓ RHACS authentication configuration complete"
echo ""