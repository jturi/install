#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329 # tests change state inside subshells on purpose
# Unit tests for setup.sh: distro detection, package mapping, config install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../setup.sh
source "${ROOT}/setup.sh"
set +e

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILS=0
# Tests may run under WSL: never touch the real Windows home or Scoop.
echo "6.0.0-generic" >"${WORK}/osrelease-linux"
KERNEL_RELEASE_FILE="${WORK}/osrelease-linux"
# The developer may run the tests over SSH or inside tmux: the SSH lock-out
# check must not see that session.
unset SSH_CONNECTION TMUX

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
check macos-package-list "tmux vim nano bash bash-completion@2 fzf htop git wget rsync tree jq" "$(load_catalog macos; config_load "${WORK}/none"; selected_packages macos | xargs)"

# Catalog parsing and platform filtering.
FIXTURE="${ROOT}/tests/fixtures/catalog.txt"
keys_for() { (catalog_load "${FIXTURE}" "$1" "$2"; local i; for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do catalog_key "${i}"; done | xargs); }
check catalog-linux "shell.zsh shell.less configs.tmux" "$(keys_for linux 0)"
check catalog-wsl "shell.zsh shell.less configs.tmux terminals.wezterm-wsl" "$(keys_for linux 1)"
check catalog-macos "shell.zsh configs.tmux terminals.ghostty" "$(keys_for macos 0)"
check catalog-groups "shell configs terminals" "$(catalog_load "${FIXTURE}" linux 1; catalog_groups | xargs)"
check catalog-fields "tmux config|on|step:configs" "$(catalog_load "${FIXTURE}" linux 0; printf '%s|%s|%s' "${CAT_LABEL[2]}" "${CAT_DEFAULT[2]}" "${CAT_ACTION[2]}")"
check catalog-real-scoop-action "scoop:main/cmder" "$(catalog_load "${ROOT}/catalog.txt" windows 0; for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do [[ "${CAT_ITEM[i]}" == cmder ]] && echo "${CAT_ACTION[i]}"; done)"
check catalog-crlf "shell.zsh" "$(sed 's/$/\r/' "${FIXTURE}" >"${WORK}/crlf.txt"; catalog_load "${WORK}/crlf.txt" macos 0; catalog_key 0)"
# Malformed catalogs stop with the line number.
bad_catalog() { printf '%s\n' '# comment' "$1" >"${WORK}/bad.txt"; (catalog_load "${WORK}/bad.txt" linux 0) 2>&1 | grep -o 'catalog.*line 2' | sed 's/.*line/line/'; }
check catalog-too-few "line 2" "$(bad_catalog 'a|b|c|linux|on')"
check catalog-too-many "line 2" "$(bad_catalog 'a|b|c|linux|on|pkg|x')"
check catalog-bad-default "line 2" "$(bad_catalog 'a|b|c|linux|maybe|pkg')"
check catalog-bad-platform "line 2" "$(bad_catalog 'a|b|c|plan9|on|pkg')"
check catalog-bad-action "line 2" "$(bad_catalog 'a|b|c|linux|on|nope')"
check catalog-missing-file "1" "$( (catalog_load "${WORK}/none.txt" linux 0) >/dev/null 2>&1; echo $?)"
# A pkg item with no package on this distro is hidden; steps are not.
printf '%s\n' 'shell|tmux|tmux|macos|on|pkg' 'shell|less|less|macos|on|pkg' 'configs|tmux|tmux|macos|on|step:configs' >"${WORK}/mapped.txt"
check catalog-hides-unmapped "shell.tmux configs.tmux" "$(catalog_load "${WORK}/mapped.txt" macos 0; catalog_hide_unmapped macos; for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do catalog_key "${i}"; done | xargs)"

# --ssh-server on Arch: openssh is listed once.
check arch-sshd-dedup "1" "$(pkg_installed() { return 1; }; load_catalog arch; config_load "${WORK}/none"; set_selection extras.ssh-server 1; DRY_RUN=1 install_packages arch 2>/dev/null | grep -m1 'Installing (arch)' | tr ' ' '\n' | grep -c '^openssh$')"
# An empty selection plus the SSH server must not trip set -u on bash 3.2.
check empty-selection-ssh-server "openssh" "$(pkg_installed() { return 1; }; load_catalog arch; config_load "${WORK}/none"; for ((i = 0; i < ${#CAT_SEL[@]}; i++)); do CAT_SEL[i]=0; done; set_selection extras.ssh-server 1; DRY_RUN=1 install_packages arch 2>/dev/null | grep -o 'openssh$' | head -n 1)"
check unticked-package-not-installed "0" "$(load_catalog debian; config_load "${WORK}/none"; set_selection shell.vim 0; selected_packages debian | grep -c '^vim$')"
# Config steps below use the default selection.
load_catalog debian
config_load "${WORK}/none"

# Config install: fresh, idempotent, backup on change.
# (Terminal configs are opt-in via setup_terminals, not install_configs.)
home="${WORK}/home"
mkdir -p "${home}/.tmux/plugins/tpm"
TARGET_HOME="${home}" install_configs >/dev/null
check tmux-conf-copied "same" "$(cmp -s "${ROOT}/configs/tmux.conf" "${home}/.tmux.conf" && echo same)"
check zshrc-copied "same" "$(cmp -s "${ROOT}/configs/zshrc" "${home}/.zshrc" && echo same)"
check nanorc-copied "same" "$(cmp -s "${ROOT}/configs/nanorc" "${home}/.nanorc" && echo same)"
check kitty-not-installed "no" "$([[ -e "${home}/.config/kitty/kitty.conf" ]] && echo yes || echo no)"
check ghostty-not-installed "no" "$([[ -e "${home}/.config/ghostty/config" ]] && echo yes || echo no)"
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

# private_dir: created 0700, tightened when looser, silent when already private.
pd="${WORK}/pd"
check private-dir-new "700" "$(private_dir "${pd}/new" >/dev/null; stat -c %a "${pd}/new" 2>/dev/null || stat -f %Lp "${pd}/new")"
mkdir -p "${pd}/open" && chmod 755 "${pd}/open"
check private-dir-tightened "700" "$(private_dir "${pd}/open" >/dev/null; stat -c %a "${pd}/open" 2>/dev/null || stat -f %Lp "${pd}/open")"
check private-dir-quiet "" "$(private_dir "${pd}/open")"
check private-dir-dry-run "no" "$(DRY_RUN=1 private_dir "${pd}/dry" >/dev/null; [[ -e "${pd}/dry" ]] && echo yes || echo no)"
# The tmux config comes with a private save directory: resurrect keeps what
# was on screen there.
th="${WORK}/tmux_home"
mkdir -p "${th}"
check tmux-resurrect-private "700" "$(TARGET_HOME="${th}"; load_catalog arch; config_load "${WORK}/none"; install_configs arch >/dev/null 2>&1; stat -c %a "${th}/.local/share/tmux/resurrect" 2>/dev/null || stat -f %Lp "${th}/.local/share/tmux/resurrect")"

# Aliases: fresh home gets ~/.bash_aliases, ~/.bash_extras, and a loader in ~/.bashrc.
ah="${WORK}/alias_home"
mkdir -p "${ah}"
TARGET_HOME="${ah}" install_aliases >/dev/null
check aliases-created "same" "$(cmp -s "${ROOT}/configs/bash_aliases" "${ah}/.bash_aliases" && echo same)"
check extras-created "same" "$(cmp -s "${ROOT}/configs/bash_extras" "${ah}/.bash_extras" && echo same)"
check origin-created "same" "$(cmp -s "${ROOT}/configs/bash_show_origin" "${ah}/.bash_show_origin" && echo same)"
check aliases2-not-created "" "$(ls "${ah}/.bash_aliases2" 2>/dev/null)"
check loader-in-bashrc "1" "$(grep -c 'source ~/.bash_extras' "${ah}/.bashrc")"
check loader-origin-in-bashrc "1" "$(grep -c 'source ~/.bash_show_origin' "${ah}/.bashrc")"
check no-bashrc-backup-when-new "0" "$(find "${ah}" -maxdepth 1 -name '.bashrc.bak.*' | wc -l | tr -d ' ')"
TARGET_HOME="${ah}" install_aliases >/dev/null
check loader-not-duplicated "1" "$(grep -c 'source ~/.bash_extras' "${ah}/.bashrc")"
check origin-loader-not-duplicated "1" "$(grep -c 'source ~/.bash_show_origin' "${ah}/.bashrc")"
check aliases-rerun-no-backup "0" "$(find "${ah}" -maxdepth 1 -name '*.bak.*' | wc -l | tr -d ' ')"
# Loader sources every file in order: extras before origin (origin hooks the prompt, so it loads last).
check loader-order "aliases aliases2 extras show_origin" "$(grep -o 'source ~/\.bash_[a-z0-9_]*' "${ah}/.bashrc" | sed 's/.*\.bash_//' | tr '\n' ' ' | sed 's/ $//')"

