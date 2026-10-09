#!/usr/bin/env bash
# tests/fm-watch-parked-run.test.sh - bin/fm-watch.sh's parked_run_tick: a
# no-mistakes run parked on its WORKER ("awaiting_agent: parked <duration>")
# wakes firstmate once per parked episode after a threshold, even when the
# worker's latest status line is a declared `paused:` wait. Each case drives a
# real watcher subprocess against a hermetic fake fm-crew-state.sh (the verdict
# line is the contract between bin/fm-crew-state.sh and the watcher; the
# crew-state half is pinned in tests/fm-crew-state.test.sh) and reads the
# durable wake queue back.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-parked-run-tests)

TASK=parkedrun
WINDOW="test:fm-$TASK"
FAKE_VAR="FM_FAKE_CREW_STATE_$(printf '%s' "$TASK" | tr -c 'A-Za-z0-9' '_')"
PAUSED_LINE='paused [at=1]: waiting for the run to return a gate or outcome'

# <parked-for-secs> [<findings>] [<run>] [<step>]: the verdict fm-crew-state.sh
# renders for a run parked on its worker.
parked_verdict() {
  printf 'state: parked · source: run-step · parked at %s: %s finding(s) · parked-for: %ss · run: %s' \
    "${4:-review}" "${2:-1}" "$1" "${3:-01RUNPARK}"
}

