# Selectable Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user see, select and save what gets installed on Linux, macOS, WSL and native Windows, from one shared catalog.

**Architecture:** `catalog.txt` lists every item. Two engines read it: bash (`lib/catalog.sh`, `lib/menu.sh`) and PowerShell (`windows/lib.ps1`, `windows/menu.ps1`). Each shows the same menu, writes the same `key=value` config, and runs its platform's native install steps.

**Tech Stack:** bash 3.2+, Windows PowerShell 5.1+, ANSI escape codes, Scoop, shellcheck, Docker for existing suites.

**Spec:** `docs/superpowers/specs/2026-11-05-selectable-installer-design.md`

## Global Constraints

- No runtime dependencies: bash 3.2 on macOS, PowerShell 5.1 on Windows. No `mapfile`, no associative arrays, no fractional `read -t`, no `jq`, no Pester.
- This repo is public. No real usernames, personal paths, private IPs or personal emails. Use `$HOME`, `$env:USERPROFILE`, `%USERPROFILE%`. The repo's own public URL is the only exception.
- Nothing from the private source is staged until it passes `tests/test_repo.sh`.
- Config path: `~/.local/bootstrap/config`, `%USERPROFILE%\.local\bootstrap\config` on Windows.
- Config keys are `<group>.<item>`, values `0` or `1`. Files are written with LF, no BOM.
- Unticking never uninstalls.
- `./setup.sh --yes` with no saved config installs what it installs today.
- `.ps1` files must be ASCII or UTF-8 with BOM.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests must never touch the real Windows home or real Scoop. Pin `KERNEL_RELEASE_FILE` as `tests/test_setup.sh` already does.

## Review Focus

1. **Menu taller than the terminal.** Windows has about 20 rows and a small window may have fewer. The cursor row must stay visible through scrolling. Pinned in Tasks 4 and 7.
2. **Config edited in Notepad.** A UTF-8 BOM on the first line plus CRLF must not lose the first key or leave `\r` in values. Pinned in Tasks 3 and 6.
3. **Home path with spaces or non-ASCII characters.** Windows profile names often have them. Config save, WezTerm copy, startup shortcuts and `wslpath` must all work. Pinned in Tasks 3, 6 and 8.
4. **Missing or unwritable config.** `--config` pointing at a missing file with `--yes` stops with an error; interactive creates it on save. If saving fails, nothing installs. `~/.local` not existing is normal. Pinned in Tasks 3 and 5.
5. **`sudo ./setup.sh`.** The config would silently land in root's home. Warn and name the path used, without blocking root-only containers. Pinned in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `catalog.txt` | All selectable items. Replaces `packages/base.txt` |
| `lib/catalog.sh` | Bash catalog parsing, filtering, config read/write |
| `lib/menu.sh` | Bash menu: pure key handling, drawing, terminal restore |
| `setup.sh` | Entry point, modes, flags, step runner, install logic |
| `setup.ps1` | Windows entry point, modes, step dispatch |
| `windows/lib.ps1` | Section framework, `Get-ScoopRoot`, catalog, config |
| `windows/menu.ps1` | PowerShell menu |
| `windows/steps/*.ps1` | One file per install step |
| `configs/windows/` | Cleaned profile, hotkeys, VS Code extension list |
| `tests/test_repo.sh` | Privacy and encoding guards |
| `tests/test_windows.ps1` | PowerShell tests |
| `tests/fixtures/` | Shared catalog fixture and expected outputs |

---

### Task 1: Repo guards and the bash 3.2 fix

**Files:**
- Create: `tests/test_repo.sh`
- Modify: `setup.sh` (`login_shell`), `Makefile` (`SHELL_FILES`, `test`, `check`)

**Interfaces:**
- Produces: `bash tests/test_repo.sh [dir]` exits 0 when clean, 1 and prints `file:line` otherwise. Default dir is the repo root.

