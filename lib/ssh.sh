# shellcheck shell=bash
# SSH: OpenSSH server, the local-network-only restriction (with its
# lock-out check), and the user SSH key.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

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
  if ! has_systemd; then
    warn "systemd not running; enable ${svc} manually"
    return 0
  fi
  info "Enabling ${svc}"
  as_root systemctl enable --now "${svc}"
}

# The local-network restriction failed. Do not leave open an sshd this run
# brought up (Debian and Ubuntu start ssh as soon as the package installs).
# One that already ran before this run is left alone: stopping it could cut
# off the user's own remote session. Always fails, so the run exits 1.
ssh_server_fail_closed() {
  local family="$1" was_running="$2" svc=sshd
  if ((was_running)); then
    warn "sshd was already running and keeps running WITHOUT the local-network restriction; fix the error above and rerun"
    return 1
  fi
  warn "not starting sshd: the local-network restriction failed"
  # macOS: Remote Login is only turned on by enable_ssh_server, which did not run.
  [[ "${family}" != "macos" ]] || return 1
  [[ "${family}" == "debian" ]] && svc=ssh
  if has_systemd; then
    as_root systemctl disable --now "${svc}.socket" "${svc}" 2>/dev/null ||
      as_root systemctl disable --now "${svc}" || true
  fi
  return 1
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
  has_systemd || return 0
  systemctl is-active --quiet "${svc}" || return 0
  as_root systemctl reload "${svc}" || warn "could not reload ${svc}; restart it to apply the restriction"
}

# The SSH_CONNECTION of the session running setup ("client cport server
# sport"), or nothing on a local console. Inside tmux a pane keeps the value
# from when it was created; tmux refreshes its own copy on every attach.
ssh_connection() {
  local v=""
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    v="$(tmux show-environment SSH_CONNECTION 2>/dev/null || true)"
    if [[ "${v}" == SSH_CONNECTION=* ]]; then
      printf '%s\n' "${v#SSH_CONNECTION=}"
      return 0
    fi
  fi
  printf '%s\n' "${SSH_CONNECTION:-}"
}

# True when the installed sshd config would refuse the SSH session running
# setup. sshd evaluates its own Match blocks (-T -C), so this never disagrees
# with a real login. Also true when we are on SSH but sshd cannot answer: an
# unverifiable restriction must not go live under a remote user.
ssh_session_denied() {
  local sshd="$1" out
  # shellcheck disable=SC2046 # split "client cport server sport" into words
  set -- $(ssh_connection)
  if [[ $# -ne 4 ]]; then
    if is_root && [[ -n "${SUDO_USER:-}" ]]; then
      warn "running under sudo: cannot tell whether you are connected over SSH"
    fi
    return 1
  fi
  SSH_CLIENT_ADDR="$1"
  out="$(root_quiet "${sshd}" -T -f "${SSH_CONFIG_DIR}/sshd_config" \
    -C "user=$(current_user),host=$1,addr=$1,laddr=$3,lport=$4" 2>/dev/null)" || {
    warn "cannot check that your SSH session from $1 stays allowed (sshd -T failed)"
    return 0
  }
  grep -qi '^denyusers \*$' <<<"${out}"
}

# Install the local-network-only drop-in, check it with sshd -t, reload sshd.
# A config sshd rejects is removed again, so sshd never stays broken. Over SSH,
# a config that would refuse this very session is removed too.
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
  if ((!DRY_RUN)) && ! root_quiet "${sshd}" -t -f "${SSH_CONFIG_DIR}/sshd_config"; then
    warn "sshd rejected the new config; removing ${dst}"
    as_root rm -f "${dst}"
    return 1
  fi
  if ((!DRY_RUN)) && ssh_session_denied "${sshd}"; then
    warn "you are connected over SSH from ${SSH_CLIENT_ADDR}, which this restriction refuses; removing ${dst}. Run setup from the local network or the console."
    as_root rm -f "${dst}"
    return 1
  fi
  reload_sshd "${family}"
  ok "SSH logins now only from the local network (${dst})"
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
  if ! has_systemd; then
    echo "SKIPPED systemd not running"
    return 0
  fi
  [[ "${family}" == "debian" ]] && svc=ssh
  # Ubuntu 22.10+ starts sshd per connection from ssh.socket.
  if systemctl is-active --quiet "${svc}" || systemctl is-active --quiet "${svc}.socket"; then echo OK; else echo MISSING; fi
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
  run_tty ssh-keygen "${args[@]}"
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
