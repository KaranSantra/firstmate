#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's browser grants: --browser clean (the worker's
# own throwaway browser) and --browser work (a sealed compartment inside the
# captain's signed-in work browser), plus --chrome (his own Chrome through the
# extension, the rare exception).
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


# The two settings whose absence fails SILENTLY must reach the launched command:
# a unique session name (or two workers share one browser and read each other's
# pages) and an explicit port (or the hashed default collides across lanes and
# kills that worker's name for good).
test_browser_grant_wires_session_and_port_into_the_launch() {
  local rec id launch port
  id=browser-clean-b1
  rec=$(make_case browser-clean claude "$id")
  read_case "$rec"

  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --browser clean >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_SESSION='$id'" \
    "the launch did not pin the session name to the task id"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_PORT=" \
    "the launch did not set an explicit port"
  assert_contains "$launch" "disable-component-update" \
    "the launch did not carry the lean-profile Chrome flags"
  # A clean grant is the tool's isolated throwaway mode: its own browser, so
  # neither a persistent profile nor an attachment to the shared work browser.
  case "$launch" in
    *CHROME_DEVTOOLS_AXI_USER_DATA_DIR*) fail "a clean grant pointed at a persistent profile: $launch" ;;
  esac
  case "$launch" in
    *CHROME_DEVTOOLS_AXI_BROWSER_URL*) fail "a clean grant attached to the shared work browser: $launch" ;;
  esac
  # The allocated port must sit above the tool's 9225..10224 hashed range, which
  # is what makes a firstmate worker unable to collide with another lane.
  port=$(sed -n "s/.*CHROME_DEVTOOLS_AXI_PORT='\([0-9]*\)'.*/\1/p" "$LAUNCH_LOG")
  [ -n "$port" ] || fail "could not read the allocated port from the launch: $launch"
  [ "$port" -gt 10224 ] || fail "allocated port $port is inside the hashed range that collides across lanes"
  assert_grep "browser=clean" "$HOME_DIR/state/$id.meta" "the grant was not recorded"
  assert_grep "browser_port=$port" "$HOME_DIR/state/$id.meta" "the allocated port was not recorded"
  pass "fm-spawn.sh: a clean grant wires a unique session and an explicit out-of-range port into the launch"
}

# A work grant attaches to the running work browser and carries no profile of its
# own; the compartment inside that browser is what holds the session.
test_work_grant_refuses_without_a_work_browser() {
  local rec id out status
  id=browser-work-b2
  rec=$(make_case browser-work claude "$id")
  read_case "$rec"

  # No work browser runs in the test home, so the spawn must refuse rather than
  # launch a worker whose compartment was never created.
  status=0
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --browser work --sites example.com 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a work grant launched with no work browser running: $out"
  assert_contains "$out" "compartment" "the refusal did not name the missing compartment: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail "a failed compartment still launched a worker: $(cat "$LAUNCH_LOG")"
  pass "fm-spawn.sh: a work grant refuses rather than launching a worker with no compartment"
}

# The allowlist IS the worker's blast radius, so it must be chosen per task and
# is refused where it would mean nothing.
test_work_grant_requires_an_explicit_site_allowlist() {
  local rec id out status
  id=browser-sites-b3
  rec=$(make_case browser-sites claude "$id")
  read_case "$rec"

  status=0
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --browser work 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a work grant launched with no --sites allowlist: $out"
  assert_contains "$out" "blast radius" "the refusal did not explain why the allowlist is required: $out"

  status=0
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --browser clean --sites example.com 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "--sites was accepted on a clean grant that has no logins to scope: $out"
  pass "fm-spawn.sh: a work grant requires an explicit site allowlist and refuses it elsewhere"
}

# Two granted workers must never land on the same port.
test_two_grants_get_distinct_ports() {
  local rec first second p1 p2
  rec=$(make_case browser-two claude browser-two-c1)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" browser-two-c2

  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" browser-two-c1 "$PROJ_DIR" --browser clean >/dev/null
  first=$(cat "$LAUNCH_LOG")
  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" browser-two-c2 "$PROJ_DIR" --browser clean >/dev/null
  second=$(cat "$LAUNCH_LOG")

  p1=$(printf '%s' "$first" | sed -n "s/.*CHROME_DEVTOOLS_AXI_PORT='\([0-9]*\)'.*/\1/p")
  p2=$(printf '%s' "$second" | sed -n "s/.*CHROME_DEVTOOLS_AXI_PORT='\([0-9]*\)'.*/\1/p")
  [ -n "$p1" ] && [ -n "$p2" ] || fail "could not read both allocated ports ('$p1', '$p2')"
  [ "$p1" != "$p2" ] || fail "two browser workers were given the same port $p1; they would collide"
  pass "fm-spawn.sh: concurrent browser workers are allocated distinct ports"
}