- [ ] **Step 1: Write the failing test.** `tests/test_repo.sh` scans `git ls-files` plus untracked non-ignored files, or every file under `[dir]`. Fail on: private IPv4 (`10.x`, `192.168.x`, `172.16-31.x`), emails outside `example.com`/`noreply@anthropic.com`, `[A-Z]:\Users\<word>`, `/home/<word>`, `/Users/<word>`; and any `.ps1` that is non-ASCII without a UTF-8 BOM. Placeholders in angle brackets (`<name>`) and `$USER`-style variables do not match. Add a `--self-test` mode that builds a temp dir with one violation of each kind and asserts each is reported, using strings assembled at runtime so the guard's own source stays clean.
- [ ] **Step 2: Run it.** `bash tests/test_repo.sh --self-test`. Expected: all kinds reported, exit 0. `bash tests/test_repo.sh`. Expected: clean, exit 0.
- [ ] **Step 3: Fix `login_shell`.** Replace `user="$(id -un)"` with `user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"`. Apply the same fallback where `setup_zsh_default` calls `id -un`.
- [ ] **Step 4: Wire into make.** `make test` also runs `tests/test_repo.sh --self-test` and `tests/test_repo.sh`. Add the file to `SHELL_FILES` coverage.
- [ ] **Step 5: Verify.** `make test` passes, `make test-bash32` exits 0.
- [ ] **Step 6: Commit** `test: add public repo guard and fix bash 3.2 run`.

### Task 2: Catalog and parser

**Files:**
- Create: `catalog.txt`, `lib/catalog.sh`, `tests/fixtures/catalog.txt`
- Modify: `setup.sh` (source lib, replace `read_packages`), `tests/test_setup.sh`, `README.md` ("Add more")
- Delete: `packages/base.txt`

**Interfaces:**
- Consumes: `pkg_name family pkg`
- Produces, in `lib/catalog.sh`, usable after `source`:
  - `catalog_load file platform wsl` (`platform` is `linux` or `macos`, `wsl` is `0` or `1`) fills parallel arrays `CAT_GROUP CAT_ITEM CAT_LABEL CAT_DEFAULT CAT_ACTION` with items for this platform. Calls `die` on a malformed line, naming the line number.
  - `catalog_key index` prints `<group>.<item>`.
  - `catalog_groups` prints unique groups in file order.
- `CATALOG_FILE` defaults to `${SCRIPT_DIR}/catalog.txt`.

- [ ] **Step 1: Write the failing tests.** Fixture has 8 lines covering `linux,macos`, `wsl`, `windows`, comments, blank lines. Assert: `catalog_load fixture linux 0` excludes `wsl` and `windows` rows; `linux 1` includes `wsl` rows; `macos 0` excludes both; `CAT_ACTION` keeps `scoop:main/cmder` intact; a line with 5 fields or a default of `maybe` dies with its line number; an unknown platform name in a row dies; a missing file dies.
- [ ] **Step 2: Run** `bash tests/test_setup.sh`. Expected: FAIL, `catalog_load` not found.
- [ ] **Step 3: Implement `lib/catalog.sh`** with `while IFS='|' read -r`, tolerating CRLF, using only bash 3.2 features.
- [ ] **Step 4: Write `catalog.txt`.** Every `base.txt` package moves to `shell`, `system`, `network` or `files` with `linux,macos|on|pkg`. Add:

  ```text
  configs|tmux|tmux config|linux,macos|on|step:configs
  configs|nanorc|nano config|linux,macos|on|step:configs
  configs|zshrc|zsh config|linux,macos|on|step:configs
  configs|aliases|Shell aliases|linux,macos|on|step:configs
  configs|bin|Helper scripts|linux,macos|on|step:configs
  tmux-plugins|tpm|TPM and plugins|linux,macos|on|step:tpm
  terminals|kitty|kitty|linux,macos|off|step:terminals
  terminals|ghostty|Ghostty|linux,macos|off|step:terminals
  terminals|wezterm-wsl|WezTerm on Windows|wsl|off|step:wezterm-wsl
  extras|ssh-server|OpenSSH server|linux,macos|off|step:ssh-server
  extras|ssh-key|SSH key|linux,macos|off|step:ssh-key
  extras|zsh-login|zsh as login shell|linux,macos|off|step:zsh-login
  terminals|wezterm|WezTerm|windows|off|step:wezterm
  terminals|cmder|Cmder|windows|off|scoop:main/cmder
  dev-tools|7zip|7-Zip|windows|on|scoop:main/7zip
  dev-tools|curl|curl|windows|on|scoop:main/curl
  dev-tools|rustup|rustup|windows|on|scoop:main/rustup
  win-setup|profile|PowerShell profile|windows|on|step:profile
  win-setup|vscode|VS Code + extensions|windows|off|step:vscode
  win-setup|flameshot|Flameshot + hotkey|windows|off|step:flameshot
  win-setup|hotkeys|AutoHotkey hotkeys|windows|off|step:hotkeys
  win-setup|wsl|WSL (Ubuntu)|windows|off|step:wsl
  ```

  Add `win-apps` rows, all `off`, as `scoop:<bucket>/<app>`, for: copyq, foxit-reader, greenshot, irfanview, screentogif, totalcommander, vlc (all `extras`).
