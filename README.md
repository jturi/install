# install

Bootstrap a new Linux or macOS machine. One script installs the basic packages and
copies the base configs. Configs come from the
[dotfiles](../dotfiles) repo.

## Quick start

One line, no git needed (downloads the repo to `~/install` and runs it):

```sh
mkdir -p ~/install && curl -fsSL https://github.com/jturi/install/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C ~/install && ~/install/setup.sh
```

No curl (minimal Debian/Ubuntu)? Use wget:

```sh
mkdir -p ~/install && wget -qO- https://github.com/jturi/install/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C ~/install && ~/install/setup.sh
```

Add options at the end, for example `... && ~/install/setup.sh --yes`.
The curl line also works on macOS (curl and tar are built in).

Or clone it:

```sh
git clone https://github.com/jturi/install.git ~/repos/install
cd ~/repos/install
./setup.sh            # asks once, then installs packages + configs
./setup.sh --dry-run  # show what would run, change nothing
```

Options: `-n/--dry-run`, `-y/--yes`, `--no-packages`, `--no-configs`,
`--ssh-server`, `--ssh-key`, `--no-ssh-key`, `--zsh-default`,
`--no-zsh-default`, `-h/--help`.

Run it as your normal user. The script uses `sudo` for the package manager
only. It runs as root without `sudo` when you are root.

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

- Packages: `packages/base.txt`, grouped:
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
session instead of nesting. `configs/bash_extras` holds the most-used
simple aliases from this machine's `~/.bash_history` (`m`, `tls`/`tn`,
`gst`/`gd`/`ga`/`gc`, `gpush`/`gpull`/`gsync`/`gchm`/`gl`, `dow`/`rep`,
`lt`, `mkcd`, ...): plain aliases plus tiny portable helpers only, no
fzf/eza/python deps. Both bash and zsh load both files (extras last, so
`m` can use `tm`).

- No `~/.bash_aliases` yet: it is created from the repo file.
- You already have your own `~/.bash_aliases`: it is kept as is, and the repo
  file goes to `~/.bash_aliases2`.
- `~/.bash_extras` is always installed from the repo file.
- Helper scripts in `configs/bin/` (e.g. `tmuxhelp.sh`) install executable
  into `~/.local/bin/`; the wrapper in `bash_extras` (`tmuxhelp`) calls them.
  The loader block and repo `.zshrc` export `~/.local/bin` on `PATH`.
- The loader block below is appended to `~/.bash_profile` if that file
  exists, else to `~/.bashrc` (backed up first). It is not added twice;
  an older loader gains just the missing `~/.bash_extras` block on rerun.

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
```

## Login shell

At the end, `setup.sh` asks `Make zsh your login shell (now /bin/bash)? [y/N]`.
On Linux it runs `usermod -s <zsh> <user>` (via sudo); on macOS `chsh -s`.
Log out and back in to use it.

- `--zsh-default`: change it without asking.
- `--no-zsh-default`: skip the question.
- `--yes`, `--dry-run`, or no terminal: never changes the shell.

## SSH key

After the configs, `setup.sh` checks `~/.ssh` for a key pair (any `*.pub`
with its private key, so custom names like `id_github` count). If none
exists, it asks `Create an ed25519 SSH key now? [Y/n]`, runs `ssh-keygen`
(which asks for a passphrase), and prints the public key.

- `--ssh-key`: create the key without asking (empty passphrase when there is no terminal).
- `--no-ssh-key`: skip the check.
- `--yes`, `--dry-run`, or no terminal: never creates a key, only warns.

## Add more

- Package: add a line to `packages/base.txt`. Add a `pkg_name` case if the
  name differs on a distro.
- Config: put the file in `configs/` and add `"src:target"` to `CONFIG_MAP`
  in `setup.sh`.

## Make targets

Run `make` (or `make help`) to list them. Extra `setup.sh` flags go in
`ARGS`, for example `make install ARGS="--ssh-server"`.

| Target | Does |
|--------|------|
| `make install` | full setup, with the SSH key and zsh prompts |
| `make install-yes` | full setup, no prompts |
| `make dry-run` | show what would run, change nothing |
| `make packages` / `make configs` | only packages / only configs |
| `make ssh-key` | create an ed25519 key if none exists |
| `make ssh-server` | install and enable the OpenSSH server |
| `make zsh-default` | make zsh the login shell |
| `make lint` | shellcheck |
| `make test` | unit tests: distro detection, name mapping, configs, aliases |
| `make check` | lint + test |
| `make test-bash32` | unit tests + macOS dry-run under bash 3.2 |
| `make test-docker` | real run in Arch, Ubuntu, Debian, Fedora, Rocky, Alma containers |
| `make test-all` | every test above |
| `make sync-dotfiles` | refresh `tmux.conf` and `zshrc` from the dotfiles repo |

## Sync configs from dotfiles

```sh
cp ../dotfiles/dot_tmux.conf configs/tmux.conf
```

Or `make sync-dotfiles` (reads `DOTFILES=../dotfiles`): it copies
`dot_tmux.conf` and rebuilds `configs/zshrc` from `dot_zshrc` plus the alias
loader block, then shows the diff.
