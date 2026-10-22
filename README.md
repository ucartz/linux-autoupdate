# linux-autoupdate

A single bash script that detects your Linux distribution, keeps packages up to
date (kernel and PHP included), and manages the whole job: scheduled runs,
safe reboots, notifications and a post-reboot health check.

Created by Ucartz. Current version: **2.0.0**

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

## Install

Run as root. Download the pinned `v2.0.0` release (not the moving `main`
branch), install it, review the config, then switch the schedule on:

```sh
curl -fsSL https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.0.0/auto-update.sh -o /usr/local/sbin/auto-update.sh && chmod +x /usr/local/sbin/auto-update.sh && auto-update.sh install
```

```sh
vi /etc/linux-autoupdate.conf     # review the settings
linux-autoupdate check            # see what is pending, changes nothing
linux-autoupdate enable           # turn on the schedule
```

`install` copies the script to `/usr/local/sbin/linux-autoupdate`, creates
`/etc/linux-autoupdate.conf` (if missing), a logrotate rule and the systemd
units, and leaves auto-updates **disabled** until you run `enable`.

### Verify the download

The SHA256 checksum of `auto-update.sh` for v2.0.0 is:

```
c644a5a3a140acf3452e94a7b5772f12829106e8e909db5c08424e8646891667
```

To verify, download the script and its checksum file into the same directory
and check them before installing:

```sh
curl -fsSLO https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.0.0/auto-update.sh
curl -fsSLO https://raw.githubusercontent.com/ucartz/linux-autoupdate/v2.0.0/auto-update.sh.sha256
sha256sum -c auto-update.sh.sha256
```

Expected output: `auto-update.sh: OK`

## Commands

All commands must be run as root.

| Command             | What it does |
|---------------------|--------------|
| `install`           | Copy itself to `/usr/local/sbin/linux-autoupdate`, create the config, logrotate rule and timer. Auto-updates stay disabled. Safe to re-run to upgrade the binary; an existing config is never overwritten. |
| `enable`            | Enable and start the systemd timer (falls back to a cron entry when systemd is not available). Re-run it after changing `SCHEDULE` or `RANDOM_DELAY`. |
| `disable`           | Stop and disable the timer / remove the cron entry. |
| `status`            | Show enabled/disabled, next scheduled run, last run time and result, pending update count, reboot required yes/no and livepatch status. |
| `run`               | Perform the updates. Silent, writes to the log only. This is what the timer runs. |
| `check`             | List pending updates and change nothing. |
| `uninstall`         | Remove the timer, cron entry, logrotate rule and binary. Config, logs and state are kept unless you add `--purge`. |

The options from version 1 still work as aliases:

| Option        | Same as                                                         |
|---------------|-----------------------------------------------------------------|
| *(none)*      | Update everything now, printing progress to the terminal.       |
| `--check`     | `check`                                                         |
| `--php-only`  | Update only PHP packages (overrides `UPDATE_MODE` for this run). |
| `--reboot`    | Reboot if a reboot is required (see [Reboots](#reboots)).        |
| `--version`   | Print the version.                                              |

### Terminal versus scheduled runs

Run by hand (`linux-autoupdate`, `check`, `status`, ...) the script prints a
banner, short `==>` progress lines for each step and the command output, and
ends with a clear result: `SUCCESS: update completed - N package(s) updated.`
or `Nothing found - no updates available.`

Run by the timer or cron (`run`) it prints nothing and only writes to the log.
If someone has a terminal open when a scheduled run finishes, a one-line result
is shown there (`NOTIFY_TERMINALS`).

Every action is logged to `/var/log/auto-update.log` (rotated weekly, 8 kept,
compressed). The last run is also recorded in
`/var/lib/linux-autoupdate/state`, which `status` reads.

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

### Security-only updates

`UPDATE_MODE="security"` installs only security updates:

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
service checks that they are active again (waiting up to two minutes), logs the
result, sends a notification according to `NOTIFY`, and removes the marker. Under
cron, an `@reboot` entry does the same.

## Weekly updates

The timer installed by `enable` does this for you. If you prefer your own cron
entry, run the silent command:

```cron
0 3 * * 0 /usr/local/sbin/linux-autoupdate run
```

## Upgrading from version 1

Run the install command above. `install` replaces `/usr/local/sbin/auto-update.sh`
with a symlink to `/usr/local/sbin/linux-autoupdate` when it is an unmodified
copy of the downloaded script, so existing cron entries keep working. Version
1.0.0 stays available at the `v1.0.0` tag.

Behaviour changes to be aware of:

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
- **No major upgrades.** The script installs the updates available within your
  current release. It does not move PHP to a new minor/major version (for
  example 8.3 to 8.4) or upgrade the OS to a new release.
- **cPanel / Plesk servers:** use the panel's own updater (`/scripts/upcp` for
  cPanel, `plesk installer update` for Plesk).
- The script holds a lock, so two runs never overlap.

## Disclaimer

Take a backup or snapshot before running this on any server. This software is
provided as is, without warranty of any kind. Use it at your own risk.

## License

[MIT](LICENSE)
