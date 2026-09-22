#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL, a GitLab merge request URL, and an AWS CodeCommit
# console pull request URL are all accepted, including a merge request on a
# self-hosted GitLab instance.
# A GitHub pull request the forge reports as a draft is refused, naming the draft
# state and recording and arming nothing: a draft cannot be merged, so a poll armed on it
# would wait for an event that cannot occur while nobody is asked to act.
# Mark the pull request ready for review, then arm again; a lane that keeps a
# draft on purpose declares a wait instead of reporting done. An unreadable
# draft state does not refuse, matching how the head read below is optional.
# bin/fm-pr-merge.sh records through this script with FM_PR_CHECK_MERGE=1 and
# skips this refusal, because its own merge-time draft refusal is authoritative.
#
# A CodeCommit poll additionally needs the local AWS profile that selects its
# account's credentials, which no URL carries. It is read out of the task
# worktree's own git remote, where the git-remote-codecommit helper records it,
# and never guessed: the default credential chain is exactly what that profile
# exists to override, so falling back to it would arm a watch that can only
# fail. The profile is stored in the same private sidecar as the identity and
# is never interpolated into shell source.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
REGION=$FM_PR_REGION

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# The same reasoning applies to CodeCommit, which needs both tools and, unlike
# the other two forges, a profile that only the repository's own remote records.
CREDENTIAL=
if [ "$PROVIDER" = codecommit ]; then
  CODECOMMIT_MISSING=
  command -v aws >/dev/null 2>&1 || CODECOMMIT_MISSING="the AWS CLI"
  if ! command -v jq >/dev/null 2>&1; then
    CODECOMMIT_MISSING="${CODECOMMIT_MISSING:+$CODECOMMIT_MISSING and }jq"
  fi
  if [ -n "$CODECOMMIT_MISSING" ]; then
    echo "error: watching a CodeCommit pull request requires $CODECOMMIT_MISSING on PATH" >&2
    exit 1
  fi
fi

# The draft state is read before anything is recorded or armed. Only a positive
# draft reading refuses, because an unreadable one must not block arming.
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DRAFT_JSON=$(gh pr view "$URL" --json isDraft 2>/dev/null || true)
  if [ "$(fm_pr_json_draft_state "$DRAFT_JSON")" = true ]; then
    echo "error: $URL is a draft pull request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate" >&2
    exit 1
  fi
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# For GitHub, pr_head is recorded only when the forge's CLI can supply it. gh
# exposes the head commit as a selectable field, and CodeCommit names it on the
# pull request's own target and requires it (below); plain glab exposes it only
# inside its JSON output, which
# would need a JSON processor firstmate does not require, so a GitLab task
# records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)

# The CodeCommit profile is a prerequisite, not a best effort: without it the
# poll cannot authenticate at all, so an underivable profile stops the watch
# here rather than arming one that is silent for the wrong reason.
if [ "$PROVIDER" = codecommit ]; then
  REMOTE_URL=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    REMOTE_URL=$(git -C "$WT" remote get-url origin 2>/dev/null || true)
  fi
  if [ -z "$REMOTE_URL" ]; then
    echo "error: could not read the origin remote of the task worktree, so the AWS profile for $URL is unknown" >&2
    exit 1
  fi
  if ! fm_pr_codecommit_remote_profile "$REMOTE_URL" "$PROJECT_PATH" "$REGION"; then
    echo "error: the origin remote of the task worktree names no AWS profile for repository $PROJECT_PATH in $REGION" >&2
    exit 1
  fi
  CREDENTIAL=$FM_PR_CREDENTIAL
fi

PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi
# CodeCommit names the head commit of every pull request target, so the exact
# head is recorded here the way GitHub's is. Unlike GitHub's, this read is a
# prerequisite rather than a best effort: it is the only proof that the profile
# the remote names is actually authenticated, and a shape-valid profile whose
# SSO session has expired is indistinguishable from a working one until the
# poll runs. A watch that reports itself armed but can never fire silently
# disables merging green work autonomously and nothing ever surfaces it, which
# is exactly the failure this file's header says the profile requirement exists
# to prevent. The trade is accepted deliberately: a transient AWS outage now
# refuses to arm rather than arming headless, because a refusal is loud,
# immediate, and recovered by re-running this script, while a dead watch stays
# quiet until a human notices work never merged.
# A read that fails and a read that succeeds for another repository leave the
# operator somewhere different, so they are reported apart the way the missing
# tool, the unreadable remote, and the underivable profile above already are.
if [ "$PROVIDER" = codecommit ]; then
  CC_PR_JSON=
  CC_PR_TARGETS=
  REMOTE_HEAD=
  if ! CC_PR_JSON=$(aws codecommit get-pull-request --pull-request-id "$NUMBER" \
      --region "$REGION" --profile "$CREDENTIAL" --output json 2>/dev/null) \
    || [ -z "$CC_PR_JSON" ] \
    || ! CC_PR_TARGETS=$(printf '%s' "$CC_PR_JSON" | jq -r \
          'if type == "object" then
             [(.pullRequest // error("no pull request")).pullRequestTargets[]?
              | .repositoryName // empty]
             | join(", ")
           else
             error("pull request payload is not an object")
           end' 2>/dev/null); then
    echo "error: could not read CodeCommit pull request $NUMBER in $REGION with AWS profile $CREDENTIAL; re-authenticate that profile's SSO session (aws sso login --profile $CREDENTIAL) and re-run bin/fm-pr-check.sh" >&2
    exit 1
  fi
  if ! REMOTE_HEAD=$(printf '%s' "$CC_PR_JSON" | jq -r --arg repo "$PROJECT_PATH" \
        '[.pullRequest.pullRequestTargets[]
           | select(.repositoryName == $repo)
           | .sourceCommit]
         | if length == 1 then .[0] else error("no single target") end' 2>/dev/null); then
    echo "error: CodeCommit pull request $NUMBER was read but does not target repository $PROJECT_PATH; it targets ${CC_PR_TARGETS:-no repository}, so the URL names the wrong repository" >&2
    exit 1
  fi
  if ! fm_pr_head_valid "$REMOTE_HEAD"; then
    echo "error: CodeCommit pull request $NUMBER names no valid head commit for repository $PROJECT_PATH" >&2
    exit 1
  fi
  PR_HEAD=$REMOTE_HEAD
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" "$CREDENTIAL" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if fm_pr_poll_publish_prepared; then
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
