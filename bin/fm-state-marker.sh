#!/usr/bin/env bash
# fm-state-marker.sh - show what currently holds a worker's lane on its own
# Herdr sidebar row.
#
# Usage:
#   fm-state-marker.sh update <task-id>
#   fm-state-marker.sh clear <task-id>
#   fm-state-marker.sh state <task-id>
#
# update reads the task's CURRENT pipeline state, turns it into one short
# display marker, and reports that marker on the task's own pane.
# It is the only writer of that marker.
# clear requests its removal.
# state prints the marker update it would show.
# It supports tests and decision reads without touching Herdr.
#
# Why this exists: since the review moved inside the validation pipeline it runs
# headlessly, with no terminal of its own, so nothing represents it in the
# sidebar. The lane's own worker does have a row, so that row is the only place
# a supervisor can see that a lane is with the reviewer rather than coding.
#
# COST AND CADENCE. bin/fm-crew-state.sh is not a pure read - it may make
# bounded no-mistakes calls - so bin/fm-classify-lib.sh forbids calling it on
# every wake. update therefore refuses to read state more often than
# FM_STATE_MARKER_INTERVAL seconds (default 60) per task, and shows the last
# known marker in between. A caller may run it every poll; the interval, not the
# caller, bounds the cost. One read per task per interval is the ceiling, and a
# marker that has not changed makes no Herdr call at all.
#
# STALENESS. A marker that still claimed a lane was in review once it was not
# would be worse than no marker, so every state that is not a live pipeline step
# clears it, and bin/fm-teardown.sh drops the record with the rest of the task.
# Only a working or parked run-step verdict ever shows a marker.
#
# Unknown or absent state shows nothing at all rather than a placeholder. A
# task with no local Herdr row - another runtime, or a remote
# secondmate whose row is on another machine - is excluded before any state is
# read, so it never pays for an answer that has nowhere to land. A Herdr that
# rejects the call, or no Herdr at all, leaves the row exactly as it was and
# stays silent, because the marker is cosmetic and the worker is unaffected
# either way.
#
# Paths: task records come from FM_STATE_OVERRIDE or $FM_HOME/state, the glyph
# lookup from FM_CONFIG_OVERRIDE or $FM_HOME/config, and the marker record is
# <state>/<task-id>.state-marker, holding the epoch second of the last state
# read, whether its marker is confirmed on the row, and that marker. Both are
# passed down to the state reader and the lookup, so a secondmate home marks
# its own rows from its own records.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CREW_STATE_BIN="${FM_STATE_MARKER_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
LABELS_BIN="${FM_STATE_MARKER_LABELS_BIN:-$SCRIPT_DIR/fm-model-labels.sh}"
INTERVAL="${FM_STATE_MARKER_INTERVAL:-60}"

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"
}

record_path() {  # <id>
  printf '%s/%s.state-marker' "$STATE" "$1"
}

failure_path() {  # <id>
  printf '%s/%s.state-marker.error' "$STATE" "$1"
}

update_lock_path() {  # <id>
  printf '%s/.state-marker-%s.lock' "$STATE" "$1"
}

now_epoch() {
  date +%s
}

# state_key <crew-state line>: the lookup key for what holds this lane, or
# nothing when no live pipeline step does. Only a run-step verdict speaks for
# the pipeline: a pane-derived or status-log verdict says the worker is busy,
# not which step of the pipeline owns it, and marking those would be the stale
# claim this marker exists to avoid.
state_key() {  # <line>
  local line=$1 state src detail
  case "$line" in state:*) ;; *) return 0 ;; esac
  state=${line#state: }; state=${state%% *}
  src=${line#*source: }; src=${src%% *}
  [ "$src" = run-step ] || return 0
  detail=${line#*source: }
  detail=${detail#* · }
  case "$state" in
    parked) printf 'decision'; return 0 ;;
    working) ;;
    *) return 0 ;;
  esac
  case "$detail" in
    'ci running'*) printf 'ci' ;;
    'validating (fixing'*) printf 'fix' ;;
    'validating (running: '*)
      detail=${detail#validating (running: }
      printf '%s' "${detail%%)*}"
      ;;
    *) return 0 ;;
  esac
}

