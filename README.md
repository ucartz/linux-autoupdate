# linux-autoupdate

One command to find and install every update on a Linux server, and one more to
keep it updated automatically. It detects your distribution, updates the
kernel, PHP and everything else, repairs common problems on its own, and tells
you in plain words whether the server is up to date.

Created by Ucartz. Current version: **2.3.0**

## Quick start

Run as root (or put `sudo` before `bash`). Nothing needs to be installed first.

**Find and install all updates now**

```sh
curl -fsSL https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.3.0/auto-update.sh | sudo bash
```

**Only look, change nothing**

```sh
curl -fsSL https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.3.0/auto-update.sh | sudo bash -s -- check
```

**Install the tool and turn on weekly automatic updates, in one command**

```sh
curl -fsSL https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.3.0/auto-update.sh -o /usr/local/sbin/auto-update.sh && chmod +x /usr/local/sbin/auto-update.sh && auto-update.sh install --enable
```

Other options for the first command: `-- --security` (security updates only),
`-- --php-only`, `-- --reboot` (reboot if needed), `-- --allow-major` (also
install risky updates; alias `--allow-risky`) and `-- --backup` (back up first). No `curl`? Use
`wget -qO- <url> | sudo bash` instead. Prefer to read the script first? See
[Verify the download](#verify-the-download).

### How to read the result

Every run ends with a `STATUS:` line, so there is never a doubt:

| You see | Meaning |
|---------|---------|
| `STATUS: UP TO DATE` | Nothing is waiting to be installed. |
| `STATUS: UPDATES PENDING` | Updates are available (`check` only). Run the command again without `check` to install them. |
| `STATUS: UPDATED, BUT RISKY UPDATE(S) HELD BACK ...` | Everything else was installed, but a risky update was held back for your review: a major-version change to a sensitive package (database, PHP, web server, OpenSSL...) or a Docker engine update that would restart your running containers. See [Major updates](#major-updates-and-backups) and [Servers running Docker](#servers-running-docker-and-azuracast). |
| `STATUS: REBOOT REQUIRED` | Updates are installed, but a reboot is needed to load the new kernel. |
| `STATUS: CANNOT CONFIRM ...` | The package sources have a problem (unreachable, expired, or the OS release is end-of-life), so "up to date" cannot be trusted. The log line above it says what to fix. |
| `STATUS: NOT UP TO DATE` | The update failed or was refused. |
| `NOTE: ... phased rollout` | Ubuntu is releasing a few updates to servers in stages. They install by themselves later; no action needed. |

When a run installs updates it also says
`SUCCESS: update completed - N package(s) updated to the latest version and fixed (patches applied).`
or, if there was nothing to do, `Nothing found - no updates available.`

### What it handles for you

| Problem on the server | What the script does |
|-----------------------|----------------------|
| A Docker engine update on a server with running containers (it restarts all of them) | Holds it back in scheduled runs and tells you; asks in a terminal. Never restarts Docker behind your back. |
| A risky major-version update (for example MariaDB 10.6 to 10.11, PHP 8.3 to 8.4) | Shows a heads-up. In a terminal it asks; in scheduled runs it holds that package back, installs the rest and notifies you. |
| You want a safety net | Offers a backup before major updates (external server over SSH, another disk, or this server), and can back up before every run. If a requested backup fails, no updates are installed. |
| Not logged in as root | Re-runs itself with `sudo`, or prints the exact command to use. |
| Another update holds the package lock (for example Ubuntu's own boot-time updates) | Waits for the lock instead of failing. |
| Mirror or network hiccup | Retries the package list refresh 3 times. |
| One dead extra repository (an old PPA) | Continues with the repositories that work and warns about the broken one. |
| All repositories unreachable | Fails clearly, with a DNS/network hint. Never reports "up to date" by mistake. |
| Expired repositories or an end-of-life OS release | Warns that the result cannot be trusted and points to the fix. |
| Interrupted install (half-configured packages) | Repairs the package system before updating. |
| Update fails part-way | Repairs, then retries once. |
| Low disk space | Cleans the package cache, then stops with a clear message if there is still not enough room. |
| Package installs that ask questions | Runs fully non-interactive and keeps existing config files. |
| SSH connection drops mid-update | The update keeps running. |
| Two updates started at once | The second waits (when run by hand) or exits (when scheduled). |
| Ubuntu phased updates | Lists them separately so `check` and the result agree. |
| A reboot is needed | Says so on the last line; reboots automatically only if you allow it, and only when it is safe. |
| No systemd | Uses cron (`enable --cron` forces cron anywhere). |
| No config file | Works with safe defaults; the config is optional. |
| cPanel / Plesk | Refuses to touch the OS packages and points to the panel's updater. |

## Supported distributions

The script picks the package manager it finds, in this order:

| Package manager | Typical distributions                        | Security-only updates |
|-----------------|----------------------------------------------|-----------------------|
| `apt`           | Debian, Ubuntu                               | yes                   |
| `dnf`           | Fedora, RHEL / AlmaLinux / Rocky 8+          | yes                   |
| `yum`           | CentOS 7 and other older RHEL-family systems | yes (needs the yum security plugin on EL7) |
| `zypper`        | openSUSE, SUSE Linux Enterprise              | yes                   |
| `pacman`        | Arch Linux                                   | no                    |
| `apk`           | Alpine Linux                                 | no                    |

Snap and Flatpak applications update themselves and are not touched.

## Install

The quick-start command above installs the pinned `v2.3.0` release and enables
the schedule. To install without enabling it:

```sh
curl -fsSL https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.3.0/auto-update.sh -o /usr/local/sbin/auto-update.sh && chmod +x /usr/local/sbin/auto-update.sh && auto-update.sh install
```

```sh
vi /etc/linux-autoupdate.conf     # review the settings
linux-autoupdate check            # see what is pending, changes nothing
linux-autoupdate enable           # turn on the schedule
```

`install` copies the script to `/usr/local/sbin/linux-autoupdate`, creates
`/etc/linux-autoupdate.conf` (if missing), a logrotate rule and the systemd
units, and leaves auto-updates **disabled** until you run `enable` (or use
`install --enable`).

### Verify the download

The SHA256 checksum of `auto-update.sh` for v2.3.0 is:

```
af3cc73c83998491280718eb207d8e29f1bd5a0006c42ee79b3a5d66de44b637
```

To verify, download the script and its checksum file into the same directory
and check them before running anything:

```sh
curl -fsSLO https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.3.0/auto-update.sh
curl -fsSLO https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.3.0/auto-update.sh.sha256
sha256sum -c auto-update.sh.sha256
```

Expected output: `auto-update.sh: OK`

## Commands

Run as root; as a normal user the script re-runs itself with `sudo`.

| Command             | What it does |
|---------------------|--------------|
| `install [--enable [--cron]]` | Copy itself to `/usr/local/sbin/linux-autoupdate`, create the config, logrotate rule and timer. With `--enable` it also turns the schedule on. Safe to re-run to upgrade the binary; an existing config is never overwritten. |
| `enable [--cron]`   | Enable and start the systemd timer (falls back to a cron entry when systemd is not available; `--cron` forces cron). Re-run it after changing `SCHEDULE` or `RANDOM_DELAY`. |
| `disable`           | Stop and disable the timer / remove the cron entry. |
| `status`            | Show enabled/disabled, next scheduled run, last run time and result, whether the system is up to date, pending update count, reboot required yes/no, release upgrade availability and livepatch status. |
| `run`               | Perform the updates. Silent, writes to the log only. This is what the timer and cron run. |
| `check`             | List pending updates and change nothing. |
| `release-upgrade`   | Ubuntu only: review a new OS release, back up, and upgrade (see below). Interactive. |
| `uninstall`         | Remove the timer, cron entry, logrotate rule and binary. Config, logs and state are kept unless you add `--purge`. |

The options from version 1 still work as aliases:

| Option        | Same as                                                         |
|---------------|-----------------------------------------------------------------|
| *(none)*      | Update everything now, printing progress to the terminal.       |
| `--check`     | `check`                                                         |
| `--php-only`  | Update only PHP packages (overrides `UPDATE_MODE` for this run). |
| `--security`  | Install security updates only (overrides `UPDATE_MODE` for this run). |
| `--allow-major` (or `--allow-risky`) | Also install risky updates: major-version changes of sensitive packages and Docker engine updates that restart running containers (otherwise asked about or held back). |
| `--backup`    | Back up first: in a terminal you choose the destination; otherwise `BACKUP_DESTINATION` is used. |
| `--reboot`    | Reboot if a reboot is required (see [Reboots](#reboots)).        |
| `--version`   | Print the version.                                              |

Every action is logged to `/var/log/auto-update.log` (rotated weekly, 8 kept,
compressed). The last run is also recorded in
`/var/lib/linux-autoupdate/state`, which `status` reads.

### Terminal versus scheduled runs

Run by hand (`linux-autoupdate`, `check`, `status`, ...) the script prints a
banner, short `==>` progress lines for each step and the command output, and
ends with the `STATUS:` line.

Run by the timer or cron (`run`) it prints nothing and only writes to the log.
If someone has a terminal open when a scheduled run finishes, a one-line result
is shown there (`NOTIFY_TERMINALS`).

## Automatic updates with cron

`enable` uses a systemd timer when systemd is present and cron otherwise.
To use cron on any system:

```sh
linux-autoupdate enable --cron
```

That writes `/etc/cron.d/linux-autoupdate` (or root's crontab on Alpine) with
your `SCHEDULE`, and an `@reboot` entry for the post-reboot health check. If
you prefer your own entry, this is all it needs:

```cron
0 3 * * 0 /usr/local/sbin/linux-autoupdate run
```

## Configuration

`/etc/linux-autoupdate.conf` is sourced as bash and contains comments for every
option. The script refuses to load it unless it is owned by root and not
group/world-writable. The installer creates it with mode `600`.

| Option | Default | Meaning |
|--------|---------|---------|
| `SCHEDULE` | `Sun 03:00` | systemd `OnCalendar` format. With the cron fallback only `[Day[,Day]] HH:MM`, `daily` and `weekly` work. |
| `RANDOM_DELAY` | `30m` | Random delay added to each run (`RandomizedDelaySec`). |
| `UPDATE_MODE` | `all` | `all`, `security` or `php`. |
| `REBOOT_POLICY` | `never` | `never`, `auto` or `window`. |
| `REBOOT_WINDOW` | `Sun 03:00-05:00` | Used when the policy is `window`. Days are optional; the window may cross midnight. |
| `SKIP_REBOOT_IF_USERS` | `1` | Skip the reboot while interactive (SSH/terminal) users are logged in. |
| `MAX_LOAD` | `4.0` | Skip the reboot while the 1-minute load average is above this. |
| `EXCLUDE_PACKAGES` | *(empty)* | Space-separated globs that are never updated, e.g. `"mysql* mariadb*"`. |
| `PRE_UPDATE_HOOK` | *(empty)* | Command run before updating (for example a snapshot). If it fails, the update is aborted. |
| `NOTIFY` | `failure` | `never`, `failure` or `always`. |
| `NOTIFY_EMAIL` | *(empty)* | Needs `mail`, `mailx` or `sendmail` on the server. |
| `NOTIFY_WEBHOOK` | *(empty)* | Slack or generic webhook that accepts `{"text": "..."}`. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | *(empty)* | Telegram notifications. |
| `ALLOW_ON_PANELS` | `0` | Refuse to update on cPanel/Plesk servers unless set to `1`. |
| `NOTIFY_TERMINALS` | `1` | After a scheduled run, print the result on any terminal that is open (SSH/console). Nothing is shown when nobody is logged in. |
| `RELEASE_UPGRADE_CHECK` | `1` | Check for a new Ubuntu release after each run and report it. It is never installed automatically. |
| `BACKUP_PATHS` | `/etc /var/www /home /root /var/spool/cron /opt /srv` | What a backup contains. |
| `MAJOR_UPDATES` | `hold` | `hold`: ask in a terminal, hold back in scheduled runs. `allow`: install major-version updates (a warning is still logged). |
| `RISK_PACKAGES` | PHP, MySQL/MariaDB/PostgreSQL, nginx, Apache, OpenSSL, libc, Docker/Podman, Redis, MongoDB, OpenSSH... | Packages treated as sensitive (globs). |
| `BACKUP_BEFORE_UPDATE` | `no` | `no`, `major` (before major-version updates) or `always` (before every run that has updates). |
| `BACKUP_DESTINATION` | *(empty)* | Where unattended backups go: `user@host:/path` (SSH key login), a directory on another disk, or empty for `/var/backups/linux-autoupdate` on this server. |
| `BACKUP_KEEP` | `3` | Keep this many backups in the destination (`0` keeps all). |

### Major updates and backups

Before installing, the script looks at the pending updates. Packages that can
change how a server behaves (the kernel, PHP, databases, web servers, OpenSSL,
libc, container runtimes... see `RISK_PACKAGES`) are listed under
**Heads-up - review before installing**:

- **Major version change** (the `major.minor` version changes, e.g. MariaDB
  10.6 to 10.11): in a terminal you are asked whether to install it, with
  *no* as the default. In a scheduled run or a piped one-liner it is **held
  back**, the other updates install, and you are notified. Install it later with
  `linux-autoupdate --allow-major --backup`, or set `MAJOR_UPDATES="allow"`.
- **Same major version** (patch-level): listed so you know services may restart.
- **Kernel**: listed; a reboot is needed to use it.

**Backup options.** When you agree to a major update (or use `--backup`), you
choose where the backup goes:

1. an **external server** over SSH (`user@host:/path`), recommended;
2. a **different disk or mount** on this server;
3. **this server**, same disk (quick, but lost if the disk or server fails);
4. an existing **snapshot** you confirm you can restore;
5. **no backup** (you must type `NO BACKUP`);
6. cancel.

For unattended runs set `BACKUP_BEFORE_UPDATE` (`major` or `always`) and
`BACKUP_DESTINATION`. External servers need SSH **key** login and must already be
in `known_hosts` (run `ssh user@host` once by hand). If a requested backup fails,
**no updates are installed** and you are notified. Each backup holds the files in
`BACKUP_PATHS`, MySQL/MariaDB and PostgreSQL dumps when those are running,
package lists, checksums and a `RESTORE.txt`, and is verified before updating.
Old backups beyond `BACKUP_KEEP` are removed from the destination (only the ones
this tool created).

### Servers running Docker and AzuraCast

Updating the Docker engine (`docker-ce`, `docker.io`, `containerd.io`...)
restarts the Docker daemon, which stops **every running container** unless
`live-restore` is enabled in `/etc/docker/daemon.json`. On a radio server that
means every stream drops. When containers are running and `live-restore` is off,
the script therefore:

- lists engine updates under **DOCKER ENGINE** in the heads-up;
- holds them back in scheduled runs and piped one-liners (the rest still
  installs and you are notified), and asks in a terminal (default no);
- installs OS updates in `needrestart` list-only mode, so no service is restarted
  behind your back, and lists the services still running old libraries so you can
  restart them in a quiet moment;
- installs engine updates only with `--allow-risky`, when you choose to.

**AzuraCast** is detected automatically (`/var/azuracast` or an `azuracast`
container). Its station data lives in Docker volumes, which are **not** part of
this tool's file backup, so the tool reminds you to back it up with AzuraCast's
own command (`cd /var/azuracast && ./docker.sh backup`) or a server snapshot
before risky changes. Update AzuraCast itself with `./docker.sh update`. A
release upgrade on such a server warns that Docker restarts and the streams
drop.

### Security-only updates

`UPDATE_MODE="security"` (or `--security` for one run) installs only security updates:

- **apt:** packages whose update comes from the distribution's security
  pocket (for example `jammy-security`, `stable-security`).
- **dnf / yum:** `upgrade --security`.
- **zypper:** `patch --category security`.
- **pacman / apk:** not supported. A warning is logged and **nothing is
  updated**; the script never silently falls back to a full update.

### Exclusions

Packages matching `EXCLUDE_PACKAGES` are protected for the duration of a run
only: `apt-mark hold` on apt, `--exclude` on dnf/yum, `zypper addlock`,
`--ignore` on pacman, and a filtered upgrade list on apk. Holds and locks are
released afterwards, and holds you set yourself are left untouched.

## Reboots

A reboot happens only if all of these are true:

1. a reboot is required (new kernel or core libraries), and
2. `REBOOT_POLICY` allows it, and for `window` the current time is inside
   `REBOOT_WINDOW`, and
3. no interactive users are logged in (if `SKIP_REBOOT_IF_USERS=1`), and
4. the 1-minute load is below `MAX_LOAD`.

Otherwise the reason is logged and the reboot is recorded as pending, which
`status` shows. The reboot itself is scheduled with `shutdown -r +1`.

`--reboot` keeps the version 1 meaning of "reboot now if needed": it ignores the
policy, window, user and load checks. It never reboots after a run that reported
errors.

### Livepatch

The script detects Canonical Livepatch (`canonical-livepatch status`),
KernelCare (`kcarectl --info`) and kpatch (`kpatch list`). It does not install
or license them. When one is active, `status` and the log report it, and the
server is **not rebooted just for a kernel update**. A reboot is still
considered if something other than the kernel needs one. Livepatch does not
replace occasional reboots: schedule one yourself from time to time.

On RHEL-family systems the split between "kernel only" and "other reasons" is
parsed from `needs-restarting -r` and is best effort.

### Post-reboot health check

Before it reboots, the script records which of nginx, Apache (`apache2` /
`httpd`), PHP-FPM and MySQL/MariaDB were running. After boot, a small systemd
service checks that they are active again (waiting up to two minutes), restarts
any that are not once, logs the result, sends a notification according to
`NOTIFY`, and removes the marker. Under cron, an `@reboot` entry does the same.

## Release upgrades (Ubuntu)

When Ubuntu offers a new release, for example the `26.04.1 LTS` notice shown at
login, every run reports it: in the log, in `status`, and on any open terminal.
The upgrade itself is **never** started by the timer or cron, because it needs
a person to decide and to watch.

In a terminal, after an update (or when nothing needed updating), the script
shows the pros and cons and asks:

- **yes** - continue to the safe upgrade process below;
- **no** (the default) - nothing changes; you keep the current release with all
  the latest updates installed.

You can also start it yourself at any time:

```sh
linux-autoupdate release-upgrade
```

**The safe process**

1. Safety checks, each shown as `[ ok ]`, `[warn]` or `[FAIL]`: no cPanel/Plesk,
   system fully updated, package system healthy (repaired if not), no reboot
   pending, no held packages, enough disk space, third-party repositories,
   and whether you are on SSH outside tmux/screen. A `[FAIL]` stops the upgrade.
2. Backup. You choose:
   1. an **external server** over SSH (`user@host:/path`), recommended;
   2. a **different disk or mount** on this server;
   3. **this server**, same disk (quick, but lost if the disk or server fails);
   4. an **existing snapshot/backup** you confirm you can restore;
   5. **no backup needed** (you must type `NO BACKUP`);
   6. cancel.
   A backup contains the paths in `BACKUP_PATHS`, MySQL/MariaDB and PostgreSQL
   dumps when those are running, package lists, checksums and a `RESTORE.txt`.
   It is verified before the upgrade starts.
3. A final confirmation, then the upgrade runs with automatic repair: if it is
   interrupted, the package system is repaired and the upgrade is retried (up to
   3 attempts).
4. Afterwards the script checks the package system, finishes anything left
   half-done, and restarts any web/PHP/database service that is not running.
   It then offers a reboot; a health check runs after boot.

A release upgrade cannot be rolled back; if it fails, the only way back is
your backup or snapshot, and the script tells you where it is. Other
distributions are not supported by this command yet.

## Upgrading from earlier versions

Run the install command above. `install` replaces `/usr/local/sbin/auto-update.sh`
with a symlink to `/usr/local/sbin/linux-autoupdate` when it is an unmodified
copy of the downloaded script, so existing cron entries keep working. Version
1.0.0 stays available at the `v1.0.0` tag.

Behaviour changes since version 1:

- On **cPanel / Plesk** the script now refuses to update unless
  `ALLOW_ON_PANELS=1` is set (`check` and `status` still work). Version 1 only
  printed a warning.
- Failures now produce a non-zero exit code and a `failure` result.
- `--php-only` on Alpine with no PHP installed no longer upgrades the whole
  system.
- Settings in `/etc/linux-autoupdate.conf` apply to the legacy invocations too.

## Notes

- **Kernel updates need a reboot.** Without a reboot (or an active livepatch) the
  new kernel is not loaded.
- **Updates, not upgrades.** The normal run installs the updates available within
  your current OS release. It does not move PHP to a new minor/major version
  (for example 8.3 to 8.4) and does not change the OS release; on Ubuntu that
  is the separate, confirmed `release-upgrade` command.
- **cPanel / Plesk servers:** use the panel's own updater (`/scripts/upcp` for
  cPanel, `plesk installer update` for Plesk).
- The script holds a lock, so two runs never overlap.

## Disclaimer

Take a backup or snapshot before running this on any server. This software is
provided as is, without warranty of any kind. Use it at your own risk.

## License

[MIT](LICENSE)
