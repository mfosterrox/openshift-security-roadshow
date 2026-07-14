#!/usr/bin/env bash
# Provision the ACS roadshow lab environment on the bastion host.
# Runs RHACS demo configure (settings, compliance, monitoring, MCP, Lightspeed),
# then configures CLI access, deploys demo apps, and builds/pushes Quay images.
#
# Quiet by default (progress bar + current step). Use --verbose for full logs.
#
# Usage:
#   bash setup/lab-environment.sh \
#     --quay-user QUAYADMIN \
#     --quay-password 'secret'
#
# After making the frontend repository public in Quay UI:
#   bash setup/lab-environment.sh --deploy-skupper-only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/rhacs/lib/progress.sh"

QUAY_USER=""
QUAY_PASSWORD=""
DEPLOY_SKUPPER_ONLY=false
SKIP_DEMO_APPS=false
SKIP_IMAGES=false
SKIP_RHACS_CONFIGURE=false
VERBOSE=false
WORK_DIR="${HOME}"

DEMO_APPS_REPO="${DEMO_APPS_REPO:-https://github.com/mfosterrox/demo-apps.git}"
SKUPPER_REPO="${SKUPPER_REPO:-https://github.com/mfosterrox/skupper-security-demo.git}"

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
  --skip-rhacs-configure    Skip setup/rhacs-configure.sh (RHACS/monitoring/MCP)
  --verbose                 Stream detailed command output
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
    --skip-rhacs-configure) SKIP_RHACS_CONFIGURE=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --work-dir) WORK_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

PROGRESS_VERBOSE="${VERBOSE}"

deploy_skupper() {
  echo "Deploying patient-portal application (Skupper demo)..."
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

# Count top-level lab steps (rhacs-configure has its own progress bar)
TOTAL=0
TOTAL=$((TOTAL + 2)) # admin + wait central
[[ "${SKIP_RHACS_CONFIGURE}" != true ]] && TOTAL=$((TOTAL + 1))
TOTAL=$((TOTAL + 2)) # CLI vars + verify API
[[ "${SKIP_DEMO_APPS}" != true ]] && TOTAL=$((TOTAL + 1))
[[ "${SKIP_IMAGES}" != true ]] && TOTAL=$((TOTAL + 3)) # quay login + golden + frontend

LOG_DIR="${HOME}/.acs-roadshow"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/lab-environment-$(date +%Y%m%d-%H%M%S).log"
progress_init "${TOTAL}" "${LOG_FILE}" "Lab environment setup"

do_verify_admin() {
  oc config use-context admin 2>/dev/null || oc config use-context "$(oc config get-contexts -o name | head -1)"
  oc whoami
  oc get nodes --no-headers | head -5
}

do_wait_central() {
  if ! oc -n stackrox get route central >/dev/null 2>&1; then
    echo "Error: RHACS Central route not found in namespace stackrox." >&2
    echo "Ensure RHACS is installed (Central route in namespace stackrox) before running this script." >&2
    return 1
  fi
  oc -n stackrox wait --for=condition=available --timeout=300s deployment/central 2>/dev/null \
    || echo "NOTE: Central deployment not yet Available; continuing with route lookup."
}

do_cli_vars() {
  ROX_CENTRAL_ADDRESS="$(oc -n stackrox get route central -o jsonpath='{.spec.host}')"
  ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS#https://}"
  ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS#http://}"
  persist_var ROX_CENTRAL_ADDRESS "${ROX_CENTRAL_ADDRESS}"

  if [[ -z "${ROX_API_TOKEN:-}" ]] && grep -q '^export ROX_API_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc"
  fi

  if [[ -z "${ROX_PASSWORD:-}" ]]; then
    ROX_PASSWORD="$(oc -n stackrox get secret central-htpasswd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  if [[ -n "${ROX_PASSWORD:-}" ]]; then
    persist_var ROX_PASSWORD "${ROX_PASSWORD}"
  fi

  if [[ -z "${ROX_API_TOKEN:-}" ]]; then
    if [[ -z "${ROX_PASSWORD:-}" ]]; then
      echo "Error: ROX_API_TOKEN is unset and could not read ROX_PASSWORD from central-htpasswd." >&2
      return 1
    fi
    token_json="$(curl -ksS --connect-timeout 15 --max-time 60 \
      -X POST \
      -u "admin:${ROX_PASSWORD}" \
      -H "Content-Type: application/json" \
      "https://${ROX_CENTRAL_ADDRESS}/v1/apitokens/generate" \
      -d "{\"name\":\"roadshow-bastion-$(date +%s)\",\"roles\":[\"Admin\"]}")"
    ROX_API_TOKEN="$(printf '%s' "${token_json}" | jq -r '.token // empty')"
    if [[ -z "${ROX_API_TOKEN}" || "${#ROX_API_TOKEN}" -lt 20 ]]; then
      echo "Error: failed to generate ROX_API_TOKEN. Response: ${token_json}" >&2
      return 1
    fi
  fi
  persist_var ROX_API_TOKEN "${ROX_API_TOKEN}"
}

do_verify_api() {
  roxctl --insecure-skip-tls-verify -e "${ROX_CENTRAL_ADDRESS}:443" central whoami
  curl -ksS -H "Authorization: Bearer ${ROX_API_TOKEN}" \
    "https://${ROX_CENTRAL_ADDRESS}/v1/auth/status" | jq -r '.userId // .user // "ok"' >/dev/null
}

