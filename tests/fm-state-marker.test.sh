#!/usr/bin/env bash
# Behavior tests for bin/fm-state-marker.sh: which pipeline states earn a
# sidebar marker, the cadence that keeps the state read off every wake, and the
# clearing that stops a row claiming a lane is in review once it is not.
# A logging fake herdr and a scripted fake crew-state stand in, so no live Herdr
# and no validation daemon are touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (reads the lookup file)"; exit 0; }

unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_MODEL_LABELS_FILE
unset FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(fm_test_tmproot fm-state-marker)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
SCRIPT="$ROOT/bin/fm-state-marker.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HERDR_LOG="$TMP_ROOT/herdr.log"
CREW_LOG="$TMP_ROOT/crew.log"
CREW_BIN="$TMP_ROOT/fake-crew-state.sh"
LINE_FILE="$TMP_ROOT/crew-line"
mkdir -p "$STATE_DIR" "$HOME_DIR/config" "$HOME_DIR/data"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
sep=
for a in "$@"; do printf '%s%s' "$sep" "$a"; sep=$'\x1f'; done >> "$FM_FAKE_HERDR_LOG"
printf '\n' >> "$FM_FAKE_HERDR_LOG"
exit "${FM_FAKE_HERDR_EXIT:-0}"
SH
chmod +x "$FAKEBIN/herdr"

# Stands in for bin/fm-crew-state.sh, whose real read may make bounded
# no-mistakes calls. Every invocation is logged so a test can prove the cadence
# actually suppressed a read rather than merely producing the same answer.
cat > "$CREW_BIN" <<'SH'
#!/usr/bin/env bash
printf '%s state=%s home=%s\n' "$1" "${FM_STATE_OVERRIDE:-unset}" "${FM_HOME:-unset}" \
  >> "$FM_FAKE_CREW_LOG"
sleep "${FM_FAKE_CREW_DELAY:-0}"
cat "$FM_FAKE_CREW_LINE"
SH
chmod +x "$CREW_BIN"

joined() {  # <args...> -> unit-separated, matching the fake's log line
  local out
  out=$(printf '%s\x1f' "$@")
  printf '%s' "${out%$'\x1f'}"
}

say() {  # <crew-state line>
  printf '%s\n' "$1" > "$LINE_FILE"
}

marker_run() {  # <subcommand> <id> [env assignments...]
  local sub=$1 id=$2
  shift 2
  env PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" FM_FAKE_CREW_LOG="$CREW_LOG" FM_FAKE_CREW_LINE="$LINE_FILE" \
    FM_STATE_MARKER_CREW_STATE_BIN="$CREW_BIN" \
    FM_STATE_MARKER_LABELS_BIN="$ROOT/bin/fm-model-labels.sh" \
    "$@" "$SCRIPT" "$sub" "$id"
}

reset_logs() {
  : > "$HERDR_LOG"
  : > "$CREW_LOG"
}

herdr_calls() {
  grep -c . < "$HERDR_LOG" | tr -d ' '
}

crew_calls() {
  grep -c . < "$CREW_LOG" | tr -d ' '
}

fm_write_meta "$STATE_DIR/t.meta" window=fm:fm-t backend=herdr herdr_session=s1 \
  herdr_pane_id=w1:p1 kind=ship
fm_write_meta "$STATE_DIR/tmux-task.meta" window=fm:fm-tmux kind=ship
fm_write_meta "$STATE_DIR/local-secondmate.meta" window=fm:fm-local-secondmate backend=herdr herdr_session=s2 \
  herdr_pane_id=w2:p2 kind=secondmate
fm_write_meta "$STATE_DIR/remote.meta" window=fm:fm-remote backend=herdr herdr_session=s9 \
  herdr_pane_id=w9:p9 remote_host=example-host kind=secondmate

# --- which states earn a marker ----------------------------------------------

