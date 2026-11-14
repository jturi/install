# Hardening and Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the SSH exposure paths the 2026-11-14 audit found, fix the shell helpers and the alias loader that misbehave on real machines, and make the Windows bootstrap honest about what it does, without growing the installer's surface.

**Architecture:** No new components. Each fix lands in the function that owns the behaviour, comes with a failing test written first, and keeps the existing contracts: idempotent reruns, backups before every change, dry run changes nothing, bash 3.2 and PowerShell 5.1.

**Tech Stack:** bash 3.2+, zsh, Windows PowerShell 5.1+, OpenSSH (`sshd -t`, `sshd -T -C`), systemd, shellcheck, the existing `tests/test_setup.sh` and `tests/test_windows.ps1` harnesses.

**Source:** the architecture audit of 2026-11-14 (in the session). This plan reviews that audit's remediation list, keeps what survives scrutiny, and corrects what does not (see *Review of the audit* below).

## Global Constraints

- Everything from the 2026-11-05 plan still holds: bash 3.2 (no `mapfile`, no associative arrays), PowerShell 5.1, ASCII `.ps1`, no real usernames or IPs in the repo, tests never touch the real home, real Scoop or real `/etc/ssh`.
- **Work happens on branch `fix/hardening`; the WIP was committed first as `89d75c9`. Commit messages carry no `Co-Authored-By:` or "Generated with" lines.** The user's global instructions override the 2026-11-05 plan's commit constraint.
- Never stop or reconfigure a service the user already had running before this run, unless they asked for it. A remote user must not be cut off by a fix.
- Never delete content from a user-owned rc file. Add, back up, and tell the user what they can remove.
- Every new behaviour gets a test that fails before the change. Run `make check` after every task.
- `tests/test_repo.sh` rejects literal private host IPs anywhere in the repo, plans included. Tests build them from 3-octet prefixes (`LAN=192.168.1`, then `"${LAN}.9"`); network ranges like `10.0.0.0/8` are allowed as written.

## Before Task 1: commit the work in progress

The working tree holds about 300 uncommitted lines in `setup.sh` (the `ssh-local-only` feature, among others) plus test and README changes. Tasks 4 and 5 rewrite that code. Commit or stash it first, as its own commit, so these fixes can be reviewed and reverted on their own. **This is the user's call. Do not commit it without asking.**

---

## Review of the audit

Before planning, every P0/P1 claim from the audit was rechecked against the code and, where possible, run. Five claims were wrong or incomplete. The plan below uses the corrected versions.

| Audit claim | Status | Evidence | Consequence for the plan |
|---|---|---|---|
| `again`: `fc -ln -1` can return `again` itself; fix with `fc -ln -2 -2` | **Wrong** | Ran in a pty under bash 5.3 and zsh: inside a function, `fc -ln -1` already returns the *previous* command, and `-2 -2` returns the one before it | The proposed fix would have run the wrong command as root. The real bug is only that the line is passed as one argv with a leading tab (verified: `argc=1 argv1=<\t echo hello world>`). Task 1 |
| `killport` kills clients too | Confirmed | `lsof -ti tcp:N` matches either end of a socket | Task 2. Watch out for zsh: a variable holding PIDs does not word-split |
| sshd fails open; fix by restricting before `enable --now` | **Incomplete** | Debian/Ubuntu `openssh-server` starts `ssh` in its postinst, so sshd is already up when the packages step ends, whatever the step order | Reordering helps Arch/Fedora/RHEL/macOS only. Debian needs an explicit stop on failure. And "fail closed" must never stop an sshd that ran *before* this run. Task 5 |
| Lock-out check over SSH | Confirmed, and there is a better tool | `sshd -T -C addr=…` evaluates the real Match blocks. Sandbox run against our drop-in: a 192.168/16 host, a 10/8 host, `::1`, `fd00::5` allowed; `8.8.8.8`, `100.64.1.1`, `2a01:4f8::1`, `::ffff:8.8.8.8` denied | No CIDR code in bash: ask sshd. Task 4 |
| Global IPv6 / Tailscale clients are refused | Confirmed (same run) | `100.64.1.1` and `2a01:4f8::1` → `DenyUsers *` | Documented, not widened (decision D6) |
| Windows rule needs `-Profile Private,Domain` | **Incomplete** | Windows marks new networks Public by default, so many home networks are Public | Without a warning the fix makes sshd silently unreachable at home. Also, the step returns early when sshd already runs, so existing installs would never be narrowed. Task 6 |
| Loader in `~/.bash_profile` is a bug | Confirmed, but it was **deliberate and tested** (`f32941f`, `tests/test_setup.sh:144`) | `/etc/skel` on this CachyOS machine ships `.bash_profile` that sources `.bashrc`; Arch and Fedora do the same. Non-login terminals read only `.bashrc` | Reverse the design on Linux only, keep macOS, migrate without deleting. Task 8 |
| `INSTALL_ITEMS` is ignored | Confirmed | Read only by the `bootstrap.ps1` fallback, which never runs because `setup.ps1` always exists; CI sets it anyway | Task 7 |
| Turn off tmux pane capture | **Wrong target** | `configs/tmux.conf` is copied from `../dotfiles` by `make sync-dotfiles`, so an edit here is overwritten | Protect the directory instead. Task 9 |
| Run all of CI on push | **Too broad** | The repo is **private** (`gh repo view`): minutes are billed and macOS minutes cost 10×. Manual-only was a deliberate choice | Only the cheap Linux jobs run on push. Task 10 |
| wget resends the token on redirect | Dropped | Only matters if the user points `BOOTSTRAP_URL` at a hostile host themselves | Not planned |

---

## Decision Log

Each decision lists the options considered and why the chosen one wins. Reviewers should push back here first.

**D1: Ask sshd, don't parse CIDRs (Task 4).**
Options: (a) reimplement IPv4/IPv6 prefix matching in bash 3.2; (b) `sshd -T -C user=…,host=…,addr=…,laddr=…,lport=…` against the config just written; (c) skip the check and only document it.
Chosen: **(b)**. It gives exactly the answer sshd will give at login, including Match ordering, IPv4-mapped addresses and anything the user adds later. (a) is about 80 lines of untestable bit arithmetic that can drift from sshd's semantics. (c) leaves the worst outcome, a remote lockout, unguarded.
If `sshd -T` itself fails while we are on SSH, we **treat it as denied** and roll back. An unverifiable restriction on a remote session is the one case where failing safe means *not* applying it.

