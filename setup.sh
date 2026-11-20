#!/usr/bin/env bash
# Bootstrap a new Linux or macOS machine: install basic packages and configs.
#
# Supported families (auto-detected from uname and /etc/os-release):
#   arch   — Arch, CachyOS, Manjaro, EndeavourOS   (pacman)
#   debian — Debian, Ubuntu, Mint, Pop!_OS        (apt-get)
#   fedora — Fedora                               (dnf)
#   rhel   — RHEL, Rocky, AlmaLinux, CentOS Stream (dnf/yum + EPEL)
#   macos  — macOS                                (Homebrew)
#
# Works with the bash 3.2 that ships with macOS.
#
# Usage: ./setup.sh [--dry-run] [--yes] [--select] [--config FILE]
#                   [--no-packages] [--no-configs] [--ssh-server]
#                   [--ssh-local-only]
#                   [--terminal | --no-terminal] [--ssh-key | --no-ssh-key]
#                   [--zsh-default | --no-zsh-default] [--debug] [--no-log]
# Started as `sh setup.sh` or `zsh setup.sh`? Rerun under bash before any
# bash-only syntax. Sourced into such a shell, refuse instead: `exec bash "$0"`
# would replace that shell with a full install. POSIX sh cannot tell sourcing
# from running, so the script name decides; zsh says so in ZSH_EVAL_CONTEXT.
if [ -z "${BASH_VERSION:-}" ]; then
  _setup_sourced=1
  case "${0##*/}" in setup.sh) _setup_sourced=0 ;; esac
  case "${ZSH_EVAL_CONTEXT:-}" in *:file*) _setup_sourced=1 ;; esac
  if [ "${_setup_sourced}" = 1 ]; then
    unset _setup_sourced
    echo "setup.sh: run it (./setup.sh); source it from bash only" >&2
    # shellcheck disable=SC2317 # reached when `return` fails: not sourced after all
    return 1 2>/dev/null || exit 1
  fi
  exec bash "$0" "$@"
fi
# macOS /bin/sh is bash 3.2 in POSIX mode, where process substitution (used
# below and in lib/) is off. Turn POSIX mode off for a run; a POSIX-mode bash
# that sources this file is the caller's shell, so refuse there.
if shopt -qo posix; then
  if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "setup.sh: source it from bash only, not in POSIX mode (set +o posix)" >&2
    return 1
  fi
  set +o posix
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
UNAME_S="${UNAME_S:-$(uname -s)}"
KERNEL_RELEASE_FILE="${KERNEL_RELEASE_FILE:-/proc/sys/kernel/osrelease}"
CATALOG_FILE="${CATALOG_FILE:-${SCRIPT_DIR}/catalog.txt}"
TARGET_HOME="${TARGET_HOME:-${HOME}}"
TPM_REPO="https://github.com/tmux-plugins/tpm"
SSH_CONFIG_DIR="${SSH_CONFIG_DIR:-/etc/ssh}"
SSH_LOCAL_CONF_NAME="20-local-network-only.conf"
SSHD_RUN_DIR="${SSHD_RUN_DIR:-/run/sshd}"
SYSTEMD_RUN_DIR="${SYSTEMD_RUN_DIR:-/run/systemd/system}"

DRY_RUN=0
ASSUME_YES=0
DO_PACKAGES=1
DO_CONFIGS=1
DO_SSH_SERVER=0
DO_SSH_LOCAL=0
SSH_KEY_MODE=saved # saved | create | skip
ZSH_DEFAULT_MODE=saved # saved | change | skip
TERMINAL_MODE=saved # saved | install | skip
SELECT_ONLY=0
CONFIG_FILE=""
CONFIG_EXPLICIT=0
FLAGS_USED=0 # a selection flag was passed: use it instead of the menu
DEBUG=0
LOGGING=1
STEP_LABELS=() STEP_STATUS=() STEP_TIME=()
STEP_WARN_FILE="" RUN_DIR="" LOCK_DIR="" LOG_FILE="" SUDO_KEEPALIVE="" TEE_PID=""
SSH_CLIENT_ADDR="" # set by ssh_session_denied, for its caller's message
KEEP_LOGS=20

# catalog item : config source (relative to configs/) : target (relative to $TARGET_HOME)
CONFIG_MAP=(
  "tmux:tmux.conf:.tmux.conf"
  "nanorc:nanorc:.nanorc"
  "zshrc:zshrc:.zshrc"
)

