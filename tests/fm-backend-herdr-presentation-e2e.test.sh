#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for project grouping of fresh Herdr workers:
# the explicit opt-out, the version-floor default, grouping under one Herdr
# project parent across sequential, concurrent, and multi-home spawns, lock
# contention and launcher-at-project-root refusals, exact-pane teardown, and
# restart recovery for grouped and retired flat records.
# The test drives the real spawn and teardown scripts, a real Treehouse pool,
# and the guarded named-session lab helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-presentation.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
TREEHOUSE_CALL_LOG="$TMP_ROOT/treehouse-calls.log"
TREEHOUSE_LOCK_DIR="$TMP_ROOT/treehouse-call.lock"
MOVE_CALL_LOG="$TMP_ROOT/workspace-move-calls.log"
FOCUS_AUDIT_LOG="$TMP_ROOT/focus-audit.log"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
: > "$TREEHOUSE_CALL_LOG"
: > "$MOVE_CALL_LOG"
: > "$FOCUS_AUDIT_LOG"
REAL_MOVER="$ROOT/bin/backends/herdr-workspace-move.py"
export REAL_HERDR REAL_TREEHOUSE REAL_MOVER HERDR_CALL_LOG TREEHOUSE_CALL_LOG TREEHOUSE_LOCK_DIR MOVE_CALL_LOG FOCUS_AUDIT_LOG HERDR_ORIGINAL_PATH HERDR_LAB_HELPER
export TMP_ROOT

# Log every production-adapter call, remove its already-validated trailing
# session flag, and send the operation through the lab helper so that helper
# remains the sole process which appends the real trailing session flag.
# The adapter's deliberately session-independent version read cannot pass the
# helper's leading-option guard, so the wrapper sends only that read straight
# to the absolute real binary with the same explicit trailing lab session.
# Every layout mutation also records the exact active workspace and tab before
# and after the call so focus drift is attributable to one call.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last_index=$((${#args[@]} - 1))
flag_index=$((last_index - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag_index]}" = --session ] \
   && [ "${args[$last_index]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last_index]" "args[$flag_index]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}

arg_value() {
  local want=$1 previous= arg
  shift
  for arg in "$@"; do
    if [ "$previous" = "$want" ]; then
      printf '%s' "$arg"
      return 0
    fi
    previous=$arg
  done
  return 1
}

label=$(arg_value --label "$@" || true)
mutation=
mutation_target=${3:-}
case "${1:-} ${2:-}" in
  "workspace create") mutation=workspace-create; mutation_target=$label ;;
  "workspace close") mutation=workspace-close ;;
  "worktree open") mutation=worktree-open; mutation_target=$label ;;
  "pane move") mutation=pane-move ;;
  "tab create") mutation=tab-create; mutation_target=$label ;;
  "pane close") mutation=pane-close ;;
  "tab focus") mutation=tab-focus ;;
esac
before=
[ -z "$mutation" ] || before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"); then
  status=0
else
  status=$?
fi
if [ -n "$mutation" ]; then
  after=$(focus_snapshot || printf ambiguous/ambiguous)
  printf '%s\t%s\t%s\t%s\n' "$mutation" "$before" "$after" "$mutation_target" >> "$FOCUS_AUDIT_LOG"
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$TREEHOUSE_CALL_LOG"
# Treehouse's pool allocator is outside the Herdr concurrency contract under
# test. Serialize its calls so simultaneous spawns cannot race for one pool
# slot before reaching the Herdr session lock exercised below.
while ! mkdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null; do
  sleep 0.01
done
release_treehouse_lock() { rmdir "$TREEHOUSE_LOCK_DIR" 2>/dev/null || true; }
trap release_treehouse_lock EXIT
trap 'exit 1' HUP INT TERM
"$REAL_TREEHOUSE" "$@"
exit $?
SH

# The focus-safe emptying-close plan that teardown uses may reposition a
# workspace through this mover; record it with the same focus audit.
cat > "$FAKEBIN/herdr-workspace-mover" <<'SH'
#!/usr/bin/env bash
set -u
focus_snapshot() {
  local list row workspace tab tabs
  list=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list) || return 1
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || return 1
  [ -n "$row" ] || return 1
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$workspace") || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s/%s' "$workspace" "$tab"
}
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$MOVE_CALL_LOG"
before=$(focus_snapshot || printf ambiguous/ambiguous)
if out=$("$REAL_MOVER" "$@"); then
  status=0
else
  status=$?