**D2: Where the SSH client address comes from (Task 4).**
`$SSH_CONNECTION`, except inside tmux, where the pane's copy is stale (a session created locally and later attached over SSH has none). There we read `tmux show-environment SSH_CONNECTION`, which tmux updates on every attach (it is in tmux's default `update-environment`).
Under `sudo ./setup.sh`, `env_reset` usually drops the variable. We warn instead of guessing (`who -m` parsing differs across distros and macOS). Running setup as root is already a warned path.

**D3: Fail closed only for what this run started (Task 5).**
Options: (a) always stop sshd when the restriction fails; (b) never touch sshd and only mark FAILED (today's behaviour); (c) record whether sshd was active *before* the run; stop it only if this run brought it up.
Chosen: **(c)**. (a) can cut off a user who runs setup over SSH on a machine they administer remotely, which is worse than the exposure. (b) leaves a server open that the user asked to be local-only. With (c), a new exposure never survives a failed restriction, and an existing setup is never broken.
"Before" is measured in the parent shell before the packages step, because steps run in subshells and cannot hand state back.

**D4: Don't pre-seed the drop-in before the package install (Task 5).**
Writing `sshd_config.d/20-…conf` before `apt install openssh-server` would close the few seconds sshd is open on Debian. Rejected for now: `sshd -t` cannot validate the file before sshd exists; RHEL 8's `sshd_config` has no Include line until the package lands; and a `policy-rc.d` trick changes global dpkg behaviour. The remaining exposure is a few seconds, on a fresh install, with the distro's default config, and it ends in either the restriction or a stopped sshd. Revisit if the step is ever used on internet-facing hosts.

**D5: Windows firewall: Private and Domain, plus a warning (Task 6).**
Options: Any profile (today: on café Wi-Fi, "LocalSubnet" means strangers); Private only (breaks domain-joined work laptops, whose networks are managed); **Private + Domain**. Home networks that Windows marks Public lose access, so the step names those networks and says how to mark them Private. It does not change the network category itself: that is a trust decision about the network, and it belongs to the user.
Existing installs: the "already running" early return now also requires the rule to be scoped. Otherwise the fix would only reach new machines.

**D6: Don't widen the Linux allow-list (documented limitation).**
Allowing `100.64.0.0/10` would let carrier-NAT neighbours in on some ISPs. Allowing the current global IPv6 prefix pins an address the ISP rotates. The README will say what is refused and how to add a site-specific drop-in. Not a code change.

**D7: Loader goes to `~/.bashrc` on Linux; macOS unchanged (Task 8).**
Linux terminals start non-login shells, which read only `~/.bashrc`, and Arch/Fedora ship a `.bash_profile` that sources `.bashrc`. So `.bashrc` is right on every Linux distro: login shells reach it through `.bash_profile` or `.profile`. macOS Terminal starts login shells, and creating a `.bash_profile` there would shadow an existing `~/.profile`, so macOS keeps today's rule. macOS's default shell is zsh, whose rc already loads the aliases.
Migration: if an old loader sits in `.bash_profile`, we add one to `.bashrc` and **leave the old one**, printing that it can be removed. Login shells then load the files twice. That is harmless: aliases are redefined, `show_origin` already guards against a second hook, and PATH gets one duplicate entry. Editing a user rc file to remove a block is the riskier operation (constraint: never delete user content).

**D8: Remove the `bootstrap.ps1` fallback installer instead of reviving `INSTALL_ITEMS` (Task 7).**
The fallback (about 100 lines, a third catalog parser) only runs for downloads without `setup.ps1`, which no longer exist. Reviving `INSTALL_ITEMS` would add a third selection channel next to the menu and the saved config. CI gets the same coverage by writing a config file, which is the real interface. The exit code is passed on with `Write-Error`, **not `exit`**: under `irm | iex`, `exit` would close the user's PowerShell window.

**D9: tmux resurrect: protect, don't disable (Task 9).**
Pane capture is a feature the user chose in their dotfiles repo. The risk is mainly *other local users* reading saved scrollback: the directory is created 0755 under the default umask. `chmod 700` on the directory removes that without changing behaviour. The same goes for `~/.local/bootstrap` (logs, config).

**D10: Arch full upgrade: say it, don't add another prompt (Task 9).**
`pacman -Syu` is correct (partial upgrades are unsupported, and `-S` against a stale database gives 404s). The interactive run already ends in "Go ahead?", so a plan line naming the upgrade makes that prompt informed. `--yes` users opted out of prompts on purpose. A second prompt would only add prompt fatigue.

**D11: CI stays manual-only (user decision, 2026-11-14).** The repo is private and minutes are billed; `ci.yml` keeps `workflow_dispatch` as its only trigger. The Windows job's content is still corrected in Task 7 so a manual run tests the real interface, but nothing in this plan triggers it.

### Deferred or rejected (with reasons)

| Item | Verdict | Why |
|---|---|---|
| Pin Homebrew/Scoop installers, TPM, plugins | Rejected | Upstream installers are meant to be fetched live, and pinned copies break when their APIs move. TPM pins need upkeep for no threat this repo can address |
| Pin the bootstrap download (`INSTALL_REF`) | Deferred (P2) | Only meaningful if the user also fetches `bootstrap.sh` from a tag URL, which needs releases first |
| Lock takeover race | Rejected | Needs two simultaneous runs right after a crash, for a single-user tool. `mkdir` is already atomic for the normal case |
| Step registry, split `setup.sh` | Deferred | Worth doing, but not mixed with security fixes. Do it after this plan and the WIP commit, as a pure refactor with no behaviour change |
| Optional "SSH keys only" hardening item | Deferred | Needs its own design: it locks out users with no `authorized_keys` entry, which is exactly the fresh-machine case |
| `stty echo` trap, `ZeroFreeBSTR`, Windows backup suffix, `vscode` exit codes, `ltt` arg limit | Follow-up batch | Low impact and independent. One small PR after this plan |

---

## File Structure

| File | Change |
|---|---|
| `configs/bash_extras` | `again`, `killport`, `duh`, `down` |
| `setup.sh` | `has_systemd`, `ssh_connection`, `ssh_session_denied`, `-f` on sshd calls, step order, `ssh_server_fail_closed`, `last_step_failed`, `bash_rc_file`, private dirs, Arch plan note |
| `windows/steps/sshserver.ps1` | Firewall profiles, `Test-StepSshFirewallScoped`, `Get-StepPublicNetworks` |
| `bootstrap.ps1` | Fallback removed, exit status passed on |
| `.github/workflows/ci.yml` | Triggers, Windows job uses a config file |
| `tests/test_setup.sh`, `tests/test_windows.ps1`, `tests/docker_matrix.sh` | New and updated cases |
| `README.md` | Loader location, SSH limits, bootstrap env vars |

---

### Task 1: `again` reruns the previous command correctly

**Files:** Modify `configs/bash_extras:132`. Test: `tests/test_setup.sh` (new block near the other `bash_extras` checks).

- [ ] **Step 1: Write the failing test.** `fc` is a builtin, and a function of the same name overrides it, so the test needs no pty:

```bash
# again: the previous line is re-split into words, leading blanks dropped.
again_case() {
  "$1" -c '
    source "$0"
    fc() { printf "\t echo \"a b\" c\n"; }
    sudo() { printf "%s|" "$#" "$@"; }
    again 2>/dev/null' "${ROOT}/configs/bash_extras"
}
check again-bash "3|echo|a b|c|" "$(again_case bash)"
if command -v zsh >/dev/null 2>&1; then check again-zsh "3|echo|a b|c|" "$(again_case zsh)"; fi
check again-empty-rc "1" "$(bash -c 'source "$0"; fc() { :; }; again' "${ROOT}/configs/bash_extras" >/dev/null 2>&1; echo $?)"
```

- [ ] **Step 2: Run it.** `bash tests/test_setup.sh | grep again`. Expect `FAIL again-bash: want [3|echo|a b|c|] got [1|	 echo "a b" c|]`.

- [ ] **Step 3: Implement.**

```bash
# again: rerun the previous command as root. `fc -ln -1` prints it with
# leading blanks; eval splits it into words the way the shell did. It runs
# exactly what you typed last, so it is shown first.
again() {
  local c
  c="$(fc -ln -1)"
  c="${c#"${c%%[![:space:]]*}"}"
  [ -n "$c" ] || { echo "again: no previous command" >&2; return 1; }
  printf 'sudo %s\n' "$c" >&2
  eval "sudo $c"
}
```

Note for the reviewer: the `eval` runs only the user's own last history line, which they could already run with `sudo !!`. It adds no trust boundary.

- [ ] **Step 4: Run** `make check`. Expect all PASS, shellcheck clean.
- [ ] **Step 5: Commit** `fix(extras): again reruns the last command as separate words`.

### Task 2: `killport` kills listeners only

**Files:** Modify `configs/bash_extras:143-147`. Test: `tests/test_setup.sh`.

- [ ] **Step 1: Failing test.** Stub `lsof` to record its arguments and print two PIDs, and stub `kill` to record what it got. Run under bash and zsh. Zsh matters: `kill $pids` with a *variable* does not word-split in zsh.

```bash
killport_case() {
  "$1" -c '
    source "$0"
    lsof() { echo "$*" >"$1.args"; [ -n "$LSOF_OUT" ] && printf "%s\n" $LSOF_OUT; }
    kill() { echo "kill $*"; }
    killport "$2"' "${ROOT}/configs/bash_extras" "${WORK}/kp" "$2"
}
out="$(LSOF_OUT="11 22" killport_case bash 8080)"
check killport-listen-only "1" "$(grep -c -- '-sTCP:LISTEN' "${WORK}/kp.args")"
check killport-bash "kill 11 22" "${out}"
if command -v zsh >/dev/null 2>&1; then check killport-zsh "kill 11 22" "$(LSOF_OUT="11 22" killport_case zsh 8080)"; fi
check killport-none "1" "$(LSOF_OUT="" killport_case bash 8080 >/dev/null 2>&1; echo $?)"
check killport-not-number "1" "$(killport_case bash abc >/dev/null 2>&1; echo $?)"
```

(The stub's `$1.args` path is the function's own `$1` from the `lsof` arguments. Simplify to a fixed `"${WORK}/kp.args"` passed in through the environment if that reads better. What matters is the assertions.)

- [ ] **Step 2: Run.** Expect `killport-listen-only` and `killport-none` to FAIL.
- [ ] **Step 3: Implement.**

```bash
# killport <port>: kill whatever LISTENS on TCP <port> (not clients that
# merely talk to it: `lsof -i tcp:443` would include your browser).
killport() {
  [ $# -eq 1 ] || { echo "usage: killport <port>" >&2; return 1; }
  case "$1" in ''|*[!0-9]*) echo "killport: not a port: $1" >&2; return 1 ;; esac
  local pids
  pids="$(lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null)"
  [ -n "$pids" ] || { echo "killport: nothing listens on TCP $1" >&2; return 1; }
  # xargs splits the PID list the same way in bash and zsh.
  printf '%s\n' "$pids" | xargs kill
}
```

`-sTCP:LISTEN` is supported by lsof on macOS and Linux (checked against lsof 4.99). Problem: `xargs kill` runs `/bin/kill`, not the stubbed function. So the test should stub `kill` as an executable on `PATH` (write `${WORK}/bin/kill`) instead of as a function. Adjust Step 1 to that. This is the kind of detail Step 2's run is there to catch.

- [ ] **Step 4:** `make check`. **Step 5: Commit** `fix(extras): killport only kills listeners`.

### Task 3: `duh` sorts by size; `down` keeps the name with wget

**Files:** `configs/bash_extras:154-158`, the `down()` wget branch.

- [ ] **Step 1: Failing test.** In a temp dir, create `big` (2 MiB) and `small` (600 KiB) with `head -c`. Then `check duh-order "small big" "$(cd dir && duh | awk '{print $2}' | xargs)"`. For `down`: put a fake `wget` on PATH that prints its args, hide curl (a PATH with only the fake dir plus `/bin` utilities is enough), and `check down-wget-name "1" "$(… down http://x/y out.bin | grep -c -- '-O out.bin')"`.
- [ ] **Step 2: Run** and see both FAIL.
- [ ] **Step 3: Implement.** `duh`: `du -sk -- * .[!.]* 2>/dev/null | sort -n | awk -F'\t' '{s=$1;u="K"; if(s>=1048576){s/=1048576;u="G"} else if(s>=1024){s/=1024;u="M"} printf "%6.1f%s\t%s\n",s,u,$2}'`. This is numeric, so it works with BSD `sort` (no `-h` on macOS). `down`: `wget -q --show-progress -O "${2:-$(basename "$1")}" "$1"`.
- [ ] **Step 4:** `make check`, `make test-bash32`. **Step 5: Commit** `fix(extras): duh sorts by size; down keeps the name with wget`.

### Task 4: Refuse a restriction that would lock out the current SSH session

**Files:** `setup.sh` (`restrict_ssh_local_only`, new `ssh_connection`, `ssh_session_denied`). Tests: `tests/test_setup.sh` SSH block.

- [ ] **Step 1: Make the tests deterministic.** At the top of `tests/test_setup.sh`, add `unset SSH_CONNECTION TMUX`. The developer may be running the tests over SSH or inside tmux.

- [ ] **Step 2: Failing unit tests.** Use a fake sshd that behaves like the real one for `-t` and `-T -C`, and logs its calls:

```bash
cat >"${WORK}/fake-sshd" <<'EOF'
#!/bin/sh
echo "$*" >>"${FAKE_SSHD_LOG}"
case "$*" in
  *-T*addr=8.8.8.8*) echo "port 22"; echo "denyusers *" ;;
  *-T*addr=6.6.6.6*) exit 255 ;;   # sshd -T itself fails
  *-T*) echo "port 22" ;;
esac
exit 0
EOF
chmod +x "${WORK}/fake-sshd"
lockout() {  # $1 = SSH_CONNECTION value ('' = local console)
  rm -f "${dropin}"; : >"${WORK}/sshd.log"
  ( eval "${ssh_stubs}"; SSH_CONFIG_DIR="${sshdir}"; FAKE_SSHD_LOG="${WORK}/sshd.log"
    sshd_path() { echo "${WORK}/fake-sshd"; }
    SSH_CONNECTION="$1" restrict_ssh_local_only debian ) 2>&1
}
LAN=192.168.1 TEN=10.0.0   # 3-octet prefixes: tests/test_repo.sh rejects literal private host IPs
out="$(lockout "8.8.8.8 50000 ${LAN}.2 22")"; rc=$?
check lockout-public-rc "1" "${rc}"
check lockout-public-removed "no" "$([[ -e "${dropin}" ]] && echo yes || echo no)"
check lockout-public-says "1" "$(grep -c 'connected over SSH from 8.8.8.8' <<<"${out}")"
check lockout-public-no-reload "0" "$(grep -c reloaded <<<"${out}")"
out="$(lockout "${LAN}.9 50000 ${LAN}.2 22")"; rc=$?
check lockout-lan-rc "0" "${rc}"
check lockout-lan-spec "1" "$(grep -c "addr=${LAN}.9,laddr=${LAN}.2,lport=22" "${WORK}/sshd.log")"
out="$(lockout '')"; rc=$?
check lockout-console-rc "0" "${rc}"
check lockout-console-no-T "0" "$(grep -c -- '-T' "${WORK}/sshd.log")"
out="$(lockout "6.6.6.6 1 ${LAN}.2 22")"; rc=$?
check lockout-unverifiable-rc "1" "${rc}"
check lockout-config-flag "1" "$(grep -c -- "-t -f ${sshdir}/sshd_config" "${WORK}/sshd.log")"
# Inside tmux the attach-time value wins over the pane's stale one.
check ssh-connection-tmux "9.9.9.9 1 ${TEN}.1 22" "$(TMUX=x SSH_CONNECTION=old tmux() { echo "SSH_CONNECTION=9.9.9.9 1 ${TEN}.1 22"; }; ssh_connection)"
```

(The last line needs the `tmux` stub defined in a subshell before the call. Write it as `( tmux() { …; }; TMUX=x SSH_CONNECTION=old ssh_connection )`.)

- [ ] **Step 3: Failing integration test with the real sshd** (skipped when none is installed). This pins the Match semantics that the audit verified by hand:

```bash
real_sshd="$(sshd_path 2>/dev/null || true)"
if [[ -n "${real_sshd}" ]]; then
  sb="${WORK}/sshd-real"; mkdir -p "${sb}/sshd_config.d"
  ssh-keygen -q -t ed25519 -N '' -f "${sb}/hk"
  printf 'HostKey %s/hk\nUsePAM no\n' "${sb}" >"${sb}/sshd_config"
  ( eval "${ssh_stubs}"; SSH_CONFIG_DIR="${sb}"; restrict_ssh_local_only arch ) >/dev/null 2>&1
  for a in ${LAN}.5:allow ${TEN}.3:allow ::1:allow fd00::5:allow \
           8.8.8.8:deny 100.64.1.1:deny 2a01:4f8::1:deny ::ffff:8.8.8.8:deny; do
    ip="${a%:*}" want="${a##*:}"
    got=allow
    "${real_sshd}" -T -f "${sb}/sshd_config" -C "user=u,host=h,addr=${ip}" 2>/dev/null | grep -qi '^denyusers \*$' && got=deny
    check "match-${ip}" "${want}" "${got}"
  done
fi
```

(Split on the *last* colon: IPv6 addresses contain colons, and `${a%:*}` / `${a##*:}` handle that.)

- [ ] **Step 4: Run.** Expect the `lockout-*` checks to FAIL. The `match-*` checks should already PASS, because they pin existing behaviour. That is intended.

- [ ] **Step 5: Implement.**

```bash
# The SSH_CONNECTION of the session running setup ("client cport server sport"),
# or nothing on a local console. Inside tmux a pane keeps the value from when
# it was created; tmux refreshes its own copy on every attach.
ssh_connection() {
  local v=""
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    v="$(tmux show-environment SSH_CONNECTION 2>/dev/null || true)"
    if [[ "${v}" == SSH_CONNECTION=* ]]; then printf '%s\n' "${v#SSH_CONNECTION=}"; return 0; fi
  fi
  printf '%s\n' "${SSH_CONNECTION:-}"
}

# True when the installed sshd config would refuse the SSH session running
# setup. sshd evaluates its own Match blocks (-T -C), so this never disagrees
# with a real login. Also true when we are on SSH but sshd cannot answer:
# an unverifiable restriction must not go live under a remote user.
ssh_session_denied() {
  local sshd="$1" conn out
  conn="$(ssh_connection)"
  # shellcheck disable=SC2086 # split "client cport server sport"
  set -- ${conn}
  if [[ $# -ne 4 ]]; then
    if is_root && [[ -n "${SUDO_USER:-}" ]]; then
      warn "running under sudo: cannot tell whether you are connected over SSH"
    fi
    return 1
  fi
  SSH_CLIENT_ADDR="$1"
  out="$(root_quiet "${sshd}" -T -f "${SSH_CONFIG_DIR}/sshd_config" \
    -C "user=$(current_user),host=$1,addr=$1,laddr=$3,lport=$4" 2>/dev/null)" || {
    warn "cannot check that your SSH session from $1 stays allowed (sshd -T failed)"
    return 0
  }
  grep -qi '^denyusers \*$' <<<"${out}"
}
```

In `restrict_ssh_local_only`, change `root_quiet "${sshd}" -t` to `root_quiet "${sshd}" -t -f "${SSH_CONFIG_DIR}/sshd_config"`. This also makes `SSH_CONFIG_DIR` honest: today `-t` always reads `/etc/ssh`. Then insert this between the `-t` check and `reload_sshd`:

```bash
  if ((!DRY_RUN)) && ssh_session_denied "${sshd}"; then
    warn "you are connected over SSH from ${SSH_CLIENT_ADDR:-an unknown address}, which this restriction refuses; removing ${dst}. Run setup from the local network or the console."
    as_root rm -f "${dst}"
    return 1
  fi
```

`SSH_CLIENT_ADDR` is a plain global so the message can name the address. Declare it next to the other globals (`SSH_CLIENT_ADDR=""`).

- [ ] **Step 6:** `make check`, `make test-bash32` (bash 3.2: `set --` inside a function, `<<<`: both fine in 3.2). **Step 7: Commit** `fix(ssh): never apply a local-only restriction that locks out the current session`.

### Task 5: A failed restriction never leaves a new sshd open

**Files:** `setup.sh` (`run_steps`, new `has_systemd`, `last_step_failed`, `ssh_server_fail_closed`). Tests: the `run_main` block (`tests/test_setup.sh:385-430`).

- [ ] **Step 1: Testability refactor (no behaviour change).** Add `SYSTEMD_RUN_DIR="${SYSTEMD_RUN_DIR:-/run/systemd/system}"` and `has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d "${SYSTEMD_RUN_DIR}" ]]; }`. Replace the three inline checks (`setup.sh:490, 563, 1074`). Run `make check`: everything must stay green. Commit `refactor: has_systemd helper`.

- [ ] **Step 2: Failing tests.** Update and extend the step-order checks:

```bash
# Restriction before the server: sshd never starts without it.
m_reset; run_main --ssh-server --ssh-local-only --yes >/dev/null
check main-ssh-local-only "packages ssh-local-only ssh-server configs tpm" "$(steps)"
# Restriction fails: the server step closes instead of enabling.
m_reset; M_EXTRA='restrict_ssh_local_only() { echo ssh-local-only >>"${m_log}"; return 1; }
  ssh_server_fail_closed() { echo "fail-closed $2" >>"${m_log}"; return 1; }
  check_ssh_server() { echo MISSING; }'
run_main --ssh-server --ssh-local-only --yes >/dev/null
check main-ssh-fail-closed "packages ssh-local-only fail-closed 0 configs tpm" "$(steps)"
# sshd already ran before this run: fail-closed is told so.
m_reset; M_EXTRA="${M_EXTRA/echo MISSING/echo OK}"; run_main --ssh-server --ssh-local-only --yes >/dev/null
check main-ssh-fail-closed-was-running "packages ssh-local-only fail-closed 1 configs tpm" "$(steps)"
```

Unit tests for `ssh_server_fail_closed`, with `as_root` stubbed to log and `SYSTEMD_RUN_DIR` pointed at a temp dir:

```bash
fc_case() { ( as_root() { echo "as_root $*"; }; SYSTEMD_RUN_DIR="${WORK}"; systemctl() { :; }
  ssh_server_fail_closed "$1" "$2" ) 2>&1; }
out="$(fc_case debian 1)"; rc=$?
check fail-closed-was-running-rc "1" "${rc}"
check fail-closed-was-running-untouched "0" "$(grep -c as_root <<<"${out}")"
check fail-closed-was-running-warns "1" "$(grep -c 'WITHOUT the local-network restriction' <<<"${out}")"
out="$(fc_case debian 0)"
check fail-closed-debian-stops "1" "$(grep -c 'as_root systemctl disable --now ssh.socket ssh' <<<"${out}")"
out="$(fc_case macos 0)"
check fail-closed-macos-no-action "0" "$(grep -c as_root <<<"${out}")"
```

- [ ] **Step 3: Run** and see the new checks FAIL.

- [ ] **Step 4: Implement.**

```bash
# True when the step that ran last failed.
last_step_failed() {
  [[ "${STEP_STATUS[${#STEP_STATUS[@]}-1]}" == "FAILED" ]]
}

# The local-network restriction failed. Do not leave open an sshd this run
# brought up (Debian and Ubuntu start ssh as soon as the package installs).
# One that already ran before this run is left alone: stopping it could cut
# off the user's own remote session.
ssh_server_fail_closed() {
  local family="$1" was_running="$2" svc=sshd
  if ((was_running)); then
    warn "sshd was already running and keeps running WITHOUT the local-network restriction; fix the error above and rerun"
    return 1
  fi
  warn "not starting sshd: the local-network restriction failed"
  # macOS: Remote Login is only turned on by enable_ssh_server, which did not run.
  [[ "${family}" != "macos" ]] || return 1
  [[ "${family}" == "debian" ]] && svc=ssh
  if has_systemd; then
    as_root systemctl disable --now "${svc}.socket" "${svc}" 2>/dev/null ||
      as_root systemctl disable --now "${svc}" || true
  fi
  return 1
}
```

`run_steps` becomes:

```bash
run_steps() {
  local family="$1" sshd_before=0 local_failed=0
  # Measured here: steps run in subshells and cannot report state back.
  [[ "$(check_ssh_server "${family}")" != "OK" ]] || sshd_before=1
  if action_selected pkg || item_selected extras.ssh-server; then
    [[ "${family}" != "macos" ]] || ensure_brew
    run_step packages install_packages "${family}"
  fi
  # The restriction goes in before sshd is enabled, so it never runs without it.
  if action_selected step:ssh-local-only; then
    run_step "ssh local network only" restrict_ssh_local_only "${family}"
    ! last_step_failed || local_failed=1
  fi
  if item_selected extras.ssh-server; then
    if ((local_failed)); then
      run_step "ssh server" ssh_server_fail_closed "${family}" "${sshd_before}"
    else
      run_step "ssh server" enable_ssh_server "${family}"
    fi
  fi
  # … rest unchanged
```

Reviewer note: `check_ssh_server` runs `systemctl is-active` (no root), and on macOS `netstat`. Both are read-only and safe in a dry run. When sshd is not installed it prints `MISSING`, so `sshd_before` stays 0.

- [ ] **Step 5:** `make check`, `make test-bash32`. Optionally `make test-docker`: the Debian and Ubuntu images exercise the postinst start for real only when systemd runs, which it does not in these containers, so the unit tests carry this. **Step 6: Commit** `fix(ssh): restrict before enabling sshd, and stop an sshd this run started when the restriction fails`.

### Task 6: Windows sshd: trusted networks only, existing installs narrowed

**Files:** `windows/steps/sshserver.ps1`. Tests: `tests/test_windows.ps1` (SSH server block, lines 372-445).

- [ ] **Step 1: Failing tests.**

```powershell
# Both firewall calls limit the rule to Private and Domain networks.
Check 'sshd-script-profiles' '2' ([string]([regex]::Matches($global:ElevLog[0], '-Profile Private,Domain').Count))
# Scoped-rule detection, on injected objects (no NetSecurity module in the container).
$R = New-Object PSObject -Property @{ Profile = 'Domain, Private' }
$F = New-Object PSObject -Property @{ RemoteAddress = 'LocalSubnet' }
Check 'fw-scoped-ok' 'True' ([string](Test-StepSshFirewallScoped -Rule $R -Filter $F))
Check 'fw-scoped-any' 'False' ([string](Test-StepSshFirewallScoped -Rule (New-Object PSObject -Property @{ Profile = 'Any' }) -Filter $F))
Check 'fw-scoped-public' 'False' ([string](Test-StepSshFirewallScoped -Rule (New-Object PSObject -Property @{ Profile = 'Private, Public' }) -Filter $F))
Check 'fw-scoped-anyaddr' 'False' ([string](Test-StepSshFirewallScoped -Rule $R -Filter (New-Object PSObject -Property @{ RemoteAddress = 'Any' })))
Check 'fw-scoped-norule' 'False' ([string](Test-StepSshFirewallScoped))
# Public networks are named, so the user knows why sshd is unreachable there.
$Nets = @((New-Object PSObject -Property @{ Name = 'Home'; NetworkCategory = 'Public' }), (New-Object PSObject -Property @{ Name = 'Work'; NetworkCategory = 'DomainAuthenticated' }))
Check 'public-networks' 'Home' ((Get-StepPublicNetworks -Profiles $Nets) -join ',')
# Running sshd with an old Any-profile rule: elevate once to narrow it.
$global:Sshd = New-Object PSObject -Property @{ Status = 'Running'; StartType = 'Automatic' }
function global:Test-StepSshFirewallScoped { $false }
$Before = $global:ElevLog.Count
Invoke-SshServerStep -Items @('ssh-server') -IsAdmin $true | Out-Null
Check 'sshd-narrows-old-rule' '1' ([string]($global:ElevLog.Count - $Before))
function global:Test-StepSshFirewallScoped { $true }
```

The existing `sshd-idempotent` test must stub `Test-StepSshFirewallScoped` to `$true` before it runs. Put the stub next to the `Get-StepSshdService` stub, and `Remove-Item Function:\Test-StepSshFirewallScoped` in the cleanup line.

- [ ] **Step 2: Run** `make test-windows` (the container fallback works from Linux). Expect the new checks to FAIL.

- [ ] **Step 3: Implement.**
  - In `Get-StepSshServerScript`, add `-Profile Private,Domain` to both `Set-NetFirewallRule` and `New-NetFirewallRule`, and update the comment on why.
  - Add:

```powershell
# True when the sshd firewall rule only admits the local subnet on trusted
# (Private, Domain) networks. Reading rules needs no admin rights.
function Test-StepSshFirewallScoped {
  param([object]$Rule = $null, [object]$Filter = $null)
  if ($Rule -eq $null) {
    try { $Rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction Stop } catch { return $false }
  }
  if ($Filter -eq $null) {
    try { $Filter = $Rule | Get-NetFirewallAddressFilter -ErrorAction Stop } catch { return $false }
  }
  $Prof = [string]$Rule.Profile
  if ($Prof -notmatch 'Domain' -or $Prof -notmatch 'Private' -or $Prof -match 'Public|Any') { return $false }
  return ([string]$Filter.RemoteAddress -eq 'LocalSubnet')
}

# Names of connected networks Windows treats as Public; the rule does not apply there.
function Get-StepPublicNetworks {
  param([object[]]$Profiles = $null)
  if ($Profiles -eq $null) {
    try { $Profiles = @(Get-NetConnectionProfile -ErrorAction Stop) } catch { return @() }
  }
  $Out = @()
  foreach ($P in $Profiles) { if ([string]$P.NetworkCategory -eq 'Public') { $Out += [string]$P.Name } }
  return $Out
}
```

  - In `Invoke-SshServerStep`, the early return becomes `if ((Test-StepSshdRunning) -and (Test-StepSshFirewallScoped)) { … ok …; Write-StepPublicNetworkWarning; return }`. After a successful install, call the same warning helper:

```powershell
function Write-StepPublicNetworkWarning {
  param([object[]]$Profiles = $null)
  foreach ($N in (Get-StepPublicNetworks -Profiles $Profiles)) {
    Write-StepWarn ("network '" + $N + "' is Public, so sshd is not reachable on it. If you trust it: Settings > Network & internet > " + $N + " > Network profile type > Private")
  }
}
```

- [ ] **Step 4: The user verifies on a real Windows machine** (the container has no NetSecurity module). Run `make windows ARGS="-Verify"`, then a real run with the step ticked on a machine that already has the old rule. Confirm `Get-NetFirewallRule -Name OpenSSH-Server-In-TCP | Select Profile` shows `Domain, Private`, and that `RemoteAddress` reads exactly `LocalSubnet` (the string comparison in `Test-StepSshFirewallScoped` depends on it).
- [ ] **Step 5: Commit** `fix(windows): sshd firewall rule only on Private and Domain networks; narrow existing rules`.

### Task 7: `bootstrap.ps1` hands off honestly

**Files:** `bootstrap.ps1`, `.github/workflows/ci.yml`, `README.md`.

- [ ] **Step 1: Failing CI change first.** In the `windows` job, replace `INSTALL_ITEMS: wezterm,vlc` with a saved config, and assert on the dry-run output and the exit status:

```yaml
        run: |
          $cfg = Join-Path $env:USERPROFILE '.local\bootstrap'
          New-Item -ItemType Directory -Force $cfg | Out-Null
          [IO.File]::WriteAllText("$cfg\config", "terminals.wezterm=1`nwin-apps.vlc=1`n")
          $out = .\bootstrap.ps1 *>&1 | Out-String
          Write-Output $out
          if ($out -notmatch 'would install extras/vlc') { throw 'vlc not planned' }
          if ($out -notmatch 'would install WezTerm') { throw 'wezterm not planned' }
          if (-not (Test-Path "$env:USERPROFILE\install\.source")) { throw 'no .source' }
```

- [ ] **Step 2: Implement in `bootstrap.ps1`.**
  - Delete the fallback installer (`# --- Scoop and git ---` through the summary, lines 125-222) and `$wanted`/`$results`/`Add-Result`/`Invoke-Native`, which only it used. `Get-BackupPath` stays (the repo move uses it).
  - Validate the download by `setup.ps1` instead of `catalog.txt`: `if (-not (Test-Path (Join-Path $top.FullName 'setup.ps1'))) { Write-Error 'no setup.ps1 in the download'; return }`.
  - After `& powershell.exe … -File $setup @a`, add `if ($LASTEXITCODE) { Write-Error "setup.ps1 failed (exit $LASTEXITCODE); see the log above" }`. **No `exit`**: under `irm | iex` it would close the user's PowerShell.
  - Header: drop `INSTALL_ITEMS` and the "When the repo ships setup.ps1" line. Say that the selection comes from the menu or `~\.local\bootstrap\config`.
- [ ] **Step 3: Verify locally.** Parse check with `make lint` (or `pwsh` when present). The user runs the Windows dry run by hand; CI is not triggered.
- [ ] **Step 4: Commit** `fix(bootstrap.ps1): drop the dead fallback installer; report setup.ps1 failures`.

### Task 8: Alias loader in `~/.bashrc` on Linux

**Files:** `setup.sh` (`install_configs`, `install_aliases`, `check_item`, new `bash_rc_file`), `tests/test_setup.sh:125-160`, `tests/docker_matrix.sh:31`, `README.md:302,328`.

- [ ] **Step 1: Failing tests.**

```bash
# Linux with the Arch/Fedora skeleton: .bash_profile sources .bashrc. The loader
# goes to .bashrc (non-login terminals read only that); .bash_profile is untouched.
ah3="${WORK}/alias_home3"; mkdir -p "${ah3}"
printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' >"${ah3}/.bash_profile"
printf '# rc\n' >"${ah3}/.bashrc"
cp "${ah3}/.bash_profile" "${WORK}/profile3.orig"
TARGET_HOME="${ah3}" install_aliases arch >/dev/null
check linux-loader-in-bashrc "1" "$(grep -c 'source ~/.bash_extras' "${ah3}/.bashrc")"
check linux-profile-untouched "same" "$(cmp -s "${WORK}/profile3.orig" "${ah3}/.bash_profile" && echo same)"
check linux-nonlogin-loads "mkcd" "$(HOME="${ah3}" bash -i -c 'type -t mkcd >/dev/null && echo mkcd' 2>/dev/null)"
# Upgrade: an old loader in .bash_profile stays; .bashrc gets one; a note says so.
ah4="${WORK}/alias_home4"; mkdir -p "${ah4}"
printf 'if [ -f ~/.bash_extras ]; then\n    source ~/.bash_extras\nfi\n' >"${ah4}/.bash_profile"
out="$(TARGET_HOME="${ah4}" install_aliases fedora 2>&1)"
check linux-upgrade-bashrc "1" "$(grep -c 'source ~/.bash_extras' "${ah4}/.bashrc")"
check linux-upgrade-profile-kept "1" "$(grep -c 'source ~/.bash_extras' "${ah4}/.bash_profile")"
check linux-upgrade-note "1" "$(grep -c 'can be removed' <<<"${out}")"
```

Change the existing `ah2` case (line 144) to call `install_aliases macos`. Its assertions (loader in `.bash_profile`) then pin the macOS rule.

- [ ] **Step 2: Run.** Expect the `linux-*` checks to FAIL.
- [ ] **Step 3: Implement.**

```bash
# The bash startup file for the alias loader. Linux terminals start non-login
# shells, which read only ~/.bashrc; login shells reach it through the
# ~/.bash_profile (Arch, Fedora) or ~/.profile (Debian) the distro ships.
# macOS terminals start login shells: there ~/.bash_profile, when it exists.
bash_rc_file() {
  if [[ "${1:-}" == "macos" && -f "${TARGET_HOME}/.bash_profile" ]]; then
    printf '%s\n' "${TARGET_HOME}/.bash_profile"
  else
    printf '%s\n' "${TARGET_HOME}/.bashrc"
  fi
}
```

  - `install_configs` passes `"${family}"` to `install_aliases`. `install_aliases` takes `family="${1:-}"` and sets `rc="$(bash_rc_file "${family}")"` in place of the two-line pick.
  - After the loader is written to `.bashrc` on a non-macOS family, `grep -qsF 'source ~/.bash_extras' "${TARGET_HOME}/.bash_profile"` → `info "an older alias loader in ${TARGET_HOME}/.bash_profile can be removed; ~/.bashrc loads the aliases now"`.
  - `check_item configs.aliases` uses `bash_rc_file "${family}"` too, so the check agrees with the install.
  - `tests/docker_matrix.sh:31`: `rc=~/.bashrc` (Linux only, so no macOS branch is needed there).
  - README lines 302 and 328: describe the per-OS rule and the upgrade note.
- [ ] **Step 4:** `make check`, `make test-bash32` (macOS dry run), and `make test-docker` if available: Arch and Fedora images are the ones that matter. **Step 5: Commit** `fix(aliases): load from ~/.bashrc on Linux so non-login terminals get them`.

### Task 9: Private state directories; Arch upgrade in the plan

**Files:** `setup.sh` (`start_run`, `install_configs`, `print_plan`), tests.

- [ ] **Step 1: Failing tests.** After a real `run_main --yes` with stubs, `check state-dir-private "700" "$(stat -c %a "${m_home}/.local/bootstrap" 2>/dev/null || stat -f %Lp …)"`. After `install_configs` with `configs.tmux` ticked, the same check for `${TARGET_HOME}/.local/share/tmux/resurrect`. For the plan: with `OS_RELEASE_FILE` set to Arch and the default selection, `run_main --dry-run` output contains `full system upgrade (pacman -Syu)`, and with `--no-packages` it does not.
- [ ] **Step 2: Run** and see them FAIL.
- [ ] **Step 3: Implement.**
  - `start_run`: after the dry-run return, `mkdir -p "${state}" && chmod 700 "${state}"` (best effort with `|| warn`). `config_save` also creates this directory; add the same `chmod` there.
  - `install_configs`: when `configs.tmux` is ticked, `run mkdir -p "${TARGET_HOME}/.local/share/tmux/resurrect"` and `run chmod 700` it. Comment: the saved panes can hold anything that was on screen; tmux.conf comes from the dotfiles repo, so the setting is protected here instead of edited.
  - `print_plan` takes `family`. When it is `arch` and any `pkg` item is ticked, print `  note    on Arch, installing a missing package runs a full system upgrade (pacman -Syu)`. Callers pass `"${family}"`.
- [ ] **Step 4:** `make check`. **Step 5: Commit** `fix: keep logs, config and tmux saves private; name the Arch full upgrade in the plan`.

### Task 10: (dropped: CI stays manual-only, see D11)

### Task 11: Docs and final verification

- [ ] README: the SSH section gains "What local network means": the allowed ranges, that global IPv6 and Tailscale/CGNAT (`100.64.0.0/10`) are refused, how to add a site-specific allowance as your own drop-in, the lock-out check, and the fail-closed rule. The Windows section gains the Private/Domain profile note.
- [ ] `make check`, `make test-bash32`, `make test-docker`, `make test-windows`. Every one green, or a failure explained in the PR.
- [ ] One manual end-to-end on a throwaway VM (Ubuntu 24.04 with systemd), reached over SSH from a **public** address, with `--ssh-server --ssh-local-only`. Expect: the restriction step FAILS with the lock-out message, sshd keeps running (it ran before), and the session stays alive. Repeat from the LAN: the restriction applies, and a new login from outside is refused.

---

## Self-Review

**Coverage of the audit.** Every P0/P1 item maps to a task or to a reasoned row in *Deferred or rejected*: S1 → T5, S2 → T6, S3 → T4, S4 → rejected/deferred, S5 → T9, S6 → D6 + T11, S7 → dropped, S8 → deferred. Bugs 1-3 → T1-T3, bug 4 → T8, bug 5 → T7, bug 6 (dry-run Include message) → not planned: it is cosmetic and only shows on a dry run without cached sudo. Bug 7 → T3 plus the follow-up batch. Bug 8 → follow-up batch. Stability items → T9 (Arch) and the follow-up batch.

**Where this plan could still be wrong** (verify while implementing, do not assume):
1. `sshd -T -C` key support on old OpenSSH. `laddr` and `lport` are long supported, but RHEL 8 (OpenSSH 8.0) is the oldest target: run the Rocky 9 image *and* an Alma 8 container by hand before merging T4. If an old sshd rejects a key, T4's "unverifiable → denied" rule makes the step fail safe, not open.
2. The Windows `Profile` and `RemoteAddress` string forms (`'Domain, Private'`, `'LocalSubnet'`) come from documentation, not from a run. T6 Step 4 is mandatory for that reason.
3. `systemctl disable --now ssh.socket ssh` on a Debian without a socket unit: the fallback `|| disable --now ssh` covers it, but only the unit tests check this path. A systemd-enabled Debian VM (T11) is the real proof.
4. Test snippets in T2 and T4 contain known rough edges, flagged inline (`xargs kill` bypasses a function stub; the tmux stub needs a subshell). They are written to show the assertions. Step 2's "watch it fail for the right reason" run is where they get fixed.

**Things deliberately not done here:** no refactor of `setup.sh` structure, no new catalog items, no change to what a default `--yes` run installs. The one exception is that the restriction-before-server order changes the order of steps a user sees in the summary.

---

## Execution Log (2026-11-14, branch `fix/hardening`)

| Task | Commit | Notes |
|---|---|---|
| WIP | `89d75c9` | Committed separately first, as asked |
| 1-3 | `7c05bce` | One commit: same function block, one test block. `again` also verified in a real pty under bash and zsh |
| 4 | `145ab68` | The `-f` fix let the real-sshd match tests run (they were skipped before it) |
| 5 | `b43dbe7`, `245c25b` | Deviation: the "sshd ran before" probe runs only when both SSH items are ticked, so ordinary runs make no extra `systemctl`/`netstat` call |
| 6 | `a7193c6` | Container tests green except the two below. **Real-Windows check (Step 4) is the user's** |
| 7 | `575d000` | Parse and ASCII checked in the pwsh container. CI not triggered (manual-only) |
| 8 | `5a3f8c5` | The distro matrix now fails if non-login bash lacks the aliases (it used to fall back to a login shell) |
| 9 | `774e62a` | |
| 10 | dropped | D11 |
| 11 | `70dcadb` | Correction found while writing it: a second drop-in **cannot** allow a range, because sshd adds `DenyUsers` lines up (checked with `sshd -T`). The README says to edit the Match list and untick the item |

**Found, not fixed (outside this plan):**
- `tests/test_windows.ps1`: `sshd-declined-check-skipped` and `sshd-restart-check-skipped` fail in the Linux container before and after this work: the check step counts `git` and `make` as missing there. Expected to pass on Windows with both installed.
- The manual Windows CI job runs elevated, and `setup.ps1` refuses to run elevated without Scoop. Before Task 7 that failure was swallowed; now `bootstrap.ps1` reports it. If the job fails there, that is the reason, not the config change.

**Still open:** Task 6 Step 4 (real Windows), Task 11's VM end-to-end over SSH from a public address, and the follow-up batch.
