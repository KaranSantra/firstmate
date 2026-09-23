# AWS CodeCommit pull request watch and merge verification

Empirical record for the merge watch and the merge path on AWS CodeCommit, alongside the existing GitHub and GitLab ones.
All evidence here was collected on 2026-09-04.
Identifiers in this record are redacted, not fabricated: every command and every output below was really run and really returned, and only the identifying values inside them were replaced.
The AWS account id reads `123456789012`, the repository reads `Example-Payments-Client`, the SSO instance id and the operator address in the merge ARN are placeholders, and the squash commit message is a stand-in for the real one.
Everything else - structure, field names, ordering, argv positions, and the shapes those values take - is reproduced exactly, which is what this record is evidence of.

## Versions

```
$ aws --version
aws-cli/2.34.9 Python/3.13.11 Darwin/25.6.0 exe/arm64

$ jq --version
jq-1.7.1-apple

$ bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
```

## The live subject

Every read below is against a real, private repository in `us-east-1`, shown here under the redacted name `Example-Payments-Client`.
Pull request 27 was open and unmerged throughout, and pull request 26 was already merged before this work began.
No merge was performed against either during this verification; the one merge attempt was deliberately blocked and is shown below.

## Why the status is never the merge signal

CodeCommit closes a pull request whether it was merged or abandoned, so `pullRequestStatus` alone cannot distinguish the two.
Only `mergeMetadata.isMerged` can, and only on the target whose repository matches the identity.
Pull request 26 shows the merged shape:

```
$ aws codecommit get-pull-request --pull-request-id 26 --region us-east-1 \
    --profile AWSAdministratorAccess-123456789012 \
  | jq '{status:.pullRequest.pullRequestStatus, targets:[.pullRequest.pullRequestTargets[]|{repositoryName,sourceCommit,mergeMetadata}]}'
{
  "status": "CLOSED",
  "targets": [
    {
      "repositoryName": "Example-Payments-Client",
      "sourceCommit": "1c0829bc4f2076dc5d08ce409b5b503bcd9eab60",
      "mergeMetadata": {
        "isMerged": true,
        "mergedBy": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AWSAdministratorAccess_0123456789abcdef/user@example.com",
        "mergeCommitId": "17d50b90965a8becffe9b042199547a579a9b1db",
        "mergeOption": "THREE_WAY_MERGE"
      }
    }
  ]
}
```

`CLOSED` is what a merged and an abandoned pull request have in common, which is why `bin/fm-pr-poll.sh` and `bin/fm-pr-merge.sh` read `isMerged` and nothing else.

## Where the AWS profile comes from

No CodeCommit URL carries the credentials for its account.
The `git-remote-codecommit` helper records the profile as the userinfo of the remote, which is the only place it is written:

```
$ git -C projects/Example-Payments-Client remote -v
origin	codecommit::us-east-1://AWSAdministratorAccess-123456789012@Example-Payments-Client (fetch)
origin	codecommit::us-east-1://AWSAdministratorAccess-123456789012@Example-Payments-Client (push)
```

The default credential chain is unauthenticated on this machine, so falling back to it would arm a watch that can only fail.
`bin/fm-pr-check.sh` and `bin/fm-pr-merge.sh` therefore refuse when no profile can be derived, and both require the remote to name the same repository, and the same region when it pins one, as the URL.
A derivable profile is not proof of a working one, so arming reads the pull request with it before publishing anything: a profile that cannot read the pull request refuses non-zero with the `aws sso login` remedy and leaves no check, sidecar, or registration behind, rather than dropping `pr_head` and reporting a watch that can never fire.
A read that succeeds but returns a pull request targeting another repository refuses separately, naming the repository it actually targets, because that session is authenticated and re-authenticating it would send the operator in circles.

## The poll, against both live pull requests

The watcher's `--validated` entry point, run against the open pull request 27 and the merged pull request 26, plus three cases that must stay silent:

```
$ BASE='https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Example-Payments-Client/pull-requests'
$ P=AWSAdministratorAccess-123456789012

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/27?region=us-east-1" \
    us-east-1.console.aws.amazon.com Example-Payments-Client 27 "$P"

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/26?region=us-east-1" \
    us-east-1.console.aws.amazon.com Example-Payments-Client 26 "$P"
merged

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/26?region=us-east-1" \
    us-east-1.console.aws.amazon.com Example-Payments-Client 26 no-such-profile

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/26?region=us-east-1" \
    us-east-1.console.aws.amazon.com Example-Payments-Client 27 "$P"

$ bin/fm-pr-poll.sh --validated github https://github.com/o/r/pull/1 github.com o/r 1 "$P"
```

