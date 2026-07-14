#!/usr/bin/env bash
#
# Configure OpenShift Lightspeed OLSConfig defaults for the roadshow.
#
# Non-interactive (preferred for setup/rhacs-configure.sh):
#   LIGHTSPEED_DEFAULT_PROVIDER + LIGHTSPEED_DEFAULT_MODEL
#     -> set OLS defaults only (provider must already exist)
#   LIGHTSPEED_BACKEND=bam + LIGHTSPEED_BAM_URL + ANTHROPIC_API_KEY/CLAUDE_API_KEY
#     -> create secret + provider + defaults
#   LIGHTSPEED_BACKEND=vertex + LIGHTSPEED_GCP_PROJECT + LIGHTSPEED_GCP_LOCATION
#     + LIGHTSPEED_GCP_CREDENTIALS_FILE
#     -> create secret from SA JSON + provider + defaults
#
# If OLS is missing or no credentials/defaults env vars are set, exit 0 with a skip message
# (MCP OLSConfig wiring is handled by setup/mcp-server/install.sh).
#
# Interactive walkthrough: pass --interactive
#
# Docs: https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../rhacs/lib/common.sh"

LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
LIGHTSPEED_OLSCONFIG_NAME="${LIGHTSPEED_OLSCONFIG_NAME:-cluster}"
LIGHTSPEED_SECRET_NAME="${LIGHTSPEED_SECRET_NAME:-anthropic-api-keys}"
LIGHTSPEED_RESTART="${LIGHTSPEED_RESTART:-true}"
LIGHTSPEED_PROVIDER_NAME="${LIGHTSPEED_PROVIDER_NAME:-claude}"
LIGHTSPEED_MODEL="${LIGHTSPEED_MODEL:-claude-sonnet-4-20250514}"

ols_oc() {
  command oc --request-timeout="${OLS_OC_REQUEST_TIMEOUT:-60s}" "$@"
}

declare -a OLS_CMD=()
OLS_SCOPE=""

resolve_ols_cmd() {
  OLS_CMD=(ols_oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}")
  if ! "${OLS_CMD[@]}" &>/dev/null; then
    OLS_CMD=(ols_oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}")
    if ! "${OLS_CMD[@]}" &>/dev/null; then
      return 1
    fi
    OLS_SCOPE="namespaced"
  else
    OLS_SCOPE="cluster"
  fi
  return 0
}

usage() {
  cat <<EOF
Usage: $0 [--interactive] [--help]

Non-interactive (default for roadshow configure):
  Export one of:
    LIGHTSPEED_DEFAULT_PROVIDER + LIGHTSPEED_DEFAULT_MODEL
    LIGHTSPEED_BACKEND=bam LIGHTSPEED_BAM_URL + ANTHROPIC_API_KEY (or CLAUDE_API_KEY)
    LIGHTSPEED_BACKEND=vertex LIGHTSPEED_GCP_PROJECT LIGHTSPEED_GCP_LOCATION LIGHTSPEED_GCP_CREDENTIALS_FILE

  --interactive   Run the original prompt-driven walkthrough
EOF
}

read_secret_token() {
  if [[ -n "${CLAUDE_API_KEY:-}" ]]; then
    printf '%s' "${CLAUDE_API_KEY}"
    return 0
  fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    printf '%s' "${ANTHROPIC_API_KEY}"
    return 0
  fi
  return 1
}

ensure_secret_bam() {
  local token
  token="$(read_secret_token)" || {
    print_error "Export CLAUDE_API_KEY or ANTHROPIC_API_KEY for BAM backend."
    return 1
  }
  [[ -n "${token}" ]] || {
    print_error "Empty API token."
    return 1
  }
  print_step "Creating/updating secret ${LIGHTSPEED_NAMESPACE}/${LIGHTSPEED_SECRET_NAME} (key apitoken)..."
  ols_oc create secret generic "${LIGHTSPEED_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" \
    --from-literal=apitoken="${token}" \
    --dry-run=client -o yaml | ols_oc apply -f -
}

ensure_secret_vertex() {
  local creds_path="$1"
  if [[ -z "${creds_path}" || ! -f "${creds_path}" ]]; then
    print_error "LIGHTSPEED_GCP_CREDENTIALS_FILE missing or not readable: ${creds_path:-}"
    return 1
  fi
  print_step "Creating/updating secret ${LIGHTSPEED_NAMESPACE}/${LIGHTSPEED_SECRET_NAME} from ${creds_path}..."
  ols_oc create secret generic "${LIGHTSPEED_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" \
    --from-file=apitoken="${creds_path}" \
    --dry-run=client -o yaml | ols_oc apply -f -
}