# marker_for <id>: the marker string for a task's current state, empty for none.
marker_for() {  # <id> -> sets MARKER_VALUE or MARKER_FAILURE
  local line key out
  MARKER_VALUE=
  MARKER_FAILURE=
  if ! line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CREW_STATE_BIN" "$1" 2>/dev/null); then
    MARKER_FAILURE="state read failed"
    return 1
  fi
  key=$(state_key "$line")
  [ -n "$key" ] || return 0
  if ! out=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$LABELS_BIN" marker "$key" 2>&1); then
    out=${out%%$'\n'*}
    out=${out//$'\r'/}
    MARKER_FAILURE="marker lookup failed"
    [ -z "$out" ] || MARKER_FAILURE="$MARKER_FAILURE: ${out:0:200}"
    return 1
  fi
  MARKER_VALUE=$out
}

read_failure() {  # <id> -> sets FAIL_AT, FAIL_MESSAGE
  local path line tab=$'\t'
  FAIL_AT=0
  FAIL_MESSAGE=
  path=$(failure_path "$1")
  [ -r "$path" ] || return 0
  IFS= read -r line < "$path" || return 0
  FAIL_AT=${line%%"$tab"*}
  case "$FAIL_AT" in '' | *[!0-9]*) FAIL_AT=0 ;; esac
  FAIL_MESSAGE=${line#*"$tab"}
  [ "$FAIL_MESSAGE" != "$line" ] || FAIL_MESSAGE=$line
}

write_failure() {  # <id> <epoch> <message>
  local path tmp
  path=$(failure_path "$1")
  tmp="$path.tmp.$$"
  printf '%s\t%s\n' "$2" "$3" > "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

emit_failure_once() {  # <id> <epoch> <message>
  local prior
  read_failure "$1"
  prior=$FAIL_MESSAGE
  write_failure "$1" "$2" "$3"
  [ "$prior" = "$3" ] && return 0
  printf 'error: state marker %s: %s\n' "$1" "$3" >&2
}

clear_failure() {  # <id>
  rm -f "$(failure_path "$1")" 2>/dev/null
}

failure_within_interval() {  # <id> <now>
  local latest=$REC_AT
  read_failure "$1"
  [ "$FAIL_AT" -le "$latest" ] || latest=$FAIL_AT
  [ "$latest" -gt 0 ] && [ $(( $2 - latest )) -lt "$INTERVAL" ]
}

# herdr_target <id>: "<session>\t<pane>" for a task with a local Herdr row, else
# nothing. This is a cheap metadata read and every caller runs it FIRST, before
# any state read: a task with no row to paint must never pay for a pipeline
# state read, and a remote secondmate's read would go over SSH for a row that
# does not exist on this machine at all.
herdr_target() {  # <id>
  local meta backend session pane
  meta="$STATE/$1.meta"
  [ -r "$meta" ] || return 0
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  backend=$(fm_meta_get "$meta" backend)
  [ "$backend" = herdr ] || return 0
  session=$(fm_meta_get "$meta" herdr_session)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  [ -n "$session" ] && [ -n "$pane" ] || return 0
  printf '%s\t%s' "$session" "$pane"
}

# publish <id> <marker>: put <marker> on the task's row, or clear it when empty.
# Returns 0 when the row now holds what was wanted - including when the task has
# no sidebar to paint at all - and 1 when Herdr would not take it. Every failure
# is cosmetic and silent by contract: the caller records what was actually
# shown, so a refusal is retried on the next interval rather than on every poll
# and rather than never again.
publish() {  # <id> <marker>
  local target
  target=$(herdr_target "$1")
  [ -n "$target" ] || return 0
  publish_target "$target" "$2"
}

publish_target() {  # <session>\t<pane> <marker>
  local target=$1 session pane
  session=${target%%	*}
  pane=${target#*	}
  fm_backend_source herdr 2>/dev/null || return 1
  if [ -n "$2" ]; then
    fm_backend_herdr_report_state_marker "$session" "$pane" "$2" >/dev/null 2>&1 || return 1
  else
    fm_backend_herdr_clear_state_marker "$session" "$pane" >/dev/null 2>&1 || return 1
  fi
}

read_record() {  # <id> -> sets REC_AT, REC_CONFIRMED, REC_MARKER
  local rec line rest tab=$'\t'
  REC_AT=0
  REC_CONFIRMED=0
  REC_MARKER=
  rec=$(record_path "$1")
  [ -r "$rec" ] || return 0
  IFS= read -r line < "$rec" || return 0
  REC_AT=${line%%"$tab"*}
  case "$REC_AT" in '' | *[!0-9]*) REC_AT=0 ;; esac
  rest=${line#*"$tab"}
  [ "$rest" != "$line" ] || return 0
  case "$rest" in
    *"$tab"*)
      REC_CONFIRMED=${rest%%"$tab"*}
      REC_MARKER=${rest#*"$tab"}
      case "$REC_CONFIRMED" in 0 | 1) ;; *) REC_CONFIRMED=0 ;; esac
      ;;
    *)
      REC_MARKER=$rest
      ;;
  esac
}

