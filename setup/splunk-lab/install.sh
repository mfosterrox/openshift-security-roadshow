#!/usr/bin/env bash
#
# Splunk on OpenShift + RHACS TA-stackrox + OpenShift API audit forwarding.
# Wrapper for setup.sh then configure-openshift-audit.sh.
#
# Requires: oc (logged in), jq, curl — same as setup.sh.
# Uses ROX_CENTRAL_ADDRESS and ROX_API_TOKEN from the environment when present
# (RHACS notifier is skipped if they are unset).
#
# Optional env:
#   SPLUNK_RUN_CLEAN_FIRST — default false when using this wrapper.
#   SPLUNK_FORWARD_OPENSHIFT_AUDIT — run configure-openshift-audit.sh (default: true)
#   Other SPLUNK_* / RHACS_* vars — see setup.sh header.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SPLUNK_RUN_CLEAN_FIRST="${SPLUNK_RUN_CLEAN_FIRST:-false}"

bash "${SCRIPT_DIR}/setup.sh" "$@"

if [ "${SPLUNK_FORWARD_OPENSHIFT_AUDIT:-true}" = "true" ]; then
  bash "${SCRIPT_DIR}/configure-openshift-audit.sh"
fi
