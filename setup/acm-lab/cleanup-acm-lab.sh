#!/usr/bin/env bash
# Remove 201-10 RHACM Policy objects. Leaves ACM itself installed.
set -euo pipefail

NS="${POLICY_NAMESPACE:-policies}"

if oc get crd policies.policy.open-cluster-management.io >/dev/null 2>&1; then
  oc -n "${NS}" delete policy,placementbinding,placement \
    -l app.kubernetes.io/component=201-10-acm --ignore-not-found=true 2>/dev/null || true
  oc -n "${NS}" delete policy policy-dod-ocp-baseline --ignore-not-found=true 2>/dev/null || true
  oc -n "${NS}" delete placementbinding binding-dod-ocp-baseline --ignore-not-found=true 2>/dev/null || true
  oc -n "${NS}" delete placement.cluster.open-cluster-management.io placement-dod-ocp-baseline --ignore-not-found=true 2>/dev/null || true
fi

if oc get crd managedclustersetbindings.cluster.open-cluster-management.io >/dev/null 2>&1; then
  oc -n "${NS}" delete managedclustersetbinding \
    -l app.kubernetes.io/component=201-10-acm --ignore-not-found=true 2>/dev/null || true
fi

oc delete namespace dod-workloads --wait=false --ignore-not-found=true 2>/dev/null || true

echo "Removed 201-10 DoD baseline Policy objects (ACM operators left installed)."