# Aliases: user's own ~/.bash_aliases is kept; repo file goes to .bash_aliases2;
# on macOS (login shells) an existing ~/.bash_profile gets the loader (backed
# up), ~/.bashrc is untouched.
ah2="${WORK}/alias_home2"
mkdir -p "${ah2}"
echo "alias mine='echo mine'" >"${ah2}/.bash_aliases"
echo "# profile" >"${ah2}/.bash_profile"
TARGET_HOME="${ah2}" install_aliases macos >/dev/null
check own-aliases-kept "alias mine='echo mine'" "$(cat "${ah2}/.bash_aliases")"
check aliases2-created "same" "$(cmp -s "${ROOT}/configs/bash_aliases" "${ah2}/.bash_aliases2" && echo same)"
check loader-in-profile "1" "$(grep -c 'source ~/.bash_aliases2' "${ah2}/.bash_profile")"
check profile-backup "# profile" "$(cat "${ah2}"/.bash_profile.bak.*)"
check bashrc-untouched "" "$(ls "${ah2}/.bashrc" 2>/dev/null)"
check loader-works "mine" "$(HOME="${ah2}" bash -c 'shopt -s expand_aliases; source ~/.bash_profile; alias mine >/dev/null && echo mine')"
check extras2-created "same" "$(cmp -s "${ROOT}/configs/bash_extras" "${ah2}/.bash_extras" && echo same)"
check zshrc-loads-aliases "1" "$(grep -c 'source ~/.bash_aliases2' "${ROOT}/configs/zshrc")"
check zshrc-loads-extras "1" "$(grep -c 'source ~/.bash_extras' "${ROOT}/configs/zshrc")"
check zshrc-loads-origin "1" "$(grep -c 'source ~/.bash_show_origin' "${ROOT}/configs/zshrc")"
check profile-loads-origin "1" "$(grep -c 'source ~/.bash_show_origin' "${ah2}/.bash_profile")"

# Linux with the Arch/Fedora skeleton (.bash_profile sources .bashrc): the
# loader goes to ~/.bashrc, which non-login terminals read; .bash_profile is
# left alone.
ah4="${WORK}/alias_home4"
mkdir -p "${ah4}"
printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' >"${ah4}/.bash_profile"
printf '# rc\n' >"${ah4}/.bashrc"
cp "${ah4}/.bash_profile" "${WORK}/profile4.orig"
TARGET_HOME="${ah4}" install_aliases arch >/dev/null
check linux-loader-in-bashrc "1" "$(grep -c 'source ~/.bash_extras' "${ah4}/.bashrc")"
check linux-profile-untouched "same" "$(cmp -s "${WORK}/profile4.orig" "${ah4}/.bash_profile" && echo same)"
check linux-nonlogin-loads "function" "$(HOME="${ah4}" bash -i -c 'type -t mkcd' </dev/null 2>/dev/null)"
check linux-check-agrees "OK" "$(TARGET_HOME="${ah4}"; load_catalog arch; config_load "${WORK}/none"; for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do [[ "$(catalog_key "${i}")" != configs.aliases ]] || check_item arch "${i}"; done)"
# Upgrade on Linux: an old loader in .bash_profile stays (never deleted),
# .bashrc gets one, and a note says the old one can go.
ah5="${WORK}/alias_home5"
mkdir -p "${ah5}"
printf 'if [ -f ~/.bash_extras ]; then\n    source ~/.bash_extras\nfi\n' >"${ah5}/.bash_profile"
out="$(TARGET_HOME="${ah5}" install_aliases fedora 2>&1)"
check linux-upgrade-bashrc "1" "$(grep -c 'source ~/.bash_extras' "${ah5}/.bashrc")"
check linux-upgrade-profile-kept "1" "$(grep -c 'source ~/.bash_extras' "${ah5}/.bash_profile")"
check linux-upgrade-note "1" "$(grep -c 'can be removed' <<<"${out}")"
out="$(TARGET_HOME="${ah5}" install_aliases fedora 2>&1)"
check linux-upgrade-note-once "0" "$(grep -c 'can be removed' <<<"${out}")"

# Upgrade: an old loader (aliases + aliases2, no extras) gains extras idempotently.
ah3="${WORK}/alias_home3"
mkdir -p "${ah3}"
cp "${ROOT}/configs/bash_aliases" "${ah3}/.bash_aliases"
cp "${ROOT}/configs/bash_extras" "${ah3}/.bash_extras"
printf '\n# Load custom aliases in Zsh\nif [ -f ~/.bash_aliases ]; then\n    source ~/.bash_aliases\nfi\n\nif [ -f ~/.bash_aliases2 ]; then\n    source ~/.bash_aliases2\nfi\n' >"${ah3}/.bashrc"
TARGET_HOME="${ah3}" install_aliases >/dev/null
check upgrade-adds-extras-loader "1" "$(grep -c 'source ~/.bash_extras' "${ah3}/.bashrc")"
check upgrade-keeps-alias-count "1" "$(grep -c 'source ~/.bash_aliases2' "${ah3}/.bashrc")"
check upgrade-backup "1" "$(find "${ah3}" -maxdepth 1 -name '.bashrc.bak.*' | wc -l | tr -d ' ')"
TARGET_HOME="${ah3}" install_aliases >/dev/null
check upgrade-idempotent "1" "$(grep -c 'source ~/.bash_extras' "${ah3}/.bashrc")"
check upgrade-adds-origin-loader "1" "$(grep -c 'source ~/.bash_show_origin' "${ah3}/.bashrc")"
check upgrade-origin-file "same" "$(cmp -s "${ROOT}/configs/bash_show_origin" "${ah3}/.bash_show_origin" && echo same)"
TARGET_HOME="${ah3}" install_aliases >/dev/null
check upgrade-origin-idempotent "1" "$(grep -c 'source ~/.bash_show_origin' "${ah3}/.bashrc")"
check upgrade-origin-single-backup "1" "$(find "${ah3}" -maxdepth 1 -name '.bashrc.bak.*' | wc -l | tr -d ' ')"

# origin script: parses in bash (and zsh when present); toggle works without a prompt.
check origin-parse "ok" "$(bash -n "${ROOT}/configs/bash_show_origin" && { ! command -v zsh >/dev/null || zsh -n "${ROOT}/configs/bash_show_origin"; } && echo ok)"
check origin-toggle "show_origin: off" "$(bash -c 'source '"${ROOT}"'/configs/bash_show_origin; show_origin off')"
check origin-bad-arg "2" "$(bash -c 'source '"${ROOT}"'/configs/bash_show_origin; show_origin nope 2>/dev/null; echo $?')"

# Both alias files parse and key aliases resolve; mkcd/lt helpers work.
check extras-parse "ok" "$(bash -n "${ROOT}/configs/bash_extras" && bash -n "${ROOT}/configs/bash_aliases" && echo ok)"
check extras-aliases-resolve "27" "$(bash -c 'shopt -s expand_aliases; source '"${ROOT}"'/configs/bash_aliases; source '"${ROOT}"'/configs/bash_extras; for a in m gs gst gl gbr gch gpush gpull gchm dow sudo2 psmem pscpu ports dfh myip ping5 md gundo groot gstash gpop; do alias "$a" >/dev/null 2>&1 || exit 1; done; for f in again psg killport duh down serve extract hgrep alg ltt lt mkcd tmuxhelp; do type -t "$f" | grep -q function || exit 1; done; echo 27')"
# alg colors only on a terminal: piped output must have no escape codes.
check extras-alg-plain-when-piped "0" "$(bash -c 'source '"${ROOT}"'/configs/bash_extras; alg gl' | grep -c $'\033' || true)"
check extras-mkcd "yes" "$(bash -c 'source '"${ROOT}"'/configs/bash_extras; d=$(mktemp -d); mkcd "$d/sub" >/dev/null && [[ "$PWD" == "$d/sub" ]] && echo yes; rm -rf "$d"')"
check extras-lt "0" "$(bash -c 'source '"${ROOT}"'/configs/bash_extras; d=$(mktemp -d); cd "$d"; touch a b; lt 2 >/dev/null | grep -c "^total"; rm -rf "$d"')"

# ltt: works where the file list exceeds the argument limit (the old version
# passed every file to one ls and printed nothing).
lt_dir="${WORK}/ltt"
mkdir -p "${lt_dir}"
(cd "${lt_dir}" && seq 1 40000 | sed 's/^/file-with-a-long-enough-name-to-pass-the-argument-limit-/' | xargs touch -t 202001010000)
touch "${lt_dir}/newest"
check ltt-many-files "newest" "$(cd "${lt_dir}" && bash -c 'source "$0"; ltt 1' "${ROOT}/configs/bash_extras" | awk '{print $NF}' | sed 's#^\./##')"
if command -v zsh >/dev/null 2>&1; then
  check ltt-zsh "newest" "$(cd "${lt_dir}" && zsh -c 'source "$0"; ltt 1' "${ROOT}/configs/bash_extras" | awk '{print $NF}' | sed 's#^\./##')"
fi
rm -rf "${lt_dir}"
check ltt-empty "" "$(mkdir -p "${WORK}/ltt-empty" && cd "${WORK}/ltt-empty" && bash -c 'source "$0"; ltt 3' "${ROOT}/configs/bash_extras")"

# again: the previous line (fc prints it with leading blanks) runs as root,
# split into words the way the shell split it. fc and sudo are stubbed.
again_case() {
  "$1" -c 'source "$0"; fc() { printf "\t echo \"a b\" c\n"; }; sudo() { printf "%s|" "$#" "$@"; }; again 2>/dev/null' \
    "${ROOT}/configs/bash_extras"
}
check again-bash "3|echo|a b|c|" "$(again_case bash)"
if command -v zsh >/dev/null 2>&1; then check again-zsh "3|echo|a b|c|" "$(again_case zsh)"; fi
check again-empty-rc "1" "$(bash -c 'source "$0"; fc() { :; }; sudo() { echo ran; }; again' "${ROOT}/configs/bash_extras" >/dev/null 2>&1; echo $?)"

