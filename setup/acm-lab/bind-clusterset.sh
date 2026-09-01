#!/usr/bin/env bash
# Bind a ManagedClusterSet into namespace `policies` so Placement can select clusters.
set -euo pipefail

NS="${POLICY_NAMESPACE:-policies}"

if ! oc get crd managedclustersets.cluster.open-cluster-management.io >/dev/null 2>&1; then
  echo "RHACM / MCE cluster inventory CRDs not found. Install Advanced Cluster Management first." >&2
  exit 1
fi

oc get namespace "${NS}" >/dev/null 2>&1 || oc create namespace "${NS}"

SET="${MANAGED_CLUSTER_SET:-}"
if [ -z "${SET}" ]; then
  SET="$(oc get managedclusterset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [ -z "${SET}" ]; then
  echo "No ManagedClusterSet found. Create one or set MANAGED_CLUSTER_SET." >&2
  exit 1
fi

echo "Binding ClusterSet '${SET}' into namespace ${NS}"

# Prefer v1beta2; fall back to v1beta1.
if oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${SET}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: openshift-security-roadshow
    app.kubernetes.io/component: 201-10-acm
spec:
  clusterSet: ${SET}
EOF
then
  exit 0
fi

oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: ManagedClusterSetBinding
metadata:
  name: ${SET}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: openshift-security-roadshow
    app.kubernetes.io/component: 201-10-acm
spec:
  clusterSet: ${SET}
EOF
