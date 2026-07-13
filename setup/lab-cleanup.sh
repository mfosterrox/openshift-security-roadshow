#!/usr/bin/env bash
# Reset transient lab resources after each ACS module.
# Usage: bash setup/lab-cleanup.sh --module 01
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

if [[ ! "${MODULE}" =~ ^(0[0-9]|10|101-[0-9]{2}|201-[0-9]{2}|301-[0-9]{2}|tssc-0[0-2])$ ]]; then
  echo "Error: unsupported module id '${MODULE}'" >&2
  usage
  exit 1
fi

record_completion() {
  mkdir -p "${PROGRESS_DIR}"
  touch "${PROGRESS_FILE}"
  if [[ -f "${PROGRESS_FILE}" ]]; then
    grep -v "^MODULE=${MODULE} " "${PROGRESS_FILE}" > "${PROGRESS_FILE}.tmp" 2>/dev/null || true
    mv "${PROGRESS_FILE}.tmp" "${PROGRESS_FILE}"
  fi
  printf 'MODULE=%s COMPLETE %s user=%s\n' \
    "${MODULE}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(whoami)" >> "${PROGRESS_FILE}"
}

# shellcheck source=/dev/null
source "${HOME}/.bashrc" 2>/dev/null || true

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
      fi
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
  *)
    rm -f "/tmp/lab-${MODULE}.txt" /tmp/lab-scratch-* 2>/dev/null || true
    echo "Removed temporary lab files for module ${MODULE}."
    ;;
esac

record_completion
echo "==> Module ${MODULE} cleanup complete."
