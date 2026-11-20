# shellcheck shell=bash
# Run flow: the selection on top of the catalog, the plan, steps in
# subshells with a summary, lock, log and sudo for a real run.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

# Load the catalog items for this machine.
load_catalog() {
  local family="$1" platform=linux wsl=0
  [[ "${family}" == "macos" ]] && platform=macos
  is_wsl && wsl=1
  catalog_load "${CATALOG_FILE}" "${platform}" "${wsl}"
  catalog_hide_unmapped "${family}"
}

# Print the distro package name of every ticked pkg item.
selected_packages() {
  local family="$1" i
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    [[ "${CAT_ACTION[i]}" == "pkg" && "${CAT_SEL[i]}" == "1" ]] || continue
    pkg_name "${family}" "${CAT_ITEM[i]}"
  done
}

# True when the item <group>.<item> is ticked.
item_selected() {
  local key="$1" i
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    if [[ "${CAT_GROUP[i]}.${CAT_ITEM[i]}" == "${key}" ]]; then
      [[ "${CAT_SEL[i]}" == "1" ]]
      return
    fi
  done
  return 1
}

# Tick or clear one item. Keys not on this platform are ignored.
set_selection() {
  local key="$1" value="$2" i
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    if [[ "${CAT_GROUP[i]}.${CAT_ITEM[i]}" == "${key}" ]]; then CAT_SEL[i]="${value}"; fi
  done
}

# True when any item with this exact action is ticked.
action_selected() {
  local wanted="$1" i
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    [[ "${CAT_ACTION[i]}" == "${wanted}" && "${CAT_SEL[i]}" == "1" ]] && return 0
  done
  return 1
}

# Apply this run's flags on top of the selection. Never saved.
apply_flag_overrides() {
  local i
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    if ((!DO_PACKAGES)) && [[ "${CAT_ACTION[i]}" == "pkg" ]]; then CAT_SEL[i]=0; fi
    if ((!DO_CONFIGS)) && [[ "${CAT_ACTION[i]}" == "step:configs" || "${CAT_ACTION[i]}" == "step:tpm" ]]; then CAT_SEL[i]=0; fi
    if [[ "${CAT_GROUP[i]}" == "terminals" ]]; then
      [[ "${TERMINAL_MODE}" != "install" ]] || CAT_SEL[i]=1
      [[ "${TERMINAL_MODE}" != "skip" ]] || CAT_SEL[i]=0
    fi
  done
  ((!DO_SSH_SERVER)) || set_selection extras.ssh-server 1
  ((!DO_SSH_LOCAL)) || set_selection extras.ssh-local-only 1
  # The server is a package: --no-packages always did skip it.
  ((DO_PACKAGES)) || set_selection extras.ssh-server 0
  [[ "${SSH_KEY_MODE}" != "create" ]] || set_selection extras.ssh-key 1
  [[ "${SSH_KEY_MODE}" != "skip" ]] || set_selection extras.ssh-key 0
  [[ "${ZSH_DEFAULT_MODE}" != "change" ]] || set_selection extras.zsh-login 1
  [[ "${ZSH_DEFAULT_MODE}" != "skip" ]] || set_selection extras.zsh-login 0
}

# Print what this run will do, one group per line.
print_plan() {
  local family="${1:-}" group i install skip
  info "Plan"
  while IFS= read -r group; do
    install="" skip=""
    for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
      [[ "${CAT_GROUP[i]}" == "${group}" ]] || continue
      if [[ "${CAT_SEL[i]}" == "1" ]]; then
        install="${install}${install:+, }${CAT_LABEL[i]}"
      else
        skip="${skip}${skip:+, }${CAT_LABEL[i]}"
      fi
    done
    [[ -z "${install}" ]] || printf '  install %-13s %s\n' "${group}" "${install}"
    [[ -z "${skip}" ]] || printf '  skip    %-13s %s\n' "${group}" "${skip}"
  done < <(catalog_groups)
  # pacman -Syu: Arch does not support partial upgrades, and -S against a
  # stale package database fails. Say so before "Go ahead?".
  if [[ "${family}" == "arch" ]] && action_selected pkg; then
    printf '  note    on Arch, installing a missing package runs a full system upgrade (pacman -Syu)\n'
  fi
}

