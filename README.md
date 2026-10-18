# install

Bootstrap a new Linux machine. One script installs the basic packages and
copies the base configs. Configs come from the
[dotfiles](../dotfiles) repo.

## Quick start

```sh
git clone <this-repo> ~/repos/install
cd ~/repos/install
./setup.sh            # asks once, then installs packages + configs
./setup.sh --dry-run  # show what would run, change nothing
```

Options: `-n/--dry-run`, `-y/--yes`, `--no-packages`, `--no-configs`,
`--ssh-server`, `--ssh-key`, `--no-ssh-key`, `-h/--help`.

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

## What it installs

- Packages: `packages/base.txt`, grouped:
  - editors/terminal: tmux, vim, nano, less, bash-completion, man-db
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
- [TPM](https://github.com/tmux-plugins/tpm) in `~/.tmux/plugins/tpm`, plus
  the plugins listed in `.tmux.conf` (resurrect, continuum).

## SSH key

After the configs, `setup.sh` checks `~/.ssh` for a key pair (any `*.pub`
with its private key, so custom names like `id_github` count). If none
exists, it asks `Create an ed25519 SSH key now? [Y/n]`, runs `ssh-keygen`
(which asks for a passphrase), and prints the public key.

- `--ssh-key`: create the key without asking (empty passphrase when there is no terminal).
- `--no-ssh-key`: skip the check.
- `--yes`, `--dry-run`, or no terminal: never creates a key, only warns.

An existing config that differs is moved to `<file>.bak.<timestamp>` first.
Reruns are safe: identical files are left alone.

## Add more

- Package: add a line to `packages/base.txt`. Add a `pkg_name` case if the
  name differs on a distro.
- Config: put the file in `configs/` and add `"src:target"` to `CONFIG_MAP`
  in `setup.sh`.

## Tests

```sh
make lint         # shellcheck
make test         # unit tests: distro detection, name mapping, config copy
make test-docker  # real run in archlinux, ubuntu:24.04, debian:12, fedora,
                  # rockylinux 9, almalinux 9 containers
```

## Sync tmux.conf from dotfiles

```sh
cp ../dotfiles/dot_tmux.conf configs/tmux.conf
```
