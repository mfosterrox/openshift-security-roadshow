#!/usr/bin/env bash
#
# Remove ClusterLogForwarder and collector RBAC created by configure-openshift-audit.sh.
# Does not uninstall Cluster Logging Operator or delete the Splunk namespace.
#
# Usage:
#   ./cleanup-openshift-audit.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/splunk-pod.sh
source "${SCRIPT_DIR}/lib/splunk-pod.sh"

CLF_NS="${SPLUNK_CLF_NAMESPACE:-openshift-logging}"
CLF_NAME="${SPLUNK_CLF_NAME:-splunk-audit}"
CLF_SA="${SPLUNK_CLF_SA:-splunk-audit-collector}"
HEC_SECRET="${SPLUNK_HEC_SECRET_NAME:-splunk-hec-audit}"

crd_exists() {
  oc get crd "$1" >/dev/null 2>&1
}

strip_instance_splunk_output() {
  if ! oc -n "${CLF_NS}" get clusterlogforwarder.logging.openshift.io instance >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  oc -n "${CLF_NS}" get clusterlogforwarder.logging.openshift.io instance -o json | \
    jq '
      .spec.outputs = ((.spec.outputs // []) | map(select(.name != "splunk-hec")))
      | .spec.pipelines = ((.spec.pipelines // []) | map(select(.name != "audit-to-splunk")))
    ' > "${tmp}"
  oc apply -f "${tmp}"
  rm -f "${tmp}"
  print_info "Removed Splunk audit output from ClusterLogForwarder/instance (if it was present)."
}

print_step "Removing OpenShift audit → Splunk forwarder resources"

if crd_exists clusterlogforwarders.observability.openshift.io; then
  oc -n "${CLF_NS}" delete clusterlogforwarder.observability.openshift.io "${CLF_NAME}" --ignore-not-found=true
fi
if crd_exists clusterlogforwarders.logging.openshift.io; then
  oc -n "${CLF_NS}" delete clusterlogforwarder.logging.openshift.io "${CLF_NAME}" --ignore-not-found=true
  strip_instance_splunk_output || print_warn "Could not strip instance outputs."
fi

oc adm policy remove-cluster-role-from-user collect-audit-logs \
  -z "${CLF_SA}" -n "${CLF_NS}" >/dev/null 2>&1 || true
oc adm policy remove-cluster-role-from-user cluster-logging-collect-audit-logs \
  -z "${CLF_SA}" -n "${CLF_NS}" >/dev/null 2>&1 || true

oc -n "${CLF_NS}" delete serviceaccount "${CLF_SA}" --ignore-not-found=true 2>/dev/null || true
oc -n "${CLF_NS}" delete secret "${HEC_SECRET}" --ignore-not-found=true 2>/dev/null || true
oc -n "${SPLUNK_NAMESPACE}" delete secret "${HEC_SECRET}" --ignore-not-found=true 2>/dev/null || true

print_info "Audit forwarder cleanup finished (Cluster Logging Operator left installed)."
print_info "To tear down Splunk itself: ${SCRIPT_DIR}/clean.sh"
