#!/usr/bin/env bash
# Reset transient lab resources after each module.
# Usage: bash setup/lab-cleanup.sh --module 101-01
#
# Do not source ~/.bashrc here: on lab bastions it often calls `exit` for
# non-interactive shells and aborts this script with no output.
# Exported env vars (ROX_*, APP_HOME, etc.) are already inherited from the parent shell.
set -euo pipefail

MODULE=""
PROGRESS_DIR="${HOME}/.acs-roadshow"
PROGRESS_FILE="${PROGRESS_DIR}/progress"

usage() {
  cat <<'EOF'
Usage: lab-cleanup.sh --module MODULE

MODULE examples: 00-10 (ACS), 101-01, 201-06, 301-10, tssc-00, tssc-01, tssc-02
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${MODULE}" ]]; then
  echo "Error: --module is required" >&2
  usage
  exit 1
fi

if [[ ! "${MODULE}" =~ ^(0[0-9]|10|101-[0-9]{2}|201-[0-9]{2}|301-[0-9]{2}|tssc-0[0-2])$ ]]; then
  echo "Error: unsupported module id '${MODULE}'" >&2
  usage
  exit 1
fi

record_completion() {
  mkdir -p "${PROGRESS_DIR}"
  touch "${PROGRESS_FILE}"
  # Drop prior markers for this module (new + legacy formats); ignore "no match" under set -e
  grep -v -E "^(MODULE=${MODULE} |Module ${MODULE} done[[:space:]]*$)" \
    "${PROGRESS_FILE}" > "${PROGRESS_FILE}.tmp" 2>/dev/null || true
  mv "${PROGRESS_FILE}.tmp" "${PROGRESS_FILE}"
  printf 'Module %s done\n' "${MODULE}" >> "${PROGRESS_FILE}"
}

delete_projects() {
  local deleted_any=false
  local ns
  for ns in "$@"; do
    if oc get project "${ns}" >/dev/null 2>&1; then
      oc delete project "${ns}" --wait=false
      echo "Namespace deleted: ${ns}"
      deleted_any=true
    fi
  done
  if [[ "${deleted_any}" == "false" ]]; then
    echo "Namespace(s) $* not found (already cleaned up)."
  fi
}

echo "==> Cleaning up module ${MODULE} resources..."

case "${MODULE}" in
  00)
    rm -f /tmp/frontend-build.log /tmp/quay-push.log 2>/dev/null || true
    echo "Removed temporary image build logs."
    ;;
  01)
    rm -f /tmp/rhacs-risk-notes.txt 2>/dev/null || true
    echo "Removed local RHACS navigation scratch files."
    ;;
  02)
    rm -f /tmp/vuln-report-*.txt 2>/dev/null || true
    echo "Removed temporary vulnerability report files."
    ;;
  03)
    rm -f /tmp/process-baseline-notes.txt 2>/dev/null || true
    echo "Removed process discovery scratch files."
    ;;
  04)
    if [[ -n "${ROX_API_TOKEN:-}" && -n "${ROX_CENTRAL_ADDRESS:-}" ]]; then
      policy_id=$(curl --silent --insecure -X GET \
        -H "Authorization: Bearer ${ROX_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "https://${ROX_CENTRAL_ADDRESS}/v1/policies" \
        | jq -r '.policies[] | select(.name=="Alpine Linux Package Manager in Image - Enforce Deploy") | .id' 2>/dev/null || true)
      if [[ -n "${policy_id}" && "${policy_id}" != "null" ]]; then
        curl --silent --insecure -X DELETE \
          -H "Authorization: Bearer ${ROX_API_TOKEN}" \
          -H "Content-Type: application/json" \
          "https://${ROX_CENTRAL_ADDRESS}/v1/policies/${policy_id}" >/dev/null || true
        echo "Removed lab deploy enforcement policy."
      else
        echo "No lab deploy enforcement policy found to remove."
      fi
    else
      echo "ROX_API_TOKEN / ROX_CENTRAL_ADDRESS not set; skipped policy cleanup."
    fi
    if [[ -n "${APP_HOME:-}" && -d "${APP_HOME}/skupper-demo" ]]; then
      oc apply -f "${APP_HOME}/skupper-demo/" >/dev/null
      echo "Redeployed Skupper demo application."
    fi
    ;;
  05)
    rm -f /tmp/audit-search-*.json 2>/dev/null || true
    echo "Removed temporary audit log query files."
    ;;
  06)
    rm -f /tmp/compliance-notes.txt 2>/dev/null || true
    echo "Removed compliance review scratch files."
    ;;
  07)
    rm -f /tmp/notification-test.log 2>/dev/null || true
    echo "Removed notification test scratch files."
    ;;
  08)
    unset CLUSTER_ID 2>/dev/null || true
    rm -f /tmp/api-response-*.json 2>/dev/null || true
    echo "Cleared temporary API session variables and response files."
    ;;
  09)
    rm -f /tmp/netpol-*.yaml 2>/dev/null || true
    echo "Removed temporary network policy drafts."
    ;;
  10)
    rm -f /tmp/checkpointctl /tmp/checkpoint-payment-gateway_* 2>/dev/null || true
    echo "Removed CRIU checkpoint scratch files from /tmp."
    ;;
  101-01)
    delete_projects 101-01-httpd-demo
    ;;
  101-02)
    delete_projects 101-02-demo team-payments-dev
    ;;
  101-03)
    delete_projects 101-03-r-rbac
    ;;
  101-04)
    delete_projects 101-04-s-scc-demo 101-04-s-resources-demo
    ;;
  101-05)
    delete_projects 101-05-n-netpol-demo
    ;;
  101-06)
    delete_projects 101-06-s-secrets
    ;;
  101-07)
    delete_projects 101-07-i-trusted
    ;;
  101-08|101-09|101-10)
    rm -f "/tmp/lab-${MODULE}.txt" /tmp/lab-scratch-* 2>/dev/null || true
    echo "Removed temporary lab files for module ${MODULE}."
    ;;
  101-11|101-12)
    # 101-12 reuses the 101-11 rebuild project
    delete_projects 101-11-r-rebuild
    ;;
  201-01)
    delete_projects app-frontend app-backend app-db
    ;;
  201-02)
    delete_projects 201-02-c-rbac-lab
    ;;
  201-03)
    delete_projects 201-03-w-harden
    ;;
  201-04)
    rm -f /tmp/lab-201-04.txt /tmp/lab-scratch-* 2>/dev/null || true
    echo "Removed temporary lab files for module 201-04."
    ;;
  201-05)
    delete_projects 201-05-s-pipeline
    ;;
  201-06)
    rm -f /tmp/lab-201-06.txt /tmp/lab-scratch-* 2>/dev/null || true
    echo "Vault workshop cleanup is handled by cleanup-vault-lab.sh; recorded module completion."
    ;;
  201-07)
    delete_projects 201-07-a-correlation
    ;;
  201-08)
    oc delete compliancescans baseline-scan tailored-scan -n openshift-compliance --ignore-not-found 2>/dev/null || true
    oc delete tailoredprofile rhcos4-moderate-tailored -n openshift-compliance --ignore-not-found 2>/dev/null || true
    echo "Removed compliance scan and tailored profile objects (if present)."
    ;;
  201-09)
    delete_projects 201-09-demo
    ;;
  201-10)
    delete_projects 201-10-s-sandbox
    ;;
  201-11)
    delete_projects 201-11-a-govern
    ;;
  301-10)
    rm -f /tmp/lab-301-10.txt /tmp/lab-scratch-* 2>/dev/null || true
    echo "ZTWIM workshop cleanup is handled by configure-ztwim-postgresql-lab.sh; recorded module completion."
    ;;
  301-11)
    delete_projects 301-11-demo
    ;;
  tssc-00|tssc-01|tssc-02)
    rm -f "/tmp/lab-${MODULE}.txt" /tmp/lab-scratch-* 2>/dev/null || true
    echo "Removed temporary lab files for module ${MODULE}."
    ;;
  *)
    rm -f "/tmp/lab-${MODULE}.txt" /tmp/lab-scratch-* 2>/dev/null || true
    echo "Removed temporary lab files for module ${MODULE}."
    ;;
esac

record_completion
echo "Operation successful."
echo "==> Module ${MODULE} cleanup complete."
