#!/usr/bin/env bash
# Behavior tests for bin/fm-model-labels.sh label rendering, pipeline-state
# marker lookup, and lookup checks, plus the argument order of
# bin/backends/herdr.sh's sidebar-label, worker-space-marker, and
# state-marker calls, driven through a logging fake herdr so no live Herdr is
# touched.
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
assert_equals 'codex · gpt-9-example · ultra' "$out" "an unprefixed model and effort word with no alias print their recorded names"
assert_equals '' "$(cat "$ERR")" "a missing alias is not a warning"
pass "label: missing aliases fall back to recorded names"

# The label already names the runtime, so an unaliased model never repeats it:
# the reported symptom was "claude · claude-opus-5-5 · high".
fm_write_meta "$STATE_DIR/harness-prefix.meta" harness=claude model=claude-opus-5-5 effort=high
out=$(label harness-prefix) || fail "harness prefix: label exited non-zero"
assert_equals 'claude · opus-5-5 · hi' "$out" "a leading harness prefix is dropped from an unaliased model"
fm_write_meta "$STATE_DIR/provider-path.meta" harness=pi model=anthropic/claude-opus-5-5 effort=high
out=$(label provider-path) || fail "provider path: label exited non-zero"
assert_equals 'pi · claude-opus-5-5 · hi' "$out" "a leading provider path is dropped, keeping a name that is not the runtime"
fm_write_meta "$STATE_DIR/provider-and-harness.meta" harness=claude model=anthropic/claude-opus-5-5
out=$(label provider-and-harness) || fail "provider and harness: label exited non-zero"
assert_equals 'claude · opus-5-5' "$out" "a provider path and a harness prefix are both dropped"
fm_write_meta "$STATE_DIR/bare-harness.meta" harness=codex model=codex
out=$(label bare-harness) || fail "bare harness model: label exited non-zero"
assert_equals 'codex · codex' "$out" "a model named only for its harness is kept whole"
fm_write_meta "$STATE_DIR/aliased-prefix.meta" harness=claude model=claude-opus-5 effort=high
out=$(label aliased-prefix) || fail "aliased prefixed model: label exited non-zero"
assert_equals 'claude · opus5 · hi' "$out" "an alias wins over the prefix-stripped name"
assert_equals '' "$(cat "$ERR")" "prefix stripping is not a warning"
pass "label: an unaliased model never repeats its provider or harness"

fm_write_meta "$STATE_DIR/no-effort.meta" harness=codex model=gpt-5.6-terra
out=$(label no-effort) || fail "missing effort: label exited non-zero"
assert_equals 'codex · terra5.6' "$out" "a missing effort omits that segment"
fm_write_meta "$STATE_DIR/unset-markers.meta" harness=claude model=default effort=-
out=$(label unset-markers) || fail "unset markers: label exited non-zero"
assert_equals 'claude' "$out" "default and - markers omit their segments"
pass "label: missing effort omits the segment"

out=$(label exact FM_MODEL_LABELS_FILE="$TMP_ROOT/absent.toml") || fail "absent lookup: label exited non-zero"
assert_equals 'claude · opus-5 · high' "$out" "an absent lookup file falls back to unaliased names"
assert_equals '' "$(cat "$ERR")" "an absent lookup file is silent"
printf '[models."claude-opus-5"]\nalias = opus5\n' > "$TMP_ROOT/broken.toml"
out=$(label exact FM_MODEL_LABELS_FILE="$TMP_ROOT/broken.toml") || fail "invalid lookup: label exited non-zero"
assert_equals 'claude · opus-5 · high' "$out" "an invalid lookup file falls back to unaliased names"
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

# --- pipeline-state markers --------------------------------------------------

marker() {  # <state key> [env assignments...] -> marker on stdout, stderr in $ERR
  local key=$1
  shift
  env FM_HOME="$HOME_DIR" "$@" "$SCRIPT" marker "$key" 2>"$ERR"
}

# The shipped default means the review marker works before the captain has
# written a single line of lookup: this file has no [states] table at all.
assert_equals "rvx" "$(marker review)" "review shows the reviewer's default marker"
pass "marker: the shipped review default renders with no lookup entry"

# Only the review ships a marker; every other state stays bare until the
# lookup gives it one.
for key in intent test lint document push pr ci fix decision; do
  assert_equals "" "$(marker "$key")" "$key shows nothing by default"
done
pass "marker: every state but the review is unmarked by default"

# Nothing at all for a state this release does not mark - never a placeholder.
assert_equals "" "$(marker nosuchstate)" "an unmarked state shows nothing"
pass "marker: an unknown state shows nothing rather than a placeholder"

STATES_OK="$TMP_ROOT/states-ok.toml"
cat > "$STATES_OK" <<'TOML'
[meta]
schema = 1

[states.glyphs]
review = "rvc"
test = "◉ts"
TOML
assert_equals "rvc" "$(marker review FM_MODEL_LABELS_FILE="$STATES_OK")" \
  "a configured glyph replaces the default"
assert_equals "◉ts" "$(marker test FM_MODEL_LABELS_FILE="$STATES_OK")" \
  "a configured glyph marks a state that has no default"
assert_equals "" "$(marker ci FM_MODEL_LABELS_FILE="$STATES_OK")" \
  "an unconfigured state stays unmarked"
pass "marker: the lookup overrides a glyph without a code change"

assert_contains "$(check_file "$STATES_OK")" "ok:" "a valid states table checks clean"
pass "marker: check accepts a valid states table"

