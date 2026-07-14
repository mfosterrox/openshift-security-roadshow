#!/bin/bash
#
# RHACS Monitoring Setup - Certificate Generation
# Generates CA and client certificates for monitoring authentication
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../rhacs/lib/common.sh"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get the script directory
cd "$SCRIPT_DIR"

step "Certificate Generation"
echo "=========================================="
echo ""

log "Generating CA and client certificates in $SCRIPT_DIR..."

# Clean up any existing certificates
rm -f ca.key ca.crt ca.srl client.key client.crt client.csr

# Step 1: Create a proper CA (Certificate Authority)
log "Creating CA certificate..."
openssl genrsa -out ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days 1825 -out ca.crt \
  -subj "/CN=Monitoring Root CA/O=RHACS Demo" \
  -addext "basicConstraints=CA:TRUE" 2>/dev/null

# Step 2: Generate client certificate signed by the CA
log "Creating client certificate..."
openssl genrsa -out client.key 2048 2>/dev/null
openssl req -new -key client.key -out client.csr \
  -subj "/CN=monitoring-user/O=Monitoring Team" 2>/dev/null

# Sign the client cert with the CA and add clientAuth extended key usage
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 365 -sha256 \
  -extfile <(printf "extendedKeyUsage=clientAuth") 2>/dev/null

# Clean up intermediate files
rm -f client.csr ca.srl

# Create TLS secret for Prometheus using the client certificate
log "Creating Kubernetes secret for Prometheus..."
kubectl delete secret sample-stackrox-prometheus-tls -n stackrox 2>/dev/null || true
kubectl create secret tls sample-stackrox-prometheus-tls --cert=client.crt --key=client.key -n stackrox

# Export the CA certificate for the auth provider (this is what goes in the userpki config)
# The auth provider trusts certificates signed by this CA
export TLS_CERT=$(awk '{printf "%s\\n", $0}' ca.crt)

log "✓ Certificates generated successfully"
echo "  CA: $(openssl x509 -in ca.crt -noout -subject -dates | head -1)"
echo "  Client: $(openssl x509 -in client.crt -noout -subject -dates | head -1)"
echo ""

# Export TLS_CERT for parent script
echo "export TLS_CERT='$TLS_CERT'" > "$SCRIPT_DIR/.env.certs"
log "✓ Certificate environment exported to .env.certs"
echo ""