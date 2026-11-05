# Selectable installer: design

## Goal

Let the user see and choose what will be installed, and remember that choice
in a config file, on Linux, macOS, WSL and native Windows.

Success means:

- One menu shows everything that can be installed, grouped, with drill-down to
  single items.
- The selection is saved to `~/.local/bootstrap/config`
  (`%USERPROFILE%\.local\bootstrap\config` on Windows) and reused on later runs.
- Native Windows is a supported platform, through a PowerShell entry point
  ported from a private Windows setup, with no personal data in this repo.
- A fresh machine needs nothing beyond what it ships with: bash 3.2 on macOS,
  PowerShell 5.1 on Windows.
- `./setup.sh --yes` with no saved config installs what it installs today.

## Non-goals

- Uninstalling. An unticked item is left alone, never removed.
- Ansible, Python or any other runtime dependency. Ansible was considered and
  rejected: it has no native Windows control node, needs bootstrapping first,
  and would not replace the menu.
- Managing remote machines.
- Running `setup.sh` under Git Bash. Windows means `setup.ps1`.

## Architecture

A shared plain-text catalog is read by two small engines, one in bash and one
in PowerShell. Each engine has its own menu and config reader. Install logic
stays native to each platform.

```text
catalog.txt              every selectable item; replaces packages/base.txt
setup.sh                 Linux/macOS/WSL entry point and install logic
setup.ps1                Windows entry point
lib/catalog.sh           bash catalog and config read/write
lib/menu.sh              bash menu
windows/lib.ps1          section framework, catalog and config
windows/menu.ps1         PowerShell menu
windows/steps/*.ps1      preflight, scoop, profile, vscode, flameshot,
                         hotkeys, wsl, wezterm
configs/windows/         PowerShell profile, hotkeys, VS Code extensions
configs/wezterm/         WezTerm config
tests/test_windows.ps1   PowerShell tests
tests/fixtures/          shared fixture for both engines
```

`curl | tar`, the zip download and `git clone` all fetch the whole repo, so
`setup.sh` can source `lib/` safely.

## Catalog

`catalog.txt` is pipe-separated. Blank lines and lines starting with `#` are
ignored:

```text
# group|item|label|platforms|default|action
shell|zsh|zsh|linux,macos|on|pkg
terminals|ghostty|Ghostty|linux,macos|off|step:terminals
terminals|wezterm-wsl|WezTerm on Windows|wsl|off|step:wezterm-wsl
terminals|wezterm|WezTerm|windows|off|step:wezterm
terminals|cmder|Cmder|windows|off|scoop:main/cmder
win-apps|vlc|VLC|windows|off|scoop:extras/vlc
win-setup|flameshot|Flameshot + hotkey|windows|off|step:flameshot
```

- `platforms` is a comma list of `linux`, `macos`, `wsl`, `windows`. WSL matches
  both `linux` and `wsl`.
- `default` is `on` or `off`.
- `action` is one of:
  - `pkg`: passed through the existing `pkg_name` distro mapping. An item that
    maps to nothing, such as `less` on macOS, is hidden from the menu.
  - `scoop:<bucket>/<app>`: installed by the Windows scoop step, which adds the
    bucket first when needed.
  - `step:<name>`: runs a named step once. Several items may share a step, and
    the step is told which of its items are selected.

### Groups

Linux, macOS and WSL:

- Shell and editors, System, Network, Files: the four groups of `base.txt`
- Configs: tmux, nano, zsh, aliases, helper scripts
- tmux plugins
- Terminals: kitty, Ghostty, and WezTerm on Windows under WSL only
- Extras: OpenSSH server, SSH key, zsh as login shell

Windows:

- Dev tools: 7zip, curl, rustup
- Apps: the remaining Scoop apps
- Terminals: WezTerm, Cmder
- Windows setup: PowerShell profile, VS Code with extensions, Flameshot,
  hotkeys, WSL

KiTTY, the PuTTY fork in the source Scoop list, is dropped.

### Defaults

