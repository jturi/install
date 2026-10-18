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
  UNAME_S=Linux OS_RELEASE_FILE="${WORK}/os-release" detect_family 2>/dev/null
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
check macos "macos" "$(UNAME_S=Darwin OS_RELEASE_FILE=/nonexistent detect_family)"

printf '%s\n' ID=rocky VERSION_ID=9.4 >"${WORK}/os-release"
check major-version "9" "$(OS_RELEASE_FILE="${WORK}/os-release" os_major_version)"

check vim-fedora "vim-enhanced" "$(pkg_name fedora vim)"
check vim-rhel "vim-enhanced" "$(pkg_name rhel vim)"
check vim-arch "vim" "$(pkg_name arch vim)"
check vim-debian "vim" "$(pkg_name debian vim)"
check ssh-arch "openssh" "$(pkg_name arch openssh-client)"
check ssh-debian "openssh-client" "$(pkg_name debian openssh-client)"
check ssh-fedora "openssh-clients" "$(pkg_name fedora openssh-client)"
check sshd-arch "openssh" "$(pkg_name arch openssh-server)"
check sshd-rhel "openssh-server" "$(pkg_name rhel openssh-server)"
check dns-fedora "bind-utils" "$(pkg_name fedora dnsutils)"
check ping-debian "iputils-ping" "$(pkg_name debian iputils)"
check macos-builtin-skipped "" "$(pkg_name macos openssh-client)"
check zsh-arch "zsh" "$(pkg_name arch zsh)"
check macos-zsh-builtin "" "$(pkg_name macos zsh)"
check macos-bash-completion "bash-completion@2" "$(pkg_name macos bash-completion)"
check macos-package-list "tmux vim nano bash-completion@2 htop git wget rsync tree jq" "$(read_packages macos | xargs)"

printf '%s\n' '# comment' '' 'tmux' 'vim  # editor' >"${WORK}/pkgs.txt"
check package-list "tmux vim-enhanced" "$(PACKAGE_LIST="${WORK}/pkgs.txt" read_packages fedora | xargs)"
printf '%s\n' tmux which vim >"${WORK}/pkgs.txt"
check package-list-skip-empty "tmux vim" "$(PACKAGE_LIST="${WORK}/pkgs.txt" read_packages debian | xargs)"

# Config install: fresh, idempotent, backup on change.
home="${WORK}/home"
mkdir -p "${home}/.tmux/plugins/tpm"
TARGET_HOME="${home}" install_configs >/dev/null
check tmux-conf-copied "same" "$(cmp -s "${ROOT}/configs/tmux.conf" "${home}/.tmux.conf" && echo same)"
check zshrc-copied "same" "$(cmp -s "${ROOT}/configs/zshrc" "${home}/.zshrc" && echo same)"
check nanorc-copied "same" "$(cmp -s "${ROOT}/configs/nanorc" "${home}/.nanorc" && echo same)"
TARGET_HOME="${home}" install_configs >/dev/null
check idempotent-no-backup "0" "$(find "${home}" -maxdepth 1 -name '*.bak.*' | wc -l | tr -d ' ')"
echo "old" >"${home}/.nanorc"
TARGET_HOME="${home}" install_configs >/dev/null
check backup-created "1" "$(find "${home}" -maxdepth 1 -name '.nanorc.bak.*' | wc -l | tr -d ' ')"
check backup-content "old" "$(cat "${home}"/.nanorc.bak.*)"
check backup-name-format "yes" "$(find "${home}" -maxdepth 1 -name '.nanorc.bak.*' | grep -Eq '\.nanorc\.bak\.[0-9]{8}_[0-9]{6}$' && echo yes)"
check new-file-installed "same" "$(cmp -s "${ROOT}/configs/nanorc" "${home}/.nanorc" && echo same)"
# A symlinked target is backed up and replaced by a real file; the link target is untouched.
echo "linked" >"${WORK}/link-target"
rm -f "${home}/.zshrc" && ln -s "${WORK}/link-target" "${home}/.zshrc"
TARGET_HOME="${home}" install_configs >/dev/null
check symlink-replaced "file" "$([[ -f "${home}/.zshrc" && ! -L "${home}/.zshrc" ]] && echo file)"
check symlink-target-kept "linked" "$(cat "${WORK}/link-target")"
check symlink-backup "1" "$(find "${home}" -maxdepth 1 -name '.zshrc.bak.*' | wc -l | tr -d ' ')"

