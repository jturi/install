# shellcheck shell=bash
# Install steps for configs, aliases, tmux plugins, terminals and the login
# shell, plus the read-only check of every ticked item.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

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
  # tmux-resurrect (in tmux.conf) saves pane contents here every few minutes.
  # tmux.conf comes from the dotfiles repo, so the setting is protected here
  # instead of edited.
  if item_selected configs.tmux; then private_dir "${TARGET_HOME}/.local/share/tmux/resurrect"; fi
  if item_selected configs.aliases; then install_aliases "${family}"; fi
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

# The bash startup file for the alias loader. Linux terminals start non-login
# shells, which read only ~/.bashrc; login shells reach it through the
# ~/.bash_profile (Arch, Fedora) or ~/.profile (Debian) the distro ships.
# macOS terminals start login shells: there ~/.bash_profile, when it exists.
bash_rc_file() {
  if [[ "${1:-}" == "macos" && -f "${TARGET_HOME}/.bash_profile" ]]; then
    printf '%s\n' "${TARGET_HOME}/.bash_profile"
  else
    printf '%s\n' "${TARGET_HOME}/.bashrc"
  fi
}

# Install configs/bash_aliases as ~/.bash_aliases, or as ~/.bash_aliases2 when
# the user already has their own ~/.bash_aliases. Then make bash load all
# alias files. configs/bash_extras and configs/bash_show_origin always install
# as ~/.bash_extras and ~/.bash_show_origin.
install_aliases() {
  local family="${1:-}"
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

  local rc
  rc="$(bash_rc_file "${family}")"
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
  # Older installs put the loader in ~/.bash_profile on Linux too. It is never
  # deleted for the user; login shells just load the files twice, harmlessly.
  if [[ "${rc}" == "${TARGET_HOME}/.bashrc" ]] && grep -qsF 'source ~/.bash_extras' "${TARGET_HOME}/.bash_profile"; then
    info "an older alias loader in ${TARGET_HOME}/.bash_profile can be removed; ${rc} loads the aliases now"
  fi
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
    run_tty chsh -s "${zsh_path}"
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
      rc="$(bash_rc_file "${family}")"
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
    # shellcheck disable=SC2034 # read by pkg_installed (lib/pkg.sh)
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
