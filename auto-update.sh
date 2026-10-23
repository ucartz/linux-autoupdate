#!/usr/bin/env bash
# linux-autoupdate - detects the Linux distro and keeps packages up to date
# (kernel, PHP, everything), restarts PHP services, handles reboots safely.
#
# Usage: linux-autoupdate <command> [options]
#   install | enable | disable | status | run | check | uninstall [--purge]
# Legacy options (still supported):
#   ./auto-update.sh              # update everything
#   ./auto-update.sh --check      # only list available updates, change nothing
#   ./auto-update.sh --php-only   # update only PHP packages
#   ./auto-update.sh --reboot     # reboot automatically if kernel updated
#   ./auto-update.sh --version
#
set -uo pipefail

VERSION="2.3.0"
PROG="linux-autoupdate"
BIN="/usr/local/sbin/linux-autoupdate"
LEGACY_BIN="/usr/local/sbin/auto-update.sh"
CONF="/etc/linux-autoupdate.conf"
LOG="/var/log/auto-update.log"
LOCK="/var/run/auto-update.lock"
STATE_DIR="/var/lib/linux-autoupdate"
STATE="$STATE_DIR/state"
MARKER="$STATE_DIR/postboot.marker"
LOGROTATE_FILE="/etc/logrotate.d/linux-autoupdate"
UNIT_DIR="/etc/systemd/system"
CRON_FILE="/etc/cron.d/linux-autoupdate"
CRONTABS_ROOT="/etc/crontabs/root"
TIMER_UNIT="linux-autoupdate.timer"
SERVICE_UNIT="linux-autoupdate.service"
POSTBOOT_UNIT="linux-autoupdate-postboot.service"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

CMD=""
LEGACY_CHECK=0
MODE_OVERRIDE=""
FLAG_REBOOT=0
PURGE=0
RANDOM_DELAY_ARG=0
VERBOSE=1

PM=""
PANEL=""
UPDATE_MODE_EFFECTIVE=""
PHP_BEFORE="none"
PHP_AFTER="none"
FAILED=0
SKIPPED=0
RESULT="success"
UPDATED=0
REBOOT_PENDING=0
REBOOT_NOTE=""
RUN_STARTED=0
RUN_FINISHED=0
EXCL=()
EXCL_ARGS=()
HELD=()
LIVEPATCH=""
NEED_REBOOT=0
KERNEL_ONLY=0
REBOOT_REASON=""
W_DAYS="*"
W_START=0
W_END=0
OS_ID=""
OS_PRETTY=""
OS_VERSION_ID=""
RELEASE_AVAILABLE=""
BACKUP_LOCATION=""
PF_FAIL=0
PF_WARN=0
PENDING_AFTER=0
DEFERRED_COUNT=0
RUN_FROM_PIPE=0
FLAG_ENABLE=0
FORCE_CRON=0
FLAG_BACKUP=0
ALLOW_MAJOR=0
MAJOR_HELD=""
MAJOR_HELD_DETAIL=""
MAJOR_BLOCKED=0
CONTAINERS_CHECKED=0
CONTAINERS_RUNNING=0
DOCKER_LIVE_RESTORE=0
AZURACAST=0
LOG_START=0
REFRESH_FAILED=0
REPO_PROBLEM=""
REPO_HINT=""
APT_NET=(-o DPkg::Lock::Timeout=600 -o Acquire::Retries=3 -o APT::Update::Error-Mode=any)

# ---------------------------------------------------------------- helpers ---

now() { date '+%F %T'; }

die() {
  echo "ERROR: $*" >&2
  [[ -w $LOG ]] && echo "[$(now)] ERROR: $*" >>"$LOG"
  exit 1
}

log() {
  local line
  line="[$(now)] $*"
  printf '%s\n' "$line" >>"$LOG"
  if (( VERBOSE )); then printf '%s\n' "$line"; fi
  return 0
}

# Run a command, log it and its output; return the command's exit status.
run() {
  local rc
  log "+ $*"
  if (( VERBOSE )); then
    "$@" 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
  else
    "$@" >>"$LOG" 2>&1
    rc=$?
  fi
  return "$rc"
}

# Like run, but a failure marks the whole run as failed.
pkg_run() { run "$@" || FAILED=1; return 0; }

has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

# Friendly progress line, shown only when run from a terminal (not logged).
say() {
  if (( VERBOSE )); then printf '==> %s\n' "$*"; fi
  return 0
}

# Show a one-line result on every open interactive terminal (used after scheduled runs).
tell_terminals() {
  local msg=$1 tty
  (( NOTIFY_TERMINALS )) || return 0
  [[ $(interactive_sessions) -gt 0 ]] || return 0
  if command -v wall >/dev/null 2>&1; then
    printf '%s\n' "$msg" | wall -n >/dev/null 2>&1 && return 0
  fi
  for tty in $(who 2>/dev/null | awk '$2 ~ /^pts\// {print $2}'); do
    printf '\n%s\n' "$msg" >"/dev/$tty" 2>/dev/null
  done
  return 0
}

banner() { printf '%s %s - created by Ucartz\n\n' "$PROG" "$VERSION"; }

init_log() {
  if [[ ! -e $LOG ]]; then
    : >"$LOG" 2>/dev/null && chmod 0640 "$LOG"
  fi
}

usage() {
  cat <<EOF
$PROG $VERSION - detect the Linux distro and keep packages up to date
Created by Ucartz

Usage: $PROG <command> [options]

Commands:
  install      Copy to $BIN, create the config, logrotate rule and
               timer. Auto-updates stay DISABLED until you run 'enable'
               (or use 'install --enable' to do both in one step).
  enable       Enable and start the systemd timer (cron if no systemd;
               'enable --cron' forces a cron entry instead)
  disable      Stop the timer / remove the cron entry
  status       Show scheduler state, last run, pending updates, reboot and
               livepatch status
  run          Perform updates (used by the timer; silent, log only)
  check        List pending updates, change nothing
  uninstall    Remove timer, cron, logrotate rule and binary; keeps config and
               logs unless --purge is given
  release-upgrade
               Ubuntu only: review a new OS release (pros/cons), back up,
               and upgrade with automatic repair. Interactive; never run
               by the timer or cron.

Legacy options (still supported):
  (no arguments)   update everything
  --check          same as 'check'
  --php-only       update only PHP packages
  --security       security updates only (apt, dnf, yum, zypper)
  --allow-major    also install risky updates (major-version changes of PHP,
                   databases, web servers, OpenSSL... and Docker engine updates
                   that would restart running containers); otherwise they are
                   asked about or held back   (alias: --allow-risky)
  --backup         back up (external server, other disk or this server) first
  --reboot         reboot automatically if a reboot is required
  --version        print the version
  -h, --help       show this help

Config: $CONF    Log: $LOG
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      install|enable|disable|status|run|check|uninstall|release-upgrade|postboot)
        [[ -n $CMD ]] && { echo "Only one command allowed: $CMD, $arg" >&2; exit 1; }
        CMD="$arg" ;;
      --check)    LEGACY_CHECK=1 ;;
      --php-only) MODE_OVERRIDE="php" ;;
      --security) MODE_OVERRIDE="security" ;;
      --allow-major|--allow-risky) ALLOW_MAJOR=1 ;;
      --backup)   FLAG_BACKUP=1 ;;
      --reboot)   FLAG_REBOOT=1 ;;
      --purge)    PURGE=1 ;;
      --enable)   FLAG_ENABLE=1 ;;
      --cron)     FORCE_CRON=1 ;;
      --random-delay=*)
        RANDOM_DELAY_ARG=${arg#*=}
        [[ $RANDOM_DELAY_ARG =~ ^[0-9]+$ ]] || { echo "Bad value for --random-delay" >&2; exit 1; } ;;
      --version)  echo "$VERSION"; exit 0 ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
  done
  if (( LEGACY_CHECK )); then
    case "$CMD" in
      ""|check) CMD="check" ;;
      *) echo "--check cannot be combined with '$CMD'" >&2; exit 1 ;;
    esac
  fi
  [[ -z $CMD ]] && CMD="legacy"
  if (( PURGE )) && [[ $CMD != uninstall ]]; then
    echo "--purge is only valid with 'uninstall'" >&2; exit 1
  fi
  if (( FLAG_ENABLE )) && [[ $CMD != install ]]; then
    echo "--enable is only valid with 'install'" >&2; exit 1
  fi
  if (( FORCE_CRON )) && [[ $CMD != install && $CMD != enable ]]; then
    echo "--cron is only valid with 'install --enable' or 'enable'" >&2; exit 1
  fi
  if (( FORCE_CRON )) && [[ $CMD == install ]] && (( ! FLAG_ENABLE )); then
    echo "--cron needs --enable when used with 'install'" >&2; exit 1
  fi
  return 0
}

# ----------------------------------------------------------------- config ---

set_defaults() {
  SCHEDULE="Sun 03:00"
  RANDOM_DELAY="30m"
  UPDATE_MODE="all"
  REBOOT_POLICY="never"
  REBOOT_WINDOW="Sun 03:00-05:00"
  SKIP_REBOOT_IF_USERS=1
  MAX_LOAD="4.0"
  EXCLUDE_PACKAGES=""
  PRE_UPDATE_HOOK=""
  NOTIFY="failure"
  NOTIFY_EMAIL=""
  NOTIFY_WEBHOOK=""
  TELEGRAM_BOT_TOKEN=""
  TELEGRAM_CHAT_ID=""
  ALLOW_ON_PANELS=0
  NOTIFY_TERMINALS=1
  RELEASE_UPGRADE_CHECK=1
  BACKUP_PATHS="/etc /var/www /home /root /var/spool/cron /opt /srv"
  MAJOR_UPDATES="hold"
  RISK_PACKAGES="php* ea-php* mysql* mariadb* percona* postgresql* nginx* apache2* httpd* openssl libssl* libc6 glibc docker* containerd* redis* mongodb* openssh-server podman* runc crun conmon"
  BACKUP_BEFORE_UPDATE="no"
  BACKUP_DESTINATION=""
  BACKUP_KEEP=3
}

write_config_template() {
  cat <<'EOF'
# /etc/linux-autoupdate.conf - settings for linux-autoupdate
#
# This file is sourced as bash by a root process. Keep it owned by root and not
# writable by anyone else (it may hold tokens: chmod 600). Use KEY="value" with
# no spaces around "=".
#
# After changing SCHEDULE or RANDOM_DELAY run:  linux-autoupdate enable

# When to run, in systemd OnCalendar format: "Sun 03:00", "daily",
# "Mon,Thu 02:30". The cron fallback only understands "[Day[,Day]] HH:MM",
# "daily" and "weekly".
SCHEDULE="Sun 03:00"

# Random delay added to the schedule so many servers do not update at once
# (systemd RandomizedDelaySec). Examples: 0, 90s, 30m, 2h.
RANDOM_DELAY="30m"

# What to update:
#   all      - everything, including the kernel and PHP
#   security - security updates only (apt, dnf, yum, zypper). On pacman and apk
#              nothing is updated and a warning is logged.
#   php      - only PHP packages
UPDATE_MODE="all"

# When to reboot after an update that needs one:
#   never  - only report it (safe default)
#   auto   - reboot as soon as the guards below allow it
#   window - reboot only inside REBOOT_WINDOW
REBOOT_POLICY="never"

# Reboot window for REBOOT_POLICY="window": "[Day[,Day]] HH:MM-HH:MM"
# (Mon Tue Wed Thu Fri Sat Sun, local time, may cross midnight).
REBOOT_WINDOW="Sun 03:00-05:00"

# 1 = do not reboot while interactive (SSH/terminal) users are logged in.
SKIP_REBOOT_IF_USERS=1

# Do not reboot while the 1-minute load average is above this value.
MAX_LOAD=4.0

# Packages that must never be updated by this tool: space-separated globs,
# e.g. "mysql* mariadb*". Held only for the duration of a run.
EXCLUDE_PACKAGES=""

# Command run (via bash -c) before updating, e.g. a snapshot. If it exits
# non-zero the update is aborted and counted as a failure.
PRE_UPDATE_HOOK=""

# When to send notifications: never | failure | always
NOTIFY="failure"

# Where to send them (any combination; leave empty to disable a channel).
NOTIFY_EMAIL=""
NOTIFY_WEBHOOK=""        # Slack/generic webhook that accepts {"text": "..."}
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# 0 = refuse to run updates on cPanel/Plesk servers (use the panel's updater).
# Set to 1 to allow it anyway.
ALLOW_ON_PANELS=0

# 1 = after a scheduled run, print the result on any terminal that is open
# (SSH/console sessions). Nothing is printed when nobody is logged in.
NOTIFY_TERMINALS=1

# 1 = check for a new Ubuntu release after each run and report it. The upgrade
# itself is never started automatically: run "linux-autoupdate release-upgrade".
RELEASE_UPGRADE_CHECK=1

# Paths included when you choose to back up before a release upgrade.
# Databases (MySQL/MariaDB/PostgreSQL) are dumped separately when running.
BACKUP_PATHS="/etc /var/www /home /root /var/spool/cron /opt /srv"

# Major-version updates (a change of major.minor in a package matching
# RISK_PACKAGES, e.g. MariaDB 10.6 -> 10.11 or PHP 8.3 -> 8.4):
#   hold  - in a terminal you are asked; in scheduled runs they are held back,
#           the rest is installed, and you are notified
#   allow - install them (a warning is still logged)
# One-off override: linux-autoupdate --allow-major
MAJOR_UPDATES="hold"

# Packages treated as sensitive (space-separated globs).
RISK_PACKAGES="php* ea-php* mysql* mariadb* percona* postgresql* nginx* apache2* httpd* openssl libssl* libc6 glibc docker* containerd* redis* mongodb* openssh-server podman* runc crun conmon"

# Back up before installing updates:
#   no     - never (a terminal run still offers a backup before major updates)
#   major  - before major-version updates
#   always - before every run that has updates to install
BACKUP_BEFORE_UPDATE="no"

# Where unattended backups go: an external server over SSH key login
# (user@host:/path), a directory on another disk, or empty for
# /var/backups/linux-autoupdate on this server. From a terminal you choose
# interactively instead.
BACKUP_DESTINATION=""

# Keep this many backups in the destination (0 = keep all).
BACKUP_KEEP=3
EOF
}

