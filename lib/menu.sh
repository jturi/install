# shellcheck shell=bash
# Selection menu. Sourced by setup.sh; reads the CAT_* arrays from catalog.sh.
# Only bash 3.2 and ANSI escape codes: no dialog, whiptail or tput.
#
# menu_handle_key is a pure state change, so tests need no terminal.

MENU_GROUPS=() MENU_VIEW=()
MENU_CURSOR=0 MENU_TOP=0 MENU_ROWS=20 MENU_OPEN_GROUP="" MENU_RESULT="" MENU_GROUP_CURSOR=0

# True when a menu can be drawn: terminal on both ends, and not a dumb one.
menu_available() {
  [[ -t 0 && -t 1 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]]
}

menu_init() {
  local group
  MENU_GROUPS=()
  while IFS= read -r group; do
    MENU_GROUPS+=("${group}")
  done < <(catalog_groups)
  MENU_CURSOR=0 MENU_TOP=0 MENU_OPEN_GROUP="" MENU_RESULT="" MENU_GROUP_CURSOR=0
  menu_build_view
}

# MENU_VIEW holds the rows on screen: group indexes, or catalog indexes of the
# open group.
menu_build_view() {
  local i
  MENU_VIEW=()
  if [[ -z "${MENU_OPEN_GROUP}" ]]; then
    for ((i = 0; i < ${#MENU_GROUPS[@]}; i++)); do MENU_VIEW+=("${i}"); done
  else
    for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
      [[ "${CAT_GROUP[i]}" == "${MENU_OPEN_GROUP}" ]] && MENU_VIEW+=("${i}")
    done
  fi
  return 0
}

# Print "<selected> <total>" for a group.
menu_group_counts() {
  local group="$1" i on=0 total=0
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    [[ "${CAT_GROUP[i]}" == "${group}" ]] || continue
    total=$((total + 1))
    on=$((on + CAT_SEL[i]))
  done
  printf '%s %s\n' "${on}" "${total}"
}

menu_group_summary() {
  local on total
  read -r on total <<<"$(menu_group_counts "$1")"
  printf '%s/%s selected\n' "${on}" "${total}"
}

# All on when any item is off, otherwise all off.
menu_toggle_group() {
  local group="$1" on total i value=1
  read -r on total <<<"$(menu_group_counts "${group}")"
  ((on < total)) || value=0
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    [[ "${CAT_GROUP[i]}" != "${group}" ]] || CAT_SEL[i]="${value}"
  done
}

menu_toggle_cursor() {
  if [[ -n "${MENU_OPEN_GROUP}" ]]; then
    local i="${MENU_VIEW[MENU_CURSOR]}"
    CAT_SEL[i]=$((1 - CAT_SEL[i]))
  else
    menu_toggle_group "${MENU_GROUPS[MENU_CURSOR]}"
  fi
}

# Keep the cursor row inside the visible window.
menu_scroll() {
  local last=$((${#MENU_VIEW[@]} - 1))
  ((MENU_CURSOR <= last)) || MENU_CURSOR="${last}"
  ((MENU_CURSOR >= 0)) || MENU_CURSOR=0
  ((MENU_CURSOR >= MENU_TOP)) || MENU_TOP="${MENU_CURSOR}"
  ((MENU_CURSOR < MENU_TOP + MENU_ROWS)) || MENU_TOP=$((MENU_CURSOR - MENU_ROWS + 1))
}

menu_close_group() {
  [[ -n "${MENU_OPEN_GROUP}" ]] || return 0
  MENU_OPEN_GROUP=""
  menu_build_view
  MENU_CURSOR="${MENU_GROUP_CURSOR}"
  MENU_TOP=0
}

# Keys: up down space enter continue quit back
menu_handle_key() {
  case "$1" in
    up) MENU_CURSOR=$((MENU_CURSOR - 1)) ;;
    down) MENU_CURSOR=$((MENU_CURSOR + 1)) ;;
    space) menu_toggle_cursor ;;
    enter)
      if [[ -n "${MENU_OPEN_GROUP}" ]]; then
        menu_close_group
      else
        local group="${MENU_GROUPS[MENU_CURSOR]}" counts
        counts="$(menu_group_counts "${group}")"
        if [[ "${counts#* }" == "1" ]]; then
          menu_toggle_group "${group}"
        else
          MENU_OPEN_GROUP="${group}"
          MENU_GROUP_CURSOR="${MENU_CURSOR}"
          MENU_CURSOR=0 MENU_TOP=0
          menu_build_view
        fi
      fi
      ;;
    back) menu_close_group ;;
    continue) MENU_RESULT="continue" ;;
    quit) MENU_RESULT="quit" ;;
  esac
  menu_scroll
}

