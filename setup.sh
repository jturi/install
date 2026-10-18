#!/usr/bin/env bash
# Bootstrap a new Linux machine: install basic packages and drop in configs.
#
# Supported families (auto-detected from /etc/os-release):
#   arch   — Arch, CachyOS, Manjaro, EndeavourOS   (pacman)
#   debian — Debian, Ubuntu, Mint, Pop!_OS        (apt-get)
#   fedora — Fedora                               (dnf)
#   rhel   — RHEL, Rocky, AlmaLinux, CentOS Stream (dnf/yum + EPEL)
#
# Usage: ./setup.sh [--dry-run] [--yes] [--no-packages] [--no-configs]
#                   [--ssh-server] [--ssh-key | --no-ssh-key]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
PACKAGE_LIST="${PACKAGE_LIST:-${SCRIPT_DIR}/packages/base.txt}"
TARGET_HOME="${TARGET_HOME:-${HOME}}"
TPM_REPO="https://github.com/tmux-plugins/tpm"

DRY_RUN=0
ASSUME_YES=0
DO_PACKAGES=1
DO_CONFIGS=1
DO_SSH_SERVER=0
SSH_KEY_MODE=ask # ask | create | skip

# config source (relative to configs/) -> target (relative to $TARGET_HOME)
CONFIG_MAP=(
  "tmux.conf:.tmux.conf"
  "nanorc:.nanorc"
)

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
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  -n, --dry-run      Print what would run, change nothing
  -y, --yes          Do not ask for confirmation
      --no-packages  Skip package installation
      --no-configs   Skip config files
      --ssh-server   Also install OpenSSH server and enable sshd
      --ssh-key      Create an ed25519 SSH key if none exists (no prompt)
      --no-ssh-key   Do not check for an SSH key
  -h, --help         Show this help
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

# Print the distro family: arch | debian | fedora | rhel.
detect_family() {
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
    *) echo "${pkg}" ;;
  esac
}

# Read the package list, skipping comments and blank lines.
read_packages() {
  local family="$1" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "${line}" ]] || continue
    pkg_name "${family}" "${line}"
  done <"${PACKAGE_LIST}"
}

# RHEL/Fedora images ship curl-minimal, which conflicts with the curl package.
# It already provides the curl command, so keep it.
skip_installed_variant() {
  local pkg="$1"
  [[ "${pkg}" == "curl" ]] && rpm -q curl-minimal >/dev/null 2>&1
}

install_packages() {
  local family="$1"
  local -a pkgs
  mapfile -t pkgs < <(read_packages "${family}")
  ((DO_SSH_SERVER)) && pkgs+=("$(pkg_name "${family}" openssh-server)")
  if [[ "${family}" == "fedora" || "${family}" == "rhel" ]]; then
    local -a kept=()
    local pkg
    for pkg in "${pkgs[@]}"; do
      skip_installed_variant "${pkg}" || kept+=("${pkg}")
    done
    pkgs=("${kept[@]}")
  fi
  ((${#pkgs[@]})) || { warn "no packages in ${PACKAGE_LIST}"; return 0; }
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
    *) die "no installer for family '${family}'" ;;
  esac
}

# Enable and start the SSH daemon (service is "ssh" on Debian/Ubuntu).
enable_ssh_server() {
  local family="$1" svc=sshd
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

# Copy src to dst. Back up a different existing dst first; skip if identical.
install_file() {
  local src="$1" dst="$2"
  [[ -f "${src}" ]] || die "missing config source: ${src}"
  if [[ -f "${dst}" ]] && files_equal "${src}" "${dst}"; then
    ok "${dst} (unchanged)"
    return 0
  fi
  if [[ -e "${dst}" || -L "${dst}" ]]; then
    local backup
    backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backing up ${dst} -> ${backup}"
    run mv "${dst}" "${backup}"
  fi
  run mkdir -p "$(dirname "${dst}")"
  run cp "${src}" "${dst}"
  ok "${dst}"
}

install_configs() {
  info "Installing configs into ${TARGET_HOME}"
  local entry
  for entry in "${CONFIG_MAP[@]}"; do
    install_file "${SCRIPT_DIR}/configs/${entry%%:*}" "${TARGET_HOME}/${entry#*:}"
  done
  install_tpm
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

# Offer to create an ed25519 key when the user has none.
setup_ssh_key() {
  [[ "${SSH_KEY_MODE}" == "skip" ]] && return 0
  local key
  if key="$(find_ssh_key)"; then
    ok "SSH key found: ${key}"
    return 0
  fi
  info "No SSH key found in ${TARGET_HOME}/.ssh"
  if [[ "${SSH_KEY_MODE}" == "ask" ]]; then
    if ((ASSUME_YES || DRY_RUN)) || [[ ! -t 0 ]]; then
      warn "skipped SSH key; rerun with --ssh-key to create one"
      return 0
    fi
    local reply
    read -r -p "Create an ed25519 SSH key now? [Y/n] " reply
    [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]] || { warn "skipped SSH key"; return 0; }
  fi
  command -v ssh-keygen >/dev/null 2>&1 || ((DRY_RUN)) ||
    { warn "ssh-keygen not found; install the OpenSSH client first"; return 0; }

  key="${TARGET_HOME}/.ssh/id_ed25519"
  local -a args=(-t ed25519 -f "${key}" -C "${USER:-$(id -un)}@$(hostname 2>/dev/null || uname -n)")
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
      --no-packages) DO_PACKAGES=0 ;;
      --no-configs) DO_CONFIGS=0 ;;
      --ssh-server) DO_SSH_SERVER=1 ;;
      --ssh-key) SSH_KEY_MODE=create ;;
      --no-ssh-key) SSH_KEY_MODE=skip ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  local family
  family="$(detect_family)"
  info "Detected distro family: ${family}"

  if ((DO_PACKAGES)); then
    if confirm "Install basic packages via ${family} package manager?"; then
      install_packages "${family}"
      ((DO_SSH_SERVER)) && enable_ssh_server "${family}"
    else
      warn "skipped packages"
    fi
  fi
  ((DO_CONFIGS)) && install_configs
  setup_ssh_key
  info "Done."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
