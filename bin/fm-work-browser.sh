#!/usr/bin/env bash
# The fleet work browser: ONE Chrome the captain signs into once, inside which
# each worker gets its own sealed compartment holding only the sites that worker
# needs.
#
# Usage: fm-work-browser.sh start|sign-in|hide|status|stop|url
#        fm-work-browser.sh compartment-open <task-id> <site>[,<site>...]
#        fm-work-browser.sh compartment-close <context-id>
#
# This is NOT the captain's personal Chrome and never touches it. It is a
# separate browser with its own profile directory, on its own debugging port,
# holding only work sites. His own Chrome and the claude-in-chrome extension
# stay reserved for him.
#
#   start     launch it headless and leave it running. Headless because opening
#             a compartment pops a window in a VISIBLE browser, which would
#             interrupt whoever is looking at it. If it is already running and
#             visible, start names hide instead of leaving it on screen.
#   sign-in   launch it headed, once, so the captain can sign into the work
#             sites himself. Firstmate never signs in for him and never reads
#             session values out of his personal Chrome. A hidden browser is
#             restarted visible, keeping its sessions, and like hide this refuses
#             while a worker compartment is open. Once the owner has signed in, run hide before any worker gets a page.
#   hide      restart a visible browser headless, keeping its sessions (the same
#             stop and headless start this script already uses). Refuses while
#             a worker compartment is open, because a restart closes those
#             pages, and lists their context ids. Does nothing if it is already hidden.
#   stop      close it. Sessions survive in the profile because every launch
#             passes --restore-last-session.
#
# --restore-last-session is not optional. Enterprise apps commonly keep a login
# only "until you close the browser", written to disk with no expiry; without
# this flag Chrome drops exactly those on the next launch and the browser opens
# silently signed out (proved in data/fm-browser-session-strategy/report.md).
#
# The port defaults to 9333 and never to 9222, which is where the captain's own
# Chrome listens; config/work-browser-port overrides it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

CHROME_BIN="${FM_WORK_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
}

work_browser_port() {
  local configured
  if [ -f "$CONFIG/work-browser-port" ]; then
    configured=$(head -n 1 "$CONFIG/work-browser-port" 2>/dev/null | tr -d '[:space:]')
    case "$configured" in
      ''|*[!0-9]*) echo "error: config/work-browser-port must be a port number; got '$configured'" >&2; return 1 ;;
    esac
    # 9222 is the captain's own Chrome. Pointing the fleet there would put every
    # worker back inside the browser he is using, which is the one thing this
    # design exists to prevent.
    if [ "$configured" = 9222 ]; then
      echo "error: config/work-browser-port is 9222, which is the captain's own Chrome; the work browser must be a separate browser on its own port" >&2
      return 1
    fi
    printf '%s\n' "$configured"
    return 0
  fi
  printf '%s\n' "${FM_WORK_BROWSER_PORT:-9333}"
}