# killport: only processes that LISTEN on the port; PIDs split in bash and zsh.
# lsof is a stub function; kill is a stub on PATH because xargs runs it.
mkdir -p "${WORK}/kbin"
printf '#!/bin/sh\necho "kill $*"\n' >"${WORK}/kbin/kill"
chmod +x "${WORK}/kbin/kill"
killport_case() {
  KP_ARGS="${WORK}/kp.args" PATH="${WORK}/kbin:${PATH}" "$1" -c \
    'source "$0"; lsof() { echo "$*" >"${KP_ARGS}"; [ -z "${LSOF_OUT}" ] || printf "%s\n" 11 22; }; killport "$1"' \
    "${ROOT}/configs/bash_extras" "$2"
}
check killport-bash "kill 11 22" "$(LSOF_OUT=1 killport_case bash 8080 2>&1)"
check killport-listen-only "1" "$(grep -c -- '-sTCP:LISTEN' "${WORK}/kp.args")"
check killport-port-arg "1" "$(grep -c -- '-iTCP:8080' "${WORK}/kp.args")"
if command -v zsh >/dev/null 2>&1; then check killport-zsh "kill 11 22" "$(LSOF_OUT=1 killport_case zsh 8080 2>&1)"; fi
check killport-none-rc "1" "$(LSOF_OUT='' killport_case bash 8080 >/dev/null 2>&1; echo $?)"
check killport-not-number-rc "1" "$(LSOF_OUT=1 killport_case bash abc >/dev/null 2>&1; echo $?)"

# duh: smallest first by real size (sort -n on "2.0M" vs "600K" got it wrong).
dd_dir="${WORK}/duh"
mkdir -p "${dd_dir}"
head -c 2097152 /dev/zero >"${dd_dir}/big"
head -c 614400 /dev/zero >"${dd_dir}/small"
check duh-order "small big" "$(cd "${dd_dir}" && bash -c 'source "$0"; duh' "${ROOT}/configs/bash_extras" | awk -F'\t' '{print $2}' | xargs)"
check duh-units "1" "$(cd "${dd_dir}" && bash -c 'source "$0"; duh' "${ROOT}/configs/bash_extras" | grep -c 'M[[:space:]]big$')"

# down: the wget fallback keeps the requested file name.
mkdir -p "${WORK}/wbin"
printf '#!/bin/sh\necho "wget $*"\n' >"${WORK}/wbin/wget"
chmod +x "${WORK}/wbin/wget"
check down-wget-name "1" "$(bash -c 'PATH="$1"; source "$0"; down http://x/y out.bin' "${ROOT}/configs/bash_extras" "${WORK}/wbin" | grep -c -- '-O out.bin')"

# Helper scripts: tmuxhelp.sh installs executable into ~/.local/bin with a
# wrapper in bash_extras; idempotent. The PATH line for ~/.local/bin
# ships inside the alias loader block (and the repo .zshrc).
bin_home="${WORK}/bin_home"
mkdir -p "${bin_home}/.tmux/plugins/tpm" "${bin_home}/.local/bin"
printf 'old\n' >"${bin_home}/.local/bin/other.sh"
chmod +x "${bin_home}/.local/bin/other.sh"
printf '# rc\n' >"${bin_home}/.bashrc"
# shellcheck disable=SC2016 # literal PATH line, checked literally below
path_line='export PATH="$HOME/.local/bin:$PATH"'
TARGET_HOME="${bin_home}" install_aliases >/dev/null
TARGET_HOME="${bin_home}" install_bin_scripts >/dev/null
check bin-tmuxhelp-installed "same" "$(cmp -s "${ROOT}/configs/bin/tmuxhelp.sh" "${bin_home}/.local/bin/tmuxhelp.sh" && echo same)"
check bin-tmuxhelp-exec "yes" "$([[ -x "${bin_home}/.local/bin/tmuxhelp.sh" ]] && echo yes)"
check bin-other-kept "old" "$(cat "${bin_home}/.local/bin/other.sh")"
check bin-bashrc-path "1" "$(grep -cF "${path_line}" "${bin_home}/.bashrc")"
TARGET_HOME="${bin_home}" install_aliases >/dev/null
TARGET_HOME="${bin_home}" install_bin_scripts >/dev/null
check bin-idempotent "1" "$(grep -cF "${path_line}" "${bin_home}/.bashrc")"
check bin-rerun-no-backup "0" "$(find "${bin_home}/.local/bin" -maxdepth 1 -name 'tmuxhelp.sh.bak.*' | wc -l | tr -d ' ')"
check bin-wrapper "1" "$(grep -c 'tmuxhelp()' "${ROOT}/configs/bash_extras")"
# tmuxhelp works against a real ~/.tmux.conf (quick-ref markers).
# (wrapper prefers tmuxhelp.sh on PATH, falls back to ~/.local/bin;
# grep -m1 avoids SIGPIPE/head truncation tripping set -o pipefail.)
check bin-tmuxhelp-runs "TMUX CONFIGURATION START" "$(HOME="${bin_home}" PATH="${bin_home}/.local/bin:${PATH}" bash -c 'cp '"${ROOT}"'/configs/tmux.conf "$HOME/.tmux.conf"; source '"${ROOT}"'/configs/bash_extras; tmuxhelp' 2>/dev/null | grep -m1 TMUX)"

# macOS: nanorc points at the Homebrew prefix; terminal configs stay
# opt-in (install_terminal_configs) on both platforms.
home_mac="${WORK}/home_mac"
mkdir -p "${home_mac}/.tmux/plugins/tpm"
TARGET_HOME="${home_mac}" install_configs macos >/dev/null
check macos-nanorc "include \"$(brew_prefix)/share/nano/*.nanorc\"" "$(grep '^include' "${home_mac}/.nanorc")"
TARGET_HOME="${home_mac}" install_configs macos >/dev/null
check macos-nanorc-idempotent "0" "$(find "${home_mac}" -maxdepth 1 -name '*.bak.*' | wc -l | tr -d ' ')"
check macos-kitty-skipped "no" "$([[ -e "${home_mac}/.config/kitty/kitty.conf" ]] && echo yes || echo no)"
check macos-ghostty-skipped "no" "$([[ -e "${home_mac}/Library/Application Support/com.mitchellh.ghostty/config.ghostty" ]] && echo yes || echo no)"
# Opt-in path still copies the right per-platform files.
TARGET_HOME="${home}" install_terminal_configs linux kitty ghostty >/dev/null
check kitty-linux-copied "same" "$(cmp -s "${ROOT}/configs/kitty/linux.conf" "${home}/.config/kitty/kitty.conf" && echo same)"
check ghostty-linux-copied "same" "$(cmp -s "${ROOT}/configs/ghostty/linux.config" "${home}/.config/ghostty/config" && echo same)"
# The macOS Ghostty path must not be created on Linux.
check ghostty-mac-path-absent "no" "$([[ -e "${home}/Library/Application Support/com.mitchellh.ghostty/config.ghostty" ]] && echo yes || echo no)"
TARGET_HOME="${home_mac}" install_terminal_configs macos kitty ghostty >/dev/null
check macos-kitty-copied "same" "$(cmp -s "${ROOT}/configs/kitty/macos.conf" "${home_mac}/.config/kitty/kitty.conf" && echo same)"
check macos-ghostty-copied "same" "$(cmp -s "${ROOT}/configs/ghostty/macos.config" "${home_mac}/Library/Application Support/com.mitchellh.ghostty/config.ghostty" && echo same)"

# Only ticked terminals are installed.
t_home="${WORK}/t_home"
mkdir -p "${t_home}"
TARGET_HOME="${t_home}" install_terminal_configs linux kitty >/dev/null
check terminal-only-kitty-config "yes/no" "$([[ -e "${t_home}/.config/kitty/kitty.conf" ]] && echo yes || echo no)/$([[ -e "${t_home}/.config/ghostty/config" ]] && echo yes || echo no)"
check terminal-only-kitty-package "kitty" "$(as_root() { run "$@"; }; DRY_RUN=1 install_terminal_packages fedora kitty 2>&1 | grep -o 'install -y.*' | sed 's/install -y //')"
check terminal-only-ghostty-brew "ghostty" "$(ensure_brew() { :; }; DRY_RUN=1 install_terminal_packages macos ghostty 2>&1 | grep -o 'cask.*' | sed 's/cask //')"

# WSL: WezTerm through Scoop on the Windows side, config in the Windows home.
echo "6.18.33.2-microsoft-standard-WSL2" >"${WORK}/osrelease-wsl"
check wsl-detected "yes" "$(KERNEL_RELEASE_FILE="${WORK}/osrelease-wsl" is_wsl && echo yes)"
check wsl-not-on-linux "no" "$(is_wsl && echo yes || echo no)"
check wsl-missing-file "no" "$(KERNEL_RELEASE_FILE=/nonexistent is_wsl && echo yes || echo no)"
stub="${WORK}/stub"
win_home="${WORK}/win_home"
mkdir -p "${stub}" "${win_home}"
cat >"${stub}/scoop" <<STUB
#!/bin/sh
echo "\$*" >>"${WORK}/scoop.log"
[ "\$1" != bucket ]
STUB
chmod +x "${stub}/scoop"
PATH="${stub}:${PATH}" WINDOWS_HOME="${win_home}" install_windows_terminal >/dev/null 2>&1
check wezterm-scoop-calls "bucket add extras|install wezterm" "$(paste -sd '|' "${WORK}/scoop.log")"
check wezterm-config-copied "same" "$(cmp -s "${ROOT}/configs/wezterm/windows.lua" "${win_home}/.wezterm.lua" && echo same)"
# No Scoop: warn, still copy the config (as kitty does when its package fails).
nobin="${WORK}/nobin"
mkdir -p "${nobin}"
for tool in cat cmp cp date dirname mkdir mv rm; do ln -s "$(command -v "${tool}")" "${nobin}/${tool}"; done
rm -f "${win_home}/.wezterm.lua"
check wezterm-no-scoop-warns "scoop not found" "$(PATH="${nobin}" WINDOWS_HOME="${win_home}" install_windows_terminal 2>&1 | grep -o 'scoop not found')"
check wezterm-no-scoop-config "same" "$(cmp -s "${ROOT}/configs/wezterm/windows.lua" "${win_home}/.wezterm.lua" && echo same)"

