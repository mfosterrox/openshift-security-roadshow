#!/usr/bin/env bash
#
# After Splunk is running: create an HEC token for OpenShift API audit, store it
# as a Secret, and apply a ClusterLogForwarder that ships kube-apiserver /
# OpenShift / OAuth audit to Splunk.
#
# Usage (from this directory, Splunk already up):
#   ./configure-openshift-audit.sh
#
# Optional:
#   SPLUNK_NAMESPACE / SPLUNK_NAME     (default: splunk)
#   SPLUNK_AUDIT_HEC_NAME              (default: openshift-audit-hec)
#   SPLUNK_AUDIT_SOURCE_TYPE           (default: kube:apiserver:audit)
#   SPLUNK_INSTALL_CLUSTER_LOGGING     Install CLO if CRDs are missing (default: true)
#   SPLUNK_APPLY_CLUSTERLOGFORWARDER   Apply ClusterLogForwarder (default: true)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/splunk-pod.sh
source "${SCRIPT_DIR}/lib/splunk-pod.sh"

CLF_NS="${SPLUNK_CLF_NAMESPACE:-openshift-logging}"
CLF_NAME="${SPLUNK_CLF_NAME:-splunk-audit}"
CLF_SA="${SPLUNK_CLF_SA:-splunk-audit-collector}"
HEC_SECRET="${SPLUNK_HEC_SECRET_NAME:-splunk-hec-audit}"
HEC_NAME="${SPLUNK_AUDIT_HEC_NAME:-openshift-audit-hec}"
SOURCE_TYPE="${SPLUNK_AUDIT_SOURCE_TYPE:-kube:apiserver:audit}"
HEC_URL="https://${SPLUNK_NAME}.${SPLUNK_NAMESPACE}.svc.cluster.local:8088"

crd_exists() {
  oc get crd "$1" >/dev/null 2>&1
}

wait_for_splunk_ready() {
  print_step "Waiting for Splunk deployment/${SPLUNK_NAME} in ${SPLUNK_NAMESPACE}"
  if ! oc -n "${SPLUNK_NAMESPACE}" get "deployment/${SPLUNK_NAME}" >/dev/null 2>&1; then
    print_error "Splunk deployment not found. Run ./install.sh (or ./setup.sh) first."
    exit 1
  fi
  oc -n "${SPLUNK_NAMESPACE}" rollout status "deployment/${SPLUNK_NAME}" --timeout="${SPLUNK_ROLLOUT_TIMEOUT:-25m}"
}

store_hec_secret() {
  local token="$1"
  local ns="$2"
  oc get namespace "${ns}" >/dev/null 2>&1 || oc create namespace "${ns}"
  oc -n "${ns}" create secret generic "${HEC_SECRET}" \
    --from-literal=hecToken="${token}" \
    --from-literal=token="${token}" \
    --dry-run=client -o yaml | oc apply -f -
}

