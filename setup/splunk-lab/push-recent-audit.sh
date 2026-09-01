#!/usr/bin/env bash
#
# Copy recent kube-apiserver audit lines from control-plane nodes into Splunk HEC.
# Use this after you generate oc exec so Search is not empty while ClusterLogForwarder
# collectors start (or if CLO is not installed).
#
# Usage:
#   ./push-recent-audit.sh
#
# Optional:
#   SPLUNK_AUDIT_LINES   How many trailing lines per master (default: 400)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/splunk-pod.sh
source "${SCRIPT_DIR}/lib/splunk-pod.sh"

HEC_SECRET="${SPLUNK_HEC_SECRET_NAME:-splunk-hec-audit}"
SOURCE_TYPE="${SPLUNK_AUDIT_SOURCE_TYPE:-kube:apiserver:audit}"
LINES="${SPLUNK_AUDIT_LINES:-400}"

require_cmd oc
require_cmd jq

if ! oc whoami >/dev/null 2>&1; then
  print_error "You are not logged in to OpenShift. Run: oc login"
  exit 1
fi

pod="$(splunk_pod_name)"
if [ -z "${pod}" ]; then
  print_error "No Splunk pod in ${SPLUNK_NAMESPACE}. Run ./install.sh first."
  exit 1
fi

token="$(oc -n "${SPLUNK_NAMESPACE}" get secret "${HEC_SECRET}" -o jsonpath='{.data.hecToken}' 2>/dev/null | base64 -d || true)"
if [ -z "${token}" ]; then
  print_error "Secret ${SPLUNK_NAMESPACE}/${HEC_SECRET} missing hecToken. Run ./configure-openshift-audit.sh first."
  exit 1
fi

nodes="$(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ -z "${nodes}" ]; then
  nodes="$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
fi
if [ -z "${nodes}" ]; then
  print_error "No control-plane / master nodes found."
  exit 1
fi

hec_url="https://127.0.0.1:8088/services/collector/raw?sourcetype=${SOURCE_TYPE}&index=main"
count=0
for node in ${nodes}; do
  print_step "Shipping last ${LINES} kube-apiserver audit lines from ${node}"
  if oc adm node-logs "${node}" --path=kube-apiserver/audit.log 2>/dev/null | tail -n "${LINES}" | \
      splunk_oc_exec_i "${SPLUNK_NAMESPACE}" "${pod}" curl -k -sS \
        -H "Authorization: Splunk ${token}" \
        -H "Content-Type: application/json" \
        "${hec_url}" \
        --data-binary @- >/tmp/splunk-audit-seed.out; then
    print_info "Posted from ${node} (HEC response in /tmp/splunk-audit-seed.out)"
    count=$((count + 1))
  else
    print_warn "Could not read or post audit.log from ${node}"
  fi
done

if [ "${count}" -eq 0 ]; then
  print_error "No audit lines were posted."
  exit 1
fi

print_info "Search in Splunk: index=main sourcetype=\"${SOURCE_TYPE}\" earliest=-1h"
print_info "Or: index=main sleeper exec"
