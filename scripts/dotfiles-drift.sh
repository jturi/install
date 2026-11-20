#!/usr/bin/env bash
# Check and sync the files this repo mirrors from the dotfiles repo.
#
# The files are listed in dotfiles.txt. Which of them you check is your
# choice: `select` shows the installer's checkbox menu and saves the ticks to
# ~/.local/bootstrap/dotfiles-drift; check and sync then use only ticked files.
#
# Usage: scripts/dotfiles-drift.sh [check] [-v] [name ...]
#        scripts/dotfiles-drift.sh select
#        scripts/dotfiles-drift.sh list
#        scripts/dotfiles-drift.sh sync [-y] [-n] [name ...]
#
# A name is an item (tmuxhelp), a key (tmux.tmuxhelp) or a group (tmux). Named
# files are used whether ticked or not.
#
# Environment: DOTFILES     dotfiles checkout (default: ../dotfiles)
#              MANIFEST     file list (default: dotfiles.txt)
#              DRIFT_CONFIG saved ticks (default: ~/.local/bootstrap/dotfiles-drift)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# setup.sh runs nothing when sourced; it brings the helpers, the catalog
# selection (config_load/config_save) and the checkbox menu.
# shellcheck source-path=SCRIPTDIR source=../setup.sh
source "${ROOT}/setup.sh"

DOTFILES="${DOTFILES:-${ROOT}/../dotfiles}"
MANIFEST="${MANIFEST:-${ROOT}/dotfiles.txt}"
DRIFT_CONFIG="${DRIFT_CONFIG:-${TARGET_HOME}/.local/bootstrap/dotfiles-drift}"
# shellcheck disable=SC2034 # read by config_save (lib/catalog.sh) and menu_render (lib/menu.sh)
CONFIG_HEADER='# Saved by make dotfiles-select. 1 = check and sync, 0 = skip. Safe to edit by hand.'
# shellcheck disable=SC2034
MENU_TITLE='Files to keep in sync with dotfiles'
VERBOSE=0

# Per item, next to the CAT_* arrays: install path, dotfiles path, stop, ignore.
DRIFT_LOCAL=() DRIFT_SOURCE=() DRIFT_STOP=() DRIFT_IGNORE=()

