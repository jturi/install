# install

Bootstrap a new Linux, macOS or Windows machine. On Linux and macOS,
`setup.sh` installs the basic packages and copies the base configs (configs come
from the [dotfiles](../dotfiles) repo). On Windows, `bootstrap.ps1` installs
Scoop and the Windows apps from `catalog.txt`.

## Quick start

Each script downloads this repo to `~/install` and runs the installer. If
`~/install` already exists, it is moved to `~/install.bak.<timestamp>` first.
A git clone there is pulled instead (Linux and macOS only).

### Linux and macOS

Paste into a terminal (bash or zsh):

```sh
curl -fsSL https://raw.githubusercontent.com/jturi/install/main/bootstrap.sh | sh
```

No curl (minimal Debian/Ubuntu)? Use `wget -qO- <same URL> | sh`. To pass
`setup.sh` options, set `SETUP_ARGS`:

```sh
curl -fsSL https://raw.githubusercontent.com/jturi/install/main/bootstrap.sh | SETUP_ARGS="--yes" sh
```

You can also paste the whole of [`bootstrap.sh`](bootstrap.sh) into a terminal.
It runs in a subshell, so it can't close your shell.

### Windows

Paste into a normal PowerShell window, not one run as Administrator (Scoop
refuses elevated installs):

```powershell
irm https://raw.githubusercontent.com/jturi/install/main/bootstrap.ps1 | iex
```