cfg_err() { echo "ERROR: $CONF: $*" >&2; CFG_BAD=1; }

# Parse "[Day[,Day]] <time-spec>" days into a comma list of numbers (Sun=0).
day_num() {
  case "$1" in
    Sun) echo 0 ;; Mon) echo 1 ;; Tue) echo 2 ;; Wed) echo 3 ;;
    Thu) echo 4 ;; Fri) echo 5 ;; Sat) echo 6 ;; *) return 1 ;;
  esac
}

days_to_nums() {
  local days=$1 part dn list="" parts=()
  IFS=, read -ra parts <<<"$days"
  for part in "${parts[@]}"; do
    dn=$(day_num "$part") || return 1
    list+="${list:+,}$dn"
  done
  [[ -n $list ]] || return 1
  echo "$list"
}

# Sets W_DAYS, W_START, W_END (minutes since midnight) from REBOOT_WINDOW.
parse_window() {
  local parts=() days="*" range nums
  local re='^([0-9]{1,2}):([0-9]{2})-([0-9]{1,2}):([0-9]{2})$'
  read -ra parts <<<"$REBOOT_WINDOW"
  case ${#parts[@]} in
    1) range=${parts[0]} ;;
    2) days=${parts[0]}; range=${parts[1]} ;;
    *) return 1 ;;
  esac
  [[ $range =~ $re ]] || return 1
  local sh=$((10#${BASH_REMATCH[1]})) sm=$((10#${BASH_REMATCH[2]}))
  local eh=$((10#${BASH_REMATCH[3]})) em=$((10#${BASH_REMATCH[4]}))
  (( sh <= 23 && eh <= 23 && sm <= 59 && em <= 59 )) || return 1
  W_START=$((sh * 60 + sm))
  W_END=$((eh * 60 + em))
  (( W_START != W_END )) || return 1
  if [[ $days != "*" ]]; then
    nums=$(days_to_nums "$days") || return 1
    days=$nums
  fi
  W_DAYS=$days
}

validate_config() {
  CFG_BAD=0
  local re p excl_check=()
  case "$UPDATE_MODE" in all|security|php) ;; *) cfg_err "UPDATE_MODE must be all, security or php" ;; esac
  case "$REBOOT_POLICY" in never|auto|window) ;; *) cfg_err "REBOOT_POLICY must be never, auto or window" ;; esac
  case "$NOTIFY" in never|failure|always) ;; *) cfg_err "NOTIFY must be never, failure or always" ;; esac
  re='^[A-Za-z0-9 :,.*/~-]+$'
  [[ $SCHEDULE =~ $re ]] || cfg_err "SCHEDULE contains unsupported characters"
  re='^[0-9]+(s|sec|m|min|h)?$'
  [[ $RANDOM_DELAY =~ $re ]] || cfg_err "RANDOM_DELAY must look like 0, 90s, 30m or 2h"
  re='^[0-9]+(\.[0-9]+)?$'
  [[ $MAX_LOAD =~ $re ]] || cfg_err "MAX_LOAD must be a number"
  [[ $SKIP_REBOOT_IF_USERS == [01] ]] || cfg_err "SKIP_REBOOT_IF_USERS must be 0 or 1"
  [[ $ALLOW_ON_PANELS == [01] ]] || cfg_err "ALLOW_ON_PANELS must be 0 or 1"
  [[ $NOTIFY_TERMINALS == [01] ]] || cfg_err "NOTIFY_TERMINALS must be 0 or 1"
  [[ $RELEASE_UPGRADE_CHECK == [01] ]] || cfg_err "RELEASE_UPGRADE_CHECK must be 0 or 1"
  case "$MAJOR_UPDATES" in hold|allow) ;; *) cfg_err "MAJOR_UPDATES must be hold or allow" ;; esac
  case "$BACKUP_BEFORE_UPDATE" in no|major|always) ;; *) cfg_err "BACKUP_BEFORE_UPDATE must be no, major or always" ;; esac
  re='^[0-9]+$'
  [[ $BACKUP_KEEP =~ $re ]] || cfg_err "BACKUP_KEEP must be a number"
  re='^(/[A-Za-z0-9._/+@-]*|([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+:/[A-Za-z0-9._/+@-]+)?$'
  [[ $BACKUP_DESTINATION =~ $re ]] || cfg_err "BACKUP_DESTINATION must be /directory or user@host:/path"
  re='^[A-Za-z0-9][A-Za-z0-9._+*?:-]*$'
  read -ra excl_check <<<"$RISK_PACKAGES"
  for p in ${excl_check[@]+"${excl_check[@]}"}; do
    [[ $p =~ $re ]] || cfg_err "RISK_PACKAGES entry '$p' is not a valid package glob"
  done
  re='^/[A-Za-z0-9._/+@-]*$'
  read -ra excl_check <<<"$BACKUP_PATHS"
  for p in ${excl_check[@]+"${excl_check[@]}"}; do
    [[ $p =~ $re ]] || cfg_err "BACKUP_PATHS entry '$p' must be an absolute path without spaces"
  done
  if [[ $REBOOT_POLICY == window ]]; then
    parse_window || cfg_err "REBOOT_WINDOW must look like \"Sun 03:00-05:00\" (days optional)"
  fi
  re='^[A-Za-z0-9][A-Za-z0-9._+*?:-]*$'
  read -ra excl_check <<<"$EXCLUDE_PACKAGES"
  for p in ${excl_check[@]+"${excl_check[@]}"}; do
    [[ $p =~ $re ]] || cfg_err "EXCLUDE_PACKAGES entry '$p' is not a valid package glob"
  done
  re='^[A-Za-z0-9._%+@,-]+$'
  [[ -z $NOTIFY_EMAIL || $NOTIFY_EMAIL =~ $re ]] || cfg_err "NOTIFY_EMAIL is not valid"
  re='^https?://[^[:space:]]+$'
  [[ -z $NOTIFY_WEBHOOK || $NOTIFY_WEBHOOK =~ $re ]] || cfg_err "NOTIFY_WEBHOOK must be an http(s) URL"
  re='^[0-9]+:[A-Za-z0-9_-]+$'
  [[ -z $TELEGRAM_BOT_TOKEN || $TELEGRAM_BOT_TOKEN =~ $re ]] || cfg_err "TELEGRAM_BOT_TOKEN is not valid"
  re='^(-?[0-9]+|@[A-Za-z0-9_]+)$'
  [[ -z $TELEGRAM_CHAT_ID || $TELEGRAM_CHAT_ID =~ $re ]] || cfg_err "TELEGRAM_CHAT_ID is not valid"
  return "$CFG_BAD"
}

load_config() {
  set_defaults
  if [[ -e $CONF ]]; then
    local owner mode
    owner=$(stat -c '%u' "$CONF" 2>/dev/null) || die "cannot stat $CONF"
    mode=$(stat -c '%a' "$CONF" 2>/dev/null) || die "cannot stat $CONF"
    if [[ $owner != 0 ]] || (( 8#$mode & 8#022 )); then
      die "refusing to load $CONF: it must be owned by root and not group/world-writable"
    fi
    # shellcheck disable=SC1090
    . "$CONF" || die "could not read $CONF"
  fi
  validate_config || exit 1
}

# ------------------------------------------------------------------ state ---

state_set() {
  local key=$1 val tmp
  val=$(printf '%s' "$2" | tr '\n"' '  ')
  mkdir -p "$STATE_DIR" || return 1
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
  {
    [[ -f $STATE ]] && grep -v "^$key=" "$STATE"
    printf '%s="%s"\n' "$key" "$val"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATE"
}

state_get() {
  [[ -r $STATE ]] || return 0
  sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$STATE" | tail -n1
}

# ----------------------------------------------------------- notifications ---

json_escape() {
  local s=$1
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

host_name() {
  hostname -f 2>/dev/null || hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || uname -n
}

# notify <failure|success> <subject> <body>
notify() {
  local level=$1 subject=$2 body=$3 body_file
  case "$NOTIFY" in
    never) return 0 ;;
    failure) [[ $level == failure ]] || return 0 ;;
  esac
  [[ -n $NOTIFY_EMAIL$NOTIFY_WEBHOOK$TELEGRAM_BOT_TOKEN ]] || return 0

  if [[ -n $NOTIFY_EMAIL ]]; then
    if command -v mail >/dev/null 2>&1; then
      printf '%s\n' "$body" | mail -s "$subject" "$NOTIFY_EMAIL" >/dev/null 2>&1 \
        || log "WARNING: email notification failed"
    elif command -v mailx >/dev/null 2>&1; then
      printf '%s\n' "$body" | mailx -s "$subject" "$NOTIFY_EMAIL" >/dev/null 2>&1 \
        || log "WARNING: email notification failed"
    elif command -v sendmail >/dev/null 2>&1; then
      printf 'To: %s\nSubject: %s\n\n%s\n' "$NOTIFY_EMAIL" "$subject" "$body" \
        | sendmail -t >/dev/null 2>&1 || log "WARNING: email notification failed"
    else
      log "WARNING: NOTIFY_EMAIL is set but no mail command was found"
    fi
  fi

  if [[ -n $NOTIFY_WEBHOOK || -n $TELEGRAM_BOT_TOKEN ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      log "WARNING: curl not found - webhook/Telegram notifications skipped"
      return 0
    fi
  fi

  if [[ -n $NOTIFY_WEBHOOK ]]; then
    body_file=$(mktemp) || return 0
    printf '{"text":"%s"}' "$(json_escape "$subject"$'\n'"$body")" >"$body_file"
    # The URL goes through stdin so the secret never shows up in the process list.
    printf 'url = "%s"\n' "$NOTIFY_WEBHOOK" \
      | curl -fsS -m 20 -o /dev/null -X POST -H 'Content-Type: application/json' \
          --data-binary @"$body_file" -K - >/dev/null 2>&1 \
      || log "WARNING: webhook notification failed"
    rm -f "$body_file"
  fi

  if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
      | curl -fsS -m 20 -o /dev/null -K - \
          --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
          --data-urlencode "text=$subject"$'\n'"$body" >/dev/null 2>&1 \
      || log "WARNING: Telegram notification failed"
  fi
  return 0
}

# --------------------------------------------------------------- detection ---

detect_pm() {
  if   command -v apt-get >/dev/null; then PM=apt
  elif command -v dnf     >/dev/null; then PM=dnf
  elif command -v yum     >/dev/null; then PM=yum
  elif command -v zypper  >/dev/null; then PM=zypper
  elif command -v pacman  >/dev/null; then PM=pacman
  elif command -v apk     >/dev/null; then PM=apk
  else return 1
  fi
}

detect_panel() {
  PANEL=""
  [[ -d /usr/local/cpanel ]] && PANEL="cPanel"
  [[ -d /usr/local/psa ]] && PANEL="Plesk"
  return 0
}

# Sets LIVEPATCH to the name of an active kernel livepatch service, or "".
detect_livepatch() {
  LIVEPATCH=""
  if command -v canonical-livepatch >/dev/null 2>&1; then
    if canonical-livepatch status 2>/dev/null | grep -Eqi 'check-in: *succeeded|running: *true'; then
      LIVEPATCH="Canonical Livepatch"; return 0
    fi
  fi
  if command -v kcarectl >/dev/null 2>&1; then
    if kcarectl --info 2>/dev/null | grep -qi 'kpatch-state:'; then
      LIVEPATCH="KernelCare"; return 0
    fi
  fi
  if command -v kpatch >/dev/null 2>&1; then
    if kpatch list 2>/dev/null \
        | awk '/^Loaded/{f=1; next} /^Installed/{f=0} f && /\[enabled\]/{found=1} END{exit !found}'; then
      LIVEPATCH="kpatch"; return 0
    fi
  fi
  return 0
}

# Sets NEED_REBOOT, KERNEL_ONLY (reboot is needed only for a kernel update)
# and REBOOT_REASON.
reboot_required() {
  NEED_REBOOT=0
  KERNEL_ONLY=0
  REBOOT_REASON=""
  local out rc reasons latest
  if [[ -f /var/run/reboot-required ]]; then
    NEED_REBOOT=1
    REBOOT_REASON="reboot-required flag is set"
    if [[ -s /var/run/reboot-required.pkgs ]] \
        && ! grep -qvE '^(linux-|raspberrypi-kernel)' /var/run/reboot-required.pkgs; then
      KERNEL_ONLY=1
    fi
  elif command -v needs-restarting >/dev/null; then
    out=$(needs-restarting -r 2>&1)
    rc=$?
    if (( rc != 0 )); then
      NEED_REBOOT=1
      REBOOT_REASON="needs-restarting reports core packages were updated"
      reasons=$(grep -E '^[[:space:]]+[^[:space:]]' <<<"$out")
      if [[ -n $reasons ]] && ! grep -qviE '^[[:space:]]*(\*[[:space:]]*)?kernel' <<<"$reasons"; then
        KERNEL_ONLY=1
      fi
    fi
  else
    latest=$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -n1)
    if [[ -n $latest && $latest != "$(uname -r)" ]]; then
      NEED_REBOOT=1
      KERNEL_ONLY=1
      REBOOT_REASON="newer kernel installed ($latest, running $(uname -r))"
    fi
  fi
  return 0
}

# ---------------------------------------------------------- reboot guards ---

in_reboot_window() {
  local now_m today yday
  now_m=$((10#$(date +%H) * 60 + 10#$(date +%M)))
  today=$(( $(date +%u) % 7 ))
  yday=$(( (today + 6) % 7 ))
  day_ok() { [[ $W_DAYS == "*" || ",$W_DAYS," == *",$1,"* ]]; }
  if (( W_START < W_END )); then
    day_ok "$today" && (( now_m >= W_START && now_m < W_END ))
  else
    { day_ok "$today" && (( now_m >= W_START )); } \
      || { day_ok "$yday" && (( now_m < W_END )); }
  fi
}

interactive_sessions() { who 2>/dev/null | awk '$2 ~ /^pts\// {n++} END {print n+0}'; }

load_too_high() {
  local load
  read -r load _ </proc/loadavg || return 1
  awk -v a="$load" -v b="$MAX_LOAD" 'BEGIN { exit !(a > b) }'
}

# Prints "reboot" or "skip:<reason>" or "none".
reboot_decision() {
  if (( ! NEED_REBOOT )); then echo none; return; fi
  if [[ -n $LIVEPATCH ]] && (( KERNEL_ONLY )); then
    echo "none:kernel update covered by $LIVEPATCH, reboot deferred"; return
  fi
  if (( FAILED )); then echo "skip:the update reported errors"; return; fi
  if (( FLAG_REBOOT )); then echo reboot; return; fi
  case "$REBOOT_POLICY" in
    never) echo "skip:REBOOT_POLICY is never"; return ;;
    window)
      if ! in_reboot_window; then echo "skip:outside REBOOT_WINDOW ($REBOOT_WINDOW)"; return; fi ;;
  esac
  if (( SKIP_REBOOT_IF_USERS )); then
    local n
    n=$(interactive_sessions)
    if (( n > 0 )); then echo "skip:$n interactive user session(s) logged in"; return; fi
  fi
  if load_too_high; then echo "skip:load average above MAX_LOAD ($MAX_LOAD)"; return; fi
  echo reboot
}

write_marker() {
  mkdir -p "$STATE_DIR" || return 0
  {
    echo "created=$(now)"
    echo "kernel_before=$(uname -r)"
    if has_systemd; then
      systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^(nginx|apache2|httpd|mysql|mysqld|mariadb|php[^ ]*fpm[^ ]*)\.service$' \
        | sed 's/^/service=/'
    fi
  } >"$MARKER"
  return 0
}

# ------------------------------------------------------------- exclusions ---

# True if package name $1 matches EXCLUDE_PACKAGES.
excl_match() {
  local p
  for p in ${EXCL[@]+"${EXCL[@]}"}; do
    # shellcheck disable=SC2053
    [[ $1 == $p ]] && return 0
  done
  return 1
}

setup_exclusions() {
  local all="$EXCLUDE_PACKAGES $MAJOR_HELD"
  [[ -n ${all// /} ]] || return 0
  read -ra EXCL <<<"$all"
  local p pkg held locks
  case "$PM" in
    apt)
      held=$(apt-mark showhold 2>/dev/null)
      for p in "${EXCL[@]}"; do
        while read -r pkg; do
          [[ -n $pkg ]] || continue
          grep -qxF "$pkg" <<<"$held" && continue
          if apt-mark hold "$pkg" >/dev/null 2>&1; then HELD+=("$pkg"); fi
        done < <(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' "$p" 2>/dev/null | awk '$2 == "ii" {print $1}')
      done ;;
    dnf|yum)
      for p in "${EXCL[@]}"; do EXCL_ARGS+=("--exclude=$p"); done ;;
    zypper)
      locks=$(zypper --non-interactive locks 2>/dev/null)
      for p in "${EXCL[@]}"; do
        grep -qwF -- "$p" <<<"$locks" && continue
        if zypper --non-interactive addlock "$p" >/dev/null 2>&1; then HELD+=("$p"); fi
      done ;;
    pacman)
      EXCL_ARGS+=(--ignore "$(IFS=,; echo "${EXCL[*]}")") ;;
  esac
  log "Exclusions active: ${all# }"
  if [[ ${#HELD[@]} -gt 0 ]]; then log "Held ${#HELD[@]} package(s) for this run: ${HELD[*]:0:20}"; fi
  return 0
}

release_exclusions() {
  local h
  [[ ${#HELD[@]} -gt 0 ]] || return 0
  case "$PM" in
    apt)    for h in "${HELD[@]}"; do apt-mark unhold "$h" >/dev/null 2>&1; done ;;
    zypper) for h in "${HELD[@]}"; do zypper --non-interactive removelock "$h" >/dev/null 2>&1; done ;;
  esac
  log "Released ${#HELD[@]} hold(s)"
  HELD=()
  return 0
}

# ------------------------------------------------------- package managers ---

# Number of pending updates. $1=1 uses cached metadata only (no network).
pending_count() {
  local cached=${1:-1} opt=() out
  case "$PM" in
    apt)
      apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst ' ;;
    dnf|yum)
      (( cached )) && opt=(-C)
      out=$("$PM" ${opt[@]+"${opt[@]}"} -q ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} check-update 2>/dev/null)
      awk '/^Obsoleting/ {exit} NF == 3 && $1 ~ /\.[A-Za-z0-9_]+$/ {n++} END {print n+0}' <<<"$out" ;;
    zypper)
      (( cached )) && opt=(--no-refresh)
      zypper --non-interactive ${opt[@]+"${opt[@]}"} -q list-updates 2>/dev/null | grep -c '^v |' ;;
    pacman)
      if command -v checkupdates >/dev/null 2>&1; then
        checkupdates 2>/dev/null | awk 'END {print NR+0}'
      else
        pacman -Qu 2>/dev/null | awk 'END {print NR+0}'
      fi ;;
    apk)
      apk version -l '<' 2>/dev/null | grep -c ' < ' ;;
    *) echo 0 ;;
  esac
  return 0
}

