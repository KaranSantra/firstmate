#!/usr/bin/env bash
# Shared owner of a crewmate's browser grant: the environment a granted worker
# is launched with, and the cleanup that must follow it.
#
# Sourced by bin/fm-spawn.sh (which wires the environment into the pane and
# records the grant) and bin/fm-teardown.sh (which stops the session). Both need
# the identical contract, so it is stated once here rather than twice.
#
# The captain's browser model, decided 2026-09-08 and measured in
# data/fm-browser-cost-scale/report.md and data/fm-chrome-devtools-axi-review/report.md:
#
#   none   the default. No browser, no cost.
#   clean  a throwaway isolated browser of the worker's own. Parallel, carries
#          no logins, and depends on nothing else being up. ~0.65GB.
#   work   a sealed compartment inside the ONE work browser the captain signed
#          into once, handed only the cookies for the sites this task named.
#          Isolated, signed in, parallel, and about six times cheaper than a
#          browser of its own. bin/fm-work-browser.sh owns that browser and the
#          compartment operations; this library only wires the result into the
#          launch and cleans it up.
#
# His personal Chrome and the claude-in-chrome extension are reserved for him
# and are not part of this grant; bin/fm-spawn.sh's --chrome is the separate,
# rare opt-in for that route.
#
# Three measured facts this library exists to enforce, each of which fails
# silently or expensively if left to a worker to remember:
#
#   1. Every worker needs a UNIQUE session name, or two workers share one
#      browser and silently read each other's pages with no error. The task id
#      is that name.
#   2. A session's port is otherwise hashed into 1000 slots shared with every
#      other lane on the machine, which collided at 19 live sessions and then
#      fails that worker's name permanently. An explicit port outside the
#      hashed range removes the failure entirely.
#   3. Cleanup MUST stop the session, or roughly 680MB leaks per worker for as
#      long as the machine is up.
#
# Headless is deliberately not configured: it is already this tool's default and
# was measured to save nothing (652MB windowed vs 662MB headless), so there is
# no memory reason to set it either way.
#
# The engine is deliberately NOT pinned. chrome-devtools-axi 0.1.34 injects a
# pageId that engine 1.7.0 rejects, so the older "pin the engine to 1.7.0"
# advice now breaks every page command.

# The tool derives an unnamed session's port by hashing into 9225..10224. Every
# firstmate grant is allocated above that range so a firstmate worker can never
# collide with a hashed session from another lane, only with another explicit
# allocation, which fm_browser_allocate_port checks directly.
FM_BROWSER_PORT_BASE=${FM_BROWSER_PORT_BASE:-11000}
FM_BROWSER_PORT_LIMIT=${FM_BROWSER_PORT_LIMIT:-11999}

# Measured recommendation: 4 concurrent browser workers routine on the captain's
# machine, where a `clean` worker is a whole browser at ~0.65GB with no economy
# of scale. A `work` compartment is far cheaper and five ran concurrently
# without interference, so a home running only compartments can safely raise
# config/browser-worker-cap. One cap counts both kinds, because a mixed fleet
# has no single honest per-worker figure. It counts THIS home only, which the
# refusal states rather than implies, since other lanes are invisible here.
FM_BROWSER_DEFAULT_CAP=4

fm_browser_mode_valid() {  # <mode>
  case "${1:-}" in
    clean|work) return 0 ;;
    *) return 1 ;;
  esac
}

# True when something is already listening on the port. Uses bash's own /dev/tcp
# so the check needs no external tool on either supported platform.
fm_browser_port_in_use() {  # <port>
  local port=$1
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || return 1
  exec 3<&- 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  return 0
}

# Ports already handed to a live task in this home. A recorded port is reserved
# even when nothing is listening yet, because a granted worker may not have
# opened its browser at the moment a sibling spawns.
fm_browser_reserved_ports() {  # <state-dir> [<exclude-task-id>]
  local state=$1 exclude=${2:-} meta id port
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    port=$(sed -n 's/^browser_port=//p' "$meta" 2>/dev/null | head -n 1)
    [ -n "$port" ] && printf '%s\n' "$port"
  done
  return 0
}

