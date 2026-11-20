#!/usr/bin/env bash
# Public repo guards: no personal data, and .ps1 files that PowerShell 5.1 can read.
#
# Usage: tests/test_repo.sh             scan the repo (tracked + untracked files)
#        tests/test_repo.sh <dir>       scan every file under <dir>
#        tests/test_repo.sh --self-test prove each rule fires
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The address the commit attribution uses, and addresses for documentation.
ALLOWED_EMAIL='(@example\.(com|org|net)|^noreply@anthropic\.com$|^git@github\.com$)'
IP_RE='(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})($|[^0-9.])'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
PATH_RE='([A-Za-z]:\\+Users\\+[A-Za-z0-9_.-]+|(^|[^A-Za-z0-9_.])/(home|Users)/[A-Za-z0-9_.-]+)'

scan_file() {
  local f="$1" line
  # Network ranges (x.y.z.0/n, e.g. in an sshd Match line) name no machine:
  # drop them first. A host address, with or without a mask, still counts.
  if grep -Iq . "${f}" 2>/dev/null; then
    LC_ALL=C sed -E 's#[0-9]{1,3}(\.[0-9]{1,3}){2}\.0/[0-9]{1,2}##g' "${f}" | grep -nE "${IP_RE}" | cut -d: -f1 | while read -r line; do
      printf '%s:%s: private IP\n' "${f}" "${line}"
    done
  fi
  grep -InE "${PATH_RE}" "${f}" 2>/dev/null | cut -d: -f1 | while read -r line; do
    printf '%s:%s: personal path\n' "${f}" "${line}"
  done
  grep -InoE "${EMAIL_RE}" "${f}" 2>/dev/null | while IFS=: read -r line addr; do
    printf '%s\n' "${addr}" | grep -qE "${ALLOWED_EMAIL}" ||
      printf '%s:%s: email address\n' "${f}" "${line}"
  done
  if [[ "${f}" == *.ps1 ]] && LC_ALL=C grep -q $'[\x80-\xFF]' "${f}" &&
    [[ "$(head -c 3 "${f}" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ]]; then
    printf '%s:1: non-ASCII .ps1 without a UTF-8 BOM\n' "${f}"
  fi
  return 0
}

list_files() {
  if [[ -n "${1:-}" ]]; then
    find "$1" -name .git -prune -o -type f -print
  else
    (cd "${ROOT}" && git ls-files --cached --others --exclude-standard) |
      while IFS= read -r f; do
        [[ -f "${ROOT}/${f}" ]] && printf '%s\n' "${ROOT}/${f}"
      done
  fi
}

scan() {
  local f
  list_files "${1:-}" | while IFS= read -r f; do scan_file "${f}"; done
}

# Each bad value is built at runtime so this file passes its own scan.
self_test() {
  local fails=0 out
  SELF_DIR="$(mktemp -d)"
  trap 'rm -rf "${SELF_DIR}"' EXIT
  local dir="${SELF_DIR}"
  printf 'ssh host %s\n' "10"".1.2.3" >"${dir}/ip10"
  printf 'ping %s\n' "192"".168.1.5" >"${dir}/ip192"
  printf 'ping %s\n' "172"".20.0.1" >"${dir}/ip172"
  printf 'allow %s\n' "10"".1.2.3/24" >"${dir}/hostmask"
  printf 'Match Address %s,%s\n' "10"".0.0.0/8" "192"".168.0.0/16" >"${dir}/cidr"
  printf 'mail %s\n' "someone""@corp.test" >"${dir}/email"
  printf 'cd %s\n' 'C:''\Users\someone\x' >"${dir}/winpath"
  printf 'cd %s\n' "/ho""me/someone/x" >"${dir}/homepath"
  printf 'cd %s\n' "/Us""ers/someone/x" >"${dir}/macpath"
  printf '# caf\xc3\xa9\n' >"${dir}/nobom.ps1"
  printf '\xef\xbb\xbf# caf\xc3\xa9\n' >"${dir}/bom.ps1"
  printf 'ok %s %s %s\n' '/home/<name>' 'me@example.com' '8.8.8.8' >"${dir}/clean"
  out="$(scan "${dir}")"
  for want in ip10 ip192 ip172 hostmask email winpath homepath macpath nobom.ps1; do
    if [[ "${out}" == *"${dir}/${want}:"* ]]; then
      printf 'PASS guard-%s\n' "${want}"
    else
      printf 'FAIL guard-%s not reported\n' "${want}"
      fails=$((fails + 1))
    fi
  done
  for want in clean cidr bom.ps1; do
    if [[ "${out}" == *"${dir}/${want}:"* ]]; then
      printf 'FAIL guard-%s wrongly reported\n' "${want}"
      fails=$((fails + 1))
    else
      printf 'PASS guard-%s\n' "${want}"
    fi
  done
  return "${fails}"
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    return
  fi
  local out
  out="$(scan "${1:-}")"
  if [[ -n "${out}" ]]; then
    printf '%s\n' "${out}"
    printf 'FAIL repo guard: %s finding(s)\n' "$(printf '%s\n' "${out}" | wc -l | tr -d ' ')"
    return 1
  fi
  printf 'PASS repo guard\n'
}

main "$@"
