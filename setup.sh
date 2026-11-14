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
# Started as `sh setup.sh`? Rerun under bash before any bash-only syntax.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
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

# Run a command, or print it in dry-run mode.
run() {
  if ((DRY_RUN)); then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  printf '   %s$ %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
  "$@"
}

# Prefix with sudo when not root.
as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    run "$@"
  elif command -v sudo >/dev/null 2>&1; then
    run sudo "$@"
  else
    die "need root for: $* (run as root or install sudo)"
  fi
}

# Print one field (ID, ID_LIKE, VERSION_ID, ...) of os-release.
os_field() {
  # shellcheck disable=SC1090
  (. "${OS_RELEASE_FILE}" && printf '%s' "${!1:-}")
}

# Print the distro family: arch | debian | fedora | rhel | macos.
detect_family() {
  [[ "${UNAME_S}" == "Darwin" ]] && { echo macos; return 0; }
  [[ -r "${OS_RELEASE_FILE}" ]] || die "cannot read ${OS_RELEASE_FILE}"
  local id id_like
  id="$(os_field ID)"
  id_like="$(os_field ID_LIKE)"

  local word
  for word in ${id} ${id_like}; do
    case "${word}" in
      arch | archlinux | cachyos | manjaro | endeavouros) echo arch; return 0 ;;
      debian | ubuntu | linuxmint | pop) echo debian; return 0 ;;
      fedora) [[ "${id}" == "fedora" ]] && { echo fedora; return 0; } ;;
      rhel | centos | rocky | almalinux | ol) echo rhel; return 0 ;;
    esac
  done
  # RHEL clones list "fedora" in ID_LIKE after "rhel"; plain fedora-likes land here.
  [[ " ${id_like} " == *" fedora "* ]] && { echo fedora; return 0; }
  die "unsupported distro: ID='${id}' ID_LIKE='${id_like}'"
}

# Major version of the distro (for EPEL on RHEL-likes).
os_major_version() {
  local v
  v="$(os_field VERSION_ID)"
  printf '%s' "${v%%.*}"
}

# Map a generic package name to the distro name. Prints nothing when the
# distro has no separate package for it (already in the base system).
pkg_name() {
  local family="$1" pkg="$2"
  case "${family}:${pkg}" in
    fedora:vim | rhel:vim) echo vim-enhanced ;;
    arch:openssh-client) echo openssh ;;
    fedora:openssh-client | rhel:openssh-client) echo openssh-clients ;;
    arch:openssh-server) echo openssh ;;
    arch:procps | fedora:procps | rhel:procps) echo procps-ng ;;
    fedora:iproute2 | rhel:iproute2) echo iproute ;;
    debian:iputils) echo iputils-ping ;;
    arch:dnsutils) echo bind ;;
    fedora:dnsutils | rhel:dnsutils) echo bind-utils ;;
    debian:which) ;;
    # macOS ships these (or a BSD equivalent) in the base system.
    macos:less | macos:man-db | macos:sudo | macos:procps | macos:lsof | macos:which | \
      macos:file | macos:diffutils | macos:openssh-client | macos:openssh-server | \
      macos:curl | macos:iproute2 | macos:iputils | macos:dnsutils | \
      macos:ca-certificates | macos:zsh | macos:tar | macos:gzip | macos:zip | macos:unzip | \
      macos:make) ;;
    macos:bash-completion) echo bash-completion@2 ;;
    *) echo "${pkg}" ;;
  esac
}

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
  local group i install skip
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
}

# Run one step in a subshell, so `set -e` works inside it and a failure does not
# stop the next step. Subshells lose environment changes: see ensure_brew in main.
# A step that warned shows WARN in the summary; only FAILED makes the run fail.
run_step() {
  local title="$1" rc=0 start="${SECONDS}" n="${#STEP_LABELS[@]}"
  shift
  [[ -n "${RUN_DIR}" ]] || RUN_DIR="$(mktemp -d)"
  info "Step $((n + 1)): ${title}"
  STEP_WARN_FILE="${RUN_DIR}/warn.${n}"
  : >"${STEP_WARN_FILE}"
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  STEP_WARN_FILE=""
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
    [[ -s "${RUN_DIR}/warn.${i}" ]] || continue
    while IFS= read -r line; do printf '                 - %s\n' "${line}"; done <"${RUN_DIR}/warn.${i}"
  done
  [[ -z "${LOG_FILE}" ]] || printf '  Log: %s\n' "${LOG_FILE}"
  return "${failed}"
}

is_root() {
  [[ "${EUID}" -eq 0 ]]
}

# RHEL/Fedora images ship curl-minimal, which conflicts with the curl package.
# It already provides the curl command, so keep it.
skip_installed_variant() {
  local pkg="$1"
  [[ "${pkg}" == "curl" ]] && rpm -q curl-minimal >/dev/null 2>&1
}

# True when the distro package is already installed. Read-only, so dry-run
# shows the real plan. macOS reads BREW_INSTALLED, filled by install_packages.
# shellcheck disable=SC2016 # ${Status} is a dpkg-query format, not a shell variable
pkg_installed() {
  local family="$1" pkg="$2"
  case "${family}" in
    arch) pacman -Q "${pkg}" >/dev/null 2>&1 ;;
    debian) [[ "$(dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null)" == "install ok installed" ]] ;;
    fedora | rhel) rpm -q --whatprovides "${pkg}" >/dev/null 2>&1 ;;
    macos) [[ " ${BREW_INSTALLED:-} " == *" ${pkg} "* ]] ;;
    *) return 1 ;;
  esac
}

