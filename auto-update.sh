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

VERSION="2.0.0"
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
               timer. Auto-updates stay DISABLED until you run 'enable'.
  enable       Enable and start the systemd timer (cron if no systemd)
  disable      Stop the timer / remove the cron entry
  status       Show scheduler state, last run, pending updates, reboot and
               livepatch status
  run          Perform updates (used by the timer; silent, log only)
  check        List pending updates, change nothing
  uninstall    Remove timer, cron, logrotate rule and binary; keeps config and
               logs unless --purge is given

Legacy options (still supported):
  (no arguments)   update everything
  --check          same as 'check'
  --php-only       update only PHP packages
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
      install|enable|disable|status|run|check|uninstall|postboot)
        [[ -n $CMD ]] && { echo "Only one command allowed: $CMD, $arg" >&2; exit 1; }
        CMD="$arg" ;;
      --check)    LEGACY_CHECK=1 ;;
      --php-only) MODE_OVERRIDE="php" ;;
      --reboot)   FLAG_REBOOT=1 ;;
      --purge)    PURGE=1 ;;
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

host_name() { hostname -f 2>/dev/null || hostname; }

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
  [[ -n $EXCLUDE_PACKAGES ]] || return 0
  read -ra EXCL <<<"$EXCLUDE_PACKAGES"
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
  log "Exclusions active: $EXCLUDE_PACKAGES"
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

pm_refresh() {
  case "$PM" in
    apt)    pkg_run apt-get update ;;
    zypper) pkg_run zypper --non-interactive refresh ;;
    apk)    pkg_run apk update ;;
  esac
  return 0
}

pm_check() {
  case "$PM" in
    apt)
      case "$UPDATE_MODE_EFFECTIVE" in
        security) apt-get -s dist-upgrade 2>/dev/null | awk '/^Inst / && /[Ss]ecurity/' | tee -a "$LOG" ;;
        php)      apt list --upgradable 2>/dev/null | grep -i '^php' | tee -a "$LOG" ;;
        *)        apt list --upgradable 2>/dev/null | tee -a "$LOG" ;;
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
      export DEBIAN_FRONTEND=noninteractive
      local APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
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
          pkg_run apt-get autoremove -y ;;
      esac ;;
    dnf|yum)
      case "$UPDATE_MODE_EFFECTIVE" in
        php)      pkg_run "$PM" -y ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} upgrade 'php*' 'ea-php*' ;;
        security) pkg_run "$PM" -y ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} upgrade --security ;;
        *)
          pkg_run "$PM" -y ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} upgrade
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
        *)        pkg_run pacman -Syu --noconfirm ${EXCL_ARGS[@]+"${EXCL_ARGS[@]}"} ;;
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
  exec 9>"$LOCK"
  flock -n 9 || { echo "Another update is already running."; exit 1; }
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
  case "$RESULT" in
    success)
      if (( UPDATED > 0 )); then
        log "SUCCESS: update completed - $UPDATED package(s) updated."
      else
        log "Nothing found - no updates available."
      fi ;;
    skipped) log "Nothing was updated (see the warning above)." ;;
    *)       log "FAILED: the update did not complete - see $LOG for details." ;;
  esac
  log "==== Finished: $RESULT ===="
  subject="[$(host_name)] linux-autoupdate: $RESULT"
  body="Result: $RESULT
Mode: $UPDATE_MODE_EFFECTIVE
Packages updated: $UPDATED
Reboot pending: $REBOOT_PENDING${REBOOT_NOTE:+ ($REBOOT_NOTE)}
Log: $LOG"
  case "$RESULT" in
    success|skipped) notify success "$subject" "$body" ;;
    *)               notify failure "$subject" "$body" ;;
  esac
  if [[ $CMD == run ]]; then
    tell_terminals "linux-autoupdate on $(host_name): $RESULT, $UPDATED package(s) updated${REBOOT_NOTE:+, reboot: $REBOOT_NOTE}. Details: $LOG"
  fi
  [[ $RESULT == success || $RESULT == skipped ]]
}

