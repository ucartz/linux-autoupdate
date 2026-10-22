# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - 2026-10-22

### Added
- Initial release of `auto-update.sh`.
- Automatic detection of apt, dnf, yum, zypper, pacman and apk.
- Full update (including kernel and PHP), `--check`, `--php-only` and `--reboot` options.
- `--version` option.
- PHP-FPM / web server restart after updates and reboot-required detection.
- Logging to `/var/log/auto-update.log`.
- SHA256 checksum file and ShellCheck GitHub Actions workflow.
