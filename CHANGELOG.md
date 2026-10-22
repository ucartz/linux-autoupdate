# Changelog

All notable changes to this project are documented in this file.

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
