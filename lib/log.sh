# shellcheck shell=bash
# Output helpers: colours, info/ok/warn/die, run (print then run), confirm.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

stdout_is_tty() {
  [[ -t 1 ]]
}

# Colours only on a terminal, and never when NO_COLOR is set (no-color.org).
set_colours() {
  if stdout_is_tty && [[ -z "${NO_COLOR:-}" ]]; then
    C_BLUE=$'\e[34m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
  else
    C_BLUE="" C_YELLOW="" C_RED="" C_GREEN="" C_DIM="" C_RESET=""
  fi
}
set_colours

# Remove colour codes from a file in place (the log keeps plain text).
strip_colours() {
  local tmp="$1.tmp.$$"
  if sed $'s/\e\\[[0-9;]*m//g' "$1" >"${tmp}"; then mv "${tmp}" "$1"; else rm -f "${tmp}"; fi
}

info() { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }

ok() { printf '%s ok%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }

# Warnings inside a step are also collected for the summary.
warn() {
  printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
  [[ -z "${STEP_WARN_FILE}" ]] || printf '%s\n' "$*" >>"${STEP_WARN_FILE}" 2>/dev/null || true
}

die() {
  printf '%serror%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
  exit 1
}

# Run a command, or print it in dry-run mode. Quiet by default: the command's
# output goes to the log only, and its last lines are shown if it fails.
# --verbose (or no step dir yet) shows the output as it comes.
run() {
  if ((DRY_RUN)); then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  printf '   %s$ %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
  if ((VERBOSE)) || [[ -z "${RUN_DIR}" ]]; then
    "$@"
    return
  fi
  local out rc=0
  out="$(mktemp "${RUN_DIR}/cmd.XXXXXX")" || { "$@"; return; }
  "$@" >"${out}" 2>&1 || rc=$?
  [[ -z "${LOG_FILE}" ]] || cat "${out}" >>"${LOG_FILE}" 2>/dev/null || true
  if ((rc != 0)) && [[ -s "${out}" ]]; then
    printf '   %soutput (last 40 lines; all of it is in the log):%s\n' "${C_RED}" "${C_RESET}" >&2
    tail -n 40 "${out}" | sed 's/^/   | /' >&2
  fi
  rm -f "${out}"
  ((rc == 0)) || note_failure "$*"
  return "${rc}"
}

# Record the first failure of a step, with the line that called run/as_root:
# "failed at lib/steps.sh:42: git clone ...". The summary prints it.
note_failure() {
  [[ -n "${STEP_ERR_FILE:-}" && ! -s "${STEP_ERR_FILE}" ]] || return 0
  local i=1
  while [[ "${FUNCNAME[i]:-}" == run || "${FUNCNAME[i]:-}" == run_tty || "${FUNCNAME[i]:-}" == as_root ]]; do
    i=$((i + 1))
  done
  printf 'failed at %s:%s: %s\n' "${BASH_SOURCE[i]#"${SCRIPT_DIR}"/}" "${BASH_LINENO[i - 1]}" "$1" \
    >"${STEP_ERR_FILE}" 2>/dev/null || true
}

# Like run, but never captures: for commands that talk to the user
# (passphrase, password prompts).
run_tty() {
  if ((DRY_RUN)); then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  printf '   %s$ %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
  "$@" || { local rc=$?; note_failure "$*"; return "${rc}"; }
}

# True when stdin is a terminal, so a question can be asked. Tests replace it.
have_tty() {
  [[ -t 0 ]]
}

# Ask a yes/no question; Enter means yes. Nobody to ask means no: an unattended
# run must say --yes.
confirm() {
  ((ASSUME_YES || DRY_RUN)) && return 0
  have_tty || return 1
  local reply
  read -r -p "$1 [Y/n] " reply
  [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
}
