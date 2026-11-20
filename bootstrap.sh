#!/bin/sh
# Bootstrap a new Linux or macOS machine: download this repo to ~/install and
# run setup.sh. Paste-safe: the body runs in a subshell, so pasting the whole
# file into bash or zsh never closes your shell.
#
#   curl -fsSL https://raw.githubusercontent.com/jturi/install/main/bootstrap.sh | sh
#   sh bootstrap.sh [setup.sh options]
#
# Environment:
#   INSTALL_DIR    where the repo goes (default ~/install)
#   SETUP_ARGS     setup.sh options when pasted or piped, e.g. "--yes"
#   GITHUB_TOKEN   token for a private repo; else `gh auth token`, else a prompt
(
  set -eu
  repo=jturi/install
  dir="${INSTALL_DIR:-$HOME/install}"
  url="${BOOTSTRAP_URL:-https://api.github.com/repos/$repo/tarball/main}"
  token="${GITHUB_TOKEN:-}"
  if [ -z "$token" ] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi

  has_tty() { (: </dev/tty) 2>/dev/null; }

  # fetch URL [TOKEN]: print the body to stdout.
  fetch() {
    if command -v curl >/dev/null 2>&1; then
      if [ -n "${2:-}" ]; then curl -fsSL -H "Authorization: Bearer $2" "$1"; else curl -fsSL "$1"; fi
    elif command -v wget >/dev/null 2>&1; then
      if [ -n "${2:-}" ]; then wget -qO- --header="Authorization: Bearer $2" "$1"; else wget -qO- "$1"; fi
    else
      echo "error: need curl or wget" >&2
      return 1
    fi
  }

  if [ -d "$dir/.git" ]; then
    echo "==> $dir is a git clone, pulling"
    git -C "$dir" pull --ff-only || echo "warn: git pull failed, using $dir as is" >&2
  else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "==> downloading $repo"
    if ! fetch "$url" "$token" >"$tmp/repo.tgz"; then
      if [ -n "$token" ] || ! has_tty; then
        echo "error: download failed: $url (private repo? set GITHUB_TOKEN)" >&2
        exit 1
      fi
      printf 'Download failed; the repo may be private.\nGitHub token (hidden, blank to abort): ' >/dev/tty
      # Ctrl-C at the prompt must not leave the terminal without echo.
      tty_state="$(stty -g </dev/tty)"
      trap 'stty "$tty_state" </dev/tty 2>/dev/null; rm -rf "$tmp"' EXIT
      trap 'exit 130' INT TERM
      stty -echo </dev/tty
      IFS= read -r token </dev/tty || true
      stty "$tty_state" </dev/tty
      echo >/dev/tty
      [ -n "$token" ] || exit 1
      fetch "$url" "$token" >"$tmp/repo.tgz"
    fi
    mkdir "$tmp/src"
    tar -xzf "$tmp/repo.tgz" --strip-components=1 -C "$tmp/src"
    [ -f "$tmp/src/setup.sh" ] || { echo "error: no setup.sh in the download" >&2; exit 1; }
    # GitHub names the top folder <owner>-<repo>-<commit>; setup.sh prints it.
    top="$(tar -tzf "$tmp/repo.tgz" | head -n 1)"
    top="${top%/}"
    printf '%s@%s downloaded %s\n' "$repo" "${top##*-}" "$(date '+%Y-%m-%d %H:%M')" >"$tmp/src/.source"
    if [ -e "$dir" ]; then
      bak="$dir.bak.$(date +%Y%m%d_%H%M%S)"
      base="$bak" n=0
      while [ -e "$bak" ]; do n=$((n + 1)); bak="$base.$n"; done
      echo "==> moving the old $dir to $bak"
      mv "$dir" "$bak"
    fi
    mkdir -p "$(dirname "$dir")"
    mv "$tmp/src" "$dir"
  fi

  # Split SETUP_ARGS the same way in sh, bash and zsh.
  eval "set -- \"\$@\" ${SETUP_ARGS:-}"
  echo "==> $dir/setup.sh $*"
  # Piped (curl | sh): stdin is the script, so give setup.sh the terminal.
  if [ -t 0 ] || ! has_tty; then
    bash "$dir/setup.sh" "$@"
  else
    bash "$dir/setup.sh" "$@" </dev/tty
  fi

  # A child process cannot source ~/.bashrc into the shell that ran it, so
  # start a fresh interactive shell instead: it reads ~/.bashrc (or ~/.zshrc)
  # and the new aliases work at once. Skipped for a dry run, --select, --help,
  # with no terminal, or with BOOTSTRAP_NO_SHELL=1.
  for a in "$@"; do
    case "$a" in -n | --dry-run | --select | -h | --help) exit 0 ;; esac
  done
  [ "${BOOTSTRAP_NO_SHELL:-0}" != 1 ] || exit 0
  has_tty || exit 0
  shell="${SHELL:-/bin/bash}"
  command -v "$shell" >/dev/null 2>&1 || shell=bash
  echo "==> starting a new $(basename "$shell") so the new aliases load (exit returns to the old one)"
  exec "$shell" -i </dev/tty >/dev/tty 2>&1
)