- [ ] **Step 5: Replace `read_packages`** with `selected_packages family`, printing `pkg_name` output for `pkg` items. For now all items count as selected, so behaviour is unchanged. Delete `packages/base.txt` and `PACKAGE_LIST`. Update the tests and `tests/docker_matrix.sh` if they reference them. Update "Add more" in the README.
- [ ] **Step 6: Verify** `make test`. Then compare the package list printed by `UNAME_S=Linux ./setup.sh --dry-run --yes` with the non-comment lines of `git show HEAD:packages/base.txt`. Expected: same packages, same order.
- [ ] **Step 7: Commit** `feat: add shared install catalog`.

### Task 3: Config read and write

**Files:**
- Modify: `lib/catalog.sh`, `tests/test_setup.sh`
- Create: `tests/fixtures/config.input`, `tests/fixtures/config.expected`

**Interfaces:**
- Consumes: `catalog_load`, `catalog_key`, `backup_file`, `warn`
- Produces:
  - `config_default_path` prints `${TARGET_HOME}/.local/bootstrap/config`.
  - `config_load file` fills `CAT_SEL` (0/1, parallel to `CAT_ITEM`), `CAT_NEW` (1 when a config exists but omits the key) and `CONFIG_EXTRA` (raw `key=value` lines not in this platform's catalog). A missing file gives catalog defaults and all `CAT_NEW=0`.
  - `config_save file` returns non-zero on failure. Writes known keys in catalog order, then `CONFIG_EXTRA` sorted, under one header comment line.

- [ ] **Step 1: Write the failing tests.** Round trip keeps values. Unknown key survives a save. `shell.zsh=2`, `noequals` and `=1` each warn and use the default. **BOM on line 1 plus CRLF throughout: every key reads correctly with no `\r`.** A key missing from an existing config sets `CAT_NEW=1`. **Save to `"${WORK}/a b/.local/bootstrap/config"` creates parents and works with the space.** Saving over a file makes one `.bak.` file. **Saving into a read-only directory returns non-zero and leaves the old config intact** (skip when running as root). Output matches `tests/fixtures/config.expected` byte for byte.
- [ ] **Step 2: Run** `bash tests/test_setup.sh`. Expected: FAIL, `config_load` not found.
- [ ] **Step 3: Implement.** Strip `$'\xEF\xBB\xBF'` from line 1 and a trailing `\r` from each line. Save with `mkdir -p`, write `${file}.tmp.$$`, then `mv`. Honour `DRY_RUN` by not writing.
- [ ] **Step 4: Verify** `make test` passes.
- [ ] **Step 5: Commit** `feat: read and write the saved selection`.

### Task 4: Bash menu

**Files:**
- Create: `lib/menu.sh`
- Modify: `tests/test_setup.sh`

**Interfaces:**
- Consumes: `CAT_*` arrays, `catalog_groups`
- Produces:
  - `menu_handle_key key` updates globals `MENU_CURSOR MENU_OPEN_GROUP MENU_TOP MENU_RESULT`. Keys are the tokens `up down space enter continue quit back`. `MENU_RESULT` becomes `continue` or `quit`.
  - `menu_read_key` prints one token. Reads with `read -rsn1`, then for ESC reads up to two more bytes with `read -rsn2 -t 1` (integer timeout for bash 3.2). Lone ESC is `back`.
  - `menu_run` returns 0 on continue, 1 on quit. Draws to `/dev/tty`.
  - `menu_available` returns 0 when stdin and stdout are terminals and `TERM` is not `dumb` or empty.

- [ ] **Step 1: Write the failing tests** against `menu_handle_key` with the fixture catalog: `down` moves, stops at the end; `space` on a group toggles all its items, on a partly-selected group selects all; `enter` opens a group, `back` closes it; `space` inside toggles one item and updates the `n/m selected` text from `menu_group_summary group`; `continue` and `quit` set `MENU_RESULT`. **With `MENU_ROWS=5` and 20 rows, moving down past row 5 advances `MENU_TOP`, and the cursor is always within `MENU_TOP` and `MENU_TOP+MENU_ROWS-1`.**
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Rows per screen come from `stty size </dev/tty`, default 24, minus 4 for header and footer. Single-item groups (such as `tmux-plugins`) toggle on `enter` instead of opening. Mark `CAT_NEW` items `new`. Save `stty -g`, hide the cursor, and restore both through `trap ... EXIT INT TERM`.
- [ ] **Step 4: Add a pseudo-terminal test.** Run a small driver under `script -qec` feeding keys through a FIFO: `down`, `space`, `c`. Assert the selection changed and `stty` state is restored. Skip with `SKIP` when `script` is missing, which is the case in the bash 3.2 image.
- [ ] **Step 5: Verify** `make test` and `make test-bash32`.
- [ ] **Step 6: Commit** `feat: add terminal selection menu`.

### Task 5: `setup.sh` run flow

**Files:**
- Modify: `setup.sh`, `Makefile`, `tests/test_setup.sh`, `tests/docker_matrix.sh`, `README.md`

**Interfaces:**
- Consumes: Tasks 2 to 4.
- Produces:
  - `run_step label fn [args...]`: `set +e; ( set -e; "$fn" "$@" ); rc=$?; set -e`, then records `STEP_LABELS`/`STEP_STATUS`.
  - `print_summary` prints the table and returns 1 if any step failed.
  - `print_plan` prints install, change and skip lines.
  - `item_selected key` returns 0 when ticked.
  - `apply_flag_overrides` applies flags to `CAT_SEL` for this run.
  - New globals `SELECT_ONLY`, `CONFIG_FILE`, `FLAGS_USED`.

- [ ] **Step 1: Write the failing tests** with step functions stubbed:
  - Selection: `--yes` with no config matches catalog defaults; a saved `configs.tmux=0` skips only tmux.
  - Flags: `--terminal` selects every `terminals` row for the platform and doesn't save; passing any selection flag leaves `menu_run` uncalled; `--no-packages` clears `pkg` items; `--no-configs` clears `step:configs` and `step:tpm`.
  - Modes: `--dry-run` writes no config; `--select` with no terminal exits non-zero; `--select` runs no install step; **`--yes --config /missing` exits non-zero before any step; an unwritable config path exits non-zero before any step.**
  - Failures: a failing stub doesn't stop later stubs, the summary shows `FAILED`, exit is 1.
  - SSH: saved `extras.ssh-key=1` with no terminal skips with a warning; `--ssh-key` creates it.
  - zsh: saved `extras.zsh-login=1` applies under `--yes`.
  - **Root: `EUID=0` with `SUDO_USER` set prints a warning naming the config path; the run continues.**
  - WSL: `terminals.wezterm-wsl=1` calls the Scoop stub; plain Linux doesn't.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement flags and `main`.** Add `--select` and `--config <file>`. Set `FLAGS_USED=1` for the nine selection flags. Flow: load, warn if sudo, `menu_available && !ASSUME_YES && !DRY_RUN && !FLAGS_USED` then menu, plan, confirm, save (a failed save dies), then steps. `q` exits 0 with no save.
- [ ] **Step 4: Split steps.** Make `install_configs` honour `configs.*`, and split out `install_tpm` as `step:tpm`. Make `install_terminal_packages` and `install_terminal_configs` take selected items. Call `ensure_brew` in the main shell before any step on macOS. Move the WSL WezTerm function to `step:wezterm-wsl`.
- [ ] **Step 5: Remove the prompts** from `setup_terminals`, `setup_ssh_key` and `setup_zsh_default`, plus the `TERMINAL_MODE`, `SSH_KEY_MODE` and `ZSH_DEFAULT_MODE` ask paths. Replace the old prompt tests. Update `usage`, the Makefile `install-yes` text and the README's Terminals, SSH key and Login shell sections.
- [ ] **Step 6: Verify** `make check`, `make test-bash32`, `make test-docker`. Expected: all pass. `./setup.sh --dry-run --yes` shows today's package list.
- [ ] **Step 7: Commit** `feat: drive setup.sh from the saved selection`.

### Task 6: PowerShell framework, catalog and config

**Files:**
- Create: `windows/lib.ps1`, `tests/test_windows.ps1`
- Modify: `Makefile` (`test-windows`, PowerShell parse in `lint`), `tests/test_setup.sh`

**Interfaces:**
- Produces, dot-sourced from `windows/lib.ps1`:
  - `Get-ScoopRoot` returns a path string.
  - `Import-Catalog -Path <string>` returns objects `{Group, Item, Label, Default, Action, Key, Selected, New}` for `windows` rows. Throws on a malformed line, naming the line number.
  - `Import-Selection -Path <string> -Catalog <object[]>` sets `Selected` and `New`, returns extra lines as `string[]`.
  - `Save-Selection -Path <string> -Catalog <object[]> -Extra <string[]>` writes atomically with LF, no BOM, and a `.bak.` copy.
  - Ported unchanged from the source framework: `Write-Check`, `Invoke-WithRecovery`, `Add-Result`, `Show-Summary`, `Update-SessionPath`, `Test-Command`, `Test-WslPath`, logging helpers.
  - `Invoke-Section -Name -Pre [-Do] [-Post] [-MaxPasses] [-Verify]`: the source version without `-Question`, `-Yes` or `Confirm-Step`.

- [ ] **Step 1: Write the failing tests.** `tests/test_windows.ps1` has a `Check $name $want $got` helper and exits non-zero on failure. Assert: catalog filtering; malformed line throws; bad config values warn and use defaults; **BOM plus CRLF config reads every key; a save under `$env:TEMP\a b\é\.local\bootstrap\config` works**; unknown keys survive; `Get-ScoopRoot` prefers `$env:SCOOP`, then the `scoop` command's location, then `%USERPROFILE%\scoop`.
- [ ] **Step 2: Add the cross-engine check** in `tests/test_setup.sh`: when `powershell.exe` exists, load `tests/fixtures/config.input` in both engines and require both saved files to equal `tests/fixtures/config.expected` byte for byte. Skip otherwise. Note that WSL paths must go through `wslpath -w`.
- [ ] **Step 3: Run** `make test-windows`. Expected: FAIL.
- [ ] **Step 4: Implement.** Port the framework from the private source, removing prompts. Write with `[IO.File]::WriteAllText(path, text, [Text.UTF8Encoding]::new($false))`, because `Set-Content -Encoding UTF8` writes a BOM on PowerShell 5.1. Keep the file ASCII.
- [ ] **Step 5: Add make targets.** `test-windows` runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w tests/test_windows.ps1)"`. `lint` parses every `.ps1` with `[Parser]::ParseFile` when `powershell.exe` exists.
- [ ] **Step 6: Verify** `make test-windows`, `make test`. Only PowerShell 5.1 is available here, so state that 7 was not run.
- [ ] **Step 7: Commit** `feat: add PowerShell framework, catalog and config`.

