#!/usr/bin/env bash
# One-time cluster prerequisites for ACME incident exercises.
# Run as cluster-admin from the repository root: ./setup/cluster-prerequisites.sh
set -euo pipefail

echo "==> Creating node-log-viewer ClusterRole..."
oc apply --filename - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-log-viewer
rules:
  - apiGroups: [""]
    resources:
      - nodes/log
      - nodes/proxy
      - nodes
    verbs: ["get", "list", "create"]
  - apiGroups: ["config.openshift.io"]
    resources:
      - clusterversions
      - clusteroperators
      - apiservers
    verbs: ["get", "list"]
EOF

echo "==> Installing Web Terminal operator..."
oc apply --filename - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: web-terminal
  namespace: openshift-operators
spec:
  channel: fast
  installPlanApproval: Automatic
  name: web-terminal
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "==> Enabling external IP collection in RHACS..."
oc apply --filename - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: collector-config
  namespace: stackrox
data:
  runtime_config.yaml: |
    networking:
      externalIps:
        enabled: ENABLED
EOF

echo "==> Enabling CRIU checkpoint RBAC..."
oc apply --filename - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-apiserver-checkpoints
rules:
  - apiGroups: [""]
    resources:
      - nodes/checkpoint
    verbs:
      - get
      - create
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-apiserver-checkpoints
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-apiserver-checkpoints
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kube-apiserver
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: system:kube-apiserver
EOF

echo "==> Increasing audit log retention..."
oc apply --filename - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: KubeAPIServer
metadata:
  name: cluster
spec:
  unsupportedConfigOverrides:
    apiServerArguments:
      audit-log-maxsize:
        - "2048"
      audit-log-maxbackup:
        - "3"
EOF

echo "==> Cluster prerequisites applied."