# <name> [<status-log>] [<kind>]: a case with one task whose endpoint is recorded.
parked_case() {
  local name=$1 log=${2:-$PAUSED_LINE} kind=${3:-ship} dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/config"
  printf 'window=%s\nkind=%s\nharness=grok\nbackend=tmux\n' "$WINDOW" "$kind" > "$state/$TASK.meta"
  printf '%s\n' "$log" > "$state/$TASK.status"
  # The status line was already surfaced; only the parked run is under test.
  prime_status_seen "$state" "$state/$TASK.status"
  printf 'waiting for the run' > "$dir/pane.txt"
  printf '%s\n' "$dir"
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# 0 once <pid>'s watcher has completed a whole poll cycle (the liveness beacon is
# touched at the top of every poll, so wait for two distinct touches), 1 if it
# exited first. Without it a "stayed silent" assertion could pass before the
# poll it describes ever ran.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first='' now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

parked_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && index($5, "no-mistakes run parked on worker") > 0 { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# One watcher run against <verdict>. The per-task read marker is dropped first so
# the read is due at once. <expect> is `wake` (the watcher must exit on the
# wake) or `quiet` (it must survive a whole poll cycle with no parked-run wake).
# Extra environment assignments follow.
parked_round() {  # <dir> <verdict> <wake|quiet> [env...]
  local dir=$1 verdict=$2 expect=$3 state pid fakebin out
  shift 3
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  rm -f "$state/.parked-run-check-$TASK" "$out"
  env PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_CONFIG_OVERRIDE="$dir/config" "$FAKE_VAR=$verdict" \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_STALE_ESCALATE_SECS=999999 "$@" "$WATCH" > "$out" &
  pid=$!
  if [ "$expect" = wake ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; return 1; }
  reap "$pid"
  return 0
}

test_parked_run_wakes_once_per_episode_even_under_a_declared_pause() {
  local dir state out
  dir=$(parked_case wake-once); state="$dir/state"; out="$dir/watch.out"

  parked_round "$dir" "$(parked_verdict 420 1)" wake \
    || fail "a run parked on its worker for 7m never woke firstmate: $(cat "$out")"
  [ "$(parked_wakes "$state")" -eq 1 ] \
    || fail "expected exactly one parked-run wake: $(cat "$state/.wake-queue")"
  grep -F "stale: $WINDOW (task $TASK: no-mistakes run parked on worker 7m at review, 1 finding)" "$out" >/dev/null \
    || fail "the wake reason lost the task, duration, step or finding count: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the parked-run wake"

  # The same episode keeps being read as parked and must stay silent, however
  # long it runs: one wake per episode.
  parked_round "$dir" "$(parked_verdict 900 1)" quiet \
    || fail "the watcher exited while re-reading the same parked episode: $(cat "$dir/watch.out")"
  [ "$(parked_wakes "$state")" -eq 0 ] \
    || fail "the same parked episode woke a second time: $(cat "$state/.wake-queue")"
  parked_round "$dir" "$(parked_verdict 3900 3)" quiet \
    || fail "the watcher exited on a long-running parked episode"
  [ "$(parked_wakes "$state")" -eq 0 ] \
    || fail "a long parked episode woke again: $(cat "$state/.wake-queue")"
  pass "a parked run wakes once per episode with task, step, duration and finding count, under a declared pause"
}

test_parked_run_reason_reports_plural_findings_and_longer_durations() {
  local dir state out
  dir=$(parked_case wake-plural); state="$dir/state"; out="$dir/watch.out"
  parked_round "$dir" "$(parked_verdict 4500 2 01RUNPARK test)" wake \
    || fail "a run parked for over an hour never woke: $(cat "$out")"
  grep -F "no-mistakes run parked on worker 1h15m at test, 2 findings)" "$out" >/dev/null \
    || fail "the plural finding count or the hour duration was misworded: $(cat "$out")"
  pass "the wake reason words plural findings and hour-long waits"
}

test_runs_that_are_not_parked_on_the_worker_stay_silent() {
  local dir state verdict n=0
  for verdict in \
    "$(parked_verdict 120 1)" \
    'state: working · source: run-step · validating (running: review)' \
    'state: parked · source: run-step · parked at review: 1 finding(s) · run: 01RUNPARK' \
    "state: parked · source: status-log · parked at review: 1 finding(s) · parked-for: 900s · run: 01RUNPARK" \
    'state: unknown · source: run-step · run inventory unavailable' \
    'state: paused · source: status-log · waiting for the run to return a gate or outcome' \
    'state: done · source: run-step · checks green: PR ready for review'; do
    n=$((n + 1))
    dir=$(parked_case "silent-$n"); state="$dir/state"
    parked_round "$dir" "$verdict" quiet \
      || fail "the watcher exited on a verdict that is not a run parked past the threshold: $verdict"
    [ "$(parked_wakes "$state")" -eq 0 ] \
      || fail "a verdict that is not a run parked past the threshold woke firstmate: $verdict: $(cat "$state/.wake-queue")"
  done
  pass "a parked run under the threshold, a working run, a gate with no worker clock, a non-run source, an unreadable run and a finished run all stay silent"
}

test_a_task_with_no_run_or_not_a_ship_stays_silent() {
  local dir state
  dir=$(parked_case no-run); state="$dir/state"
  parked_round "$dir" 'state: paused · source: status-log · waiting' quiet || fail "the no-run case exited"
  [ ! -e "$state/.parked-run-$TASK" ] || fail "a task with no run left an episode record"
  [ "$(cat "$state/.parked-run-check-$TASK" 2>/dev/null)" = 60 ] \
    || fail "a task with no run did not keep the fixed 60s re-read interval"

  dir=$(parked_case scout-kind "$PAUSED_LINE" scout); state="$dir/state"
  parked_round "$dir" "$(parked_verdict 900 1)" quiet || fail "the scout case exited"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "a scout task woke on a parked run"
  [ ! -e "$state/.parked-run-check-$TASK" ] || fail "a scout task was read at all"
  pass "a task with no run keeps the 60s cadence, and scout tasks are never read"
}

test_oldest_due_run_is_read_before_the_cap() {
  local dir state name back
  dir=$(parked_case oldest-due); state="$dir/state"
  back=$(( $(date +%s) - 120 ))
  for name in a01 a02 a03 a04 a05 a06 a07 a08 a09 a10 a11 a12; do
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$WINDOW" > "$state/$name.meta"
    printf '60' > "$state/.parked-run-check-$name"
    fm_touch_epoch "$back" "$state/.parked-run-check-$name"
  done
  parked_round "$dir" "$(parked_verdict 420 1)" wake \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' FM_POLL=60 \
    || fail "a later-listed parked task was skipped behind twelve due working runs: $(cat "$dir/watch.out")"
  [ "$(parked_wakes "$state")" -eq 1 ] || fail "the oldest due parked run did not wake in the first poll"
  pass "an oldest-due parked run is read before the per-poll cap"
}

test_run_only_read_skips_forge() {
  local dir state
  dir=$(parked_case no-forge); state="$dir/state"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_CREW_STATE_RUN_ONLY:-}" = 1 ]; then
  printf '%s\n' "${FM_CREW_STATE_NO_FORGE:-unset}" >> "$FM_FAKE_CREW_STATE_LOG"
fi
printf '%s\n' 'state: done · source: run-step · run completed'
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  parked_round "$dir" unused quiet FM_FAKE_CREW_STATE_LOG="$dir/no-forge.log" \
    || fail "a terminal run unexpectedly woke the watcher: $(cat "$dir/watch.out")"
  [ "$(cat "$dir/no-forge.log")" = 1 ] || fail "the run-only watcher read did not suppress forge access"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "a terminal run woke as parked"
  pass "a run-only terminal read skips forge access"
}

test_leaving_and_reentering_parked_starts_a_new_episode() {
  local dir state out
  dir=$(parked_case reenter); state="$dir/state"; out="$dir/watch.out"

  parked_round "$dir" "$(parked_verdict 360 1)" wake || fail "the first episode never woke: $(cat "$out")"
  grep -F 'at review, 1 finding)' "$out" >/dev/null || fail "the first wake lost the step or finding count: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first wake"

  # An unreadable verdict neither ends nor reopens the episode.
  parked_round "$dir" 'state: unknown · source: run-step · run inventory unavailable' quiet \
    || fail "an unreadable verdict exited the watcher"
  parked_round "$dir" "$(parked_verdict 700 1)" quiet || fail "the watcher exited on the same episode after an unreadable read"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "an unreadable read reopened the episode: $(cat "$state/.wake-queue")"

  # The run leaves the parked state (a fix round is running), then parks again.
  parked_round "$dir" 'state: working · source: run-step · validating (fixing: review)' quiet \
    || fail "the watcher exited while the run was working"
  parked_round "$dir" "$(parked_verdict 100 1)" quiet || fail "the watcher exited on a fresh episode under the threshold"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "a fresh episode woke before the threshold"
  parked_round "$dir" "$(parked_verdict 330 2)" wake \
    || fail "re-entering the parked state never produced a second wake: $(cat "$dir/watch.out")"
  [ "$(parked_wakes "$state")" -eq 1 ] || fail "expected exactly one second wake: $(cat "$state/.wake-queue")"
  grep -F 'at review, 2 findings)' "$dir/watch.out" >/dev/null \
    || fail "the second episode lost the step or finding count: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the second wake"

  # A clock that went backwards is a leave-and-return that no read observed.
  parked_round "$dir" "$(parked_verdict 305 1)" wake \
    || fail "a parked clock that restarted did not open a new episode: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the restarted-clock wake"

  # A different step is its own episode.
  parked_round "$dir" "$(parked_verdict 400 1 01RUNPARK test)" wake \
    || fail "parking at a different step did not wake: $(cat "$dir/watch.out")"
  grep -F 'at test, 1 finding)' "$dir/watch.out" >/dev/null \
    || fail "a new step was not named in the wake: $(cat "$dir/watch.out")"
  pass "leaving and re-entering parked wakes again; an unreadable read and a steady episode do not"
}

# Each non-definite read is its own case: stacking several non-working verdicts
# in one lane trips the ordinary stale path, which is not this tick.
test_a_non_definite_read_preserves_the_episode() {
  local dir state rec name verdict
  for name in timed-out no-clock other-source; do
    case "$name" in
      timed-out) verdict='state: unknown · source: none · no run attributed (run-only read)' ;;
      no-clock) verdict='state: parked · source: run-step · parked at review: 1 finding(s) · run: 01RUNPARK' ;;
      other-source) verdict='state: done · source: status-log · checks green' ;;
    esac
    dir=$(parked_case "preserve-$name"); state="$dir/state"
    parked_round "$dir" "$(parked_verdict 360 1)" wake || fail "$name: the episode never woke: $(cat "$dir/watch.out")"
    ack_stopped_cycle "$state" || fail "$name: could not acknowledge the wake"
    rec=$(cat "$state/.parked-run-$TASK")
    [ -n "$rec" ] || fail "$name: the wake left no episode record"
    parked_round "$dir" "$verdict" quiet || fail "$name: the non-definite read exited the watcher: $(cat "$dir/watch.out")"
    [ "$(cat "$state/.parked-run-$TASK")" = "$rec" ] || fail "$name: a non-definite read closed the episode record"
    parked_round "$dir" "$(parked_verdict 700 1)" quiet || fail "$name: the watcher exited on the same episode"
    [ "$(parked_wakes "$state")" -eq 0 ] || fail "$name: a non-definite read reopened the episode: $(cat "$state/.wake-queue")"
  done

  # crew-state printing nothing is the other unreadable shape. The shared fake
  # substitutes a default for an empty override, so this case replaces it.
  dir=$(parked_case preserve-empty); state="$dir/state"
  parked_round "$dir" "$(parked_verdict 360 1)" wake || fail "empty: the episode never woke: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$state" || fail "empty: could not acknowledge the wake"
  rec=$(cat "$state/.parked-run-$TASK")
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/fakebin/fm-crew-state.sh"
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  parked_round "$dir" 'unused' quiet || fail "empty: an empty read exited the watcher: $(cat "$dir/watch.out")"
  [ "$(cat "$state/.parked-run-$TASK")" = "$rec" ] || fail "empty: an empty read closed the episode record"
  make_fake_crew_state "$dir/fakebin" >/dev/null
  parked_round "$dir" "$(parked_verdict 700 1)" quiet || fail "empty: the watcher exited on the same episode"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "empty: an empty read reopened the episode: $(cat "$state/.wake-queue")"
  pass "an unreadable, timed-out, empty, or clockless read keeps the episode and does not wake again"
}

