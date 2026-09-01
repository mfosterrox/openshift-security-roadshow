#!/usr/bin/env bash
# Remove 301-03 labeled AdminNetworkPolicy objects and tenant projects.
# Never deletes BaselineAdminNetworkPolicy/default.
set -euo pipefail

if oc get crd adminnetworkpolicies.policy.networking.k8s.io >/dev/null 2>&1; then
  oc delete adminnetworkpolicy -l app.kubernetes.io/component=301-03-anp --ignore-not-found=true 2>/dev/null || true
  oc delete adminnetworkpolicy stride-allow-dns stride-allow-intra-tenant-a stride-allow-intra-tenant-b stride-deny-cross-tenant --ignore-not-found=true 2>/dev/null || true
fi

oc delete project 301-03-tenant-a 301-03-tenant-b --wait=false --ignore-not-found=true 2>/dev/null || true

echo "Removed 301-03 AdminNetworkPolicy objects (BANP/default left as-is)."
