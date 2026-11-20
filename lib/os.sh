# shellcheck shell=bash
# Platform facts: distro family, WSL, systemd, root, users and shells,
# the Homebrew prefix.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

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

is_root() {
  [[ "${EUID}" -eq 0 ]]
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

# Run a read-only command as root without printing it. sudo is primed before
# the first step; -n never stops for a password (a dry run then just fails).
root_quiet() {
  if is_root; then "$@"; else sudo -n "$@"; fi
}

# True when systemd runs this machine (not in most containers).
has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d "${SYSTEMD_RUN_DIR}" ]]
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
    dscl . -read "/Users/${user}" UserShell 2>/dev/null | awk '{print $2}' || true
  else
    printf '%s\n' "${SHELL:-}"
  fi
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
