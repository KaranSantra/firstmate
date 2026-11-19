#!/usr/bin/env bash
# One-pass pstack review for a PR-based ship, run beside the selected delivery
# path rather than as a gate on it (docs/pstack-review.md owns the design).
#
# Every enabled change gets exactly one review pass, from a reviewer of another
# vendor than the builder: a Claude-built change goes to pi on OpenAI, a pi or
# Codex built change goes to Claude Code. The reviewer follows pstack's
# interrogate brief as the only adversary: findings count only when a run
# proves them, and it never edits, commits, pushes, or merges. Each verified
# finding is filed as a backlog ticket through bin/fm-tasks-axi.sh, held for
# the captain by default so a finding never dispatches a fix round on its own.
# The review never blocks, re-runs, or steers the task: the PR merges or waits
# on its existing merge authority exactly as before.
#
# The project's own policy file (.agents/pstack-review.json at the PR head)
# sorts the change into a tier before any merge decision:
#   skip   every changed path matches a "skip" pattern; no review runs.
#   review the default; one review pass runs, the merge path is unchanged.
#   tap    a changed path matches a "tap" pattern (money, auth); one review
#          pass runs AND the merge waits for the captain whatever yolo says.
# Patterns are bash [[ == ]] globs, where * also crosses /.
#
# Opt-in per home: nothing runs unless config/pstack-review.json lists the
# project (by the basename of its directory) under "projects".
#
# Usage:
#   fm-pstack-review.sh classify <task-id>  print tier=<skip|review|tap> and why
#   fm-pstack-review.sh start <task-id>     classify, then run the one pass detached
#   fm-pstack-review.sh run <task-id>       the one pass in the foreground
#   fm-pstack-review.sh status <task-id>    print the recorded result
# Exit status: 0 on success (including "not enabled", "skip", "already
# reviewed", and a reviewer that failed, which is recorded rather than
# retried); 2 on usage or an unreadable task record.
#
# Test seams: FM_PSTACK_REVIEW_REVIEWER_CMD replaces the reviewer launch
# (called as <cmd> <harness> <model> <prompt-file> in the review checkout);
# FM_PSTACK_REVIEW_TASKS_CMD replaces bin/fm-tasks-axi.sh;
# FM_PSTACK_REVIEW_ROOT moves the disposable review checkouts.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CFG_FILE="$CONFIG/pstack-review.json"
TASKS_CMD="${FM_PSTACK_REVIEW_TASKS_CMD:-$SCRIPT_DIR/fm-tasks-axi.sh}"
REVIEW_ROOT="${FM_PSTACK_REVIEW_ROOT:-$HOME/.fm-pstack-review}"
POLICY_PATH=.agents/pstack-review.json

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-pstack-review.sh classify|start|run|status <task-id>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
CMD=$1
ID=$2
case "$CMD" in classify | start | run | status) ;; *) usage ;; esac
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid task id" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

META="$STATE/$ID.meta"
RESULT="$STATE/$ID.pstack-review"
LOCK="$STATE/$ID.pstack-review.lock"
LOG="$STATE/$ID.pstack-review.log"

meta() {  # <key>: last value of key in the task record
  sed -n "s/^$1=//p" "$META" | tail -n 1
}

if [ "$CMD" = status ]; then
  if [ -f "$RESULT" ]; then cat "$RESULT"; elif [ -d "$LOCK" ]; then echo "status=running"; else echo "status=none"; fi
  exit 0
fi

if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 2
fi
PROJECT=$(meta project)
WT=$(meta worktree)
HARNESS=$(meta harness)
MODEL=$(meta model)
PR_URL=$(meta pr)
if [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ]; then
  echo "error: task records no readable project" >&2
  exit 2
fi
PROJECT_NAME=$(basename "$PROJECT")

enabled() {
  [ -f "$CFG_FILE" ] && jq -e --arg p "$PROJECT_NAME" '(.projects // []) | index($p) != null' "$CFG_FILE" >/dev/null 2>&1
}
cfg() {  # <jq path> <default>
  local v=
  [ -f "$CFG_FILE" ] && v=$(jq -r "$1 // empty" "$CFG_FILE" 2>/dev/null)
  printf '%s\n' "${v:-$2}"
}

if ! enabled; then
  echo "pstack-review: off for $PROJECT_NAME (not listed in config/pstack-review.json)"
  exit 0
fi