### Task 7: PowerShell menu

**Files:**
- Create: `windows/menu.ps1`
- Modify: `tests/test_windows.ps1`

**Interfaces:**
- Consumes: `Import-Catalog` objects.
- Produces:
  - `Update-MenuState -State <hashtable> -Key <string>`: same tokens and behaviour as `menu_handle_key`. State keys are `Cursor`, `OpenGroup`, `Top`, `Rows`, `Result`.
  - `Test-MenuAvailable` returns false when input is redirected or the host has no real console.
  - `Show-Menu -Catalog <object[]>` returns `'continue'` or `'quit'`.

- [ ] **Step 1: Write the failing tests** mirroring Task 4's key tests, **including `Rows=5` with 20 rows keeping the cursor visible**. Items with `New` set show the `new` marker in the row text from `Format-MenuRow -Row <object>`.
- [ ] **Step 2: Run** `make test-windows`. Expected: FAIL.
- [ ] **Step 3: Implement** with `[Console]::ReadKey($true)`, ANSI-free redraw through `[Console]::SetCursorPosition` (PowerShell 5.1 consoles may lack VT support), and `Rows` from `[Console]::WindowHeight`. `try/finally` restores `CursorVisible`.
- [ ] **Step 4: Verify** `make test-windows`.
- [ ] **Step 5: Commit** `feat: add PowerShell selection menu`.