apply_ols_patch_python() {
  local patch_json_out="$1"
  shift
  export _OLS_PATCH_OUT="${patch_json_out}"
  export _OLS_BACKEND="$1"
  export _OLS_PROVIDER_NAME="$2"
  export _OLS_MODEL="$3"
  export _OLS_SECRET_NAME="$4"
  export _OLS_BAM_URL="${5:-}"
  export _OLS_GCP_PROJECT="$6"
  export _OLS_GCP_LOCATION="$7"
  export _OLS_DEFAULTS_ONLY="$8"

  python3 - <<'PY'
import json, os, sys

out_path = os.environ["_OLS_PATCH_OUT"]
backend = os.environ["_OLS_BACKEND"]
provider_name = os.environ["_OLS_PROVIDER_NAME"]
model_name = os.environ["_OLS_MODEL"]
secret_name = os.environ["_OLS_SECRET_NAME"]
bam_url = os.environ.get("_OLS_BAM_URL") or ""
gcp_project = os.environ.get("_OLS_GCP_PROJECT") or ""
gcp_location = os.environ.get("_OLS_GCP_LOCATION") or ""
defaults_only = os.environ.get("_OLS_DEFAULTS_ONLY") == "1"

with open(os.environ["_OLS_JSON_IN"], encoding="utf-8") as f:
    doc = json.load(f)

spec = doc.setdefault("spec", {})

if defaults_only:
    fragment = {"spec": {"ols": {"defaultProvider": provider_name, "defaultModel": model_name}}}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(fragment, f)
    sys.exit(0)

llm = spec.setdefault("llm", {})
providers = list(llm.get("providers") or [])
providers = [p for p in providers if isinstance(p, dict) and p.get("name") != provider_name]

entry = {
    "name": provider_name,
    "credentialsSecretRef": {"name": secret_name},
    "models": [{"name": model_name}],
}

if backend == "bam":
    if not bam_url:
        print("error: BAM URL required", file=sys.stderr)
        sys.exit(2)
    entry["type"] = "bam"
    entry["url"] = bam_url
elif backend == "vertex":
    if not gcp_project or not gcp_location:
        print("error: GCP project and region required for vertex", file=sys.stderr)
        sys.exit(2)
    region = gcp_location.strip()
    entry["type"] = "google_vertex_anthropic"
    entry["url"] = f"https://{region}-aiplatform.googleapis.com"
    entry["googleVertexAnthropicConfig"] = {"project": gcp_project, "location": region}
else:
    print(f"error: unknown backend {backend}", file=sys.stderr)
    sys.exit(2)

providers.append(entry)
llm["providers"] = providers
ols = spec.setdefault("ols", {})
ols["defaultProvider"] = provider_name
ols["defaultModel"] = model_name

fragment = {
    "spec": {
        "llm": {"providers": llm["providers"]},
        "ols": {"defaultProvider": ols["defaultProvider"], "defaultModel": ols["defaultModel"]},
    }
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(fragment, f)
PY
}

run_patch_and_restart() {
  local defaults_only_flag="$1"
  local backend="$2"
  local provider_name="$3"
  local model_name="$4"
  local bam_url="$5"
  local gcp_project="$6"
  local gcp_location="$7"

  local tmpjson patchfile
  tmpjson="$(mktemp)"
  patchfile="$(mktemp)"
  if ! "${OLS_CMD[@]}" -o json > "${tmpjson}"; then
    print_error "Failed to export OLSConfig JSON"
    rm -f "${tmpjson}"
    return 1
  fi

  export _OLS_JSON_IN="${tmpjson}"
  if ! apply_ols_patch_python "${patchfile}" "${backend}" "${provider_name}" "${model_name}" \
    "${LIGHTSPEED_SECRET_NAME}" "${bam_url}" "${gcp_project}" "${gcp_location}" "${defaults_only_flag}"; then
    rm -f "${tmpjson}" "${patchfile}"
    print_error "Could not build the configuration patch."
    return 1
  fi

  print_step "Applying change to OLSConfig..."
  local prc=0
  if [[ "${OLS_SCOPE}" == "cluster" ]]; then
    ols_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" --type=merge -p "$(cat "${patchfile}")" || prc=$?
  else
    ols_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" --type=merge -p "$(cat "${patchfile}")" || prc=$?
  fi
  rm -f "${tmpjson}" "${patchfile}"

  if [[ "${prc}" -ne 0 ]]; then
    print_error "oc patch failed. Check messages above (RBAC or invalid provider settings)."
    return 1
  fi

  print_info "✓ OLSConfig updated. Default provider «${provider_name}», model «${model_name}»."

  if [[ "${LIGHTSPEED_RESTART}" == "true" ]] && ols_oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
    print_step "Restarting lightspeed-app-server..."
    ols_oc rollout restart deployment/lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" >/dev/null || true
    print_info "✓ Restart triggered."
  fi
}

run_noninteractive() {
  if [[ -n "${LIGHTSPEED_DEFAULT_PROVIDER:-}" && -n "${LIGHTSPEED_DEFAULT_MODEL:-}" ]]; then
    print_step "Setting OLS defaults only (provider already expected in OLSConfig)"
    run_patch_and_restart "1" "" "${LIGHTSPEED_DEFAULT_PROVIDER}" "${LIGHTSPEED_DEFAULT_MODEL}" "" "" ""
    return $?
  fi

  local backend="${LIGHTSPEED_BACKEND:-}"
  backend="$(echo "${backend}" | tr '[:upper:]' '[:lower:]')"
  local pname="${LIGHTSPEED_PROVIDER_NAME}"
  local mname="${LIGHTSPEED_MODEL}"

  case "${backend}" in
    bam)
      [[ -n "${LIGHTSPEED_BAM_URL:-}" ]] || {
        print_warn "LIGHTSPEED_BACKEND=bam but LIGHTSPEED_BAM_URL is unset; skipping LLM configure."
        return 0
      }
      ensure_secret_bam || return 1
      run_patch_and_restart "0" "bam" "${pname}" "${mname}" "${LIGHTSPEED_BAM_URL}" "" ""
      ;;
    vertex)
      ensure_secret_vertex "${LIGHTSPEED_GCP_CREDENTIALS_FILE:-}" || return 1
      run_patch_and_restart "0" "vertex" "${pname}" "${mname}" "" \
        "${LIGHTSPEED_GCP_PROJECT:-}" "${LIGHTSPEED_GCP_LOCATION:-us-central1}"
      ;;
    *)
      print_warn "No Lightspeed LLM env vars set; skipping (MCP OLSConfig wiring may still apply via mcp-server)."
      print_info "Set LIGHTSPEED_DEFAULT_PROVIDER/MODEL or LIGHTSPEED_BACKEND=bam|vertex with credentials."
      return 0
      ;;
  esac
}

