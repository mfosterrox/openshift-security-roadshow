#!/usr/bin/env bash
# Provision the ACS roadshow lab environment on the bastion host.
# Configures Quay first (repairs a MinIO ImagePullBackOff when the public
# quay.io/minio/minio image cannot be pulled), then runs RHACS demo configure
# (settings, compliance, monitoring, MCP, Lightspeed), CLI access, demo apps,
# and Quay image builds.
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
ROADSHOW_ENV_FILE="${HOME}/.acs-roadshow/env"
# Pin Alpine minor so Clair can match apk CVEs. Floating python:3.12-alpine tracks
# current Alpine (3.24.1 today); catalog Clair indexes it but leaves version_id
# empty, so Quay's Security Scan column shows Passed / namespace "".
PYTHON_ALPINE_BASE="${PYTHON_ALPINE_BASE:-docker.io/library/python:3.12-alpine3.20}"
# quay.io/minio/minio and docker.io/minio/minio reject anonymous pulls.
# pgsty/minio is a public fork frozen at this tag. It keeps /usr/bin/minio and
# /usr/bin/docker-entrypoint.sh, so the Quay MinIO deployment's existing
# command and args still start the server. Override with MINIO_REPLACEMENT_IMAGE.
MINIO_REPLACEMENT_IMAGE="${MINIO_REPLACEMENT_IMAGE:-docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z}"

# Persist lab vars to a dedicated env file (safe to source from scripts) and ~/.bashrc
# (for interactive shells). Never source ~/.bashrc from this script — bastion images
# often call `exit` for non-interactive shells, which aborts setup mid-run.
persist_var() {
  local name=$1
  local value=$2
  mkdir -p "$(dirname "${ROADSHOW_ENV_FILE}")"
  touch "${ROADSHOW_ENV_FILE}" "${HOME}/.bashrc"
  if grep -q "^export ${name}=" "${ROADSHOW_ENV_FILE}" 2>/dev/null; then
    sed -i "/^export ${name}=/d" "${ROADSHOW_ENV_FILE}"
  fi
  if grep -q "^export ${name}=" "${HOME}/.bashrc" 2>/dev/null; then
    sed -i "/^export ${name}=/d" "${HOME}/.bashrc"
  fi
  printf 'export %s=%q\n' "${name}" "${value}" >> "${ROADSHOW_ENV_FILE}"
  printf 'export %s=%q\n' "${name}" "${value}" >> "${HOME}/.bashrc"
  # shellcheck disable=SC2163
  export "${name}=${value}"
}

