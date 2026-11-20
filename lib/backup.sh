# shellcheck shell=bash
# Backups: before a file changes, the run copies it to
#   ~/.local/bootstrap/backups/<time>/<path under home>
# (files outside the home under _abs/<absolute path>), and lists it in that
# dir's MANIFEST. One dir per run, the newest KEEP_BACKUPS are kept, and
# `setup.sh --restore [<time>]` puts a run's files back.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, BACKUP_DIR, ...).

backup_root() {
  printf '%s\n' "${TARGET_HOME}/.local/bootstrap/backups"
}

# A fresh dir name for this run: the time, plus .N if a run in the same
# second already took it.
new_backup_dir() {
  local base n=0 dir
  base="$(backup_root)/$(date +%Y%m%d_%H%M%S)"
  dir="${base}"
  while [[ -e "${dir}" ]]; do n=$((n + 1)); dir="${base}.${n}"; done
  printf '%s\n' "${dir}"
}

# Where a file's backup goes inside a run dir.
backup_rel() {
  case "$1" in
    "${TARGET_HOME}"/*) printf '%s\n' "${1#"${TARGET_HOME}"/}" ;;
    *) printf '_abs%s\n' "$1" ;;
  esac
}

# Copy an existing file (or symlink) into this run's backup dir before it
# changes. Does nothing when the file does not exist, or when this run saved it
# already: the backup is always the file as it was before the run.
backup_file() {
  local file="$1" dst
  [[ -e "${file}" || -L "${file}" ]] || return 0
  [[ "${file}" == /* ]] || file="${PWD}/${file}"
  # Made on first use; made again if it belongs to another home.
  [[ -n "${BACKUP_DIR}" && "${BACKUP_DIR}" == "$(backup_root)"/* ]] || BACKUP_DIR="$(new_backup_dir)"
  dst="${BACKUP_DIR}/$(backup_rel "${file}")"
  [[ ! -e "${dst}" && ! -L "${dst}" ]] || return 0
  info "Backing up ${file} -> ${dst}"
  if ((DRY_RUN)); then
    printf '   [dry-run] cp -pP %s %s\n' "${file}" "${dst}"
    return 0
  fi
  # Backups hold configs and SSH public keys: only the owner may read them.
  mkdir -p "$(backup_root)" && chmod 700 "$(backup_root)" || return 1
  mkdir -p "$(dirname "${dst}")" || return 1
  run cp -pP "${file}" "${dst}" || return 1
  printf '%s\n' "${file}" >>"${BACKUP_DIR}/MANIFEST"
}

# Run dirs, oldest first (names are times, so a name sort is a time sort).
list_backup_dirs() {
  local root d
  root="$(backup_root)"
  [[ -d "${root}" ]] || return 0
  for d in "${root}"/[0-9]*_[0-9]*; do
    [[ -d "${d}" ]] && printf '%s\n' "${d##*/}"
  done | sort
}

# Keep the newest KEEP_BACKUPS run dirs. Best effort.
prune_backups() {
  local root old
  root="$(backup_root)"
  { list_backup_dirs | sort -r | tail -n +"$((KEEP_BACKUPS + 1))" | while IFS= read -r old; do
    rm -rf "${root:?}/${old}"
  done; } 2>/dev/null || true
}

# True when two paths hold the same thing: same file content, or the same
# symlink target.
same_entry() {
  if [[ -L "$1" || -L "$2" ]]; then
    [[ -L "$1" && -L "$2" && "$(readlink "$1")" == "$(readlink "$2")" ]]
  else
    [[ -f "$1" && -f "$2" ]] && files_equal "$1" "$2"
  fi
}

# --restore list: every run dir with its file count.
print_backups() {
  local d n
  info "Backups in $(backup_root) (oldest first):"
  while IFS= read -r d; do
    n="$(wc -l <"$(backup_root)/${d}/MANIFEST" 2>/dev/null | tr -d ' ')"
    printf '  %s  %s files\n' "${d}" "${n:-0}"
  done < <(list_backup_dirs)
}

# --restore [<time>]: put back every file a run backed up. The files as they
# are now are backed up first, into a new run dir, so a restore can be undone.
restore_backup() {
  local stamp="$1" dir orig src failed=0
  if [[ "${stamp}" == latest ]]; then
    stamp="$(list_backup_dirs | tail -n 1)"
    [[ -n "${stamp}" ]] || die "no backups in $(backup_root)"
  fi
  dir="$(backup_root)/${stamp}"
  if [[ ! -f "${dir}/MANIFEST" ]]; then
    print_backups >&2
    die "no backup ${stamp}"
  fi
  info "Restore from ${dir}:"
  while IFS= read -r orig; do printf '  %s\n' "${orig}"; done <"${dir}/MANIFEST"
  confirm "Go ahead?" || { info "Nothing restored."; return 0; }
  while IFS= read -r orig; do
    [[ -n "${orig}" ]] || continue
    src="${dir}/$(backup_rel "${orig}")"
    if [[ ! -e "${src}" && ! -L "${src}" ]]; then
      warn "${src} is missing; ${orig} not restored"
      failed=1
      continue
    fi
    if same_entry "${src}" "${orig}"; then
      ok "${orig} (unchanged)"
      continue
    fi
    if ! { backup_file "${orig}" && run mkdir -p "$(dirname "${orig}")" &&
      run cp -pP "${src}" "${orig}.restore.$$" && run mv -f "${orig}.restore.$$" "${orig}"; }; then
      rm -f "${orig}.restore.$$"
      warn "could not restore ${orig}"
      failed=1
      continue
    fi
    ((DRY_RUN)) || ok "${orig}"
  done <"${dir}/MANIFEST"
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    info "The replaced files are in ${BACKUP_DIR}; undo with: setup.sh --restore ${BACKUP_DIR##*/}"
  fi
  return "${failed}"
}