test_a_finished_or_failed_run_ends_the_episode() {
  local dir state name verdict
  for name in done failed; do
    case "$name" in
      done) verdict='state: done · source: run-step · checks green: PR ready for review' ;;
      failed) verdict='state: failed · source: run-step · run failed' ;;
    esac
    dir=$(parked_case "left-$name"); state="$dir/state"
    parked_round "$dir" "$(parked_verdict 360 1)" wake || fail "the episode never woke before $name: $(cat "$dir/watch.out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the wake before $name"
    parked_round "$dir" "$verdict" quiet || fail "a $name run read exited the watcher"
    parked_round "$dir" "$(parked_verdict 360 1)" wake \
      || fail "a $name run did not open a new episode when it parked again: $(cat "$dir/watch.out")"
    [ "$(parked_wakes "$state")" -eq 1 ] || fail "expected one new wake after the run $name: $(cat "$state/.wake-queue")"
  done
  pass "a finished or failed run ends the episode, so the next park wakes again"
}

test_postures_that_already_account_for_the_wait_stay_silent() {
  local dir state human
  human="state: parked · source: run-step · parked at review: 2 finding(s) · parked-for: 900s · ask-user: authority decision · run: 01RUNPARK"

  dir=$(parked_case captain-held 'captain-held [key=route]: tracked by task-decision-route'); state="$dir/state"
  parked_round "$dir" "$(parked_verdict 900 1)" quiet || fail "the captain-held case exited"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "a verified captain-held transfer woke on a parked run"

  dir=$(parked_case decision-open 'needs-decision [key=nm-01RUNPARK-review]: ask-user findings=r2 file=/x'); state="$dir/state"
  parked_round "$dir" "$human" quiet || fail "the open-decision case exited"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "a human-owed gate whose decision is already open with firstmate woke"

  # The same gate with the decision for a different run is not "firstmate was told".
  dir=$(parked_case decision-other-run 'needs-decision [key=nm-01OTHERRUN-review]: ask-user findings=r2 file=/x'); state="$dir/state"
  parked_round "$dir" "$human" wake || fail "a decision for another run hid a parked gate: $(cat "$dir/watch.out")"
  [ "$(parked_wakes "$state")" -eq 1 ] || fail "expected one wake for the unannounced gate"

  # A worker-owed gate is woken for even with an unrelated open decision.
  dir=$(parked_case decision-worker-owed 'needs-decision [key=nm-01RUNPARK-review]: something'); state="$dir/state"
  parked_round "$dir" "$(parked_verdict 900 1)" wake || fail "a worker-owed gate was hidden by an open decision: $(cat "$dir/watch.out")"
  pass "a captain-held transfer and a human-owed gate with its decision already open stay silent; every other parked gate wakes"
}

