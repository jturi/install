#!/usr/bin/env bash
# tmuxhelp — print the tmux quick-reference section from ~/.tmux.conf.
# Usage: tmuxhelp [OPTIONS] [SEARCH_TEXT]
#   No args: print the whole block from TMUX CONFIGURATION START to TMUX CONFIGURATION END.
#   With args: fuzzy-search that block with fzf (prefilled with SEARCH_TEXT);
#              falls back to grep -i when fzf is missing or stdout is not a TTY.
# Options:
#   -a, --all    Print the whole ~/.tmux.conf instead of just the marked section.
#   -h, --help   Show this help.
set -euo pipefail

usage() {
  sed -n '2,9p' "$0"
}

CONF="${HOME}/.tmux.conf"
START_MARKER="TMUX CONFIGURATION START"
END_MARKER="TMUX CONFIGURATION END"
show_all=0
args=()

for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    -a|--all) show_all=1 ;;
    *) args+=("$a") ;;
  esac
done

if [[ ! -f "$CONF" ]]; then
  printf 'tmuxhelp: not found: %s\n' "$CONF" >&2
  exit 1
fi

# Strip the leading "# " comment markers and decoration-only lines
# (====, ----, #### runs) so the quick-ref reads cleanly; squeeze blanks.
clean() {
  sed -e 's/^#[[:space:]]\{0,1\}//' \
      -e '/^[=#-]\{3,\}$/d' | cat -s
}

if [[ $show_all -eq 1 ]]; then
  section="$(cat "$CONF")"
else
  section="$(sed -n "/${START_MARKER}/,/${END_MARKER}/p" "$CONF")"
  if [[ -z $section ]]; then
    printf 'tmuxhelp: markers %q..%q not found in %s\n' "$START_MARKER" "$END_MARKER" "$CONF" >&2
    exit 1
  fi
fi
section="$(printf '%s\n' "$section" | clean)"

# No search text: print everything.
if [[ ${#args[@]} -eq 0 ]]; then
  printf '%s\n' "$section"
  exit 0
fi

query="${args[*]}"

# Interactive fzf search when possible (prefill with the given text so the
# user can refine; ESC aborts without error).
if command -v fzf >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
  printf '%s\n' "$section" | fzf --query="$query" --prompt='tmuxhelp> ' --height 60% --reverse || true
  exit 0
fi

# Non-interactive / no-fzf fallback: case-insensitive fixed-string filter.
printf '%s\n' "$section" | grep -i -F -- "$query" || true
