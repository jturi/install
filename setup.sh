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
#                   [--terminal | --no-terminal] [--ssh-key | --no-ssh-key]
#                   [--zsh-default | --no-zsh-default]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
UNAME_S="${UNAME_S:-$(uname -s)}"
KERNEL_RELEASE_FILE="${KERNEL_RELEASE_FILE:-/proc/sys/kernel/osrelease}"
CATALOG_FILE="${CATALOG_FILE:-${SCRIPT_DIR}/catalog.txt}"
TARGET_HOME="${TARGET_HOME:-${HOME}}"
TPM_REPO="https://github.com/tmux-plugins/tpm"

DRY_RUN=0
ASSUME_YES=0
DO_PACKAGES=1
DO_CONFIGS=1
DO_SSH_SERVER=0
SSH_KEY_MODE=saved # saved | create | skip
ZSH_DEFAULT_MODE=saved # saved | change | skip
TERMINAL_MODE=saved # saved | install | skip
SELECT_ONLY=0
CONFIG_FILE=""
CONFIG_EXPLICIT=0
FLAGS_USED=0 # a selection flag was passed: use it instead of the menu
STEP_LABELS=() STEP_STATUS=()

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
  C_BLUE=$'\e[34m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_RESET=$'\e[0m'
else
  C_BLUE="" C_YELLOW="" C_RED="" C_GREEN="" C_RESET=""
fi

info() { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok() { printf '%s ok%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die() {
  printf '%serror%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
  exit 1
}

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
      --ssh-key      Create an ed25519 SSH key if none exists
      --no-ssh-key   Do not check for an SSH key
      --zsh-default  Make zsh the login shell
      --no-zsh-default  Keep the current login shell
      --terminal     Install every terminal for this platform and its config
      --no-terminal  Skip all terminals
EOF
}

# Run a command, or print it in dry-run mode.
run() {
  if ((DRY_RUN)); then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
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
      macos:ca-certificates | macos:zsh | macos:tar | macos:gzip | macos:zip | macos:unzip) ;;
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
run_step() {
  local title="$1" rc=0
  shift
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  STEP_LABELS+=("${title}")
  if ((rc == 0)); then STEP_STATUS+=("OK"); else STEP_STATUS+=("FAILED"); fi
}

# Print the result of every step. Returns 1 if any failed.
print_summary() {
  local i failed=0
  info "Summary"
  for ((i = 0; i < ${#STEP_LABELS[@]}; i++)); do
    printf '  %-7s %s\n' "${STEP_STATUS[i]}" "${STEP_LABELS[i]}"
    [[ "${STEP_STATUS[i]}" == "OK" ]] || failed=1
  done
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
  info "Installing (${family}): ${pkgs[*]}"

  case "${family}" in
    arch)
      as_root pacman -Sy --needed --noconfirm "${pkgs[@]}"
      ;;
    debian)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get update
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    fedora)
      as_root dnf install -y "${pkgs[@]}"
      ;;
    rhel)
      local pm=dnf
      command -v dnf >/dev/null 2>&1 || pm=yum
      enable_epel "${pm}"
      as_root "${pm}" install -y "${pkgs[@]}"
      ;;
    macos)
      ensure_brew
      run brew install "${pkgs[@]}"
      ;;
    *) die "no installer for family '${family}'" ;;
  esac
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
    info "Installing Homebrew (official installer, asks for your password)"
    if ((DRY_RUN)); then
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
  # Remove a symlink so cp writes a new file, not through the link.
  [[ -L "${dst}" ]] && run rm -f "${dst}"
  run mkdir -p "$(dirname "${dst}")"
  run cp "${src}" "${dst}"
  ok "${dst}"
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
    arch)
      as_root pacman -Sy --needed --noconfirm "$@" || \
        warn "$* install failed (pacman)"
      ;;
    debian)
      if [[ " $* " == *" kitty "* ]]; then
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y kitty || \
          warn "kitty install failed (apt)"
      fi
      [[ " $* " != *" ghostty "* ]] ||
        warn "Ghostty has no apt package; install it from https://ghostty.org/download"
      ;;
    fedora)
      as_root dnf install -y "$@" || \
        warn "$* install failed (dnf)"
      ;;
    rhel)
      local pm=dnf
      command -v dnf >/dev/null 2>&1 || pm=yum
      as_root "${pm}" install -y "$@" || \
        warn "$* install failed (${pm}; Ghostty may need a manual install from https://ghostty.org/download)"
      ;;
    macos)
      ensure_brew
      run brew install --cask "$@" || \
        warn "$* install failed (brew)"
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
    if [[ -f "${bindir}/${base}" ]] && cmp -s "${f}" "${bindir}/${base}" \
      && [[ -x "${bindir}/${base}" ]]; then
      ok "${bindir}/${base} (unchanged)"
      continue
    fi
    backup_file "${bindir}/${base}"
    info "Installing ${bindir}/${base}"
    if ((DRY_RUN)); then
      printf '   [dry-run] install %s -> %s\n' "${f}" "${bindir}/${base}"
    else
      cp "${f}" "${bindir}/${base}"
      chmod +x "${bindir}/${base}"
    fi
    ok "${bindir}/${base}"
  done
}

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
    "${tpm_dir}/bin/install_plugins" >/dev/null 2>&1 ||
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
  if [[ "${SSH_KEY_MODE}" != "create" && ! -t 0 ]]; then
    warn "skipped SSH key: no terminal for a passphrase; rerun with --ssh-key to create one"
    return 0
  fi
  command -v ssh-keygen >/dev/null 2>&1 || ((DRY_RUN)) ||
    { warn "ssh-keygen not found; install the OpenSSH client first"; return 0; }

  key="${TARGET_HOME}/.ssh/id_ed25519"
  local -a args=(-t ed25519 -f "${key}" -C "$(current_user)@$(hostname 2>/dev/null || uname -n)")
  # Without a terminal ssh-keygen cannot ask for a passphrase.
  [[ -t 0 ]] || args+=(-N "")
  run mkdir -p "${TARGET_HOME}/.ssh"
  run chmod 700 "${TARGET_HOME}/.ssh"
  run ssh-keygen "${args[@]}"
  if ((!DRY_RUN)); then
    ok "Created ${key}. Public key (add it to GitHub/servers):"
    cat "${key}.pub"
  fi
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
      --ssh-key) SSH_KEY_MODE=create FLAGS_USED=1 ;;
      --no-ssh-key) SSH_KEY_MODE=skip FLAGS_USED=1 ;;
      --zsh-default) ZSH_DEFAULT_MODE=change FLAGS_USED=1 ;;
      --no-zsh-default) ZSH_DEFAULT_MODE=skip FLAGS_USED=1 ;;
      --terminal) TERMINAL_MODE=install FLAGS_USED=1 ;;
      --no-terminal) TERMINAL_MODE=skip FLAGS_USED=1 ;;
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
  if action_selected step:configs; then run_step configs install_configs "${family}"; fi
  if action_selected step:tpm; then run_step "tmux plugins" install_tpm; fi
  if action_selected step:terminals; then run_step terminals setup_terminals "${family}"; fi
  if action_selected step:wezterm-wsl; then run_step "WezTerm on Windows" install_windows_terminal; fi
  if action_selected step:ssh-key; then run_step "SSH key" setup_ssh_key; fi
  if action_selected step:zsh-login; then run_step "zsh login shell" setup_zsh_default; fi
}

main() {
  parse_args "$@"
  local family menu=0
  family="$(detect_family)"
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

  run_steps "${family}"
  print_summary || die "some steps failed; rerun to retry"
  info "Done."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
