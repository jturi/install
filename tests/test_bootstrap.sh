#!/usr/bin/env bash
# bootstrap.sh: download from a local tarball, run setup.sh, back up on rerun,
# fail cleanly on a bad URL. Runs under sh, bash and zsh when present.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fails=0

check() { # name, then a command that must succeed
  local name="$1"
  shift
  if "$@"; then printf 'PASS %s\n' "${name}"; else
    printf 'FAIL %s\n' "${name}"
    fails=$((fails + 1))
  fi
}

# Tarball of the working tree with a GitHub-style top directory.
mkdir -p "${TMP}/src/jturi-install-abc"
(cd "${ROOT}" && git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
  [[ -f "${f}" ]] && printf '%s\n' "${f}"
done | tar -cf - -T -) | tar -xf - -C "${TMP}/src/jturi-install-abc"
tar -czf "${TMP}/repo.tgz" -C "${TMP}/src" jturi-install-abc

for sh in sh bash zsh; do
  command -v "${sh}" >/dev/null 2>&1 || continue
  home="${TMP}/home-${sh}"
  mkdir -p "${home}"
  run() {
    HOME="${home}" BOOTSTRAP_URL="file://${TMP}/repo.tgz" GITHUB_TOKEN=x \
      SETUP_ARGS="--dry-run --yes --no-terminal" "${sh}" "${ROOT}/bootstrap.sh" </dev/null >"${TMP}/out" 2>&1
  }
  check "bootstrap-${sh}-runs" run
  check "bootstrap-${sh}-setup" grep -q 'Detected distro family' "${TMP}/out"
  check "bootstrap-${sh}-extract" test -f "${home}/install/setup.sh"
  run
  run
  check "bootstrap-${sh}-backups" test "$(find "${home}" -maxdepth 1 -name 'install.bak.*' | wc -l)" -eq 2
done

bad() {
  HOME="${TMP}/bad" BOOTSTRAP_URL="file://${TMP}/missing.tgz" GITHUB_TOKEN=x \
    sh "${ROOT}/bootstrap.sh" </dev/null >/dev/null 2>&1
}
if bad; then printf 'FAIL bootstrap-bad-url-fails\n'; fails=$((fails + 1)); else printf 'PASS bootstrap-bad-url-fails\n'; fi
check bootstrap-bad-url-no-dir test ! -e "${TMP}/bad/install"

exit "${fails}"
