#!/usr/bin/env bash
# Remove 301-01 STRIDE RHACM Policy objects. Leaves ACM itself installed.
set -euo pipefail

NS="${POLICY_NAMESPACE:-policies}"

if oc get crd policies.policy.open-cluster-management.io >/dev/null 2>&1; then
  oc -n "${NS}" delete policyset.policy.open-cluster-management.io stride-ocp-baseline --ignore-not-found=true 2>/dev/null || true
  oc -n "${NS}" delete policy,placementbinding,placement \
    -l app.kubernetes.io/component=301-01-acm --ignore-not-found=true 2>/dev/null || true
  oc -n "${NS}" delete policy policy-stride-ns-psa policy-stride-quota-limits policy-stride-netpol-sa --ignore-not-found=true 2>/dev/null || true
  oc -n "${NS}" delete placementbinding binding-stride-ocp-baseline --ignore-not-found=true 2>/dev/null || true
  oc -n "${NS}" delete placement.cluster.open-cluster-management.io placement-stride-ocp-baseline --ignore-not-found=true 2>/dev/null || true
fi

oc delete namespace stride-workloads --wait=false --ignore-not-found=true 2>/dev/null || true

echo "Removed 301-01 STRIDE PolicySet objects (ACM operators left installed)."
