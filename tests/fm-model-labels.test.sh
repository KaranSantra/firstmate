#!/usr/bin/env bash
# Behavior tests for bin/fm-model-labels.sh label rendering and lookup checks,
# plus the argument order of bin/backends/herdr.sh's sidebar-label call, driven
# through a logging fake herdr so no live Herdr is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (reads the lookup file)"; exit 0; }

unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_MODEL_LABELS_FILE FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(fm_test_tmproot fm-model-labels)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
LABELS="$HOME_DIR/config/model-labels.toml"
SCRIPT="$ROOT/bin/fm-model-labels.sh"
ERR="$TMP_ROOT/stderr"
mkdir -p "$STATE_DIR" "$HOME_DIR/config"

cat > "$LABELS" <<'TOML'
# Synthetic lookup for these tests.
[meta]
schema = 1
updated = "2026-01-01"

[models."claude-opus-5"]
provider = "anthropic"
alias = "opus5"
also_recorded_as = ["opus"]   # the short name a harness records
verified = "2026-01-01"

[models."gpt-5.6-terra"]
provider = "openai"
alias = "terra5.6"
note = "example entry"

[effort.aliases]
low = "lo"
medium = "med"
high = "hi"
xhigh = "xhi"
max = "max"

[effort.accepted]
claude = ["low", "medium", "high", "xhigh", "max"]
cursor = []
TOML

label() {  # <task-id> [env assignments...] -> label on stdout, stderr in $ERR
  local id=$1
  shift
  env FM_HOME="$HOME_DIR" "$@" "$SCRIPT" label "$id" 2>"$ERR"
}

check_file() {  # <lookup-file> -> report on stdout
  FM_HOME="$HOME_DIR" FM_MODEL_LABELS_FILE="$1" "$SCRIPT" check 2>&1
}

# --- label rendering ---------------------------------------------------------

fm_write_meta "$STATE_DIR/exact.meta" harness=claude model=claude-opus-5 effort=high
out=$(label exact) || fail "exact match: label exited non-zero"
assert_equals 'claude · opus5 · hi' "$out" "exact model key renders its alias and effort alias"
pass "label: exact model key"

fm_write_meta "$STATE_DIR/also.meta" harness=claude model=opus effort=xhigh
out=$(label also) || fail "also_recorded_as: label exited non-zero"
assert_equals 'claude · opus5 · xhi' "$out" "an also_recorded_as name renders the entry's alias"
pass "label: also_recorded_as match"

fm_write_meta "$STATE_DIR/unknown.meta" harness=codex model=gpt-9-example effort=turbo
out=$(label unknown) || fail "unknown model: label exited non-zero"
assert_equals 'codex · gpt-9-example · turbo' "$out" "an unknown model and effort print their raw names"
assert_equals '' "$(cat "$ERR")" "an unknown model is not a warning"
pass "label: unknown model falls back to its raw name"

fm_write_meta "$STATE_DIR/no-effort.meta" harness=codex model=gpt-5.6-terra
out=$(label no-effort) || fail "missing effort: label exited non-zero"
assert_equals 'codex · terra5.6' "$out" "a missing effort omits that segment"
fm_write_meta "$STATE_DIR/unset-markers.meta" harness=claude model=default effort=-
out=$(label unset-markers) || fail "unset markers: label exited non-zero"
assert_equals 'claude' "$out" "default and - markers omit their segments"
pass "label: missing effort omits the segment"

out=$(label exact FM_MODEL_LABELS_FILE="$TMP_ROOT/absent.toml") || fail "absent lookup: label exited non-zero"
assert_equals 'claude · claude-opus-5 · high' "$out" "an absent lookup file falls back to raw names"
assert_equals '' "$(cat "$ERR")" "an absent lookup file is silent"
printf '[models."claude-opus-5"]\nalias = opus5\n' > "$TMP_ROOT/broken.toml"
out=$(label exact FM_MODEL_LABELS_FILE="$TMP_ROOT/broken.toml") || fail "invalid lookup: label exited non-zero"
assert_equals 'claude · claude-opus-5 · high' "$out" "an invalid lookup file falls back to raw names"
assert_equals 1 "$(grep -c '^warning:' "$ERR")" "an invalid lookup file warns exactly once"
pass "label: absent or invalid lookup never fails"