- On: all base packages, shell configs, tmux plugins, Windows dev tools and the
  PowerShell profile.
- Off: personal desktop apps, hotkeys, terminals, SSH server, SSH key, zsh as
  login shell.

Three Windows items are not selectable: preflight always runs, and `git` and
`make` always install, because Scoop buckets need `git`. Flameshot, AutoHotkey
and VS Code are installed by their own steps, so they are not also plain Scoop
items.

## Config file

```text
# ~/.local/bootstrap/config
shell.zsh=1
win-apps.vlc=0
terminals.wezterm=1
```

- Keys are `<group>.<item>`, values `0` or `1`.
- Both engines accept LF and CRLF.
- Keys that are not in the catalog, or not for this platform, are kept on write,
  so a config can move between machines.
- A malformed line gives a warning and is ignored. The item uses its catalog
  default.
- Saving writes a temp file in the same directory and renames it over the
  config. The previous config is backed up as `<file>.bak.YYYYmmdd_HHMMSS`.
- WSL and Windows have separate home directories, so they keep separate configs.

## Run flow

1. Detect the platform. Load the catalog and any saved config.
2. Show the menu, ticked from the saved config or from catalog defaults. When a
   config exists, items it does not mention are marked `new`.
3. Show the plan: what will be installed, changed and skipped.
4. On confirmation, save the config, then install.

### Modes

| Run | Menu | What gets installed |
|---|---|---|
| Interactive, in a terminal | Yes | What the user confirms |
| `--yes`, or no terminal | No | Saved config, else catalog defaults |
| `--dry-run` | No | Nothing. Prints the plan and writes nothing, including the config |
| `--select` | Yes | Nothing. Saves the selection only |
| `--config <file>` | As above | Reads and saves that file instead of the default path |

The PowerShell equivalents are `-Yes`, `-DryRun`, `-Select`, `-Config` and
`-Verify`. `-Verify` runs the read-only checks for selected items.

`--select` with no terminal stops with an error, because there is nothing to
show the menu on.

Existing flags (`--terminal`, `--no-terminal`, `--no-packages`, `--no-configs`,
`--ssh-server`, `--ssh-key`, `--no-ssh-key`, `--zsh-default`,
`--no-zsh-default`) keep working. Passing any of them skips the menu: the run
uses the saved config or catalog defaults, with the flags applied on top, and
the flags are never saved. This keeps `make` targets such as `make terminals`
as one-shot commands. `--terminal` selects every item in the Terminals group for
the current platform.

A new `make windows` runs `setup.ps1` from WSL through `powershell.exe`.

The separate terminal, SSH key and zsh prompts are removed. They become menu
items.

### Safety rules

- A saved SSH key selection creates a key only when a terminal is present, so
  that `ssh-keygen` can ask for a passphrase. Without a terminal, the key is
  skipped with a warning unless `--ssh-key` was passed.
- A saved zsh login shell selection is applied under `--yes`. This is a
  deliberate change from today, where `--yes` never changes the shell.

## Menu

Arrow keys move, space toggles, enter opens a group, `c` continues, `q` quits
without saving. Group rows show a selected count, such as `12/14 selected`.

- Bash uses `read -rsn1` and ANSI escape codes only. PowerShell uses
  `[Console]::ReadKey`.
- `TERM=dumb`, or a PowerShell host with no real console, counts as no terminal.
- Key handling is a pure function of state and key, so it can be tested without
  a terminal.

## Windows port

The source is a private set of PowerShell steps. Each section keeps its life
cycle: pre-check, apply, post-check, summary. A failed section does not block
later ones, and retries stay in `Invoke-WithRecovery`.

Changes from the source:

- Per-section `y/N` prompts are removed. The menu has already answered them.
- The fresh-machine script becomes a one-line command that downloads this repo's
  zip, extracts it to `~/install` and runs `setup.ps1` with
  `-ExecutionPolicy Bypass`. The private clone and the `gh` login are removed.
- `Get-ScoopRoot` replaces every hardcoded Scoop path. It tries `$env:SCOOP`,
  then the location of the `scoop` command, then `%USERPROFILE%\scoop`.