# apt: packages that are listed as upgradable but cannot be installed right
# now (Ubuntu phased rollout, or held back). Prints one name per line.
apt_deferred() {
  comm -13 <(apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / {print $2}' | sort -u) \
           <(apt list --upgradable 2>/dev/null | awk -F/ 'NR > 1 && NF > 1 {print $1}' | sort -u)
}

# Sets DEFERRED_COUNT (apt only).
count_deferred() {
  DEFERRED_COUNT=0
  [[ $PM == apt ]] || return 0
  DEFERRED_COUNT=$(apt_deferred | grep -c .)
  return 0
}

apt_check_report() {
  local inst deferred d
  inst=$(apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / {
    name = $2
    if ($3 ~ /^\[/) { old = $3; new = $4 } else { old = "(new package)"; new = $3 }
    gsub(/\[|\]|\(/, "", old); gsub(/\(/, "", new)
    printf "  %-38s %s -> %s\n", name, old, new }')
  deferred=$(apt_deferred)
  if [[ -n $inst ]]; then
    echo "Can be installed now:"
    echo "$inst"
  else
    echo "Nothing can be installed right now."
  fi
  if [[ -n $deferred ]]; then
    echo
    echo "Not installed yet - Ubuntu releases these to servers in phases (or they are"
    echo "held back). They install automatically on a later run; no action needed:"
    while read -r d; do printf '  %s\n' "$d"; done <<<"$deferred"
  fi
}

# True if the part of the log written since this run started shows at least one
# repository that was fetched successfully: "Hit:" lines, or "Get:" lines that
# carry a downloaded size (a failed fetch also prints "Get:" but with no size).
apt_refresh_partial() {
  tail -c "+$((LOG_START + 1))" "$LOG" 2>/dev/null | grep -qE '^(Hit:|Get:[0-9]+ .*\[[0-9.]+ ?[kKMG]?B\])'
}

# Refresh package lists. Retries on failure; for apt, a few broken repositories
# (e.g. one dead PPA) do not fail the run as long as the others worked.
pm_refresh() {
  local attempt rc
  case "$PM" in
    apt|zypper|apk) ;;
    *) return 0 ;;
  esac
  for attempt in 1 2 3; do
    case "$PM" in
      apt)    run apt-get "${APT_NET[@]}" update ;;
      zypper) run zypper --non-interactive refresh ;;
      apk)    run apk update ;;
    esac
    rc=$?
    if (( rc == 0 )); then return 0; fi
    if [[ $PM == apt ]] && apt_refresh_partial; then
      log "WARNING: some repositories could not be refreshed; continuing with the ones that worked."
      return 0
    fi
    if (( attempt < 3 )); then
      log "Refreshing the package lists failed (attempt $attempt of 3) - retrying in 10 seconds."
      sleep 10
    fi
  done
  FAILED=1
  REFRESH_FAILED=1
  log "ERROR: could not refresh the package lists after 3 attempts."
  return 0
}

# Look at what the package manager printed during this run and spot repositories
# that are expired, unreachable or unsigned. Sets REPO_PROBLEM and REPO_HINT.
scan_repo_problems() {
  local text all hits
  REPO_PROBLEM=""
  REPO_HINT=""
  text=$(tail -c "+$((LOG_START + 1))" "$LOG" 2>/dev/null)
  all=$(grep -Ei '^(Err:|E: Failed to fetch)|does not have a Release file|404 +Not Found|Release file .* expired|NO_PUBKEY|is not signed|metadata expired|Valid metadata not found|Failed to download metadata|Cannot find a valid baseurl|Errors during downloading metadata|Cannot download repomd|Failed to synchronize cache|Could not resolve|Temporary failure resolving|Failed retrieving file|^ERROR: .*(fetch|temporary)|Connection (timed out|refused)|^W: Failed to fetch' <<<"$text")
  [[ -n $all ]] || return 0
  hits=$(head -n 3 <<<"$all")
  REPO_PROBLEM=$hits
  if grep -Eiq 'metadata expired|does not have a Release file|404 +Not Found|Release file .* expired|Valid metadata' <<<"$all"; then
    REPO_HINT="This OS release may have reached end of life, so its repositories no longer receive updates. Move to a supported release (Ubuntu: '$PROG release-upgrade')."
  elif grep -Eiq 'resolv|Connection|timed out|refused|Could not connect|Network is unreachable' <<<"$all"; then
    REPO_HINT="Check DNS, internet access and any proxy configured on this server."
  elif grep -Eiq 'NO_PUBKEY|not signed' <<<"$all"; then
    REPO_HINT="A repository signing key is missing or expired. Fix or remove that repository."
  else
    REPO_HINT="See $LOG for the full error."
  fi
  return 0
}

report_repo_problems() {
  local l
  [[ -n $REPO_PROBLEM ]] || return 0
  log "WARNING: package source problem(s) detected - the result may be incomplete:"
  while read -r l; do log "    $l"; done <<<"$REPO_PROBLEM"
  log "HINT: $REPO_HINT"
}

# Make sure there is room to update; clean the package cache first if needed.
check_disk_space() {
  local avail
  avail=$(df -Pk / | awk 'NR==2 {print $4}')
  if (( avail < 307200 )) && [[ $PM == apt ]]; then
    log "Low disk space ($(( avail / 1024 )) MB free) - cleaning the apt cache."
    run apt-get clean
    avail=$(df -Pk / | awk 'NR==2 {print $4}')
  fi
  if (( avail < 307200 )); then
    log "ERROR: only $(( avail / 1024 )) MB free on / - not enough to update safely. Free some space (logs, old kernels, caches) and run again."
    return 1
  fi
  return 0
}

pm_check() {
  case "$PM" in
    apt)
      case "$UPDATE_MODE_EFFECTIVE" in
        security) apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / && /[Ss]ecurity/' | tee -a "$LOG" ;;
        php)      apt list --upgradable 2>/dev/null | grep -i '^php' | tee -a "$LOG" ;;
        *)        apt_check_report | tee -a "$LOG" ;;
      esac ;;
    dnf|yum)
      case "$UPDATE_MODE_EFFECTIVE" in
        security) "$PM" check-update --security | tee -a "$LOG" ;;
        php)      "$PM" check-update | grep -i 'php' | tee -a "$LOG" ;;
        *)        "$PM" check-update | tee -a "$LOG" ;;
      esac ;;
    zypper)
      case "$UPDATE_MODE_EFFECTIVE" in
        security) zypper --non-interactive list-patches --category security | tee -a "$LOG" ;;
        php)      zypper list-updates | grep -i 'php' | tee -a "$LOG" ;;
        *)        zypper list-updates | tee -a "$LOG" ;;
      esac ;;
    pacman)
      case "$UPDATE_MODE_EFFECTIVE" in
        security) log "WARNING: security-only listing is not supported on pacman; showing all updates." ;;
      esac
      pacman -Sy >/dev/null && pacman -Qu | tee -a "$LOG" ;;
    apk)
      case "$UPDATE_MODE_EFFECTIVE" in
        security) log "WARNING: security-only listing is not supported on apk; showing all updates." ;;
      esac
      apk version -l '<' | tee -a "$LOG" ;;
  esac
  return 0
}

unsupported_security() {
  log "WARNING: security-only updates are not supported on $PM; not running a full update (UPDATE_MODE=security)."
  SKIPPED=1
}

