# shellcheck shell=bash
# Shell startup files (~/.bashrc, ~/.bash_profile, ~/.zprofile): setup.sh
# owns only the lines between its markers
#   # >>> install/setup.sh: <name> >>>
#   # <<< install/setup.sh: <name> <<<
# and rewrites them in place; everything around them is the user's.
# Sourced by setup.sh; uses its globals (DRY_RUN, TARGET_HOME, ...).

rc_begin() { printf '# >>> install/setup.sh: %s >>>' "$1"; }
rc_end() { printf '# <<< install/setup.sh: %s <<<' "$1"; }

# The whole marked block for a body.
rc_block() {
  printf '%s\n# Managed by setup.sh: edits between these markers are replaced on the next run.\n%s\n%s' \
    "$(rc_begin "$1")" "$2" "$(rc_end "$1")"
}

# Follow symlinks to the real file (macOS readlink has no -f before 12.3).
resolve_link() {
  local f="$1" t n=0
  while [[ -L "${f}" ]] && ((n < 40)); do
    t="$(readlink "${f}")"
    [[ "${t}" == /* ]] || t="$(dirname "${f}")/${t}"
    f="${t}"
    n=$((n + 1))
  done
  printf '%s\n' "${f}"
}

# Count whole lines equal to $2 in the text $1.
count_lines() {
  local n=0 line
  while IFS= read -r line; do [[ "${line}" != "$2" ]] || n=$((n + 1)); done <<<"$1"
  printf '%s\n' "${n}"
}

# ensure_rc_block FILE NAME BODY [LEGACY...]
# Put BODY between NAME's markers in FILE: replace the block when it exists,
# else append it. Without markers, each LEGACY text (exact text that older
# versions appended) is taken out first; when the first LEGACY text is there
# whole, the block takes its place instead of going to the end. A symlinked
# FILE is written through (the link stays), its mode is kept, and the write
# is atomic. Markers that do not pair up are never guessed at: return 1.
ensure_rc_block() {
  local file="$1" name="$2" body="$3"
  shift 3
  local begin end block content="" new legacy target tmp nb ne
  begin="$(rc_begin "${name}")" end="$(rc_end "${name}")"
  block="$(rc_block "${name}" "${body}")"
  [[ ! -e "${file}" ]] || content="$(<"${file}")"

  nb="$(count_lines "${content}" "${begin}")" ne="$(count_lines "${content}" "${end}")"
  if ((nb == 1 && ne == 1)) && [[ "${content}" == *"${begin}"*"${end}"* ]]; then
    new="${content%%"${begin}"*}${block}${content#*"${end}"}"
  elif ((nb == 0 && ne == 0)); then
    # A placeholder holds the block's place while legacy texts are taken out,
    # so they are never taken out of the block itself. Splitting (not ${//})
    # keeps a `&` in the block literal under bash 5.2.
    local mark=$'\001setup.sh-block\001'
    new="${content}"
    if (($#)) && [[ -n "$1" && "${new}" == *"$1"* ]]; then
      new="${new%%"$1"*}${mark}${new#*"$1"}"
      shift
    fi
    for legacy in "$@"; do new="${new//"${legacy}"/}"; done
    if [[ "${new}" == *"${mark}"* ]]; then
      new="${new%%"${mark}"*}${block}${new#*"${mark}"}"
    elif [[ -n "${new}" ]]; then
      new="${new}"$'\n\n'"${block}"
    else
      new="${block}"
    fi
  else
    warn "${file}: the '${name}' markers do not pair up (${nb} begin, ${ne} end); fix them by hand, file left alone"
    return 1
  fi

  if [[ -e "${file}" && "${new}" == "${content}" ]]; then
    ok "${file} (unchanged)"
    return 0
  fi
  info "Updating the '${name}' block in ${file}"
  if ((DRY_RUN)); then
    printf '   [dry-run] write the %s block into %s\n' "${name}" "${file}"
    return 0
  fi
  backup_file "${file}" || return 1
  target="$(resolve_link "${file}")"
  tmp="${target}.tmp.$$"
  # cp -p first so the new file keeps the old one's mode.
  if { [[ ! -e "${target}" ]] || cp -p "${target}" "${tmp}"; } &&
    printf '%s\n' "${new}" >"${tmp}" && mv -f "${tmp}" "${target}"; then
    ok "${file}"
    return 0
  fi
  rm -f "${tmp}"
  warn "could not write ${file}"
  return 1
}

# Remove NAME's block from FILE (for --uninstall). Same rules as above.
remove_rc_block() {
  local file="$1" name="$2" content begin end new target tmp nb ne
  [[ -f "${file}" ]] || return 0
  begin="$(rc_begin "${name}")" end="$(rc_end "${name}")"
  content="$(<"${file}")"
  nb="$(count_lines "${content}" "${begin}")" ne="$(count_lines "${content}" "${end}")"
  ((nb + ne)) || return 0
  if ((nb != 1 || ne != 1)) || [[ "${content}" != *"${begin}"*"${end}"* ]]; then
    warn "${file}: the '${name}' markers do not pair up; fix them by hand, file left alone"
    return 1
  fi
  new="${content%%"${begin}"*}${content#*"${end}"}"
  info "Removing the '${name}' block from ${file}"
  if ((DRY_RUN)); then
    printf '   [dry-run] remove the %s block from %s\n' "${name}" "${file}"
    return 0
  fi
  backup_file "${file}" || return 1
  target="$(resolve_link "${file}")"
  tmp="${target}.tmp.$$"
  if cp -p "${target}" "${tmp}" && printf '%s\n' "${new}" >"${tmp}" && mv -f "${tmp}" "${target}"; then
    ok "${file}"
    return 0
  fi
  rm -f "${tmp}"
  warn "could not write ${file}"
  return 1
}
