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
  check "bootstrap-${sh}-dryrun-no-shell" sh -c "! grep -q 'starting a new' '${TMP}/out'"
  run
  run
  check "bootstrap-${sh}-backups" test "$(find "${home}" -maxdepth 1 -name 'install.bak.*' | wc -l)" -eq 2
done

# After a real run with a terminal, bootstrap starts a fresh interactive shell
# (so ~/.bashrc and the new aliases load). Stub setup.sh and $SHELL; `script`
# gives the run a /dev/tty.
if command -v script >/dev/null 2>&1; then
  mkdir -p "${TMP}/stub/jturi-install-abc"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP}/stub/jturi-install-abc/setup.sh"
  tar -czf "${TMP}/stub.tgz" -C "${TMP}/stub" jturi-install-abc
  printf '#!/bin/sh\necho "$@" >"%s/shell-args"\n' "${TMP}" >"${TMP}/fakeshell"
  chmod +x "${TMP}/fakeshell"
  # shellcheck disable=SC2329 # called through check
  shell_run() {
    HOME="${TMP}/home-shell" BOOTSTRAP_URL="file://${TMP}/stub.tgz" GITHUB_TOKEN=x \
      script -qec "SHELL='${TMP}/fakeshell' sh '${ROOT}/bootstrap.sh'" /dev/null </dev/null >"${TMP}/shell-out" 2>&1
  }
  check bootstrap-new-shell-runs shell_run
  check bootstrap-new-shell-interactive grep -qx -- '-i' "${TMP}/shell-args"
  rm -f "${TMP}/shell-args"
  # shellcheck disable=SC2329 # called through check
  no_shell_run() {
    HOME="${TMP}/home-noshell" BOOTSTRAP_URL="file://${TMP}/stub.tgz" GITHUB_TOKEN=x BOOTSTRAP_NO_SHELL=1 \
      script -qec "SHELL='${TMP}/fakeshell' sh '${ROOT}/bootstrap.sh'" /dev/null </dev/null >/dev/null 2>&1
  }
  check bootstrap-no-shell-opt-out no_shell_run
  check bootstrap-no-shell-opt-out-none test ! -e "${TMP}/shell-args"
fi

bad() {
  HOME="${TMP}/bad" BOOTSTRAP_URL="file://${TMP}/missing.tgz" GITHUB_TOKEN=x \
    sh "${ROOT}/bootstrap.sh" </dev/null >/dev/null 2>&1
}
if bad; then printf 'FAIL bootstrap-bad-url-fails\n'; fails=$((fails + 1)); else printf 'PASS bootstrap-bad-url-fails\n'; fi
check bootstrap-bad-url-no-dir test ! -e "${TMP}/bad/install"

exit "${fails}"
