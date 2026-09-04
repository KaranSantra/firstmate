# AWS CodeCommit pull request watch and merge verification

Empirical record for the merge watch and the merge path on AWS CodeCommit, alongside the existing GitHub and GitLab ones.
All evidence here was collected on 2026-09-04.
Every output is reproduced exactly, with the AWS account id left as it appears because it is already part of the profile name the remote records.

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

Every read below is against `Modus-Adyen-Client` in `us-east-1`, a real repository.
Pull request 27 was open and unmerged throughout, and pull request 26 was already merged before this work began.
No merge was performed against either during this verification; the one merge attempt was deliberately blocked and is shown below.

## Why the status is never the merge signal

CodeCommit closes a pull request whether it was merged or abandoned, so `pullRequestStatus` alone cannot distinguish the two.
Only `mergeMetadata.isMerged` can, and only on the target whose repository matches the identity.
Pull request 26 shows the merged shape:

```
$ aws codecommit get-pull-request --pull-request-id 26 --region us-east-1 \
    --profile AWSAdministratorAccess-776781950322 \
  | jq '{status:.pullRequest.pullRequestStatus, targets:[.pullRequest.pullRequestTargets[]|{repositoryName,sourceCommit,mergeMetadata}]}'
{
  "status": "CLOSED",
  "targets": [
    {
      "repositoryName": "Modus-Adyen-Client",
      "sourceCommit": "1c0829bc4f2076dc5d08ce409b5b503bcd9eab60",
      "mergeMetadata": {
        "isMerged": true,
        "mergedBy": "arn:aws:sts::776781950322:assumed-role/AWSReservedSSO_AWSAdministratorAccess_c26186d46988e4fd/Karan@pateam.co",
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
$ git -C projects/Modus-Adyen-Client remote -v
origin	codecommit::us-east-1://AWSAdministratorAccess-776781950322@Modus-Adyen-Client (fetch)
origin	codecommit::us-east-1://AWSAdministratorAccess-776781950322@Modus-Adyen-Client (push)
```

The default credential chain is unauthenticated on this machine, so falling back to it would arm a watch that can only fail.
`bin/fm-pr-check.sh` and `bin/fm-pr-merge.sh` therefore refuse when no profile can be derived, and both require the remote to name the same repository, and the same region when it pins one, as the URL.

## The poll, against both live pull requests

The watcher's `--validated` entry point, run against the open pull request 27 and the merged pull request 26, plus three cases that must stay silent:

```
$ BASE='https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Modus-Adyen-Client/pull-requests'
$ P=AWSAdministratorAccess-776781950322

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/27?region=us-east-1" \
    us-east-1.console.aws.amazon.com Modus-Adyen-Client 27 "$P"

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/26?region=us-east-1" \
    us-east-1.console.aws.amazon.com Modus-Adyen-Client 26 "$P"
merged

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/26?region=us-east-1" \
    us-east-1.console.aws.amazon.com Modus-Adyen-Client 26 no-such-profile

$ bin/fm-pr-poll.sh --validated codecommit "$BASE/26?region=us-east-1" \
    us-east-1.console.aws.amazon.com Modus-Adyen-Client 27 "$P"

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
pr=https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Modus-Adyen-Client/pull-requests/27?region=us-east-1
pr_head=6eb630be7f28c293debcd02391621d75479595ba

$ cat <state>/task-cc.pr-poll
codecommit
https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Modus-Adyen-Client/pull-requests/27?region=us-east-1
us-east-1.console.aws.amazon.com
Modus-Adyen-Client
27
AWSAdministratorAccess-776781950322

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
    'https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Modus-Adyen-Client/pull-requests/27?region=us-east-1'
armed: state/task-cc.check.sh
verified: https://us-east-1.console.aws.amazon.com/codesuite/codecommit/repositories/Modus-Adyen-Client/pull-requests/27?region=us-east-1 is open, approved, and conflict-free at head 6eb630be7f28c293debcd02391621d75479595ba
GUARD: refused write operation merge-pull-request-by-squash
```

The AWS calls it made, in order:

```
codecommit get-pull-request --pull-request-id 27 --region us-east-1 --profile AWSAdministratorAccess-776781950322 --output json
codecommit get-pull-request --pull-request-id 27 --region us-east-1 --profile AWSAdministratorAccess-776781950322 --output json
codecommit evaluate-pull-request-approval-rules --pull-request-id 27 --revision-id 1c116fa3c931887c16fda82c53f0188559b5ca99f8734ddb85c8e00b2416fee9 --region us-east-1 --profile AWSAdministratorAccess-776781950322 --output json
codecommit get-merge-conflicts --repository-name Modus-Adyen-Client --source-commit-specifier 6eb630be7f28c293debcd02391621d75479595ba --destination-commit-specifier refs/heads/main --merge-option SQUASH_MERGE --region us-east-1 --profile AWSAdministratorAccess-776781950322 --output json
codecommit merge-pull-request-by-squash --pull-request-id 27 --repository-name Modus-Adyen-Client --source-commit-id 6eb630be7f28c293debcd02391621d75479595ba --commit-message Phase 1 Wave 1: application scaffold + plan 01-01 (domain schema, migrations, seed) --region us-east-1 --profile AWSAdministratorAccess-776781950322 --output json
```

The region and profile are on every call, taken from the URL and the remote rather than any ambient default.
The conflict read asks for the same `SQUASH_MERGE` the merge itself uses.
`--source-commit-id` carries the head that was just verified, so a push landing between the read and the merge is refused by CodeCommit instead of merged unverified, exactly as `--sha` does on GitLab.

The subject was unchanged by the run:

```
$ aws codecommit get-pull-request --pull-request-id 27 --region us-east-1 \
    --profile AWSAdministratorAccess-776781950322 \
  | jq '{status:.pullRequest.pullRequestStatus, isMerged:.pullRequest.pullRequestTargets[0].mergeMetadata.isMerged}'
{
  "status": "OPEN",
  "isMerged": false
}
```

## What the live evidence does not cover

A merge that actually lands was not run against a real repository, because the only CodeCommit pull request available was real unmerged work that had not been authorized for merging.
The merge command's construction is proven above; the outcome read that follows it, and the refusal when that read cannot prove a merge, are proven by test double in `tests/fm-pr-merge.test.sh`.

## Refreshing this record

```
bin/fm-test-run.sh tests/fm-pr-merge.test.sh tests/fm-pr-check-security.test.sh
```

Those two suites carry the CodeCommit URL matrix, the arming and static-poll contract, the pre-merge conditions, and the refusal on an unproven merge.
The live reads above need an authenticated AWS profile and a CodeCommit repository, so they are refreshed by hand when the AWS CLI or the CodeCommit API changes.