# Saved selection.
selection_of() { # <config file> <key>
  catalog_load "${FIXTURE}" linux 1
  config_load "$1" 2>/dev/null
  local i
  for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do
    [[ "$(catalog_key "${i}")" == "$2" ]] && printf '%s/%s' "${CAT_SEL[i]}" "${CAT_NEW[i]}"
  done
}
cfg="${WORK}/cfg"
check config-path "${WORK}/h/.local/bootstrap/config" "$(TARGET_HOME="${WORK}/h" config_default_path)"
check config-missing-uses-defaults "1/0" "$(selection_of "${WORK}/none" shell.zsh)"
check config-missing-off-default "0/0" "$(selection_of "${WORK}/none" shell.less)"
printf 'shell.zsh=0\nshell.less=1\n' >"${cfg}"
check config-reads-off "0/0" "$(selection_of "${cfg}" shell.zsh)"
check config-reads-on "1/0" "$(selection_of "${cfg}" shell.less)"
check config-new-item "1/1" "$(selection_of "${cfg}" configs.tmux)"
check config-bom-crlf-first-key "1/0" "$(selection_of "${ROOT}/tests/fixtures/config.input" shell.zsh)"
check config-bom-crlf-later-key "0/0" "$(selection_of "${ROOT}/tests/fixtures/config.input" configs.tmux)"
printf 'shell.zsh=2\nconfigs.tmux\n=1\n' >"${cfg}.bad"
check config-bad-value-default "1/1" "$(selection_of "${cfg}.bad" shell.zsh)"
check config-bad-lines-warn "3" "$(catalog_load "${FIXTURE}" linux 1; config_load "${cfg}.bad" 2>&1 | grep -c 'ignoring')"
# Saving: both engines must write these exact bytes.
save_fixture() { # <target>
  catalog_load "${FIXTURE}" linux 1
  config_load "${ROOT}/tests/fixtures/config.input" 2>/dev/null
  config_save "$1"
}
(save_fixture "${WORK}/save/config")
check config-save-bytes "same" "$(cmp "${WORK}/save/config" "${ROOT}/tests/fixtures/config.expected" && echo same)"
(save_fixture "${WORK}/a b/.local/bootstrap/config")
check config-save-space-path "same" "$(cmp "${WORK}/a b/.local/bootstrap/config" "${ROOT}/tests/fixtures/config.expected" && echo same)"
(save_fixture "${WORK}/save/config")
check config-unchanged-no-backup "0" "$(find "${WORK}/save" -name 'config.bak.*' | wc -l | tr -d ' ')"
printf 'shell.zsh=0\n' >"${WORK}/save/config"
(save_fixture "${WORK}/save/config")
check config-changed-one-backup "1" "$(find "${WORK}/save" -name 'config.bak.*' | wc -l | tr -d ' ')"
check config-no-temp-left "0" "$(find "${WORK}/save" -name '*.tmp.*' | wc -l | tr -d ' ')"
check config-dry-run-writes-nothing "no" "$(DRY_RUN=1; save_fixture "${WORK}/dry/config"; [[ -e "${WORK}/dry" ]] && echo yes || echo no)"
if [[ "${EUID}" -ne 0 ]]; then
  mkdir -p "${WORK}/ro"
  printf 'shell.zsh=0\n' >"${WORK}/ro/config"
  chmod 555 "${WORK}/ro"
  check config-readonly-fails "1" "$( (save_fixture "${WORK}/ro/config") >/dev/null 2>&1; echo $?)"
  check config-readonly-keeps-old "shell.zsh=0" "$(cat "${WORK}/ro/config")"
  chmod 755 "${WORK}/ro"
fi

# Menu key handling, with no terminal involved.
menu_setup() { # <catalog> [rows]
  catalog_load "$1" linux 1
  config_load "${WORK}/none"
  MENU_ROWS="${2:-20}"
  menu_init
}
press() { local k; for k in "$@"; do menu_handle_key "${k}"; done; }
big="${WORK}/big.txt"
for ((n = 1; n <= 20; n++)); do printf 'big|i%s|Item %s|linux|on|step:x\n' "${n}" "${n}"; done >"${big}"
check menu-down "1" "$(menu_setup "${FIXTURE}"; press down; echo "${MENU_CURSOR}")"
check menu-down-stops "2" "$(menu_setup "${FIXTURE}"; press down down down down; echo "${MENU_CURSOR}")"
check menu-up-stops "0" "$(menu_setup "${FIXTURE}"; press up; echo "${MENU_CURSOR}")"
check menu-summary "1/2 selected" "$(menu_setup "${FIXTURE}"; menu_group_summary shell)"
check menu-space-partial-selects-all "2/2 selected" "$(menu_setup "${FIXTURE}"; press space; menu_group_summary shell)"
check menu-space-full-clears "0/2 selected" "$(menu_setup "${FIXTURE}"; press space space; menu_group_summary shell)"
check menu-enter-opens "shell" "$(menu_setup "${FIXTURE}"; press enter; echo "${MENU_OPEN_GROUP}")"
check menu-space-inside-toggles-one "2/2 selected" "$(menu_setup "${FIXTURE}"; press enter down space; menu_group_summary shell)"
check menu-back-closes "|1" "$(menu_setup "${FIXTURE}"; press down enter back; echo "${MENU_OPEN_GROUP}|${MENU_CURSOR}")"
check menu-enter-single-item-toggles "|0/1 selected" "$(menu_setup "${FIXTURE}"; press down enter; echo "${MENU_OPEN_GROUP}|$(menu_group_summary configs)")"
check menu-back-at-top-is-harmless "0" "$(menu_setup "${FIXTURE}"; press back; echo "${MENU_CURSOR}")"
check menu-continue "continue" "$(menu_setup "${FIXTURE}"; press continue; echo "${MENU_RESULT}")"
check menu-quit "quit" "$(menu_setup "${FIXTURE}"; press enter quit; echo "${MENU_RESULT}")"
# A list taller than the screen scrolls with the cursor.
check menu-scroll-down "7|3" "$(menu_setup "${big}" 5; press enter down down down down down down down; echo "${MENU_CURSOR}|${MENU_TOP}")"
check menu-scroll-up "2|2" "$(menu_setup "${big}" 5; press enter down down down down down down down up up up up up; echo "${MENU_CURSOR}|${MENU_TOP}")"
check menu-scroll-bottom "19|15" "$(menu_setup "${big}" 5; press enter; for ((n = 0; n < 30; n++)); do press down; done; echo "${MENU_CURSOR}|${MENU_TOP}")"
check menu-render-window "5" "$(menu_setup "${big}" 5; press enter; menu_render | grep -c 'Item ')"
check menu-render-has-cursor-row "1" "$(menu_setup "${big}" 5; press enter down down down down down down down; menu_render | grep -c '^> .*Item 8')"
printf 'shell.zsh=1\n' >"${cfg}.new"
check menu-render-new "1" "$(catalog_load "${FIXTURE}" linux 1; config_load "${cfg}.new"; MENU_ROWS=20; menu_init; press enter; menu_render | grep -c 'less.*new')"
check menu-available-dumb "no" "$(TERM=dumb menu_available && echo yes || echo no)"
check menu-available-pipe "no" "$(TERM=xterm menu_available </dev/null && echo yes || echo no)"

# The real menu in a pseudo-terminal: arrow, space, continue. BSD script differs,
# so this runs only where `script -qec` works (not in the bash 3.2 image).
if script -qec true /dev/null >/dev/null 2>&1; then
  cat >"${WORK}/menu_driver.sh" <<DRIVER
source "${ROOT}/setup.sh"
set +e
before="\$(stty -g)"
catalog_load "${FIXTURE}" linux 1
config_load "${WORK}/none"
menu_run; rc=\$?
{ echo "rc=\${rc}"; menu_group_summary configs; [[ "\$(stty -g)" == "\${before}" ]] && echo restored; } >"${WORK}/menu_result"
DRIVER
  { sleep 1; printf '\033[B \033[Bc'; sleep 1; } | script -qec "bash ${WORK}/menu_driver.sh" "${WORK}/menu_log" >/dev/null 2>&1
  check menu-pty "rc=0 0/1 selected restored" "$(xargs <"${WORK}/menu_result")"
  check menu-pty-cursor-shown "1" "$(grep -c $'\033\[?25h' "${WORK}/menu_log")"
else
  printf 'SKIP menu-pty: no util-linux script\n'
fi

