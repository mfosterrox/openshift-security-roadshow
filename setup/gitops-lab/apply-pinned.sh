#!/usr/bin/env bash
# Resolve the Red Hat UBI Python image digest and apply the GitOps manifests pinned to it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMG="${PYTHON_IMAGE:-registry.access.redhat.com/ubi9/python-311}"
TAG="${PYTHON_TAG:-latest}"

DIGEST=""
if DIGEST=$(oc image info "${IMG}:${TAG}" --filter-by-os=linux/amd64 2>/dev/null | awk '/Digest:/ {print $2; exit}'); then
  :
fi
if [ -z "${DIGEST}" ] && command -v skopeo >/dev/null 2>&1; then
  DIGEST=$(skopeo inspect --override-os linux --override-arch amd64 "docker://${IMG}:${TAG}" | jq -r '.Digest // empty')
fi

if [ -n "${DIGEST}" ]; then
  REF="${IMG}@${DIGEST}"
  echo "Pinning ${REF}"
else
  REF="${IMG}:${TAG}"
  echo "WARNING: could not resolve digest; applying tag ${REF}" >&2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cp "${ROOT}/namespace.yaml" "${ROOT}/sa.yaml" "${ROOT}/service.yaml" "${TMP}/"
# Rewrite Deployment image to the pinned reference.
sed "s|image: registry.access.redhat.com/ubi9/python-311:latest|image: ${REF}|" \
  "${ROOT}/deployment.yaml" > "${TMP}/deployment.yaml"

oc apply -f "${TMP}/namespace.yaml"
oc apply -f "${TMP}/sa.yaml" -n 301-02-python
oc apply -f "${TMP}/deployment.yaml" -n 301-02-python
oc apply -f "${TMP}/service.yaml" -n 301-02-python
echo "Applied python-app in 301-02-python using ${REF}"