drift_usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# Fill CAT_* (for the menu and the saved ticks) and DRIFT_* from the manifest.
drift_load() {
  local file="$1" line n=0 group item label def local_path source_path stop ignore known_keys=" "
  [[ -r "${file}" ]] || die "cannot read manifest: ${file}"
  CAT_GROUP=() CAT_ITEM=() CAT_LABEL=() CAT_DEFAULT=() CAT_ACTION=()
  DRIFT_LOCAL=() DRIFT_SOURCE=() DRIFT_STOP=() DRIFT_IGNORE=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
    # ignore is last, so read leaves any | inside it alone.
    IFS='|' read -r group item label def local_path source_path stop ignore <<<"${line}"
    [[ -n "${group}" && -n "${item}" && -n "${label}" && -n "${def}" && -n "${local_path}" &&
      -n "${source_path}" && -n "${stop}" && -n "${ignore}" ]] ||
      die "bad manifest ${file} line ${n}: too few fields (use - for no stop or ignore)"
    [[ "${def}" == "on" || "${def}" == "off" ]] || die "bad manifest ${file} line ${n}: default must be on or off"
    [[ "${local_path}" != /* && "${local_path}" != *..* ]] ||
      die "bad manifest ${file} line ${n}: install file must be inside the repo"
    [[ "${known_keys}" != *" ${group}.${item} "* ]] || die "bad manifest ${file} line ${n}: duplicate key ${group}.${item}"
    known_keys="${known_keys}${group}.${item} "
    [[ "${stop}" != "-" ]] || stop=""
    [[ "${ignore}" != "-" ]] || ignore=""
    CAT_GROUP+=("${group}") CAT_ITEM+=("${item}") CAT_LABEL+=("${label}")
    CAT_DEFAULT+=("${def}") CAT_ACTION+=("drift")
    DRIFT_LOCAL+=("${local_path}") DRIFT_SOURCE+=("${source_path}")
    DRIFT_STOP+=("${stop}") DRIFT_IGNORE+=("${ignore}")
  done <"${file}"
  ((${#CAT_ITEM[@]})) || die "manifest ${file} lists no files"
}

# Tick only the named items (item, group.item or group), ignoring saved ticks.
drift_pick() {
  local name i found
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do CAT_SEL[i]=0; done
  for name in "$@"; do
    found=0
    for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
      if [[ "${name}" == "${CAT_ITEM[i]}" || "${name}" == "${CAT_GROUP[i]}.${CAT_ITEM[i]}" || "${name}" == "${CAT_GROUP[i]}" ]]; then
        CAT_SEL[i]=1
        found=1
      fi
    done
    ((found)) || die "unknown name '${name}' (see: scripts/dotfiles-drift.sh list)"
  done
}

# Print a file the way it is compared: lines matching the ignore regex left
# out, everything from the stop line on cut off, trailing blank lines dropped.
# The patterns go through ENVIRON: awk -v would rewrite the backslashes.
drift_view() {
  DRIFT_AWK_STOP="$2" DRIFT_AWK_IGNORE="$3" awk '
    BEGIN { stop = ENVIRON["DRIFT_AWK_STOP"]; ignore = ENVIRON["DRIFT_AWK_IGNORE"] }
    stop != "" && index($0, stop) == 1 { exit }
    ignore != "" && $0 ~ ignore { next }
    { lines[++n] = $0 }
    END { while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }
  ' "$1"
}

# Print the install file from its stop line to the end (the part sync keeps).
drift_tail() {
  DRIFT_AWK_STOP="$2" awk 'index($0, ENVIRON["DRIFT_AWK_STOP"]) == 1 { on = 1 } on' "$1"
}

# "last commit: install <date>, dotfiles <date>", with "+ edits" for
# uncommitted changes. Tells which side moved last.
drift_dates() {
  local a b
  a="$(git -C "${ROOT}" log -1 --format=%cs -- "$1" 2>/dev/null || true)"
  [[ -z "$(git -C "${ROOT}" status --porcelain -- "$1" 2>/dev/null || true)" ]] || a="${a:-new} + edits"
  b="$(git -C "${DOTFILES}" log -1 --format=%cs -- "$2" 2>/dev/null || true)"
  [[ -z "$(git -C "${DOTFILES}" status --porcelain -- "$2" 2>/dev/null || true)" ]] || b="${b:-new} + edits"
  printf 'last commit: install %s, dotfiles %s' "${a:-?}" "${b:-?}"
}

drift_require_dotfiles() {
  [[ -d "${DOTFILES}" ]] || die "no dotfiles repo at ${DOTFILES} (set DOTFILES=<path>)"
}

# Compare item $1. Prints one status line (and the diff with -v).
# Returns 0 when in sync, 1 on drift, 2 when a file is missing.
drift_check_item() {
  local i="$1" key local_file source_file a b counts only_dot only_here
  key="$(catalog_key "${i}")"
  local_file="${ROOT}/${DRIFT_LOCAL[i]}"
  source_file="${DOTFILES}/${DRIFT_SOURCE[i]}"
  if [[ ! -f "${local_file}" || ! -f "${source_file}" ]]; then
    [[ -f "${local_file}" ]] || printf '%sMISSING%s %-22s %s (in this repo)\n' "${C_RED}" "${C_RESET}" "${key}" "${DRIFT_LOCAL[i]}"
    [[ -f "${source_file}" ]] || printf '%sMISSING%s %-22s %s (in dotfiles)\n' "${C_RED}" "${C_RESET}" "${key}" "${DRIFT_SOURCE[i]}"
    return 2
  fi
  a="${RUN_DIR}/dotfiles.view" b="${RUN_DIR}/install.view"
  drift_view "${source_file}" "" "${DRIFT_IGNORE[i]}" >"${a}"
  drift_view "${local_file}" "${DRIFT_STOP[i]}" "${DRIFT_IGNORE[i]}" >"${b}"
  if files_equal "${a}" "${b}"; then
    printf '%sOK%s      %-22s %s\n' "${C_GREEN}" "${C_RESET}" "${key}" "${DRIFT_LOCAL[i]}"
    return 0
  fi
  counts="$(diff "${a}" "${b}" | awk '/^</ { d++ } /^>/ { h++ } END { printf "%d %d", d, h }' || true)"
  read -r only_dot only_here <<<"${counts}"
  printf '%sDRIFT%s   %-22s %s  (%s lines only in dotfiles, %s only here; %s)\n' "${C_YELLOW}" "${C_RESET}" \
    "${key}" "${DRIFT_LOCAL[i]}" "${only_dot}" "${only_here}" "$(drift_dates "${DRIFT_LOCAL[i]}" "${DRIFT_SOURCE[i]}")"
  if ((VERBOSE)); then
    diff -u -L "dotfiles/${DRIFT_SOURCE[i]}" -L "install/${DRIFT_LOCAL[i]}" "${a}" "${b}" | sed 's/^/    /' || true
  fi
  return 1
}

drift_check() {
  drift_require_dotfiles
  local i rc drift=0 missing=0 ok_count=0 skipped=0
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    if [[ "${CAT_SEL[i]}" != "1" ]]; then skipped=$((skipped + 1)); continue; fi
    rc=0
    drift_check_item "${i}" || rc=$?
    case "${rc}" in
      0) ok_count=$((ok_count + 1)) ;;
      1) drift=$((drift + 1)) ;;
      *) missing=$((missing + 1)) ;;
    esac
  done
  printf '\n%s in sync, %s drifted, %s missing, %s not ticked (make dotfiles-select)\n' \
    "${ok_count}" "${drift}" "${missing}" "${skipped}"
  ((drift == 0 || VERBOSE)) || printf 'Show the diffs: make dotfiles-drift ARGS=-v\n'
  ((drift + missing == 0))
}

drift_list() {
  local i mark
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    mark=" "
    [[ "${CAT_SEL[i]}" != "1" ]] || mark="x"
    printf '[%s] %-22s %-50s %s <- %s\n' "${mark}" "$(catalog_key "${i}")" "${CAT_LABEL[i]}" \
      "${DRIFT_LOCAL[i]}" "${DRIFT_SOURCE[i]}"
  done
  printf '\nTicks: %s\n' "${DRIFT_CONFIG}"
}

drift_select() {
  menu_available || die "select needs a terminal"
  if ! menu_run; then
    info "Quit: nothing saved"
    return 0
  fi
  config_save "${DRIFT_CONFIG}" || die "could not save ${DRIFT_CONFIG}"
  ok "Saved ${DRIFT_CONFIG}"
  drift_list
}

# Ask before overwriting; the default is no, and no terminal means no.
drift_confirm() {
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || return 1
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "${reply}" =~ ^[Yy] ]]
}

# Copy each ticked, drifted file from dotfiles over the install copy, keeping
# the install tail below its stop line. Shows the change and asks first.
drift_sync() {
  drift_require_dotfiles
  local i rc key local_file new mode changed=0 declined=0 manual=0
  new="${RUN_DIR}/sync.new"
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    [[ "${CAT_SEL[i]}" == "1" ]] || continue
    rc=0
    drift_check_item "${i}" || rc=$?
    ((rc == 1)) || continue
    key="$(catalog_key "${i}")"
    local_file="${ROOT}/${DRIFT_LOCAL[i]}"
    if [[ -n "${DRIFT_IGNORE[i]}" ]]; then
      warn "${key}: check-only (it has an ignore regex); merge ${DRIFT_LOCAL[i]} by hand"
      manual=$((manual + 1))
      continue
    fi
    cp "${DOTFILES}/${DRIFT_SOURCE[i]}" "${new}"
    if [[ -n "${DRIFT_STOP[i]}" ]]; then
      { printf '\n'; drift_tail "${local_file}" "${DRIFT_STOP[i]}"; } >>"${new}"
    fi
    printf '    Change to %s (- lines are lost from this repo):\n' "${DRIFT_LOCAL[i]}"
    diff -u -L "install/${DRIFT_LOCAL[i]}" -L "after sync" "${local_file}" "${new}" | sed 's/^/    /' || true
    if ((DRY_RUN)); then
      printf '   [dry-run] would copy dotfiles/%s over %s\n' "${DRIFT_SOURCE[i]}" "${DRIFT_LOCAL[i]}"
      continue
    fi
    if ! drift_confirm "Overwrite ${DRIFT_LOCAL[i]} with the dotfiles version?"; then
      info "Kept ${DRIFT_LOCAL[i]}"
      declined=$((declined + 1))
      continue
    fi
    mode=644
    [[ ! -x "${local_file}" ]] || mode=755
    # The repo is under git, so no .bak copy: git diff shows the change.
    atomic_copy "${new}" "${local_file}" "${mode}"
    ok "${DRIFT_LOCAL[i]}"
    changed=$((changed + 1))
  done
  printf '\n%s updated, %s kept, %s to merge by hand\n' "${changed}" "${declined}" "${manual}"
  ((changed == 0)) || git -C "${ROOT}" --no-pager diff --stat -- . || true
}

drift_main() {
  local cmd=check
  case "${1:-}" in
    check | select | list | sync) cmd="$1"; shift ;;
    -h | --help | help) drift_usage; return 0 ;;
  esac
  local -a names=()
  while (($#)); do
    case "$1" in
      -v | --verbose) VERBOSE=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -n | --dry-run) DRY_RUN=1 ;;
      -h | --help) drift_usage; return 0 ;;
      -*) die "unknown option: $1 (see --help)" ;;
      *) names+=("$1") ;;
    esac
    shift
  done
  RUN_DIR="$(mktemp -d)"
  trap 'rm -rf "${RUN_DIR}"' EXIT
  drift_load "${MANIFEST}"
  config_load "${DRIFT_CONFIG}"
  ((${#names[@]} == 0)) || drift_pick "${names[@]}"
  case "${cmd}" in
    check) drift_check ;;
    list) drift_list ;;
    select)
      ((${#names[@]} == 0)) || die "select takes no names"
      drift_select
      ;;
    sync) drift_sync ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  drift_main "$@"
fi
