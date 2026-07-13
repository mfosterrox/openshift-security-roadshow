#!/usr/bin/env bash
# Provision the ACS roadshow lab environment on the bastion host.
# Persists workshop variables to ~/.bashrc and prints progress throughout.
#
# Usage:
#   bash setup/lab-environment.sh \
#     --quay-user QUAYADMIN \
#     --quay-password 'secret'
#
# After making the frontend repository public in Quay UI:
#   bash setup/lab-environment.sh --deploy-skupper-only
set -euo pipefail

QUAY_USER=""
QUAY_PASSWORD=""
DEPLOY_SKUPPER_ONLY=false
SKIP_DEMO_APPS=false
SKIP_IMAGES=false
WORK_DIR="${HOME}"

DEMO_APPS_REPO="${DEMO_APPS_REPO:-https://github.com/mfosterrox/demo-apps.git}"
SKUPPER_REPO="${SKUPPER_REPO:-https://github.com/mfosterrox/skupper-security-demo.git}"

step() {
  echo ""
  echo "==> $*"
  echo "------------------------------------------------------------------------"
}

persist_var() {
  local name=$1
  local value=$2
  touch "${HOME}/.bashrc"
  if grep -q "^export ${name}=" "${HOME}/.bashrc" 2>/dev/null; then
    # shellcheck disable=SC2016
    sed -i "/^export ${name}=/d" "${HOME}/.bashrc"
  fi
  printf 'export %s=%q\n' "${name}" "${value}" >> "${HOME}/.bashrc"
  # shellcheck disable=SC2163
  export "${name}=${value}"
}

usage() {
  cat <<'EOF'
Usage: lab-environment.sh [options]

Options:
  --quay-user USER          Quay admin username (required unless --deploy-skupper-only)
  --quay-password PASS      Quay admin password (required unless --deploy-skupper-only)
  --deploy-skupper-only     Deploy patient-portal after frontend repo is public in Quay
  --skip-demo-apps          Skip cloning and applying vulnerable demo manifests
  --skip-images             Skip golden image and frontend build/push
  --work-dir DIR            Base directory for clones (default: $HOME)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quay-user) QUAY_USER=$2; shift 2 ;;
    --quay-password) QUAY_PASSWORD=$2; shift 2 ;;
    --deploy-skupper-only) DEPLOY_SKUPPER_ONLY=true; shift ;;
    --skip-demo-apps) SKIP_DEMO_APPS=true; shift ;;
    --skip-images) SKIP_IMAGES=true; shift ;;
    --work-dir) WORK_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