# shellcheck source=lib/catalog.sh
source "${SCRIPT_DIR}/lib/catalog.sh"
# shellcheck source=lib/menu.sh
source "${SCRIPT_DIR}/lib/menu.sh"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/os.sh
source "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=lib/fs.sh
source "${SCRIPT_DIR}/lib/fs.sh"
# shellcheck source=lib/pkg.sh
source "${SCRIPT_DIR}/lib/pkg.sh"
# shellcheck source=lib/ssh.sh
source "${SCRIPT_DIR}/lib/ssh.sh"
# shellcheck source=lib/steps.sh
source "${SCRIPT_DIR}/lib/steps.sh"
# shellcheck source=lib/run.sh
source "${SCRIPT_DIR}/lib/run.sh"

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  -n, --dry-run      Print the plan, change nothing
  -y, --yes          No menu or prompts: use the saved selection, else defaults
      --select       Show the menu and save the selection; install nothing
      --config FILE  Use FILE instead of ~/.local/bootstrap/config
  -h, --help         Show this help

These change one run, skip the menu, and are never saved:
      --no-packages  Skip packages and the OpenSSH server
      --no-configs   Skip config files and tmux plugins
      --ssh-server   Also install OpenSSH server and enable sshd
                     (macOS: turn on Remote Login)
      --ssh-local-only  Refuse SSH logins from outside the local network
      --ssh-key      Create an ed25519 SSH key if none exists
      --no-ssh-key   Do not check for an SSH key
      --zsh-default  Make zsh the login shell
      --no-zsh-default  Keep the current login shell
      --terminal     Install every terminal for this platform and its config
      --no-terminal  Skip all terminals

Output:
      --debug        Trace every shell command (set -x)
      --no-log       Do not write ~/.local/bootstrap/logs/setup-<time>.log

Every command that changes the machine is printed before it runs.
Reruns are safe: installed packages, identical configs and existing keys
are skipped, and every changed file is backed up first.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      -n | --dry-run) DRY_RUN=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      --select) SELECT_ONLY=1 ;;
      --config)
        (($# >= 2)) || { usage >&2; die "--config needs a file"; }
        CONFIG_FILE="$2"
        CONFIG_EXPLICIT=1
        shift
        ;;
      --no-packages) DO_PACKAGES=0 FLAGS_USED=1 ;;
      --no-configs) DO_CONFIGS=0 FLAGS_USED=1 ;;
      --ssh-server) DO_SSH_SERVER=1 FLAGS_USED=1 ;;
      --ssh-local-only) DO_SSH_LOCAL=1 FLAGS_USED=1 ;;
      --ssh-key) SSH_KEY_MODE=create FLAGS_USED=1 ;;
      --no-ssh-key) SSH_KEY_MODE=skip FLAGS_USED=1 ;;
      --zsh-default) ZSH_DEFAULT_MODE=change FLAGS_USED=1 ;;
      --no-zsh-default) ZSH_DEFAULT_MODE=skip FLAGS_USED=1 ;;
      --terminal) TERMINAL_MODE=install FLAGS_USED=1 ;;
      --no-terminal) TERMINAL_MODE=skip FLAGS_USED=1 ;;
      --debug) DEBUG=1 ;;
      --no-log) LOGGING=0 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
}

# True when this run should show the menu.
want_menu() {
  if ((SELECT_ONLY)); then
    menu_available || die "--select needs a terminal"
    return 0
  fi
  ((!ASSUME_YES && !DRY_RUN && !FLAGS_USED)) && menu_available
}

main() {
  parse_args "$@"
  ((!DEBUG)) || set -x
  local family menu=0
  family="$(detect_family)"
  info "install $(source_version), bash ${BASH_VERSION}"
  info "Detected distro family: ${family}"
  load_catalog "${family}"

  [[ -n "${CONFIG_FILE}" ]] || CONFIG_FILE="$(config_default_path)"
  if is_root && [[ -n "${SUDO_USER:-}" ]]; then
    warn "running under sudo: using the selection in ${CONFIG_FILE}, not ${SUDO_USER}'s"
  fi
  config_load "${CONFIG_FILE}"
  if want_menu; then menu=1; fi
  if ((CONFIG_EXPLICIT && !menu)) && [[ ! -f "${CONFIG_FILE}" ]]; then
    die "config file not found: ${CONFIG_FILE}"
  fi

  if ((menu)) && ! menu_run; then
    info "Nothing saved, nothing installed."
    return 0
  fi
  apply_flag_overrides
  print_plan "${family}"
  confirm "Go ahead?" || { info "Nothing saved, nothing installed."; return 0; }
  if ((menu)); then
    config_save "${CONFIG_FILE}" || die "cannot save ${CONFIG_FILE}; nothing installed"
    ok "Selection saved to ${CONFIG_FILE}"
  fi
  if ((SELECT_ONLY)); then
    info "Done."
    return 0
  fi

  start_run "${family}"
  run_steps "${family}"
  print_summary || die "some steps failed; rerun to retry"
  info "Done."
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