The open pull request, an unusable profile, an identity whose parts do not reconstruct the stored URL, and a non-CodeCommit record carrying a credential all print nothing.
Only the merged pull request prints `merged`.

The self-read path, which reads the sidecar rather than taking validated arguments, agrees:

```
$ bash <armed check.sh for the open pull request 27>

$ bash <armed check.sh retargeted to the merged pull request 26>
merged
```

## Arming, and the static poll

Arming records the canonical URL and the exact head, and publishes a check that is byte-for-byte the shipped source:

```
$ grep -E '^pr=|^pr_head=' <state>/task-cc.meta
pr=https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Example-Payments-Client/pull-requests/27?region=us-east-1
pr_head=6eb630be7f28c293debcd02391621d75479595ba

$ cat <state>/task-cc.pr-poll
codecommit
https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Example-Payments-Client/pull-requests/27?region=us-east-1
us-east-1.console.aws.amazon.com
Example-Payments-Client
27
AWSAdministratorAccess-123456789012

$ cmp -s bin/fm-pr-poll.sh <state>/task-cc.check.sh && echo IDENTICAL
IDENTICAL
```

The sixth line is the profile.
It is the only field that is not reconstructible from the identity, so it is accepted only for a codecommit record, and the registration's hash of the whole sidecar is what binds it against tampering.
A GitHub or GitLab sidecar carries no sixth line at all and is byte-identical to one written before CodeCommit existed, so no already-published sidecar was invalidated.
That is not the same as needing no re-arming: this change also edits `bin/fm-pr-poll.sh`, and `fm_pr_poll_artifacts_valid` compares every armed check against the shipped poll source byte for byte, so every poll armed before the upgrade - on every provider - fails that comparison once and stays rejected until `bin/fm-pr-check.sh` arms it again.
That follows from editing the byte-static poll source at all and is not specific to CodeCommit.

## The merge path, with the merge itself blocked

The full merge path was run against the live pull request 27 behind an `aws` shim that proxies read-only calls to the real CLI and refuses every write.
This exercises the whole path, including the merge command's exact construction, without merging real unmerged work:

```
$ FM_ROOT_OVERRIDE=$PWD FM_HOME=<sandbox> FM_STATE_OVERRIDE=<state> PATH=<shim>:$PATH \
    bin/fm-pr-merge.sh task-cc \
    'https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Example-Payments-Client/pull-requests/27?region=us-east-1'
armed: state/task-cc.check.sh
verified: https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Example-Payments-Client/pull-requests/27?region=us-east-1 is open, approved, and conflict-free at head 6eb630be7f28c293debcd02391621d75479595ba
GUARD: refused write operation merge-pull-request-by-squash
```

The AWS calls it made, in order:

```
codecommit get-pull-request --pull-request-id 27 --region us-east-1 --profile AWSAdministratorAccess-123456789012 --output json
codecommit get-pull-request --pull-request-id 27 --region us-east-1 --profile AWSAdministratorAccess-123456789012 --output json
codecommit evaluate-pull-request-approval-rules --pull-request-id 27 --revision-id 1c116fa3c931887c16fda82c53f0188559b5ca99f8734ddb85c8e00b2416fee9 --region us-east-1 --profile AWSAdministratorAccess-123456789012 --output json
codecommit get-merge-conflicts --repository-name Example-Payments-Client --source-commit-specifier 6eb630be7f28c293debcd02391621d75479595ba --destination-commit-specifier refs/heads/main --merge-option SQUASH_MERGE --region us-east-1 --profile AWSAdministratorAccess-123456789012 --output json
codecommit merge-pull-request-by-squash --pull-request-id 27 --repository-name Example-Payments-Client --source-commit-id 6eb630be7f28c293debcd02391621d75479595ba --commit-message Example squash message: scaffold + plan 01-01 (schema, migrations, seed) --region us-east-1 --profile AWSAdministratorAccess-123456789012 --output json
```

The `merge-pull-request-by-squash` line above predates commit 8e49224 and is left exactly as it was captured.
That commit changed how the commit message is carried: the shipped code now emits `--commit-message=VALUE` as a single token, rather than `--commit-message` followed by a separate value token as the capture shows, so a run today logs that one position in the single-token form.
Read the argv reasoning below against that current form; `git show 8e49224` is the change itself.