# Run one step in a subshell, so `set -e` works inside it and a failure does not
# stop the next step. Subshells lose environment changes: see ensure_brew in main.
# A step that warned shows WARN in the summary; only FAILED makes the run fail.
run_step() {
  local title="$1" rc=0 start="${SECONDS}" n="${#STEP_LABELS[@]}"
  shift
  [[ -n "${RUN_DIR}" ]] || RUN_DIR="$(mktemp -d)"
  info "Step $((n + 1)): ${title}"
  STEP_WARN_FILE="${RUN_DIR}/warn.${n}" STEP_ERR_FILE="${RUN_DIR}/err.${n}"
  : >"${STEP_WARN_FILE}"
  : >"${STEP_ERR_FILE}"
  set +e
  (
    # -E: the ERR trap also fires inside functions. The first failure is
    # recorded with its place, for the summary.
    set -Ee
    trap 'note_error "${BASH_SOURCE[0]:-?}" "${LINENO}" "${BASH_COMMAND}"' ERR
    "$@"
  )
  rc=$?
  set -e
  STEP_WARN_FILE="" STEP_ERR_FILE=""
  STEP_LABELS+=("${title}")
  STEP_TIME+=("$((SECONDS - start))s")
  if ((rc != 0)); then
    STEP_STATUS+=("FAILED")
  elif [[ -s "${RUN_DIR}/warn.${n}" ]]; then
    STEP_STATUS+=("WARN")
  else
    STEP_STATUS+=("OK")
  fi
}

# ERR trap of a step: keep the first failing command and where it was, unless
# run() already recorded a better one.
note_error() {
  [[ -n "${STEP_ERR_FILE:-}" && ! -s "${STEP_ERR_FILE}" ]] || return 0
  # `return 1` from a function: it said why itself (warn), the place adds nothing.
  [[ "$3" != return* ]] || return 0
  printf 'failed at %s:%s: %s\n' "${1#"${SCRIPT_DIR}"/}" "$2" "$3" >"${STEP_ERR_FILE}" 2>/dev/null || true
}