# configs.* items are honoured one by one.
mkdir -p "${WORK}/sel_home"
(set_selection configs.tmux 0; TARGET_HOME="${WORK}/sel_home" install_configs >/dev/null 2>&1)
check configs-unticked-skipped "no" "$([[ -e "${WORK}/sel_home/.tmux.conf" ]] && echo yes || echo no)"
check configs-ticked-installed "yes" "$([[ -e "${WORK}/sel_home/.nanorc" ]] && echo yes || echo no)"

# Run flow: main with every step stubbed.
printf 'ID=debian\n' >"${WORK}/os-debian"
m_home="${WORK}/m_home"
m_log="${WORK}/steps.log"
m_cfg="${m_home}/.local/bootstrap/config"
run_main() {
  (
    UNAME_S="${M_UNAME:-Linux}" OS_RELEASE_FILE="${WORK}/os-debian" TARGET_HOME="${m_home}"
    install_packages() { echo packages >>"${m_log}"; }
    enable_ssh_server() { echo ssh-server >>"${m_log}"; }
    install_configs() { echo configs >>"${m_log}"; }
    install_tpm() { echo tpm >>"${m_log}"; }
    setup_terminals() { echo "terminals" >>"${m_log}"; }
    install_windows_terminal() { echo wezterm-wsl >>"${m_log}"; }
    setup_ssh_key() { echo ssh-key >>"${m_log}"; }
    setup_zsh_default() { echo zsh-login >>"${m_log}"; }
    restrict_ssh_local_only() { echo ssh-local-only >>"${m_log}"; }
    ssh_server_fail_closed() { echo "fail-closed $2" >>"${m_log}"; return 1; }
    check_ssh_server() { echo MISSING; }
    check_selection() { :; }
    [[ -z "${M_EXTRA:-}" ]] || eval "${M_EXTRA}"
    main "$@"
  ) </dev/null 2>&1
}
m_reset() { rm -rf "${m_home}"; mkdir -p "${m_home}"; : >"${m_log}"; M_EXTRA=""; }
m_save() { mkdir -p "$(dirname "${m_cfg}")"; printf '%s\n' "$@" >"${m_cfg}"; }
steps() { xargs <"${m_log}"; }
exists() { [[ -e "${m_cfg}" ]] && echo yes || echo no; }
MENU_ON='menu_available() { return 0; }; menu_run() { echo menu >>"${m_log}"; }'
DEFAULT_STEPS="packages configs tpm"

m_reset; run_main --yes >/dev/null
check main-yes-defaults "${DEFAULT_STEPS}" "$(steps)"
check main-yes-writes-no-config "no" "$(exists)"
m_reset; m_save 'tmux-plugins.tpm=0' 'extras.zsh-login=1'; run_main --yes >/dev/null
check main-saved-selection "packages configs zsh-login" "$(steps)"
m_reset; run_main --terminal >/dev/null
check main-flag-terminal "${DEFAULT_STEPS} terminals" "$(steps)"
check main-flag-not-saved "no" "$(exists)"
m_reset; M_EXTRA="${MENU_ON}"; run_main --terminal >/dev/null
check main-flag-skips-menu "${DEFAULT_STEPS} terminals" "$(steps)"
m_reset; run_main --no-packages --yes >/dev/null
check main-no-packages "configs tpm" "$(steps)"
m_reset; m_save 'extras.ssh-server=1'; run_main --no-packages --yes >/dev/null
check main-no-packages-clears-server "configs tpm" "$(steps)"
m_reset; run_main --no-configs --yes >/dev/null
check main-no-configs "packages" "$(steps)"
m_reset; run_main --ssh-server --yes >/dev/null
check main-ssh-server "packages ssh-server configs tpm" "$(steps)"
m_reset; run_main --ssh-server --ssh-local-only --yes >/dev/null
check main-ssh-local-only "packages ssh-local-only ssh-server configs tpm" "$(steps)"
# The restriction fails: the server step closes instead of enabling, and is
# told whether sshd already ran before this run.
m_reset; M_EXTRA='restrict_ssh_local_only() { echo ssh-local-only >>"${m_log}"; return 1; }'
run_main --ssh-server --ssh-local-only --yes >/dev/null
check main-ssh-fail-closed "packages ssh-local-only fail-closed 0 configs tpm" "$(steps)"
m_reset; M_EXTRA='restrict_ssh_local_only() { echo ssh-local-only >>"${m_log}"; return 1; }; check_ssh_server() { echo OK; }'
run_main --ssh-server --ssh-local-only --yes >/dev/null
check main-ssh-fail-closed-was-running "packages ssh-local-only fail-closed 1 configs tpm" "$(steps)"
# Restriction alone (no server item): a failure touches no server.
m_reset; M_EXTRA='restrict_ssh_local_only() { echo ssh-local-only >>"${m_log}"; return 1; }'
run_main --ssh-local-only --yes >/dev/null
check main-ssh-local-only-alone "packages ssh-local-only configs tpm" "$(steps)"
# Private state: logs and the saved selection live in a 0700 directory.
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
m_reset; run_main --yes >/dev/null
check state-dir-private "700" "$(mode_of "${m_home}/.local/bootstrap")"
# The Arch plan names the full upgrade that installing a package triggers.
printf 'ID=arch\n' >"${WORK}/os-arch-plan"
m_reset; M_EXTRA='OS_RELEASE_FILE="${WORK}/os-arch-plan"'
check plan-arch-upgrade-note "1" "$(run_main --dry-run --yes | grep -c 'full system upgrade (pacman -Syu)')"
check plan-arch-no-packages-no-note "0" "$(run_main --dry-run --yes --no-packages | grep -c 'full system upgrade')"
m_reset
check plan-debian-no-note "0" "$(run_main --dry-run --yes | grep -c 'full system upgrade')"

# The check step runs last on a real run, never on a dry run.
m_reset; M_EXTRA='check_selection() { echo check >>"${m_log}"; }'; run_main --yes >/dev/null
check main-check-last "${DEFAULT_STEPS} check" "$(steps)"
m_reset; M_EXTRA='check_selection() { echo check >>"${m_log}"; }'; run_main --dry-run >/dev/null
check main-check-not-in-dry-run "${DEFAULT_STEPS}" "$(steps)"
m_reset; M_EXTRA='check_selection() { return 1; }'; out="$(run_main --yes)"; rc=$?
check main-check-missing-fails "1" "${rc}"
check main-check-missing-summary "1" "$(printf '%s\n' "${out}" | grep -c 'FAILED.*check')"
# Modes.
m_reset; M_EXTRA="${MENU_ON}"; run_main >/dev/null
check main-menu-runs "menu ${DEFAULT_STEPS}" "$(steps)"
check main-menu-saves "yes" "$(exists)"
m_reset; M_EXTRA="${MENU_ON}"; run_main --yes >/dev/null
check main-yes-no-menu "${DEFAULT_STEPS}" "$(steps)"
m_reset; M_EXTRA="${MENU_ON}"; run_main --dry-run >/dev/null
check main-dry-run-no-menu "${DEFAULT_STEPS}" "$(steps)"
check main-dry-run-no-config "no" "$(exists)"
m_reset; run_main --select >/dev/null; rc=$?
check main-select-no-terminal "1" "${rc}"
m_reset; M_EXTRA="${MENU_ON}"; run_main --select >/dev/null
check main-select-only-menu "menu" "$(steps)"
check main-select-saves "yes" "$(exists)"
m_reset; M_EXTRA='menu_available() { return 0; }; menu_run() { return 1; }'; run_main >/dev/null; rc=$?
check main-quit-exit "0" "${rc}"
check main-quit-no-steps "" "$(steps)"
check main-quit-no-config "no" "$(exists)"
m_reset; run_main --yes --config "${WORK}/missing" >/dev/null; rc=$?
check main-config-missing-exit "1" "${rc}"
check main-config-missing-no-steps "" "$(steps)"
m_reset; printf 'tmux-plugins.tpm=0\n' >"${WORK}/other.cfg"; run_main --yes --config "${WORK}/other.cfg" >/dev/null
check main-config-file "packages configs" "$(steps)"
m_reset; M_EXTRA="${MENU_ON}"; run_main --config "${WORK}/new dir/cfg" >/dev/null
check main-config-created-on-save "yes" "$([[ -e "${WORK}/new dir/cfg" ]] && echo yes || echo no)"
check main-config-usage "1" "$(m_reset; run_main --config 2>&1 >/dev/null; echo $?)"
if [[ "${EUID}" -ne 0 ]]; then
  m_reset; mkdir -p "${WORK}/ro2"; chmod 555 "${WORK}/ro2"; M_EXTRA="${MENU_ON}"; run_main --config "${WORK}/ro2/cfg" >/dev/null; rc=$?
  check main-save-failure-exit "1" "${rc}"
  check main-save-failure-no-steps "menu" "$(steps)"
  chmod 755 "${WORK}/ro2"