# A malformed lookup is LOUD here: the marker is the captain's own surface, so a
# typo must be visible rather than quietly showing him the wrong symbol.
STATES_BAD="$TMP_ROOT/states-bad.toml"
printf '[states.glyphs\nreview = "x"\n' > "$STATES_BAD"
rc=0
out=$(marker review FM_MODEL_LABELS_FILE="$STATES_BAD") || rc=$?
expect_code 1 "$rc" "an unparseable lookup fails the marker instead of falling back"
assert_equals "" "$out" "a failed marker prints nothing on stdout"
assert_contains "$(cat "$ERR")" "could not be read" "the marker says why it showed nothing"
pass "marker: an unparseable lookup fails loudly"

# Horizontal space is the whole constraint, so an over-long glyph is an error,
# not a silently truncated or silently accepted value.
STATES_LONG="$TMP_ROOT/states-long.toml"
cat > "$STATES_LONG" <<'TOML'
[meta]
schema = 1

[states.glyphs]
review = "codex reviewing"
TOML
rc=0
out=$(marker review FM_MODEL_LABELS_FILE="$STATES_LONG") || rc=$?
expect_code 1 "$rc" "an over-long glyph fails the marker"
assert_equals "" "$out" "an over-long glyph shows nothing"
assert_contains "$(check_file "$STATES_LONG")" "at most 3 characters" \
  "check names the horizontal-space limit it enforced"
pass "marker: an over-long glyph is refused with the reason"

STATES_LETTERS="$TMP_ROOT/states-letters.toml"
cat > "$STATES_LETTERS" <<'TOML'
[meta]
schema = 1

[states.glyphs]
review = "abc"
TOML
assert_equals "abc" "$(marker review FM_MODEL_LABELS_FILE="$STATES_LETTERS")" \
  "an all-letter glyph within the limit is shown"
assert_contains "$(check_file "$STATES_LETTERS")" "ok:" "an all-letter glyph checks clean"
pass "marker: letters are allowed in a glyph"

STATES_BLANK="$TMP_ROOT/states-blank.toml"
cat > "$STATES_BLANK" <<'TOML'
[meta]
schema = 1

[states.glyphs]
review = "  "
TOML
rc=0
out=$(marker review FM_MODEL_LABELS_FILE="$STATES_BLANK") || rc=$?
expect_code 1 "$rc" "a blank glyph fails the marker"
assert_equals "" "$out" "a blank glyph shows nothing"
assert_contains "$(check_file "$STATES_BLANK")" "must be a non-empty string" \
  "check names the blank glyph"
pass "marker: a blank glyph is refused with the reason"

STATES_UNKNOWN="$TMP_ROOT/states-unknown.toml"
cat > "$STATES_UNKNOWN" <<'TOML'
[meta]
schema = 1

[states.glyphs]
nosuchstep = "@x"
TOML
out=$(check_file "$STATES_UNKNOWN")
assert_contains "$out" "warning: states.glyphs.nosuchstep" "an unrecognised state is named"
assert_contains "$out" "ok:" "an unrecognised state stays a warning, never a failure"
pass "marker: an unrecognised state name warns without failing the lookup"

# --- herdr state-marker call shape -------------------------------------------

: > "$HERDR_LOG"
herdr_backend fm_backend_herdr_report_state_marker fm-labels-fake 'w1:p2' "◆cx" \
  || fail "herdr call: state marker report exited non-zero"
herdr_backend fm_backend_herdr_clear_state_marker fm-labels-fake 'w1:p2' \
  || fail "herdr call: state marker clear exited non-zero"
assert_equals "$(joined pane report-metadata 'w1:p2' --source firstmate-state-marker \
  --token "st=◆cx" --session fm-labels-fake)" "$(sed -n 1p "$HERDR_LOG")" \
  "the pane id precedes every option in the state-marker call"
assert_equals "$(joined pane report-metadata 'w1:p2' --source firstmate-state-marker \
  --clear-token st --session fm-labels-fake)" "$(sed -n 2p "$HERDR_LOG")" \
  "clearing names the same token under the same source"
pass "herdr: the state marker is set and cleared under its own source"

# The marker must never be able to overwrite the model label: they are separate
# metadata sources precisely so a state change cannot cost the row its label.
assert_not_contains "$(cat "$HERDR_LOG")" "--display-agent" \
  "the state marker never touches the display agent"
assert_not_contains "$(cat "$HERDR_LOG")" "firstmate-model-label" \
  "the state marker never writes the label's source"
pass "herdr: the state marker cannot clobber the model label"

: > "$HERDR_LOG"
rc=0
herdr_backend fm_backend_herdr_report_state_marker fm-labels-fake 'w1:p2' "◆cx" -- FM_FAKE_HERDR_EXIT=5 2>/dev/null || rc=$?
expect_code 5 "$rc" "a failed state-marker call returns its status to the caller"
rc=0
herdr_backend fm_backend_herdr_report_state_marker fm-labels-fake 'w1:p2' '' || rc=$?
expect_code 1 "$rc" "an empty marker is refused"
rc=0
herdr_backend fm_backend_herdr_clear_state_marker fm-labels-fake '' || rc=$?
expect_code 1 "$rc" "an empty pane id is refused when clearing"
assert_equals 1 "$(wc -l < "$HERDR_LOG" | tr -d ' ')" "refused state-marker calls never reach Herdr"
pass "herdr: state-marker failures surface to the best-effort caller"
