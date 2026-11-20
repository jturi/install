#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # tests change state inside subshells on purpose
# Unit tests for scripts/dotfiles-drift.sh: manifest, filters, ticks, menu, sync.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../scripts/dotfiles-drift.sh
source "${REPO}/scripts/dotfiles-drift.sh"
set +e

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILS=0
C_BLUE="" C_YELLOW="" C_RED="" C_GREEN="" C_DIM="" C_RESET=""

check() {
  local name="$1" want="$2" got="$3"
  if [[ "${got}" == "${want}" ]]; then
    printf 'PASS %s\n' "${name}"
  else
    printf 'FAIL %s: want [%s] got [%s]\n' "${name}" "${want}" "${got}"
    FAILS=$((FAILS + 1))
  fi
}

# True when $2 contains $3.
check_has() {
  local name="$1" text="$2" want="$3"
  if [[ "${text}" == *"${want}"* ]]; then
    printf 'PASS %s\n' "${name}"
  else
    printf 'FAIL %s: [%s] not in output:\n%s\n' "${name}" "${want}" "${text}"
    FAILS=$((FAILS + 1))
  fi
}

# A fresh install repo, dotfiles repo, manifest and home under $WORK/<name>.
fixture() {
  local d="${WORK}/$1"
  mkdir -p "${d}/install/configs/bin" "${d}/dotfiles/bin" "${d}/fakehome"
  printf 'set a 1\nset b 2\n' >"${d}/install/configs/same.conf"
  printf 'set a 1\nset b 2\n' >"${d}/dotfiles/dot_same"
  printf 'set a 1\nset b 3\n' >"${d}/install/configs/drift.conf"
  printf 'set a 1\nset b 2\n' >"${d}/dotfiles/dot_drift"
  printf '# ~/.x (from dotfiles)\nset a 1\n' >"${d}/install/configs/header.conf"
  printf '# nano ~/.x\nset a 1\n' >"${d}/dotfiles/dot_header"
  printf 'top\n\n# LOADER\nsource ~/.aliases\n' >"${d}/install/configs/rc"
  printf 'top-new\n' >"${d}/dotfiles/dot_rc"
  printf '#!/bin/sh\necho old\n' >"${d}/install/configs/bin/tool.sh"
  chmod 755 "${d}/install/configs/bin/tool.sh"
  printf '#!/bin/sh\necho new\n' >"${d}/dotfiles/bin/tool.sh"
  cat >"${d}/manifest" <<'EOF'
# test manifest
g|same|Same file|on|configs/same.conf|dot_same|-|-
g|drift|Drifted file|on|configs/drift.conf|dot_drift|-|-
h|header|Header differs|on|configs/header.conf|dot_header|-|^#( ~/\.x| nano ~/\.x)
h|rc|Stop line|on|configs/rc|dot_rc|# LOADER|-
h|tool|Script|off|configs/bin/tool.sh|bin/tool.sh|-|-
EOF
  printf '%s\n' "${d}"
}

# Run drift_main in a subshell against fixture dir $1; prints output, then
# "rc=<status>" on the last line.
drift_in() {
  local d="$1"
  shift
  (
    ROOT="${d}/install" DOTFILES="${d}/dotfiles" MANIFEST="${d}/manifest"
    TARGET_HOME="${d}/fakehome" DRIFT_CONFIG="${d}/fakehome/.local/bootstrap/dotfiles-drift"
    drift_main "$@" </dev/null 2>&1
  )
  printf 'rc=%s\n' "$?"
}

# --- filters -----------------------------------------------------------------
printf 'a\n# drop me\nb\n\n\n' >"${WORK}/view"
check view-ignore "$(printf 'a\nb')" "$(drift_view "${WORK}/view" "" '^# drop')"
check view-trailing-blank "$(printf 'a\n# drop me\nb')" "$(drift_view "${WORK}/view" "" "")"
check view-stop "a" "$(drift_view "${WORK}/view" "# drop" "")"
printf 'x.y\nxzy\nb\n' >"${WORK}/view2"
check view-ignore-literal-dot "xzy" "$(drift_view "${WORK}/view2" "" '^b$|^x\.y$')"
check tail-from-stop "$(printf '# drop me\nb')" "$(drift_tail "${WORK}/view" "# drop" | sed '/^$/d')"