fi
after=$(focus_snapshot || printf ambiguous/ambiguous)
printf 'workspace-move\t%s\t%s\t%s\n' "$before" "$after" "$2" >> "$FOCUS_AUDIT_LOG"
[ -z "$out" ] || printf '%s\n' "$out"
exit "$status"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse" "$FAKEBIN/herdr-workspace-mover"
export PATH="$FAKEBIN:$PATH"
export FM_BACKEND_HERDR_WORKSPACE_MOVER="$FAKEBIN/herdr-workspace-mover"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session launcher identity. Every worker below is staged in the
# home workspace this suite sets up, not in the developer's own workspace.
herdr_forget_inherited_pane

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" name fm-herdr-presentation-projection)
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
LAB_READY=0
RECORDED_WORKTREES=""
LOCK_CONTENTION_OWNER_PID=
cleanup_all() {
  local wt
  if [ -n "$LOCK_CONTENTION_OWNER_PID" ]; then
    kill "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    wait "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null || true
    LOCK_CONTENTION_OWNER_PID=
  fi
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" \
      "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
      || PATH="$HERDR_ORIGINAL_PATH" \
        "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT

PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

focus_snapshot() {
  local list row workspace tab tabs
  list=$(lab workspace list) || fail "could not read the active workspace for focus instrumentation"
  row=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.active_tab_id | type) == "string")
    | [.workspace_id, .active_tab_id]
    | @tsv
  ') || fail "could not parse the active workspace and tab"
  [ -n "$row" ] || fail "focus instrumentation found an ambiguous active workspace"
  workspace=${row%%$'\t'*}
  tab=${row#*$'\t'}
  tabs=$(lab tab list --workspace "$workspace") || fail "could not verify the active tab"
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    ([.result.tabs[]? | select(.focused == true)] | length) == 1
    and ([.result.tabs[]? | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || fail "workspace active_tab_id disagreed with the focused tab"
  printf '%s/%s' "$workspace" "$tab"
}

assert_focus_is() {  # <expected> <case-name>
  local expected=$1 case_name=$2 actual
  actual=$(focus_snapshot)
  [ "$actual" = "$expected" ] || fail "$case_name changed active workspace/tab from $expected to $actual"
}

focus_audit_line_count() { wc -l < "$FOCUS_AUDIT_LOG" | tr -d '[:space:]'; }

# Staging creates, grouping opens and moves, and the child's seeded-tab prune
# must each leave the exact active workspace and tab untouched by themselves.
assert_raw_presentation_mutations_preserved_since() {  # <line-count> <case-name>
  local start=$1 case_name=$2 changed
  changed=$(sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' '
    ($1 == "workspace-create" || $1 == "tab-create" || $1 == "worktree-open" || $1 == "pane-move" || $1 == "workspace-move" || $1 == "pane-close") && $2 != $3 {
      print $0
    }
  ')
  [ -z "$changed" ] || fail "$case_name changed active workspace/tab inside a create, grouping, move, or seeded cleanup call: $changed"
}

# The focus-safe emptying-close plan removes a last pane through Herdr's
# pane-death path with no pane.close mutation at all (the raw explicit-close
# defect is demonstrated by tests/fm-backend-herdr-focus-flash-e2e.test.sh);
# a fallback plain close must preserve or immediately restore exact focus.
assert_cleanup_focus_preserved() {  # <line-count> <pane-id> <expected-focus>
  local start=$1 pane_id=$2 expected=$3
  sed -n "$((start + 1)),\$p" "$FOCUS_AUDIT_LOG" | awk -F '\t' -v pane="$pane_id" -v expected="$expected" '
    $1 == "pane-close" && $4 == pane {
      saw_close = 1
      if ($2 != expected) { bad = 1 }
      else if ($3 == expected) { preserved = 1 }
      else { drift = $3 }
      next
    }
    saw_close && drift != "" && $1 == "tab-focus" && $2 == drift && $3 == expected {
      preserved = 1
    }
    END { exit(bad || (saw_close && !preserved) ? 1 : 0) }
  ' || fail "grouped pane close did not preserve or restore the exact active workspace and tab"
  if lab pane get "$pane_id" >/dev/null 2>&1; then
    fail "grouped cleanup left exact pane $pane_id alive"
  fi
}

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

journal_field() {  # <journal> <key>
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(meta_field "$1" worktree)
  [ -n "$wt" ] || fail "metadata did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
  printf '%s' "$wt"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr grouping E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {  # <home> <id> [description]
  local home=$1 id=$2 description=${3:-Herdr grouping fixture $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$description

## Firstmate spec
Verify project-grouped workspace behavior for $id.
EOF
}

spawn_task() {  # <id> <home> <project>
  local id=$1 home=$2 project=$3
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}

finish_concurrent_spawn() {  # <id> <status> <stdout> <stderr> <project>
  local id=$1 status=$2 out=$3 err=$4 project=$5
  [ "$status" -ne 0 ] || return 0
  grep -F "task set is locked" "$err" >/dev/null 2>&1 \
    || fail "concurrent grouped spawn $id failed unexpectedly: $(cat "$err")"
  spawn_task "$id" "$HOME_DIR" "$project" > "$out" 2> "$err" \
    || fail "grouped spawn $id retry failed after task-set publication completed: $(cat "$err")"
}

spawn_secondmate_task() {
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$home" "sh -c 'while :; do sleep 60; done'" --secondmate --backend herdr
}

teardown_task() {  # <id> <home>
  local id=$1 home=$2
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force
}

finish_concurrent_teardown() {  # <id> <status> <stdout> <stderr>
  local id=$1 status=$2 out=$3 err=$4
  [ "$status" -ne 0 ] || return 0
  if ! grep -F "session presentation lock is contended" "$err" >/dev/null 2>&1 \
     && ! grep -F "another Treehouse slot allocation or return is in progress" "$err" >/dev/null 2>&1; then
    fail "grouped teardown $id failed unexpectedly: $(cat "$err")"
  fi
  teardown_task "$id" "$HOME_DIR" > "$out" 2> "$err" \
    || fail "grouped teardown $id retry failed after cleanup completed: $(cat "$err")"
}

normalize_meta() {  # <meta>
  sed -E \
    -e 's|^window=.*$|window=<herdr-container-id>|' \
    -e 's|^herdr_workspace_id=.*$|herdr_workspace_id=<herdr-container-id>|' \
    -e 's|^herdr_tab_id=.*$|herdr_tab_id=<herdr-container-id>|' \
    -e 's|^herdr_pane_id=.*$|herdr_pane_id=<herdr-container-id>|' \
    -e 's|^spawn_gen=.*$|spawn_gen=<spawn-incarnation>|' \
    "$1"
}

log_line_count() { wc -l < "$HERDR_CALL_LOG" | tr -d '[:space:]'; }

calls_since() {  # <line-count>
  sed -n "$(($1 + 1)),\$p" "$HERDR_CALL_LOG"
}

session_presentation_lock_path() {
  PATH="$FAKEBIN:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_presentation_session_lock_path "$1"
  ' "$ROOT" "$HERDR_LAB_SESSION"
}

assert_no_grouping_calls_since() {  # <line-count> <case-name>
  if calls_since "$1" | grep -E $'^(worktree\t(open|create)|pane\tmove)' >/dev/null 2>&1; then
    fail "$2 opened a worktree space or moved a pane"
  fi
}

assert_no_workspace_lifecycle_calls_since() {  # <line-count> <case-name>
  if calls_since "$1" | grep -E $'^(workspace\t(close|rename|move)|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$2 closed, renamed, or moved a workspace, or touched session lifecycle"
  fi
}

assert_no_projection_mutation_since() {  # <line-count> <case-name>
  if calls_since "$1" | grep -E $'^(workspace\t(create|close|rename|move)|worktree\t(open|create|remove)|tab\t(create|close)|pane\t(close|move)|session\t(stop|delete)|server)' >/dev/null 2>&1; then
    fail "$2 performed a create, close, move, rename, or lifecycle call during recovery inspection"
  fi
}

count_spaces_holding() {  # <checkout-path>
  lab workspace list | jq --arg checkout "$1" '
    [.result.workspaces[]? | select((.worktree | type) == "object" and .worktree.checkout_path == $checkout)] | length
  '
}

count_project_parents() {  # <project-dir>
  lab workspace list | jq --arg root "$(cd "$1" && pwd -P)" '
    [.result.workspaces[]?
      | select((.worktree | type) == "object"
          and .worktree.is_linked_worktree == false
          and .worktree.checkout_path == $root)]
    | length
  '
}

# assert_grouped: prove one worker is grouped exactly as the new design
# guarantees - a version 4 binding naming its physical worktree, metadata that
# points at the moved task pane inside a child space with the plain concise
# label and real linked-worktree membership, one fm-<id> tab and pane there,
# and a project parent that is the non-linked space at the project's checkout.
# Sets GROUPED_CHILD, GROUPED_TAB, GROUPED_PANE, GROUPED_PARENT, and
# GROUPED_CHECKOUT.
assert_grouped() {  # <id> <home> <project-dir> <case-name>
  local id=$1 home=$2 project=$3 name=$4 meta journal wt concise project_real child_info parent_info tabs panes window repo
  meta="$home/state/$id.meta"
  journal="$home/state/$id.herdr-presentation"
  [ -f "$meta" ] || fail "$name did not publish task metadata"
  [ -f "$journal" ] || fail "$name did not publish a grouping journal"
  wt=$(meta_field "$meta" worktree)
  GROUPED_CHECKOUT=$(cd "$wt" 2>/dev/null && pwd -P) || fail "$name recorded worktree $wt is not a directory"
  project_real=$(cd "$project" && pwd -P)
  concise=${id#fm-}
  [ "$(journal_field "$journal" version)" = 4 ] \
    || fail "$name journal is not an exact version 4 grouped binding: $(tr '\n' ' ' < "$journal")"
  [ "$(wc -l < "$journal" | tr -d '[:space:]')" = 13 ] \
    || fail "$name version 4 journal does not have its 13 fields"
  [ "$(journal_field "$journal" checkout_path)" = "$GROUPED_CHECKOUT" ] \
    || fail "$name journal did not bind the worker's physical worktree"
  [ "$(journal_field "$journal" workspace_label)" = "$concise" ] \
    || fail "$name journal workspace label is not the plain concise task name"
  [ "$(journal_field "$journal" task_label)" = "fm-$id" ] \
    || fail "$name journal task label is not fm-$id"
  [ "$(journal_field "$journal" home)" = "$(cd "$home" && pwd -P)" ] \
    || fail "$name journal did not bind the spawning home"
  [ "$(journal_field "$journal" session)" = "$HERDR_LAB_SESSION" ] \
    || fail "$name journal did not bind the lab session"
  GROUPED_CHILD=$(meta_field "$meta" herdr_workspace_id)
  GROUPED_TAB=$(meta_field "$meta" herdr_tab_id)
  GROUPED_PANE=$(meta_field "$meta" herdr_pane_id)
  GROUPED_PARENT=$(journal_field "$journal" parent_workspace_id)
  [ "$(journal_field "$journal" workspace_id)" = "$GROUPED_CHILD" ] \
    && [ "$(journal_field "$journal" tab_id)" = "$GROUPED_TAB" ] \
    && [ "$(journal_field "$journal" pane_id)" = "$GROUPED_PANE" ] \
    || fail "$name journal and metadata name different endpoints"
  window=$(meta_field "$meta" window)
  case "$window" in
    *":$GROUPED_PANE") ;;
    *) fail "$name metadata target '$window' does not name the moved task pane $GROUPED_PANE" ;;
  esac
  case "$GROUPED_CHILD" in
    "$FIRSTMATE_WSID"|"$SECOND_ONE_WSID"|"$SECOND_TWO_WSID"|"$GROUPED_PARENT")
      fail "$name metadata still points at a launching or parent space"
      ;;
  esac
  child_info=$(lab workspace get "$GROUPED_CHILD") || fail "$name child space $GROUPED_CHILD is not live"
  printf '%s' "$child_info" | jq -e --arg label "$concise" --arg checkout "$GROUPED_CHECKOUT" '
    .result.workspace
    | .label == $label
      and .worktree.is_linked_worktree == true
      and .worktree.checkout_path == $checkout
  ' >/dev/null 2>&1 \
    || fail "$name child space is not a linked worktree member with the plain concise label: $(printf '%s' "$child_info" | jq -c '.result.workspace | {label, worktree}')"
  tabs=$(lab tab list --workspace "$GROUPED_CHILD") || fail "$name could not list the child's tabs"
  panes=$(lab pane list --workspace "$GROUPED_CHILD") || fail "$name could not list the child's panes"
  printf '%s' "$tabs" | jq -e --arg tab "$GROUPED_TAB" --arg label "fm-$id" '
    (.result.tabs | length) == 1 and .result.tabs[0].tab_id == $tab and .result.tabs[0].label == $label
  ' >/dev/null 2>&1 \
    || fail "$name child space does not hold exactly its fm-$id task tab: $(printf '%s' "$tabs" | jq -c '[.result.tabs[] | {tab_id, label}]')"
  printf '%s' "$panes" | jq -e --arg pane "$GROUPED_PANE" '
    (.result.panes | length) == 1 and .result.panes[0].pane_id == $pane
  ' >/dev/null 2>&1 \
    || fail "$name child space does not hold exactly its recorded task pane"
  repo=$(printf '%s' "$child_info" | jq -r '.result.workspace.worktree.repo_key // empty')
  parent_info=$(lab workspace get "$GROUPED_PARENT") || fail "$name project parent $GROUPED_PARENT is not live"
  printf '%s' "$parent_info" | jq -e \
    --arg root "$project_real" --arg repo "$repo" --arg label "$(journal_field "$journal" parent_label)" '
    .result.workspace
    | .label == $label
      and .worktree.is_linked_worktree == false
      and .worktree.checkout_path == $root
      and .worktree.repo_key == $repo
  ' >/dev/null 2>&1 \
    || fail "$name parent is not the project's non-linked checkout space: $(printf '%s' "$parent_info" | jq -c '.result.workspace | {label, worktree}')"
  [ "$(journal_field "$journal" parent_label)" = "$(basename "$project_real")" ] \
    || fail "$name project parent label is not the repository name"
  [ "$(count_spaces_holding "$GROUPED_CHECKOUT")" = 1 ] \
    || fail "$name worktree is open in more than one space"
}

HOME_DIR="$TMP_ROOT/home"
SECOND_HOME_A="$TMP_ROOT/home-2ndmate-alpha"
SECOND_HOME_B="$TMP_ROOT/home-2ndmate-bravo"
PROJECT_DIR="$TMP_ROOT/project"
CONCURRENT_PROJECT_DIR="$TMP_ROOT/concurrent-project"
RECOVERY_PROJECT_DIR="$TMP_ROOT/recovery-project"
SELF_PROJECT_DIR="$TMP_ROOT/self-project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" \
  "$SECOND_HOME_A/state" "$SECOND_HOME_A/config" "$SECOND_HOME_A/data" \
  "$SECOND_HOME_B/state" "$SECOND_HOME_B/config" "$SECOND_HOME_B/data"
touch "$HOME_DIR/state/.last-watcher-beat"
# Presentation spaces are on by default, so the flat baseline below opts out
# explicitly; the grouped cases each restate the setting they exercise.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
make_project "$PROJECT_DIR"
make_project "$CONCURRENT_PROJECT_DIR"
make_project "$RECOVERY_PROJECT_DIR"
make_project "$SELF_PROJECT_DIR"

# Secondmate homes look like gitignored firstmate homes so inheritance may
# write config/herdr-presentation-spaces.
printf 'alpha\n' > "$SECOND_HOME_A/.fm-secondmate-home"
printf 'bravo\n' > "$SECOND_HOME_B/.fm-secondmate-home"
touch "$SECOND_HOME_A/state/.last-watcher-beat" "$SECOND_HOME_B/state/.last-watcher-beat"
for SECOND_HOME in "$SECOND_HOME_A" "$SECOND_HOME_B"; do
  git -C "$SECOND_HOME" init -q
  printf 'config/herdr-presentation-spaces\nconfig/crew-harness\nconfig/crew-dispatch.json\nconfig/backlog-backend\nconfig/backend\nconfig/startup-memory-budget\n' \
    > "$SECOND_HOME/.gitignore"
  git -C "$SECOND_HOME" add .gitignore
  git -C "$SECOND_HOME" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm init
done
mkdir -p "$SECOND_HOME_A/bin"
printf '# Firstmate secondmate fixture\n' > "$SECOND_HOME_A/AGENTS.md"
printf 'Secondmate alpha charter.\n' > "$SECOND_HOME_A/data/charter.md"

# Home workspaces the spawns adopt by label. The primary and alpha homes sit
# outside every project, so their workers may group. Bravo sits at one
# project's own checkout, like a firstmate working on its own repository, and
# is the captain's focused space throughout.
FIRSTMATE_OUT=$(lab workspace create --cwd "$HOME_DIR" --label firstmate --no-focus) \
  || fail "could not create the primary home workspace"
SECOND_ONE_OUT=$(lab workspace create --cwd "$SECOND_HOME_A" --label 2ndmate-alpha --no-focus) \
  || fail "could not create the secondmate alpha home workspace"
SECOND_TWO_OUT=$(lab workspace create --cwd "$SELF_PROJECT_DIR" --label 2ndmate-bravo --focus) \
  || fail "could not create the focused secondmate bravo home workspace"
FIRSTMATE_WSID=$(printf '%s' "$FIRSTMATE_OUT" | jq -r '.result.workspace.workspace_id // empty')
SECOND_ONE_WSID=$(printf '%s' "$SECOND_ONE_OUT" | jq -r '.result.workspace.workspace_id // empty')
SECOND_TWO_WSID=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.workspace.workspace_id // empty')
SECOND_TWO_TAB=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.tab.tab_id // empty')
SECOND_TWO_PANE=$(printf '%s' "$SECOND_TWO_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$FIRSTMATE_WSID" ] && [ -n "$SECOND_ONE_WSID" ] && [ -n "$SECOND_TWO_WSID" ] \
  && [ -n "$SECOND_TWO_TAB" ] && [ -n "$SECOND_TWO_PANE" ] \
  || fail "home workspace fixtures returned incomplete IDs"
CAPTAIN_FOCUS="$SECOND_TWO_WSID/$SECOND_TWO_TAB"
assert_focus_is "$CAPTAIN_FOCUS" "focused secondmate fixture"

# ------------------------------------------------------------------
# Opt-out and version floor.
# ------------------------------------------------------------------
write_ship_brief "$HOME_DIR" shape 'Grouping shape fixture.'
: > "$TREEHOUSE_CALL_LOG"
OFF_START=$(log_line_count)
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/off.out" 2> "$TMP_ROOT/off.err" \
  || fail "opted-out spawn failed: $(cat "$TMP_ROOT/off.err")"
OFF_META="$TMP_ROOT/off.meta"
cp "$HOME_DIR/state/shape.meta" "$OFF_META"
OFF_WT=$(remember_meta_worktree "$OFF_META")
cp "$TREEHOUSE_CALL_LOG" "$TMP_ROOT/off-treehouse.log"
[ "$(meta_field "$OFF_META" herdr_workspace_id)" = "$FIRSTMATE_WSID" ] \
  || fail "opted-out spawn did not stay in its launching home workspace"
[ ! -e "$HOME_DIR/state/shape.herdr-presentation" ] \
  || fail "opted-out spawn published a grouping journal"
assert_no_grouping_calls_since "$OFF_START" "opted-out spawn"
if calls_since "$OFF_START" | grep -E $'^(api\tschema|session\tlist)' >/dev/null 2>&1; then
  fail "opted-out spawn added presentation capability or lock calls"
fi
assert_focus_is "$CAPTAIN_FOCUS" "opted-out spawn"
pass "real Herdr lab: an opted-out spawn stays flat in its launching space with zero grouping calls"
teardown_task shape "$HOME_DIR" > "$TMP_ROOT/off-teardown.out" 2> "$TMP_ROOT/off-teardown.err" \
  || fail "opted-out teardown failed: $(cat "$TMP_ROOT/off-teardown.err")"

# A home that configured nothing at all follows the version floor: it groups on
# a release at or above it, and takes the ordinary flat layout with one naming
# warning below it.
rm -f "$HOME_DIR/config/herdr-presentation-spaces"
write_ship_brief "$HOME_DIR" default-on 'Grouping default-on fixture.'
FLOOR_STATUS=$(lab status --json) || fail 'could not read the lab release for the presentation floor'
FLOOR_VERSION=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.version else .client.version end')
FLOOR_PROTOCOL=$(printf '%s' "$FLOOR_STATUS" | jq -r 'if .server.running then .server.protocol else .client.protocol end')
FLOOR_VERDICT=$(bash -c '
  . "$0/bin/backends/herdr.sh"
  status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" || status=$?
  printf "%s\n" "$status"
' "$ROOT" "$FLOOR_PROTOCOL" "$FLOOR_VERSION")
[ "$FLOOR_VERDICT" = 0 ] || [ "$FLOOR_VERDICT" = 1 ] \
  || fail "herdr $FLOOR_VERSION protocol $FLOOR_PROTOCOL could not be classified against the presentation floor"
DEFAULT_START=$(log_line_count)
spawn_task default-on "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/default-on.out" 2> "$TMP_ROOT/default-on.err" \
  || fail "default-on spawn failed: $(cat "$TMP_ROOT/default-on.err")"
DEFAULT_ON_META="$HOME_DIR/state/default-on.meta"
remember_meta_worktree "$DEFAULT_ON_META" >/dev/null
assert_focus_is "$CAPTAIN_FOCUS" "default-on spawn"
if [ "$FLOOR_VERDICT" = 0 ]; then
  assert_grouped default-on "$HOME_DIR" "$PROJECT_DIR" "an unconfigured home's spawn"
  DEFAULT_ON_CHILD=$GROUPED_CHILD
  DEFAULT_ON_PARENT=$GROUPED_PARENT
  pass "real Herdr lab: a home that configured nothing is grouped under its project by default on herdr $FLOOR_VERSION"
else
  [ ! -e "$HOME_DIR/state/default-on.herdr-presentation" ] \
    || fail "an unconfigured home published a grouping journal on below-floor herdr $FLOOR_VERSION"
  [ "$(meta_field "$DEFAULT_ON_META" herdr_workspace_id)" = "$FIRSTMATE_WSID" ] \
    || fail "an unconfigured home did not stay flat on below-floor herdr $FLOOR_VERSION"
  assert_no_grouping_calls_since "$DEFAULT_START" "below-floor default spawn"
  grep -q "$FLOOR_VERSION" "$TMP_ROOT/default-on.err" \
    || fail "the below-floor fallback did not name herdr $FLOOR_VERSION: $(cat "$TMP_ROOT/default-on.err")"
  pass "real Herdr lab: a home that configured nothing stays flat on below-floor herdr $FLOOR_VERSION with one naming warning"
fi
teardown_task default-on "$HOME_DIR" > "$TMP_ROOT/default-on-teardown.out" 2> "$TMP_ROOT/default-on-teardown.err" \
  || fail "default-on teardown failed: $(cat "$TMP_ROOT/default-on-teardown.err")"
if [ "$FLOOR_VERDICT" = 0 ]; then
  if lab workspace get "$DEFAULT_ON_CHILD" >/dev/null 2>&1; then
    fail "default-on teardown left its child space behind"
  fi
  lab workspace get "$DEFAULT_ON_PARENT" >/dev/null 2>&1 \
    || fail "default-on teardown removed the project parent"
fi

# ------------------------------------------------------------------
# A fresh grouped spawn, compared against the opted-out one.
# ------------------------------------------------------------------
: > "$TREEHOUSE_CALL_LOG"
# The historical presence-based opt-in was an empty file; it must still group,
# so no home that had already enabled presentation spaces is turned off.
: > "$HOME_DIR/config/herdr-presentation-spaces"
SHAPE_START=$(log_line_count)
SHAPE_FOCUS_START=$(focus_audit_line_count)
SHAPE_MOVE_START=$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')
spawn_task shape "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/on.out" 2> "$TMP_ROOT/on.err" \
  || fail "grouped spawn failed: $(cat "$TMP_ROOT/on.err")"
assert_focus_is "$CAPTAIN_FOCUS" "grouped spawn"
assert_raw_presentation_mutations_preserved_since "$SHAPE_FOCUS_START" "grouped spawn"
ON_META="$TMP_ROOT/on.meta"
cp "$HOME_DIR/state/shape.meta" "$ON_META"
ON_WT=$(remember_meta_worktree "$ON_META")
assert_grouped shape "$HOME_DIR" "$PROJECT_DIR" "grouped spawn"
SHAPE_CHILD=$GROUPED_CHILD
SHAPE_PANE=$GROUPED_PANE
PROJECT_PARENT=$GROUPED_PARENT
[ "$(count_project_parents "$PROJECT_DIR")" = 1 ] \
  || fail "grouped spawn left other than exactly one project parent"
SHAPE_CALLS=$(calls_since "$SHAPE_START")
printf '%s\n' "$SHAPE_CALLS" | awk -F '\t' '$1 == "worktree" && $2 == "open"' | grep -F $'\t--no-focus' >/dev/null 2>&1 \
  || fail "grouped spawn did not open its worktree space without focus"
printf '%s\n' "$SHAPE_CALLS" | awk -F '\t' '$1 == "pane" && $2 == "move"' | grep -F $'\t--no-focus' >/dev/null 2>&1 \
  || fail "grouped spawn did not move its staged task pane without focus"
if printf '%s\n' "$SHAPE_CALLS" | grep -E $'^workspace\tcreate' >/dev/null 2>&1; then
  fail "grouped spawn created a workspace itself instead of letting worktree open own the group"
fi
assert_no_workspace_lifecycle_calls_since "$SHAPE_START" "grouped spawn"
[ "$(wc -l < "$MOVE_CALL_LOG" | tr -d '[:space:]')" = "$SHAPE_MOVE_START" ] \
  || fail "grouped spawn reordered workspaces"
lab pane get "$SECOND_TWO_PANE" >/dev/null 2>&1 \
  || fail "grouped spawn affected the focused secondmate workspace"
pass "real Herdr lab: a fresh worker is grouped as a plain-labeled linked child under one project parent with an exact version 4 binding and no focus drift"

cmp -s "$TMP_ROOT/off-treehouse.log" "$TREEHOUSE_CALL_LOG" \
  || fail "Treehouse command sequence changed between opted-out and grouped spawns"
[ "$OFF_WT" = "$ON_WT" ] || fail "Treehouse did not reuse the same fixture worktree, so metadata comparison is inconclusive"
normalize_meta "$OFF_META" > "$TMP_ROOT/off.meta.normalized"
normalize_meta "$ON_META" > "$TMP_ROOT/on.meta.normalized"
cmp -s "$TMP_ROOT/off.meta.normalized" "$TMP_ROOT/on.meta.normalized" \
  || fail "metadata changed beyond Herdr endpoint IDs between opted-out and grouped paths: $(diff "$TMP_ROOT/off.meta.normalized" "$TMP_ROOT/on.meta.normalized")"
pass "real Herdr lab: Treehouse commands and metadata shape are identical to the flat path except for endpoint IDs and spawn incarnation"

# A second worker on the same project, with an fm- prefixed identity, joins the
# same parent under its concise label.
write_ship_brief "$HOME_DIR" fm-second 'Second grouped worker on the same project.'
SECOND_FOCUS_START=$(focus_audit_line_count)
spawn_task fm-second "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/fm-second.out" 2> "$TMP_ROOT/fm-second.err" \
  || fail "second grouped spawn failed: $(cat "$TMP_ROOT/fm-second.err")"
remember_meta_worktree "$HOME_DIR/state/fm-second.meta" >/dev/null
assert_focus_is "$CAPTAIN_FOCUS" "second grouped spawn"
assert_raw_presentation_mutations_preserved_since "$SECOND_FOCUS_START" "second grouped spawn"
assert_grouped fm-second "$HOME_DIR" "$PROJECT_DIR" "second grouped spawn"
FM_SECOND_CHILD=$GROUPED_CHILD
FM_SECOND_PANE=$GROUPED_PANE
[ "$GROUPED_PARENT" = "$PROJECT_PARENT" ] \
  || fail "second worker on the same project did not reuse the existing project parent"
[ "$(count_project_parents "$PROJECT_DIR")" = 1 ] \
  || fail "second worker on the same project created another project parent"
pass "real Herdr lab: a second worker on the same project reuses the one project parent"

# Two workers on a project with no parent yet start concurrently; the session
# lock serializes their grouping into one parent with no focus drift.
write_ship_brief "$HOME_DIR" conc-a 'Concurrent grouping fixture A.'
write_ship_brief "$HOME_DIR" conc-b 'Concurrent grouping fixture B.'
CONCURRENT_FOCUS_START=$(focus_audit_line_count)
spawn_task conc-a "$HOME_DIR" "$CONCURRENT_PROJECT_DIR" > "$TMP_ROOT/conc-a.out" 2> "$TMP_ROOT/conc-a.err" &
CONC_A_PID=$!
spawn_task conc-b "$HOME_DIR" "$CONCURRENT_PROJECT_DIR" > "$TMP_ROOT/conc-b.out" 2> "$TMP_ROOT/conc-b.err" &
CONC_B_PID=$!
if wait "$CONC_A_PID"; then CONC_A_STATUS=0; else CONC_A_STATUS=$?; fi
if wait "$CONC_B_PID"; then CONC_B_STATUS=0; else CONC_B_STATUS=$?; fi
finish_concurrent_spawn conc-a "$CONC_A_STATUS" "$TMP_ROOT/conc-a.out" "$TMP_ROOT/conc-a.err" "$CONCURRENT_PROJECT_DIR"
finish_concurrent_spawn conc-b "$CONC_B_STATUS" "$TMP_ROOT/conc-b.out" "$TMP_ROOT/conc-b.err" "$CONCURRENT_PROJECT_DIR"
remember_meta_worktree "$HOME_DIR/state/conc-a.meta" >/dev/null
remember_meta_worktree "$HOME_DIR/state/conc-b.meta" >/dev/null
assert_focus_is "$CAPTAIN_FOCUS" "concurrent grouped spawns"
assert_raw_presentation_mutations_preserved_since "$CONCURRENT_FOCUS_START" "concurrent grouped spawns"
assert_grouped conc-a "$HOME_DIR" "$CONCURRENT_PROJECT_DIR" "concurrent grouped spawn A"
CONC_A_CHILD=$GROUPED_CHILD
CONC_PARENT=$GROUPED_PARENT
assert_grouped conc-b "$HOME_DIR" "$CONCURRENT_PROJECT_DIR" "concurrent grouped spawn B"
CONC_B_CHILD=$GROUPED_CHILD
[ "$GROUPED_PARENT" = "$CONC_PARENT" ] \
  || fail "concurrent workers on one project landed under different parents"
[ "$(count_project_parents "$CONCURRENT_PROJECT_DIR")" = 1 ] \
  || fail "concurrent workers on one project left other than exactly one project parent"
[ "$CONC_PARENT" != "$PROJECT_PARENT" ] \
  || fail "workers on a different project reused another project's parent"
pass "real Herdr lab: concurrent workers on one project end under exactly one parent without focus drift"

# ------------------------------------------------------------------
# Bounded lock contention.
# ------------------------------------------------------------------
write_ship_brief "$HOME_DIR" lock-contended 'Grouping lock contention fixture.'
LOCK_CONTENTION_READY="$TMP_ROOT/lock-contention-ready"
LOCK_CONTENTION_RELEASE="$TMP_ROOT/lock-contention-release"
LOCK_CONTENTION_PATH=$(session_presentation_lock_path) \
  || fail "could not resolve the session presentation lock for contention"
ROOT="$ROOT" READY="$LOCK_CONTENTION_READY" RELEASE="$LOCK_CONTENTION_RELEASE" \
  LOCK="$LOCK_CONTENTION_PATH" bash -c '
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$LOCK" || exit 1
  : > "$READY"
  while [ ! -e "$RELEASE" ]; do sleep 0.05; done
  fm_lock_release "$LOCK"
' &
LOCK_CONTENTION_OWNER_PID=$!
while [ ! -e "$LOCK_CONTENTION_READY" ] && kill -0 "$LOCK_CONTENTION_OWNER_PID" 2>/dev/null; do sleep 0.01; done
[ -e "$LOCK_CONTENTION_READY" ] || fail "could not hold the guarded lab presentation lock"
LOCK_CONTENTION_START=$(log_line_count)
LOCK_CONTENTION_FOCUS_START=$(focus_audit_line_count)
if spawn_task lock-contended "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/lock-contended.out" 2> "$TMP_ROOT/lock-contended.err"; then
  LOCK_CONTENTION_STATUS=0
else
  LOCK_CONTENTION_STATUS=$?
fi
: > "$LOCK_CONTENTION_RELEASE"
wait "$LOCK_CONTENTION_OWNER_PID" || fail "guarded lab presentation lock owner failed"
LOCK_CONTENTION_OWNER_PID=
[ "$LOCK_CONTENTION_STATUS" -eq 0 ] \
  || fail "bounded presentation lock contention did not fall back to a successful flat spawn: $(cat "$TMP_ROOT/lock-contended.err")"
grep -F "presentation lock unavailable" "$TMP_ROOT/lock-contended.err" >/dev/null 2>&1 \
  || fail "bounded presentation lock contention did not warn about staying ungrouped: $(cat "$TMP_ROOT/lock-contended.err")"
LOCK_CONTENTION_META="$HOME_DIR/state/lock-contended.meta"
remember_meta_worktree "$LOCK_CONTENTION_META" >/dev/null
[ "$(meta_field "$LOCK_CONTENTION_META" herdr_workspace_id)" = "$FIRSTMATE_WSID" ] \
  || fail "bounded lock contention did not leave the worker in its launching home workspace"
[ ! -e "$HOME_DIR/state/lock-contended.herdr-presentation" ] \
  || fail "bounded lock contention published a grouping journal"
assert_no_grouping_calls_since "$LOCK_CONTENTION_START" "bounded lock contention"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback"
assert_raw_presentation_mutations_preserved_since "$LOCK_CONTENTION_FOCUS_START" "bounded presentation lock flat fallback"
teardown_task lock-contended "$HOME_DIR" > "$TMP_ROOT/lock-contended-teardown.out" 2> "$TMP_ROOT/lock-contended-teardown.err" \
  || fail "flat lock-contention fixture teardown failed: $(cat "$TMP_ROOT/lock-contended-teardown.err")"
assert_focus_is "$CAPTAIN_FOCUS" "bounded presentation lock flat fallback teardown"
pass "real Herdr lab: bounded lock contention warns and stays flat without a journal, grouping calls, or focus drift"

# ------------------------------------------------------------------
# Exact-pane teardown removes only the child; the parent persists.
# ------------------------------------------------------------------
SHAPE_TEARDOWN_START=$(log_line_count)
SHAPE_CLEANUP_AUDIT_START=$(focus_audit_line_count)
teardown_task shape "$HOME_DIR" > "$TMP_ROOT/on-teardown.out" 2> "$TMP_ROOT/on-teardown.err" \
  || fail "grouped teardown failed: $(cat "$TMP_ROOT/on-teardown.err")"
assert_focus_is "$CAPTAIN_FOCUS" "grouped teardown"
assert_cleanup_focus_preserved "$SHAPE_CLEANUP_AUDIT_START" "$SHAPE_PANE" "$CAPTAIN_FOCUS"
if lab workspace get "$SHAPE_CHILD" >/dev/null 2>&1; then
  fail "closing the exact grouped task pane did not remove its child space"
fi
lab workspace get "$PROJECT_PARENT" >/dev/null 2>&1 \
  || fail "grouped teardown removed the project parent"
{ lab workspace get "$FM_SECOND_CHILD" >/dev/null 2>&1 && lab pane get "$FM_SECOND_PANE" >/dev/null 2>&1; } \
  || fail "grouped teardown affected a sibling child space under the same parent"
[ ! -e "$HOME_DIR/state/shape.herdr-presentation" ] \
  || fail "confirmed grouped teardown did not retire its journal"
assert_no_workspace_lifecycle_calls_since "$SHAPE_TEARDOWN_START" "grouped teardown"
teardown_task fm-second "$HOME_DIR" > "$TMP_ROOT/fm-second-teardown.out" 2> "$TMP_ROOT/fm-second-teardown.err" \
  || fail "second grouped teardown failed: $(cat "$TMP_ROOT/fm-second-teardown.err")"
if lab workspace get "$FM_SECOND_CHILD" >/dev/null 2>&1; then
  fail "the last grouped child's teardown did not remove its child space"
fi
lab workspace get "$PROJECT_PARENT" >/dev/null 2>&1 \
  || fail "tearing down the project's last grouped worker removed the project parent"
assert_no_workspace_lifecycle_calls_since "$SHAPE_TEARDOWN_START" "last grouped child teardown"
assert_focus_is "$CAPTAIN_FOCUS" "last grouped child teardown"
pass "real Herdr lab: exact task-pane teardown removes only the child space, retires its journal, and leaves the project parent"

CONC_TEARDOWN_START=$(log_line_count)
teardown_task conc-a "$HOME_DIR" > "$TMP_ROOT/conc-a-teardown.out" 2> "$TMP_ROOT/conc-a-teardown.err" &
CONC_A_TEARDOWN_PID=$!
teardown_task conc-b "$HOME_DIR" > "$TMP_ROOT/conc-b-teardown.out" 2> "$TMP_ROOT/conc-b-teardown.err" &
CONC_B_TEARDOWN_PID=$!
if wait "$CONC_A_TEARDOWN_PID"; then CONC_A_TEARDOWN_STATUS=0; else CONC_A_TEARDOWN_STATUS=$?; fi
if wait "$CONC_B_TEARDOWN_PID"; then CONC_B_TEARDOWN_STATUS=0; else CONC_B_TEARDOWN_STATUS=$?; fi
finish_concurrent_teardown conc-a "$CONC_A_TEARDOWN_STATUS" "$TMP_ROOT/conc-a-teardown.out" "$TMP_ROOT/conc-a-teardown.err"
finish_concurrent_teardown conc-b "$CONC_B_TEARDOWN_STATUS" "$TMP_ROOT/conc-b-teardown.out" "$TMP_ROOT/conc-b-teardown.err"
assert_focus_is "$CAPTAIN_FOCUS" "concurrent grouped teardowns"
if lab workspace get "$CONC_A_CHILD" >/dev/null 2>&1 || lab workspace get "$CONC_B_CHILD" >/dev/null 2>&1; then
  fail "concurrent grouped teardowns left a child space behind"
fi
lab workspace get "$CONC_PARENT" >/dev/null 2>&1 \
  || fail "concurrent grouped teardowns removed the project parent"
assert_no_workspace_lifecycle_calls_since "$CONC_TEARDOWN_START" "concurrent grouped teardowns"
pass "real Herdr lab: concurrent grouped teardowns are serialized and leave the parent and active workspace/tab unchanged"

# ------------------------------------------------------------------
# Multi-home: real secondmate FM_HOME spawn paths and inheritance.
# ------------------------------------------------------------------
[ -f "$HOME_DIR/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting disappeared before multi-home inheritance"
[ ! -e "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate A unexpectedly had a local presentation setting before inheritance"
[ ! -e "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "secondmate B unexpectedly had a local presentation setting before inheritance"
SECOND_SPAWN_START=$(log_line_count)
spawn_secondmate_task alpha "$SECOND_HOME_A" > "$TMP_ROOT/alpha.out" 2> "$TMP_ROOT/alpha.err" \
  || fail "secondmate alpha spawn failed: $(cat "$TMP_ROOT/alpha.err")"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "secondmate spawn did not inherit the presentation setting"
[ ! -e "$HOME_DIR/state/alpha.herdr-presentation" ] \
  || fail "secondmate spawn published a grouping journal"
SECOND_META="$HOME_DIR/state/alpha.meta"
[ "$(meta_field "$SECOND_META" kind)" = secondmate ] \
  || fail "secondmate spawn did not record kind=secondmate"
[ "$(meta_field "$SECOND_META" herdr_workspace_id)" = "$SECOND_ONE_WSID" ] \
  || fail "secondmate agent did not stay in its own home workspace"
assert_no_grouping_calls_since "$SECOND_SPAWN_START" "secondmate agent spawn"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_A/config" \
  || fail "inheritance into secondmate A failed"
propagate_inheritable_config "$HOME_DIR/config" "$SECOND_HOME_B/config" \
  || fail "inheritance into secondmate B failed"
[ -f "$SECOND_HOME_A/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate A"
[ -f "$SECOND_HOME_B/config/herdr-presentation-spaces" ] \
  || fail "primary presentation setting did not reach secondmate B"
assert_focus_is "$CAPTAIN_FOCUS" "secondmate agent spawn"
pass "real Herdr lab: a secondmate agent stays in its home workspace ungrouped, and the presentation setting inherits into secondmate homes"

write_ship_brief "$HOME_DIR" p1 'Primary multi-home fixture.'
write_ship_brief "$SECOND_HOME_A" a1 'Secondmate A multi-home fixture.'
write_ship_brief "$SECOND_HOME_B" b1 'Secondmate B multi-home fixture.'
MULTI_START=$(log_line_count)
MULTI_FOCUS_START=$(focus_audit_line_count)
spawn_task p1 "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/p1.out" 2> "$TMP_ROOT/p1.err" \
  || fail "multi-home primary p1 failed: $(cat "$TMP_ROOT/p1.err")"
spawn_task a1 "$SECOND_HOME_A" "$PROJECT_DIR" > "$TMP_ROOT/a1.out" 2> "$TMP_ROOT/a1.err" \
  || fail "multi-home secondmate A a1 failed: $(cat "$TMP_ROOT/a1.err")"
spawn_task b1 "$SECOND_HOME_B" "$CONCURRENT_PROJECT_DIR" > "$TMP_ROOT/b1.out" 2> "$TMP_ROOT/b1.err" \
  || fail "multi-home secondmate B b1 failed: $(cat "$TMP_ROOT/b1.err")"
remember_meta_worktree "$HOME_DIR/state/p1.meta" >/dev/null
remember_meta_worktree "$SECOND_HOME_A/state/a1.meta" >/dev/null
remember_meta_worktree "$SECOND_HOME_B/state/b1.meta" >/dev/null
assert_focus_is "$CAPTAIN_FOCUS" "multi-home spawns"
assert_raw_presentation_mutations_preserved_since "$MULTI_FOCUS_START" "multi-home spawns"
assert_grouped p1 "$HOME_DIR" "$PROJECT_DIR" "multi-home primary p1"
[ "$GROUPED_PARENT" = "$PROJECT_PARENT" ] || fail "primary p1 did not join its project's existing parent"
assert_grouped a1 "$SECOND_HOME_A" "$PROJECT_DIR" "multi-home secondmate A a1"
[ "$GROUPED_PARENT" = "$PROJECT_PARENT" ] || fail "secondmate A a1 did not join its project's existing parent"
assert_grouped b1 "$SECOND_HOME_B" "$CONCURRENT_PROJECT_DIR" "multi-home secondmate B b1"
[ "$GROUPED_PARENT" = "$CONC_PARENT" ] || fail "secondmate B b1 did not join its own project's parent"
[ "$(count_project_parents "$PROJECT_DIR")" = 1 ] && [ "$(count_project_parents "$CONCURRENT_PROJECT_DIR")" = 1 ] \
  || fail "multi-home spawns created a duplicate project parent"
for FOREIGN in a1 b1; do
  [ ! -e "$HOME_DIR/state/$FOREIGN.herdr-presentation" ] \
    || fail "secondmate worker $FOREIGN published a journal in the primary home"
done
assert_no_workspace_lifecycle_calls_since "$MULTI_START" "multi-home spawns"
pass "real Herdr lab: primary and secondmate homes each group their workers under that project's one parent with home-local journals"

# A launcher whose own space is the project's checkout would become the parent,
# and closing that parent would close the launcher, so the worker stays flat.
write_ship_brief "$SECOND_HOME_B" b-self 'Launcher at project checkout fixture.'
SELF_START=$(log_line_count)
spawn_task b-self "$SECOND_HOME_B" "$SELF_PROJECT_DIR" > "$TMP_ROOT/b-self.out" 2> "$TMP_ROOT/b-self.err" \
  || fail "launcher-at-checkout spawn failed: $(cat "$TMP_ROOT/b-self.err")"
remember_meta_worktree "$SECOND_HOME_B/state/b-self.meta" >/dev/null
[ "$(meta_field "$SECOND_HOME_B/state/b-self.meta" herdr_workspace_id)" = "$SECOND_TWO_WSID" ] \
  || fail "a worker whose launcher sits at the project checkout left its launching space"
[ ! -e "$SECOND_HOME_B/state/b-self.herdr-presentation" ] \
  || fail "a refused grouping left a journal behind"
assert_no_grouping_calls_since "$SELF_START" "launcher-at-checkout spawn"
assert_no_workspace_lifecycle_calls_since "$SELF_START" "launcher-at-checkout spawn"
assert_focus_is "$CAPTAIN_FOCUS" "launcher-at-checkout spawn"
pass "real Herdr lab: a launcher sitting at the project's own checkout is refused grouping and its worker stays flat with no residue"

MULTI_TEARDOWN_START=$(log_line_count)
for META_HOME_PAIR in "p1:$HOME_DIR" "a1:$SECOND_HOME_A" "b1:$SECOND_HOME_B" "b-self:$SECOND_HOME_B" "alpha:$HOME_DIR"; do
  TASK_ID=${META_HOME_PAIR%%:*}
  TASK_HOME=${META_HOME_PAIR#*:}
  teardown_task "$TASK_ID" "$TASK_HOME" > "$TMP_ROOT/td-$TASK_ID.out" 2> "$TMP_ROOT/td-$TASK_ID.err" \
    || fail "multi-home teardown of $TASK_ID failed: $(cat "$TMP_ROOT/td-$TASK_ID.err")"
done
assert_focus_is "$CAPTAIN_FOCUS" "multi-home teardown"
{ lab workspace get "$PROJECT_PARENT" >/dev/null 2>&1 && lab workspace get "$CONC_PARENT" >/dev/null 2>&1; } \
  || fail "multi-home teardown removed a project parent"
{ lab workspace get "$SECOND_ONE_WSID" >/dev/null 2>&1 && lab pane get "$SECOND_TWO_PANE" >/dev/null 2>&1; } \
  || fail "multi-home teardown removed a home workspace"
assert_no_workspace_lifecycle_calls_since "$MULTI_TEARDOWN_START" "multi-home teardown"
pass "real Herdr lab: multi-home exact-pane teardowns keep parents and home spaces without workspace close authority"

# ------------------------------------------------------------------
# Legacy coexistence.
# ------------------------------------------------------------------
LEGACY_OUT=$(lab workspace create --cwd "$HOME_DIR" --label "firstmate/legacy-seed · p:AbCdEfGhIjKlMnOpQrStUv" --no-focus) \
  || fail "could not seed a legacy owner-prefixed presentation space"
LEGACY_WSID=$(printf '%s' "$LEGACY_OUT" | jq -r '.result.workspace.workspace_id // empty')
CORNER_OUT=$(lab workspace create --cwd "$HOME_DIR" --label "└ corner-seed · p:ZyXwVuTsRqPoNmLkJiHgFe" --no-focus) \
  || fail "could not seed a retired corner presentation space"
CORNER_WSID=$(printf '%s' "$CORNER_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$LEGACY_WSID" ] && [ -n "$CORNER_WSID" ] || fail "legacy seeds returned no workspace id"
FLAT_TAB_OUT=$(lab tab create --workspace "$SECOND_ONE_WSID" --cwd "$SECOND_HOME_A" --label fm-flat-legacy-tab --no-focus) \
  || fail "could not seed a flat secondmate child tab"
FLAT_TAB_ID=$(printf '%s' "$FLAT_TAB_OUT" | jq -r '.result.tab.tab_id // empty')
write_ship_brief "$HOME_DIR" post-legacy 'Post-legacy grouped worker.'
POST_LEGACY_START=$(log_line_count)
spawn_task post-legacy "$HOME_DIR" "$PROJECT_DIR" > "$TMP_ROOT/post-legacy.out" 2> "$TMP_ROOT/post-legacy.err" \
  || fail "post-legacy grouped spawn failed: $(cat "$TMP_ROOT/post-legacy.err")"
remember_meta_worktree "$HOME_DIR/state/post-legacy.meta" >/dev/null
assert_grouped post-legacy "$HOME_DIR" "$PROJECT_DIR" "post-legacy grouped spawn"
[ "$(lab workspace get "$LEGACY_WSID" | jq -r '.result.workspace.label')" = "firstmate/legacy-seed · p:AbCdEfGhIjKlMnOpQrStUv" ] \
  || fail "grouping renamed or removed the seeded legacy presentation space"
[ "$(lab workspace get "$CORNER_WSID" | jq -r '.result.workspace.label')" = "└ corner-seed · p:ZyXwVuTsRqPoNmLkJiHgFe" ] \
  || fail "grouping renamed or removed the seeded retired corner presentation space"
lab tab get "$FLAT_TAB_ID" >/dev/null 2>&1 \
  || fail "grouping removed the seeded flat secondmate child tab"
assert_no_workspace_lifecycle_calls_since "$POST_LEGACY_START" "post-legacy grouped spawn"
teardown_task post-legacy "$HOME_DIR" > "$TMP_ROOT/post-legacy-teardown.out" 2> "$TMP_ROOT/post-legacy-teardown.err" \
  || fail "post-legacy teardown failed: $(cat "$TMP_ROOT/post-legacy-teardown.err")"
pass "real Herdr lab: legacy presentation labels and flat secondmate tabs are left unmigrated"

# ------------------------------------------------------------------
# Recovery of grouped workers.
# ------------------------------------------------------------------
# Closing a project group removes every child space but no worktree. A
# same-identity re-dispatch then finds no space holding its checkout, retires
# the stale binding, and groups the new worker afresh.
REGROUP_ID=regroup-r1
write_ship_brief "$HOME_DIR" "$REGROUP_ID" 'Closed project group regroup fixture.'
spawn_task "$REGROUP_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/regroup-first.out" 2> "$TMP_ROOT/regroup-first.err" \
  || fail "regroup fixture's grouped spawn failed: $(cat "$TMP_ROOT/regroup-first.err")"
REGROUP_META="$HOME_DIR/state/$REGROUP_ID.meta"
REGROUP_OLD_WT=$(remember_meta_worktree "$REGROUP_META")
assert_grouped "$REGROUP_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" "regroup fixture spawn"
REGROUP_OLD_CHILD=$GROUPED_CHILD
REGROUP_OLD_PARENT=$GROUPED_PARENT
REGROUP_OLD_CHECKOUT=$GROUPED_CHECKOUT
lab workspace close "$REGROUP_OLD_PARENT" >/dev/null \
  || fail "could not close the regroup fixture's project group"
if lab workspace get "$REGROUP_OLD_CHILD" >/dev/null 2>&1; then
  fail "closing the project parent did not close its child space"
fi
[ "$(count_spaces_holding "$REGROUP_OLD_CHECKOUT")" = 0 ] \
  || fail "a space still holds the regroup fixture's checkout after its group closed"
[ -d "$REGROUP_OLD_WT" ] || fail "closing the project group deleted the worker's worktree"
assert_focus_is "$CAPTAIN_FOCUS" "closing the regroup fixture's project group"
REGROUP_START=$(log_line_count)
spawn_task "$REGROUP_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/regroup-again.out" 2> "$TMP_ROOT/regroup-again.err" \
  || fail "regroup same-identity re-dispatch failed: $(cat "$TMP_ROOT/regroup-again.err")"
REGROUP_NEW_WT=$(remember_meta_worktree "$REGROUP_META")
assert_focus_is "$CAPTAIN_FOCUS" "regroup same-identity re-dispatch"
assert_grouped "$REGROUP_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" "regroup same-identity re-dispatch"
[ "$GROUPED_CHILD" != "$REGROUP_OLD_CHILD" ] \
  || fail "regroup re-dispatch claimed the closed child space"
[ "$(count_project_parents "$RECOVERY_PROJECT_DIR")" = 1 ] \
  || fail "regroup re-dispatch did not end with exactly one project parent"
assert_no_workspace_lifecycle_calls_since "$REGROUP_START" "regroup same-identity re-dispatch"
REGROUP_PARENT=$GROUPED_PARENT
teardown_task "$REGROUP_ID" "$HOME_DIR" > "$TMP_ROOT/regroup-teardown.out" 2> "$TMP_ROOT/regroup-teardown.err" \
  || fail "regroup teardown failed: $(cat "$TMP_ROOT/regroup-teardown.err")"
[ ! -e "$HOME_DIR/state/$REGROUP_ID.herdr-presentation" ] \
  || fail "regroup teardown did not retire its journal"
[ "$REGROUP_OLD_WT" = "$REGROUP_NEW_WT" ] || "$REAL_TREEHOUSE" return --force "$REGROUP_OLD_WT" >/dev/null 2>&1 || true
pass "real Herdr lab: a re-dispatch whose project group was closed retires the stale binding and groups the new worker afresh"

# After a full Herdr session restart the grouped child is restored as an
# agent-free husk still holding its checkout. A same-identity re-dispatch must
# never reclaim that grouped space in place; it falls back flat and leaves the
# husk untouched.
RESUME_ID=fm-resume-r1
write_ship_brief "$HOME_DIR" "$RESUME_ID" 'Grouped restart fixture.'
spawn_task "$RESUME_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/resume-first.out" 2> "$TMP_ROOT/resume-first.err" \
  || fail "restart fixture's grouped spawn failed: $(cat "$TMP_ROOT/resume-first.err")"
RESUME_META="$HOME_DIR/state/$RESUME_ID.meta"
RESUME_OLD_WT=$(remember_meta_worktree "$RESUME_META")
assert_grouped "$RESUME_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" "restart fixture spawn"
[ "$GROUPED_PARENT" = "$REGROUP_PARENT" ] || fail "restart fixture did not join the existing recovery project parent"
RESUME_OLD_CHILD=$GROUPED_CHILD
RESUME_OLD_TAB=$GROUPED_TAB
RESUME_OLD_PANE=$GROUPED_PANE
RESUME_OLD_CHECKOUT=$GROUPED_CHECKOUT
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated session for grouped restart validation"
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not reprovision the isolated session for grouped restart validation"
lab pane get "$RESUME_OLD_PANE" >/dev/null 2>&1 \
  || fail "restart did not preserve the grouped task pane structurally"
if lab agent get "$RESUME_OLD_PANE" >/dev/null 2>&1; then
  fail "restart fixture unexpectedly retained a registered agent"
fi
[ "$(count_spaces_holding "$RESUME_OLD_CHECKOUT")" = 1 ] \
  || fail "restart did not restore the grouped child's worktree membership"
RESUME_FOCUS=$(focus_snapshot)
RESUME_START=$(log_line_count)
spawn_task "$RESUME_ID" "$HOME_DIR" "$RECOVERY_PROJECT_DIR" > "$TMP_ROOT/resume-again.out" 2> "$TMP_ROOT/resume-again.err" \
  || fail "grouped restart same-identity re-dispatch failed: $(cat "$TMP_ROOT/resume-again.err")"
RESUME_NEW_WT=$(remember_meta_worktree "$RESUME_META")
RESUME_NEW_WSID=$(meta_field "$RESUME_META" herdr_workspace_id)
RESUME_NEW_PANE=$(meta_field "$RESUME_META" herdr_pane_id)
[ "$RESUME_NEW_WSID" != "$RESUME_OLD_CHILD" ] \
  || fail "grouped restart re-dispatch reclaimed the grouped child space in place"
[ "$(lab workspace get "$RESUME_NEW_WSID" | jq -r '.result.workspace.label')" = firstmate ] \
  || fail "grouped restart re-dispatch did not fall back flat into the launching home workspace"
[ "$RESUME_NEW_PANE" != "$RESUME_OLD_PANE" ] \
  || fail "grouped restart re-dispatch reused the old husk pane"
assert_no_grouping_calls_since "$RESUME_START" "grouped restart re-dispatch"
if calls_since "$RESUME_START" | awk -F '\t' -v pane="$RESUME_OLD_PANE" -v child="$RESUME_OLD_CHILD" '
  ($1 == "pane" && $2 == "close" && $3 == pane) || ($1 == "tab" && $2 == "create" && index($0, "\t" child "\t")) { found = 1 }
  END { exit(found ? 0 : 1) }
'; then
  fail "grouped restart re-dispatch closed the husk or created a replacement inside the grouped child"
fi
lab pane get "$RESUME_OLD_PANE" >/dev/null 2>&1 \
  || fail "grouped restart re-dispatch removed the old husk pane"
lab tab list --workspace "$RESUME_OLD_CHILD" | jq -e --arg tab "$RESUME_OLD_TAB" '
  (.result.tabs | length) == 1 and .result.tabs[0].tab_id == $tab
' >/dev/null 2>&1 || fail "grouped restart re-dispatch changed the grouped child's tabs"
assert_no_workspace_lifecycle_calls_since "$RESUME_START" "grouped restart re-dispatch"
assert_focus_is "$RESUME_FOCUS" "grouped restart re-dispatch"
teardown_task "$RESUME_ID" "$HOME_DIR" > "$TMP_ROOT/resume-teardown.out" 2> "$TMP_ROOT/resume-teardown.err" \
  || fail "grouped restart teardown failed: $(cat "$TMP_ROOT/resume-teardown.err")"
[ "$RESUME_OLD_WT" = "$RESUME_NEW_WT" ] || "$REAL_TREEHOUSE" return --force "$RESUME_OLD_WT" >/dev/null 2>&1 || true
pass "real Herdr lab: after a session restart a grouped worker is never reclaimed in place and its re-dispatch falls back flat"

# ------------------------------------------------------------------
# Read-only recovery diagnostics for retired flat and grouped journals.
# ------------------------------------------------------------------
# Missing, renamed, and duplicate correlators are read-only recovery
# diagnostics. Flat fallback is allowed only when every correlated pane is
# positively agent-free; a registered agent refuses a duplicate launch.
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

write_legacy_v1_journal() {  # <state-dir> <task-id> <token>
  mkdir -p "$1"
  printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$2" "$3" \
    > "$(fm_backend_herdr_projection_journal_path "$1" "$2")"
}

MISSING_STATE="$TMP_ROOT/missing-state"
write_legacy_v1_journal "$MISSING_STATE" missing1 MissingToken0123456789
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" \
  "$(fm_backend_herdr_projection_journal_path "$MISSING_STATE" missing1)" missing1 \
  || fail "a legacy journal with no matching title should degrade to flat"
assert_no_projection_mutation_since "$START" "legacy missing-token recovery"

RENAMED_STATE="$TMP_ROOT/renamed-state"
RENAMED_TOKEN=RenamedToken0123456789
write_legacy_v1_journal "$RENAMED_STATE" renamed1 "$RENAMED_TOKEN"
RENAMED_OUT=$(lab workspace create --cwd "$HOME_DIR" --label "└ renamed1 · p:$RENAMED_TOKEN" --no-focus) \
  || fail "could not seed the renamed legacy fixture"
RENAMED_WSID=$(printf '%s' "$RENAMED_OUT" | jq -r '.result.workspace.workspace_id')
lab workspace rename "$RENAMED_WSID" renamed-without-token >/dev/null
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" \
  "$(fm_backend_herdr_projection_journal_path "$RENAMED_STATE" renamed1)" renamed1 \
  || fail "a renamed legacy title should degrade to flat"
assert_no_projection_mutation_since "$START" "legacy renamed-token recovery"
lab workspace get "$RENAMED_WSID" >/dev/null 2>&1 || fail "renamed-token recovery removed or adopted the old workspace"

DUP_STATE="$TMP_ROOT/duplicate-state"
DUP_TOKEN=DuplicateTok0123456789
write_legacy_v1_journal "$DUP_STATE" duplicate1 "$DUP_TOKEN"
DUP_JOURNAL=$(fm_backend_herdr_projection_journal_path "$DUP_STATE" duplicate1)
DUP1=$(lab workspace create --cwd "$HOME_DIR" --label "└ duplicate1 · p:$DUP_TOKEN" --no-focus) \
  || fail "could not seed the first duplicate legacy fixture"
DUP2=$(lab workspace create --cwd "$HOME_DIR" --label "copy/duplicate1 · p:$DUP_TOKEN" --no-focus) \
  || fail "could not seed the second duplicate legacy fixture"
DUP1_WSID=$(printf '%s' "$DUP1" | jq -r '.result.workspace.workspace_id')
DUP2_WSID=$(printf '%s' "$DUP2" | jq -r '.result.workspace.workspace_id')
DUP1_PANE=$(printf '%s' "$DUP1" | jq -r '.result.root_pane.pane_id')
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1 \
  || fail "agent-free duplicate legacy title matches should permit flat fallback"
assert_no_projection_mutation_since "$START" "agent-free duplicate-token recovery"
lab pane report-agent "$DUP1_PANE" --source fm-projection-e2e --agent test-agent --state idle >/dev/null \
  || fail "could not register the duplicate-live-agent risk fixture"
START=$(log_line_count)
if fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$DUP_JOURNAL" duplicate1; then
  fail "a duplicate legacy title match with a registered agent should refuse fallback"
fi
assert_no_projection_mutation_since "$START" "live duplicate-token recovery"
{ lab workspace get "$DUP1_WSID" >/dev/null 2>&1 && lab workspace get "$DUP2_WSID" >/dev/null 2>&1; } \
  || fail "duplicate-token recovery removed a quarantined workspace"
pass "real Herdr lab: missing, renamed, and duplicate legacy titles trigger zero mutation calls, and live duplicate risk refuses launch"

# A grouped attempt journal correlates only through Herdr's worktree
# membership for its checkout path, never through a title.
DIAG_PROJECT_DIR="$TMP_ROOT/diagnostic-project"
make_project "$DIAG_PROJECT_DIR"
git -C "$DIAG_PROJECT_DIR" worktree add -q "$TMP_ROOT/diagnostic-worktree" -b grouped-diagnostic \
  || fail "could not create the grouped diagnostic worktree"
DIAG_WT=$(cd "$TMP_ROOT/diagnostic-worktree" && pwd -P)
GROUPED_STATE="$TMP_ROOT/grouped-state"
fm_backend_herdr_projection_journal_create "$GROUPED_STATE" grouped1 "$DIAG_WT" >/dev/null \
  || fail "could not publish a grouped attempt journal"
GROUPED_JOURNAL=$(fm_backend_herdr_projection_journal_path "$GROUPED_STATE" grouped1)
[ "$(journal_field "$GROUPED_JOURNAL" version)" = 3 ] && [ "$(journal_field "$GROUPED_JOURNAL" checkout_path)" = "$DIAG_WT" ] \
  || fail "grouped attempt journal did not record version 3 with its checkout path"
TITLE_ONLY_OUT=$(lab workspace create --cwd "$HOME_DIR" --label grouped1 --no-focus) \
  || fail "could not seed a same-title space that holds no worktree"
TITLE_ONLY_PANE=$(printf '%s' "$TITLE_ONLY_OUT" | jq -r '.result.root_pane.pane_id')
lab pane report-agent "$TITLE_ONLY_PANE" --source fm-projection-e2e --agent test-agent --state idle >/dev/null \
  || fail "could not register an agent on the same-title fixture"
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$GROUPED_JOURNAL" grouped1 \
  || fail "a grouped journal whose checkout no space holds should degrade to flat, whatever titles exist"
[ "$FM_BACKEND_HERDR_PROJECTION_RECOVERY_CORRELATED" = 0 ] \
  || fail "a same-title space without worktree membership correlated with a grouped journal"
assert_no_projection_mutation_since "$START" "grouped journal with no holding space"
GROUPED_OPEN=$(lab worktree open --cwd "$DIAG_PROJECT_DIR" --path "$DIAG_WT" --label grouped1 --no-focus) \
  || fail "could not open the grouped diagnostic worktree space"
GROUPED_OPEN_PANE=$(printf '%s' "$GROUPED_OPEN" | jq -r '.result.root_pane.pane_id')
START=$(log_line_count)
fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$GROUPED_JOURNAL" grouped1 \
  || fail "an agent-free space holding a grouped journal's checkout should permit flat fallback"
[ "$FM_BACKEND_HERDR_PROJECTION_RECOVERY_CORRELATED" = 1 ] \
  || fail "the space holding a grouped journal's checkout did not correlate"
assert_no_projection_mutation_since "$START" "agent-free grouped recovery"
lab pane report-agent "$GROUPED_OPEN_PANE" --source fm-projection-e2e --agent test-agent --state idle >/dev/null \
  || fail "could not register the grouped live-agent risk fixture"
START=$(log_line_count)
if fm_backend_herdr_projection_recovery_allows_flat "$HERDR_LAB_SESSION" "$GROUPED_JOURNAL" grouped1; then
  fail "a space holding a grouped journal's checkout with a registered agent should refuse fallback"
fi
assert_no_projection_mutation_since "$START" "live grouped recovery"
pass "real Herdr lab: grouped journals correlate only by worktree membership, with zero mutation calls, and a live agent there refuses launch"

STATUS_JSON=$(lab status --json)
HERDR_VERSION=$(printf '%s' "$STATUS_JSON" | jq -r '.client.version // "unknown"')
PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail "guarded Herdr lab teardown or default-session tripwire verification failed"
LAB_READY=0
pass "real Herdr lab validation completed on Herdr $HERDR_VERSION with the default-session tripwire intact"

cleanup_all
trap - EXIT