# apt: refresh the package lists unless they are under 6 hours old. Wait up to
# 5 minutes for the dpkg lock (unattended-upgrades holds it on a fresh Ubuntu).
APT_GET=(env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300)
apt_refresh() {
  if [[ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' -mmin -360 2>/dev/null | head -n 1)" ]]; then
    ok "apt package lists are fresh (under 6h old)"
    return 0
  fi
  as_root "${APT_GET[@]}" update
}

# Install distro packages in one transaction. Arch uses -Syu: a plain -Sy is a
# partial upgrade, which Arch does not support.
pkg_install() {
  local family="$1"
  shift
  case "${family}" in
    arch) as_root pacman -Syu --needed --noconfirm "$@" ;;
    debian) apt_refresh && as_root "${APT_GET[@]}" install -y "$@" ;;
    fedora) as_root dnf install -y "$@" ;;
    rhel)
      local pm=dnf
      command -v dnf >/dev/null 2>&1 || pm=yum
      enable_epel "${pm}"
      as_root "${pm}" install -y "$@"
      ;;
    macos) run brew install "$@" ;;
    *) die "no installer for family '${family}'" ;;
  esac
}

# Install what is missing. If the batch fails (one bad name fails a whole apt or
# dnf transaction), retry one by one so the rest still installs.
install_missing() {
  local family="$1" pkg
  shift
  local -a todo=() present=() failed=()
  for pkg in "$@"; do
    if pkg_installed "${family}" "${pkg}"; then present+=("${pkg}"); else todo+=("${pkg}"); fi
  done
  ((${#present[@]} == 0)) || ok "already installed: ${present[*]}"
  if ((${#todo[@]} == 0)); then
    ok "nothing to install"
    return 0
  fi
  info "Installing (${family}): ${todo[*]}"
  pkg_install "${family}" "${todo[@]}" && return 0
  ((${#todo[@]} > 1)) || return 1
  warn "batch install failed; retrying one package at a time"
  for pkg in "${todo[@]}"; do
    pkg_install "${family}" "${pkg}" || failed+=("${pkg}")
  done
  ((${#failed[@]} == 0)) || { warn "could not install: ${failed[*]}"; return 1; }
}

install_packages() {
  local family="$1"
  local -a pkgs=()
  local pkg
  # while-read instead of mapfile: macOS bash 3.2 has no mapfile.
  while IFS= read -r pkg; do
    pkgs+=("${pkg}")
  done < <(selected_packages "${family}")
  if item_selected extras.ssh-server; then
    pkg="$(pkg_name "${family}" openssh-server)"
    # On Arch the client package already includes the server.
    [[ -n "${pkg}" && " ${pkgs[*]-} " != *" ${pkg} "* ]] && pkgs+=("${pkg}")
  fi
  if [[ "${family}" == "fedora" || "${family}" == "rhel" ]]; then
    local -a kept=()
    for pkg in ${pkgs[@]+"${pkgs[@]}"}; do
      skip_installed_variant "${pkg}" || kept+=("${pkg}")
    done
    pkgs=(${kept[@]+"${kept[@]}"})
  fi
  ((${#pkgs[@]})) || { warn "no packages selected"; return 0; }
  if [[ "${family}" == "macos" ]]; then
    ensure_brew
    if command -v brew >/dev/null 2>&1; then BREW_INSTALLED="$(brew list --formula -1 2>/dev/null | xargs)"; fi
  fi
  install_missing "${family}" "${pkgs[@]}"
}

# Print the Homebrew prefix: from brew if on PATH, else the default location.
brew_prefix() {
  if command -v brew >/dev/null 2>&1; then
    brew --prefix
  elif [[ "$(uname -m)" == "arm64" ]]; then
    echo /opt/homebrew
  else
    echo /usr/local
  fi
}

# Install Homebrew if missing and put it on PATH for this run and for zsh.
ensure_brew() {
  [[ "${EUID}" -ne 0 ]] || die "on macOS run setup.sh as your normal user, not root"
  local brew_bin
  brew_bin="$(brew_prefix)/bin/brew"
  if ! command -v brew >/dev/null 2>&1 && [[ ! -x "${brew_bin}" ]]; then
    # Dry-run: print once; later calls (in step subshells) inherit the flag.
    if ((DRY_RUN)) && [[ -n "${BREW_DRY_SHOWN:-}" ]]; then return 0; fi
    info "Installing Homebrew (official installer, asks for your password)"
    if ((DRY_RUN)); then
      BREW_DRY_SHOWN=1
      # shellcheck disable=SC2016  # print the command, do not run it
      printf '   [dry-run] %s\n' '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      return 0
    fi
    # --yes: let the official installer run without its own prompts.
    ((ASSUME_YES)) && export NONINTERACTIVE=1
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if ! command -v brew >/dev/null 2>&1 && [[ -x "${brew_bin}" ]]; then
    eval "$("${brew_bin}" shellenv)"
    local line="eval \"\$(${brew_bin} shellenv)\""
    if ! grep -qsF "${line}" "${TARGET_HOME}/.zprofile"; then
      info "Adding Homebrew to ${TARGET_HOME}/.zprofile"
      backup_file "${TARGET_HOME}/.zprofile"
      printf '\n%s\n' "${line}" >>"${TARGET_HOME}/.zprofile"
    fi
  fi
}

# Enable and start the SSH daemon (service is "ssh" on Debian/Ubuntu).
enable_ssh_server() {
  local family="$1" svc=sshd
  if [[ "${family}" == "macos" ]]; then
    info "Turning on Remote Login (sshd)"
    as_root systemsetup -setremotelogin on ||
      warn "could not turn on Remote Login; use System Settings > General > Sharing"
    return 0
  fi
  [[ "${family}" == "debian" ]] && svc=ssh
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    warn "systemd not running; enable ${svc} manually"
    return 0
  fi
  info "Enabling ${svc}"
  as_root systemctl enable --now "${svc}"
}

# Run a read-only command as root without printing it. sudo is primed before
# the first step; -n never stops for a password (a dry run then just fails).
root_quiet() {
  if is_root; then "$@"; else sudo -n "$@"; fi
}

# Print the sshd binary; it is often in /usr/sbin, off a normal user's PATH.
sshd_path() {
  local p
  for p in "$(command -v sshd 2>/dev/null)" /usr/sbin/sshd /usr/bin/sshd; do
    [[ -n "${p}" && -x "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  done
  return 1
}

# The sshd drop-in that refuses logins from outside the local network. sshd
# enforces it the same way on every distro and macOS, firewall or not.
ssh_local_only_conf() {
  cat <<'EOF'
# Written by install/setup.sh: "Restrict SSH to local network only".
# Refuses logins from every address outside loopback, the private IPv4
# ranges (RFC 1918), link-local and IPv6 unique-local addresses.
# Delete this file and reload sshd to lift the restriction.
Match Address *,!127.0.0.0/8,!10.0.0.0/8,!172.16.0.0/12,!192.168.0.0/16,!169.254.0.0/16,!::1,!fe80::/10,!fc00::/7
    DenyUsers *
Match all
EOF
}

# sshd reads sshd_config.d only through an Include line. Recent distros and
# macOS ship one; else add it as the first line (before any Match block).
ensure_sshd_include() {
  local cfg="${SSH_CONFIG_DIR}/sshd_config" tmp
  root_quiet grep -qE "^[[:space:]]*Include[[:space:]]+${SSH_CONFIG_DIR}/sshd_config\.d/" "${cfg}" 2>/dev/null && return 0
  info "Adding an Include of sshd_config.d to ${cfg}"
  if ((DRY_RUN)); then
    printf '   [dry-run] prepend "Include %s/sshd_config.d/*.conf" to %s\n' "${SSH_CONFIG_DIR}" "${cfg}"
    return 0
  fi
  tmp="$(mktemp)"
  { printf 'Include %s/sshd_config.d/*.conf\n\n' "${SSH_CONFIG_DIR}"; root_quiet cat "${cfg}"; } >"${tmp}" ||
    { rm -f "${tmp}"; warn "cannot read ${cfg}"; return 1; }
  as_root cp -p "${cfg}" "${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
  # cp onto the existing file keeps its owner and mode (0600 on Fedora/RHEL).
  as_root cp "${tmp}" "${cfg}"
  rm -f "${tmp}"
}

# sshd -t refuses to run without host keys, which containers and fresh
# Arch/Fedora installs only get when sshd first starts. Generate them.
ensure_ssh_host_keys() {
  compgen -G "${SSH_CONFIG_DIR}/ssh_host_*_key" >/dev/null || as_root ssh-keygen -A
  # Debian/Ubuntu sshd refuses to run (also -t) without its privilege
  # separation dir, which systemd creates only while sshd runs; socket-activated
  # Ubuntu 24.04 often has none. ssh.service makes it the same way.
  if [[ "${1:-}" == "debian" && ! -d "${SSHD_RUN_DIR}" ]]; then as_root mkdir -p -m 755 "${SSHD_RUN_DIR}"; fi
  return 0
}

# Make a running sshd read the new config. macOS (launchd) and socket-activated
# sshd start per connection, so new logins see it anyway.
reload_sshd() {
  local family="$1" svc=sshd
  [[ "${family}" != "macos" ]] || return 0
  [[ "${family}" == "debian" ]] && svc=ssh
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || return 0
  systemctl is-active --quiet "${svc}" || return 0
  as_root systemctl reload "${svc}" || warn "could not reload ${svc}; restart it to apply the restriction"
}

# Install the local-network-only drop-in, check it with sshd -t, reload sshd.
# A config sshd rejects is removed again, so sshd never stays broken.
restrict_ssh_local_only() {
  local family="$1" dst="${SSH_CONFIG_DIR}/sshd_config.d/${SSH_LOCAL_CONF_NAME}" sshd tmp
  if ! sshd="$(sshd_path)" || [[ ! -f "${SSH_CONFIG_DIR}/sshd_config" ]]; then
    if ((!DRY_RUN)); then
      warn "no SSH server installed; tick OpenSSH server too"
      return 0
    fi
    sshd=/usr/sbin/sshd
  fi
  tmp="$(mktemp)"
  ssh_local_only_conf >"${tmp}"
  if [[ -f "${dst}" ]] && files_equal "${tmp}" "${dst}"; then
    rm -f "${tmp}"
    ok "${dst} (unchanged)"
    return 0
  fi
  ensure_sshd_include || { rm -f "${tmp}"; return 1; }
  ensure_ssh_host_keys "${family}"
  as_root mkdir -p "${SSH_CONFIG_DIR}/sshd_config.d"
  # No backup next to it: macOS includes every file in sshd_config.d, .bak too.
  as_root install -m 644 "${tmp}" "${dst}"
  rm -f "${tmp}"
  if ((!DRY_RUN)) && ! root_quiet "${sshd}" -t; then
    warn "sshd rejected the new config; removing ${dst}"
    as_root rm -f "${dst}"
    return 1
  fi
  reload_sshd "${family}"
  ok "SSH logins now only from the local network (${dst})"
}

# htop lives in EPEL on RHEL and its clones.
enable_epel() {
  local pm="$1"
  if rpm -q epel-release >/dev/null 2>&1; then
    return 0
  fi
  info "Enabling EPEL"
  if ! as_root "${pm}" install -y epel-release; then
    local major
    major="$(os_major_version)"
    as_root "${pm}" install -y \
      "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm"
  fi
}

# cmp comes from diffutils, which minimal images lack.
files_equal() {
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  else
    [[ "$(<"$1")" == "$(<"$2")" ]]
  fi
}

# Copy an existing file to <file>.bak.YYYYmmdd_HHMMSS before it changes.
# Does nothing when the file does not exist.
backup_file() {
  local file="$1" backup
  [[ -e "${file}" || -L "${file}" ]] || return 0
  backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  local base="${backup}" n=0
  while [[ -e "${backup}" ]]; do n=$((n + 1)); backup="${base}.${n}"; done
  info "Backing up ${file} -> ${backup}"
  run cp -P "${file}" "${backup}"
}

# Copy src to dst. Back up an existing dst first; skip if identical.
install_file() {
  local src="$1" dst="$2"
  [[ -f "${src}" ]] || die "missing config source: ${src}"
  if [[ -f "${dst}" ]] && files_equal "${src}" "${dst}"; then
    ok "${dst} (unchanged)"
    return 0
  fi
  backup_file "${dst}"
  run mkdir -p "$(dirname "${dst}")"
  atomic_copy "${src}" "${dst}"
  ok "${dst}"
}

# Copy to a temp file next to dst, then rename it over dst: an interrupted run
# never leaves a half-written config. The rename also replaces a symlink itself
# instead of writing through it. Optional third argument: chmod mode.
atomic_copy() {
  local src="$1" dst="$2" mode="${3:-}" tmp="$2.tmp.$$"
  if ((DRY_RUN)); then
    printf '   [dry-run] cp %s %s\n' "${src}" "${dst}"
    return 0
  fi
  printf '   %s$ cp %s %s%s\n' "${C_DIM}" "${src}" "${dst}" "${C_RESET}"
  if cp "${src}" "${tmp}" && { [[ -z "${mode}" ]] || chmod "${mode}" "${tmp}"; } && mv -f "${tmp}" "${dst}"; then
    return 0
  fi
  rm -f "${tmp}"
  die "could not write ${dst}"
}

# Install kitty and Ghostty configs. Each terminal has one file per platform
# (configs/kitty/<os>.conf, configs/ghostty/<os>.config); macOS and Linux
# (including WSL) get their own. Windows has no native kitty or Ghostty build.
install_terminal_configs() {
  local family="$1" os=linux ghostty_dst item
  shift
  [[ "${family}" == "macos" ]] && os=macos
  if [[ "${os}" == "macos" ]]; then
    ghostty_dst="${TARGET_HOME}/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
  else
    ghostty_dst="${TARGET_HOME}/.config/ghostty/config"
  fi
  for item in "$@"; do
    case "${item}" in
      kitty) install_file "${SCRIPT_DIR}/configs/kitty/${os}.conf" "${TARGET_HOME}/.config/kitty/kitty.conf" ;;
      ghostty) install_file "${SCRIPT_DIR}/configs/ghostty/${os}.config" "${ghostty_dst}" ;;
    esac
  done
}

# Install the ticked terminal packages (best effort per distro). Ghostty is not
# packaged everywhere (e.g. Debian/Ubuntu apt); there we install kitty and point
# at the manual Ghostty install.
install_terminal_packages() {
  local family="$1"
  shift
  case "${family}" in
    debian)
      if [[ " $* " == *" kitty "* ]]; then
        install_missing debian kitty || warn "kitty install failed (apt)"
      fi
      [[ " $* " != *" ghostty "* ]] ||
        warn "Ghostty has no apt package; install it from https://ghostty.org/download"
      ;;
    arch | fedora | rhel)
      install_missing "${family}" "$@" ||
        warn "$* install failed; Ghostty may need a manual install from https://ghostty.org/download"
      ;;
    macos)
      ensure_brew
      local cask casks="" todo=()
      if command -v brew >/dev/null 2>&1; then casks=" $(brew list --cask -1 2>/dev/null | xargs) "; fi
      for cask in "$@"; do
        if [[ "${casks}" == *" ${cask} "* ]]; then ok "${cask} (already installed)"; else todo+=("${cask}"); fi
      done
      ((${#todo[@]} == 0)) || run brew install --cask "${todo[@]}" || warn "${todo[*]} install failed (brew)"
      ;;
    *) die "no installer for family '${family}'" ;;
  esac
}

# True under WSL, where Linux can run Windows programs.
is_wsl() {
  [[ -r "${KERNEL_RELEASE_FILE}" && "$(<"${KERNEL_RELEASE_FILE}")" == *[Mm]icrosoft* ]]
}

# Print the Windows user's home as a WSL path. WINDOWS_HOME overrides it.
windows_home() {
  if [[ -n "${WINDOWS_HOME:-}" ]]; then
    printf '%s\n' "${WINDOWS_HOME}"
    return 0
  fi
  local dir
  dir="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null)" || return 1
  dir="${dir%$'\r'}"
  [[ -n "${dir}" ]] || return 1
  wslpath "${dir}"
}

# WSL only: install WezTerm on the Windows side with Scoop and copy its config
# to the Windows home. WezTerm is in the extras bucket, which a fresh Scoop
# lacks. If adding it fails, `scoop install` reports that.
install_windows_terminal() {
  if command -v scoop >/dev/null 2>&1; then
    run scoop bucket add extras || true
    run scoop install wezterm || warn "WezTerm install failed (scoop)"
  else
    warn "scoop not found on PATH; install it from https://scoop.sh, then run: scoop bucket add extras; scoop install wezterm"
  fi
  local home
  if home="$(windows_home)"; then
    install_file "${SCRIPT_DIR}/configs/wezterm/windows.lua" "${home}/.wezterm.lua"
  else
    warn "cannot find the Windows home; skipping .wezterm.lua"
  fi
}

# Install the ticked terminals and their configs.
setup_terminals() {
  local family="$1" item
  local -a items=()
  for item in kitty ghostty; do
    if item_selected "terminals.${item}"; then items+=("${item}"); fi
  done
  ((${#items[@]})) || return 0
  info "Installing terminals: ${items[*]}"
  install_terminal_packages "${family}" "${items[@]}"
  install_terminal_configs "${family}" "${items[@]}"
}

install_configs() {
  local family="${1:-}"
  info "Installing configs into ${TARGET_HOME}"
  local entry item name src tmp_dir=""
  for entry in "${CONFIG_MAP[@]}"; do
    item="${entry%%:*}"
    entry="${entry#*:}"
    name="${entry%%:*}"
    item_selected "configs.${item}" || continue
    src="${SCRIPT_DIR}/configs/${name}"
    # Homebrew nano keeps its syntax files under the brew prefix.
    if [[ "${family}" == "macos" && "${name}" == "nanorc" ]]; then
      [[ -n "${tmp_dir}" ]] || tmp_dir="$(mktemp -d)"
      sed "s|/usr/share/nano|$(brew_prefix)/share/nano|" "${src}" >"${tmp_dir}/nanorc"
      src="${tmp_dir}/nanorc"
    fi
    install_file "${src}" "${TARGET_HOME}/${entry#*:}"
  done
  [[ -z "${tmp_dir}" ]] || rm -rf "${tmp_dir}"
  if item_selected configs.aliases; then install_aliases; fi
  # Scripts only (no PATH appends here): the loader block and repo .zshrc
  # already export ~/.local/bin, so reruns stay idempotent.
  if item_selected configs.bin; then install_bin_scripts; fi
}

# Install helper scripts (executables) into ~/.local/bin.
# The tmuxhelp wrapper in bash_extras finds them via the PATH line that
# install_aliases (and the repo .zshrc) already provide.
install_bin_scripts() {
  local bindir="${TARGET_HOME}/.local/bin"
  local f base
  for f in "${SCRIPT_DIR}"/configs/bin/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    run mkdir -p "${bindir}"
    if [[ -f "${bindir}/${base}" ]] && files_equal "${f}" "${bindir}/${base}" \
      && [[ -x "${bindir}/${base}" ]]; then
      ok "${bindir}/${base} (unchanged)"
      continue
    fi
    backup_file "${bindir}/${base}"
    info "Installing ${bindir}/${base}"
    atomic_copy "${f}" "${bindir}/${base}" 755
    ok "${bindir}/${base}"
  done
}

# bash only: Homebrew's bash-completion@2. Part of the loader; also appended
# alone to an older loader. Its own script returns early under bash < 4.2.
# shellcheck disable=SC2016 # literal text, expanded in the user shell
BREW_COMPLETION_BLOCK='
# bash only: Homebrew bash-completion@2 (macOS; needs the brew bash 5).
if [ -n "${BASH_VERSION:-}" ]; then
    for _bc in "${HOMEBREW_PREFIX:-/opt/homebrew}/etc/profile.d/bash_completion.sh" \
               /usr/local/etc/profile.d/bash_completion.sh; do
        [ -r "$_bc" ] && { . "$_bc"; break; }
    done
    unset _bc
fi'

# Block that loads all alias files; added to the bash startup file.
# shellcheck disable=SC2016 # loader is literal text, expanded in the user shell
ALIAS_LOADER='# Load custom aliases in Zsh
# Helper scripts installed by setup.sh (~/.local/bin).
export PATH="$HOME/.local/bin:$PATH"
if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi

if [ -f ~/.bash_aliases2 ]; then
    source ~/.bash_aliases2
fi

if [ -f ~/.bash_extras ]; then
    source ~/.bash_extras
fi
'"${BREW_COMPLETION_BLOCK}"'

# Show where each alias/function comes from before it runs (last, so it
# sees everything above). Toggle with: show_origin on|off
if [ -f ~/.bash_show_origin ]; then
    source ~/.bash_show_origin
fi'

# Install configs/bash_aliases as ~/.bash_aliases, or as ~/.bash_aliases2 when
# the user already has their own ~/.bash_aliases. Then make bash load all
# alias files. configs/bash_extras and configs/bash_show_origin always install
# as ~/.bash_extras and ~/.bash_show_origin.
install_aliases() {
  local src="${SCRIPT_DIR}/configs/bash_aliases"
  local extra_src="${SCRIPT_DIR}/configs/bash_extras"
  local origin_src="${SCRIPT_DIR}/configs/bash_show_origin"
  local dst="${TARGET_HOME}/.bash_aliases"
  if [[ -e "${dst}" ]] && ! files_equal "${src}" "${dst}"; then
    info "Keeping your ${dst}; installing repo aliases as .bash_aliases2"
    dst="${TARGET_HOME}/.bash_aliases2"
  fi
  install_file "${src}" "${dst}"
  install_file "${extra_src}" "${TARGET_HOME}/.bash_extras"
  install_file "${origin_src}" "${TARGET_HOME}/.bash_show_origin"

  # ~/.bash_profile when it exists, else ~/.bashrc.
  local rc="${TARGET_HOME}/.bash_profile"
  [[ -f "${rc}" ]] || rc="${TARGET_HOME}/.bashrc"
  # Upgrade: an older loader has .bash_aliases2 (or only .bash_extras) but lacks
  # newer lines. Append just the missing blocks instead of duplicating the loader.
  # Also ensure ~/.local/bin is on PATH (older loaders predate bin scripts).
  if grep -qsF 'source ~/.bash_aliases2' "${rc}" || grep -qsF 'source ~/.bash_extras' "${rc}"; then
    local missing=""
    grep -qsF 'source ~/.bash_extras' "${rc}" || missing="${missing} extras"
    # shellcheck disable=SC2016 # literal line, matched literally with grep -F
    grep -qsF 'export PATH="$HOME/.local/bin:$PATH"' "${rc}" || missing="${missing} path"
    grep -qsF 'source ~/.bash_show_origin' "${rc}" || missing="${missing} origin"
    grep -qsF 'profile.d/bash_completion.sh' "${rc}" || missing="${missing} completion"
    if [[ -n "${missing}" ]]; then
      backup_file "${rc}"
      info "Adding${missing} to ${rc}"
      if ((DRY_RUN)); then
        printf '   [dry-run] append%s to %s\n' "${missing}" "${rc}"
      else
        # shellcheck disable=SC2016 # written literally into the rc file
        [[ "${missing}" == *extras* ]] && printf '\nif [ -f ~/.bash_extras ]; then\n    source ~/.bash_extras\nfi\n' >>"${rc}"
        # shellcheck disable=SC2016 # written literally into the rc file
        [[ "${missing}" == *path* ]] && printf '\n# Helper scripts installed by setup.sh (~/.local/bin).\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"${rc}"
        [[ "${missing}" == *origin* ]] && printf '\nif [ -f ~/.bash_show_origin ]; then\n    source ~/.bash_show_origin\nfi\n' >>"${rc}"
        [[ "${missing}" == *completion* ]] && printf '%s\n' "${BREW_COMPLETION_BLOCK}" >>"${rc}"
      fi
      ok "${rc}"
      return 0
    fi
    ok "${rc} already loads the alias files"
    return 0
  fi
  backup_file "${rc}"
  info "Adding alias loader to ${rc}"
  if ((DRY_RUN)); then
    printf '   [dry-run] append alias loader to %s\n' "${rc}"
  else
    printf '\n%s\n' "${ALIAS_LOADER}" >>"${rc}"
  fi
  ok "${rc}"
}

# .tmux.conf ends with `run ~/.tmux/plugins/tpm/tpm`, so TPM must exist.
install_tpm() {
  local tpm_dir="${TARGET_HOME}/.tmux/plugins/tpm"
  if [[ -d "${tpm_dir}" ]]; then
    ok "${tpm_dir} (present)"
  elif command -v git >/dev/null 2>&1 || ((DRY_RUN)); then
    info "Cloning TPM into ${tpm_dir}"
    run git clone --depth 1 "${TPM_REPO}" "${tpm_dir}"
  else
    warn "git not found; skipping TPM. Install git and rerun."
    return 0
  fi
  if ((!DRY_RUN)) && [[ -x "${tpm_dir}/bin/install_plugins" ]] && command -v tmux >/dev/null 2>&1; then
    info "Installing tmux plugins"
    "${tpm_dir}/bin/install_plugins" 2>&1 | sed 's/^/   /' ||
      warn "TPM plugin install failed; press Prefix + I inside tmux"
  fi
}

# Print the first private key in ~/.ssh that has a matching .pub file.
find_ssh_key() {
  local pub
  for pub in "${TARGET_HOME}/.ssh/"*.pub; do
    [[ -f "${pub}" && -f "${pub%.pub}" ]] && { printf '%s\n' "${pub%.pub}"; return 0; }
  done
  return 1
}

# Create an ed25519 key when the user has none. A saved selection needs a
# terminal, so ssh-keygen can ask for a passphrase; only --ssh-key may create a
# key with an empty passphrase.
setup_ssh_key() {
  local key
  if key="$(find_ssh_key)"; then
    ok "SSH key found: ${key}"
    return 0
  fi
  info "No SSH key found in ${TARGET_HOME}/.ssh"
  command -v ssh-keygen >/dev/null 2>&1 || ((DRY_RUN)) ||
    { warn "ssh-keygen not found; install the OpenSSH client first"; return 0; }
  key="${TARGET_HOME}/.ssh/id_ed25519"
  # A private key whose .pub is lost: ssh-keygen -f would offer to overwrite
  # the key. Never do that; rebuild the .pub from it instead.
  if [[ -f "${key}" ]]; then
    rebuild_ssh_pub "${key}"
    return
  fi
  if [[ "${SSH_KEY_MODE}" != "create" && ! -t 0 ]]; then
    warn "skipped SSH key: no terminal for a passphrase; rerun with --ssh-key to create one"
    return 0
  fi

  local -a args=(-t ed25519 -f "${key}" -C "$(current_user)@$(hostname 2>/dev/null || uname -n)")
  # Without a terminal ssh-keygen cannot ask for a passphrase.
  [[ -t 0 ]] || args+=(-N "")
  run mkdir -p "${TARGET_HOME}/.ssh"
  run chmod 700 "${TARGET_HOME}/.ssh"
  # A .pub with no private half may belong to a key kept elsewhere: keep a copy.
  backup_file "${key}.pub"
  run ssh-keygen "${args[@]}"
  if ((!DRY_RUN)); then
    ok "Created ${key}. Public key (add it to GitHub/servers):"
    cat "${key}.pub"
  fi
}

# Write <key>.pub from the private key. An encrypted key asks for its
# passphrase; without a terminal that fails, which only warns.
rebuild_ssh_pub() {
  local key="$1" pub
  info "Rebuilding ${key}.pub from the existing private key"
  if ((DRY_RUN)); then
    printf '   [dry-run] ssh-keygen -y -f %s > %s.pub\n' "${key}" "${key}"
    return 0
  fi
  printf '   %s$ ssh-keygen -y -f %s > %s.pub%s\n' "${C_DIM}" "${key}" "${key}" "${C_RESET}"
  if ! pub="$(ssh-keygen -y -f "${key}")" || [[ -z "${pub}" ]]; then
    warn "could not read ${key} (passphrase?); run: ssh-keygen -y -f ${key} > ${key}.pub"
    [[ -t 0 ]] || return 0
    return 1
  fi
  local tmp="${key}.pub.tmp.$$"
  if ! { printf '%s\n' "${pub}" >"${tmp}" && chmod 644 "${tmp}" && mv -f "${tmp}" "${key}.pub"; }; then
    rm -f "${tmp}"
    die "could not write ${key}.pub"
  fi
  ok "Rebuilt ${key}.pub. Public key (add it to GitHub/servers):"
  cat "${key}.pub"
}

# Print the user name. Containers can run under a UID with no passwd entry.
current_user() {
  id -un 2>/dev/null || printf '%s\n' "${USER:-}"
}

# Print the login shell of the current user.
login_shell() {
  local user
  user="$(current_user)"
  if command -v getent >/dev/null 2>&1; then
    # No passwd entry is an unknown shell, not an error (pipefail would abort).
    getent passwd "${user}" | cut -d: -f7 || true
  elif [[ "${UNAME_S}" == "Darwin" ]]; then
    dscl . -read "/Users/${user}" UserShell | awk '{print $2}'
  else
    printf '%s\n' "${SHELL:-}"
  fi
}

# Make zsh the login shell.
setup_zsh_default() {
  local zsh_path current
  zsh_path="$(command -v zsh 2>/dev/null || true)"
  if [[ -z "${zsh_path}" ]]; then
    if ((DRY_RUN)); then
      zsh_path="/bin/zsh"
    else
      warn "zsh not installed; login shell unchanged"
      return 0
    fi
  fi
  current="$(login_shell)"
  if [[ "${current##*/}" == "zsh" ]]; then
    ok "login shell is already zsh (${current})"
    return 0
  fi
  info "Setting login shell to ${zsh_path}"
  if [[ "${UNAME_S}" == "Darwin" ]]; then
    run chsh -s "${zsh_path}"
  else
    as_root usermod -s "${zsh_path}" "$(current_user)"
  fi
  ((DRY_RUN)) || ok "login shell set to zsh; log out and back in to use it"
}

# Print the target ($TARGET_HOME relative) of a CONFIG_MAP item.
config_target() {
  local entry
  for entry in "${CONFIG_MAP[@]}"; do
    [[ "${entry%%:*}" == "$1" ]] && { printf '%s\n' "${entry##*:}"; return 0; }
  done
  return 1
}

# True when a terminal app is installed: a brew cask on macOS, else a command.
terminal_installed() {
  local family="$1" name="$2"
  if [[ "${family}" == "macos" ]]; then
    command -v brew >/dev/null 2>&1 && brew list --cask "${name}" >/dev/null 2>&1
  else
    command -v "${name}" >/dev/null 2>&1
  fi
}

# Print the state of sshd: OK, MISSING, or SKIPPED <reason>.
check_ssh_server() {
  local family="$1" svc=sshd
  if [[ "${family}" == "macos" ]]; then
    # launchd owns port 22 while Remote Login is on; netstat needs no root.
    if netstat -an -p tcp 2>/dev/null | grep -qE '[.:]22 .*LISTEN'; then echo OK; else echo MISSING; fi
    return 0
  fi
  sshd_path >/dev/null || { echo MISSING; return 0; }
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    echo "SKIPPED systemd not running"
    return 0
  fi
  [[ "${family}" == "debian" ]] && svc=ssh
  # Ubuntu 22.10+ starts sshd per connection from ssh.socket.
  if systemctl is-active --quiet "${svc}" || systemctl is-active --quiet "${svc}.socket"; then echo OK; else echo MISSING; fi
}

# Print OK, MISSING or SKIPPED <reason> for catalog item i. Read-only, and
# always returns 0 so it is safe inside $(...) under set -e.
check_item() {
  local family="$1" i="$2" key target pkg h="${TARGET_HOME}" f rc
  key="${CAT_GROUP[i]}.${CAT_ITEM[i]}"
  if [[ "${CAT_ACTION[i]}" == "pkg" ]]; then
    pkg="$(pkg_name "${family}" "${CAT_ITEM[i]}")"
    if [[ -z "${pkg}" ]]; then echo "SKIPPED part of the base system"
    elif pkg_installed "${family}" "${pkg}" || skip_installed_variant "${pkg}"; then echo OK
    else echo MISSING; fi
    return 0
  fi
  case "${key}" in
    configs.aliases)
      rc="${h}/.bash_profile"
      [[ -f "${rc}" ]] || rc="${h}/.bashrc"
      if [[ -f "${h}/.bash_extras" && -f "${h}/.bash_show_origin" ]] &&
        [[ -f "${h}/.bash_aliases" || -f "${h}/.bash_aliases2" ]] &&
        grep -qsF 'source ~/.bash_extras' "${rc}"; then echo OK; else echo MISSING; fi
      ;;
    configs.bin)
      for f in "${SCRIPT_DIR}"/configs/bin/*; do
        [[ ! -f "${f}" || -x "${h}/.local/bin/$(basename "${f}")" ]] || { echo MISSING; return 0; }
      done
      echo OK
      ;;
    configs.*)
      if target="$(config_target "${CAT_ITEM[i]}")" && [[ -f "${h}/${target}" ]]; then echo OK; else echo MISSING; fi
      ;;
    tmux-plugins.tpm)
      if [[ -f "${h}/.tmux/plugins/tpm/tpm" ]]; then echo OK; else echo MISSING; fi
      ;;
    terminals.kitty | terminals.ghostty)
      if [[ "${CAT_ITEM[i]}" == "kitty" ]]; then
        f="${h}/.config/kitty/kitty.conf"
      elif [[ "${family}" == "macos" ]]; then
        f="${h}/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
      else
        f="${h}/.config/ghostty/config"
      fi
      if [[ -f "${f}" ]] && terminal_installed "${family}" "${CAT_ITEM[i]}"; then echo OK
      elif [[ -f "${f}" && "${CAT_ITEM[i]}" == "ghostty" && "${family}" != "arch" && "${family}" != "macos" ]]; then
        echo "SKIPPED no ${family} package; install from https://ghostty.org/download"
      else echo MISSING; fi
      ;;
    terminals.wezterm-wsl)
      if ! f="$(windows_home 2>/dev/null)"; then echo "SKIPPED cannot find the Windows home"
      elif [[ -f "${f}/.wezterm.lua" ]]; then echo OK
      else echo MISSING; fi
      ;;
    extras.ssh-server) check_ssh_server "${family}" ;;
    extras.ssh-local-only)
      f="${SSH_CONFIG_DIR}/sshd_config.d/${SSH_LOCAL_CONF_NAME}"
      if [[ -f "${f}" && "$(<"${f}")" == "$(ssh_local_only_conf)" ]]; then echo OK
      elif ! sshd_path >/dev/null; then echo "SKIPPED no SSH server installed"
      else echo MISSING; fi
      ;;
    extras.ssh-key)
      if find_ssh_key >/dev/null; then echo OK
      elif [[ "${SSH_KEY_MODE}" != "create" && ! -t 0 ]]; then echo "SKIPPED no terminal for a passphrase"
      else echo MISSING; fi
      ;;
    extras.zsh-login)
      f="$(login_shell 2>/dev/null || true)"
      if [[ "${f##*/}" == "zsh" ]]; then echo OK; else echo MISSING; fi
      ;;
    *) echo OK ;;
  esac
  return 0
}

# Check step: one OK / MISSING / SKIPPED line per ticked item. Fails when
# anything is missing, so the run exits 1 and a rerun retries.
check_selection() {
  local family="$1" i result status note color missing=0
  if [[ "${family}" == "macos" ]] && command -v brew >/dev/null 2>&1; then
    BREW_INSTALLED="$(brew list --formula -1 2>/dev/null | xargs)"
  fi
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    [[ "${CAT_SEL[i]}" == "1" ]] || continue
    result="$(check_item "${family}" "${i}")"
    status="${result%% *}" note=""
    [[ "${result}" != *" "* ]] || note="${result#* }"
    case "${status}" in
      OK) color="${C_GREEN}" ;;
      SKIPPED) color="${C_YELLOW}" ;;
      *) color="${C_RED}" missing=$((missing + 1)) ;;
    esac
    printf '  %s%-7s%s %s%s\n' "${color}" "${status}" "${C_RESET}" "${CAT_LABEL[i]}" "${note:+ (${note})}"
  done
  ((missing == 0)) || { warn "${missing} item(s) missing; rerun to retry"; return 1; }
}

confirm() {
  ((ASSUME_YES || DRY_RUN)) && return 0
  [[ -t 0 ]] || return 0
  local reply
  read -r -p "$1 [Y/n] " reply
  [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
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

# Run every ticked step, in catalog-independent install order.
run_steps() {
  local family="$1"
  if action_selected pkg || item_selected extras.ssh-server; then
    # In the main shell: PATH changes must reach the steps, which are subshells.
    [[ "${family}" != "macos" ]] || ensure_brew
    run_step packages install_packages "${family}"
  fi
  if item_selected extras.ssh-server; then run_step "ssh server" enable_ssh_server "${family}"; fi
  if action_selected step:ssh-local-only; then run_step "ssh local network only" restrict_ssh_local_only "${family}"; fi
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
  [[ -z "${SUDO_KEEPALIVE}" ]] || kill "${SUDO_KEEPALIVE}" 2>/dev/null || true
  [[ -z "${LOCK_DIR}" ]] || rm -rf "${LOCK_DIR}"
  [[ -z "${RUN_DIR}" ]] || rm -rf "${RUN_DIR}"
  if [[ -n "${TEE_PID}" ]]; then
    # Let tee flush the last lines before the prompt comes back.
    exec 1>&- 2>&-
    wait "${TEE_PID}" 2>/dev/null || true
  fi
}

# Lock, log and sudo for a real install run.
start_run() {
  local family="$1" state="${TARGET_HOME}/.local/bootstrap"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ((!DRY_RUN)) || return 0
  take_lock "${state}/lock"
  ((!LOGGING)) || start_log "${state}/logs"
  [[ -z "${LOG_FILE}" ]] || info "Logging to ${LOG_FILE}"
  prime_sudo "${family}"
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
  print_plan
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
