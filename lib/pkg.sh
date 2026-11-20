# shellcheck shell=bash
# Packages: generic name to distro name, installed checks, one-transaction
# installs per package manager, Homebrew and EPEL bootstrap.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

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