# Lowest free port at or above the base: not recorded by a sibling task and not
# currently listening. The residual race - a port free here that another lane
# claims before this worker opens its browser - is real but far smaller than the
# hashed-slot collision it replaces, and it surfaces as the tool's own loud
# BRIDGE_NOT_READY rather than as silent crosstalk.
fm_browser_allocate_port() {  # <state-dir> [<exclude-task-id>]
  local state=$1 exclude=${2:-} reserved port
  reserved=$(fm_browser_reserved_ports "$state" "$exclude")
  port=$FM_BROWSER_PORT_BASE
  while [ "$port" -le "$FM_BROWSER_PORT_LIMIT" ]; do
    if ! printf '%s\n' "$reserved" | grep -qx "$port"; then
      if ! fm_browser_port_in_use "$port"; then
        printf '%s\n' "$port"
        return 0
      fi
    fi
    port=$((port + 1))
  done
  echo "error: no free browser port between $FM_BROWSER_PORT_BASE and $FM_BROWSER_PORT_LIMIT" >&2
  return 1
}

fm_browser_cap() {  # <config-dir>
  local config=$1 configured
  if [ -f "$config/browser-worker-cap" ]; then
    configured=$(head -n 1 "$config/browser-worker-cap" 2>/dev/null | tr -d '[:space:]')
    case "$configured" in
      ''|*[!0-9]*) echo "error: config/browser-worker-cap must be a positive whole number; got '$configured'" >&2; return 1 ;;
      *) [ "$configured" -gt 0 ] || { echo "error: config/browser-worker-cap must be greater than zero" >&2; return 1; }
         printf '%s\n' "$configured"; return 0 ;;
    esac
  fi
  printf '%s\n' "$FM_BROWSER_DEFAULT_CAP"
}

# Task records in this home that already hold a browser grant.
fm_browser_granted_count() {  # <state-dir> [<exclude-task-id>]
  local state=$1 exclude=${2:-} meta id count=0
  if [ -d "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      id=${meta##*/}; id=${id%.meta}
      [ "$id" != "$exclude" ] || continue
      grep -q '^browser=' "$meta" 2>/dev/null && count=$((count + 1))
    done
  fi
  printf '%s\n' "$count"
}

# The environment a granted worker is launched with, one `NAME=value` per line.
# Callers quote and join it for their own launch surface.
fm_browser_launch_env() {  # <mode> <task-id> <bridge-port> <work-browser-url>
  local mode=$1 id=$2 port=$3 browser_url=$4
  printf 'CHROME_DEVTOOLS_AXI_SESSION=%s\n' "$id"
  printf 'CHROME_DEVTOOLS_AXI_PORT=%s\n' "$port"
  # Holds a profile at ~17MB instead of ~87MB, durably, with no loss of
  # function. Disk only - it saves no memory.
  printf 'CHROME_DEVTOOLS_AXI_CHROME_ARGS=%s\n' '--disable-component-update --disable-component-extensions-with-background-pages'
  # A work grant attaches to the running work browser; the worker then drives
  # its own compartment's tab inside it. A clean grant sets neither a browser URL
  # nor a profile, which is the tool's isolated throwaway mode - exactly what a
  # worker with no logins wants.
  [ "$mode" = work ] && printf 'CHROME_DEVTOOLS_AXI_BROWSER_URL=%s\n' "$browser_url"
  return 0
}

# Stop a task's browser session. Idempotent: stopping a session that was never
# started reports "stopped (no-op)" and exits 0, so teardown can always call it.
# Best effort by contract - a stop failure must never block a teardown - but it
# is reported so a leak is visible rather than silent.
fm_browser_stop_session() {  # <task-id> <port>
  local id=$1 port=$2 out
  command -v chrome-devtools-axi >/dev/null 2>&1 || {
    echo "browser-cleanup: chrome-devtools-axi not on PATH; session '$id' may still hold a browser" >&2
    return 1
  }
  if out=$(CHROME_DEVTOOLS_AXI_SESSION="$id" CHROME_DEVTOOLS_AXI_PORT="$port" \
      chrome-devtools-axi stop 2>&1); then
    return 0
  fi
  echo "browser-cleanup: could not stop browser session '$id': $out" >&2
  return 1
}