pm_update() {
  local PKGS=() name names
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1
      if container_guard; then export NEEDRESTART_MODE=l; fi
      local APT_OPTS=(-y "${APT_NET[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
      case "$UPDATE_MODE_EFFECTIVE" in
        php)
          while read -r name; do
            excl_match "$name" || PKGS+=("$name")
          done < <(dpkg-query -W -f='${Package}\n' 'php*' 2>/dev/null)
          if [[ ${#PKGS[@]} -gt 0 ]]; then
            pkg_run apt-get install --only-upgrade "${APT_OPTS[@]}" "${PKGS[@]}"
          fi ;;
        security)
          while read -r name; do
            excl_match "$name" || PKGS+=("$name")
          done < <(apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / && /[Ss]ecurity/ {print $2}')
          if [[ ${#PKGS[@]} -gt 0 ]]; then
            pkg_run apt-get install --only-upgrade "${APT_OPTS[@]}" "${PKGS[@]}"
          else
            log "No security updates pending."
          fi ;;
        *)
          pkg_run apt-get dist-upgrade "${APT_OPTS[@]}"
          pkg_run apt-get autoremove -y "${APT_NET[@]}" ;;
      esac ;;
    dnf|yum)
      # When packages are held back, let the package manager skip anything that
      # depends on the held version instead of failing the whole transaction.
      local sb=()
      if [[ ${#EXCL_ARGS[@]} -gt 0 ]]; then sb=(--skip-broken); fi
      case "$UPDATE_MODE_EFFECTIVE" in
        php)      pkg_run "$PM" -y ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} ${sb[@]+"${sb[@]}"} upgrade 'php*' 'ea-php*' ;;
        security) pkg_run "$PM" -y ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} ${sb[@]+"${sb[@]}"} upgrade --security ;;
        *)
          pkg_run "$PM" -y ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} ${sb[@]+"${sb[@]}"} upgrade
          if [[ $PM == dnf ]]; then pkg_run dnf -y autoremove; fi ;;
      esac ;;
    zypper)
      case "$UPDATE_MODE_EFFECTIVE" in
        php)      pkg_run zypper --non-interactive update 'php*' ;;
        security) pkg_run zypper --non-interactive patch --category security ;;
        *)        pkg_run zypper --non-interactive update ;;
      esac ;;
    pacman)
      case "$UPDATE_MODE_EFFECTIVE" in
        php)      log "Arch does not support partial upgrades safely; use full update." ;;
        security) unsupported_security ;;
        *)
          if [[ -n $MAJOR_HELD ]]; then
            log "WARNING: Arch does not support partial upgrades, so nothing was updated because major-version updates are waiting for your review. Install everything with: $PROG --allow-major"
            SKIPPED=1
          else
            pkg_run pacman -Syu --noconfirm ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"}
          fi ;;
      esac ;;
    apk)
      case "$UPDATE_MODE_EFFECTIVE" in
        php)
          while read -r name; do
            excl_match "$name" || PKGS+=("$name")
          done < <(apk info 2>/dev/null | grep '^php')
          if [[ ${#PKGS[@]} -gt 0 ]]; then
            pkg_run apk upgrade "${PKGS[@]}"
          else
            log "No PHP packages installed - nothing to do."
          fi ;;
        security) unsupported_security ;;
        *)
          if [[ ${#EXCL[@]} -eq 0 ]]; then
            pkg_run apk upgrade
          else
            names=$(apk version -l '<' 2>/dev/null | awk '/ < / {print $1}' | sed -E 's/-[0-9][^ ]*$//')
            while read -r name; do
              [[ -n $name ]] || continue
              excl_match "$name" || PKGS+=("$name")
            done <<<"$names"
            if [[ ${#PKGS[@]} -gt 0 ]]; then
              pkg_run apk upgrade "${PKGS[@]}"
            else
              log "No upgradable packages left after exclusions."
            fi
          fi ;;
      esac ;;
  esac
  return 0
}

restart_php_services() {
  local svc web
  has_systemd || return 0
  while read -r svc; do
    [[ -n $svc ]] || continue
    pkg_run systemctl restart "$svc"
  done < <(systemctl list-units --type=service --state=running --no-legend \
             | awk '{print $1}' | grep -Ei 'php.*fpm')
  if [[ $PHP_BEFORE != "$PHP_AFTER" ]]; then
    for web in apache2 httpd; do
      if systemctl is-active --quiet "$web"; then pkg_run systemctl restart "$web"; fi
    done
  fi
  return 0
}

# --------------------------------------------------------- update workflow ---

acquire_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    log "WARNING: flock not found - cannot prevent two updates from running at once."
    return 0
  fi
  exec 9>"$LOCK"
  if flock -n 9; then return 0; fi
  if (( VERBOSE )); then
    echo "Another update is already running - waiting up to 10 minutes for it to finish..."
    flock -w 600 9 && return 0
  fi
  echo "Another update is already running."
  exit 1
}

run_hook() {
  local rc
  log "Running PRE_UPDATE_HOOK"
  if (( VERBOSE )); then
    bash -c "$PRE_UPDATE_HOOK" 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
  else
    bash -c "$PRE_UPDATE_HOOK" >>"$LOG" 2>&1
    rc=$?
  fi
  return "$rc"
}

cleanup() {
  release_exclusions
  if (( RUN_STARTED && ! RUN_FINISHED )); then
    state_set LAST_RUN "$(now)"
    state_set LAST_RESULT "failure (aborted)"
  fi
}

finish_run() {
  local body subject
  RUN_FINISHED=1
  state_set LAST_RUN "$(now)"
  state_set LAST_RESULT "$RESULT"
  state_set LAST_MODE "$UPDATE_MODE_EFFECTIVE"
  state_set PACKAGES_UPDATED "$UPDATED"
  state_set REBOOT_PENDING "$REBOOT_PENDING"
  state_set REBOOT_NOTE "$REBOOT_NOTE"
  state_set LAST_WARNING "$(printf '%s' "$REPO_PROBLEM" | head -n1)"
  state_set HELD_MAJOR "$MAJOR_HELD_DETAIL"
  case "$RESULT" in
    success)
      if (( UPDATED > 0 )); then
        if [[ $UPDATE_MODE_EFFECTIVE == security ]]; then
          log "SUCCESS: $UPDATED security update(s) installed - updated to the latest version and the fixes are applied."
        else
          log "SUCCESS: update completed - $UPDATED package(s) updated to the latest version and fixed (patches applied)."
        fi
      else
        log "Nothing found - no updates available."
      fi
      if [[ -n $REPO_PROBLEM ]]; then
        report_repo_problems
        log "STATUS: CANNOT CONFIRM THE SYSTEM IS UP TO DATE - fix the package source problem above."
      elif [[ -n $MAJOR_HELD ]]; then
        log "STATUS: UPDATED, BUT RISKY UPDATE(S) HELD BACK FOR YOUR REVIEW (with anything that depends on them): $MAJOR_HELD_DETAIL"
        log "        Install them when you are ready (after a backup): $PROG --allow-major --backup"
      elif (( PENDING_AFTER > 0 )); then
        log "STATUS: $PENDING_AFTER UPDATE(S) STILL PENDING - run it again or see $LOG."
      else
        log "STATUS: UP TO DATE - no updates pending."
      fi
      if (( REBOOT_PENDING )) && [[ $REBOOT_NOTE != rebooting ]]; then
        log "STATUS: REBOOT REQUIRED to finish - run 'reboot' when it suits you (or re-run with --reboot)."
      elif [[ $REBOOT_NOTE == rebooting ]]; then
        log "STATUS: REBOOTING in 1 minute to finish the update."
      fi
      if (( DEFERRED_COUNT > 0 )); then
        log "NOTE: $DEFERRED_COUNT more update(s) are waiting for Ubuntu's phased rollout (or are held back). They install automatically on a later run - no action needed."
      fi ;;
    skipped) log "Nothing was updated (see the warning above)."
             if (( MAJOR_BLOCKED )); then
               log "STATUS: NOT UPDATED - the pending updates depend on major-version update(s) that need your review: $MAJOR_HELD_DETAIL"
               log "        Review them, then install everything (after a backup): $PROG --allow-major --backup"
             elif [[ -n $MAJOR_HELD ]]; then
               log "STATUS: NOT UPDATED - major-version update(s) need your review: $MAJOR_HELD_DETAIL"
               log "        Install them when you are ready (after a backup): $PROG --allow-major --backup"
             else
               log "STATUS: NOT UPDATED - this update mode is not supported on this system."
             fi ;;
    *)       log "FAILED: the update did not complete - see $LOG for details."
             if [[ -n $REPO_PROBLEM ]]; then report_repo_problems; fi
             log "STATUS: NOT UP TO DATE - the update failed or was refused; the system may be only partly updated." ;;
  esac
  log "==== Finished: $RESULT ===="
  subject="[$(host_name)] linux-autoupdate: $RESULT"
  body="Result: $RESULT
Mode: $UPDATE_MODE_EFFECTIVE
Packages updated: $UPDATED
Reboot pending: $REBOOT_PENDING${REBOOT_NOTE:+ ($REBOOT_NOTE)}${RELEASE_AVAILABLE:+
New Ubuntu release available: $RELEASE_AVAILABLE (run: $PROG release-upgrade)}
Log: $LOG"
  if [[ -n $MAJOR_HELD ]]; then
    body+="
HELD BACK (risky update, needs your review): $MAJOR_HELD_DETAIL
Install after a backup with: $PROG --allow-major --backup"
  fi
  if [[ -n $BACKUP_LOCATION ]]; then
    body+="
Backup: $BACKUP_LOCATION"
  fi
  if [[ -n $REPO_PROBLEM ]]; then
    body+="
WARNING: package source problem - $(printf '%s' "$REPO_PROBLEM" | head -n1)
$REPO_HINT"
  fi
  case "$RESULT" in
    success|skipped) if [[ -n $REPO_PROBLEM || -n $MAJOR_HELD || $MAJOR_BLOCKED -eq 1 ]]; then notify failure "$subject" "$body"; else notify success "$subject" "$body"; fi ;;
    *)               notify failure "$subject" "$body" ;;
  esac
  if [[ $CMD == run ]]; then
    tell_terminals "linux-autoupdate on $(host_name): $RESULT, $UPDATED package(s) updated${REBOOT_NOTE:+, reboot: $REBOOT_NOTE}${RELEASE_AVAILABLE:+; new release available: $RELEASE_AVAILABLE ($PROG release-upgrade)}. Details: $LOG"
  fi
  [[ $RESULT == success || $RESULT == skipped ]]
}

cmd_update() {
  local before after decision rc
  (( RANDOM_DELAY_ARG > 0 )) && sleep $(( RANDOM % RANDOM_DELAY_ARG ))
  acquire_lock
  UPDATE_MODE_EFFECTIVE=${MODE_OVERRIDE:-$UPDATE_MODE}
  LOG_START=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  trap '' HUP   # a dropped SSH session must not kill an update half-way

  # ---- Detect OS ----
  load_os_release
  log "==== Start: ${OS_PRETTY:-unknown OS} | kernel $(uname -r) | mode=$UPDATE_MODE_EFFECTIVE ===="
  RUN_STARTED=1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # ---- Control panels that manage their own packages ----
  detect_panel
  if [[ $PANEL == cPanel ]]; then
    log "WARNING: cPanel detected - consider /scripts/upcp; EA-PHP is updated via yum/dnf."
  elif [[ $PANEL == Plesk ]]; then
    log "WARNING: Plesk detected - consider 'plesk installer update'."
  fi
  if [[ -n $PANEL ]] && (( ! ALLOW_ON_PANELS )); then
    log "ERROR: $PANEL detected and ALLOW_ON_PANELS=0 - refusing to update. Use the panel's updater or set ALLOW_ON_PANELS=1 in $CONF."
    RESULT="refused"
    finish_run
    exit 1
  fi

  if ! detect_pm; then
    log "ERROR: No supported package manager found."
    RESULT="failure"
    finish_run
    exit 1
  fi
  log "Package manager: $PM"
  say "Detected ${OS_PRETTY:-this system}; package manager: $PM; update mode: $UPDATE_MODE_EFFECTIVE"

  detect_livepatch
  if [[ -n $LIVEPATCH ]]; then log "Livepatch: $LIVEPATCH active"; else log "Livepatch: none detected"; fi

  if [[ -n $PRE_UPDATE_HOOK ]] && ! run_hook; then
    log "ERROR: PRE_UPDATE_HOOK failed - aborting, nothing was updated."
    RESULT="failure"
    finish_run
    exit 1
  fi

  PHP_BEFORE=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "none")

  if ! check_disk_space; then
    RESULT="failure"
    finish_run
    exit 1
  fi
  if [[ $PM == apt ]] && ! apt_health; then
    log "The package system needs repair before updating (interrupted install?)."
    apt_heal || log "WARNING: automatic repair did not fully succeed; continuing."
  fi

  say "Refreshing package lists..."
  pm_refresh

  # ---- Review risky (major-version) updates before installing anything ----
  MAJOR_HELD=""
  MAJOR_HELD_DETAIL=""
  local major_kind=normal
  assess_risk
  if risk_found; then
    if is_tty; then
      show_risk
    else
      log "Heads-up: ${#RISK_MAJOR[@]} major-version update(s), ${#RISK_RESTART[@]} Docker engine update(s), ${#RISK_REVIEW[@]} service-package update(s), ${#RISK_KERNEL[@]} kernel update(s) pending."
    fi
  fi
  if [[ ${#RISK_HOLD[@]} -gt 0 ]]; then
    if (( ALLOW_MAJOR )) || [[ $MAJOR_UPDATES == allow ]]; then
      log "WARNING: installing risky update(s) (allowed): ${RISK_HOLD[*]}"
      major_kind=major
    elif is_tty && ask_yn "Install the risky update(s) above as well?" n; then
      log "Risky update(s) approved by the user: ${RISK_HOLD[*]}"
      major_kind=major
    else
      MAJOR_HELD="${RISK_MAJOR_NAMES[*]}"
      MAJOR_HELD_DETAIL="${RISK_HOLD[*]}"
      log "WARNING: ${#RISK_HOLD[@]} risky update(s) held back for your review: $MAJOR_HELD_DETAIL"
    fi
  fi
  if (( AZURACAST )); then
    log "NOTE: AzuraCast detected - its data lives in Docker volumes (not in this tool's backup). Back it up with: cd /var/azuracast && ./docker.sh backup"
  fi

  setup_exclusions
  before=$(pending_count 0)
  say "Found $before pending update(s)."
  if (( before > 0 )) && ! pre_update_backup "$major_kind"; then
    log "ERROR: the requested backup did not complete - updates were NOT installed."
    release_exclusions
    RESULT="failure"
    finish_run
    exit 1
  fi
  say "Installing updates - this can take several minutes..."
  pm_update
  if (( FAILED )) && [[ -n $MAJOR_HELD ]] \
      && tail -c "+$((LOG_START + 1))" "$LOG" | grep -qE 'exclude filtering|conflicting requests|cannot install both|Problem:'; then
    log "WARNING: the pending updates depend on the held-back major-version update(s), so they cannot be installed separately. Nothing was changed."
    FAILED=0
    SKIPPED=1
    MAJOR_BLOCKED=1
  fi
  if (( FAILED && ! REFRESH_FAILED )); then
    case "$PM" in
      apt|dnf|yum)
        log "The update reported errors - trying to repair automatically and retrying once."
        FAILED=0
        if heal_pm; then
          pm_update
          if (( ! FAILED )); then log "Recovered: the retry after automatic repair succeeded."; fi
        else
          FAILED=1
        fi ;;
    esac
  fi
  after=$(pending_count 0)
  PENDING_AFTER=$after
  if [[ $PM == apt ]] && container_guard; then report_needrestart; fi
  count_deferred
  release_exclusions
  UPDATED=$(( before - after ))
  (( UPDATED < 0 )) && UPDATED=0
  log "Packages updated: $UPDATED"

  # ---- Restart PHP-FPM / web server if PHP changed ----
  PHP_AFTER=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "none")
  log "PHP: $PHP_BEFORE -> $PHP_AFTER"
  restart_php_services
  if php -v 2>/dev/null | grep -qi ioncube; then
    log "ionCube loader OK"
  elif command -v php >/dev/null; then
    log "NOTE: ionCube loader not shown in php -v (ignore if not used)."
  fi

  # ---- Does the new kernel need a reboot? ----
  say "Checking whether a reboot is needed..."
  reboot_required
  decision=$(reboot_decision)
  case "$decision" in
    none:*)
      REBOOT_NOTE=${decision#none:}
      log "No reboot needed: $REBOOT_NOTE." ;;
    none)
      log "No reboot needed." ;;
    skip:*)
      REBOOT_PENDING=1
      REBOOT_NOTE=${decision#skip:}
      log "REBOOT REQUIRED to load the new kernel ($REBOOT_REASON). Not rebooting: $REBOOT_NOTE. Reboot pending." ;;
    reboot)
      REBOOT_NOTE="rebooting"
      REBOOT_PENDING=1
      write_marker
      log "Kernel/core libs updated - rebooting in 1 minute."
      shutdown -r +1 "Rebooting after system updates" || {
        log "ERROR: shutdown command failed - reboot manually."
        REBOOT_NOTE="shutdown command failed"
      } ;;
  esac

  scan_repo_problems

  # ---- Is a new OS release available? (reported only; never started here) ----
  release_check
  state_set RELEASE_AVAILABLE "$RELEASE_AVAILABLE"
  release_note

  if (( SKIPPED )); then RESULT="skipped"; fi
  if (( FAILED )); then RESULT="failure"; fi
  finish_run
  rc=$?
  if [[ $CMD == legacy ]] && (( ! FAILED )); then release_offer; fi
  return "$rc"
}

