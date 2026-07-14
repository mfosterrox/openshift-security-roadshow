#!/usr/bin/env bash
# Quiet progress UI for roadshow setup scripts.
# Shows a single progress bar + current step; details go to a log file.

PROGRESS_TOTAL=0
PROGRESS_CURRENT=0
PROGRESS_LOG=""
PROGRESS_TITLE="${PROGRESS_TITLE:-Setup}"
PROGRESS_VERBOSE="${PROGRESS_VERBOSE:-false}"
PROGRESS_WIDTH="${PROGRESS_WIDTH:-28}"

progress_init() {
  local total="$1"
  local log_path="${2:-}"
  local title="${3:-Setup}"
  PROGRESS_TOTAL="${total}"
  PROGRESS_CURRENT=0
  PROGRESS_TITLE="${title}"
  if [[ -z "${log_path}" ]]; then
    log_path="$(mktemp "${TMPDIR:-/tmp}/roadshow-setup.XXXXXX.log")"
  fi
  PROGRESS_LOG="${log_path}"
  : > "${PROGRESS_LOG}"
  if [[ ! -t 1 ]]; then
    # Non-TTY: still print simple status lines
    echo "${PROGRESS_TITLE}: logging to ${PROGRESS_LOG}"
  else
    echo "${PROGRESS_TITLE}"
    echo "Details: ${PROGRESS_LOG}"
    echo ""
  fi
}

progress_render() {
  local label="$1"
  local cur="${PROGRESS_CURRENT}"
  local total="${PROGRESS_TOTAL}"
  [[ "${total}" -lt 1 ]] && total=1
  local width="${PROGRESS_WIDTH}"
  local filled=$((cur * width / total))
  [[ "${filled}" -gt "${width}" ]] && filled="${width}"
  local empty=$((width - filled))
  local bar
  bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')$(printf '%*s' "${empty}" '' | tr ' ' '-')"
  if [[ -t 1 ]]; then
    printf '\r\033[K[%s] %d/%d  %s' "${bar}" "${cur}" "${total}" "${label}"
  else
    echo "[${cur}/${total}] ${label}"
  fi
}

progress_done() {
  local msg="${1:-Complete}"
  PROGRESS_CURRENT="${PROGRESS_TOTAL}"
  progress_render "${msg}"
  if [[ -t 1 ]]; then
    printf '\n'
  fi
}

# Run a command as the next progress step. On failure, dump log tail and exit.
progress_run() {
  local label="$1"
  shift
  PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
  progress_render "${label}"
  {
    echo ""
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) STEP ${PROGRESS_CURRENT}/${PROGRESS_TOTAL}: ${label} ====="
  } >> "${PROGRESS_LOG}"

  if [[ "${PROGRESS_VERBOSE}" == true ]]; then
    printf '\n'
    "$@" 2>&1 | tee -a "${PROGRESS_LOG}"
    return "${PIPESTATUS[0]}"
  fi

  local rc=0
  set +e
  "$@" >>"${PROGRESS_LOG}" 2>&1
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    if [[ -t 1 ]]; then
      printf '\n'
    fi
    echo "FAILED: ${label} (exit ${rc})" >&2
    echo "Last log lines (${PROGRESS_LOG}):" >&2
    tail -n 40 "${PROGRESS_LOG}" >&2 || true
    return "${rc}"
  fi
  return 0
}

# Run several independent jobs in parallel. Each job logs to its own file under PROGRESS_LOG_DIR
# (or beside PROGRESS_LOG). Updates the progress bar as each job finishes.
#
# Usage:
#   progress_run_parallel \
#     "Settings" "bash setup/rhacs/05-....sh" \
#     "Monitoring" "bash setup/monitoring/install.sh"
progress_run_parallel() {
  if [[ $(($# % 2)) -ne 0 || $# -lt 2 ]]; then
    echo "progress_run_parallel: expected label/command pairs" >&2
    return 1
  fi

  local -a labels=()
  local -a cmds=()
  while [[ $# -gt 0 ]]; do
    labels+=("$1")
    cmds+=("$2")
    shift 2
  done

  local n="${#labels[@]}"
  local log_dir
  log_dir="$(dirname "${PROGRESS_LOG}")"
  local -a pids=()
  local -a job_logs=()
  local i slug joblog
  local start_current="${PROGRESS_CURRENT}"

  {
    echo ""
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) PARALLEL x${n}: ${labels[*]} ====="
  } >> "${PROGRESS_LOG}"

  for i in "${!labels[@]}"; do
    slug="$(printf '%s' "${labels[$i]}" | tr -cs 'A-Za-z0-9._-' '_' | cut -c1-48)"
    joblog="${log_dir}/parallel-${slug}-$$.log"
    job_logs+=("${joblog}")
    (
      echo "===== START ${labels[$i]} $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
      set +e
      # shellcheck disable=SC2086
      bash -c "${cmds[$i]}"
      rc=$?
      echo "===== END ${labels[$i]} rc=${rc} $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
      exit "${rc}"
    ) >"${joblog}" 2>&1 &
    pids+=("$!")
  done

  local completed=0 failed=0
  local -a failed_labels=()
  # Track which pids still running (1=running)
  local -a alive=()
  for i in "${!pids[@]}"; do
    alive[$i]=1
  done

  while [[ "${completed}" -lt "${n}" ]]; do
    for i in "${!pids[@]}"; do
      [[ "${alive[$i]}" -eq 1 ]] || continue
      if ! kill -0 "${pids[$i]}" 2>/dev/null; then
        local rc=0
        wait "${pids[$i]}" || rc=$?
        alive[$i]=0
        completed=$((completed + 1))
        PROGRESS_CURRENT=$((start_current + completed))
        {
          echo ""
          echo "----- parallel result: ${labels[$i]} (exit ${rc}) -----"
          cat "${job_logs[$i]}"
        } >> "${PROGRESS_LOG}"
        if [[ "${rc}" -ne 0 ]]; then
          failed=$((failed + 1))
          failed_labels+=("${labels[$i]}")
          progress_render "FAILED: ${labels[$i]} (${completed}/${n})"
        else
          progress_render "Parallel ${completed}/${n} done — ${labels[$i]}"
        fi
      fi
    done
    if [[ "${completed}" -lt "${n}" ]]; then
      local running_names=""
      for i in "${!pids[@]}"; do
        [[ "${alive[$i]}" -eq 1 ]] || continue
        if [[ -n "${running_names}" ]]; then
          running_names+=", "
        fi
        running_names+="${labels[$i]}"
      done
      # Keep bar on running set without advancing count twice
      local show_cur=$((start_current + completed))
      local saved="${PROGRESS_CURRENT}"
      PROGRESS_CURRENT="${show_cur}"
      progress_render "Parallel (${completed}/${n}) running: ${running_names}"
      PROGRESS_CURRENT="${saved}"
      sleep 1
    fi
  done

  if [[ "${failed}" -gt 0 ]]; then
    if [[ -t 1 ]]; then
      printf '\n'
    fi
    echo "FAILED parallel jobs: ${failed_labels[*]}" >&2
    echo "See ${PROGRESS_LOG} (and ${log_dir}/parallel-*.log)" >&2
    local fl
    for fl in "${failed_labels[@]}"; do
      echo "---- last lines: ${fl} ----" >&2
      # Find matching job log by label slug
      slug="$(printf '%s' "${fl}" | tr -cs 'A-Za-z0-9._-' '_' | cut -c1-48)"
      tail -n 30 "${log_dir}/parallel-${slug}-$$.log" >&2 || true
    done
    return 1
  fi
  return 0
}