### Task 8: Windows steps and `setup.ps1`

**Files:**
- Create: `setup.ps1`, `windows/steps/{preflight,scoop,vscode,flameshot,wsl,wezterm}.ps1`, `configs/windows/vscode_extensions.txt`
- Modify: `tests/test_windows.ps1`, `README.md`, `Makefile` (`windows`)

**Interfaces:**
- Consumes: Tasks 6 and 7.
- Produces:
  - `setup.ps1 [-Yes] [-DryRun] [-Select] [-Config <path>] [-Verify]`.
  - Each step file takes `[string[]]$Items` and `[switch]$Verify`, except `scoop.ps1`, which takes `[object[]]$Apps` with `Bucket` and `Name`.

- [ ] **Step 1: Write the failing tests** with `scoop` stubbed as a PowerShell function: `scoop.ps1` installs ticked apps only and adds only their buckets; `git` and `make` are always installed; `wezterm.ps1` copies to a home containing a space; `setup.ps1 -DryRun` writes no config and runs no step; `-Verify` runs only the pre-checks of selected items and changes nothing; `-Select` with redirected input errors; `-Yes -Config <missing>` errors before any step; a failing step doesn't stop later ones and exit is 1; running elevated stops when Scoop is missing.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Port the steps** from the private source. Replace every hardcoded Scoop path with `Get-ScoopRoot`. Remove `-Yes` and `-Question`. `preflight.ps1` validates the catalog instead of the JSON list. `vscode.ps1` reads `configs/windows/vscode_extensions.txt`.
- [ ] **Step 4: Add `wezterm.ps1`.** `scoop install extras/wezterm`, then copy `configs/wezterm/windows.lua` to `$env:USERPROFILE\.wezterm.lua` with a backup when it differs.
- [ ] **Step 5: Write `setup.ps1`.** Same flow as Task 5. Install Scoop from `get.scoop.sh` when missing, unless elevated. Run preflight first and stop if it fails. Add the one-line zip download to the README, using the public repo URL.
- [ ] **Step 6: Add `make windows`,** which runs `setup.ps1` through `powershell.exe` with `wslpath -w` and `$(ARGS)`.
- [ ] **Step 7: Verify** `make test-windows`, `bash tests/test_repo.sh`, and `powershell.exe ... setup.ps1 -DryRun` from WSL. Expected: Scoop found at its real non-default root, no apps reported missing because of the path.
- [ ] **Step 8: Commit** `feat: add native Windows installer`.

