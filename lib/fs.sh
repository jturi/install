# shellcheck shell=bash
# Files: compare, back up, private dirs, atomic install of a config file.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

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

# Make a directory only its owner can read: setup logs, the saved selection
# and tmux saves can hold what was on screen. Silent when it already is, so
# reruns stay quiet.
private_dir() {
  local dir="$1"
  if [[ -d "${dir}" && "$(ls -ld "${dir}")" == drwx------* ]]; then return 0; fi
  run mkdir -p "${dir}"
  run chmod 700 "${dir}"
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