cmd_update() {
  local before after decision
  (( RANDOM_DELAY_ARG > 0 )) && sleep $(( RANDOM % RANDOM_DELAY_ARG ))
  acquire_lock
  UPDATE_MODE_EFFECTIVE=${MODE_OVERRIDE:-$UPDATE_MODE}

  # ---- Detect OS ----
  # shellcheck disable=SC1091
  [[ -f /etc/os-release ]] && . /etc/os-release
  log "==== Start: ${PRETTY_NAME:-unknown OS} | kernel $(uname -r) | mode=$UPDATE_MODE_EFFECTIVE ===="
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
  say "Detected ${PRETTY_NAME:-this system}; package manager: $PM; update mode: $UPDATE_MODE_EFFECTIVE"

  detect_livepatch
  if [[ -n $LIVEPATCH ]]; then log "Livepatch: $LIVEPATCH active"; else log "Livepatch: none detected"; fi

  if [[ -n $PRE_UPDATE_HOOK ]] && ! run_hook; then
    log "ERROR: PRE_UPDATE_HOOK failed - aborting, nothing was updated."
    RESULT="failure"
    finish_run
    exit 1
  fi

  PHP_BEFORE=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "none")

  setup_exclusions
  say "Refreshing package lists..."
  pm_refresh
  before=$(pending_count 0)
  say "Found $before pending update(s)."
  say "Installing updates - this can take several minutes..."
  pm_update
  after=$(pending_count 0)
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

  if (( SKIPPED )); then RESULT="skipped"; fi
  if (( FAILED )); then RESULT="failure"; fi
  finish_run
}

cmd_check() {
  local total
  acquire_lock
  UPDATE_MODE_EFFECTIVE=${MODE_OVERRIDE:-$UPDATE_MODE}
  # shellcheck disable=SC1091
  [[ -f /etc/os-release ]] && . /etc/os-release
  log "==== Start: ${PRETTY_NAME:-unknown OS} | kernel $(uname -r) | mode=check ===="
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
  total=$(pending_count 0)
  if (( total > 0 )); then
    log "$total update(s) available."
  else
    log "Nothing found - no updates available."
  fi
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
  if has_systemd; then
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
  src=$(readlink -f "$0" 2>/dev/null) || src=$0
  [[ -f $src ]] || die "install must be run from the script file, not from a pipe"
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
  cat <<EOF

$PROG $VERSION installed. Auto-updates are DISABLED.
Next steps:
  1. Review the settings:   $CONF
  2. Try it:                $PROG check
  3. Turn on the schedule:  $PROG enable
EOF
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
  local services=() failed=() ok=() svc kernel_before deadline subject body level
  while IFS= read -r line; do
    case "$line" in
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
    if systemctl is-active --quiet "$svc"; then
      ok+=("$svc"); log "OK: $svc is active"
    else
      failed+=("$svc"); log "FAILED: $svc is not active"
    fi
  done
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
  local sched next last_run last_result updated pending note live
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
    echo "Pending updates:  ${pending:-0} (from cached package metadata, $PM; run '$PROG check' to refresh)"
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
  echo "Update mode:      $UPDATE_MODE | reboot policy: $REBOOT_POLICY | notify: $NOTIFY"
  if [[ -n $(state_get LAST_BOOT_CHECK) ]]; then
    echo "Post-reboot check: $(state_get LAST_BOOT_CHECK) ($(state_get LAST_BOOT_CHECK_TIME))"
  fi
  return 0
}

# ------------------------------------------------------------------- main ---

main() {
  parse_args "$@"
  [[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }
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
    postboot)  cmd_postboot ;;
    check)     cmd_check ;;
    run)       VERBOSE=0; cmd_update ;;
    legacy)    cmd_update ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
  exit $?
fi
