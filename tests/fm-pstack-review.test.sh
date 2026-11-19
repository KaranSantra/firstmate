#!/usr/bin/env bash
# Behavior tests for bin/fm-pstack-review.sh, the one-pass pstack review that
# runs beside a PR-based ship: it is off unless the home opts the project in,
# sorts a change into skip/review/tap from the project's policy file at the PR
# head, picks a reviewer of another vendor than the builder, files each
# verified finding as a captain-held backlog ticket, and never runs a second
# pass. The reviewer and the backlog command are stand-ins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-pstack-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-pstack-review)
fm_git_identity fmtest fmtest@example.invalid

# fixture <name> <harness> <model> <changed-path...>: a home, a project with a
# policy file on main, and a worker copy whose branch changes the given paths.
fixture() {
  local name=$1 harness=$2 model=$3 p
  shift 3
  HOME_DIR="$TMP_ROOT/$name/home"
  REPO="$TMP_ROOT/$name/proj"
  WT="$TMP_ROOT/$name/wt"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  fm_git_worktree "$REPO" "$WT" fm/t1
  mkdir -p "$WT/.agents"
  printf '%s\n' '{"skip": ["docs/*", "*.md"], "tap": ["src/lib/payments/*", "src/lib/auth*"]}' > "$WT/.agents/pstack-review.json"
  git -C "$WT" add .agents/pstack-review.json
  git -C "$WT" commit -qm 'policy'
  git -C "$WT" push -q origin HEAD:main
  git -C "$REPO" fetch -q origin
  for p in "$@"; do
    mkdir -p "$WT/$(dirname "$p")"
    printf 'change\n' > "$WT/$p"
    git -C "$WT" add "$p"
  done
  git -C "$WT" commit -qm 'the change'
  META="$HOME_DIR/state/t1.meta"
  fm_write_meta "$META" "worktree=$WT" "project=$REPO" kind=ship mode=direct-PR yolo=on branch=fm/t1 \
    "harness=$harness" "model=$model" "pr=https://example.invalid/pr/7"
  TASKS_LOG="$TMP_ROOT/$name/tasks.log"
  REVIEWER_LOG="$TMP_ROOT/$name/reviewer.log"
  FAKE_TASKS="$TMP_ROOT/$name/fake-tasks.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$TASKS_LOG" > "$FAKE_TASKS"
  chmod +x "$FAKE_TASKS"
  : > "$TASKS_LOG"
  : > "$REVIEWER_LOG"
}

enable() {
  printf '{"projects": ["%s"]}\n' "$(basename "$REPO")" > "$HOME_DIR/config/pstack-review.json"
}

# fake_reviewer <mode>: findings | clean | garbage
fake_reviewer() {
  FAKE_REVIEWER="$TMP_ROOT/fake-reviewer-$1.sh"
  case "$1" in
    findings) BODY='{"intent":"x","findings":[{"title":"Refund (date) off by one","severity":"high","command":"pnpm e2e r","output":"got 2","expected":"1","breaks":"wrong day"},{"title":"Second","command":"c","output":"o","expected":"e","breaks":"b"}],"dropped":1}' ;;
    clean) BODY='{"intent":"x","findings":[],"dropped":0}' ;;
    garbage) BODY='' ;;
  esac
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Expanded by the generated stand-in, not here.
    printf 'printf "%%s %%s %%s\\n" "$1" "$2" "$(pwd)" >> "$REVIEWER_LOG"\n'
    printf 'echo thinking out loud\n'
    if [ -n "$BODY" ]; then
      printf 'echo PSTACK_REVIEW_JSON_BEGIN\n'
      printf 'cat <<%s\n%s\n%s\n' "'J'" "$BODY" "J"
      printf 'echo PSTACK_REVIEW_JSON_END\n'
    fi
  } > "$FAKE_REVIEWER"
  chmod +x "$FAKE_REVIEWER"
}

run_review() {  # <cmd>; sets OUT and RC
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_PSTACK_REVIEW_TASKS_CMD="$FAKE_TASKS" FM_PSTACK_REVIEW_REVIEWER_CMD="${FAKE_REVIEWER:-}" \
    FM_PSTACK_REVIEW_ROOT="$TMP_ROOT/review-root" REVIEWER_LOG="$REVIEWER_LOG" \
    "$REVIEW" "$1" t1 2>&1)
  RC=$?
}

test_off_unless_the_project_is_listed() {
  fixture off claude claude-opus-5-5 src/app/page.tsx
  fake_reviewer clean
  run_review start
  expect_code 0 "$RC" "an unlisted project failed: $OUT"
  assert_contains "$OUT" "off for" "an unlisted project was not reported as off"
  assert_absent "$HOME_DIR/state/t1.pstack-review" "an unlisted project recorded a review"
  [ ! -s "$REVIEWER_LOG" ] || fail "an unlisted project launched a reviewer"
  pass "fm-pstack-review: does nothing unless config/pstack-review.json lists the project"
}

test_tiers_follow_the_policy_at_the_pr_head() {
  fixture tap claude claude-opus-5-5 src/lib/payments/refund.ts src/app/page.tsx
  enable
  run_review classify
  expect_code 0 "$RC" "classify failed: $OUT"
  assert_contains "$OUT" "tier=tap" "a payments path was not tap"
  fixture skip claude claude-opus-5-5 docs/guide.md README2.md
  enable
  run_review classify
  assert_contains "$OUT" "tier=skip" "a docs-only change was not skip"
  fixture review claude claude-opus-5-5 docs/guide.md src/app/page.tsx
  enable
  run_review classify
  assert_contains "$OUT" "tier=review" "a mixed change was not review"
  pass "fm-pstack-review: tap beats skip, skip needs every path, anything else is review"
}

