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
      test -f ~/.ssh/id_ed25519.pub
      for bin in zsh tmux vim nano htop git curl ssh sshd dig ip ping less sudo which file lsof zip; do command -v "$bin" >/dev/null || { echo "missing $bin"; exit 1; }; done
      cmp /src/configs/tmux.conf ~/.tmux.conf
      cmp /src/configs/nanorc ~/.nanorc
      test -f ~/.tmux/plugins/tpm/tpm
      tmux -f ~/.tmux.conf new-session -d -s t && tmux kill-server
      echo "verified: packages, configs, tpm, tmux config loads"
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