The region and profile are on every call, taken from the URL and the remote rather than any ambient default.
The conflict read asks for the same `SQUASH_MERGE` the merge itself uses.
`--source-commit-id` carries the head that was just verified, so a push landing between the read and the merge is refused by CodeCommit instead of merged unverified, exactly as `--sha` does on GitLab.

The subject was unchanged by the run:

```
$ aws codecommit get-pull-request --pull-request-id 27 --region us-east-1 \
    --profile AWSAdministratorAccess-123456789012 \
  | jq '{status:.pullRequest.pullRequestStatus, isMerged:.pullRequest.pullRequestTargets[0].mergeMetadata.isMerged}'
{
  "status": "OPEN",
  "isMerged": false
}
```

## What the live evidence does not cover

A merge that actually lands was not run against a real repository, because the only CodeCommit pull request available was real unmerged work that had not been authorized for merging.
The merge command's construction is proven above for the default squash method only; the other two methods, the outcome read that follows the merge, and the refusal when that read cannot prove a merge, are proven by test double in `tests/fm-pr-merge.test.sh`.

## The console's several spellings, normalised to one

Added 2026-09-08.
The console reaches one pull request by more than one address: its own address bar carries a `/details` segment, and a link shortened by hand drops the `?region=` query.
Accepting only the canonical spelling refused most real links, including the ones firstmate's own workers report, so each spelling is now accepted and rewritten to the single stored form before any consumer sees it.

```
$ B='https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Example-Payments-Client/pull-requests'
$ . bin/fm-pr-lib.sh
$ for u in "$B/26?region=us-east-1" "$B/26/details?region=us-east-1" "$B/26/details" "$B/26" "$B/26?region=eu-west-1"; do
    fm_pr_url_parse "$u" && printf '%s\n  -> %s\n' "$u" "$FM_PR_URL" || printf '%s\n  -> REFUSED\n' "$u"
  done
.../pull-requests/26?region=us-east-1
  -> .../pull-requests/26?region=us-east-1
.../pull-requests/26/details?region=us-east-1
  -> .../pull-requests/26?region=us-east-1
.../pull-requests/26/details
  -> .../pull-requests/26?region=us-east-1
.../pull-requests/26
  -> .../pull-requests/26?region=us-east-1
.../pull-requests/26?region=eu-west-1
  -> REFUSED
```

A query naming a region the host does not is still refused rather than resolved to the host's, and the canonical form re-parses to itself.

Normalising is what makes accepting those spellings safe rather than merely permissive.
`bin/fm-pr-poll.sh` is byte-static and rebuilds the URL from the stored parts, so a stored `/details` URL would arm a watch that never matches and therefore never reports the merge - silently worse than refusing the link.
The poll is unchanged by this work, and it still answers on the stored canonical form for the already-merged pull request 26:

```
$ bin/fm-pr-poll.sh --validated codecommit "$B/26?region=us-east-1" \
    us-east-1.console.aws.amazon.com Example-Payments-Client 26 AWSAdministratorAccess-123456789012
merged
```

`tests/fm-pr-check-security.test.sh` carries the regression as "every console spelling of a CodeCommit pull request arms one canonical watch", which arms a separate task from each spelling and drives the real poll to `merged` for each, so a spelling that were accepted without being normalised would fail there rather than in production.

## Refreshing this record

```
bin/fm-test-run.sh tests/fm-pr-merge.test.sh tests/fm-pr-check-security.test.sh
```

Those two suites carry the CodeCommit URL matrix, the arming and static-poll contract, the arming refusals for a profile that cannot read the pull request and for a pull request belonging to another repository, an option-shaped pull request title reaching the merge intact, the pre-merge conditions, and the refusal on an unproven merge.
They also carry, by test double, the poll's merge detection on both of its entry points - printing `merged` only for `isMerged` on this repository's own target, and staying silent on an open pull request, a closed but unmerged one, a failed AWS call, a foreign target, and a doctored sidecar - and each accepted merge method's own API paired with the `--merge-option` its conflict read is judged under, with the commit message present or absent as that API takes it.
The live reads above need an authenticated AWS profile and a CodeCommit repository, so they are refreshed by hand when the AWS CLI or the CodeCommit API changes.