cmd_check() {
  local total
  acquire_lock
  UPDATE_MODE_EFFECTIVE=${MODE_OVERRIDE:-$UPDATE_MODE}
  LOG_START=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  load_os_release
  log "==== Start: ${OS_PRETTY:-unknown OS} | kernel $(uname -r) | mode=check ===="
  detect_panel
  if [[ $PANEL == cPanel ]]; then
    log "WARNING: cPanel detected - consider /scripts/upcp; EA-PHP is updated via yum/dnf."
  elif [[ $PANEL == Plesk ]]; then
    log "WARNING: Plesk detected - consider 'plesk installer update'."
  fi
  detect_pm || { log "ERROR: No supported package manager found."; exit 1; }
  log "Package manager: $PM"
  say "Refreshing package lists..."
  pm_refresh
  say "Pending updates:"
  pm_check
  assess_risk 1
  show_risk
  if [[ ${#RISK_HOLD[@]} -gt 0 ]]; then
    log "WARNING: ${#RISK_HOLD[@]} risky update(s) need your review. Scheduled runs hold them back; install with: $PROG --allow-major --backup"
  fi
  total=$(pending_count 0)
  count_deferred
  scan_repo_problems
  if [[ -n $REPO_PROBLEM ]]; then report_repo_problems; fi
  if (( total > 0 )); then
    log "$total update(s) can be installed now."
    log "STATUS: UPDATES PENDING - run '$PROG' to install them (nothing was changed by this check)."
  elif [[ -n $REPO_PROBLEM ]]; then
    log "STATUS: CANNOT CONFIRM THE SYSTEM IS UP TO DATE - fix the package source problem above."
  else
    log "Nothing found - no updates available."
    log "STATUS: UP TO DATE - nothing to install."
  fi
  if (( DEFERRED_COUNT > 0 )); then
    log "NOTE: $DEFERRED_COUNT more update(s) are waiting for Ubuntu's phased rollout (or are held back). They install automatically on a later run - no action needed."
  fi
  reboot_required
  if (( NEED_REBOOT )); then
    log "NOTE: this server already needs a reboot ($REBOOT_REASON) - the newest kernel/libraries are not in use yet."
  fi
  release_check
  release_note
  log "==== Check finished (no changes made) ===="
}

# ------------------------------------------------------------- scheduling ---

delay_seconds() {
  local v=$1
  case "$v" in
    *h)       echo $(( ${v%h} * 3600 )) ;;
    *min)     echo $(( ${v%min} * 60 )) ;;
    *m)       echo $(( ${v%m} * 60 )) ;;
    *sec)     echo "${v%sec}" ;;
    *s)       echo "${v%s}" ;;
    *)        echo "$v" ;;
  esac
}

# Convert SCHEDULE to a cron "m h dom mon dow" expression.
schedule_to_cron() {
  local parts=() days="*" time h m nums
  local re='^([0-9]{1,2}):([0-9]{2})(:[0-9]{2})?$'
  case "$SCHEDULE" in
    daily)  echo "0 0 * * *"; return 0 ;;
    weekly) echo "0 0 * * 1"; return 0 ;;
  esac
  read -ra parts <<<"$SCHEDULE"
  case ${#parts[@]} in
    1) time=${parts[0]} ;;
    2) days=${parts[0]}; time=${parts[1]} ;;
    *) return 1 ;;
  esac
  [[ $time =~ $re ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  (( h <= 23 && m <= 59 )) || return 1
  if [[ $days != "*" ]]; then
    nums=$(days_to_nums "$days") || return 1
    days=$nums
  fi
  echo "$m $h * * $days"
}

render_units() {
  cat >"$UNIT_DIR/$SERVICE_UNIT" <<EOF
[Unit]
Description=linux-autoupdate system update run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN run
Nice=10
EOF
  cat >"$UNIT_DIR/$TIMER_UNIT" <<EOF
[Unit]
Description=linux-autoupdate scheduled system updates

[Timer]
OnCalendar=$SCHEDULE
RandomizedDelaySec=$RANDOM_DELAY
Persistent=true

[Install]
WantedBy=timers.target
EOF
  cat >"$UNIT_DIR/$POSTBOOT_UNIT" <<EOF
[Unit]
Description=linux-autoupdate post-reboot health check
ConditionPathExists=$MARKER
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN postboot

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT_DIR/$SERVICE_UNIT" "$UNIT_DIR/$TIMER_UNIT" "$UNIT_DIR/$POSTBOOT_UNIT"
}

cron_remove() {
  rm -f "$CRON_FILE"
  if [[ -f $CRONTABS_ROOT ]] && grep -q '# BEGIN linux-autoupdate' "$CRONTABS_ROOT"; then
    sed -i '/# BEGIN linux-autoupdate/,/# END linux-autoupdate/d' "$CRONTABS_ROOT"
  fi
}

cron_enable() {
  local expr rd cmd
  expr=$(schedule_to_cron) \
    || die "SCHEDULE \"$SCHEDULE\" cannot be used with cron. Use \"[Day[,Day]] HH:MM\", daily or weekly."
  rd=$(delay_seconds "$RANDOM_DELAY")
  cmd="$BIN run"
  (( rd > 0 )) && cmd+=" --random-delay=$rd"
  cron_remove
  if [[ -d /etc/cron.d ]]; then
    cat >"$CRON_FILE" <<EOF
# Managed by linux-autoupdate - re-run '$PROG enable' after changing SCHEDULE
SHELL=/bin/bash
PATH=$PATH
$expr root $cmd >/dev/null 2>&1
@reboot root sleep 60 && $BIN postboot >/dev/null 2>&1
EOF
    chmod 0644 "$CRON_FILE"
  elif [[ -d /etc/crontabs ]]; then
    cat >>"$CRONTABS_ROOT" <<EOF
# BEGIN linux-autoupdate
$expr $cmd >/dev/null 2>&1
@reboot sleep 60 && $BIN postboot >/dev/null 2>&1
# END linux-autoupdate
EOF
  else
    die "no cron directory found (/etc/cron.d or /etc/crontabs) and no systemd"
  fi
  command -v crond >/dev/null 2>&1 || command -v cron >/dev/null 2>&1 \
    || log "WARNING: no cron daemon found - install and start one for the schedule to run."
  log "Auto-updates ENABLED via cron ($expr)"
}

scheduler_state() {  # prints "systemd", "cron" or "none"
  if has_systemd && systemctl is-enabled --quiet "$TIMER_UNIT" 2>/dev/null; then
    echo systemd
  elif [[ -f $CRON_FILE ]] \
      || { [[ -f $CRONTABS_ROOT ]] && grep -q '# BEGIN linux-autoupdate' "$CRONTABS_ROOT"; }; then
    echo cron
  else
    echo none
  fi
}

cmd_enable() {
  [[ -x $BIN ]] || die "$BIN not found - run '$PROG install' first"
  detect_panel
  if [[ -n $PANEL ]] && (( ! ALLOW_ON_PANELS )); then
    die "$PANEL detected and ALLOW_ON_PANELS=0 - use the panel's updater, or set ALLOW_ON_PANELS=1 in $CONF"
  fi
  if has_systemd && (( ! FORCE_CRON )); then
    if command -v systemd-analyze >/dev/null 2>&1; then
      systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1 \
        || die "SCHEDULE \"$SCHEDULE\" is not a valid systemd calendar expression"
    fi
    render_units
    cron_remove
    systemctl daemon-reload
    systemctl enable "$POSTBOOT_UNIT" >/dev/null 2>&1
    systemctl enable --now "$TIMER_UNIT" || die "could not enable $TIMER_UNIT"
    log "Auto-updates ENABLED via systemd timer (OnCalendar=$SCHEDULE, RandomizedDelaySec=$RANDOM_DELAY)"
  else
    if has_systemd && [[ -f $UNIT_DIR/$TIMER_UNIT ]]; then
      systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1
    fi
    cron_enable
  fi
}

cmd_disable() {
  if has_systemd && [[ -f $UNIT_DIR/$TIMER_UNIT ]]; then
    systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1
  fi
  cron_remove
  log "Auto-updates DISABLED"
}

# ------------------------------------------------------ install/uninstall ---

write_logrotate() {
  mkdir -p "$(dirname "$LOGROTATE_FILE")" || die "could not create $(dirname "$LOGROTATE_FILE")"
  cat >"$LOGROTATE_FILE" <<EOF
$LOG {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
  chmod 0644 "$LOGROTATE_FILE"
}

cmd_install() {
  local src tmp
  (( RUN_FROM_PIPE )) && die "install needs the script saved as a file: download it with 'curl -o /usr/local/sbin/auto-update.sh ...', then run 'auto-update.sh install'"
  src=$(readlink -f "$0" 2>/dev/null) || src=$0
  if [[ ! -f $src ]] || ! grep -q '^PROG="linux-autoupdate"' "$src"; then
    die "install must be run from the downloaded script file"
  fi
  install -d -m 0755 "$(dirname "$BIN")" "$STATE_DIR" || die "could not create directories"
  if [[ $src != "$BIN" ]]; then
    tmp=$(mktemp "$BIN.XXXXXX") || die "could not write to $(dirname "$BIN")"
    if ! { cp "$src" "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$BIN"; }; then
      rm -f "$tmp"
      die "could not install $BIN"
    fi
    log "Installed $BIN (version $VERSION)"
  fi
  if [[ -e $CONF ]]; then
    log "Config $CONF already exists - left unchanged"
  else
    ( umask 077; write_config_template >"$CONF" )
    chmod 0600 "$CONF"
    log "Created config $CONF"
  fi
  write_logrotate
  command -v logrotate >/dev/null 2>&1 || log "WARNING: logrotate is not installed; the rotation rule has no effect until it is."
  log "Wrote logrotate rule $LOGROTATE_FILE"
  if has_systemd; then
    render_units
    systemctl daemon-reload
    systemctl enable "$POSTBOOT_UNIT" >/dev/null 2>&1
    log "Wrote systemd units (timer NOT enabled)"
  else
    log "systemd not detected - 'enable' will use cron"
  fi
  # Keep v1 cron entries that call the old path working.
  if [[ -f $LEGACY_BIN && ! -L $LEGACY_BIN && $LEGACY_BIN != "$BIN" ]] \
      && [[ $(sha256sum <"$src") == "$(sha256sum <"$LEGACY_BIN")" ]]; then
    ln -sfn "$BIN" "$LEGACY_BIN"
    log "Replaced $LEGACY_BIN with a symlink to $BIN"
  fi
  if (( FLAG_ENABLE )); then
    cmd_enable
    cat <<EOF

$PROG $VERSION installed and auto-updates are ENABLED ($SCHEDULE).
 - See the state any time:  $PROG status
 - Change the settings:     $CONF  (then run: $PROG enable)
EOF
  else
    cat <<EOF

$PROG $VERSION installed. Auto-updates are DISABLED.
Next steps:
  1. Review the settings:   $CONF
  2. Try it:                $PROG check
  3. Turn on the schedule:  $PROG enable
EOF
  fi
}

cmd_uninstall() {
  VERBOSE=1
  if has_systemd; then
    systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1
    systemctl disable "$POSTBOOT_UNIT" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$SERVICE_UNIT" "$UNIT_DIR/$TIMER_UNIT" "$UNIT_DIR/$POSTBOOT_UNIT"
    systemctl daemon-reload
  fi
  cron_remove
  rm -f "$LOGROTATE_FILE" "$MARKER"
  if [[ -L $LEGACY_BIN && $(readlink "$LEGACY_BIN") == "$BIN" ]]; then rm -f "$LEGACY_BIN"; fi
  rm -f "$BIN"
  if (( PURGE )); then
    rm -f "$CONF" "$LOG" "$LOG".*
    rm -rf "$STATE_DIR"
    echo "Uninstalled $PROG and purged config, logs and state."
  else
    echo "Uninstalled $PROG. Kept $CONF, $LOG and $STATE_DIR (use --purge to remove them)."
  fi
}

# --------------------------------------------------------- post-reboot check ---

cmd_postboot() {
  VERBOSE=0
  [[ -f $MARKER ]] || return 0
  local services=() failed=() ok=() svc kernel_before release_from="" deadline subject body level line
  while IFS= read -r line; do
    case "$line" in
      release_from=*) release_from=${line#release_from=} ;;
      service=*) services+=("${line#service=}") ;;
      kernel_before=*) kernel_before=${line#kernel_before=} ;;
    esac
  done <"$MARKER"
  log "==== Post-reboot health check (kernel ${kernel_before:-?} -> $(uname -r)) ===="
  deadline=$(( $(date +%s) + 120 ))
  for svc in ${services[@]+"${services[@]}"}; do
    while ! systemctl is-active --quiet "$svc"; do
      (( $(date +%s) >= deadline )) && break
      sleep 5
    done
    if ! systemctl is-active --quiet "$svc"; then
      log "Self-heal: $svc is not active, restarting it once"
      systemctl restart "$svc" >>"$LOG" 2>&1
      sleep 5
    fi
    if systemctl is-active --quiet "$svc"; then
      ok+=("$svc"); log "OK: $svc is active"
    else
      failed+=("$svc"); log "FAILED: $svc is not active"
    fi
  done
  if [[ -n $release_from ]]; then
    load_os_release
    log "Release upgrade check: $release_from -> ${OS_VERSION_ID:-?} (${OS_PRETTY:-?})"
    if ! apt_health; then apt_heal || failed+=("package-system"); fi
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    level=failure
    state_set LAST_BOOT_CHECK "FAILED: ${failed[*]}"
  else
    level=success
    state_set LAST_BOOT_CHECK "ok"
    log "All previously running services are active."
  fi
  state_set LAST_BOOT_CHECK_TIME "$(now)"
  state_set REBOOT_PENDING 0
  state_set REBOOT_NOTE ""
  subject="[$(host_name)] linux-autoupdate: post-reboot check $level"
  body="Kernel: ${kernel_before:-?} -> $(uname -r)
Active: ${ok[*]:-none}
Not active: ${failed[*]:-none}
Log: $LOG"
  notify "$level" "$subject" "$body"
  rm -f "$MARKER"
}

# ----------------------------------------------------------------- status ---

cmd_status() {
  VERBOSE=0
  local sched next last_run last_result updated pending note live rel
  sched=$(scheduler_state)
  case "$sched" in
    systemd) echo "Auto-updates:     enabled (systemd timer)" ;;
    cron)    echo "Auto-updates:     enabled (cron)" ;;
    *)       echo "Auto-updates:     disabled" ;;
  esac
  echo "Schedule:         $SCHEDULE (random delay $RANDOM_DELAY)"
  if [[ $sched == systemd ]]; then
    next=$(systemctl show -p NextElapseUSecRealtime "$TIMER_UNIT" 2>/dev/null | sed 's/^[^=]*=//')
    echo "Next run:         ${next:-unknown}"
  elif [[ $sched == cron ]]; then
    echo "Next run:         per cron ($(schedule_to_cron 2>/dev/null || echo "$SCHEDULE"))"
  else
    echo "Next run:         -"
  fi
  last_run=$(state_get LAST_RUN)
  last_result=$(state_get LAST_RESULT)
  updated=$(state_get PACKAGES_UPDATED)
  if [[ -n $last_run ]]; then
    echo "Last run:         $last_run - ${last_result:-unknown} (${updated:-0} packages updated, mode $(state_get LAST_MODE))"
  else
    echo "Last run:         never"
  fi
  if detect_pm; then
    pending=$(pending_count 1)
    count_deferred
    if (( ${pending:-0} > 0 )); then
      echo "System:           UPDATES PENDING - ${pending} can be installed now (run '$PROG')"
    else
      echo "System:           UP TO DATE - nothing to install"
    fi
    echo "Pending updates:  ${pending:-0} (from cached package metadata, $PM; run '$PROG check' to refresh)"
    if (( DEFERRED_COUNT > 0 )); then
      echo "Deferred:         $DEFERRED_COUNT (Ubuntu phased rollout / held back - install automatically later)"
    fi
  else
    echo "Pending updates:  unknown (no supported package manager)"
  fi
  reboot_required
  detect_livepatch
  note=$(state_get REBOOT_NOTE)
  if (( NEED_REBOOT )); then
    live="yes ($REBOOT_REASON)"
    if [[ -n $LIVEPATCH ]] && (( KERNEL_ONLY )); then live="no action needed - kernel update covered by $LIVEPATCH"; fi
    echo "Reboot required:  $live"
    [[ -n $note ]] && echo "Reboot status:    $note"
  else
    echo "Reboot required:  no"
  fi
  if [[ -n $LIVEPATCH ]]; then
    echo "Livepatch:        $LIVEPATCH active"
  else
    echo "Livepatch:        none detected"
  fi
  rel=$(state_get RELEASE_AVAILABLE)
  if [[ -n $rel ]]; then
    echo "Release upgrade:  Ubuntu $rel available (review it with: $PROG release-upgrade)"
  else
    echo "Release upgrade:  no new release known (checked on the last run)"
  fi
  if [[ -n $(state_get HELD_MAJOR) ]]; then
    echo "Held back:        $(state_get HELD_MAJOR) (major update; install with: $PROG --allow-major --backup)"
  fi
  if [[ -n $(state_get LAST_RELEASE_UPGRADE) ]]; then
    echo "Last upgrade:     $(state_get LAST_RELEASE_UPGRADE) (backup: $(state_get BACKUP_LOCATION))"
  fi
  echo "Update mode:      $UPDATE_MODE | reboot policy: $REBOOT_POLICY | notify: $NOTIFY"
  if [[ -n $(state_get LAST_BOOT_CHECK) ]]; then
    echo "Post-reboot check: $(state_get LAST_BOOT_CHECK) ($(state_get LAST_BOOT_CHECK_TIME))"
  fi
  return 0
}