load_roadshow_env() {
  if [[ -f "${ROADSHOW_ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ROADSHOW_ENV_FILE}"
    return 0
  fi
  # Fallback: pull only known exports from ~/.bashrc without executing the full file
  if [[ -f "${HOME}/.bashrc" ]]; then
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        export\ ROX_*|export\ QUAY_*|export\ TUTORIAL_HOME=*|export\ APP_HOME=*)
          # shellcheck disable=SC2163
          eval "${line}"
          ;;
      esac
    done < "${HOME}/.bashrc"
  fi
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

Environment:
  MINIO_REPLACEMENT_IMAGE   Public image used when Quay's MinIO pod cannot pull
                            quay.io/minio/minio. Default:
                            docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z
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
    load_roadshow_env
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
TOTAL=$((TOTAL + 3)) # admin + configure quay + wait central
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

  if [[ -z "${ROX_API_TOKEN:-}" ]]; then
    load_roadshow_env
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

# Resolve Quay registry hostname. Showroom clusters commonly use namespace "quay"
# (route quay-quay); some older labs used "quay-enterprise".
detect_quay_url() {
  local ns route host
  for ns in quay quay-enterprise; do
    for route in quay-quay quay; do
      host="$(oc -n "${ns}" get route "${route}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
      if [[ -n "${host}" ]]; then
        echo "${host}"
        return 0
      fi
    done
  done
  # Last resort: any route whose name/host contains "quay"
  host="$(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' 'tolower($2) ~ /quay/ || tolower($3) ~ /quay/ { print $3; exit }')"
  if [[ -n "${host}" ]]; then
    echo "${host}"
    return 0
  fi
  return 1
}

# Labs expect podman; install it when missing (common on minimal bastions).
ensure_podman() {
  if command -v podman >/dev/null 2>&1; then
    return 0
  fi
  echo "podman not found; attempting install..."
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y podman
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y podman
  else
    echo "Error: podman is required but could not be installed (no dnf/yum)." >&2
    return 1
  fi
  command -v podman >/dev/null 2>&1
}

do_quay_login() {
  ensure_podman || return 1
  QUAY_URL="$(detect_quay_url)" || {
    echo "Error: could not find a Quay route (tried namespaces quay, quay-enterprise)." >&2
    return 1
  }
  persist_var QUAY_USER "${QUAY_USER}"
  persist_var QUAY_URL "${QUAY_URL}"
  echo "Using Quay at ${QUAY_URL}"
  podman login "${QUAY_URL}" -u "${QUAY_USER}" -p "${QUAY_PASSWORD}"
}

do_golden_image() {
  ensure_podman || return 1
  podman pull "${PYTHON_ALPINE_BASE}"
  podman tag "${PYTHON_ALPINE_BASE}" "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
  podman push "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
}

do_frontend_image() {
  ensure_podman || return 1
  load_roadshow_env
  if [[ -z "${TUTORIAL_HOME:-}" || -z "${QUAY_URL:-}" || -z "${QUAY_USER:-}" ]]; then
    echo "Error: TUTORIAL_HOME / QUAY_URL / QUAY_USER must be set before building the frontend image." >&2
    return 1
  fi
  sed -i "s|^FROM python:3\.12-alpine[^ ]* AS \(\w\+\)|FROM ${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1 AS \1|" \
    "${TUTORIAL_HOME}/app-images/frontend/Dockerfile"
  cd "${TUTORIAL_HOME}/app-images/frontend/"
  podman build -t "${QUAY_URL}/${QUAY_USER}/frontend:0.1" .
  podman push "${QUAY_URL}/${QUAY_USER}/frontend:0.1" --remove-signatures
}

# True when a MinIO server container is waiting on a pull of minio/minio.
minio_pull_failed() {
  local ns=$1
  local count
  count="$(oc -n "${ns}" get pods -o json | jq '
    [ .items[]
      | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]
      | select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull")
      | select((.image // "") | test("minio/minio"))
    ] | length
  ')"
  [[ "${count}" -gt 0 ]]
}

# Namespace that holds the roadshow Quay install.
quay_namespace() {
  local ns
  for ns in quay quay-enterprise; do
    if oc get namespace "${ns}" >/dev/null 2>&1; then
      printf '%s\n' "${ns}"
      return 0
    fi
  done
  return 1
}

# Point MinIO workloads that still reference minio/minio at the public image.
# Returns 0 when at least one workload was updated and became ready.
repoint_minio_image() {
  local ns=$1
  local kind name container image kind_lc workload
  local -a workloads=()
  local seen=" "

  while IFS=$'\t' read -r kind name container image; do
    [[ -z "${kind}" ]] && continue
    echo "Quay MinIO cannot pull ${image}"
    echo "Using public image ${MINIO_REPLACEMENT_IMAGE} for ${kind}/${name} container ${container}"
    kind_lc="$(printf '%s' "${kind}" | tr '[:upper:]' '[:lower:]')"
    oc -n "${ns}" set image "${kind_lc}/${name}" "${container}=${MINIO_REPLACEMENT_IMAGE}" || return 1
    workloads+=("${kind_lc}/${name}")
  done < <(oc -n "${ns}" get deploy,sts -o json | jq -r '
    .items[]?
    | .kind as $kind
    | .metadata.name as $name
    | ((.spec.template.spec.containers // []) + (.spec.template.spec.initContainers // []))[]
    | select((.image // "") | test("minio/minio"))
    | [$kind, $name, .name, .image] | @tsv
  ')

  if [[ "${#workloads[@]}" -eq 0 ]]; then
    echo "Error: MinIO is in ImagePullBackOff but no Deployment or StatefulSet uses a minio/minio image." >&2
    oc -n "${ns}" get pods -o wide >&2 || true
    oc -n "${ns}" get events --sort-by='.lastTimestamp' >&2 | tail -n 20 || true
    return 1
  fi

  for workload in "${workloads[@]}"; do
    [[ "${seen}" == *" ${workload} "* ]] && continue
    seen+="${workload} "
    oc -n "${ns}" rollout restart "${workload}" >/dev/null || return 1
    if ! oc -n "${ns}" rollout status "${workload}" --timeout=300s; then
      echo "Error: ${workload} did not become ready with ${MINIO_REPLACEMENT_IMAGE}" >&2
      oc -n "${ns}" get pods -o wide >&2 || true
      oc -n "${ns}" get events --sort-by='.lastTimestamp' >&2 | tail -n 20 || true
      return 1
    fi
  done
}

quay_instance_healthy() {
  local host
  host="$(detect_quay_url 2>/dev/null || true)"
  [[ -n "${host}" ]] || return 1
  curl -kfsS --connect-timeout 5 --max-time 15 "https://${host}/health/instance" >/dev/null
}

# Repair Quay object storage before the rest of the lab. A healthy registry
# is left alone. A MinIO ImagePullBackOff is switched to MINIO_REPLACEMENT_IMAGE.
do_ensure_quay() {
  local ns repaired=false
  ns="$(quay_namespace)" || {
    echo "Error: Quay namespace not found (tried quay, quay-enterprise)." >&2
    return 1
  }
  echo "Checking Quay in namespace ${ns}"

  if ! minio_pull_failed "${ns}"; then
    if quay_instance_healthy; then
      echo "Quay is up at $(detect_quay_url); MinIO image left unchanged."
      return 0
    fi
    echo "Quay is not healthy yet, and MinIO is not failing an image pull."
    echo "Waiting for the registry health endpoint..."
  else
    echo "Quay is down: MinIO is in ImagePullBackOff."
    echo "Public replacement: ${MINIO_REPLACEMENT_IMAGE}"
    repoint_minio_image "${ns}" || return 1
    repaired=true
  fi

  local deadline=$((SECONDS + 600))
  local next_note=0
  while (( SECONDS < deadline )); do
    if quay_instance_healthy; then
      echo "Quay is up at $(detect_quay_url)"
      return 0
    fi
    if (( SECONDS >= next_note )); then
      echo "Waiting for Quay health endpoint..."
      next_note=$((SECONDS + 30))
    fi
    sleep 5
  done

  echo "Error: Quay did not become healthy within 600s (namespace ${ns})." >&2
  if [[ "${repaired}" == true ]]; then
    echo "MinIO was switched to ${MINIO_REPLACEMENT_IMAGE}" >&2
  fi
  oc -n "${ns}" get pods -o wide >&2 || true
  oc -n "${ns}" get quayregistry,route,deploy >&2 || true
  oc -n "${ns}" get events --sort-by='.lastTimestamp' >&2 | tail -n 30 || true
  return 1
}

progress_run "Verify OpenShift access" do_verify_admin
progress_run "Configure Quay" do_ensure_quay
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
  # Heartbeat while background configure runs so the bar does not look stuck.
  while kill -0 "${configure_pid}" 2>/dev/null; do
    progress_render "Waiting for RHACS configure to finish"
    sleep 2
  done
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
  progress_render "RHACS configure finished"
  load_roadshow_env
fi

if [[ "${SKIP_IMAGES}" != true ]]; then
  progress_run "Build and push frontend image" do_frontend_image
fi

progress_done "Lab environment setup complete"
load_roadshow_env

progress_success_banner "Lab environment setup completed successfully" \
  "Quay registry reachable" \
  "RHACS CLI ready (ROX_CENTRAL_ADDRESS / ROX_API_TOKEN saved)" \
  "Workshop demo applications deployed" \
  "Quay images ready (golden base + frontend, when image steps ran)" \
  "Env file: ${ROADSHOW_ENV_FILE}" \
  "Detailed log: ${LOG_FILE}"
