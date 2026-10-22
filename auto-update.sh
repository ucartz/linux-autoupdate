#!/usr/bin/env bash
# auto-update.sh - Detects the Linux distro and updates all packages
# (kernel, PHP, everything), restarts PHP services, reports reboot need.
#
# Usage:
#   ./auto-update.sh              # update everything
#   ./auto-update.sh --check      # only list available updates, change nothing
#   ./auto-update.sh --php-only   # update only PHP packages
#   ./auto-update.sh --reboot     # reboot automatically if kernel updated
#
set -uo pipefail

VERSION="1.0.0"
LOG="/var/log/auto-update.log"
LOCK="/var/run/auto-update.lock"
MODE="all"
AUTO_REBOOT=0

for arg in "$@"; do
  case "$arg" in
    --check)    MODE="check" ;;
    --php-only) MODE="php" ;;
    --reboot)   AUTO_REBOOT=1 ;;
    -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
    --version)  echo "$VERSION"; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

# Prevent two runs at once
exec 9>"$LOCK"
flock -n 9 || { echo "Another update is already running."; exit 1; }

# ---- Detect OS ----
[[ -f /etc/os-release ]] && . /etc/os-release
log "==== Start: ${PRETTY_NAME:-unknown OS} | kernel $(uname -r) | mode=$MODE ===="

# ---- Warn about control panels that manage their own packages ----
[[ -d /usr/local/cpanel ]] && log "WARNING: cPanel detected - consider /scripts/upcp; EA-PHP is updated via yum/dnf."
[[ -d /usr/local/psa ]]    && log "WARNING: Plesk detected - consider 'plesk installer update'."

# ---- Pick package manager ----
if   command -v apt-get >/dev/null; then PM=apt
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v yum     >/dev/null; then PM=yum
elif command -v zypper  >/dev/null; then PM=zypper
elif command -v pacman  >/dev/null; then PM=pacman
elif command -v apk     >/dev/null; then PM=apk
else log "ERROR: No supported package manager found."; exit 1
fi
log "Package manager: $PM"

PHP_BEFORE=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "none")

run() { log "+ $*"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

case "$PM" in
  apt)
    export DEBIAN_FRONTEND=noninteractive
    APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    run apt-get update
    case "$MODE" in
      check) apt list --upgradable 2>/dev/null | tee -a "$LOG" ;;
      php)   mapfile -t PKGS < <(dpkg-query -W -f='${Package}\n' 'php*' 2>/dev/null)
             [[ ${#PKGS[@]} -gt 0 ]] && run apt-get install --only-upgrade "${APT_OPTS[@]}" "${PKGS[@]}" ;;
      all)   run apt-get dist-upgrade "${APT_OPTS[@]}"
             run apt-get autoremove -y ;;
    esac ;;
  dnf|yum)
    case "$MODE" in
      check) $PM check-update | tee -a "$LOG" ;;
      php)   run $PM -y upgrade 'php*' 'ea-php*' ;;
      all)   run $PM -y upgrade
             [[ $PM == dnf ]] && run dnf -y autoremove ;;
    esac ;;
  zypper)
    run zypper --non-interactive refresh
    case "$MODE" in
      check) zypper list-updates | tee -a "$LOG" ;;
      php)   run zypper --non-interactive update 'php*' ;;
      all)   run zypper --non-interactive update ;;
    esac ;;
  pacman)
    case "$MODE" in
      check) pacman -Sy >/dev/null && pacman -Qu | tee -a "$LOG" ;;
      php)   log "Arch does not support partial upgrades safely; use full update." ;;
      all)   run pacman -Syu --noconfirm ;;
    esac ;;
  apk)
    run apk update
    case "$MODE" in
      check) apk version -l '<' | tee -a "$LOG" ;;
      php)   run apk upgrade $(apk info | grep '^php') ;;
      all)   run apk upgrade ;;
    esac ;;
esac

[[ "$MODE" == "check" ]] && { log "==== Check finished (no changes made) ===="; exit 0; }

# ---- Restart PHP-FPM / web server if PHP changed ----
PHP_AFTER=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "none")
log "PHP: $PHP_BEFORE -> $PHP_AFTER"
if command -v systemctl >/dev/null; then
  for svc in $(systemctl list-units --type=service --state=running --no-legend \
               | awk '{print $1}' | grep -Ei 'php.*fpm'); do
    run systemctl restart "$svc"
  done
  if [[ "$PHP_BEFORE" != "$PHP_AFTER" ]]; then
    for web in apache2 httpd; do
      systemctl is-active --quiet "$web" && run systemctl restart "$web"
    done
  fi
fi
php -v 2>/dev/null | grep -qi ioncube && log "ionCube loader OK" || \
  { command -v php >/dev/null && log "NOTE: ionCube loader not shown in php -v (ignore if not used)."; }

# ---- Does the new kernel need a reboot? ----
NEED_REBOOT=0
if [[ -f /var/run/reboot-required ]]; then
  NEED_REBOOT=1
elif command -v needs-restarting >/dev/null; then
  needs-restarting -r >/dev/null 2>&1 || NEED_REBOOT=1
else
  LATEST=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1)
  [[ -n "$LATEST" && "$LATEST" != "$(uname -r)" ]] && NEED_REBOOT=1
fi

if [[ $NEED_REBOOT -eq 1 ]]; then
  if [[ $AUTO_REBOOT -eq 1 ]]; then
    log "Kernel/core libs updated - rebooting in 1 minute."
    shutdown -r +1 "Rebooting after system updates"
  else
    log "REBOOT REQUIRED to load the new kernel. Run --reboot or reboot manually."
  fi
else
  log "No reboot needed."
fi

log "==== Finished ===="