You can also paste the whole of [`bootstrap.ps1`](bootstrap.ps1) into PowerShell.
See [Windows](#windows) for what it does and its options.

### Private repo

While the repo is private, the one-liners need a GitHub token with read access
to it:

```sh
export GITHUB_TOKEN=<token>
curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" https://raw.githubusercontent.com/jturi/install/main/bootstrap.sh | sh
```

```powershell
$env:GITHUB_TOKEN = '<token>'
irm -Headers @{ Authorization = "Bearer $env:GITHUB_TOKEN" } https://raw.githubusercontent.com/jturi/install/main/bootstrap.ps1 | iex
```

To download the repo, the scripts use `GITHUB_TOKEN` if it is set, then
`gh auth token` if `gh` is logged in. If neither works, they ask for a token
when the download fails. A pasted copy of the script needs no token to start.

### Clone instead

```sh
git clone https://github.com/jturi/install.git ~/repos/install
cd ~/repos/install
./setup.sh            # asks once, then installs packages + configs
./setup.sh --dry-run  # show what would run, change nothing
```

Options: `-n/--dry-run`, `-y/--yes`, `--select`, `--config FILE`, `--no-packages`, `--no-configs`,
`--terminal`, `--no-terminal`, `--ssh-server`, `--ssh-key`, `--no-ssh-key`,
`--zsh-default`, `--no-zsh-default`, `--debug`, `--no-log`, `-h/--help`.

Run it as your normal user. The script uses `sudo` for the package manager
only. It runs as root without `sudo` when you are root.

## Reruns, logs and safety

Run it as often as you like; a second run changes nothing.

- **Idempotent.** Installed packages are checked first (`pacman -Q`,
  `dpkg-query`, `rpm -q`, `brew list`). If nothing is missing, the package
  manager doesn't run at all: no sudo, no network. A config identical to the repo
  file is left alone, and an existing SSH key, TPM or login shell is kept.
- **Verbose.** Each step prints a header, and each command that changes the
  machine is printed (`$ cmd`) before it runs. `--dry-run` prints the same
  commands without running them. `--debug` traces every shell line (`set -x`).
  The summary shows each step with its time and `OK`, `WARN` (with the warning
  text) or `FAILED`.
- **Logged.** Every real run is copied to
  `~/.local/bootstrap/logs/setup-<time>.log`, and the newest 20 logs are kept.
  `--no-log` turns this off. The first line names the version: the git commit,
  or the commit `bootstrap.sh` downloaded (saved in `.source`).
- **Failsafe.**
  - A failed step doesn't stop the next one. The exit code is 1 only if a step
    failed, so a rerun retries.
  - If a batch package install fails (apt and dnf fail the whole batch for one
    bad name), each package is retried alone and the failures are named.
  - apt waits up to 5 minutes for the dpkg lock, which `unattended-upgrades`
    holds on a fresh Ubuntu. Package lists are refreshed only when they are
    older than 6 hours.
  - Configs are written to a temp file and renamed into place, so an interrupted
    run never leaves a half-written `.zshrc`. Every changed file is backed up
    first (`<file>.bak.<time>`, with a counter if one exists).
  - sudo is checked once before the first step and kept valid until the end, so
    a long install never stops halfway for a password.
  - A lock (`~/.local/bootstrap/lock`) stops two runs at once. A lock left by a
    killed run is taken over.
  - `sh setup.sh` re-runs itself under bash.
- **Arch:** packages install with `pacman -Syu --needed`, because Arch doesn't
  support partial upgrades (`-Sy` alone). So when something is missing, the run
  also upgrades the system.

## Windows

`bootstrap.ps1` runs on the Windows PowerShell 5.1 that ships with Windows. It:

1. Stops if PowerShell runs as Administrator.
2. Downloads the repo to `~\install`.
3. Hands off to `setup.ps1` if the repo has one (the planned menu installer,
   see `docs/superpowers/specs/`). It doesn't exist yet, so steps 4 to 6 run.
4. Sets the CurrentUser execution policy to `RemoteSigned` if it is
   `Undefined`, `Restricted` or `AllSigned`, then installs
   [Scoop](https://scoop.sh) if it is missing.
5. Installs `git` with Scoop. Scoop needs it to add buckets.
6. Installs every `windows` item in `catalog.txt` that is `on` by default
   (7-Zip, curl, rustup), adding Scoop buckets as needed. `WezTerm` also
   copies `configs/wezterm/windows.lua` to `~\.wezterm.lua`, backing up a
   different file first. Steps that need `setup.ps1` (PowerShell profile,
   VS Code, Flameshot, hotkeys, WSL) print a warning and are skipped.

Reruns are safe. An installed Scoop app shows `SKIP`, an unchanged
`.wezterm.lua` is left alone, and a failed `scoop` command is retried once. A
failed item doesn't stop the rest. The run ends with an
`OK`/`SKIP`/`WARN`/`FAILED` summary, and a log goes to
`~\.local\bootstrap\logs\bootstrap-<time>.log`.

Options are environment variables, set before running the script:

| Variable | Does |
|----------|------|
| `INSTALL_ITEMS` | Comma list of extra catalog items, e.g. `wezterm,vlc`. `-rustup` drops a default. `all` selects every Windows item |
| `INSTALL_DRYRUN` | `1`: download only, print the Scoop commands |
| `INSTALL_DIR` | Where the repo goes (default `~\install`) |
| `GITHUB_TOKEN` | Token for the private repo |

```powershell
$env:INSTALL_ITEMS = 'wezterm,vlc,greenshot'
irm https://raw.githubusercontent.com/jturi/install/main/bootstrap.ps1 | iex
```

`bootstrap.sh` takes `INSTALL_DIR`, `SETUP_ARGS` and `GITHUB_TOKEN` the same way.

## Supported distros

`setup.sh` reads `/etc/os-release` (`ID`, then `ID_LIKE`) and picks the
package manager:

| Family | Distros | Package manager |
|--------|---------|-----------------|
| arch   | Arch, CachyOS, Manjaro, EndeavourOS | `pacman -Sy --needed` |
| debian | Debian, Ubuntu, Mint, Pop!_OS | `apt-get install` |
| fedora | Fedora and Fedora-likes | `dnf install` |
| rhel   | RHEL, Rocky, AlmaLinux, CentOS Stream | `dnf`/`yum` + EPEL (for `htop`) |
| macos  | macOS (Intel and Apple Silicon) | Homebrew (`brew install`) |

## macOS

- Run as your normal user, not root (Homebrew refuses root).
- If `brew` is missing, `setup.sh` runs the official installer:
  `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`.
  It asks for your password and installs the Xcode Command Line Tools.
  With `--yes` it sets `NONINTERACTIVE=1`.
- After the install it adds `eval "$(<prefix>/bin/brew shellenv)"` to `~/.zprofile`.
- macOS already has less, curl, ssh, lsof, file, tar, zip and the other base
  tools, so brew installs only: tmux, vim, nano, bash-completion@2, htop, git,
  wget, rsync, tree, jq.
- `~/.nanorc` points at Homebrew's nano syntax files (`<prefix>/share/nano`).
- `--ssh-server` turns on Remote Login (`systemsetup -setremotelogin on`).
  Newer macOS can block this without Full Disk Access; then use
  System Settings > General > Sharing > Remote Login.
- `setup.sh` runs on the bash 3.2 that ships with macOS.

## What it installs

- Packages: `pkg` lines in `catalog.txt`, grouped:
  - shell/editors/terminal: zsh, tmux, vim, nano, less, bash-completion, man-db
  - system: sudo, htop, procps, lsof, which, file, diffutils
  - network: git, OpenSSH client, curl, wget, rsync, iproute2, ping, dig, ca-certificates
  - files: tree, tar, gzip, zip, unzip, jq

  Names that differ per distro are mapped in `pkg_name` in `setup.sh` (for
  example `openssh-client` → `openssh` on Arch, `openssh-clients` on
  Fedora/RHEL; `dnsutils` → `bind` / `bind-utils`).
- `--ssh-server`: also installs the OpenSSH server and runs
  `systemctl enable --now sshd` (`ssh` on Debian/Ubuntu). Off by default.
- Configs (`configs/` → `$HOME`):
  - `tmux.conf` → `~/.tmux.conf` (copy of `dotfiles/dot_tmux.conf`, prefix `Ctrl+a`)
  - `nanorc` → `~/.nanorc`
  - `zshrc` → `~/.zshrc` (copy of `dotfiles/dot_zshrc`; the `~/.bash_*` alias
    files and OpenCode lines it references are skipped when absent), plus a
    block at the end that loads `~/.bash_aliases` and `~/.bash_aliases2`
  - `bash_aliases` → `~/.bash_aliases`, or `~/.bash_aliases2` (see below)
  - `bash_show_origin` → `~/.bash_show_origin`: before each command, prints
    where its aliases and functions are defined (`ll → ls -la  ~/.bash_aliases:12`).
    Toggle with `show_origin on|off`. Works in bash and zsh.
  - Terminals (off by default): kitty and Ghostty packages plus
    `configs/kitty/<os>.conf` → `~/.config/kitty/kitty.conf` and
    `configs/ghostty/<os>.config` → `~/.config/ghostty/config` on Linux or
    `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` on
    macOS. Ghostty has no Debian/Ubuntu apt package, so install it from
    https://ghostty.org/download there. Under WSL the menu also offers WezTerm
    on Windows (`scoop bucket add extras`, `scoop install wezterm`, and
    `configs/wezterm/windows.lua` → `%USERPROFILE%\.wezterm.lua`). Scoop must
    already be on `PATH` (see https://scoop.sh); without it, only the config is
    copied.
- `--terminal`: install every terminal for this platform without the menu.
- `--no-terminal`: skip all terminals.
- [TPM](https://github.com/tmux-plugins/tpm) in `~/.tmux/plugins/tpm`, plus
  the plugins listed in `.tmux.conf` (resurrect, continuum).

Before a file changes, `setup.sh` copies it to `<file>.bak.$(date +%Y%m%d_%H%M%S)`,
for example `~/.zshrc.bak.20261018_191502`. This covers every config in
`configs/`, the alias loader in `~/.bash_profile`/`~/.bashrc`, and the
`~/.zprofile` line on macOS. A file that is already
identical to the repo version is left alone, so reruns make no new backups.

## Aliases

`configs/bash_aliases` holds a small starter set (`ll`, `la`, `..`, `cp -i`,
`ta` for tmux attach, ...) and the `tm [session]` function: attach to or
create a tmux session (default `tmux1`); inside tmux it switches to the
session instead of nesting. `configs/bash_extras` holds extra portable
aliases (`m`, `tn`, `gst`/`gd`/`ga`/`gc`, `gpush`/`gpull`/`gsync`/`gchm`/`gl`,
`dow`/`rep`, `lt`/`ltt`, `mkcd`, ...): plain aliases plus tiny portable helpers
only, no fzf/eza/python deps. Plus 18 more keepers that work on macOS + Linux
(no 1-char names, no GNU-only flags except behind feature checks):
`sudo2`/`again`, `psg`/`psmem`/`pscpu`/`killport`/`ports`, `dfh`/`duh`,
`myip`/`down`/`serve`/`ping5`, `md`/`extract`, `hgrep`/`alg`,
`gundo`/`groot`/`gstash`/`gpop`. Both bash and zsh load both files (extras last, so
`m` can use `tm`).

- No `~/.bash_aliases` yet: it is created from the repo file.
- You already have your own `~/.bash_aliases`: it is kept as is, and the repo
  file goes to `~/.bash_aliases2`.
- `~/.bash_extras` and `~/.bash_show_origin` are always installed from the repo files.
- Helper scripts in `configs/bin/` (e.g. `tmuxhelp.sh`) install executable
  into `~/.local/bin/`; the wrapper in `bash_extras` (`tmuxhelp`) calls them.
  The loader block and repo `.zshrc` export `~/.local/bin` on `PATH`.
- The loader block below is appended to `~/.bash_profile` if that file
  exists, else to `~/.bashrc` (backed up first). It is not added twice;
  an older loader gains just the missing blocks (`~/.bash_extras`,
  `~/.bash_show_origin`) on rerun.

```sh
# Load custom aliases in Zsh
if [ -f ~/.bash_aliases ]; then
    source ~/.bash_aliases
fi

if [ -f ~/.bash_aliases2 ]; then
    source ~/.bash_aliases2
fi

if [ -f ~/.bash_extras ]; then
    source ~/.bash_extras
fi

# Show where each alias/function comes from before it runs (last, so it
# sees everything above). Toggle with: show_origin on|off
if [ -f ~/.bash_show_origin ]; then
    source ~/.bash_show_origin
fi
```

## Login shell

Tick `zsh as login shell` under `extras`. On Linux it runs
`usermod -s <zsh> <user>` (via sudo); on macOS `chsh -s`. Log out and back in to
use it.

- `--zsh-default`: change it for this run.
- `--no-zsh-default`: skip it for this run.
- A saved selection also applies under `--yes`.

## SSH key

Tick `SSH key` under `extras`. If `~/.ssh` has no key pair (any `*.pub` with its
private key, so custom names like `id_github` count), `setup.sh` runs
`ssh-keygen`, which asks for a passphrase, and prints the public key.

- `--ssh-key`: create the key for this run (empty passphrase when there is no
  terminal).
- `--no-ssh-key`: skip the check.
- With no terminal, a saved selection only warns: it never creates a key with an
  empty passphrase.

## Add more

- Package: add a line to `catalog.txt`. Add a `pkg_name` case if the name
  differs on a distro.
- Config: put the file in `configs/` and add `"src:target"` to `CONFIG_MAP`
  in `setup.sh`.

## Make targets

Run `make` (or `make help`) to list them. Extra `setup.sh` flags go in
`ARGS`, for example `make install ARGS="--ssh-server"`.

| Target | Does |
|--------|------|
| `make install` | full setup, with the SSH key, terminal, and zsh prompts |
| `make install-yes` | full setup, no prompts (no SSH key, no terminals, shell unchanged) |
| `make dry-run` | show what would run, change nothing |
| `make packages` / `make configs` | only packages / only configs |
| `make terminals` | install kitty + Ghostty packages and configs (WSL: also WezTerm via Scoop) |
| `make ssh-key` | create an ed25519 key if none exists |
| `make ssh-server` | install and enable the OpenSSH server |
| `make zsh-default` | make zsh the login shell |
| `make lint` | shellcheck, plus a `bootstrap.ps1` parse check when `pwsh` exists |
| `make test` | unit tests: distro detection, name mapping, configs, aliases, repo guard, `bootstrap.sh` |
| `make check` | lint + test |
| `make test-bash32` | unit tests + macOS dry-run under bash 3.2 |
| `make test-docker` | real run in Arch, Ubuntu, Debian, Fedora, Rocky, Alma containers, then a rerun that must change nothing |
| `make test-all` | every test above |
| `make sync-dotfiles` | refresh `tmux.conf` and `zshrc` from the dotfiles repo |

## CI

`.github/workflows/ci.yml` runs only when started by hand: Actions tab >
ci > Run workflow, or `gh workflow run ci.yml --ref <branch>`. It runs:

- `make check`
- bash 3.2
- the six-distro Docker matrix, each with a rerun check
- a real install plus a no-op rerun on macOS with the system bash
- a parse check and a dry run of `bootstrap.ps1` on Windows PowerShell 5.1.
  Runners are elevated, so CI sets `INSTALL_ALLOW_ADMIN=1`.

On a private repo, macOS minutes count 10x against the Actions quota.

## Sync configs from dotfiles

```sh
cp ../dotfiles/dot_tmux.conf configs/tmux.conf
```

Or `make sync-dotfiles` (reads `DOTFILES=../dotfiles`): it copies
`dot_tmux.conf` and rebuilds `configs/zshrc` from `dot_zshrc` plus the alias
loader block, then shows the diff.
