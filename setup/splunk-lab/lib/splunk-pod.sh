#!/usr/bin/env bash
# Shared oc-exec helpers for the Splunk pod (UID 41812).
# Sourced by configure-openshift-audit.sh and push-recent-audit.sh.
# Mirrors the exec fallbacks in setup.sh (dash -u / --user / sudo -u splunk).

: "${SPLUNK_EXEC_USER:=41812}"
: "${SPLUNK_NAMESPACE:=splunk}"
: "${SPLUNK_NAME:=splunk}"

_splunk_oc_mode_cached_key=""
_splunk_oc_mode_cached_val=""

readonly _SP_RED='\033[0;31m'
readonly _SP_GREEN='\033[0;32m'
readonly _SP_YELLOW='\033[1;33m'
readonly _SP_BLUE='\033[0;34m'
readonly _SP_NC='\033[0m'

print_info() { echo -e "${_SP_GREEN}[INFO]${_SP_NC} $*"; }
print_warn() { echo -e "${_SP_YELLOW}[WARN]${_SP_NC} $*"; }
print_error() { echo -e "${_SP_RED}[ERROR]${_SP_NC} $*" >&2; }
print_step() { echo -e "${_SP_BLUE}[STEP]${_SP_NC} $*"; }

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    print_error "Required command not found: ${cmd}"
    exit 1
  fi
}

splunk_pod_name() {
  oc -n "${SPLUNK_NAMESPACE}" get pods -l "app=${SPLUNK_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

get_splunk_oc_exec_mode() {
  local namespace="$1"
  local pod="$2"

  if [ -n "${SPLUNK_FORCE_OC_EXEC_MODE:-}" ]; then
    printf '%s' "${SPLUNK_FORCE_OC_EXEC_MODE}"
    return 0
  fi
  if [ -z "${pod}" ] || [ -z "${namespace}" ]; then
    printf 'runuser'
    return 0
  fi
  local key="${namespace}/${pod}"
  if [ "${key}" = "${_splunk_oc_mode_cached_key}" ] && [ -n "${_splunk_oc_mode_cached_val}" ]; then
    printf '%s' "${_splunk_oc_mode_cached_val}"
    return 0
  fi

  local mode="runuser"
  if oc -n "${namespace}" exec -u "${SPLUNK_EXEC_USER}" "${pod}" -- true 2>/dev/null; then
    mode="dash_u"
  elif oc -n "${namespace}" exec --user="${SPLUNK_EXEC_USER}" "${pod}" -- true 2>/dev/null; then
    mode="long_user"
  fi
  _splunk_oc_mode_cached_key="${key}"
  _splunk_oc_mode_cached_val="${mode}"
  printf '%s' "${mode}"
}

splunk_oc_exec() {
  local namespace="$1"
  local pod="$2"
  shift 2
  local mode
  mode="$(get_splunk_oc_exec_mode "${namespace}" "${pod}")"

  case "${mode}" in
    dash_u)
      oc -n "${namespace}" exec -u "${SPLUNK_EXEC_USER}" "${pod}" -- "$@"
      ;;
    long_user)
      oc -n "${namespace}" exec --user="${SPLUNK_EXEC_USER}" "${pod}" -- "$@"
      ;;
    *)
      oc -n "${namespace}" exec "${pod}" -- sudo -n -u splunk -- "$@" 2>/dev/null || \
        oc -n "${namespace}" exec "${pod}" -- sudo -u splunk -- "$@"
      ;;
  esac
}

# stdin-aware exec (for piping audit lines into HEC).
splunk_oc_exec_i() {
  local namespace="$1"
  local pod="$2"
  shift 2
  local mode
  mode="$(get_splunk_oc_exec_mode "${namespace}" "${pod}")"

  case "${mode}" in
    dash_u)
      oc -n "${namespace}" exec -i -u "${SPLUNK_EXEC_USER}" "${pod}" -- "$@"
      ;;
    long_user)
      oc -n "${namespace}" exec -i --user="${SPLUNK_EXEC_USER}" "${pod}" -- "$@"
      ;;
    *)
      oc -n "${namespace}" exec -i "${pod}" -- sudo -n -u splunk -- "$@" 2>/dev/null || \
        oc -n "${namespace}" exec -i "${pod}" -- sudo -u splunk -- "$@"
      ;;
  esac
}

run_splunk_curl() {
  local namespace="$1"
  local pod="$2"
  shift 2
  if splunk_oc_exec "${namespace}" "${pod}" sh -c "command -v curl >/dev/null 2>&1"; then
    splunk_oc_exec "${namespace}" "${pod}" curl "$@"
  else
    splunk_oc_exec "${namespace}" "${pod}" /opt/splunk/bin/splunk cmd curl "$@"
  fi
}

create_or_get_splunk_hec_token() {
  local namespace="$1"
  local name="$2"
  local splunk_password="$3"
  local hec_name="$4"
  local sourcetype="${5:-kube:apiserver:audit}"

  local pod
  pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "${pod}" ]; then
    print_error "No Splunk pod found in namespace ${namespace}"
    return 1
  fi

  local auth_u="admin:${splunk_password}"

  run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" -X POST \
    "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http/http?output_mode=json" \
    --data-urlencode "disabled=0" >/dev/null 2>&1 || true

  local create_body create_code
  create_body="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" -w "\n%{http_code}" -X POST \
    "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http?output_mode=json" \
    --data-urlencode "name=${hec_name}" \
    --data-urlencode "index=main" \
    --data-urlencode "indexes=main" \
    --data-urlencode "sourcetype=${sourcetype}" \
    --data-urlencode "description=OpenShift kube-apiserver audit (roadshow 201-06)" \
    --data-urlencode "disabled=0" 2>/dev/null || true)"
  create_code="$(echo "${create_body}" | tail -n1)"
  create_body="$(echo "${create_body}" | sed '$d')"

  local token
  token="$(echo "${create_body}" | jq -r '.entry[0].content.token // empty' 2>/dev/null || true)"

  if [ -z "${token}" ]; then
    token="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" \
      "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http/${hec_name}?output_mode=json" 2>/dev/null | \
      jq -r '.entry[0].content.token // empty' 2>/dev/null || true)"
  fi

  if [ -z "${token}" ]; then
    token="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" \
      "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http?output_mode=json&count=0" 2>/dev/null | \
      jq -r --arg n "${hec_name}" '.entry[]? | select(.name==$n) | .content.token' 2>/dev/null | head -n1 || true)"
  fi

  if [ -z "${token}" ]; then
    print_error "Failed to create or read Splunk HEC token '${hec_name}' (create HTTP ${create_code:-n/a})"
    return 1
  fi
  printf '%s' "${token}"
}