HEAD_SHA=$(meta pr_head)
if [ -z "$HEAD_SHA" ] && [ -n "$WT" ] && [ -d "$WT" ]; then
  HEAD_SHA=$(git -C "$WT" rev-parse --verify --quiet HEAD 2>/dev/null) || HEAD_SHA=
fi
if [ -z "$HEAD_SHA" ] || ! git -C "$PROJECT" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null; then
  echo "error: no reviewable head commit for $ID" >&2
  exit 2
fi

policy() {  # <jq path>: values from the policy file at the PR head, one per line
  git -C "$PROJECT" show "$HEAD_SHA:$POLICY_PATH" 2>/dev/null | jq -r "$1 // empty" 2>/dev/null
}

BASE_BRANCH=$(policy '.base_branch')
BASE_BRANCH=${BASE_BRANCH:-main}

resolve_base() {
  local ref
  git -C "$PROJECT" fetch --quiet origin "$BASE_BRANCH" >/dev/null 2>&1 || true
  for ref in "origin/$BASE_BRANCH" "$BASE_BRANCH"; do
    if git -C "$PROJECT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
      git -C "$PROJECT" merge-base "$ref" "$HEAD_SHA" 2>/dev/null && return 0
    fi
  done
  return 1
}

matches_any() {  # <path> <patterns...>
  local path=$1 pat
  shift
  for pat in "$@"; do
    # shellcheck disable=SC2053
    [[ $path == $pat ]] && return 0
  done
  return 1
}

classify() {  # sets TIER and REASON from the diff BASE_SHA..HEAD_SHA
  local files=() tap=() skip=() f all_skip=1 n=0
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(git -C "$PROJECT" diff --name-only "$BASE_SHA" "$HEAD_SHA")
  while IFS= read -r f; do [ -n "$f" ] && tap+=("$f"); done < <(policy '.tap[]?')
  while IFS= read -r f; do [ -n "$f" ] && skip+=("$f"); done < <(policy '.skip[]?')
  if [ "${#files[@]}" -eq 0 ]; then
    TIER=skip
    REASON="no changed files"
    return
  fi
  for f in "${files[@]}"; do
    n=$((n + 1))
    if [ "${#tap[@]}" -gt 0 ] && matches_any "$f" "${tap[@]}"; then
      TIER=tap
      REASON="$f matches a tap pattern"
      return
    fi
    if [ "${#skip[@]}" -eq 0 ] || ! matches_any "$f" "${skip[@]}"; then all_skip=0; fi
  done
  if [ "$all_skip" = 1 ]; then
    TIER=skip
    REASON="all $n changed files match skip patterns"
  else
    TIER=review
    REASON="$n changed files, none on a tap pattern"
  fi
}

