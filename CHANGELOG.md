# Changelog

All notable changes to this project are documented in this file.

## [2.3.0] - 2026-10-23

### Added
- Container-host protection: when Docker has running containers and
  `live-restore` is off, Docker engine updates (`docker-ce`, `docker.io`,
  `containerd.io`...) are listed under "DOCKER ENGINE" in the heads-up and held
  back in scheduled runs, because updating them restarts every container. In a
  terminal you are asked (default no). `--allow-risky` (alias of `--allow-major`)
  installs them.
- On those hosts OS updates run with `needrestart` in list-only mode and the
  services still using old libraries are listed, instead of being restarted
  automatically.
- AzuraCast detection: reminds you that its data lives in Docker volumes outside
  this tool's backup and points to `./docker.sh backup`; the release-upgrade
  safety checks warn about running containers and AzuraCast.

### Changed
- The status wording for held updates is now "RISKY UPDATE(S) HELD BACK" because
  it covers both major-version changes and Docker engine updates.

## [2.2.0] - 2026-10-23

### Added
- Risk review before installing: updates to sensitive packages (kernel, PHP,
  MySQL/MariaDB/PostgreSQL, nginx, Apache, OpenSSL, libc, container runtimes,
  see `RISK_PACKAGES`) are listed in a "Heads-up" block in `check`, in terminal
  runs and in the log. A change of `major.minor` version counts as a major
  update.
- Major updates are asked about in a terminal (default no) and held back in
  scheduled runs and piped one-liners; the rest still installs and a
  notification is sent. `--allow-major` or `MAJOR_UPDATES="allow"` installs them.
  `status` shows what is held back.
- Backup before updating: `--backup`, `BACKUP_BEFORE_UPDATE` (`no`, `major`,
  `always`), `BACKUP_DESTINATION` and `BACKUP_KEEP`. Destinations are an
  external server over SSH key login, a directory on another disk, or this
  server. If a requested backup fails, no updates are installed.
- The backup menu now lists external server, different disk and same server as
  separate choices, and is shared by updates and the Ubuntu release upgrade.
- `check` reports when the server already needs a reboot.

### Fixed
- Installed versions of packages with several installed copies (for example
  `glibc` i686 + x86_64, or several kernels) are read correctly.

## [2.1.0] - 2026-10-23

### Added
- One-command use: `curl -fsSL <url> | sudo bash` finds and installs all
  updates, `... | sudo bash -s -- check` only looks, and
  `auto-update.sh install --enable` installs the tool and turns on the schedule
  in a single step. The script now also runs correctly when piped into bash.
- `STATUS:` line at the end of every run and check (`UP TO DATE`,
  `UPDATES PENDING`, `REBOOT REQUIRED`, `CANNOT CONFIRM ...`, `NOT UP TO DATE`)
  so it is always clear whether the server is updated.
- After an update the script reports that packages were updated to the latest
  version and fixed (patches applied).
- Ubuntu phased updates are listed separately from updates that can be
  installed now, so the list and the count agree.
- `release-upgrade` command (Ubuntu): shows the pros and cons of a new release,
  asks yes/no, runs safety checks, offers a backup (different location, this
  server, existing snapshot, or none), upgrades with automatic repair and
  retries, verifies services afterwards and offers a reboot. It is interactive
  and never started by the timer or cron, which only report that a release is
  available (log, `status`, open terminals).
- `--security` option for one-off security-only runs, `enable --cron` to force
  cron, `install --enable`.
- Non-root users: the script re-runs itself with `sudo` or prints the exact
  command to use.
- Gap handling for the update process: waits for the package-manager lock,
  retries the package list refresh, keeps going when a single extra repository
  is broken, repairs an interrupted package install before updating, repairs and
  retries once when an update fails, checks free disk space, runs fully
  non-interactive, ignores SSH hang-ups during an update, and waits for another
  running update instead of failing.
- Detects expired, unreachable or end-of-life repositories and says that the
  result cannot be confirmed instead of reporting "up to date".
- Post-reboot check restarts a service that did not come back, once, before
  reporting it as failed.
- `NOTIFY_TERMINALS`, `RELEASE_UPGRADE_CHECK` and `BACKUP_PATHS` options.

### Changed
- A failed package list refresh now fails the run (it used to be reported as
  success with nothing to do).

### Fixed
- `/etc/os-release` is no longer sourced into the script, which overwrote the
  `VERSION` variable.
- Missing `hostname` command on minimal systems no longer prints errors.

## [2.0.0] - 2026-10-22

### Added
- Management subcommands: `install`, `enable`, `disable`, `status`, `run`,
  `check` and `uninstall` (`--purge` also removes config, logs and state).
- Config file `/etc/linux-autoupdate.conf` with schedule, random delay, update
  mode, reboot policy and window, package exclusions, pre-update hook and
  notification settings. The file is validated and must be root-owned and not
  group/world-writable.
- systemd timer with a cron fallback (including Alpine's crontabs).
- Security-only updates for apt, dnf, yum and zypper (`UPDATE_MODE=security`).
- Package exclusions applied for a single run, with existing holds preserved.
- Livepatch detection for Canonical Livepatch, KernelCare and kpatch; kernel
  updates covered by a livepatch no longer trigger a reboot.
- Reboot policy (`never`, `auto`, `window`) with guards for logged-in users and
  system load; skipped reboots are recorded as pending.
- Post-reboot health check service for nginx, Apache, PHP-FPM and MySQL/MariaDB.
- Notifications by email, webhook and Telegram.
- State file in `/var/lib/linux-autoupdate/state` and logrotate rule for the log.
- Short `==>` progress lines when run from a terminal; scheduled runs stay
  silent and show a one-line result on any open terminal (`NOTIFY_TERMINALS`).
- Terminal output ends with `SUCCESS: update completed - N package(s) updated.`
  or `Nothing found - no updates available.`

### Changed
- On cPanel and Plesk servers updates are refused unless `ALLOW_ON_PANELS=1`
  (v1 only printed a warning). `check` is still allowed.
- A run that hits errors now exits with a non-zero status and never reboots.
- `--reboot` ignores the reboot policy, window, user and load checks (as v1
  did) but still honours an active livepatch.

### Fixed
- `--php-only` on Alpine with no PHP packages installed no longer upgrades the
  whole system.

### Unchanged
- `--check`, `--php-only`, `--reboot` and `--version` still work, and running
  with no arguments still updates everything. Version 1.0.0 remains available
  at the `v1.0.0` tag.

## [1.0.0] - 2026-10-22

### Added
- Initial release of `auto-update.sh`.
- Automatic detection of apt, dnf, yum, zypper, pacman and apk.
- Full update (including kernel and PHP), `--check`, `--php-only` and `--reboot` options.
- `--version` option.
- PHP-FPM / web server restart after updates and reboot-required detection.
- Logging to `/var/log/auto-update.log`.
- SHA256 checksum file and ShellCheck GitHub Actions workflow.