# --- check -------------------------------------------------------------------
d="$(fixture check)"
out="$(drift_in "${d}" check)"
check_has check-same-ok "${out}" "OK      g.same"
check_has check-drift "${out}" "DRIFT   g.drift"
check_has check-drift-counts "${out}" "1 lines only in dotfiles, 1 only here"
check_has check-ignore-ok "${out}" "OK      h.header"
check_has check-stop-compares-above "${out}" "DRIFT   h.rc"
check_has check-summary "${out}" "2 in sync, 2 drifted, 0 missing, 1 not ticked"
check_has check-fails-on-drift "${out}" "rc=1"
check_has check-verbose-diff "$(drift_in "${d}" check -v g.drift)" "+set b 3"
check_has check-name-group "$(drift_in "${d}" check g)" "1 in sync, 1 drifted, 0 missing, 3 not ticked"
check_has check-name-overrides-tick "$(drift_in "${d}" check tool)" "DRIFT   h.tool"
check_has check-in-sync-passes "$(drift_in "${d}" check same header)" "rc=0"
check_has check-unknown-name "$(drift_in "${d}" check nope)" "unknown name 'nope'"
printf 'set b 2\n\n# LOADER\nx\n' >"${d}/install/configs/rc"
printf 'set b 2\n' >"${d}/dotfiles/dot_rc"
check_has check-stop-ignores-tail "$(drift_in "${d}" check rc)" "OK      h.rc"
rm "${d}/dotfiles/dot_same"
out="$(drift_in "${d}" check same)"
check_has check-missing "${out}" "MISSING g.same"
check_has check-missing-fails "${out}" "rc=1"
check_has check-no-manifest "$(drift_in "${WORK}/none" check)" "cannot read manifest"
rm -rf "${d}/dotfiles"
check_has check-no-dotfiles "$(drift_in "${d}" check)" "no dotfiles repo at"

# --- saved ticks -------------------------------------------------------------
d="$(fixture ticks)"
mkdir -p "${d}/fakehome/.local/bootstrap"
printf 'g.drift=0\nh.rc=0\nh.tool=1\nold.key=1\n' >"${d}/fakehome/.local/bootstrap/dotfiles-drift"
out="$(drift_in "${d}" check)"
check_has ticks-skip-unticked "${out}" "not ticked"
check_has ticks-tick-default-off "${out}" "DRIFT   h.tool"
check "ticks-drift-off-not-checked" "" "$(printf '%s\n' "${out}" | grep 'g.drift')"
check_has ticks-list-marks "$(drift_in "${d}" list)" "[x] h.tool"
check_has ticks-list-unticked "$(drift_in "${d}" list)" "[ ] g.drift"

# --- menu --------------------------------------------------------------------
d="$(fixture menu)"
start="${FAILS}"
(
  ROOT="${d}/install" TARGET_HOME="${d}/fakehome" DRY_RUN=0
  cfg="${d}/fakehome/.local/bootstrap/dotfiles-drift"
  drift_load "${d}/manifest"
  config_load "${cfg}"
  menu_init
  check menu-title "Files to keep in sync with dotfiles" "$(menu_render | head -n 1)"
  check_has menu-groups "$(menu_render)" "[x] g"
  menu_handle_key enter # open g
  check_has menu-open-title "$(menu_render)" "Files to keep in sync with dotfiles > g"
  menu_handle_key down
  menu_handle_key space # untick g.drift
  menu_handle_key back
  menu_handle_key down
  menu_handle_key enter # open h
  menu_handle_key down
  menu_handle_key down
  menu_handle_key space # tick h.tool
  config_save "${cfg}"
  check menu-saved "$(printf '%s\n' "${CONFIG_HEADER}" g.drift=0 g.same=1 h.header=1 h.rc=1 h.tool=1)" "$(cat "${cfg}")"
  # shellcheck disable=SC2012 # the mode string is the point; the path is ours
  check menu-private-dir "drwx------" "$(ls -ld "${d}/fakehome/.local/bootstrap" | cut -c1-10)"
  exit $((FAILS - start))
) || FAILS=$((FAILS + $?))
check_has menu-save-used-by-check "$(drift_in "${d}" check)" "2 in sync, 2 drifted, 0 missing, 1 not ticked"
check_has select-needs-terminal "$(drift_in "${d}" select)" "select needs a terminal"
check_has setup-menu-title-default "$(MENU_TITLE='' bash -c "source '${REPO}/setup.sh'; printf '%s' \"\${MENU_TITLE}\"")" "What to install"

