#!/usr/bin/env bash
# Unit tests for setup.sh: distro detection, package mapping, config install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../setup.sh
source "${ROOT}/setup.sh"
set +e

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILS=0

check() {
  local name="$1" want="$2" got="$3"
  if [[ "${got}" == "${want}" ]]; then
    printf 'PASS %s\n' "${name}"
  else
    printf 'FAIL %s: want [%s] got [%s]\n' "${name}" "${want}" "${got}"
    FAILS=$((FAILS + 1))
  fi
}

family_of() {
  printf '%s\n' "$@" >"${WORK}/os-release"
  OS_RELEASE_FILE="${WORK}/os-release" detect_family 2>/dev/null
}

check arch "arch" "$(family_of ID=arch)"
check cachyos "arch" "$(family_of ID=cachyos ID_LIKE=arch)"
check manjaro "arch" "$(family_of ID=manjaro ID_LIKE=arch)"
check ubuntu "debian" "$(family_of ID=ubuntu ID_LIKE=debian)"
check debian "debian" "$(family_of ID=debian)"
check mint "debian" "$(family_of ID=linuxmint 'ID_LIKE="ubuntu debian"')"
check fedora "fedora" "$(family_of ID=fedora)"
check nobara "fedora" "$(family_of ID=nobara ID_LIKE=fedora)"
check rhel "rhel" "$(family_of ID=rhel 'ID_LIKE="fedora"')"
check rocky "rhel" "$(family_of ID=rocky 'ID_LIKE="rhel centos fedora"')"
check alma "rhel" "$(family_of ID=almalinux 'ID_LIKE="rhel centos fedora"')"
check centos "rhel" "$(family_of ID=centos 'ID_LIKE="rhel fedora"')"
check unsupported "" "$(family_of ID=gentoo)"

printf '%s\n' ID=rocky VERSION_ID=9.4 >"${WORK}/os-release"
check major-version "9" "$(OS_RELEASE_FILE="${WORK}/os-release" os_major_version)"

check vim-fedora "vim-enhanced" "$(pkg_name fedora vim)"
check vim-rhel "vim-enhanced" "$(pkg_name rhel vim)"
check vim-arch "vim" "$(pkg_name arch vim)"
check vim-debian "vim" "$(pkg_name debian vim)"

printf '%s\n' '# comment' '' 'tmux' 'vim  # editor' >"${WORK}/pkgs.txt"
check package-list "tmux vim-enhanced" "$(PACKAGE_LIST="${WORK}/pkgs.txt" read_packages fedora | xargs)"

# Config install: fresh, idempotent, backup on change.
home="${WORK}/home"
mkdir -p "${home}/.tmux/plugins/tpm"
TARGET_HOME="${home}" install_configs >/dev/null
check tmux-conf-copied "same" "$(cmp -s "${ROOT}/configs/tmux.conf" "${home}/.tmux.conf" && echo same)"
check nanorc-copied "same" "$(cmp -s "${ROOT}/configs/nanorc" "${home}/.nanorc" && echo same)"
TARGET_HOME="${home}" install_configs >/dev/null
check idempotent-no-backup "0" "$(find "${home}" -maxdepth 1 -name '*.bak.*' | wc -l)"
echo "old" >"${home}/.nanorc"
TARGET_HOME="${home}" install_configs >/dev/null
check backup-created "1" "$(find "${home}" -maxdepth 1 -name '.nanorc.bak.*' | wc -l)"
check backup-content "old" "$(cat "${home}"/.nanorc.bak.*)"

if ((FAILS)); then
  printf '%d test(s) failed\n' "${FAILS}"
  exit 1
fi
echo "all tests passed"