# The captain's own ask: a lane sitting with the reviewer must be readable from
# the row, and must be distinguishable from one running tests or writing docs.
for pair in \
  "validating (running: review)=◆cx" \
  "validating (running: test)=◉ts" \
  "validating (running: document)=◎dc" \
  "validating (running: push)=▲ps" \
  "validating (fixing: review)=◈fx" \
  "ci running=◌ci"; do
  detail=${pair%=*}
  want=${pair#*=}
  say "state: working · source: run-step · $detail"
  assert_equals "$want" "$(marker_run state t)" "\"$detail\" shows its own marker"
done
say 'state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision)'
assert_equals "◍?" "$(marker_run state t)" "a lane held for an answer shows the decision marker"
pass "state: each pipeline step the captain named reads differently"

# Anything that is not a live pipeline step shows NOTHING. A pane-derived or
# log-derived verdict says the worker is busy, not which step owns it, and
# marking those is exactly the stale claim this marker exists to avoid.
for line in \
  'state: working · source: pane · pane busy' \
  'state: working · source: status-log · working: still going' \
  'state: done · source: run-step · run passed: PR merged/closed' \
  'state: done · source: run-step · checks green: PR ready for review' \
  'state: failed · source: run-step · run failed' \
  'state: paused · source: status-log · paused: waiting on a release' \
  'state: unknown · source: none · no metadata for t' \
  'state: working · source: run-step · validating (running)' \
  'garbage that is not a state line at all'; do
  say "$line"
  assert_equals "" "$(marker_run state t)" "no marker for: $line"
done
pass "state: anything but a live pipeline step shows nothing at all"

# --- publishing, change gating, and cadence ----------------------------------

reset_logs
rm -f "$STATE_DIR/t.state-marker"
say 'state: working · source: run-step · validating (running: review)'
marker_run update t
assert_equals "$(joined pane report-metadata w1:p1 --source firstmate-state-marker \
  --token 'st=◆cx' --session s1)" "$(sed -n 1p "$HERDR_LOG")" \
  "the first update publishes the marker under its own source"
assert_equals 1 "$(herdr_calls)" "one publish, not more"
pass "update: a new marker reaches the row"

# The same state again must not re-publish: the watcher calls this every poll.
reset_logs
marker_run update t FM_STATE_MARKER_INTERVAL=0
assert_equals 1 "$(crew_calls)" "state was read again once the interval elapsed"
assert_equals 0 "$(herdr_calls)" "an unchanged marker makes no Herdr call"
pass "update: an unchanged marker is not republished"

# The cadence, not the caller, bounds the cost: bin/fm-classify-lib.sh forbids
# reading crew state on every wake, so a call inside the interval must not read.
reset_logs
marker_run update t FM_STATE_MARKER_INTERVAL=3600
assert_equals 0 "$(crew_calls)" "no state read inside the interval"
assert_equals 0 "$(herdr_calls)" "and therefore no Herdr call either"
pass "update: the interval suppresses the state read the cost guard warns about"

reset_logs
rm -f "$STATE_DIR/t.state-marker"
say 'state: working · source: run-step · validating (running: review)'
marker_run update t FM_STATE_MARKER_INTERVAL=3600 FM_FAKE_CREW_DELAY=1 &
slow_update=$!
i=0
while [ "$(crew_calls)" -lt 1 ]; do
  [ "$i" -lt 30 ] || fail "the first marker update never began its state read"
  sleep 0.1
  i=$((i + 1))
done
marker_run update t FM_STATE_MARKER_INTERVAL=3600
wait "$slow_update" || fail "the first marker update failed"
assert_equals 1 "$(crew_calls)" "concurrent updates make one state read per interval"
assert_equals 1 "$(herdr_calls)" "concurrent updates publish one marker"
pass "update: concurrent refreshes preserve the per-task cadence"

# A changed step repaints the row.
reset_logs
say 'state: working · source: run-step · validating (running: test)'
marker_run update t FM_STATE_MARKER_INTERVAL=0
assert_equals "$(joined pane report-metadata w1:p1 --source firstmate-state-marker \
  --token 'st=◉ts' --session s1)" "$(sed -n 1p "$HERDR_LOG")" \
  "a changed step publishes the new marker"
pass "update: a state change repaints the row"

# The staleness property that matters most: once the run ends, the row must stop
# claiming the lane is with the reviewer.
reset_logs
say 'state: done · source: run-step · checks green: PR ready for review'
marker_run update t FM_STATE_MARKER_INTERVAL=0
assert_equals "$(joined pane report-metadata w1:p1 --source firstmate-state-marker \
  --clear-token st --session s1)" "$(sed -n 1p "$HERDR_LOG")" \
  "a finished run clears the marker instead of leaving it"
pass "update: a finished run clears the marker"

reset_logs
marker_run update t FM_STATE_MARKER_INTERVAL=0
assert_equals 0 "$(herdr_calls)" "an already-clear row is not cleared again"
pass "update: clearing is not repeated once the row is clear"

# --- clear -------------------------------------------------------------------

reset_logs
say 'state: working · source: run-step · validating (running: review)'
marker_run update t FM_STATE_MARKER_INTERVAL=0 >/dev/null
[ -f "$STATE_DIR/t.state-marker" ] || fail "update did not record what it showed"
reset_logs
marker_run clear t
assert_equals "$(joined pane report-metadata w1:p1 --source firstmate-state-marker \
  --clear-token st --session s1)" "$(sed -n 1p "$HERDR_LOG")" "clear retires the marker"
[ -f "$STATE_DIR/t.state-marker" ] && fail "clear left its record behind"
pass "clear: the marker and its record are both retired"

reset_logs
say 'state: working · source: run-step · validating (running: review)'
marker_run update t FM_STATE_MARKER_INTERVAL=0 FM_FAKE_CREW_DELAY=1 &
stale_update=$!
i=0
while [ "$(crew_calls)" -lt 1 ]; do
  [ "$i" -lt 30 ] || fail "the stale refresh never began its state read"
  sleep 0.1
  i=$((i + 1))
done
fm_write_meta "$STATE_DIR/t.meta" window=fm:fm-t backend=herdr herdr_session=s3 \
  herdr_pane_id=w3:p3 kind=ship
marker_run clear t &
clear_after_relaunch=$!
sleep 0.1
kill -0 "$clear_after_relaunch" 2>/dev/null || fail "clear did not wait for the in-flight refresh"
wait "$stale_update" || fail "the stale refresh failed"
wait "$clear_after_relaunch" || fail "clear after relaunch failed"
assert_equals "$(joined pane report-metadata w3:p3 --source firstmate-state-marker \
  --clear-token st --session s3)" "$(tail -n 1 "$HERDR_LOG")" \
  "the replacement row is cleared after the stale refresh completes"
[ ! -e "$STATE_DIR/t.state-marker" ] || fail "clear after relaunch left a marker record behind"
fm_write_meta "$STATE_DIR/t.meta" window=fm:fm-t backend=herdr herdr_session=s1 \
  herdr_pane_id=w1:p1 kind=ship
pass "clear: a stale refresh cannot repaint a relaunched row"

# --- quiet degradation -------------------------------------------------------

# No other runtime has this sidebar, so a non-herdr task must never reach Herdr -
# and must not pay for a pipeline state read either, since there is no row for
# the answer to land on.
reset_logs
say 'state: working · source: run-step · validating (running: review)'
marker_run update tmux-task FM_STATE_MARKER_INTERVAL=0
assert_equals 0 "$(herdr_calls)" "a tmux-backed task makes no Herdr call"
assert_equals 0 "$(crew_calls)" "a tmux-backed task does not even read pipeline state"
pass "degrade: a non-herdr backend is a silent no-op"

# A remote secondmate's state read crosses SSH, and its row is not on this
# machine at all, so it must be excluded before any read is attempted.
reset_logs
marker_run update remote FM_STATE_MARKER_INTERVAL=0
assert_equals 0 "$(crew_calls)" "a remote task's state is never read for a marker"
assert_equals 0 "$(herdr_calls)" "a remote task makes no local Herdr call"
pass "degrade: a remote task never pays for a marker it cannot show"

reset_logs
say 'state: working · source: run-step · validating (running: review)'
marker_run update local-secondmate FM_STATE_MARKER_INTERVAL=0
assert_equals 1 "$(crew_calls)" "a local secondmate reads its pipeline state"
assert_equals "$(joined pane report-metadata w2:p2 --source firstmate-state-marker \
  --token 'st=◆cx' --session s2)" "$(sed -n 1p "$HERDR_LOG")" \
  "a local secondmate publishes its marker to its own row"
pass "degrade: a local secondmate receives its lane marker"

# An unknown task is a no-op, not an error.
reset_logs
rc=0
marker_run update no-such-task FM_STATE_MARKER_INTERVAL=0 || rc=$?
expect_code 0 "$rc" "an unknown task is not an error"
assert_equals 0 "$(herdr_calls)" "an unknown task makes no Herdr call"
pass "degrade: an unknown task is a quiet no-op"

# A Herdr that refuses the call - an older one without the flag, or none at all -
# must leave the row alone and stay silent, because the marker is cosmetic.
reset_logs
rm -f "$STATE_DIR/t.state-marker"
say 'state: working · source: run-step · validating (running: review)'
err="$TMP_ROOT/err"
rc=0
marker_run update t FM_STATE_MARKER_INTERVAL=0 FM_FAKE_HERDR_EXIT=2 2>"$err" || rc=$?
expect_code 0 "$rc" "a refused Herdr call never fails the caller"
assert_equals "" "$(cat "$err")" "a refused Herdr call prints no noise"
pass "degrade: a Herdr that refuses the call is silent and harmless"

# A refusal must not be retried on the very next poll either, or a fleet with an
# old Herdr would call it once per task per poll forever.
reset_logs
marker_run update t FM_STATE_MARKER_INTERVAL=3600 >/dev/null 2>&1
assert_equals 0 "$(herdr_calls)" "the refusal is not retried inside the interval"
pass "degrade: a refused call is not retried every poll"

# ...but it IS retried once the interval elapses, so a row recovers on its own
# when Herdr comes back, instead of staying blank until the state next changes.
reset_logs
marker_run update t FM_STATE_MARKER_INTERVAL=0
assert_equals "$(joined pane report-metadata w1:p1 --source firstmate-state-marker \
  --token 'st=◆cx' --session s1)" "$(sed -n 1p "$HERDR_LOG")" \
  "the marker Herdr refused is published once Herdr accepts it again"
pass "degrade: a recovered Herdr gets the marker without a state change"

# --- home routing ------------------------------------------------------------

# A secondmate home reads its own records, so the home and state directory this
# script resolved must reach the state reader rather than leaking the ambient
# ones. Without this the marker would read another home's tasks entirely.
reset_logs
rm -f "$STATE_DIR/t.state-marker"
say 'state: working · source: run-step · validating (running: review)'
marker_run update t FM_STATE_MARKER_INTERVAL=0 >/dev/null 2>&1
assert_contains "$(cat "$CREW_LOG")" "state=$STATE_DIR" \
  "the state directory is passed down to the state reader"
assert_contains "$(cat "$CREW_LOG")" "home=$HOME_DIR" \
  "the home is passed down to the state reader"
pass "routing: the resolved home and state reach the state reader"

# --- argument safety ---------------------------------------------------------

rc=0
marker_run update "../escape" 2>/dev/null || rc=$?
expect_code 2 "$rc" "a path-shaped task id is refused"
rc=0
env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$SCRIPT" 2>/dev/null || rc=$?
expect_code 2 "$rc" "no subcommand is a usage error"
pass "arguments: unsafe ids and missing subcommands are refused"

echo "all fm-state-marker tests passed"