write_record() {  # <id> <epoch> <confirmed> <marker>
  local rec tmp
  rec=$(record_path "$1")
  tmp="$rec.tmp.$$"
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$tmp" 2>/dev/null || return 0
  mv -f "$tmp" "$rec" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

cmd_update() {  # <id>
  local id=${1:-} now marker target current lock
  case "$id" in
    '' | */* | .*) die "update needs a task id" 2 ;;
  esac
  # No row to paint means no state read at all, which is what keeps a tmux task
  # and a remote secondmate off this path entirely rather than merely off Herdr.
  target=$(herdr_target "$id")
  [ -n "$target" ] || return 0
  lock=$(update_lock_path "$id")
  fm_lock_try_acquire "$lock" || return 0
  current=$(herdr_target "$id")
  if [ "$current" != "$target" ]; then
    fm_lock_release "$lock" || true
    return 0
  fi
  read_record "$id"
  now=$(now_epoch)
  if failure_within_interval "$id" "$now"; then
    fm_lock_release "$lock" || true
    return 0
  fi
  if ! marker_for "$id"; then
    current=$(herdr_target "$id")
    if [ "$current" = "$target" ]; then
      emit_failure_once "$id" "$now" "$MARKER_FAILURE"
    fi
    fm_lock_release "$lock" || true
    return 0
  fi
  marker=$MARKER_VALUE
  current=$(herdr_target "$id")
  if [ "$current" != "$target" ]; then
    fm_lock_release "$lock" || true
    return 0
  fi
  clear_failure "$id"
  if [ "$REC_CONFIRMED" = 1 ] && [ "$marker" = "$REC_MARKER" ]; then
    write_record "$id" "$now" 1 "$marker"
  elif publish_target "$target" "$marker"; then
    write_record "$id" "$now" 1 "$marker"
  else
    write_record "$id" "$now" 0 "$REC_MARKER"
  fi
  fm_lock_release "$lock" || true
}

cmd_clear() {  # <id>
  local id=${1:-} lock
  case "$id" in
    '' | */* | .*) die "clear needs a task id" 2 ;;
  esac
  lock=$(update_lock_path "$id")
  fm_lock_acquire_wait "$lock"
  read_record "$id"
  if publish "$id" ""; then
    rm -f "$(record_path "$id")" 2>/dev/null
  elif [ -n "$REC_MARKER" ]; then
    write_record "$id" "$REC_AT" 0 "$REC_MARKER"
  fi
  clear_failure "$id"
  fm_lock_release "$lock" || true
}

cmd_retire() {  # <id>
  local id=${1:-} lock
  case "$id" in
    '' | */* | .*) die "retire needs a task id" 2 ;;
  esac
  lock=$(update_lock_path "$id")
  fm_lock_acquire_wait "$lock"
  rm -f "$(record_path "$id")" 2>/dev/null
  clear_failure "$id"
  fm_lock_release "$lock" || true
}

cmd_state() {  # <id>
  local id=${1:-}
  case "$id" in
    '' | */* | .*) die "state needs a task id" 2 ;;
  esac
  marker_for "$id" || {
    printf 'error: state marker %s: %s\n' "$id" "$MARKER_FAILURE" >&2
    return 1
  }
  printf '%s\n' "$MARKER_VALUE"
}

case "${1:-}" in
  update) shift; cmd_update "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  state) shift; cmd_state "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