test_threshold_is_configurable_and_unusable_values_use_the_default() {
  local dir state
  dir=$(parked_case config-default); state="$dir/state"
  parked_round "$dir" "$(parked_verdict 200 1)" quiet || fail "the default-threshold case exited"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "a run parked 200s woke under the 300s default"

  dir=$(parked_case config-file); state="$dir/state"
  printf '120\n' > "$dir/config/parked-run-secs"
  parked_round "$dir" "$(parked_verdict 200 1)" wake || fail "config/parked-run-secs=120 did not lower the threshold: $(cat "$dir/watch.out")"

  dir=$(parked_case config-env-wins); state="$dir/state"
  printf '120\n' > "$dir/config/parked-run-secs"
  parked_round "$dir" "$(parked_verdict 200 1)" quiet FM_PARKED_RUN_SECS=600 || fail "the env override case exited"
  [ "$(parked_wakes "$state")" -eq 0 ] || fail "FM_PARKED_RUN_SECS did not outrank config/parked-run-secs"

  dir=$(parked_case config-garbage); state="$dir/state"
  printf 'soon\n' > "$dir/config/parked-run-secs"
  parked_round "$dir" "$(parked_verdict 400 1)" wake || fail "an unusable threshold silenced the tick instead of using the default"

  dir=$(parked_case config-zero); state="$dir/state"
  printf '0\n' > "$dir/config/parked-run-secs"
  parked_round "$dir" "$(parked_verdict 400 1)" wake || fail "a zero threshold silenced the tick instead of using the default"

  dir=$(parked_case config-spaced); state="$dir/state"
  printf ' 120 \t\n' > "$dir/config/parked-run-secs"
  parked_round "$dir" "$(parked_verdict 200 1)" wake || fail "surrounding config whitespace hid a valid threshold"

  dir=$(parked_case config-internal-space); state="$dir/state"
  printf '6 00\n' > "$dir/config/parked-run-secs"
  parked_round "$dir" "$(parked_verdict 400 1)" wake || fail "internal config whitespace delayed a parked-run wake"
  dir=$(parked_case env-internal-space); state="$dir/state"
  parked_round "$dir" "$(parked_verdict 400 1)" wake 'FM_PARKED_RUN_SECS=6 00' \
    || fail "internal environment whitespace delayed a parked-run wake"

  dir=$(parked_case config-overflow); state="$dir/state"
  printf '18446744073709551621\n' > "$dir/config/parked-run-secs"
  parked_round "$dir" "$(parked_verdict 200 1)" quiet || fail "an overflowing config threshold wrapped below the default"
  dir=$(parked_case env-overflow); state="$dir/state"
  parked_round "$dir" "$(parked_verdict 200 1)" quiet FM_PARKED_RUN_SECS=18446744073709551621 \
    || fail "an overflowing environment threshold wrapped below the default"
  pass "the threshold comes from the env, then config/parked-run-secs, then 300s; malformed and overflowing values use the default"
}

test_away_posture_queues_the_wake_for_the_daemon() {
  local dir state
  dir=$(parked_case afk); state="$dir/state"
  : > "$state/.afk"
  parked_round "$dir" "$(parked_verdict 420 1)" wake || fail "the parked-run wake was not queued while state/.afk exists: $(cat "$dir/watch.out")"
  [ "$(parked_wakes "$state")" -eq 1 ] || fail "expected one queued wake under away posture"
  pass "while state/.afk exists the wake is queued for the away daemon like every other"
}

test_parked_run_wakes_once_per_episode_even_under_a_declared_pause
test_parked_run_reason_reports_plural_findings_and_longer_durations
test_runs_that_are_not_parked_on_the_worker_stay_silent
test_a_task_with_no_run_or_not_a_ship_stays_silent
test_oldest_due_run_is_read_before_the_cap
test_run_only_read_skips_forge
test_leaving_and_reentering_parked_starts_a_new_episode
test_a_non_definite_read_preserves_the_episode
test_a_finished_or_failed_run_ends_the_episode
test_postures_that_already_account_for_the_wait_stay_silent
test_threshold_is_configurable_and_unusable_values_use_the_default
test_away_posture_queues_the_wake_for_the_daemon