# --- sync --------------------------------------------------------------------
d="$(fixture sync)"
out="$(drift_in "${d}" sync -n drift tool rc)"
check_has sync-dry-run-says "${out}" "[dry-run] would copy dotfiles/dot_drift"
check sync-dry-run-unchanged "$(printf 'set a 1\nset b 3')" "$(cat "${d}/install/configs/drift.conf")"
out="$(drift_in "${d}" sync drift)"
check_has sync-no-tty-keeps "${out}" "Kept configs/drift.conf"
check_has sync-shows-loss "${out}" "-set b 3"
check sync-no-tty-unchanged "$(printf 'set a 1\nset b 3')" "$(cat "${d}/install/configs/drift.conf")"
out="$(drift_in "${d}" sync -y drift tool rc header)"
check sync-copies "$(printf 'set a 1\nset b 2')" "$(cat "${d}/install/configs/drift.conf")"
check sync-keeps-exec "yes" "$([[ -x "${d}/install/configs/bin/tool.sh" ]] && echo yes || echo no)"
check sync-keeps-tail "$(printf 'top-new\n\n# LOADER\nsource ~/.aliases')" "$(cat "${d}/install/configs/rc")"
check_has sync-summary "${out}" "3 updated, 0 kept, 0 to merge by hand"
check_has sync-after-is-clean "$(drift_in "${d}" check drift tool rc)" "3 in sync, 0 drifted"
printf '# ~/.x (from dotfiles)\nset a 2\n' >"${d}/install/configs/header.conf"
out="$(drift_in "${d}" sync -y header)"
check_has sync-ignore-is-check-only "${out}" "h.header: check-only"
check sync-ignore-unchanged "$(printf '# ~/.x (from dotfiles)\nset a 2')" "$(cat "${d}/install/configs/header.conf")"

# --- manifest validation -----------------------------------------------------
bad() {
  local name="$1" line="$2" want="$3"
  printf '%s\n' "${line}" >"${WORK}/bad"
  check_has "manifest-${name}" "$( (drift_load "${WORK}/bad") 2>&1)" "${want}"
}
bad few 'g|i|L|on|a|b|-' "too few fields"
bad default 'g|i|L|maybe|a|b|-|-' "default must be on or off"
bad outside 'g|i|L|on|../x|b|-|-' "inside the repo"
bad absolute 'g|i|L|on|/etc/x|b|-|-' "inside the repo"
bad duplicate "$(printf 'g|i|L|on|a|b|-|-\ng|i|L|on|a|b|-|-')" "duplicate key g.i"
bad empty '# nothing' "lists no files"
drift_load "${WORK}/check/manifest"
check manifest-pipe-in-ignore '^#( ~/\.x| nano ~/\.x)' "${DRIFT_IGNORE[2]}"

# The real manifest parses and every install file exists.
drift_load "${REPO}/dotfiles.txt"
missing=""
for ((i = 0; i < ${#DRIFT_LOCAL[@]}; i++)); do
  [[ -f "${REPO}/${DRIFT_LOCAL[i]}" ]] || missing="${missing} ${DRIFT_LOCAL[i]}"
done
check manifest-real-files-exist "" "${missing}"

if ((FAILS)); then
  printf '%s test(s) failed\n' "${FAILS}"
  exit 1
fi
printf 'All drift tests passed\n'
