#!/usr/bin/env bash
# Behavior tests for bin/fm-model-labels.sh label rendering and lookup checks,
# plus the argument order of bin/backends/herdr.sh's sidebar-label and
# worker-space-marker calls, driven through a logging fake herdr so no live
# Herdr is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (reads the lookup file)"; exit 0; }

unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_MODEL_LABELS_FILE FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(fm_test_tmproot fm-model-labels)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
LABELS="$HOME_DIR/config/model-labels.toml"
SCRIPT="$ROOT/bin/fm-model-labels.sh"
ERR="$TMP_ROOT/stderr"
mkdir -p "$STATE_DIR" "$HOME_DIR/config" "$HOME_DIR/data"

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
alias = "terra5.6"
note = "example entry"

[effort.aliases]
low = "lo"
medium = "med"
high = "hi"
xhigh = "xhi"
max = "max"
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

fm_write_meta "$STATE_DIR/unknown.meta" harness=codex model=gpt-9-example effort=ultra
out=$(label unknown) || fail "unknown model: label exited non-zero"
assert_equals 'codex · gpt-9-example · ultra' "$out" "a model and effort word with no alias print their raw names"
assert_equals '' "$(cat "$ERR")" "a missing alias is not a warning"
pass "label: missing aliases fall back to raw names"

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
assert_not_contains "$out" 'warning:' "a valid aliases-only lookup has no warnings"
pass "check: valid lookup"

cp "$LABELS" "$TMP_ROOT/effort-words.toml"
printf 'ultra = "ult"\nturbo = "tb"\n' >> "$TMP_ROOT/effort-words.toml"
printf '\n[effort.accepted]\nclaude = ["low"]\n' >> "$TMP_ROOT/effort-words.toml"
out=$(check_file "$TMP_ROOT/effort-words.toml") || fail "check: effort words must never fail"$'\n'"$out"
assert_not_contains "$out" 'effort level' "check never validates an effort word"
assert_contains "$out" 'warning: unknown key effort.accepted' "a leftover accepted-levels block is only an unknown key"
pass "check: effort words are aliases only, never validated"

cp "$LABELS" "$TMP_ROOT/extra-key.toml"
printf '\n[models."example-model"]\nalias = "ex1"\ncolour = "blue"\n' >> "$TMP_ROOT/extra-key.toml"
out=$(check_file "$TMP_ROOT/extra-key.toml") || fail "check: an unknown key must not fail"$'\n'"$out"
assert_contains "$out" 'warning: unknown key models."example-model".colour' "check names the unknown key"
pass "check: unknown keys warn without failing"

cat > "$HOME_DIR/data/model-effort-catalog.md" <<'MD'
# Synthetic catalog
| Model | Effort levels it accepts |
|---|---|
| `gpt-5.6-terra` | low · medium |
| `gpt-9-example` | low · ultra |
- `claude-opus-5`
- `claude-example-9`
Prose that mentions `not-a-model` stays out of the report.
MD
out=$(check_file "$LABELS") || fail "check: the catalog report must not fail"$'\n'"$out"
assert_contains "$out" 'info: catalog model gpt-9-example has no alias' "check reports an unaliased catalog table row"
assert_contains "$out" 'info: catalog model claude-example-9 has no alias' "check reports an unaliased catalog list item"
assert_not_contains "$out" 'catalog model gpt-5.6-terra' "an aliased catalog model is not reported"
assert_not_contains "$out" 'not-a-model' "catalog prose is not read as a model"
rm "$HOME_DIR/data/model-effort-catalog.md"
pass "check: catalog models without an alias are information only"

cp "$LABELS" "$TMP_ROOT/duplicate.toml"
printf '\n[models."claude-opus-4"]\nalias = "opus4"\nalso_recorded_as = ["opus"]\n' >> "$TMP_ROOT/duplicate.toml"
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

# --- Herdr sidebar-label and worker-space-marker calls -------------------------

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

herdr_backend() {  # <function> <args...> [-- env assignments...] via the logging fake
  local -a args=() envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "$#" -eq 0 ] || { shift; envs=("$@"); }
  # The inner script expands its own positional arguments, not this shell's.
  # shellcheck disable=SC2016
  env PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_LOG="$HERDR_LOG" FM_HOME="$HOME_DIR" ${envs[@]+"${envs[@]}"} \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/herdr.sh"; "$@"' "$ROOT" "${args[@]}"
}

joined() {  # <args...> -> unit-separated, matching the fake's log line
  local out
  out=$(printf '%s\x1f' "$@")
  printf '%s' "${out%$'\x1f'}"
}

text=$(label exact) || fail "herdr call: label exited non-zero"
herdr_backend fm_backend_herdr_report_display_agent fm-labels-fake 'w1:p2' "$text" || fail "herdr call: label report exited non-zero"
herdr_backend fm_backend_herdr_report_worker_mark fm-labels-fake w7 || fail "herdr call: worker mark exited non-zero"
assert_equals "$(joined pane report-metadata 'w1:p2' --source firstmate-model-label \
  --display-agent 'claude · opus5 · hi' --session fm-labels-fake)" "$(sed -n 1p "$HERDR_LOG")" \
  "the pane id precedes every option in the label call"
assert_equals "$(joined workspace report-metadata w7 --source firstmate-worker-mark \
  --token 'wt=●' --session fm-labels-fake)" "$(sed -n 2p "$HERDR_LOG")" \
  "the workspace id precedes every option in the worker-mark call"
pass "herdr: pane and workspace ids come before their options"

: > "$HERDR_LOG"
rc=0
herdr_backend fm_backend_herdr_report_display_agent fm-labels-fake 'w1:p2' "$text" -- FM_FAKE_HERDR_EXIT=3 2>/dev/null || rc=$?
expect_code 3 "$rc" "a failed label call returns its status to the caller"
rc=0
herdr_backend fm_backend_herdr_report_worker_mark fm-labels-fake w7 -- FM_FAKE_HERDR_EXIT=4 2>/dev/null || rc=$?
expect_code 4 "$rc" "a failed worker-mark call returns its status to the caller"
rc=0
herdr_backend fm_backend_herdr_report_display_agent fm-labels-fake 'w1:p2' '' || rc=$?
expect_code 1 "$rc" "an empty label is refused"
rc=0
herdr_backend fm_backend_herdr_report_worker_mark fm-labels-fake '' || rc=$?
expect_code 1 "$rc" "an empty workspace id is refused"
assert_equals 2 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "refused calls never reach Herdr"
pass "herdr: failures surface to the best-effort caller"