### Task 9: PowerShell profile and hotkeys

**Files:**
- Create: `configs/windows/Microsoft.PowerShell_profile.ps1`, `configs/windows/hotkeys/my_hotkeys.ahk`, `configs/windows/hotkeys/personal.ahk.example`, `windows/steps/profile.ps1`, `windows/steps/hotkeys.ps1`
- Modify: `tests/test_windows.ps1`

**Interfaces:**
- Consumes: Task 8's step contract.

Do the cleanup in the scratchpad first. Copy into the repo only after Step 2 passes.

- [ ] **Step 1: Clean the profile.** Remove the `ssh1` function and the fixed host list inside `Check-IpHosts` (make it take hosts as arguments, or remove it). Rewrite lines 1 to 12 so the header names no private files. Read the whole file for other personal hosts, paths and employer names. Save with a UTF-8 BOM, because it contains box-drawing characters.
- [ ] **Step 2: Clean the hotkeys.** Read all of `my_hotkeys.ahk`. Remove or generalise anything personal. Change the defaults to `"Terminal", "wezterm-gui.exe"` and `"TerminalExe", "wezterm-gui.exe"`. **Change the Ctrl+Alt+T handler, because `wt`'s `-d` flag is not valid for WezTerm:** use `wezterm-gui.exe start --cwd "<path>"`. Keep it working when `settings.ini` still names `wt.exe`, by choosing the arguments from the configured terminal. Check that the Windows Terminal dimming block near line 133 doesn't depend on the default. Run `bash tests/test_repo.sh <scratch dir>`. Expected: clean.
- [ ] **Step 3: Write the failing tests.** The profile parses with no errors; `hotkeys.ps1` always targets `%USERPROFILE%\ahk`, including when the repo is on a local drive; `personal.ahk` is created from the example only if missing and an existing one is never overwritten.
- [ ] **Step 4: Run.** Expected: FAIL.
- [ ] **Step 5: Add the files and port both steps.** `hotkeys.ps1` uses `Get-ScoopRoot` for the AutoHotkey path. Startup shortcuts must work when the home path has spaces.
- [ ] **Step 6: Verify** `make test-windows`, `make check`, then review the staged diff for personal data by eye as well as by guard.
- [ ] **Step 7: Commit** `feat: add PowerShell profile and hotkeys`.

### Task 10: Docs and final verification

**Files:**
- Modify: `README.md`, `setup.sh` (header comment)

- [ ] **Step 1: Update the README.** Cover the menu, config path, modes table, Windows quick start, catalog format and the rule that unticking never uninstalls. Remove the outdated "Linux or macOS" wording. Update the `setup.sh` header. `usage` prints lines 2 to 15, so keep that range correct.
- [ ] **Step 2: Run everything.** `make test-all`, `make test-windows`, `bash tests/test_repo.sh`. Expected: all pass. Record any skipped test.
- [ ] **Step 3: Commit** `docs: describe the selectable installer`.
- [ ] **Step 4: Report the manual checks** from the spec as not done: PowerShell menu in a real console, a real Windows install (needs the owner's OK), Windows Sandbox fresh install, the menu on a real Mac, and PowerShell 7.