test_skip_records_without_a_reviewer() {
  fixture skiprun pi xai/grok-4.7 docs/guide.md
  enable
  fake_reviewer findings
  run_review start
  expect_code 0 "$RC" "a skip start failed: $OUT"
  assert_grep 'status=skipped' "$HOME_DIR/state/t1.pstack-review" "a skip was not recorded"
  [ ! -s "$REVIEWER_LOG" ] || fail "a skip launched a reviewer"
  pass "fm-pstack-review: a skip tier records the skip and launches nothing"
}

test_one_pass_files_held_tickets_cross_vendor() {
  fixture findings claude claude-opus-5-5 src/app/page.tsx
  enable
  fake_reviewer findings
  run_review run
  expect_code 0 "$RC" "the review pass failed: $OUT"
  assert_grep 'status=findings' "$HOME_DIR/state/t1.pstack-review" "findings were not recorded"
  assert_grep 'tickets=rv-t1-1 rv-t1-2' "$HOME_DIR/state/t1.pstack-review" "the ticket ids were not recorded"
  assert_grep 'pi openai-codex/gpt-6-sol ' "$REVIEWER_LOG" "a Claude-built change was not reviewed by pi on OpenAI"
  assert_grep 'add rv-t1-1 Review finding: Refund date off by one --kind ship' "$TASKS_LOG" "the first ticket was not filed without parentheses"
  assert_grep 'hold rv-t1-1 --reason pstack review finding from t1, captain triage before any fix --kind captain' "$TASKS_LOG" "the first ticket was not held for the captain"
  assert_grep 'add rv-t1-2 ' "$TASKS_LOG" "the second ticket was not filed"
  [ ! -d "$TMP_ROOT/review-root/t1" ] || fail "the disposable review checkout was left behind"
  [ ! -d "$HOME_DIR/state/t1.pstack-review.lock" ] || fail "the run lock was left behind"
  run_review run
  expect_code 0 "$RC" "a second run failed: $OUT"
  assert_contains "$OUT" "already had its one pass" "a second run was not refused as already reviewed"
  [ "$(wc -l < "$REVIEWER_LOG" | tr -d ' ')" = 1 ] || fail "the reviewer ran more than once"
  pass "fm-pstack-review: one cross-vendor pass files captain-held tickets and never runs twice"
}

test_pi_builder_gets_claude_and_clean_files_nothing() {
  fixture clean pi xai/grok-4.7 src/app/page.tsx
  enable
  fake_reviewer clean
  run_review run
  expect_code 0 "$RC" "a clean pass failed: $OUT"
  assert_grep 'claude claude-sonnet-5-5 ' "$REVIEWER_LOG" "a pi/Grok-built change was not reviewed by Claude"
  assert_grep 'status=clean' "$HOME_DIR/state/t1.pstack-review" "a clean pass was not recorded"
  [ ! -s "$TASKS_LOG" ] || fail "a clean pass filed a ticket"
  pass "fm-pstack-review: a pi-built change goes to Claude, and a clean pass files nothing"
}

test_unparseable_output_is_recorded_not_retried() {
  fixture garbage claude claude-opus-5-5 src/app/page.tsx
  enable
  fake_reviewer garbage
  run_review run
  expect_code 0 "$RC" "an unparseable result failed the command: $OUT"
  assert_grep 'status=error' "$HOME_DIR/state/t1.pstack-review" "an unparseable result was not recorded as an error"
  [ ! -s "$TASKS_LOG" ] || fail "an unparseable result filed a ticket"
  run_review run
  assert_contains "$OUT" "already had its one pass" "an errored pass was retried"
  pass "fm-pstack-review: an unparseable reviewer result is recorded once and never retried"
}

test_start_runs_the_pass_detached() {
  local i=0
  fixture start pi openai-codex/gpt-6-sol src/lib/auth.ts
  enable
  fake_reviewer clean
  run_review start
  expect_code 0 "$RC" "start failed: $OUT"
  assert_contains "$OUT" "tier=tap, one pass started" "start did not report the tap tier and the started pass"
  while [ ! -f "$HOME_DIR/state/t1.pstack-review" ] && [ "$i" -lt 600 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_grep "status=clean" "$HOME_DIR/state/t1.pstack-review" "the detached pass did not record its result"
  assert_grep "claude claude-sonnet-5-5 " "$REVIEWER_LOG" "an OpenAI-built change was not reviewed by Claude"
  run_review start
  assert_contains "$OUT" "already had its one pass" "a second start was not refused"
  pass "fm-pstack-review: start runs the one pass detached, records it, and refuses a second start"
}

test_refusals() {
  fixture refuse claude claude-opus-5-5 src/app/page.tsx
  OUT=$("$REVIEW" bogus t1 2>&1); RC=$?
  expect_code 2 "$RC" "an unknown subcommand was accepted"
  OUT=$("$REVIEW" run '../x' 2>&1); RC=$?
  expect_code 2 "$RC" "an unsafe task id was accepted"
  rm -f "$META"
  run_review run
  expect_code 2 "$RC" "a missing task record was accepted"
  pass "fm-pstack-review: refuses an unknown subcommand, an unsafe id, and a missing task record"
}

test_off_unless_the_project_is_listed
test_tiers_follow_the_policy_at_the_pr_head
test_skip_records_without_a_reviewer
test_one_pass_files_held_tickets_cross_vendor
test_pi_builder_gets_claude_and_clean_files_nothing
test_unparseable_output_is_recorded_not_retried
test_start_runs_the_pass_detached
test_refusals

echo "# all fm-pstack-review tests passed"