# ------------------------------------------------------------ risk review ---
# Looks at the updates that are about to be installed and flags the ones that
# can change how a server behaves: kernel, PHP, databases, web servers, OpenSSL,
# libc and similar (RISK_PACKAGES). A change of major.minor version in one of
# those is a "major" update: it is held back in unattended runs and asked about
# in a terminal.

KERNEL_GLOBS="linux-image* linux-modules* kernel kernel-core kernel-modules* kernel-default kernel-lt kernel-ml linux linux-lts linux-hardened linux-zen"

DOCKER_ENGINE_GLOBS="docker-ce docker.io docker-engine moby-engine containerd.io containerd"

# Docker / AzuraCast detection. Updating the Docker engine restarts the Docker
# daemon, which stops every running container unless live-restore is enabled.
detect_containers() {
  CONTAINERS_CHECKED=1
  CONTAINERS_RUNNING=0
  DOCKER_LIVE_RESTORE=0
  AZURACAST=0
  if [[ -f /var/azuracast/docker.sh || -f /var/azuracast/docker-compose.yml ]]; then AZURACAST=1; fi
  command -v docker >/dev/null 2>&1 || return 0
  CONTAINERS_RUNNING=$(timeout 15 docker ps -q 2>/dev/null | grep -c .)
  if grep -qE '"live-restore"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json 2>/dev/null; then
    DOCKER_LIVE_RESTORE=1
  fi
  if (( ! AZURACAST )) && timeout 15 docker ps --format '{{.Names}}' 2>/dev/null | grep -qi '^azuracast'; then
    AZURACAST=1
  fi
  return 0
}

# True when updating the Docker engine would interrupt running containers.
container_guard() {
  (( CONTAINERS_CHECKED )) || detect_containers
  (( CONTAINERS_RUNNING > 0 && ! DOCKER_LIVE_RESTORE ))
}

azuracast_note() {
  (( CONTAINERS_CHECKED )) || detect_containers
  (( AZURACAST )) || return 0
  echo "  AzuraCast detected: its station data lives in Docker volumes, which are NOT part of"
  echo "  this tool's file backup. Back it up with: cd /var/azuracast && ./docker.sh backup"
  echo "  (or take a server snapshot). Update AzuraCast itself with ./docker.sh update."
}

# After an apt update on a container host: list services still running old
# libraries instead of restarting them behind your back.
report_needrestart() {
  local svcs
  command -v needrestart >/dev/null 2>&1 || return 0
  svcs=$(needrestart -b -r l 2>/dev/null | sed -n 's/^NEEDRESTART-SVC: //p' | tr '\n' ' ')
  [[ -n $svcs ]] || return 0
  log "NOTE: services still running old libraries (restart them in a quiet moment, or reboot): ${svcs% }"
}

# Print "name<TAB>installed<TAB>new" for every package that would be updated.
pending_list() {
  local cached=${1:-0} opt=() out line n old
  case "$PM" in
    apt)
      apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / {
        name = $2
        if ($3 ~ /^\[/) { old = $3; new = $4 } else { old = "-"; new = $3 }
        gsub(/\[|\]|\(|\)/, "", old); gsub(/\[|\]|\(|\)/, "", new)
        printf "%s\t%s\t%s\n", name, old, new }' ;;
    dnf|yum)
      (( cached )) && opt=(-C)
      out=$("$PM" ${opt[@]+"${opt[@]}"} -q check-update 2>/dev/null \
        | awk '/^Obsoleting/ {exit} NF == 3 && $1 ~ /\.[A-Za-z0-9_]+$/ {print $1 "\t" $2}')
      while IFS=$'\t' read -r n line; do
        [[ -n $n ]] || continue
        n=${n%.*}
        old=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$n" 2>/dev/null | sort -V | tail -n1)
        printf '%s\t%s\t%s\n' "$n" "${old:--}" "$line"
      done <<<"$out" ;;
    zypper)
      zypper --non-interactive -q list-updates 2>/dev/null | awk -F'|' '/^v/ {
        gsub(/ /, "", $3); gsub(/ /, "", $4); gsub(/ /, "", $5)
        printf "%s\t%s\t%s\n", $3, $4, $5 }' ;;
    pacman)
      pacman -Qu 2>/dev/null | awk 'NF >= 4 {printf "%s\t%s\t%s\n", $1, $2, $4}' ;;
    apk)
      apk version -l '<' 2>/dev/null | awk '/ < / {
        full = $1; new = $3; name = full; sub(/-[0-9][^ ]*$/, "", name)
        printf "%s\t%s\t%s\n", name, substr(full, length(name) + 2), new }' ;;
  esac
}

