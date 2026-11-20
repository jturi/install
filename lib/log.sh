# shellcheck shell=bash
# Output helpers: colours, info/ok/warn/die, run (print then run), confirm.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

if [[ -t 1 ]]; then
  C_BLUE=$'\e[34m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
  C_BLUE="" C_YELLOW="" C_RED="" C_GREEN="" C_DIM="" C_RESET=""
fi

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

# Run a command, or print it in dry-run mode.
run() {
  if ((DRY_RUN)); then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  printf '   %s$ %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
  "$@"
}

confirm() {
  ((ASSUME_YES || DRY_RUN)) && return 0
  [[ -t 0 ]] || return 0
  local reply
  read -r -p "$1 [Y/n] " reply
  [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
}
