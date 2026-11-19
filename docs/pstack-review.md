# One-pass pstack review

This page describes the optional review that runs beside a PR-based ship, once per change, using the review rules from poteto's pstack plugin.
It is for operators deciding whether to turn it on for a project, and for maintainers of `bin/fm-pstack-review.sh`.

It replaces an open-ended automated reviewer, whose rounds of findings kept merges waiting, with three fixed rules:

- Each change gets exactly one review pass, never a second one, even after the branch moves.
- The review never blocks or delays a merge. Each verified finding becomes a backlog ticket held for the captain, so no fix round starts by itself.
- A finding counts only when the reviewer proves it with a run, following pstack's `interrogate` skill as its only adversary.

## Turning it on

Nothing runs until the home's `config/pstack-review.json` lists the project by the basename of its directory.
`config/` is per-home and untracked, so this is the switch:

```json
{
  "projects": ["Modus-Adyen-Client"],
  "timeout_seconds": 2400,
  "ticket_hold": "captain",
  "reviewers": {
    "anthropic": { "harness": "pi", "model": "openai-codex/gpt-6-sol", "effort": "high" },
    "openai": { "harness": "claude", "model": "claude-sonnet-5-5" },
    "xai": { "harness": "claude", "model": "claude-sonnet-5-5" },
    "default": { "harness": "claude", "model": "claude-sonnet-5-5" }
  }
}
```

Only `projects` is required; the other keys show the built-in defaults.
`ticket_hold` set to `none` leaves findings as ordinary queued work that ordinary dispatch may pick up.

## Tiers from the project's policy

The project owns which changes are low-risk and which ones touch money or access, in `.agents/pstack-review.json`, read from the PR head:

```json
{
  "base_branch": "main",
  "skip": ["docs/*", "*.md"],
  "tap": ["src/lib/payments/*", "src/lib/auth*"]
}
```

Patterns are bash `[[ == ]]` globs, where `*` also crosses `/`.

| Tier | When | Review | Merge |
| --- | --- | --- | --- |
| `skip` | Every changed path matches a `skip` pattern | None | Unchanged |
| `review` | Default | One pass | Unchanged: the delivery path's checks and merge authority decide |
| `tap` | Any changed path matches a `tap` pattern | One pass | Waits for the captain whatever `yolo` says |

A project without the file gets `review` for every change.

## Who reviews

The reviewer is always another vendor than the builder recorded in the task's `harness` and `model`:
a Claude Code builder is reviewed by pi on OpenAI, and a pi, Codex, or Grok builder is reviewed by Claude Code.
Claude Code's own subagents accept only Claude models, so the cross-vendor seat is a separate headless process: `claude -p` or `pi -p`.

The reviewer runs in a disposable detached checkout of the PR head under `~/.fm-pstack-review/<task-id>`, with edit and write tools turned off, and that checkout is removed afterwards.
It follows the project's `AGENTS.md` for how tests run.

## Lifecycle

1. The worker reports its PR and firstmate registers it with `bin/fm-pr-check.sh`, as before.
2. `bin/fm-pstack-review.sh classify <id>` prints the tier. A `tap` tier means the merge escalates to the captain.
3. `bin/fm-pstack-review.sh start <id>` records a skip, or starts the one pass detached and returns at once.
   It records the merge base first, so a merge that lands before the reviewer starts does not empty the diff.
4. The merge proceeds or waits on its existing authority, without waiting for the review.
5. The pass writes `state/<id>.pstack-review` with `status=skipped|clean|findings|error`, the reviewer, the tier, and the ticket ids.
   Its full output is kept in `state/<id>.pstack-review.out`, and the detached run's log in `state/<id>.pstack-review.log`.
6. Each finding becomes a backlog ticket `rv-<id>-<n>` in the project's repo, held with `--kind captain` by default.

A reviewer that times out or returns no parseable result is recorded as `status=error` and is not retried.
`bin/fm-pstack-review.sh status <id>` prints the record at any time.

## Verification

`tests/fm-pstack-review.test.sh` covers the opt-in switch, tier selection, the cross-vendor reviewer choice, ticket filing and holds, the one-pass refusal, the detached start, and the unparseable result.