# ver_series VERSION N -> first N dot-separated numbers ("1:10.11.8-0ubuntu1" -> "10.11")
ver_series() {
  local v=$1 n=$2 parts=() out="" i
  if [[ $v =~ ^[0-9]+: ]]; then v=${v#*:}; fi
  [[ $v =~ ^[^0-9]*([0-9]+(\.[0-9]+)*) ]] || return 0
  IFS=. read -ra parts <<<"${BASH_REMATCH[1]}"
  for (( i = 0; i < n && i < ${#parts[@]}; i++ )); do
    out+="${out:+.}${parts[i]}"
  done
  printf '%s' "$out"
}

glob_match() {  # glob_match NAME "glob glob ..."
  local g globs=()
  read -ra globs <<<"$2"
  for g in ${globs[@]+"${globs[@]}"}; do
    # shellcheck disable=SC2053
    [[ $1 == $g ]] && return 0
  done
  return 1
}

RISK_MAJOR=()
RISK_MAJOR_NAMES=()
RISK_REVIEW=()
RISK_KERNEL=()
RISK_RESTART=()
RISK_HOLD=()

assess_risk() {
  local name old new a b seen="|"
  RISK_MAJOR=()
  RISK_MAJOR_NAMES=()
  RISK_REVIEW=()
  RISK_KERNEL=()
  RISK_RESTART=()
  RISK_HOLD=()
  detect_containers
  read -ra EXCL <<<"$EXCLUDE_PACKAGES"
  while IFS=$'\t' read -r name old new; do
    [[ -n $name && $old != "-" ]] || continue
    [[ $seen == *"|$name|"* ]] && continue   # e.g. glibc.i686 and glibc.x86_64
    seen+="$name|"
    excl_match "$name" && continue
    if glob_match "$name" "$KERNEL_GLOBS"; then
      RISK_KERNEL+=("$name  $old -> $new")
      continue
    fi
    if container_guard && glob_match "$name" "$DOCKER_ENGINE_GLOBS"; then
      RISK_RESTART+=("$name  $old -> $new")
      RISK_MAJOR_NAMES+=("$name")
      continue
    fi
    glob_match "$name" "$RISK_PACKAGES" || continue
    a=$(ver_series "$old" 2)
    b=$(ver_series "$new" 2)
    if [[ -n $a && -n $b && $a != "$b" ]]; then
      RISK_MAJOR+=("$name  $old -> $new")
      RISK_MAJOR_NAMES+=("$name")
    else
      RISK_REVIEW+=("$name  $old -> $new")
    fi
  done < <(pending_list "${1:-0}")
  RISK_HOLD=(${RISK_MAJOR[@]+"${RISK_MAJOR[@]}"} ${RISK_RESTART[@]+"${RISK_RESTART[@]}"})
}

risk_found() { (( ${#RISK_MAJOR[@]} + ${#RISK_RESTART[@]} + ${#RISK_REVIEW[@]} + ${#RISK_KERNEL[@]} > 0 )); }

print_risk_group() {  # title, then lines
  local title=$1 shown=0 l
  shift
  echo "  $title"
  for l in "$@"; do
    if (( shown >= 12 )); then echo "      ... and $(( $# - shown )) more"; break; fi
    echo "      $l"
    shown=$((shown + 1))
  done
}

show_risk() {
  risk_found || return 0
  echo
  echo "Heads-up - review before installing:"
  if [[ ${#RISK_MAJOR[@]} -gt 0 ]]; then
    print_risk_group "MAJOR VERSION CHANGE (can change behaviour or break apps):" "${RISK_MAJOR[@]}"
  fi
  if [[ ${#RISK_RESTART[@]} -gt 0 ]]; then
    print_risk_group "DOCKER ENGINE (restarts ALL $CONTAINERS_RUNNING running container(s); live-restore is off):" "${RISK_RESTART[@]}"
    azuracast_note
  fi
  if [[ ${#RISK_REVIEW[@]} -gt 0 ]]; then
    print_risk_group "Service packages, same major version (services may restart briefly):" "${RISK_REVIEW[@]}"
  fi
  if [[ ${#RISK_KERNEL[@]} -gt 0 ]]; then
    print_risk_group "Kernel (needs a reboot to take effect):" "${RISK_KERNEL[@]}"
  fi
  echo
}

# Runs a backup before updating when asked for. Returns 1 if a backup that was
# requested failed or was cancelled (the updates must then not be installed).
pre_update_backup() {  # $1 = major|normal
  local want=0
  case "$BACKUP_BEFORE_UPDATE" in
    always) want=1 ;;
    major)  [[ $1 == major ]] && want=1 ;;
  esac
  if (( FLAG_BACKUP )); then want=1; fi
  if (( want == 0 )) && [[ $1 == major ]] && is_tty; then want=1; fi
  (( want )) || return 0
  if is_tty; then
    backup_flow "$([[ $1 == major ]] && echo "major-version updates can change how your services behave" || echo "an update can occasionally go wrong")" || return 1
  else
    log "Backing up before updating to ${BACKUP_DESTINATION:-/var/backups/linux-autoupdate} ..."
    backup_to "${BACKUP_DESTINATION:-/var/backups/linux-autoupdate}" || return 1
  fi
  state_set BACKUP_LOCATION "$BACKUP_LOCATION"
  state_set BACKUP_TIME "$(now)"
  log "Backup before update: $BACKUP_LOCATION"
}

# ------------------------------------------------------- release upgrade ---
# Interactive OS release upgrade (Ubuntu only). Never started by the timer,
# cron or 'run': those only record that a new release is available.

# True when we may ask questions: a real terminal, and not a scheduled-style 'run'.
is_tty() { [[ -t 0 && -t 1 && $CMD != run && $CMD != postboot ]]; }

# ask_yn "question" y|n  -> 0 for yes, 1 for no / end of input
ask_yn() {
  local ans hint="[y/N]"
  [[ $2 == y ]] && hint="[Y/n]"
  while true; do
    read -r -p "$1 $hint " ans || return 1
    ans=${ans,,}
    case "$ans" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      "")    [[ $2 == y ]]; return ;;
    esac
    echo "Please answer yes or no."
  done
}

# Read /etc/os-release without letting its variables (e.g. VERSION) leak in.
load_os_release() {
  OS_ID=""
  OS_PRETTY=""
  OS_VERSION_ID=""
  [[ -f /etc/os-release ]] || return 0
  # shellcheck disable=SC1091
  OS_ID=$(. /etc/os-release; printf '%s' "${ID:-}")
  # shellcheck disable=SC1091
  OS_PRETTY=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-}")
  # shellcheck disable=SC1091
  OS_VERSION_ID=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
}

# Sets RELEASE_AVAILABLE (e.g. "26.04.1 LTS") when Ubuntu offers a new release.
release_check() {
  local out
  RELEASE_AVAILABLE=""
  (( RELEASE_UPGRADE_CHECK )) || return 0
  [[ $OS_ID == ubuntu ]] || return 0
  command -v do-release-upgrade >/dev/null 2>&1 || return 0
  out=$(timeout 90 do-release-upgrade -c 2>&1) || true
  RELEASE_AVAILABLE=$(sed -n "s/^New release '\\(.*\\)' available\\.\$/\\1/p" <<<"$out" | head -n1)
  return 0
}

release_note() {
  [[ -n $RELEASE_AVAILABLE ]] || return 0
  log "NOTE: a new Ubuntu release is available: $RELEASE_AVAILABLE. Run '$PROG release-upgrade' in a terminal to review and upgrade."
}

detect_stack() {
  local out="" v
  v=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
  [[ -n $v ]] && out+="PHP $v, "
  if command -v mariadbd >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1; then
    out+="MariaDB, "
  elif command -v mysqld >/dev/null 2>&1; then
    out+="MySQL, "
  fi
  command -v psql >/dev/null 2>&1 && out+="PostgreSQL, "
  command -v nginx >/dev/null 2>&1 && out+="nginx, "
  command -v apache2 >/dev/null 2>&1 && out+="Apache, "
  printf '%s' "${out%, }"
}

show_release_info() {
  local stack
  stack=$(detect_stack)
  cat <<EOF

================================================================
 A new Ubuntu release is available: Ubuntu $RELEASE_AVAILABLE
 This server runs:                  ${OS_PRETTY:-unknown}
================================================================
 Pros of upgrading
   + Longer security and bug-fix support (a new LTS is supported 5 years)
   + Newer kernel, hardware support, and newer PHP / database / web server
   + You avoid running an unsupported release after the current one ends

 Cons and risks
   - Big version jump: PHP, MySQL/MariaDB, Apache/nginx, Python and others
     can change version and configuration. Websites and apps can break and
     must be tested afterwards.
   - Takes about 30-90 minutes and ends with a reboot
   - Third-party repositories (PPAs) are disabled during the upgrade
   - It cannot be rolled back. The only way back is a backup or snapshot.
   - Not supported on cPanel / Plesk servers
EOF
  if [[ -n $stack ]]; then
    echo
    echo " Found on this server: $stack"
    echo " These are likely to change version in the upgrade."
  fi
  cat <<EOF

 If you answer "no", nothing changes: you keep the current release with
 all the latest updates installed.
================================================================
EOF
}

# ---- self-healing helpers ----

apt_health() {
  [[ -z $(dpkg --audit 2>/dev/null) ]] && apt-get check >/dev/null 2>&1
}

apt_heal() {
  log "Self-heal: repairing the package system"
  run dpkg --configure -a
  run apt-get -f install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  run apt-get update
  apt_health
}

# Try to repair the package manager after a failed update (used before one retry).
heal_pm() {
  case "$PM" in
    apt)     apt_heal ;;
    dnf|yum) run "$PM" clean all && run "$PM" makecache ;;
    *)       return 1 ;;
  esac
}

# ---- pre-flight checks ----

pf() {  # pf ok|warn|fail "message"
  case "$1" in
    ok)   printf '  [ ok ] %s\n' "$2" ;;
    warn) printf '  [warn] %s\n' "$2"; PF_WARN=$((PF_WARN + 1)) ;;
    fail) printf '  [FAIL] %s\n' "$2"; PF_FAIL=$((PF_FAIL + 1)) ;;
  esac
  printf '[%s] preflight %s: %s\n' "$(now)" "$1" "$2" >>"$LOG"
}

third_party_sources() {
  {
    grep -hE '^[[:space:]]*deb(-src)?[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null
    grep -hE '^URIs:' /etc/apt/sources.list.d/*.sources 2>/dev/null
  } | grep -viE 'ubuntu\.com|/ubuntu'
}

release_preflight() {
  local held avail boot_avail n
  PF_FAIL=0
  PF_WARN=0
  echo
  echo "Safety checks before the upgrade:"
  detect_panel
  if [[ -n $PANEL ]]; then
    pf fail "$PANEL detected - its updater controls the OS; do not release-upgrade it with this tool"
  else
    pf ok "no control panel (cPanel/Plesk) detected"
  fi

  say "Bringing the system fully up to date first..."
  FAILED=0
  UPDATE_MODE_EFFECTIVE="all"
  pm_refresh
  pm_update
  if (( FAILED )) && heal_pm; then FAILED=0; pm_update; fi
  if (( FAILED )); then
    pf fail "the system could not be fully updated first (see $LOG)"
  else
    pf ok "system is fully up to date"
  fi

  if apt_health || { apt_heal; }; then
    pf ok "package system is healthy"
  else
    pf fail "the package system is broken (dpkg --audit / apt-get check) and automatic repair failed"
  fi

  reboot_required
  if (( NEED_REBOOT )); then
    pf fail "a reboot is pending ($REBOOT_REASON) - reboot first, then run '$PROG release-upgrade' again"
  else
    pf ok "no reboot pending"
  fi

  held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
  if [[ -n $held ]]; then
    pf warn "held packages can block the upgrade: $held"
  else
    pf ok "no held packages"
  fi

  avail=$(df -Pk / | awk 'NR==2 {print $4}')
  if (( avail < 6291456 )); then
    pf fail "less than 6 GB free on / ($(( avail / 1024 )) MB free)"
  else
    pf ok "enough free disk space on / ($(( avail / 1024 )) MB)"
  fi
  if mountpoint -q /boot 2>/dev/null; then
    boot_avail=$(df -Pk /boot | awk 'NR==2 {print $4}')
    if (( boot_avail < 307200 )); then
      pf warn "/boot has only $(( boot_avail / 1024 )) MB free; old kernels may need removing"
    fi
  fi

  detect_containers
  if (( CONTAINERS_RUNNING > 0 )); then
    pf warn "$CONTAINERS_RUNNING Docker container(s) are running; the upgrade restarts Docker, so they stop for a while"
  fi
  if (( AZURACAST )); then
    pf warn "AzuraCast detected: its data is in Docker volumes, not in this tool's backup. Run 'cd /var/azuracast && ./docker.sh backup' first, and expect the streams to drop during the upgrade"
  fi

  n=$(third_party_sources | wc -l)
  if (( n > 0 )); then
    pf warn "$n third-party apt source line(s) found; the upgrade will disable them"
  else
    pf ok "no third-party apt sources"
  fi

  if [[ -n ${SSH_CONNECTION:-} && -z ${TMUX:-} && -z ${STY:-} ]]; then
    pf warn "you are on SSH outside tmux/screen; if the connection drops the upgrade could be interrupted (run 'tmux' first)"
  else
    pf ok "session is protected (console, tmux or screen)"
  fi

  if [[ -n $PRE_UPDATE_HOOK ]]; then
    if run_hook; then pf ok "PRE_UPDATE_HOOK succeeded"; else pf fail "PRE_UPDATE_HOOK failed"; fi
  fi

  echo
  if (( PF_FAIL > 0 )); then
    echo "Cannot continue: fix the items marked [FAIL] and run '$PROG release-upgrade' again."
    return 1
  fi
  if (( PF_WARN > 0 )); then
    ask_yn "Continue despite $PF_WARN warning(s)?" n || return 1
  fi
  return 0
}

# ---- backup ----

# Build a backup set in directory $1 (files, package lists, database dumps, checksums).
make_backup() {
  local dir=$1 paths=() rel=() p est avail rc
  mkdir -p "$dir" || return 1
  chmod 0700 "$dir"
  read -ra want <<<"$BACKUP_PATHS"
  for p in "${want[@]}"; do
    [[ -e $p ]] && paths+=("$p")
  done
  [[ ${#paths[@]} -gt 0 ]] || { echo "None of BACKUP_PATHS exist: $BACKUP_PATHS"; return 1; }
  say "Estimating backup size..."
  est=$(du -skc "${paths[@]}" 2>/dev/null | tail -n1 | awk '{print $1}')
  avail=$(df -Pk "$dir" | awk 'NR==2 {print $4}')
  if (( est > avail )); then
    echo "Not enough free space for the backup: need about $(( est / 1024 )) MB, have $(( avail / 1024 )) MB."
    return 1
  fi
  for p in "${paths[@]}"; do rel+=("${p#/}"); done
  say "Archiving: ${paths[*]}"
  tar -czpf "$dir/files.tar.gz" --ignore-failed-read --exclude="${dir#/}" -C / "${rel[@]}" 2>>"$LOG"
  rc=$?
  if (( rc > 1 )); then echo "Archiving failed (tar exit $rc), see $LOG."; return 1; fi

  cp /etc/os-release "$dir/os-release.txt" 2>/dev/null
  dpkg --get-selections >"$dir/packages.selections" 2>/dev/null
  apt-mark showmanual >"$dir/packages.manual" 2>/dev/null
  apt-mark showhold >"$dir/packages.hold" 2>/dev/null

  if { pgrep -x mysqld || pgrep -x mariadbd; } >/dev/null 2>&1 && command -v mysqldump >/dev/null 2>&1; then
    say "Dumping MySQL/MariaDB databases..."
    mysqldump --all-databases --single-transaction --routines --events --triggers 2>"$dir/mysqldump.err" \
      | gzip >"$dir/mysql-all-databases.sql.gz"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      echo "The database dump failed: $(head -c 300 "$dir/mysqldump.err")"
      ask_yn "Continue the backup without the MySQL/MariaDB dump?" n || return 1
      rm -f "$dir/mysql-all-databases.sql.gz"
    fi
  fi
  if pgrep -x postgres >/dev/null 2>&1 && command -v pg_dumpall >/dev/null 2>&1; then
    say "Dumping PostgreSQL databases..."
    runuser -u postgres -- pg_dumpall 2>"$dir/pg_dumpall.err" | gzip >"$dir/postgres-all.sql.gz"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      echo "The PostgreSQL dump failed: $(head -c 300 "$dir/pg_dumpall.err")"
      ask_yn "Continue the backup without the PostgreSQL dump?" n || return 1
      rm -f "$dir/postgres-all.sql.gz"
    fi
  fi

  cat >"$dir/RESTORE.txt" <<EOF
Backup made by $PROG $VERSION on $(now) from $(host_name) ($OS_PRETTY).

Restore files:        tar -xzpf files.tar.gz -C /
Restore MySQL/MariaDB: zcat mysql-all-databases.sql.gz | mysql
Restore PostgreSQL:    zcat postgres-all.sql.gz | runuser -u postgres -- psql
Reinstall packages:    dpkg --set-selections < packages.selections && apt-get dselect-upgrade
Check integrity:       sha256sum -c SHA256SUMS
EOF
  # shellcheck disable=SC2094
  (cd "$dir" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum >SHA256SUMS)
  if ! { (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1) && tar -tzf "$dir/files.tar.gz" >/dev/null 2>&1; }; then
    echo "Backup verification failed."
    return 1
  fi
  echo "Backup verified: $dir ($(du -sh "$dir" | awk '{print $1}'))"
}

BACKUP_RE_REMOTE='^([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+:/[A-Za-z0-9._/+@-]+$'

# Keep only the newest BACKUP_KEEP of our own backup sets in directory $1.
prune_backups_local() {
  local base=$1 d
  (( BACKUP_KEEP > 0 )) || return 0
  # shellcheck disable=SC2012
  ls -1dt "$base"/linux-autoupdate-backup-* 2>/dev/null | tail -n "+$((BACKUP_KEEP + 1))" | while read -r d; do
    rm -rf -- "$d"
  done
}

backup_local() {  # $1 = base directory, $2 = different|same|auto
  local base=$1 dir
  [[ $base =~ ^/[A-Za-z0-9._/+@-]+$ ]] || { echo "Please give an absolute path without spaces."; return 1; }
  if [[ ! -d $base ]]; then
    if is_tty && ! ask_yn "$base does not exist. Create it?" y; then return 1; fi
    mkdir -p "$base" || return 1
  fi
  if [[ $2 == different ]] && [[ $(stat -c %d "$base") == "$(stat -c %d /)" ]]; then
    echo "$base is on the same disk as the system, so it is not a different disk."
    echo "Use a separate disk/mount, an external server, or the same-server option."
    return 1
  fi
  dir="$base/linux-autoupdate-backup-$(host_name)-$(date +%Y%m%d-%H%M%S)"
  make_backup "$dir" || return 1
  BACKUP_LOCATION="$dir"
  prune_backups_local "$base"
}

# The remote path is validated against BACKUP_RE_REMOTE, so expanding it here is intended.
# shellcheck disable=SC2029
backup_remote() {  # $1 = [user@]host:/path  (key-based login when not in a terminal)
  local dest=$1 host rpath stage name ssh_opts=(-o ConnectTimeout=15)
  host=${dest%%:*}
  rpath=${dest#*:}
  if ! is_tty; then ssh_opts+=(-o BatchMode=yes); fi
  if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
    echo "ssh/scp not found."
    return 1
  fi
  name="linux-autoupdate-backup-$(host_name)-$(date +%Y%m%d-%H%M%S)"
  stage=$(mktemp -d /var/tmp/lau-backup.XXXXXX) || return 1
  if is_tty; then echo "Checking the connection to $host (you may be asked for a password)..."; fi
  if ! ssh "${ssh_opts[@]}" "$host" "mkdir -p '$rpath'"; then
    echo "Could not reach $host. An unattended run needs SSH key login, and the server must already be in known_hosts (run 'ssh $host' once by hand)."
    rm -rf "$stage"
    return 1
  fi
  if ! make_backup "$stage/$name"; then rm -rf "$stage"; return 1; fi
  say "Copying the backup to $host:$rpath ..."
  if ! scp -rpq "${ssh_opts[@]}" "$stage/$name" "$host:$rpath/"; then
    echo "Copy failed."
    rm -rf "$stage"
    return 1
  fi
  if ! ssh "${ssh_opts[@]}" "$host" "cd '$rpath/$name' && sha256sum -c SHA256SUMS >/dev/null 2>&1"; then
    echo "The copy on $host failed its checksum verification."
    rm -rf "$stage"
    return 1
  fi
  rm -rf "$stage"
  BACKUP_LOCATION="$host:$rpath/$name"
  echo "Backup copied and verified on $host:$rpath/$name"
  if (( BACKUP_KEEP > 0 )); then
    ssh "${ssh_opts[@]}" "$host" "cd '$rpath' && ls -1dt linux-autoupdate-backup-* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while read -r d; do rm -rf -- \"\$d\"; done" >/dev/null 2>&1
  fi
}

# Unattended backup to a configured destination (remote user@host:/path or a directory).
backup_to() {
  local dest=$1
  if [[ $dest =~ $BACKUP_RE_REMOTE ]]; then
    backup_remote "$dest"
  else
    backup_local "$dest" auto
  fi
}

# Interactive backup menu. $1 = why a backup is advised.
# Returns 0 when it is safe to continue, 1 when the user cancelled.
backup_flow() {
  local choice dest reason=${1:-"this change cannot easily be undone"}
  echo
  echo "Data safety - $reason, so back up first."
  azuracast_note
  while true; do
    cat <<'EOF'

  1) Back up to an EXTERNAL server over SSH (recommended)
  2) Back up to a different disk or mount on THIS server
  3) Back up on THIS server, same disk (quick, but lost if the disk or server fails)
  4) I already have a snapshot/backup (e.g. a VPS snapshot) I can restore
  5) No backup needed (test server, nothing important)
  6) Cancel
EOF
    read -r -p "Choose 1-6: " choice || return 1
    case "$choice" in
      1)
        read -r -p "External server as user@host:/path (SSH login needed): " dest || return 1
        if [[ $dest =~ $BACKUP_RE_REMOTE ]]; then
          backup_remote "$dest" && return 0
        else
          echo "Please use the form user@host:/absolute/path"
        fi ;;
      2)
        read -r -p "Mounted directory on another disk (e.g. /mnt/backup): " dest || return 1
        backup_local "$dest" different && return 0 ;;
      3)
        read -r -p "Directory on this server [/var/backups/linux-autoupdate]: " dest || return 1
        backup_local "${dest:-/var/backups/linux-autoupdate}" same && {
          echo "Note: this backup is on the same server. It protects against a failed change, not against disk or server loss."
          return 0
        } ;;
      4)
        if ask_yn "Do you have a recent snapshot/backup stored outside this server's disk, and can you restore it?" n; then
          BACKUP_LOCATION="existing snapshot/backup (confirmed by user)"
          return 0
        fi ;;
      5)
        echo "Without a backup, a failure can mean data loss."
        read -r -p 'Type NO BACKUP to continue without one: ' dest || return 1
        if [[ $dest == "NO BACKUP" ]]; then
          BACKUP_LOCATION="none (declined by user)"
          return 0
        fi ;;
      6) return 1 ;;
      *) echo "Please choose 1-6." ;;
    esac
  done
}

# ---- the upgrade itself, with automatic repair ----

do_release_upgrade() {
  local from=$OS_VERSION_ID attempt rc
  write_marker
  echo "release_from=$from" >>"$MARKER"
  export DEBIAN_FRONTEND=noninteractive
  for attempt in 1 2 3; do
    say "Running the release upgrade (attempt $attempt of 3) - this takes a while, please keep this terminal open..."
    run do-release-upgrade -f DistUpgradeViewNonInteractive
    rc=$?
    load_os_release
    if [[ $OS_VERSION_ID != "$from" ]]; then
      log "Release changed: $from -> $OS_VERSION_ID (exit $rc)"
      return 0
    fi
    log "Upgrade attempt $attempt ended (exit $rc) without changing the release - repairing and retrying"
    apt_heal || log "Self-heal could not fully repair the package system"
  done
  return 1
}

release_verify() {
  local svc line bad=0
  log "Verifying the upgraded system"
  if ! apt_health; then
    apt_heal || bad=1
  fi
  # finish anything the upgrade left half-done
  UPDATE_MODE_EFFECTIVE="all"
  FAILED=0
  pm_update
  (( FAILED )) && bad=1
  if [[ -f $MARKER ]]; then
    while IFS= read -r line; do
      case "$line" in
        service=*)
          svc=${line#service=}
          if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "OK: $svc is active"
          else
            log "Self-heal: restarting $svc"
            systemctl restart "$svc" >>"$LOG" 2>&1
            sleep 3
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
              log "OK: $svc recovered after restart"
            else
              log "FAILED: $svc is not running after the upgrade"
              bad=1
            fi
          fi ;;
      esac
    done <"$MARKER"
  fi
  return "$bad"
}

release_upgrade_flow() {
  local from_pretty=$OS_PRETTY from_ver=$OS_VERSION_ID
  release_preflight || return 1
  backup_flow "a release upgrade cannot be undone" || { echo "Upgrade cancelled - nothing was changed."; log "Release upgrade cancelled at the backup step"; return 1; }
  state_set BACKUP_LOCATION "$BACKUP_LOCATION"
  state_set BACKUP_TIME "$(now)"
  log "Backup/safety choice: $BACKUP_LOCATION"
  echo
  echo "Ready to upgrade $from_pretty to Ubuntu $RELEASE_AVAILABLE."
  echo "Backup: $BACKUP_LOCATION"
  ask_yn "Start the upgrade now?" n || { echo "Upgrade cancelled - nothing was changed."; log "Release upgrade cancelled before start"; return 1; }

  log "==== Release upgrade started: $from_pretty -> Ubuntu $RELEASE_AVAILABLE ===="
  if ! do_release_upgrade; then
    log "ERROR: the release upgrade did not complete after 3 attempts"
    state_set LAST_RELEASE_UPGRADE "FAILED $(now)"
    notify failure "[$(host_name)] linux-autoupdate: release upgrade FAILED" "The upgrade from $from_pretty did not complete. Backup: $BACKUP_LOCATION. Log: $LOG"
    cat <<EOF

The upgrade did not complete. Automatic repair was tried 3 times.
 - Details:  $LOG
 - Backup:   $BACKUP_LOCATION
 - Try:      dpkg --configure -a && apt-get -f install, then '$PROG release-upgrade' again
 - To go back, restore from your backup or snapshot (see RESTORE.txt in the backup).
EOF
    return 1
  fi
  load_os_release
  if release_verify; then
    log "SUCCESS: upgraded from $from_pretty ($from_ver) to ${OS_PRETTY:-?}"
    state_set LAST_RELEASE_UPGRADE "OK $from_ver -> $OS_VERSION_ID $(now)"
    notify success "[$(host_name)] linux-autoupdate: release upgrade OK" "Upgraded from $from_pretty to $OS_PRETTY. Backup: $BACKUP_LOCATION."
    echo
    echo "SUCCESS: the server was upgraded to ${OS_PRETTY:-the new release}. A reboot finishes the upgrade."
  else
    log "WARNING: upgraded to ${OS_PRETTY:-?} but some checks failed - see above"
    state_set LAST_RELEASE_UPGRADE "OK WITH WARNINGS $from_ver -> $OS_VERSION_ID $(now)"
    notify failure "[$(host_name)] linux-autoupdate: release upgrade finished with problems" "Upgraded to $OS_PRETTY but some checks failed. Log: $LOG. Backup: $BACKUP_LOCATION."
    echo
    echo "The upgrade finished, but some checks failed. Please review $LOG before relying on this server."
  fi
  state_set RELEASE_AVAILABLE ""
  if ask_yn "Reboot now to finish the upgrade? (recommended)" y; then
    log "Rebooting in 1 minute after the release upgrade."
    shutdown -r +1 "Rebooting to finish the release upgrade" || echo "shutdown failed - please reboot manually."
  else
    echo "Please reboot soon. A health check of your web/PHP/database services runs after the next boot."
  fi
  return 0
}

# Explicit, interactive command.
cmd_release_upgrade() {
  is_tty || die "release-upgrade asks questions, so it must be run in a terminal. It is never run by the timer or cron."
  acquire_lock
  load_os_release
  [[ $OS_ID == ubuntu ]] || die "release upgrades are supported on Ubuntu only (this is ${OS_PRETTY:-an unknown OS})"
  detect_pm || die "apt-get not found"
  if ! command -v do-release-upgrade >/dev/null 2>&1; then
    echo "do-release-upgrade is not installed (package update-manager-core)."
    ask_yn "Install it now?" y || exit 1
    run apt-get install -y update-manager-core || die "could not install update-manager-core"
  fi
  say "Checking for a new Ubuntu release..."
  release_check
  if [[ -z $RELEASE_AVAILABLE ]]; then
    echo "No new Ubuntu release is available for ${OS_PRETTY:-this server}."
    echo "(Release checks follow the Prompt= setting in /etc/update-manager/release-upgrades.)"
    return 0
  fi
  show_release_info
  if ask_yn "Upgrade to Ubuntu $RELEASE_AVAILABLE now?" n; then
    release_upgrade_flow
  else
    log "Release upgrade declined - staying on ${OS_PRETTY:-the current release} with the latest updates."
    echo "OK - staying on ${OS_PRETTY:-the current release}. All the latest updates stay installed."
  fi
}

# Offered after an interactive update.
release_offer() {
  [[ -n $RELEASE_AVAILABLE ]] || return 0
  is_tty || return 0
  [[ $REBOOT_NOTE == rebooting ]] && return 0
  echo
  if (( REBOOT_PENDING )); then
    echo "A new Ubuntu release is available ($RELEASE_AVAILABLE), but a reboot is pending."
    echo "Reboot first, then run '$PROG release-upgrade' to review it."
    return 0
  fi
  if (( UPDATED == 0 )); then
    echo "No package updates were found, but a new Ubuntu release is available."
  fi
  show_release_info
  if ask_yn "Upgrade to Ubuntu $RELEASE_AVAILABLE now?" n; then
    release_upgrade_flow
  else
    log "Release upgrade declined - staying on ${OS_PRETTY:-the current release} with the latest updates."
    echo "OK - staying on ${OS_PRETTY:-the current release}. All the latest updates stay installed."
    echo "You can review the upgrade later with: $PROG release-upgrade"
  fi
}

# ------------------------------------------------------------------- main ---

main() {
  parse_args "$@"
  if [[ $EUID -ne 0 ]]; then
    if (( RUN_FROM_PIPE )); then
      echo "Run as root, for example:"
      echo "  curl -fsSL https://raw.githubusercontent.com/ucartz/linux-autoupdate/v$VERSION/auto-update.sh | sudo bash -s -- ${*:-}"
      exit 1
    fi
    if command -v sudo >/dev/null 2>&1; then
      echo "Not root - running again with sudo..."
      exec sudo -- bash "$(readlink -f "$0")" "$@"
    fi
    echo "Run as root."
    exit 1
  fi
  # Run as 'curl ... | bash': stdin is the pipe the script came from. Children
  # must not read it, so point stdin at /dev/null (no prompts are possible).
  if [[ ! -t 0 ]]; then exec </dev/null; fi
  load_config
  init_log
  case "$CMD" in
    run|postboot) ;;
    *) banner ;;
  esac
  case "$CMD" in
    install)   cmd_install ;;
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    release-upgrade) cmd_release_upgrade ;;
    postboot)  cmd_postboot ;;
    check)     cmd_check ;;
    run)       VERBOSE=0; cmd_update ;;
    legacy)    cmd_update ;;
  esac
}

# Run when executed as a file or piped into bash; do nothing when sourced.
if [[ -z ${BASH_SOURCE[0]:-} ]]; then RUN_FROM_PIPE=1; fi
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
  exit $?
fi
