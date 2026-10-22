# linux-autoupdate

A single bash script that detects the Linux distribution and updates all
packages, including the kernel and PHP. After the update it restarts PHP-FPM
(and Apache/httpd if the PHP version changed) and tells you whether a reboot is
needed.

Current version: **1.0.0**

## Supported distributions

The script picks the package manager it finds, in this order:

| Package manager | Typical distributions                        |
|-----------------|----------------------------------------------|
| `apt`           | Debian, Ubuntu                               |
| `dnf`           | Fedora, RHEL / AlmaLinux / Rocky 8+          |
| `yum`           | CentOS 7 and other older RHEL-family systems |
| `zypper`        | openSUSE, SUSE Linux Enterprise              |
| `pacman`        | Arch Linux                                   |
| `apk`           | Alpine Linux                                 |

## Install

Run as root. This installs the pinned `v1.0.0` release, not the moving `main`
branch, and then runs a read-only check:

```sh
curl -fsSL https://raw.githubusercontent.com/ucartz/linux-autoupdate/v1.0.0/auto-update.sh -o /usr/local/sbin/auto-update.sh && chmod +x /usr/local/sbin/auto-update.sh && auto-update.sh --check
```

### Verify the download

The SHA256 checksum of `auto-update.sh` for v1.0.0 is:

```
0f2a41f10f638d3031bf24a51a618ab364ea3023aea70d50bfc52e5a0b5aa8a4
```

To verify, download the script and its checksum file into the same directory
and check them:

```sh
curl -fsSLO https://raw.githubusercontent.com/ucartz/linux-autoupdate/v1.0.0/auto-update.sh
curl -fsSLO https://raw.githubusercontent.com/ucartz/linux-autoupdate/v1.0.0/auto-update.sh.sha256
sha256sum -c auto-update.sh.sha256
```

Expected output: `auto-update.sh: OK`

## Usage

The script must be run as root. Only one instance can run at a time.

```sh
auto-update.sh [--check] [--php-only] [--reboot] [--version] [-h|--help]
```

| Option       | What it does                                                                 |
|--------------|------------------------------------------------------------------------------|
| *(none)*     | Update all packages, including the kernel and PHP.                           |
| `--check`    | Refresh package metadata and list available updates. Changes nothing.        |
| `--php-only` | Update only PHP packages. On Arch this is skipped (partial upgrades are unsafe). |
| `--reboot`   | If the update requires a reboot, schedule one in 1 minute.                   |
| `--version`  | Print the script version and exit.                                           |
| `-h`, `--help` | Show the built-in usage text.                                              |

Every action is logged to `/var/log/auto-update.log`.

### Examples

```sh
auto-update.sh --check             # see what is pending
auto-update.sh                     # update everything, reboot manually later
auto-update.sh --php-only          # update only PHP packages
auto-update.sh --reboot            # update everything and reboot if required
```

### Weekly updates with cron

Add this to root's crontab (`crontab -e`) to update every Sunday at 03:00:

```cron
0 3 * * 0 /usr/local/sbin/auto-update.sh >/dev/null 2>&1
```

Output is already written to `/var/log/auto-update.log`. Add `--reboot` to the
command if you want the server to reboot itself when a new kernel is installed.

## Notes

- **Kernel updates need a reboot.** Without `--reboot` the script only reports
  `REBOOT REQUIRED` in the log; the new kernel is not loaded until you reboot.
- **No major upgrades.** The script installs the updates available within your
  current release. It does not move PHP to a new minor/major version (for
  example 8.3 to 8.4) or upgrade the OS to a new release.
- **cPanel / Plesk servers:** use the panel's own updater (`/scripts/upcp` for
  cPanel, `plesk installer update` for Plesk). The script logs a warning when it
  detects either panel.

## Disclaimer

Take a backup or snapshot before running this on any server. This software is
provided as is, without warranty of any kind. Use it at your own risk.

## License

[MIT](LICENSE)