fi
# A failed step does not stop later ones, and the run reports it.
m_reset; M_EXTRA='install_configs() { false; echo after-false >>"${m_log}"; }'; out="$(run_main --yes)"; rc=$?
check main-failure-exit "1" "${rc}"
check main-failure-continues "packages tpm" "$(steps)"
check main-failure-summary "1" "$(printf '%s\n' "${out}" | grep -c 'FAILED.*configs')"
check main-ok-summary "1" "$(printf '%s\n' "${out}" | grep -c 'OK.*packages')"
# brew set up in the main shell reaches every step, which run in subshells.
m_reset; M_UNAME=Darwin; M_EXTRA='ensure_brew() { BREW_MARK=set; }; install_tpm() { echo "brew-${BREW_MARK:-lost}" >>"${m_log}"; }'; run_main --yes >/dev/null; M_UNAME=""
check main-brew-survives "packages configs brew-set" "$(steps)"
# sudo: the config lands in root's home, so say which file is used.
m_reset; M_EXTRA='is_root() { return 0; }; SUDO_USER=someone'; out="$(run_main --yes)"
check main-sudo-warning "1" "$(printf '%s\n' "${out}" | grep -c "running under sudo.*${m_cfg}")"
check main-sudo-continues "${DEFAULT_STEPS}" "$(steps)"
# WSL item.
m_reset; m_save 'terminals.wezterm-wsl=1'; run_main --yes >/dev/null
check main-linux-ignores-wsl-item "${DEFAULT_STEPS}" "$(steps)"
m_reset; m_save 'terminals.wezterm-wsl=1'; M_EXTRA="KERNEL_RELEASE_FILE='${WORK}/osrelease-wsl'"; run_main --yes >/dev/null
check main-wsl-item "${DEFAULT_STEPS} wezterm-wsl" "$(steps)"
# The plan names what happens and what does not.
m_reset; out="$(run_main --yes)"
check main-plan-install "1" "$(printf '%s\n' "${out}" | grep -c '^  install .*tmux config')"
check main-plan-skip "1" "$(printf '%s\n' "${out}" | grep -c '^  skip .*SSH key')"

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
  check ask-noninteractive-skips "" "$(TARGET_HOME="${WORK}/home3" SSH_KEY_MODE=saved setup_ssh_key </dev/null &>/dev/null; ls "${WORK}/home3/.ssh" 2>/dev/null)"

  # A private key whose .pub is lost is never overwritten: the .pub is rebuilt.
  home4="${WORK}/home4"
  mkdir -p "${home4}/.ssh"
  ssh-keygen -q -t ed25519 -N "" -f "${home4}/.ssh/id_ed25519" -C t >/dev/null
  cp "${home4}/.ssh/id_ed25519" "${WORK}/priv.orig"
  want_pub="$(cut -d' ' -f1,2 "${home4}/.ssh/id_ed25519.pub")"
  rm "${home4}/.ssh/id_ed25519.pub"
  for mode in create saved; do
    rm -f "${home4}/.ssh/id_ed25519.pub"
    TARGET_HOME="${home4}" SSH_KEY_MODE="${mode}" setup_ssh_key </dev/null >/dev/null 2>&1; rc=$?
    check "pub-rebuilt-${mode}-rc" "0" "${rc}"
    check "pub-rebuilt-${mode}" "${want_pub}" "$(cut -d' ' -f1,2 "${home4}/.ssh/id_ed25519.pub" 2>/dev/null)"
    check "private-kept-${mode}" "same" "$(cmp -s "${WORK}/priv.orig" "${home4}/.ssh/id_ed25519" && echo same)"
  done
  # An encrypted key without a terminal: warn, keep the key, do not fail.
  home5="${WORK}/home5"
  mkdir -p "${home5}/.ssh"
  ssh-keygen -q -t ed25519 -N secret -f "${home5}/.ssh/id_ed25519" -C t >/dev/null
  rm "${home5}/.ssh/id_ed25519.pub"
  cp "${home5}/.ssh/id_ed25519" "${WORK}/priv5.orig"
  out="$(TARGET_HOME="${home5}" SSH_KEY_MODE=create setup_ssh_key </dev/null 2>&1 | grep -c 'could not read')"
  check encrypted-no-tty-warns "1" "${out}"
  check encrypted-key-kept "same" "$(cmp -s "${WORK}/priv5.orig" "${home5}/.ssh/id_ed25519" && echo same)"
  # A lone .pub (no private half) is backed up before a new key replaces it.
  home6="${WORK}/home6"
  mkdir -p "${home6}/.ssh"
  echo "ssh-ed25519 AAAA other" >"${home6}/.ssh/id_ed25519.pub"
  TARGET_HOME="${home6}" SSH_KEY_MODE=create setup_ssh_key </dev/null >/dev/null 2>&1
  check lone-pub-backed-up "1" "$(grep -l 'AAAA other' "${home6}/.ssh/"id_ed25519.pub.bak.* 2>/dev/null | wc -l | tr -d ' ')"
  check lone-pub-new-key "yes" "$([[ -f "${home6}/.ssh/id_ed25519" ]] && echo yes)"
fi

# Restrict SSH to local network only: drop-in, Include line, sshd -t, rerun.
sshdir="${WORK}/etc-ssh"
mkdir -p "${sshdir}"
printf 'Port 22\n' >"${sshdir}/sshd_config"
touch "${sshdir}/ssh_host_ed25519_key"
ssh_stubs='as_root() { run "$@"; }; root_quiet() { "$@"; }; reload_sshd() { echo reloaded; }; SSHD_RUN_DIR="${WORK}/run-sshd"'
local_only() { (eval "${ssh_stubs}"; SSH_CONFIG_DIR="${sshdir}"; sshd_path() { echo /bin/true; }; restrict_ssh_local_only debian) 2>&1; }
out="$(local_only)"; rc=$?
dropin="${sshdir}/sshd_config.d/20-local-network-only.conf"
check local-only-rc "0" "${rc}"
check local-only-dropin "same" "$([[ "$(<"${dropin}")" == "$(ssh_local_only_conf)" ]] && echo same)"
check local-only-denyusers "1" "$(grep -c '^    DenyUsers \*$' "${dropin}")"
check local-only-include-first "Include ${sshdir}/sshd_config.d/*.conf" "$(head -n 1 "${sshdir}/sshd_config")"
check local-only-config-kept "1" "$(grep -c '^Port 22$' "${sshdir}/sshd_config")"
check local-only-config-backup "1" "$(find "${sshdir}" -maxdepth 1 -name 'sshd_config.bak.*' | wc -l | tr -d ' ')"
check local-only-reloaded "1" "$(grep -c reloaded <<<"${out}")"
check local-only-run-dir "yes" "$([[ -d "${WORK}/run-sshd" ]] && echo yes)"
out="$(local_only)"
check local-only-rerun-unchanged "1" "$(grep -c '(unchanged)' <<<"${out}")"
check local-only-rerun-one-include "1" "$(grep -c '^Include' "${sshdir}/sshd_config")"
check local-only-rerun-no-reload "0" "$(grep -c reloaded <<<"${out}")"
# sshd rejects the config: the drop-in is removed and the step fails.
rm -f "${dropin}"
out="$( (eval "${ssh_stubs}"; SSH_CONFIG_DIR="${sshdir}"; sshd_path() { echo /bin/false; }; restrict_ssh_local_only debian) 2>&1)"; rc=$?
check local-only-rejected-rc "1" "${rc}"
check local-only-rejected-removed "no" "$([[ -e "${dropin}" ]] && echo yes || echo no)"
# No SSH server installed: only warns.
out="$( (eval "${ssh_stubs}"; SSH_CONFIG_DIR="${WORK}/no-ssh"; restrict_ssh_local_only debian) 2>&1)"; rc=$?
check local-only-no-server-rc "0" "${rc}"
check local-only-no-server-warns "1" "$(grep -c 'no SSH server installed' <<<"${out}")"

# Lock-out check: over SSH, a restriction that refuses the current session is
# removed again and the step fails. A fake sshd answers -T like the real one.
# Private addresses come from 3-octet prefixes: tests/test_repo.sh rejects
# literal private host IPs.
LAN=192.168.1 TEN=10.0.0
cat >"${WORK}/fake-sshd" <<'EOF'
#!/bin/sh
echo "$*" >>"${FAKE_SSHD_LOG}"
case "$*" in
  *-T*addr=8.8.8.8,*) echo "port 22"; echo "denyusers *" ;;
  *-T*addr=6.6.6.6,*) exit 255 ;;
  *-T*) echo "port 22" ;;
esac
exit 0
EOF
chmod +x "${WORK}/fake-sshd"
lockout() {
  rm -f "${dropin}"
  : >"${WORK}/sshd.log"
  (
    eval "${ssh_stubs}"
    SSH_CONFIG_DIR="${sshdir}" FAKE_SSHD_LOG="${WORK}/sshd.log"
    export FAKE_SSHD_LOG
    sshd_path() { echo "${WORK}/fake-sshd"; }
    SSH_CONNECTION="$1" restrict_ssh_local_only debian
  ) 2>&1
}
out="$(lockout "8.8.8.8 50000 ${LAN}.2 22")"; rc=$?
check lockout-public-rc "1" "${rc}"
check lockout-public-removed "no" "$([[ -e "${dropin}" ]] && echo yes || echo no)"
check lockout-public-says "1" "$(grep -c 'connected over SSH from 8.8.8.8' <<<"${out}")"
check lockout-public-no-reload "0" "$(grep -c reloaded <<<"${out}")"
out="$(lockout "${LAN}.9 50000 ${LAN}.2 22")"; rc=$?
check lockout-lan-rc "0" "${rc}"
check lockout-lan-spec "1" "$(grep -c "addr=${LAN}.9,laddr=${LAN}.2,lport=22" "${WORK}/sshd.log")"
check lockout-lan-reloaded "1" "$(grep -c reloaded <<<"${out}")"
out="$(lockout '')"; rc=$?
check lockout-console-rc "0" "${rc}"
check lockout-console-no-T "0" "$(grep -c -- '-T' "${WORK}/sshd.log")"
check lockout-config-flag "1" "$(grep -c -- "-t -f ${sshdir}/sshd_config" "${WORK}/sshd.log")"
out="$(lockout "6.6.6.6 1 ${LAN}.2 22")"; rc=$?
check lockout-unverifiable-rc "1" "${rc}"
check lockout-unverifiable-removed "no" "$([[ -e "${dropin}" ]] && echo yes || echo no)"
check lockout-unverifiable-says "1" "$(grep -c 'sshd -T failed' <<<"${out}")"
# Inside tmux the attach-time value wins over the pane's stale copy.
check ssh-connection-tmux "9.9.9.9 1 ${TEN}.1 22" "$( (tmux() { echo "SSH_CONNECTION=9.9.9.9 1 ${TEN}.1 22"; }; TMUX=x SSH_CONNECTION=stale ssh_connection) )"
check ssh-connection-tmux-unset "stale" "$( (tmux() { echo "-SSH_CONNECTION"; }; TMUX=x SSH_CONNECTION=stale ssh_connection) )"
check ssh-connection-plain "a b c d" "$(SSH_CONNECTION='a b c d' ssh_connection)"