| Step | Change |
|---|---|
| preflight | Always runs; validates the catalog |
| scoop | Installs ticked items only, adding the buckets they need |
| profile | Same copy to the PowerShell 5 and 7 paths with backups, from the cleaned file |
| vscode, flameshot, wsl | Same logic, using `Get-ScoopRoot`; no prompts |
| hotkeys | Always copies to `%USERPROFILE%\ahk`; `personal.ahk` never lives in the repo |
| wezterm | New: installs through Scoop and copies `configs/wezterm/windows.lua` |
| export-scoop | Dropped; the catalog replaces it |

The hotkey script's default terminal changes from `wt.exe` to `wezterm-gui.exe`.
`settings.ini` can still override it.

### Excluded from the port

- The WSL image build scripts: they are employer-specific and hold credentials.
- Long-form notes files.
- One-off machine scripts, such as browser, firewall and Windows Update changes.
- `dow_add-units.ahk`, unless the user asks for it.

### Public repo rules

This repo is public. Nothing from the private source is committed until it is
clean:

- The PowerShell profile loses its personal SSH shortcut and its private IP list,
  and gets generic directory jumps and a rewritten header.
- `my_hotkeys.ahk` is read line by line before it is added.
- No real usernames or personal paths. Use `$HOME`, `$env:USERPROFILE` and
  `%USERPROFILE%`. The repo's own public URL is the one exception.

A guard test fails on a private IPv4 address, a non-example email address, or a
real `C:\Users\<name>` or `/home/<name>` path. It matches patterns, so it holds
no personal values itself. It runs in `make check`.

## Error handling

`setup.sh` changes from stopping at the first error to running every selected
step, printing a summary table, and exiting 1 if any step failed.

`set -e` is disabled inside a function called with `||`, so each step runs in its
own subshell with `set -e` on, and the parent reads its status. Subshells lose
environment changes, so `ensure_brew` runs in the main shell before any step.

| Case | Behaviour |
|---|---|
| Catalog missing or malformed | Stop before changing anything |
| Bad line in the saved config | Warn; use the catalog default for that item |
| `q` in the menu | Save nothing, install nothing, exit 0 |
| Ctrl+C in the menu | Restore cursor and terminal settings, using `trap` in bash and `try/finally` in PowerShell |
| Interrupted during install | Config is already saved; a rerun skips finished work |
| Scoop run elevated | Stop with a clear message |
| WSL needs a reboot | `WARN` in the summary, not a failure |

## Testing

- **Bash:** `tests/test_setup.sh` adds catalog parsing, platform filtering, config
  round trips, unknown-key preservation, bad lines and flag overrides. Key
  handling is tested as a pure function, and one test drives the real menu
  through a pseudo-terminal.
- **PowerShell:** `tests/test_windows.ps1` uses the same pass/fail style with
  stubbed `scoop` commands and no Pester dependency. `make test-windows` runs it
  from WSL. `make lint` parses every `.ps1` file when PowerShell is available.
- **Cross-engine:** both engines read `tests/fixtures/` and must produce identical
  filtered lists and identical config files, including from CRLF input.
- **Encoding:** every `.ps1` file must be ASCII or UTF-8 with a BOM, because
  Windows PowerShell 5.1 misreads UTF-8 without a BOM.
- **Privacy guard:** see Public repo rules.
- **Existing suites:** the Docker distro matrix and bash 3.2 tests must pass. The
  existing `id: unknown ID 1000` failure in `make test-bash32` is fixed so the
  target completes.

### Manual checks

These cannot run in automated tests here:

- The PowerShell menu in a real console.
- A real Windows install, which changes the machine and needs the owner's OK.
- A fresh Windows machine, through Windows Sandbox.
- The menu on a real Mac. macOS gets bash 3.2 and dry-run coverage only.

## Migration

No action is needed. With no config file, a run uses catalog defaults, and base
packages stay on. `packages/base.txt` is removed, and the README's "Add more"
section describes adding a catalog line.