deploy_skupper() {
  step "Deploying patient-portal application (Skupper demo)"
  cd "${WORK_DIR}"
  if [[ ! -d skupper-app ]]; then
    git clone "${SKUPPER_REPO}" skupper-app
  fi
  persist_var APP_HOME "${WORK_DIR}/skupper-app"

  if [[ -z "${QUAY_URL:-}" || -z "${QUAY_USER:-}" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc" 2>/dev/null || true
  fi

  sed -i "s|quay.io/mfoster/patient-portal-frontend:1.0|${QUAY_URL}/${QUAY_USER}/frontend:0.1|g" \
    "${APP_HOME}/skupper-demo/frontend.yml"

  oc apply -f "${APP_HOME}/skupper-demo/"
  oc get pods -n patient-portal
  echo ""
  echo "Patient portal deployed. Frontend image: ${QUAY_URL}/${QUAY_USER}/frontend:0.1"
}

if [[ "${DEPLOY_SKUPPER_ONLY}" == true ]]; then
  deploy_skupper
  exit 0
fi

if [[ -z "${QUAY_USER}" || -z "${QUAY_PASSWORD}" ]]; then
  echo "Error: --quay-user and --quay-password are required for full setup." >&2
  usage
  exit 1
fi

step "Verifying OpenShift admin access"
oc config use-context admin 2>/dev/null || oc config use-context "$(oc config get-contexts -o name | head -1)"
oc whoami
oc get nodes --no-headers | head -5

step "Configuring RHACS CLI variables"
ROX_CENTRAL_ADDRESS="$(oc -n stackrox get route central -o jsonpath='{.spec.host}')"
persist_var ROX_CENTRAL_ADDRESS "${ROX_CENTRAL_ADDRESS}"

if [[ -n "${ROX_API_TOKEN:-}" ]]; then
  persist_var ROX_API_TOKEN "${ROX_API_TOKEN}"
elif grep -q '^export ROX_API_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
  # shellcheck source=/dev/null
  source "${HOME}/.bashrc"
else
  echo "NOTE: ROX_API_TOKEN not set. roxctl API calls needing a token may fail until you configure one."
fi

step "Verifying roxctl access to RHACS Central"
roxctl --insecure-skip-tls-verify -e "${ROX_CENTRAL_ADDRESS}:443" central whoami

if [[ "${SKIP_DEMO_APPS}" != true ]]; then
  step "Deploying vulnerable workshop applications"
  cd "${WORK_DIR}"
  if [[ ! -d demo-apps ]]; then
    git clone "${DEMO_APPS_REPO}" demo-apps
  fi
  persist_var TUTORIAL_HOME "${WORK_DIR}/demo-apps"
  oc apply -f "${TUTORIAL_HOME}/kubernetes-manifests/" --recursive
  echo ""
  echo "Waiting for roadshow deployments (Ctrl+C to skip wait)..."
  for _ in $(seq 1 30); do
    ready=$(oc get deployments -l demo=roadshow -A --no-headers 2>/dev/null | awk '$2 ~ /^[0-9]+\/[0-9]+$/ && $2 !~ /0\// {c++} END {print c+0}')
    total=$(oc get deployments -l demo=roadshow -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  Deployments ready: ${ready:-0}/${total:-0}"
    [[ "${ready:-0}" -ge 1 && "${ready}" -eq "${total}" ]] && break
    sleep 5
  done
  oc get deployments -l demo=roadshow -A

  step "Sample vulnerability scan (DVWA image)"
  roxctl --insecure-skip-tls-verify -e "${ROX_CENTRAL_ADDRESS}:443" image scan \
    --image=quay.io/mfoster/dvwa:0.1.0 --severity CRITICAL,IMPORTANT --force -o table | head -20
  echo "... (truncated)"
fi

if [[ "${SKIP_IMAGES}" != true ]]; then
  step "Configuring Quay variables and logging in"
  QUAY_URL="$(oc -n quay-enterprise get route quay-quay -o jsonpath='{.spec.host}')"
  persist_var QUAY_USER "${QUAY_USER}"
  persist_var QUAY_URL "${QUAY_URL}"
  echo "QUAY_USER=${QUAY_USER}"
  echo "QUAY_URL=${QUAY_URL}"
  podman login "${QUAY_URL}" -u "${QUAY_USER}" -p "${QUAY_PASSWORD}"

  step "Building and pushing golden base image (python-alpine-golden:0.1)"
  podman pull python:3.12-alpine
  podman tag docker.io/library/python:3.12-alpine "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
  podman push "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"

  step "Building and pushing frontend application (frontend:0.1)"
  # shellcheck source=/dev/null
  source "${HOME}/.bashrc"
  sed -i "s|^FROM python:3\.12-alpine AS \(\w\+\)|FROM ${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1 AS \1|" \
    "${TUTORIAL_HOME}/app-images/frontend/Dockerfile"
  cd "${TUTORIAL_HOME}/app-images/frontend/"
  podman build -t "${QUAY_URL}/${QUAY_USER}/frontend:0.1" .
  podman push "${QUAY_URL}/${QUAY_USER}/frontend:0.1" --remove-signatures
fi

step "Setup complete — variables saved to ~/.bashrc"
cat <<EOF

  TUTORIAL_HOME=${TUTORIAL_HOME:-not set}
  QUAY_USER=${QUAY_USER}
  QUAY_URL=${QUAY_URL:-not set}
  ROX_CENTRAL_ADDRESS=${ROX_CENTRAL_ADDRESS}

NEXT STEPS:
  1. Open the Quay console and browse the frontend repository (see module below).
  2. Make the frontend repository PUBLIC under Repository Settings.
  3. Deploy the patient-portal application:

     bash setup/lab-environment.sh --deploy-skupper-only

  Optional verification after making the repo public:

     roxctl --insecure-skip-tls-verify -e "\$ROX_CENTRAL_ADDRESS:443" \\
       image scan --image=\$QUAY_URL/\$QUAY_USER/frontend:0.1 --force -o table

Reload your shell to pick up variables:  source ~/.bashrc
EOF
