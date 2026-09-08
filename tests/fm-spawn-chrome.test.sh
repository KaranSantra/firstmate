#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's --chrome browser grant.
#
# A worker's access to the captain's real, signed-in Chrome is a property of how
# it was launched, not of brief prose it can overlook. Claude Code's own default
# is neither fixed nor uniform - interactively it follows the home's
# claudeInChromeDefaultEnabled config and in print mode it is off (matrix in
# docs/verification/runtime-backends.md) - so fm-spawn always emits a direction.
# These tests drive the real script with a fake tmux pane that captures the
# literal launch command, so they assert the command firstmate would run rather
# than the source that builds it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-chrome)

make_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_ship() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR="" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

# The two directions must actually differ in the launched command, and the
# default must be the closed one. Asserting both halves keeps the case from
# going vacuous if one direction silently stops being emitted.
test_chrome_flag_reaches_the_claude_launch() {
  local rec id out status launch
  id=chrome-grant-a1
  rec=$(make_case chrome-grant claude "$id")
  read_case "$rec"

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --chrome)
  status=$?
  expect_code 0 "$status" "claude spawn with --chrome should succeed"
  assert_contains "$out" "chrome=on" "spawn success line did not report the browser grant"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" " --chrome " "granted launch did not carry claude's --chrome"
  case "$launch" in
    *--no-chrome*) fail "granted launch also carried --no-chrome: $launch" ;;
  esac
  pass "fm-spawn.sh: --chrome grants the captain's browser on the claude launch"
}

test_default_spawn_closes_the_browser_explicitly() {
  local rec id out status launch
  id=chrome-default-a2
  rec=$(make_case chrome-default claude "$id")
  read_case "$rec"

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without --chrome should succeed"
  case "$out" in
    *chrome=on*) fail "default spawn reported a browser grant it was never given: $out" ;;
  esac
  launch=$(cat "$LAUNCH_LOG")
  # Explicit, not merely absent: a bare launch would inherit the machine's own
  # claudeInChromeDefaultEnabled setting instead of this dispatch decision.
  assert_contains "$launch" " --no-chrome " "default launch did not explicitly close the browser"
  pass "fm-spawn.sh: a default spawn closes the browser explicitly rather than inheriting machine config"
}

# The grant is recorded so a replacement worker keeps the browser its task was
# dispatched with, and a relaunch refuses a contradicting flag exactly as it
# does for --mode and --yolo.
test_grant_is_recorded_and_not_overridable_on_relaunch() {
  local rec id out status meta
  id=chrome-meta-a3
  rec=$(make_case chrome-meta claude "$id")
  read_case "$rec"

  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --chrome >/dev/null
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "chrome=on" "$meta" "the browser grant was not recorded in the task record"

  out=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --chrome 2>&1) || status=$?
  assert_contains "$out" "--chrome cannot override it" \
    "a relaunch accepted a contradicting --chrome instead of reusing the recorded grant"
  pass "fm-spawn.sh: the browser grant is recorded and a relaunch reuses rather than re-decides it"
}

test_ordinary_task_record_keeps_no_chrome_line() {
  local rec id meta
  id=chrome-absent-a4
  rec=$(make_case chrome-absent claude "$id")
  read_case "$rec"

  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null
  meta="$HOME_DIR/state/$id.meta"
  # Absence is the record for an ordinary task, so every task recorded before
  # this flag existed still reads as "no browser" on relaunch.
  if grep -q '^chrome=' "$meta"; then
    fail "an ordinary task record grew a chrome= line: $(grep '^chrome=' "$meta")"
  fi
  pass "fm-spawn.sh: an ordinary task record carries no chrome= line"
}

# Only claude speaks the claude-in-chrome extension, so any other harness must
# refuse rather than launch a worker whose brief promises a browser it cannot open.
test_non_claude_harness_refuses_the_grant() {
  local rec id out status
  id=chrome-wrong-harness-a5
  rec=$(make_case chrome-wrong-harness codex "$id")
  read_case "$rec"

  status=0
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --chrome 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "codex spawn accepted --chrome instead of refusing it: $out"
  assert_contains "$out" "only the claude harness speaks" \
    "the refusal did not name the claude-only extension boundary: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused --chrome spawn still launched a worker: $(cat "$LAUNCH_LOG")"
  pass "fm-spawn.sh: a non-claude harness refuses --chrome instead of launching a browserless worker"
}

test_chrome_flag_reaches_the_claude_launch
test_default_spawn_closes_the_browser_explicitly
test_grant_is_recorded_and_not_overridable_on_relaunch
test_ordinary_task_record_keeps_no_chrome_line
test_non_claude_harness_refuses_the_grant
printf '%s\n' "# all fm-spawn-chrome tests passed"
