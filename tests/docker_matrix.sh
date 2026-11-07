#!/usr/bin/env bash
# Run setup.sh for real inside one container per supported distro.
# Usage: tests/docker_matrix.sh [image ...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ENGINE:-$(command -v docker || command -v podman)}"
IMAGES=("$@")
if ((${#IMAGES[@]} == 0)); then
  IMAGES=(
    archlinux:latest
    ubuntu:24.04
    debian:12
    fedora:latest
    rockylinux/rockylinux:9
    almalinux:9
  )
fi

failed=()
for image in "${IMAGES[@]}"; do
  printf '\n===== %s =====\n' "${image}"
  # shellcheck disable=SC2016  # expands inside the container
  if "${ENGINE}" run --rm -v "${ROOT}:/src:ro" "${image}" bash -c '
      set -e
      /src/setup.sh --yes --ssh-server --ssh-key --zsh-default </dev/null
      getent passwd root | grep -q "zsh$" || { echo "login shell not zsh"; exit 1; }
      cmp /src/configs/zshrc ~/.zshrc
      zsh -i -c exit </dev/null
      cmp /src/configs/bash_aliases ~/.bash_aliases
      rc=~/.bashrc; [ -f ~/.bash_profile ] && rc=~/.bash_profile
      grep -q "source ~/.bash_aliases2" "$rc"
      bash -ic "alias ll" </dev/null >/dev/null 2>&1 || bash -lc "shopt -s expand_aliases; source $rc; alias ll" >/dev/null
      zsh -ic "alias ll" </dev/null >/dev/null
      test -f ~/.ssh/id_ed25519.pub
      for bin in zsh tmux vim nano htop git curl ssh sshd dig ip ping less sudo which file lsof zip; do command -v "$bin" >/dev/null || { echo "missing $bin"; exit 1; }; done
      cmp /src/configs/tmux.conf ~/.tmux.conf
      cmp /src/configs/nanorc ~/.nanorc
      test -f ~/.tmux/plugins/tpm/tpm
      tmux -f ~/.tmux.conf new-session -d -s t && tmux kill-server
      ls ~/.local/bootstrap/logs/setup-*.log >/dev/null
      # Rerun: idempotent. No package install, no new backups, all steps OK.
      before=$(find ~ -name "*.bak.*" | wc -l)
      out=$(/src/setup.sh --yes --ssh-server --ssh-key --zsh-default </dev/null 2>&1)
      echo "$out" | grep -q "nothing to install" || { echo "$out"; echo "rerun reinstalled packages"; exit 1; }
      [ "$(find ~ -name "*.bak.*" | wc -l)" -eq "$before" ] || { echo "rerun made backups"; exit 1; }
      # Containers have no systemd, so only the ssh server step may warn.
      echo "$out" | grep -E "^  .*(FAILED|WARN) " | grep -v "WARN .* ssh server" && { echo "rerun not clean"; exit 1; }
      echo "$out" | sed -n "/==> Summary/,\$p"
      echo "verified: packages, configs, tpm, tmux config loads, rerun is a no-op"
    '; then
    printf 'PASS %s\n' "${image}"
  else
    printf 'FAIL %s\n' "${image}"
    failed+=("${image}")
  fi
done

if ((${#failed[@]})); then
  printf '\nFailed: %s\n' "${failed[*]}"
  exit 1
fi
printf '\nAll images passed\n'