work_browser_profile() {
  local configured
  if [ -f "$CONFIG/work-browser-profile" ]; then
    configured=$(head -n 1 "$CONFIG/work-browser-profile" 2>/dev/null | tr -d '\r')
    case "$configured" in
      /*) printf '%s\n' "$configured"; return 0 ;;
      '') ;;
      *) echo "error: config/work-browser-profile must hold an absolute path; got '$configured'" >&2; return 1 ;;
    esac
  fi
  printf '%s\n' "$DATA/work-browser-profile"
}

work_browser_url() {
  local port
  # Command substitution swallows the exit status, so resolve the port first and
  # propagate its refusal rather than printing a URL with an empty port.
  port=$(work_browser_port) || return 1
  printf 'http://127.0.0.1:%s\n' "$port"
}

work_browser_running() {
  curl -s --max-time 3 "$(work_browser_url)/json/version" >/dev/null 2>&1
}

# Prints hidden or visible. Hidden means the /json/version body carries Chrome's
# HeadlessChrome marker. On current Chrome that marker is in the User-Agent, not
# the Browser field, so the whole body is the signal. Anything that answers
# without the marker is visible: a worker page in that browser pops on screen.
work_browser_visibility() {
  local body url status
  url=$(work_browser_url) || return 1
  status=0
  body=$(curl -fsS --max-time 3 "$url/json/version" 2>/dev/null) || status=$?
  [ "$status" -eq 0 ] || return "$status"
  [ -n "$body" ] || return 1
  case "$body" in
    *HeadlessChrome*) printf '%s\n' hidden ;;
    *) printf '%s\n' visible ;;
  esac
}

# Open a worker page only when /json/version confirms the browser is hidden.
# A timeout or any other unreadable read refuses and names hide. Nothing
# listening is not a visible browser, and it still does not open.
work_browser_require_hidden() {
  local vis status url
  status=0
  vis=$(work_browser_visibility) || status=$?
  if [ "$status" -eq 0 ] && [ "$vis" = hidden ]; then
    return 0
  fi
  if [ "$status" -eq 7 ]; then
    url=$(work_browser_url) || return 1
    echo "error: the work browser is not answering at $url; start it with bin/fm-work-browser.sh start" >&2
    return 1
  fi
  echo "error: the work browser is visible, so a worker page would open on screen; hide it with bin/fm-work-browser.sh hide before any worker gets a page" >&2
  return 1
}

# A restart closes every open page. List the worker compartments by context id
# and stop rather than dropping a worker's page. Listing failure refuses too:
# restarting when the list cannot be read would close pages we failed to list.
work_browser_require_no_compartments() {  # <action>
  local contexts
  contexts=$(node "$SCRIPT_DIR/fm-work-browser-cdp.mjs" compartments "$(work_browser_url)") || return 1
  if [ -n "$contexts" ]; then
    echo "error: cannot $1 while a worker compartment is open, because a restart closes those pages:" >&2
    printf '%s\n' "$contexts" >&2
    return 1
  fi
}

launch() {  # <headed|headless>
  local visibility=$1 port profile vis
  port=$(work_browser_port) || return 1
  profile=$(work_browser_profile) || return 1
  if work_browser_running; then
    vis=$(work_browser_visibility) || vis=visible
    if [ "$vis" != hidden ]; then
      echo "the work browser is already running on port $port, and it is visible; hide it with bin/fm-work-browser.sh hide before any worker gets a page" >&2
      return 0
    fi
    echo "the work browser is already running on port $port"
    return 0
  fi
  [ -x "$CHROME_BIN" ] || { echo "error: Chrome not found at '$CHROME_BIN'; set FM_WORK_BROWSER_CHROME" >&2; return 1; }
  mkdir -p "$profile"
  set -- \
    --user-data-dir="$profile" \
    --remote-debugging-port="$port" \
    --no-first-run --no-default-browser-check \
    --restore-last-session
  # Headless saves no memory (652MB windowed vs 662MB headless, measured); it is
  # used so compartment windows never appear on screen, not to save anything.
  [ "$visibility" = headed ] || set -- "$@" --headless=new
  nohup "$CHROME_BIN" "$@" >/dev/null 2>&1 &
  local waited=0
  while [ "$waited" -lt 20 ]; do
    work_browser_running && { echo "work browser up on port $port ($visibility)"; return 0; }
    sleep 1
    waited=$((waited + 1))
  done
  echo "error: the work browser did not come up on port $port within 20s" >&2
  return 1
}

case "${1:---help}" in
  --help|-h|help) usage ;;
  url) work_browser_url ;;
  start) launch headless ;;
  sign-in)
    # A hidden browser has no window to sign in through. Restart it visible with
    # the same stop and a headed launch, which keeps its sessions.
    if work_browser_running; then
      vis=$(work_browser_visibility) || vis=unknown
      if [ "$vis" = hidden ]; then
        work_browser_require_no_compartments "restart the work browser visible for sign-in" || exit 1
        "$SCRIPT_DIR/fm-work-browser.sh" stop || exit 1
      fi
    fi
    launch headed || exit 1
    profile=$(work_browser_profile)
    cat <<MSG
Sign in to the work sites in the work browser window. Once the owner has signed in, run hide before any worker gets a page.
  bin/fm-work-browser.sh hide
A visible browser puts each later worker page on screen. hide restarts it headless and keeps its sessions, which live in $profile and survive because every launch passes --restore-last-session.
MSG
    ;;
  hide)
    if ! work_browser_running; then
      echo "error: the work browser is not running; start it hidden with bin/fm-work-browser.sh start" >&2
      exit 1
    fi
    vis=$(work_browser_visibility) || {
      echo "error: could not tell whether the work browser is hidden; refusing to restart it" >&2
      exit 1
    }
    if [ "$vis" = hidden ]; then
      echo "the work browser is already hidden; nothing to do"
      exit 0
    fi
    work_browser_require_no_compartments "hide the work browser" || exit 1
    "$SCRIPT_DIR/fm-work-browser.sh" stop || exit 1
    "$SCRIPT_DIR/fm-work-browser.sh" start || exit 1
    vis=$(work_browser_visibility) || {
      echo "error: hide restarted the work browser but could not confirm it is hidden" >&2
      exit 1
    }
    if [ "$vis" != hidden ]; then
      echo "error: hide restarted the work browser but it is still visible" >&2
      exit 1
    fi
    echo "work browser is hidden; its sessions were kept because every launch passes --restore-last-session"
    ;;
  status)
    if work_browser_running; then
      vis=$(work_browser_visibility) || vis=unknown
      echo "work browser: running on $(work_browser_url) ($vis)"
      node "$SCRIPT_DIR/fm-work-browser-cdp.mjs" status "$(work_browser_url)"
    else
      echo "work browser: not running (start it with bin/fm-work-browser.sh start)"
      exit 1
    fi
    ;;
  stop)
    if work_browser_running; then
      port=$(work_browser_port) || exit 1
      pkill -f "remote-debugging-port=$port" 2>/dev/null || true
      # Chrome does not exit instantly, and reporting a stop that did not happen
      # is how ~680MB per browser leaks unnoticed. Confirm it is really gone, and
      # escalate to SIGKILL rather than claiming success.
      waited=0
      while [ "$waited" -lt 10 ]; do
        work_browser_running || break
        sleep 1
        waited=$((waited + 1))
      done
      if work_browser_running; then
        pkill -9 -f "remote-debugging-port=$port" 2>/dev/null || true
        waited=0
        while [ "$waited" -lt 5 ]; do
          work_browser_running || break
          sleep 1
          waited=$((waited + 1))
        done
      fi
      if work_browser_running; then
        echo "error: the work browser on port $port is still answering after SIGTERM and SIGKILL" >&2
        exit 1
      fi
      echo "work browser stopped"
    else
      echo "work browser was not running"
    fi
    ;;
  compartment-open)
    [ $# -ge 3 ] || { echo "error: compartment-open needs <task-id> <site>[,<site>...]" >&2; exit 1; }
    work_browser_require_hidden || exit 1
    node "$SCRIPT_DIR/fm-work-browser-cdp.mjs" open "$(work_browser_url)" "$2" "$3"
    ;;
  compartment-close)
    [ $# -ge 2 ] || { echo "error: compartment-close needs <context-id>" >&2; exit 1; }
    node "$SCRIPT_DIR/fm-work-browser-cdp.mjs" close "$(work_browser_url)" "$2"
    ;;
  *) echo "error: unknown command '$1'" >&2; usage >&2; exit 1 ;;
esac