ensure_cluster_logging_operator() {
  if [ "${SPLUNK_INSTALL_CLUSTER_LOGGING:-true}" != "true" ]; then
    print_info "Skipping Cluster Logging Operator install (SPLUNK_INSTALL_CLUSTER_LOGGING=${SPLUNK_INSTALL_CLUSTER_LOGGING})"
    return 0
  fi

  if crd_exists clusterlogforwarders.observability.openshift.io || \
     crd_exists clusterlogforwarders.logging.openshift.io; then
    print_info "ClusterLogForwarder CRD already present; not installing an operator."
    return 0
  fi

  if ! oc get packagemanifest cluster-logging -n openshift-marketplace >/dev/null 2>&1; then
    print_warn "Packagemanifest cluster-logging not found. ClusterLogForwarder will be skipped."
    print_warn "You can still load audit into Splunk with ./push-recent-audit.sh"
    return 0
  fi

  local channel
  channel="$(oc get packagemanifest cluster-logging -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')"
  print_step "Installing Cluster Logging Operator (channel ${channel}) in ${CLF_NS}"

  oc get namespace "${CLF_NS}" >/dev/null 2>&1 || oc create namespace "${CLF_NS}"

  if [ -z "$(oc get operatorgroup -n "${CLF_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" ]; then
    if [[ "${channel}" == *6* ]]; then
      oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: ${CLF_NS}
spec: {}
EOF
    else
      oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: ${CLF_NS}
spec:
  targetNamespaces:
  - ${CLF_NS}
EOF
    fi
  fi

  if ! oc get subscription cluster-logging -n "${CLF_NS}" >/dev/null 2>&1; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: ${CLF_NS}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  fi

  print_step "Waiting for ClusterLogForwarder CRD (up to 10 minutes)"
  local i
  for i in $(seq 1 60); do
    if crd_exists clusterlogforwarders.observability.openshift.io || \
       crd_exists clusterlogforwarders.logging.openshift.io; then
      print_info "ClusterLogForwarder CRD is available."
      return 0
    fi
    sleep 10
  done
  print_warn "ClusterLogForwarder CRD did not appear. Continuing without a live collector."
  return 0
}

ensure_collector_sa() {
  oc get namespace "${CLF_NS}" >/dev/null 2>&1 || oc create namespace "${CLF_NS}"
  oc -n "${CLF_NS}" create serviceaccount "${CLF_SA}" --dry-run=client -o yaml | oc apply -f -
  oc adm policy add-cluster-role-to-user collect-audit-logs \
    -z "${CLF_SA}" -n "${CLF_NS}" >/dev/null 2>&1 || \
    print_warn "Could not bind collect-audit-logs to ${CLF_SA} (role missing on this version?)."
  # Logging 6 also uses these names on some channels.
  oc adm policy add-cluster-role-to-user cluster-logging-collect-audit-logs \
    -z "${CLF_SA}" -n "${CLF_NS}" >/dev/null 2>&1 || true
}

apply_observability_clf() {
  oc apply -f - <<EOF || return 1
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
  namespace: ${CLF_NS}
  labels:
    app.kubernetes.io/part-of: openshift-security-roadshow
    app.kubernetes.io/component: 201-06-audit
spec:
  serviceAccount:
    name: ${CLF_SA}
  outputs:
  - name: splunk-hec
    type: splunk
    tls:
      insecureSkipVerify: true
    splunk:
      url: ${HEC_URL}
      index: main
      authentication:
        token:
          key: hecToken
          secretName: ${HEC_SECRET}
  pipelines:
  - name: audit-to-splunk
    inputRefs:
    - audit
    outputRefs:
    - splunk-hec
EOF
}

apply_legacy_clf() {
  local yaml
  yaml=$(cat <<EOF
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
  namespace: ${CLF_NS}
  labels:
    app.kubernetes.io/part-of: openshift-security-roadshow
    app.kubernetes.io/component: 201-06-audit
spec:
  serviceAccountName: ${CLF_SA}
  outputs:
  - name: splunk-hec
    type: splunk
    url: ${HEC_URL}
    secret:
      name: ${HEC_SECRET}
    tls:
      insecureSkipVerify: true
  pipelines:
  - name: audit-to-splunk
    inputRefs:
    - audit
    outputRefs:
    - splunk-hec
EOF
)
  if echo "${yaml}" | oc apply -f -; then
    return 0
  fi
  print_warn "Apply with tls.insecureSkipVerify failed; retrying without tls."
  oc apply -f - <<EOF || return 1
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
  namespace: ${CLF_NS}
  labels:
    app.kubernetes.io/part-of: openshift-security-roadshow
    app.kubernetes.io/component: 201-06-audit
spec:
  serviceAccountName: ${CLF_SA}
  outputs:
  - name: splunk-hec
    type: splunk
    url: ${HEC_URL}
    secret:
      name: ${HEC_SECRET}
  pipelines:
  - name: audit-to-splunk
    inputRefs:
    - audit
    outputRefs:
    - splunk-hec
EOF
}

patch_legacy_instance() {
  if ! oc -n "${CLF_NS}" get clusterlogforwarder.logging.openshift.io instance >/dev/null 2>&1; then
    return 1
  fi
  print_step "Found existing ClusterLogForwarder/instance; adding Splunk audit output"
  local tmp
  tmp="$(mktemp)"
  oc -n "${CLF_NS}" get clusterlogforwarder.logging.openshift.io instance -o json | \
    jq --arg secret "${HEC_SECRET}" --arg url "${HEC_URL}" --arg sa "${CLF_SA}" '
      .spec.outputs = ((.spec.outputs // []) | map(select(.name != "splunk-hec"))) + [{
        name: "splunk-hec",
        type: "splunk",
        url: $url,
        secret: {name: $secret}
      }]
      | .spec.pipelines = ((.spec.pipelines // []) | map(select(.name != "audit-to-splunk"))) + [{
        name: "audit-to-splunk",
        inputRefs: ["audit"],
        outputRefs: ["splunk-hec"]
      }]
      | if (.spec.serviceAccountName // "") == "" then .spec.serviceAccountName = $sa else . end
    ' > "${tmp}"
  oc apply -f "${tmp}"
  rm -f "${tmp}"
}

apply_clusterlogforwarder() {
  if [ "${SPLUNK_APPLY_CLUSTERLOGFORWARDER:-true}" != "true" ]; then
    print_info "Skipping ClusterLogForwarder (SPLUNK_APPLY_CLUSTERLOGFORWARDER=${SPLUNK_APPLY_CLUSTERLOGFORWARDER})"
    return 0
  fi

  if ! crd_exists clusterlogforwarders.observability.openshift.io && \
     ! crd_exists clusterlogforwarders.logging.openshift.io; then
    print_warn "No ClusterLogForwarder CRD. Continuous forward is not active."
    print_warn "Use ./push-recent-audit.sh after you generate exec so Splunk still has events."
    return 0
  fi

  ensure_collector_sa
  store_hec_secret "${HEC_TOKEN}" "${CLF_NS}"

  if crd_exists clusterlogforwarders.observability.openshift.io; then
    print_step "Applying ClusterLogForwarder ${CLF_NS}/${CLF_NAME} (observability.openshift.io/v1)"
    if ! apply_observability_clf; then
      print_warn "observability ClusterLogForwarder apply failed. Use ./push-recent-audit.sh for this lab."
    fi
    return 0
  fi

  # CIS ocp4-cis 1.2.21 (logging.openshift.io) reads ClusterLogForwarder/instance only.
  print_step "Applying ClusterLogForwarder ${CLF_NS}/instance (logging.openshift.io/v1, CIS 1.2.21)"
  CLF_NAME="instance"
  if oc -n "${CLF_NS}" get clusterlogforwarder.logging.openshift.io instance >/dev/null 2>&1; then
    patch_legacy_instance || print_warn "Could not patch instance; rely on ./push-recent-audit.sh"
    return 0
  fi
  if apply_legacy_clf; then
    return 0
  fi
  print_warn "Could not create ClusterLogForwarder/instance; rely on ./push-recent-audit.sh"
}

print_cis_ocil() {
  print_step "CIS ocp4-cis 1.2.21 OCIL: pipelines must include inputRefs audit"
  local obs logv
  obs="$(oc get clusterlogforwarders.observability.openshift.io -n "${CLF_NS}" -o json 2>/dev/null | \
    jq -r '[.items[]?.spec.pipelines[]?.inputRefs[]?] | index("audit") != null' 2>/dev/null || echo "n/a")"
  logv="$(oc get clusterlogforwarder.logging.openshift.io instance -n "${CLF_NS}" -o json 2>/dev/null | \
    jq -r '[.spec.pipelines[]?.inputRefs[]?] | index("audit") != null' 2>/dev/null || echo "n/a")"
  print_info "observability.openshift.io CLF list contains audit: ${obs}"
  print_info "logging.openshift.io/instance contains audit:     ${logv}"
  if [ "${obs}" = "true" ] || [ "${logv}" = "true" ]; then
    print_info "Forwarding shape matches CIS 1.2.21. Re-scan ocp4-cis in 201-07 to record PASS."
  else
    print_warn "OCIL did not see audit in inputRefs. 201-07 forwarding check may still FAIL."
  fi
}

print_summary() {
  local route_host
  route_host="$(oc -n "${SPLUNK_NAMESPACE}" get route "${SPLUNK_NAME}-web" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  echo ""
  print_info "======================================"
  print_info "OpenShift audit → Splunk"
  print_info "======================================"
  print_info "HEC token name : ${HEC_NAME}"
  print_info "HEC sourcetype : ${SOURCE_TYPE}"
  print_info "HEC URL        : ${HEC_URL}/services/collector/event"
  if [ -n "${route_host}" ]; then
    print_info "Splunk Web     : https://${route_host}"
  fi
  print_info ""
  print_info "Search (after events land):"
  print_info "  index=main sourcetype=\"${SOURCE_TYPE}\" sleeper"
  print_info "  index=main (exec OR connect) sleeper earliest=-1h"
  print_info "  index=* sourcetype=\"stackrox-*\" sleeper"
  print_info ""
  print_info "Immediate seed (does not wait for the collector):"
  print_info "  ${SCRIPT_DIR}/push-recent-audit.sh"
  print_info ""
  print_info "Leave Splunk and this forwarder running for 201-07 (ocp4-cis re-scan)."
  echo ""
}

main() {
  require_cmd oc
  require_cmd jq
  require_cmd curl

  if ! oc whoami >/dev/null 2>&1; then
    print_error "You are not logged in to OpenShift. Run: oc login"
    exit 1
  fi

  wait_for_splunk_ready

  local password
  password="$(oc -n "${SPLUNK_NAMESPACE}" get secret "${SPLUNK_NAME}-auth" -o jsonpath='{.data.password}' | base64 -d)"
  if [ -z "${password}" ]; then
    print_error "Could not read ${SPLUNK_NAMESPACE}/${SPLUNK_NAME}-auth password"
    exit 1
  fi

  print_step "Creating/reading Splunk HEC token '${HEC_NAME}'"
  HEC_TOKEN="$(create_or_get_splunk_hec_token "${SPLUNK_NAMESPACE}" "${SPLUNK_NAME}" "${password}" "${HEC_NAME}" "${SOURCE_TYPE}")"
  store_hec_secret "${HEC_TOKEN}" "${SPLUNK_NAMESPACE}"
  print_info "Stored HEC token in secret/${HEC_SECRET} (namespaces ${SPLUNK_NAMESPACE}, and ${CLF_NS} if forwarding)."

  ensure_cluster_logging_operator
  apply_clusterlogforwarder
  print_cis_ocil
  print_summary
}

main "$@"
