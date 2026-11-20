# shellcheck shell=bash disable=SC2034 # CAT_* arrays are read by setup.sh and menu.sh
# Catalog of selectable items. Sourced by setup.sh; needs die(), pkg_name()
# and private_dir().
# Works with bash 3.2: parallel arrays instead of associative ones.
#
# catalog.txt format, one item per line:
#   group|item|label|platforms|default|action

CAT_GROUP=() CAT_ITEM=() CAT_LABEL=() CAT_DEFAULT=() CAT_ACTION=()

# True when a comma list of platforms covers this machine. WSL is also linux.
catalog_matches() {
  local platforms="$1" platform="$2" wsl="$3" word
  local IFS=,
  for word in ${platforms}; do
    [[ "${word}" == "${platform}" ]] && return 0
    [[ "${word}" == "wsl" && "${wsl}" == "1" ]] && return 0
  done
  return 1
}

# Print why a split catalog line is invalid; print nothing when it is fine.
catalog_line_error() {
  local item="$1" label="$2" platforms="$3" def="$4" action="$5" extra="$6" group="$7" word
  [[ -z "${extra}" ]] || { echo "too many fields"; return 0; }
  [[ -n "${group}" && -n "${item}" && -n "${label}" && -n "${platforms}" && -n "${def}" && -n "${action}" ]] ||
    { echo "too few fields"; return 0; }
  [[ "${def}" == "on" || "${def}" == "off" ]] || { echo "default must be on or off"; return 0; }
  local IFS=,
  for word in ${platforms}; do
    case "${word}" in
      linux | macos | wsl | windows) ;;
      *) echo "unknown platform '${word}'"; return 0 ;;
    esac
  done
  case "${action}" in
    pkg | scoop:?*/?* | step:?*) ;;
    *) echo "unknown action '${action}'" ;;
  esac
}

# Fill the CAT_* arrays with the items for this platform.
# Usage: catalog_load <file> <linux|macos|windows> <wsl: 0|1>
catalog_load() {
  local file="$1" platform="$2" wsl="$3"
  [[ -r "${file}" ]] || die "cannot read catalog: ${file}"
  CAT_GROUP=() CAT_ITEM=() CAT_LABEL=() CAT_DEFAULT=() CAT_ACTION=()
  local line n=0 group item label platforms def action extra problem seen=" "
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
    IFS='|' read -r group item label platforms def action extra <<<"${line}"
    problem="$(catalog_line_error "${item}" "${label}" "${platforms}" "${def}" "${action}" "${extra}" "${group}")"
    [[ -z "${problem}" ]] || die "bad catalog ${file} line ${n}: ${problem}"
    catalog_matches "${platforms}" "${platform}" "${wsl}" || continue
    [[ "${seen}" != *" ${group}.${item} "* ]] || die "bad catalog ${file} line ${n}: duplicate key ${group}.${item}"
    seen="${seen}${group}.${item} "
    CAT_GROUP+=("${group}")
    CAT_ITEM+=("${item}")
    CAT_LABEL+=("${label}")
    CAT_DEFAULT+=("${def}")
    CAT_ACTION+=("${action}")
  done <"${file}"
}

# Drop pkg items that have no package on this distro (less on macOS).
catalog_hide_unmapped() {
  local family="$1" i
  local -a group=() item=() label=() def=() action=()
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    if [[ "${CAT_ACTION[i]}" == "pkg" && -z "$(pkg_name "${family}" "${CAT_ITEM[i]}")" ]]; then
      continue
    fi
    group+=("${CAT_GROUP[i]}")
    item+=("${CAT_ITEM[i]}")
    label+=("${CAT_LABEL[i]}")
    def+=("${CAT_DEFAULT[i]}")
    action+=("${CAT_ACTION[i]}")
  done
  CAT_GROUP=(${group[@]+"${group[@]}"})
  CAT_ITEM=(${item[@]+"${item[@]}"})
  CAT_LABEL=(${label[@]+"${label[@]}"})
  CAT_DEFAULT=(${def[@]+"${def[@]}"})
  CAT_ACTION=(${action[@]+"${action[@]}"})
}

# Print the config key of one item: <group>.<item>.
catalog_key() {
  printf '%s.%s\n' "${CAT_GROUP[$1]}" "${CAT_ITEM[$1]}"
}

# Print each group once, in file order.
catalog_groups() {
  local i seen=" "
  for ((i = 0; i < ${#CAT_GROUP[@]}; i++)); do
    [[ "${seen}" == *" ${CAT_GROUP[i]} "* ]] && continue
    seen="${seen}${CAT_GROUP[i]} "
    printf '%s\n' "${CAT_GROUP[i]}"
  done
}

# --- Saved selection ---------------------------------------------------------

CAT_SEL=() CAT_NEW=() CONFIG_EXTRA=()
CONFIG_HEADER='# Saved by the installer. 1 = install, 0 = leave alone. Safe to edit by hand.'

config_default_path() {
  printf '%s\n' "${TARGET_HOME}/.local/bootstrap/config"
}

# Set CAT_SEL and CAT_NEW from a config file, or from catalog defaults when the
# file is missing. Keys for other platforms go to CONFIG_EXTRA and stay on save.
# Reads files edited on Windows: a UTF-8 BOM and CRLF line endings are fine.
config_load() {
  local file="$1" i line n=0 key value matched
  local -a seen=()
  CAT_SEL=() CAT_NEW=() CONFIG_EXTRA=()
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    if [[ "${CAT_DEFAULT[i]}" == "on" ]]; then CAT_SEL[i]=1; else CAT_SEL[i]=0; fi
    CAT_NEW[i]=0
    seen[i]=0
  done
  [[ -f "${file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    ((n > 1)) || line="${line#$'\xEF\xBB\xBF'}"
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "${line}" != *=* || -z "${key}" || ( "${value}" != "0" && "${value}" != "1" ) ]]; then
      warn "${file} line ${n}: ignoring '${line}'"
      continue
    fi
    matched=0
    for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
      if [[ "${CAT_GROUP[i]}.${CAT_ITEM[i]}" == "${key}" ]]; then
        CAT_SEL[i]="${value}"
        seen[i]=1
        matched=1
        break
      fi
    done
    ((matched)) || CONFIG_EXTRA+=("${line}")
  done <"${file}"

  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    ((seen[i])) || CAT_NEW[i]=1
  done
}

# Write the selection atomically, keeping keys for other platforms. All lines
# are sorted bytewise so setup.ps1 writes identical bytes. Returns non-zero on
# failure and leaves the old file in place.
config_save() {
  local file="$1" tmp="$1.tmp.$$" i
  ((!DRY_RUN)) || return 0
  local dir
  dir="$(dirname "${file}")"
  # The default directory also holds the logs: keep it private (setup.sh).
  if [[ "${dir}" == "${TARGET_HOME}/.local/bootstrap" ]]; then
    private_dir "${dir}" >/dev/null || return 1
  else
    mkdir -p "${dir}" || return 1
  fi
  {
    printf '%s\n' "${CONFIG_HEADER}"
    {
      for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
        printf '%s.%s=%s\n' "${CAT_GROUP[i]}" "${CAT_ITEM[i]}" "${CAT_SEL[i]}"
      done
      [[ ${#CONFIG_EXTRA[@]} -eq 0 ]] || printf '%s\n' "${CONFIG_EXTRA[@]}"
    } | LC_ALL=C sort -u
  } >"${tmp}" || { rm -f "${tmp}"; return 1; }
  if [[ -f "${file}" ]] && files_equal "${tmp}" "${file}"; then
    rm -f "${tmp}"
    return 0
  fi
  backup_file "${file}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
}