builder_vendor() {
  case "$HARNESS" in
    claude) echo anthropic ;;
    codex) echo openai ;;
    grok) echo xai ;;
    *)
      case "$MODEL" in
        openai*/* | gpt*) echo openai ;;
        xai/* | grok*) echo xai ;;
        anthropic/* | claude*) echo anthropic ;;
        *) echo default ;;
      esac
      ;;
  esac
}

pick_reviewer() {  # sets R_HARNESS R_MODEL R_EFFORT
  local v
  v=$(builder_vendor)
  case "$v" in
    anthropic) R_HARNESS=pi R_MODEL=openai-codex/gpt-6-sol R_EFFORT=high ;;
    *) R_HARNESS=claude R_MODEL=claude-sonnet-5-5 R_EFFORT=high ;;
  esac
  R_HARNESS=$(cfg ".reviewers.\"$v\".harness" "$R_HARNESS")
  R_MODEL=$(cfg ".reviewers.\"$v\".model" "$R_MODEL")
  R_EFFORT=$(cfg ".reviewers.\"$v\".effort" "$R_EFFORT")
}

if [ -f "$RESULT" ] && [ "$CMD" != classify ]; then
  echo "pstack-review: $ID already had its one pass ($(sed -n 's/^status=//p' "$RESULT"))"
  exit 0
fi

BASE_SHA=$(resolve_base) || { echo "error: cannot find the merge base with $BASE_BRANCH" >&2; exit 2; }
classify

if [ "$CMD" = classify ]; then
  echo "tier=$TIER reason=$REASON"
  exit 0
fi

if [ "$CMD" = start ]; then
  if [ -d "$LOCK" ]; then
    echo "pstack-review: $ID review already running (log $LOG)"
    exit 0
  fi
  if [ "$TIER" = skip ]; then
    printf 'status=skipped\ntier=skip\nreason=%s\nbase=%s\nhead=%s\nfinished_at=%s\n' "$REASON" "$BASE_SHA" "$HEAD_SHA" "$(date +%s)" > "$RESULT"
    echo "pstack-review: $ID skipped ($REASON)"
    exit 0
  fi
  FM_HOME="$FM_HOME" FM_PSTACK_REVIEW_BASE="$BASE_SHA" nohup "$SCRIPT_DIR/fm-pstack-review.sh" run "$ID" > "$LOG" 2>&1 < /dev/null &
  echo "pstack-review: $ID tier=$TIER, one pass started (log $LOG)"
  exit 0
fi

# run: the one pass. A recorded base from start wins, so a merge that lands
# before the reviewer starts does not empty the diff.
BASE_SHA=${FM_PSTACK_REVIEW_BASE:-$BASE_SHA}
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "pstack-review: $ID review already running"
  exit 0
fi
RDIR="$REVIEW_ROOT/$ID"
PROMPT="$LOCK/prompt.md"
OUT="$LOCK/reviewer.out"
# shellcheck disable=SC2329 # EXIT trap owns cleanup.
cleanup() {
  if [ -d "$RDIR" ]; then
    git -C "$PROJECT" worktree remove --force "$RDIR" >/dev/null 2>&1 || rm -rf "$RDIR"
  fi
  rm -rf "$LOCK"
}
trap cleanup EXIT

record() {  # <status> [extra key=value lines]
  local status=$1
  shift
  {
    printf 'status=%s\ntier=%s\nreason=%s\nbase=%s\nhead=%s\n' "$status" "$TIER" "$REASON" "$BASE_SHA" "$HEAD_SHA"
    printf 'reviewer=%s/%s\nbuilder=%s/%s\n' "$R_HARNESS" "$R_MODEL" "$HARNESS" "$MODEL"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
    printf 'finished_at=%s\n' "$(date +%s)"
  } > "$RESULT"
}

if [ "$TIER" = skip ]; then
  R_HARNESS=none R_MODEL=none
  record skipped
  echo "pstack-review: $ID skipped ($REASON)"
  exit 0
fi

pick_reviewer
mkdir -p "$REVIEW_ROOT"
rm -rf "$RDIR"
git -C "$PROJECT" worktree prune >/dev/null 2>&1 || true
if ! git -C "$PROJECT" worktree add --quiet --detach "$RDIR" "$HEAD_SHA" >/dev/null 2>&1; then
  record error "detail=could not create the review checkout"
  echo "pstack-review: $ID error: could not create the review checkout"
  exit 0
fi

cat > "$PROMPT" <<PROMPT_EOF
You are the single pstack review pass for firstmate task $ID${PR_URL:+ (PR $PR_URL)}.
The builder was $HARNESS/$MODEL; you are a different vendor on purpose.

Scope: the change from $BASE_SHA to $HEAD_SHA in this checkout
(\`git diff $BASE_SHA $HEAD_SHA\`, commits from \`git log $BASE_SHA..$HEAD_SHA\`).

Work as pstack's interrogate skill describes, as its ONLY adversary: no fan-out,
no sub-agents, no arena.
1. Intent: restate in two sentences what the change is meant to do, from the commits.
2. Break this change. Prove each finding with a run against the real code, such as
   a failing test, a repro script, or command output that shows the wrong behavior.
   Report each finding with a title, the exact command, the output it printed, and the
   output the intent requires. Leave out anything you did not run. That covers style,
   naming, structure, and risks that need a future change to matter.
3. Verify: rerun each finding's command. Keep it only when the output shows the failure
   and the failure breaks the intent. Merge findings that share a root cause.

Rules:
- Do not edit tracked files, commit, push, open or merge pull requests, or message anyone.
  Do not apply fixes. Keep any repro script under an untracked scratch folder here.
- Follow this repository's AGENTS.md for how tests are run (test slots, private databases;
  never the shared demo or live copy). Install dependencies first if the checkout lacks them.
- One pass only. No findings is a valid result.

End your reply with exactly these three parts and nothing after them:
PSTACK_REVIEW_JSON_BEGIN
{"intent": "...", "findings": [{"title": "...", "severity": "high|medium|low", "command": "...", "output": "...", "expected": "...", "breaks": "..."}], "dropped": 0}
PSTACK_REVIEW_JSON_END
PROMPT_EOF

launch_reviewer() {
  if [ -n "${FM_PSTACK_REVIEW_REVIEWER_CMD:-}" ]; then
    "$FM_PSTACK_REVIEW_REVIEWER_CMD" "$R_HARNESS" "$R_MODEL" "$PROMPT"
    return
  fi
  case "$R_HARNESS" in
    claude)
      claude -p --model "$R_MODEL" --permission-mode bypassPermissions \
        --disallowedTools Edit Write NotebookEdit --output-format text < "$PROMPT"
      ;;
    pi)
      pi -p --model "$R_MODEL" --thinking "$R_EFFORT" --no-session --approve \
        --exclude-tools edit,write "$(cat "$PROMPT")"
      ;;
    *)
      echo "unsupported reviewer harness $R_HARNESS" >&2
      return 2
      ;;
  esac
}

TIMEOUT=$(cfg '.timeout_seconds' 2400)
(cd "$RDIR" && launch_reviewer) > "$OUT" 2>&1 &
RPID=$!
waited=0
while kill -0 "$RPID" 2>/dev/null; do
  if [ "$waited" -ge "$TIMEOUT" ]; then
    kill "$RPID" 2>/dev/null || true
    sleep 2
    kill -9 "$RPID" 2>/dev/null || true
    break
  fi
  sleep 5
  waited=$((waited + 5))
done
wait "$RPID" 2>/dev/null
RRC=$?
cp "$OUT" "$STATE/$ID.pstack-review.out" 2>/dev/null || true

JSON=$(awk '/^PSTACK_REVIEW_JSON_BEGIN$/{buf=""; on=1; next} /^PSTACK_REVIEW_JSON_END$/{on=0; last=buf; next} on{buf=buf $0 "\n"} END{printf "%s", last}' "$OUT")
if [ -z "$JSON" ] || ! printf '%s' "$JSON" | jq -e '.findings | type == "array"' >/dev/null 2>&1; then
  record error "detail=reviewer exit $RRC after ${waited}s without a parseable result" "output=$STATE/$ID.pstack-review.out"
  echo "pstack-review: $ID error: no parseable reviewer result (exit $RRC); recorded, not retried"
  exit 0
fi

HOLD=$(cfg '.ticket_hold' captain)
COUNT=$(printf '%s' "$JSON" | jq '.findings | length')
TICKETS=()
i=0
while [ "$i" -lt "$COUNT" ]; do
  F=$(printf '%s' "$JSON" | jq -c ".findings[$i]")
  i=$((i + 1))
  TITLE=$(printf '%s' "$F" | jq -r '.title // "untitled finding"' | tr -d '()\n\r' | cut -c1-90)
  TID="rv-$ID-$i"
  BODY="$LOCK/ticket-$i.md"
  {
    printf 'pstack review finding from %s%s, head %s, reviewer %s/%s, severity %s.\n' \
      "$ID" "${PR_URL:+ PR $PR_URL}" "$HEAD_SHA" "$R_HARNESS" "$R_MODEL" "$(printf '%s' "$F" | jq -r '.severity // "unrated"')"
    printf 'Command: %s\n' "$(printf '%s' "$F" | jq -r '.command // ""' | tr '\n' ' ')"
    printf 'Printed: %s\n' "$(printf '%s' "$F" | jq -r '.output // ""' | tr '\n' ' ' | cut -c1-600)"
    printf 'Expected: %s\n' "$(printf '%s' "$F" | jq -r '.expected // ""' | tr '\n' ' ')"
    printf 'Breaks: %s\n' "$(printf '%s' "$F" | jq -r '.breaks // ""' | tr '\n' ' ')"
  } > "$BODY"
  if "$TASKS_CMD" add "$TID" "Review finding: $TITLE" --kind ship --repo "$PROJECT_NAME" --body-file "$BODY" >/dev/null 2>&1; then
    if [ "$HOLD" = captain ]; then
      "$TASKS_CMD" hold "$TID" --reason "pstack review finding from $ID, captain triage before any fix" --kind captain >/dev/null 2>&1 || true
    fi
    TICKETS+=("$TID")
  else
    TICKETS+=("unfiled:$i")
  fi
done

if [ "$COUNT" -eq 0 ]; then
  record clean "findings=0"
  echo "pstack-review: $ID clean, no verified findings"
else
  record findings "findings=$COUNT" "tickets=${TICKETS[*]}"
  echo "pstack-review: $ID $COUNT finding(s) filed: ${TICKETS[*]}"
fi
exit 0