# Fail closed: an sshd this run brought up is stopped when the restriction
# failed; one that ran before is left alone (it may carry the user's session).
fail_closed() {
  (
    as_root() { echo "as_root $*"; }
    systemctl() { :; }
    SYSTEMD_RUN_DIR="${WORK}"
    ssh_server_fail_closed "$1" "$2"
  ) 2>&1
}
out="$(fail_closed debian 1)"; rc=$?
check fail-closed-was-running-rc "1" "${rc}"
check fail-closed-was-running-untouched "0" "$(grep -c as_root <<<"${out}")"
check fail-closed-was-running-warns "1" "$(grep -c 'WITHOUT the local-network restriction' <<<"${out}")"
out="$(fail_closed debian 0)"; rc=$?
check fail-closed-new-rc "1" "${rc}"
check fail-closed-debian-stops "1" "$(grep -c 'as_root systemctl disable --now ssh.socket ssh$' <<<"${out}")"
check fail-closed-fedora-stops "1" "$(fail_closed fedora 0 | grep -c 'as_root systemctl disable --now sshd.socket sshd$')"
check fail-closed-macos-no-action "0" "$(fail_closed macos 0 | grep -c as_root)"
check fail-closed-no-systemd "0" "$( (as_root() { echo "as_root $*"; }; SYSTEMD_RUN_DIR="${WORK}/none"; ssh_server_fail_closed debian 0) 2>&1 | grep -c as_root)"

# The real sshd decides what the drop-in refuses (skipped when there is none).
real_sshd="$(sshd_path 2>/dev/null || true)"
if [[ -n "${real_sshd}" ]] && command -v ssh-keygen >/dev/null 2>&1; then
  sb="${WORK}/sshd-real"
  mkdir -p "${sb}"
  ssh-keygen -q -t ed25519 -N '' -f "${sb}/ssh_host_ed25519_key"
  printf 'HostKey %s/ssh_host_ed25519_key\nUsePAM no\n' "${sb}" >"${sb}/sshd_config"
  if ( eval "${ssh_stubs}"; SSH_CONFIG_DIR="${sb}"; restrict_ssh_local_only arch ) >/dev/null 2>&1; then
    for a in "${LAN}.5=allow" "${TEN}.3=allow" "::1=allow" "fd00::5=allow" \
      "8.8.8.8=deny" "100.64.1.1=deny" "2a01:4f8::1=deny" "::ffff:8.8.8.8=deny"; do
      ip="${a%=*}" got=allow
      "${real_sshd}" -T -f "${sb}/sshd_config" -C "user=u,host=h,addr=${ip}" 2>/dev/null | grep -qi '^denyusers \*$' && got=deny
      check "match-${ip}" "${a#*=}" "${got}"
    done
  else
    echo "SKIP real-sshd match tests: sshd -t rejects the sandbox config here"
  fi
fi