# True when the step that ran last failed.
last_step_failed() {
  ((${#STEP_STATUS[@]})) && [[ "${STEP_STATUS[${#STEP_STATUS[@]} - 1]}" == "FAILED" ]]
}

# Print the result of every step, with its warnings. Returns 1 if any failed.
print_summary() {
  local i failed=0 color line
  info "Summary"
  for ((i = 0; i < ${#STEP_LABELS[@]}; i++)); do
    case "${STEP_STATUS[i]}" in
      OK) color="${C_GREEN}" ;;
      WARN) color="${C_YELLOW}" ;;
      *) color="${C_RED}" failed=1 ;;
    esac
    printf '  %s%-7s%s %5s  %s\n' "${color}" "${STEP_STATUS[i]}" "${C_RESET}" "${STEP_TIME[i]}" "${STEP_LABELS[i]}"
    [[ "${STEP_STATUS[i]}" != "FAILED" || ! -s "${RUN_DIR}/err.${i}" ]] ||
      printf '                 - %s\n' "$(cat "${RUN_DIR}/err.${i}")"
    [[ -s "${RUN_DIR}/warn.${i}" ]] || continue
    while IFS= read -r line; do printf '                 - %s\n' "${line}"; done <"${RUN_DIR}/warn.${i}"
  done
  [[ -z "${LOG_FILE}" ]] || printf '  Log: %s\n' "${LOG_FILE}"
  return "${failed}"
}

# Run every ticked step, in catalog-independent install order.
run_steps() {
  local family="$1" sshd_before=0 local_failed=0
  # Measured before anything installs; steps run in subshells and cannot
  # report state back. check_ssh_server is read-only.
  if item_selected extras.ssh-server && action_selected step:ssh-local-only &&
    [[ "$(check_ssh_server "${family}")" == "OK" ]]; then
    sshd_before=1
  fi
  if action_selected pkg || item_selected extras.ssh-server; then
    # In the main shell: PATH changes must reach the steps, which are subshells.
    [[ "${family}" != "macos" ]] || ensure_brew
    run_step packages install_packages "${family}"
  fi
  # The restriction goes in before sshd is enabled, so it never runs without it.
  if action_selected step:ssh-local-only; then
    run_step "ssh local network only" restrict_ssh_local_only "${family}"
    ! last_step_failed || local_failed=1
  fi
  if item_selected extras.ssh-server; then
    if ((local_failed)); then
      run_step "ssh server" ssh_server_fail_closed "${family}" "${sshd_before}"
    else
      run_step "ssh server" enable_ssh_server "${family}"
    fi
  fi
  if action_selected step:configs; then run_step configs install_configs "${family}"; fi
  if action_selected step:tpm; then run_step "tmux plugins" install_tpm; fi
  if action_selected step:terminals; then run_step terminals setup_terminals "${family}"; fi
  if action_selected step:wezterm-wsl; then run_step "WezTerm on Windows" install_windows_terminal; fi
  if action_selected step:ssh-key; then run_step "SSH key" setup_ssh_key; fi
  if action_selected step:zsh-login; then run_step "zsh login shell" setup_zsh_default; fi
  # Last: test that every ticked item is really there. A dry run changed nothing.
  if ((!DRY_RUN)); then run_step check check_selection "${family}"; fi
}

# Print where this copy of the repo came from: git commit, or the .source file
# that bootstrap.sh writes.
source_version() {
  if [[ -d "${SCRIPT_DIR}/.git" ]] && command -v git >/dev/null 2>&1 &&
    git -C "${SCRIPT_DIR}" describe --always --dirty 2>/dev/null; then
    return 0
  fi
  if [[ -f "${SCRIPT_DIR}/.source" ]]; then head -n 1 "${SCRIPT_DIR}/.source"; else echo "unknown version"; fi
}

# True when a ticked step needs root (sudo), so the password is asked once up front.
needs_root() {
  local family="$1"
  item_selected extras.ssh-server && return 0
  item_selected extras.ssh-local-only && return 0
  [[ "${family}" != "macos" ]] || return 1
  action_selected pkg || action_selected step:terminals || action_selected step:zsh-login
}

# Ask for the sudo password before the first step and keep it valid until the
# run ends, so a long install never stops halfway for a password.
prime_sudo() {
  ((!DRY_RUN)) || return 0
  ! is_root || return 0
  needs_root "$1" || return 0
  command -v sudo >/dev/null 2>&1 || return 0
  [[ -t 0 ]] || return 0
  info "Some steps need root: checking sudo once now"
  sudo -v || die "sudo failed; nothing installed"
  (while kill -0 "$$" 2>/dev/null; do
    sudo -n true 2>/dev/null
    sleep 50
  done) >/dev/null 2>&1 &
  SUDO_KEEPALIVE=$!
}

# One run at a time: a lock dir holding the owner's pid. A lock whose pid is
# gone (killed run, reboot) is taken over.
take_lock() {
  LOCK_DIR="$1"
  mkdir -p "$(dirname "${LOCK_DIR}")"
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    local pid
    pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      LOCK_DIR=""
      die "another setup.sh is running (pid ${pid})"
    fi
    warn "removing a stale lock left by pid ${pid:-unknown}"
    rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}" || { LOCK_DIR=""; die "cannot create lock ${LOCK_DIR}"; }
  fi
  printf '%s\n' "$$" >"${LOCK_DIR}/pid"
}

# Copy all output to a log file and keep the newest KEEP_LOGS logs.
start_log() {
  local dir="$1" old
  mkdir -p "${dir}" || { warn "cannot create ${dir}; not logging"; return 0; }
  # Prune first, keeping KEEP_LOGS - 1 old logs, so the new log is never a
  # candidate. Names hold the time, so a name sort is a time sort. Best effort.
  # shellcheck disable=SC2012 # names are ours: setup-<digits>_<digits>.log
  { ls -1r "${dir}"/setup-*.log 2>/dev/null | tail -n +"${KEEP_LOGS}" | while IFS= read -r old; do
    rm -f "${old}"
  done; } || true
  LOG_FILE="${dir}/setup-$(date +%Y%m%d_%H%M%S).log"
  : >>"${LOG_FILE}" || { warn "cannot write ${LOG_FILE}; not logging"; LOG_FILE=""; return 0; }
  exec > >(tee -a "${LOG_FILE}") 2>&1
  TEE_PID=$!
}

cleanup() {
  ((!PRUNE_BACKUPS)) || prune_backups
  [[ -z "${SUDO_KEEPALIVE}" ]] || kill "${SUDO_KEEPALIVE}" 2>/dev/null || true
  [[ -z "${LOCK_DIR}" ]] || rm -rf "${LOCK_DIR}"
  [[ -z "${RUN_DIR}" ]] || rm -rf "${RUN_DIR}"
  if [[ -n "${TEE_PID}" ]]; then
    # Let tee flush the last lines before the prompt comes back.
    exec 1>&- 2>&-
    wait "${TEE_PID}" 2>/dev/null || true
  fi
  [[ -z "${LOG_FILE}" || ! -f "${LOG_FILE}" ]] || strip_colours "${LOG_FILE}" 2>/dev/null || true
}

# Lock, log and sudo for a real install run.
start_run() {
  local family="$1" state="${TARGET_HOME}/.local/bootstrap"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ((!DRY_RUN)) || return 0
  private_dir "${state}" >/dev/null || warn "cannot make ${state} private"
  take_lock "${state}/lock"
  PRUNE_BACKUPS=1
  ((!LOGGING)) || start_log "${state}/logs"
  [[ -z "${LOG_FILE}" ]] || info "Logging to ${LOG_FILE}"
  prime_sudo "${family}"
}