# Aliases: fresh home gets ~/.bash_aliases and a loader in ~/.bashrc.
ah="${WORK}/alias_home"
mkdir -p "${ah}"
TARGET_HOME="${ah}" install_aliases >/dev/null
check aliases-created "same" "$(cmp -s "${ROOT}/configs/bash_aliases" "${ah}/.bash_aliases" && echo same)"
check aliases2-not-created "" "$(ls "${ah}/.bash_aliases2" 2>/dev/null)"
check loader-in-bashrc "1" "$(grep -c 'source ~/.bash_aliases2' "${ah}/.bashrc")"
check no-bashrc-backup-when-new "0" "$(find "${ah}" -maxdepth 1 -name '.bashrc.bak.*' | wc -l | tr -d ' ')"
TARGET_HOME="${ah}" install_aliases >/dev/null
check loader-not-duplicated "1" "$(grep -c 'source ~/.bash_aliases2' "${ah}/.bashrc")"
check aliases-rerun-no-backup "0" "$(find "${ah}" -maxdepth 1 -name '*.bak.*' | wc -l | tr -d ' ')"

# Aliases: user's own ~/.bash_aliases is kept; repo file goes to .bash_aliases2;
# an existing ~/.bash_profile gets the loader (backed up), ~/.bashrc is untouched.
ah2="${WORK}/alias_home2"
mkdir -p "${ah2}"
echo "alias mine='echo mine'" >"${ah2}/.bash_aliases"
echo "# profile" >"${ah2}/.bash_profile"
TARGET_HOME="${ah2}" install_aliases >/dev/null
check own-aliases-kept "alias mine='echo mine'" "$(cat "${ah2}/.bash_aliases")"
check aliases2-created "same" "$(cmp -s "${ROOT}/configs/bash_aliases" "${ah2}/.bash_aliases2" && echo same)"
check loader-in-profile "1" "$(grep -c 'source ~/.bash_aliases2' "${ah2}/.bash_profile")"
check profile-backup "# profile" "$(cat "${ah2}"/.bash_profile.bak.*)"
check bashrc-untouched "" "$(ls "${ah2}/.bashrc" 2>/dev/null)"
check loader-works "mine" "$(HOME="${ah2}" bash -c 'shopt -s expand_aliases; source ~/.bash_profile; alias mine >/dev/null && echo mine')"
check zshrc-loads-aliases "1" "$(grep -c 'source ~/.bash_aliases2' "${ROOT}/configs/zshrc")"

# macOS: nanorc points at the Homebrew prefix.
home_mac="${WORK}/home_mac"
mkdir -p "${home_mac}/.tmux/plugins/tpm"
TARGET_HOME="${home_mac}" install_configs macos >/dev/null
check macos-nanorc "include \"$(brew_prefix)/share/nano/*.nanorc\"" "$(grep '^include' "${home_mac}/.nanorc")"
TARGET_HOME="${home_mac}" install_configs macos >/dev/null
check macos-nanorc-idempotent "0" "$(find "${home_mac}" -maxdepth 1 -name '*.bak.*' | wc -l | tr -d ' ')"

# SSH key detection.
check no-ssh-key "" "$(TARGET_HOME="${home}" find_ssh_key)"
mkdir -p "${home}/.ssh"
touch "${home}/.ssh/id_github.pub"
check pub-without-private "" "$(TARGET_HOME="${home}" find_ssh_key)"
touch "${home}/.ssh/id_github"
check custom-key-name "${home}/.ssh/id_github" "$(TARGET_HOME="${home}" find_ssh_key)"
check skip-when-key-exists "found" "$(TARGET_HOME="${home}" SSH_KEY_MODE=create setup_ssh_key | grep -o found)"

if command -v ssh-keygen >/dev/null 2>&1; then
  home2="${WORK}/home2"
  mkdir -p "${home2}"
  TARGET_HOME="${home2}" SSH_KEY_MODE=create setup_ssh_key </dev/null >/dev/null
  check key-created "yes" "$([[ -f "${home2}/.ssh/id_ed25519" && -f "${home2}/.ssh/id_ed25519.pub" ]] && echo yes)"
  check ssh-dir-mode "700" "$(stat -c %a "${home2}/.ssh" 2>/dev/null || stat -f %Lp "${home2}/.ssh")"
  check ask-noninteractive-skips "" "$(TARGET_HOME="${WORK}/home3" SSH_KEY_MODE=ask setup_ssh_key </dev/null &>/dev/null; ls "${WORK}/home3/.ssh" 2>/dev/null)"
fi

# zsh login shell: ask mode without a terminal never changes anything.
check zsh-ask-noninteractive "" "$(ZSH_DEFAULT_MODE=ask setup_zsh_default </dev/null 2>/dev/null | grep -i 'setting login shell')"
check zsh-skip "" "$(ZSH_DEFAULT_MODE=skip setup_zsh_default 2>&1)"

if ((FAILS)); then
  printf '%d test(s) failed\n' "${FAILS}"
  exit 1
fi
echo "all tests passed"