rc=0
label missing-task >/dev/null || rc=$?
expect_code 1 "$rc" "label for a task with no record"
rc=0
label ../escape >/dev/null || rc=$?
expect_code 2 "$rc" "label for a task id with a path separator"
pass "label: missing record and unsafe id are refused"

# --- check ---------------------------------------------------------------------

out=$(check_file "$LABELS") || fail "check: a valid lookup exited non-zero"$'\n'"$out"
assert_contains "$out" 'ok:' "check reports a valid lookup"
pass "check: valid lookup"

cp "$LABELS" "$TMP_ROOT/extra-key.toml"
printf '\n[models."example-model"]\nprovider = "example"\nalias = "ex1"\ncolour = "blue"\n' >> "$TMP_ROOT/extra-key.toml"
out=$(check_file "$TMP_ROOT/extra-key.toml") || fail "check: an unknown key must not fail"$'\n'"$out"
assert_contains "$out" 'warning: unknown key models."example-model".colour' "check names the unknown key"
pass "check: unknown keys warn without failing"

cp "$LABELS" "$TMP_ROOT/duplicate.toml"
printf '\n[models."claude-opus-4"]\nprovider = "anthropic"\nalias = "opus4"\nalso_recorded_as = ["opus"]\n' >> "$TMP_ROOT/duplicate.toml"
rc=0
out=$(check_file "$TMP_ROOT/duplicate.toml") || rc=$?
expect_code 1 "$rc" "check with a recorded name claimed twice"
assert_contains "$out" 'recorded name "opus" is claimed by both' "check names the ambiguous recorded name"
rc=0
out=$(check_file "$TMP_ROOT/broken.toml") || rc=$?
expect_code 1 "$rc" "check with a syntax error"
assert_contains "$out" 'error: line 2' "check names the failing line"
rc=0
check_file "$TMP_ROOT/absent.toml" >/dev/null || rc=$?
expect_code 1 "$rc" "check with no lookup file"
pass "check: invalid or absent lookup fails"

# --- Herdr sidebar-label call --------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HERDR_LOG="$TMP_ROOT/herdr.log"
: > "$HERDR_LOG"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
sep=
for a in "$@"; do printf '%s%s' "$sep" "$a"; sep=$'\x1f'; done >> "$FM_FAKE_HERDR_LOG"
printf '\n' >> "$FM_FAKE_HERDR_LOG"
exit "${FM_FAKE_HERDR_EXIT:-0}"
SH
chmod +x "$FAKEBIN/herdr"

report() {  # <session> <pane-id> <label> [env assignments...]
  local session=$1 pane=$2 text=$3
  shift 3
  # The inner script expands its own positional arguments, not this shell's.
  # shellcheck disable=SC2016
  env PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_LOG="$HERDR_LOG" FM_HOME="$HOME_DIR" "$@" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/herdr.sh"; fm_backend_herdr_report_display_agent "$1" "$2" "$3"' \
    "$ROOT" "$session" "$pane" "$text"
}

text=$(label exact) || fail "herdr call: label exited non-zero"
report fm-labels-fake 'w1:p2' "$text" || fail "herdr call: report exited non-zero"
expected=$(printf '%s\x1f' pane report-metadata 'w1:p2' --source firstmate-model-label \
  --display-agent 'claude · opus5 · hi' --session fm-labels-fake)
assert_equals "${expected%$'\x1f'}" "$(cat "$HERDR_LOG")" "the pane id precedes every option in the Herdr call"
pass "herdr: report-metadata puts the pane id before its options"

: > "$HERDR_LOG"
rc=0
report fm-labels-fake 'w1:p2' "$text" FM_FAKE_HERDR_EXIT=3 2>/dev/null || rc=$?
expect_code 3 "$rc" "a failed Herdr call returns its status to the caller"
rc=0
report fm-labels-fake 'w1:p2' '' || rc=$?
expect_code 1 "$rc" "an empty label is refused"
assert_equals 1 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "an empty label never reaches Herdr"
pass "herdr: failures surface to the best-effort caller"