# Each browser worker costs ~0.65GB with no economy of scale, so the count is
# capped rather than left to judgement.
test_browser_cap_refuses_beyond_the_configured_limit() {
  local rec out status
  rec=$(make_case browser-cap claude browser-cap-d1)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" browser-cap-d2
  mkdir -p "$HOME_DIR/config"
  printf '1\n' > "$HOME_DIR/config/browser-worker-cap"

  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" browser-cap-d1 "$PROJ_DIR" --browser clean >/dev/null
  status=0
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" browser-cap-d2 "$PROJ_DIR" --browser clean 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a second browser worker launched despite a cap of 1: $out"
  assert_contains "$out" "cap is 1" "the refusal did not name the cap that stopped it: $out"
  [ ! -s "$LAUNCH_LOG" ] || fail "a capped spawn still launched a worker: $(cat "$LAUNCH_LOG")"
  pass "fm-spawn.sh: the browser-worker cap refuses rather than overloading the machine"
}

# A worker with no grant must carry no browser environment at all.
test_ungranted_worker_gets_no_browser_environment() {
  local rec id launch
  id=browser-none-e1
  rec=$(make_case browser-none claude "$id")
  read_case "$rec"

  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *CHROME_DEVTOOLS_AXI*) fail "an ungranted worker was given browser environment: $launch" ;;
  esac
  if grep -q '^browser=' "$HOME_DIR/state/$id.meta"; then
    fail "an ungranted task record claimed a browser grant"
  fi
  pass "fm-spawn.sh: a worker with no grant carries no browser environment"
}

# The extension is reserved for the captain; --browser is the fleet route. One
# worker must never hold both.
test_chrome_and_browser_are_mutually_exclusive() {
  local rec id out status
  id=browser-both-f1
  rec=$(make_case browser-both claude "$id")
  read_case "$rec"
  status=0
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --browser clean --chrome 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a spawn accepted both --chrome and --browser: $out"
  assert_contains "$out" "cannot be combined" "the refusal did not explain the conflict: $out"
  pass "fm-spawn.sh: --chrome and --browser cannot be combined"
}

# A replacement worker must reattach to its own session rather than stranding the
# browser the previous one left running.
test_relaunch_preserves_the_grant_and_its_port() {
  local rec id out status meta port
  id=browser-relaunch-g1
  rec=$(make_case browser-relaunch claude "$id")
  read_case "$rec"

  run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --browser clean >/dev/null
  meta="$HOME_DIR/state/$id.meta"
  port=$(sed -n 's/^browser_port=//p' "$meta")
  [ -n "$port" ] || fail "no port was recorded to preserve"

  status=0
  out=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --browser clean 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a relaunch accepted a contradicting --browser: $out"
  assert_contains "$out" "--browser cannot override it" \
    "the relaunch refusal did not name the recorded grant: $out"
  pass "fm-spawn.sh: a relaunch reuses the recorded grant and port instead of re-deciding them"
}

test_chrome_flag_reaches_the_claude_launch
test_default_spawn_closes_the_browser_explicitly
test_grant_is_recorded_and_not_overridable_on_relaunch
test_ordinary_task_record_keeps_no_chrome_line
test_non_claude_harness_refuses_the_grant
test_browser_grant_wires_session_and_port_into_the_launch
test_work_grant_refuses_without_a_work_browser
test_work_grant_requires_an_explicit_site_allowlist
test_two_grants_get_distinct_ports
test_browser_cap_refuses_beyond_the_configured_limit
test_ungranted_worker_gets_no_browser_environment
test_chrome_and_browser_are_mutually_exclusive
test_relaunch_preserves_the_grant_and_its_port
printf '%s\n' "# all fm-spawn-chrome tests passed"
