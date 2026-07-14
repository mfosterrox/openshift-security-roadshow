#!/usr/bin/env bash
# Shared helpers for roadshow RHACS setup scripts.
# Roadshow persists ROX_CENTRAL_ADDRESS as host-only (no scheme); API/curl callers need https://.

# No-op stubs so ported scripts that call setup_rerun_* do not fail.
setup_rerun_register() { :; }
setup_rerun_set_script() { :; }
setup_rerun_hint_print() { :; }

print_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
print_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
print_step()  { echo -e "\033[0;34m[STEP]\033[0m $*"; }

# Strip scheme from an address (host or host:port).
rox_central_host() {
  local url="${1:-${ROX_CENTRAL_ADDRESS:-}}"
  url="${url#https://}"
  url="${url#http://}"
  url="${url%:443}"
  printf '%s' "${url}"
}

# Full https:// URL for curl/API (adds scheme if missing).
rox_central_url() {
  local url="${1:-${ROX_CENTRAL_ADDRESS:-}}"
  if [[ -z "${url}" ]]; then
    return 1
  fi
  if [[ "${url}" != https://* && "${url}" != http://* ]]; then
    url="https://${url}"
  fi
  printf '%s' "${url}"
}

# host:port for roxctl -e
rox_central_endpoint() {
  local host
  host="$(rox_central_host "${1:-}")"
  if [[ -z "${host}" ]]; then
    return 1
  fi
  if [[ "${host}" =~ :[0-9]+$ ]]; then
    printf '%s' "${host}"
  else
    printf '%s:443' "${host}"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    if ! command -v "${c}" >/dev/null 2>&1; then
      print_error "Required command not found: ${c}"
      return 1
    fi
  done
}

require_oc() {
  require_cmd oc || return 1
  if ! oc whoami >/dev/null 2>&1; then
    print_error "oc is not logged in. Run: oc login ..."
    return 1
  fi
}

# Resolve Central host from env or route; leave ROX_CENTRAL_ADDRESS as host-only.
resolve_rox_central_address() {
  local ns="${RHACS_NAMESPACE:-stackrox}"
  local host="${ROX_CENTRAL_ADDRESS:-}"
  host="$(rox_central_host "${host}")"
  if [[ -z "${host}" ]]; then
    host="$(oc -n "${ns}" get route central -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  fi
  if [[ -z "${host}" ]]; then
    print_error "Could not resolve ROX_CENTRAL_ADDRESS (set it or ensure route/central exists in ${ns})."
    return 1
  fi
  export ROX_CENTRAL_ADDRESS="${host}"
}

# Ensure ROX_API_TOKEN is set (generate from admin password if needed).
ensure_rox_api_token() {
  local ns="${RHACS_NAMESPACE:-stackrox}"
  if [[ -n "${ROX_API_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ -f "${HOME}/.bashrc" ]] && grep -qE '^(export[[:space:]]+)?ROX_API_TOKEN=' "${HOME}/.bashrc" 2>/dev/null; then
    local line
    line="$(grep -E '^(export[[:space:]]+)?ROX_API_TOKEN=' "${HOME}/.bashrc" | head -1)" || true
    if [[ -n "${line}" ]] && ! grep -qE '\$\(|`' <<<"${line}"; then
      [[ "${line}" =~ ^export[[:space:]]+ ]] || line="export ${line}"
      eval "${line}" 2>/dev/null || true
    fi
    if [[ -n "${ROX_API_TOKEN:-}" ]]; then
      return 0
    fi
  fi
  resolve_rox_central_address || return 1
  if [[ -z "${ROX_PASSWORD:-}" ]]; then
    ROX_PASSWORD="$(oc -n "${ns}" get secret central-htpasswd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  if [[ -z "${ROX_PASSWORD:-}" ]]; then
    print_error "ROX_API_TOKEN unset and could not read ROX_PASSWORD from central-htpasswd."
    return 1
  fi
  local url token_json
  url="$(rox_central_url)"
  print_info "Generating ROX_API_TOKEN via Central API..."
  token_json="$(curl -ksS --connect-timeout 15 --max-time 60 \
    -X POST \
    -u "admin:${ROX_PASSWORD}" \
    -H "Content-Type: application/json" \
    "${url}/v1/apitokens/generate" \
    -d "{\"name\":\"roadshow-configure-$(date +%s)\",\"roles\":[\"Admin\"]}")"
  ROX_API_TOKEN="$(printf '%s' "${token_json}" | jq -r '.token // empty')"
  if [[ -z "${ROX_API_TOKEN}" || "${#ROX_API_TOKEN}" -lt 20 ]]; then
    print_error "Failed to generate ROX_API_TOKEN. Response: ${token_json}"
    return 1
  fi
  export ROX_API_TOKEN
  print_info "✓ ROX_API_TOKEN generated (${#ROX_API_TOKEN} chars)"
}