# Check step: one line per ticked item; MISSING fails, SKIPPED does not.
ck_home="${WORK}/ck_home"
mkdir -p "${ck_home}"
only_ticked() { local i; for ((i = 0; i < ${#CAT_ITEM[@]}; i++)); do CAT_SEL[i]=0; done; for k in "$@"; do set_selection "${k}" 1; done; }
ck() { (load_catalog debian; only_ticked "$@"; TARGET_HOME="${ck_home}"; SSH_CONFIG_DIR="${sshdir}"; check_selection debian </dev/null; echo "rc=$?") 2>&1; }
out="$(ck tmux-plugins.tpm configs.tmux)"
check check-missing-rc "rc=1" "$(grep -o 'rc=[0-9]' <<<"${out}")"
check check-missing-lines "2" "$(grep -c '^  MISSING' <<<"${out}")"
mkdir -p "${ck_home}/.tmux/plugins/tpm"; touch "${ck_home}/.tmux/plugins/tpm/tpm" "${ck_home}/.tmux.conf"
out="$(ck tmux-plugins.tpm configs.tmux)"
check check-ok-rc "rc=0" "$(grep -o 'rc=[0-9]' <<<"${out}")"
check check-ok-line "1" "$(grep -c '^  OK      TPM and plugins$' <<<"${out}")"
out="$(ck extras.ssh-key)"
check check-ssh-key-skipped "1" "$(grep -c '^  SKIPPED SSH key (no terminal for a passphrase)$' <<<"${out}")"
check check-ssh-key-skipped-rc "rc=0" "$(grep -o 'rc=[0-9]' <<<"${out}")"
out="$( (load_catalog debian; only_ticked extras.ssh-local-only; TARGET_HOME="${ck_home}"; SSH_CONFIG_DIR="${sshdir}"; sshd_path() { echo /bin/true; }; check_selection debian; echo "rc=$?") 2>&1)"
check check-local-only-missing "1" "$(grep -c '^  MISSING Restrict SSH' <<<"${out}")"
(eval "${ssh_stubs}"; SSH_CONFIG_DIR="${sshdir}"; sshd_path() { echo /bin/true; }; restrict_ssh_local_only debian) >/dev/null 2>&1
out="$( (load_catalog debian; only_ticked extras.ssh-local-only; TARGET_HOME="${ck_home}"; SSH_CONFIG_DIR="${sshdir}"; sshd_path() { echo /bin/true; }; check_selection debian; echo "rc=$?") 2>&1)"
check check-local-only-ok "1" "$(grep -c '^  OK      Restrict SSH' <<<"${out}")"
out="$( (load_catalog debian; only_ticked shell.tmux; pkg_installed() { [[ "$2" == tmux ]]; }; check_selection debian; echo "rc=$?") 2>&1)"
check check-pkg-ok "1" "$(grep -c '^  OK      tmux$' <<<"${out}")"

# Containers can run under a UID with no passwd entry: `id -un` then fails.
# shellcheck disable=SC2329 # the stub is called through login_shell
check login-shell-no-passwd "ok" "$( (set -e; id() { return 1; }; USER=nobody-here; login_shell >/dev/null; echo ok) 2>/dev/null )"

# zsh login shell: ask mode without a terminal never changes anything.

# Cross-engine check: PowerShell load+save must equal the bash save and the
# expected bytes. Skipped when powershell.exe is missing.
if command -v powershell.exe >/dev/null 2>&1; then
  ps_fixture="$(wslpath -w "${ROOT}/tests/fixtures/catalog.txt")"
  ps_input="$(wslpath -w "${ROOT}/tests/fixtures/config.input")"
  ps_out="$(wslpath -w "${WORK}/ps-save")"
  mkdir -p "${WORK}/ps-save"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    ". '$(wslpath -w "${ROOT}/windows/lib.ps1")';" \
    " \$c = Import-Catalog -Path '${ps_fixture}';" \
    " \$e = Import-Selection -Path '${ps_input}' -Catalog \$c;" \
    " Save-Selection -Path '${ps_out}/config' -Catalog \$c -Extra \$e" >/dev/null 2>&1
  (save_fixture "${WORK}/bash-save/config")
  check cross-engine-ps-match "same" "$(cmp -s "${WORK}/ps-save/config" "${WORK}/bash-save/config" && echo same || echo differs)"
  check cross-engine-expected "same" "$(cmp -s "${WORK}/ps-save/config" "${ROOT}/tests/fixtures/config.expected" && echo same || echo differs)"
else
  printf 'SKIP cross-engine: no powershell.exe\n'
fi

# keepers-20 smoke: extract round-trip, duh, hgrep, down-usage.
keeper_home="${WORK}/keeper_home"
mkdir -p "${keeper_home}"
# groot: resolve from a scratch git repo (works in read-only mounts like
# /src); skipped when git is missing (e.g. the bash:3.2 image).
mkdir -p "${keeper_home}/grootrepo"
if command -v git >/dev/null 2>&1; then
  git -C "${keeper_home}/grootrepo" init -q 2>/dev/null || true
  check keepers-groot "${keeper_home}/grootrepo" "$(bash -c 'shopt -s expand_aliases; source '"${ROOT}"'/configs/bash_extras; eval "cd '"${keeper_home}"'/grootrepo && groot"')"
fi
( cd "${keeper_home}" && mkdir -p src && echo hi > src/f.txt && tar czf a.tar.gz src >/dev/null && rm -rf src && bash -c 'source '"${ROOT}"'/configs/bash_extras; extract a.tar.gz' && [ -f src/f.txt ] && echo keep-ok ) >/dev/null 2>&1
check keepers-extract "keep-ok" "$(cd "${keeper_home}" && rm -rf src && bash -c 'source '"${ROOT}"'/configs/bash_extras; extract a.tar.gz >/dev/null 2>&1 && [ -f src/f.txt ] && echo keep-ok')"
check keepers-duh "0" "$(bash -c 'source '"${ROOT}"'/configs/bash_extras; d=$(mktemp -d); cd "$d"; touch a; duh >/dev/null 2>&1; echo $?; rm -rf "$d"')"
check keepers-hgrep "0" "$(bash -c 'source '"${ROOT}"'/configs/bash_extras; type -t hgrep | grep -q function && echo 0')"
check keepers-alg "psmem" "$(bash -c 'shopt -s expand_aliases; source '"${ROOT}"'/configs/bash_extras; alg psmem 2>/dev/null | grep -o psmem | head -n 1')"
check keepers-down-usage "1" "$(bash -c 'source '"${ROOT}"'/configs/bash_extras; down >/dev/null 2>&1; echo $?')"

# --- Idempotent, failsafe, verbose -------------------------------------------

# Installed packages are skipped; nothing installed means no package manager.
pm_log="${WORK}/pm.log"
check pkgs-all-present-skips-pm "0" "$( : >"${pm_log}"; pkg_installed() { return 0; }; pkg_install() { echo "$@" >>"${pm_log}"; }; install_missing debian vim git >/dev/null 2>&1; wc -l <"${pm_log}" | tr -d ' ')"
check pkgs-only-missing "debian git" "$( : >"${pm_log}"; pkg_installed() { [[ "$2" == vim ]]; }; pkg_install() { echo "$@" >>"${pm_log}"; }; install_missing debian vim git >/dev/null 2>&1; xargs <"${pm_log}")"
# A failed batch retries one by one and names only the bad package.
check pkgs-batch-fallback "bad" "$( pkg_installed() { return 1; }; pkg_install() { shift; [[ " $* " != *" bad "* ]]; }; install_missing debian vim bad git 2>&1 >/dev/null | grep -o 'could not install: .*' | sed 's/could not install: //')"
check pkgs-batch-fallback-fails "1" "$( (pkg_installed() { return 1; }; pkg_install() { shift; [[ " $* " != *" bad "* ]]; }; install_missing debian vim bad) >/dev/null 2>&1; echo $?)"
# Arch never does a partial upgrade (-Sy without -u).
check arch-no-partial-upgrade "-Syu" "$(DRY_RUN=1 pkg_install arch vim 2>&1 | grep -o -- '-Sy[u]*')"
# apt waits for the dpkg lock instead of failing on a fresh Ubuntu.
check apt-lock-timeout "1" "$(apt_refresh() { :; }; DRY_RUN=1 pkg_install debian vim 2>&1 | grep -c 'DPkg::Lock::Timeout=300')"

# Backups never overwrite each other within one second.
bk="${WORK}/bk"; mkdir -p "${bk}"; echo a >"${bk}/f"
(backup_file "${bk}/f"; backup_file "${bk}/f"; backup_file "${bk}/f") >/dev/null 2>&1
check backup-unique-names "3" "$(find "${bk}" -name 'f.bak.*' | wc -l | tr -d ' ')"

# Atomic copy: no temp left, symlink replaced (not written through), mode set.
ac="${WORK}/ac"; mkdir -p "${ac}"; echo target >"${ac}/linked"; ln -s "${ac}/linked" "${ac}/dst"
(install_file "${ROOT}/configs/nanorc" "${ac}/dst") >/dev/null 2>&1
check atomic-replaces-symlink "file target" "$([[ -L "${ac}/dst" ]] && echo link || echo file) $(cat "${ac}/linked")"
check atomic-no-temp-left "0" "$(find "${ac}" -name '*.tmp.*' | wc -l | tr -d ' ')"
(atomic_copy "${ROOT}/configs/nanorc" "${ac}/exe" 755) >/dev/null 2>&1
check atomic-mode "yes" "$([[ -x "${ac}/exe" ]] && echo yes)"
check atomic-fails-cleanly "1 0" "$( (atomic_copy "${ROOT}/configs/nanorc" "${WORK}/no/such/dir/f") >/dev/null 2>&1; echo "$? $(find "${WORK}" -path '*no/such*' | wc -l | tr -d ' ')")"

# Reruns change nothing: second config install makes no backups.
idem="${WORK}/idem"; mkdir -p "${idem}"
(load_catalog debian; config_load "${WORK}/none"; TARGET_HOME="${idem}" install_configs debian) >/dev/null 2>&1
before="$(find "${idem}" -name '*.bak.*' | wc -l | tr -d ' ')"
(load_catalog debian; config_load "${WORK}/none"; TARGET_HOME="${idem}" install_configs debian) >/dev/null 2>&1
check configs-rerun-no-backups "${before}" "$(find "${idem}" -name '*.bak.*' | wc -l | tr -d ' ')"
check configs-rerun-says-unchanged "yes" "$( (load_catalog debian; config_load "${WORK}/none"; TARGET_HOME="${idem}" install_configs debian) 2>&1 | grep -c 'unchanged' | grep -q '^[1-9]' && echo yes)"

# Summary: OK, WARN (step warned) and FAILED; only FAILED fails the run.
sum_out="$( (STEP_LABELS=() STEP_STATUS=() STEP_TIME=() RUN_DIR=""
  run_step good true; run_step warned warn "heads up"; run_step bad false
  set +e; print_summary; echo "rc=$?") 2>&1)"
check summary-ok "1" "$(grep -c 'OK .* good' <<<"${sum_out}")"
check summary-warn "1" "$(grep -c 'WARN .* warned' <<<"${sum_out}")"
check summary-warn-text "1" "$(grep -c -- '- heads up' <<<"${sum_out}")"
check summary-failed "1" "$(grep -c 'FAILED .* bad' <<<"${sum_out}")"
check summary-rc "rc=1" "$(grep -o 'rc=[0-9]' <<<"${sum_out}")"
check summary-warn-only-rc "rc=0" "$( (STEP_LABELS=() STEP_STATUS=() STEP_TIME=() RUN_DIR=""; run_step w warn x; set +e; print_summary; echo "rc=$?") 2>/dev/null | grep -o 'rc=[0-9]')"

# Lock: a live owner blocks a second run; a dead owner's lock is taken over.
lk="${WORK}/lock"
check lock-live-blocks "1" "$( (take_lock "${lk}"; (take_lock "${lk}") >/dev/null 2>&1; echo $?) 2>/dev/null)"
rm -rf "${lk}"; mkdir -p "${lk}"; echo 999999 >"${lk}/pid"
check lock-stale-taken "$$" "$( (take_lock "${lk}") >/dev/null 2>&1; cat "${lk}/pid")"

# A real (non-dry) run takes the lock, writes a log, prunes old logs, and
# releases the lock. Steps are stubbed by run_main.
m_reset; mkdir -p "${m_home}/.local/bootstrap/logs"
for i in $(seq 1 25); do : >"${m_home}/.local/bootstrap/logs/setup-20200101_0000$(printf %02d "${i}").log"; done
M_EXTRA='KEEP_LOGS=20'; out="$(run_main --yes)"; rc=$?
check run-real-rc "0" "${rc}"
check run-real-log-line "1" "$(grep -c 'Logging to .*setup-.*\.log' <<<"${out}")"
check run-real-logs-pruned "20" "$(find "${m_home}/.local/bootstrap/logs" -name 'setup-*.log' | wc -l | tr -d ' ')"
check run-real-lock-released "no" "$([[ -e "${m_home}/.local/bootstrap/lock" ]] && echo yes || echo no)"
check run-real-log-has-summary "1" "$(cat "${m_home}"/.local/bootstrap/logs/setup-*.log | grep -c '==> Summary')"
m_reset; out="$(run_main --yes --no-log)"
check run-no-log "0" "$(find "${m_home}/.local/bootstrap" -name 'setup-*.log' 2>/dev/null | wc -l | tr -d ' ')"

# Catalog: a duplicate key on one platform is an error.
printf '%s\n' 'a|x|X|linux|on|pkg' 'a|x|X2|linux|on|pkg' >"${WORK}/dup.txt"
check catalog-duplicate-key "1" "$( (catalog_load "${WORK}/dup.txt" linux 0) 2>&1 | grep -c 'duplicate')"
printf '%s\n' 'a|x|X|linux|on|pkg' 'a|x|X2|macos|on|pkg' >"${WORK}/dup2.txt"
check catalog-same-key-other-platform "1" "$( (catalog_load "${WORK}/dup2.txt" linux 0; echo "${#CAT_ITEM[@]}") 2>/dev/null)"

# `sh setup.sh` re-runs itself under bash.
check sh-reexecs-bash "1" "$(sh "${ROOT}/setup.sh" --help 2>/dev/null | grep -c -- '--dry-run      Print')"
# Version line: git describe, or the .source file from bootstrap.sh.
check version-line "1" "$(OS_RELEASE_FILE="${WORK}/os-debian" TARGET_HOME="${WORK}/vh" bash "${ROOT}/setup.sh" --dry-run --yes </dev/null 2>&1 | grep -c '==> install .*, bash ')"

if ((FAILS)); then
  printf '%d test(s) failed\n' "${FAILS}"
  exit 1
fi
echo "all tests passed"