# Print the visible frame.
menu_render() {
  local row last i mark on total pointer
  if [[ -n "${MENU_OPEN_GROUP}" ]]; then
    printf 'What to install > %s\n\n' "${MENU_OPEN_GROUP}"
  else
    printf 'What to install\n\n'
  fi
  last=$((MENU_TOP + MENU_ROWS))
  ((last <= ${#MENU_VIEW[@]})) || last=${#MENU_VIEW[@]}
  for ((row = MENU_TOP; row < last; row++)); do
    pointer="  "
    ((row != MENU_CURSOR)) || pointer="> "
    i="${MENU_VIEW[row]}"
    if [[ -n "${MENU_OPEN_GROUP}" ]]; then
      mark=" "
      ((CAT_SEL[i] == 0)) || mark="x"
      printf '%s[%s] %s' "${pointer}" "${mark}" "${CAT_LABEL[i]}"
      ((CAT_NEW[i] == 0)) || printf '  (new)'
      printf '\n'
    else
      read -r on total <<<"$(menu_group_counts "${MENU_GROUPS[i]}")"
      mark=" "
      if ((on == total)); then mark="x"; elif ((on > 0)); then mark="-"; fi
      printf '%s[%s] %-20s %s/%s selected\n' "${pointer}" "${mark}" "${MENU_GROUPS[i]}" "${on}" "${total}"
    fi
  done
  printf '\narrows move, space toggles, enter opens, c continues, q quits\n'
}

# Read one key and print its token. ESC waits a second for an arrow sequence
# because bash 3.2 has no fractional read timeout.
menu_read_key() {
  local key="" rest=""
  IFS= read -rsn1 key || { echo quit; return 0; }
  case "${key}" in
    "") echo enter ;;
    " ") echo space ;;
    c | C) echo continue ;;
    q | Q) echo quit ;;
    k) echo up ;;
    j) echo down ;;
    $'\033')
      IFS= read -rsn2 -t 1 rest || true
      case "${rest}" in
        '[A' | OA) echo up ;;
        '[B' | OB) echo down ;;
        '[C' | OC) echo enter ;;
        *) echo back ;;
      esac
      ;;
    *) echo none ;;
  esac
}

menu_screen_rows() {
  local lines=""
  read -r lines _ <<<"$(stty size </dev/tty 2>/dev/null || true)"
  [[ "${lines:-0}" -gt 0 ]] 2>/dev/null || lines=24
  MENU_ROWS=$((lines - 4))
  ((MENU_ROWS >= 3)) || MENU_ROWS=3
}

MENU_SAVED_STTY=""
menu_restore_terminal() {
  printf '\033[?25h\033[?1049l' >/dev/tty
  [[ -z "${MENU_SAVED_STTY}" ]] || stty "${MENU_SAVED_STTY}" </dev/tty 2>/dev/null || true
}

# Run the menu. Returns 0 on continue, 1 on quit.
menu_run() {
  MENU_SAVED_STTY="$(stty -g </dev/tty 2>/dev/null || true)"
  trap 'menu_restore_terminal' EXIT
  trap 'menu_restore_terminal; trap - EXIT; exit 130' INT TERM
  printf '\033[?1049h\033[?25l' >/dev/tty
  menu_init
  while [[ -z "${MENU_RESULT}" ]]; do
    menu_screen_rows
    menu_scroll
    { printf '\033[H\033[J'; menu_render; } >/dev/tty
    menu_handle_key "$(menu_read_key)"
  done
  menu_restore_terminal
  trap - EXIT INT TERM
  [[ "${MENU_RESULT}" == "continue" ]]
}