do_demo_apps() {
  cd "${WORK_DIR}"
  if [[ ! -d demo-apps ]]; then
    git clone "${DEMO_APPS_REPO}" demo-apps
  else
    git -C demo-apps pull --ff-only 2>/dev/null || true
  fi
  persist_var TUTORIAL_HOME "${WORK_DIR}/demo-apps"
  if [[ ! -d "${TUTORIAL_HOME}/kubernetes-manifests" ]]; then
    echo "Error: ${TUTORIAL_HOME}/kubernetes-manifests not found." >&2
    return 1
  fi
  oc apply -f "${TUTORIAL_HOME}/kubernetes-manifests/" --recursive
  oc get deployments -l demo=roadshow -A
  total=$(oc get deployments -l demo=roadshow -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${total:-0}" -lt 1 ]]; then
    echo "Error: no deployments with label demo=roadshow were found after apply." >&2
    return 1
  fi
}

do_quay_login() {
  QUAY_URL="$(oc -n quay-enterprise get route quay-quay -o jsonpath='{.spec.host}')"
  persist_var QUAY_USER "${QUAY_USER}"
  persist_var QUAY_URL "${QUAY_URL}"
  podman login "${QUAY_URL}" -u "${QUAY_USER}" -p "${QUAY_PASSWORD}"
}

do_golden_image() {
  podman pull python:3.12-alpine
  podman tag docker.io/library/python:3.12-alpine "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
  podman push "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
}

do_frontend_image() {
  # shellcheck source=/dev/null
  source "${HOME}/.bashrc"
  sed -i "s|^FROM python:3\.12-alpine AS \(\w\+\)|FROM ${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1 AS \1|" \
    "${TUTORIAL_HOME}/app-images/frontend/Dockerfile"
  cd "${TUTORIAL_HOME}/app-images/frontend/"
  podman build -t "${QUAY_URL}/${QUAY_USER}/frontend:0.1" .
  podman push "${QUAY_URL}/${QUAY_USER}/frontend:0.1" --remove-signatures
}

progress_run "Verify OpenShift access" do_verify_admin
progress_run "Wait for RHACS Central" do_wait_central

# Kick off RHACS configure in the background so demo apps / Quay work can overlap.
configure_pid=""
configure_log="${LOG_DIR}/rhacs-configure-bg-$(date +%Y%m%d-%H%M%S).log"
if [[ "${SKIP_RHACS_CONFIGURE}" != true ]]; then
  PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
  progress_render "RHACS configure (background — overlaps with apps/Quay)"
  {
    echo ""
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) START background rhacs-configure ====="
  } >> "${LOG_FILE}"
  configure_args=()
  [[ "${VERBOSE}" == true ]] && configure_args+=(--verbose)
  # Log-only while backgrounded so this TTY keeps a single progress bar
  (
    bash "${SCRIPT_DIR}/rhacs-configure.sh" "${configure_args[@]+"${configure_args[@]}"}"
  ) >"${configure_log}" 2>&1 &
  configure_pid=$!
fi

progress_run "Configure RHACS CLI variables" do_cli_vars
progress_run "Verify RHACS API access" do_verify_api

# While RHACS configure runs in the background, deploy apps and build the golden image.
if [[ "${SKIP_DEMO_APPS}" != true ]]; then
  progress_run "Deploy workshop applications" do_demo_apps
fi

if [[ "${SKIP_IMAGES}" != true ]]; then
  progress_run "Log in to Quay" do_quay_login
  progress_run "Build and push golden base image" do_golden_image
fi

if [[ -n "${configure_pid}" ]]; then
  progress_render "Waiting for RHACS configure to finish"
  set +e
  wait "${configure_pid}"
  cfg_rc=$?
  set -e
  if [[ "${cfg_rc}" -ne 0 ]]; then
    if [[ -t 1 ]]; then printf '\n'; fi
    echo "FAILED: RHACS configure (exit ${cfg_rc}). Log: ${configure_log}" >&2
    tail -n 40 "${configure_log}" >&2 || true
    exit "${cfg_rc}"
  fi
  {
    echo ""
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) END background rhacs-configure (ok) ====="
    cat "${configure_log}"
  } >> "${LOG_FILE}"
  # shellcheck source=/dev/null
  source "${HOME}/.bashrc" 2>/dev/null || true
fi

if [[ "${SKIP_IMAGES}" != true ]]; then
  progress_run "Build and push frontend image" do_frontend_image
fi

progress_done "Lab environment setup complete"

cat <<EOF

Done. Log: ${LOG_FILE}

  TUTORIAL_HOME=${TUTORIAL_HOME:-not set}
  QUAY_USER=${QUAY_USER}
  QUAY_URL=${QUAY_URL:-not set}
  ROX_CENTRAL_ADDRESS=${ROX_CENTRAL_ADDRESS}
  ROX_API_TOKEN=<set in ~/.bashrc, ${#ROX_API_TOKEN} chars>

NEXT STEPS:
  1. Open the Quay console and browse the frontend repository (see module 00).
  2. Make the frontend repository PUBLIC under Repository Settings.
  3. Deploy the patient-portal application:

     bash setup/lab-environment.sh --deploy-skupper-only

Reload your shell to pick up variables:  source ~/.bashrc
EOF
