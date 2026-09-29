#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, Gerrit
# change, or CodeCommit pull request poll sidecar.
# It emits exactly one merged line for a merged change and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, and the AWS CLI for CodeCommit, so an upstream
# checkout needs no extra tooling to follow the first two. The Gerrit and
# CodeCommit branches additionally need jq, which bin/fm-pr-check.sh refuses to
# arm either watch without.
#
# CodeCommit needs one datum the URL cannot carry, the local AWS profile that
# selects its account's credentials. It arrives as a sixth validated field and
# is the only field that is not reconstructible from the identity, so it is
# accepted only for codecommit and only in the shape an AWS profile name takes.
# It is bound against tampering by the registration's hash of the whole sidecar,
# which bin/fm-pr-lib.sh checks before this program is ever reached.
#
# CodeCommit closes a pull request whether it was merged or abandoned, so its
# status can never be the merge signal. Only mergeMetadata.isMerged on the
# target whose repository matches the identity is read as merged.
set -u
LC_ALL=C
export LC_ALL

credential=
if [ "$#" -eq 7 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  credential=$7
elif [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r credential <&3; then
    if IFS= read -r _extra <&3; then
      exit 0
    fi
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Only codecommit may carry a credential, and it must carry a usable one. A
# profile name is never allowed to begin with "-", which the AWS CLI would read
# as another option rather than as the profile.
if [ "$provider" = codecommit ]; then
  [ "${#credential}" -ge 1 ] && [ "${#credential}" -le 128 ] || exit 0
  case "$credential" in
    -*|*[!A-Za-z0-9._@=,+-]*) exit 0 ;;
  esac
else
  [ -z "$credential" ] || exit 0
fi

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  codecommit)
    region=${host%.console.aws.amazon.com}
    [ "$host" = "$region.console.aws.amazon.com" ] || exit 0
    [ "${#region}" -ge 5 ] && [ "${#region}" -le 32 ] || exit 0
    # An AWS region is lowercase, hyphen-separated, starts with a letter and
    # ends with its numeric suffix. This poll is byte-static and sources
    # nothing, so it checks that shape itself rather than trusting the sidecar,
    # and a doctored one therefore cannot reach the AWS CLI with an
    # option-shaped or otherwise unsafe region argument. It is a shape check
    # and not a copy of fm_pr_codecommit_region_valid in bin/fm-pr-lib.sh,
    # which is the canonical rule and refuses region strings this shape check
    # accepts.
    case "$region" in
      *[!a-z0-9-]*|-*|*-|[!a-z]*|*[!0-9]|*--*) exit 0 ;;
    esac
    case "$region" in
      *-*) ;;
      *) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 100 ] || exit 0
    case "$path" in
      .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://$host/codesuite/codecommit/repositories/$path/pull-requests/$number?region=$region" ] || exit 0
    # jq reads one boolean out of the one target whose repository matches the
    # validated identity, so a pull request that also targets some other
    # repository can never supply this answer. Any missing or non-boolean field
    # makes jq fail, which stays silent exactly like an unreadable pull request.
    merged=$(aws codecommit get-pull-request \
      --pull-request-id "$number" \
      --region "$region" \
      --profile "$credential" \
      --output json 2>/dev/null \
      | jq -r --arg repo "$path" \
          '[.pullRequest.pullRequestTargets[]
             | select(.repositoryName == $repo)
             | .mergeMetadata.isMerged]
           | if length == 1 and (.[0] | type) == "boolean" then .[0] else error("no single target") end' \
          2>/dev/null) || exit 0
    [ "$merged" = true ] && printf '%s\n' merged
    ;;
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit 0
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
