# shellcheck shell=bash
# Catalog of selectable items. Sourced by setup.sh; needs die() and pkg_name().
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
  local line n=0 group item label platforms def action extra problem
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
    IFS='|' read -r group item label platforms def action extra <<<"${line}"
    problem="$(catalog_line_error "${item}" "${label}" "${platforms}" "${def}" "${action}" "${extra}" "${group}")"
    [[ -z "${problem}" ]] || die "bad catalog ${file} line ${n}: ${problem}"
    catalog_matches "${platforms}" "${platform}" "${wsl}" || continue
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