walkthrough() {
  echo ""
  print_info "Connected. OLSConfig «${LIGHTSPEED_OLSCONFIG_NAME}» is ${OLS_SCOPE}-scoped."
  echo ""
  echo "  1) Switch default only (provider already in OLSConfig)"
  echo "  2) Add Claude provider (secret + OLSConfig) and make it default"
  echo ""
  local choice
  read -r -p "Enter 1 or 2 [1]: " choice
  choice="${choice:-1}"

  case "${choice}" in
    1)
      local pname mname
      read -r -p "Provider name [Anthropic]: " pname
      pname="${pname:-Anthropic}"
      read -r -p "Model name [claude-sonnet-4-20250514]: " mname
      mname="${mname:-claude-sonnet-4-20250514}"
      run_patch_and_restart "1" "" "${pname}" "${mname}" "" "" ""
      ;;
    2)
      local sname conn backend gcp_proj gcp_loc bam_url gcp_file pname mname
      read -r -p "Secret name [${LIGHTSPEED_SECRET_NAME}]: " sname
      LIGHTSPEED_SECRET_NAME="${sname:-${LIGHTSPEED_SECRET_NAME}}"
      echo "  A) Google Cloud Vertex AI"
      echo "  B) BAM-style HTTPS URL + API token"
      read -r -p "Enter A or B [B]: " conn
      conn="$(echo "${conn:-B}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${conn}" == "a" ]]; then
        backend="vertex"
        read -r -p "GCP project ID: " gcp_proj
        read -r -p "GCP region [us-central1]: " gcp_loc
        gcp_loc="${gcp_loc:-us-central1}"
        read -r -p "Path to GCP service account JSON: " gcp_file
        ensure_secret_vertex "${gcp_file}"
      else
        backend="bam"
        read -r -p "Base URL (example: https://your-host/v1): " bam_url
        ensure_secret_bam
      fi
      read -r -p "Provider name [claude]: " pname
      pname="${pname:-claude}"
      read -r -p "Model id [claude-sonnet-4-20250514]: " mname
      mname="${mname:-claude-sonnet-4-20250514}"
      run_patch_and_restart "0" "${backend}" "${pname}" "${mname}" "${bam_url:-}" "${gcp_proj:-}" "${gcp_loc:-}"
      ;;
    *)
      print_error "Please enter 1 or 2."
      return 1
      ;;
  esac
}

main() {
  local mode="auto"
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --interactive) mode="interactive"; shift || true ;;
    "") ;;
    *)
      print_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac

  require_cmd oc python3 || exit 1
  require_oc || exit 1

  if ! resolve_ols_cmd; then
    print_warn "OLSConfig «${LIGHTSPEED_OLSCONFIG_NAME}» not found; skipping Lightspeed LLM configure."
    print_info "Showroom should install OpenShift Lightspeed; MCP wiring needs OLSConfig."
    exit 0
  fi

  if [[ "${mode}" == "interactive" ]]; then
    walkthrough
  else
    run_noninteractive
  fi
}

main "$@"
