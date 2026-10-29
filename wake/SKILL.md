---
name: wake
description: Run repo work from a repo session by the wake method — one small PR per worker, one independent mergewake review, every finding fixed or replied, CI green, then the repo session merges. No tester rounds, no director in the path. Use in a repo session (e.g. an integrator lane) that decides repo work with the operator directly, and in every worker it spawns. Triggers - "wake method", "run this as a wake PR", repo-session spawn of an implementation worker.
---

# wake — repo-session PR loop

A repo session owns its repository's work with the operator directly. It decides
**what** a task is; tools compute **who** runs it and **where**. Each change is a
small PR that lands after one independent review — not after tester rounds.

The name is the method, not the builder `[wake]` harvest event (`builder` skill).

## When to use

- You are a repo session and the operator agreed on a repo change with you.
- You are a worker spawned by such a session (follow the brief; §Worker brief is your contract).

Not for: deploys or infra changes (send to the desk lane), work routed through a
director/builder (use `builder` / `spawn-worker`), or decisions (ask the operator).

## What the repo session decides vs. computes

Decide and record on the hk task: **grade** (S+..C), **tier** (T0..T3, by revert
cost — `spawn-worker` §2-1), **urgency** (hk priority 1–2 = urgent), and
**capability tags** (`unity`, `xcode`, `gpu`, `linux`; none = any host).
Put the marker in the task title, e.g. `(grade B, T1)` — runtug refuses without it.

Model and host are computed: `pacelever --recommend <grade> --role worker` ranks
candidates; runtug applies the catalog grade check, quota gate and placement policy
(`--host auto --tags ...`). Pass an explicit `-m` or `--host NAME` only with a
reason recorded on the task (`handoffkeep tasks comment <id> ...`).

Pool order: SWE-2 free → subscription quota that would be wasted before reset
(`WASTE`) → pi credit (expires 2026-11-16; pace it to finish by then) → other
subscriptions by ranking. Do not hold urgent work for SWE-2 when paid quota is
plentiful; non-urgent work may wait for SWE-2.

## The loop

1. **Task.** Create the hk task with the title marker, tags and an expected duration
   (2h small fix, 6h normal feature, 1d large). One task = one PR.
   ```sh
   handoffkeep tasks add --project <project> --title '<title> (grade <G>, <T>)' \
     --priority <n> --expected <duration>
   ```
   The expected duration drives the quota-stop rule: a pane stopped on quota waits if the
   reset falls within it, otherwise the task is handed over (1d when absent).
   The server field ships with the next hk deploy; until then `--expected` may be refused —
   create the task without it and record `Expected: <duration>` as a task comment.
2. **Worktree.**
   ```sh
   git -C ~/work/<repo> fetch
   git -C ~/work/<repo> worktree add -b wk/<slug> ~/work/<repo>.<slug> origin/main
   ```
3. **Brief.** Copy §Worker brief to `~/work/herdr-inbox/jobs/<job>/brief.md` and fill it.
   Every instruction maps to a checkable acceptance criterion (`spawn-worker` §3).
4. **Pick the model.** `pacelever --recommend <grade> --role worker` → first eligible
   candidate in pool order above.
5. **Preview, then spawn.**
   ```sh
   runtug spawn -c ~/work/<repo>.<slug> -m <profile> -p ~/work/herdr-inbox/jobs/<job>/brief.md \
     -w workers -l <job> --t <T> --task <id> --owner <repo-session-lane> --job <job> \
     --host auto [--tags unity] --report ~/work/herdr-inbox/jobs/<job>/report.md --dry-run
   ```
   Check profile, host and preamble in the preview, then run the same command without
   `--dry-run`. **runtug is still in shadow migration.** If runtug refuses for a
   tooling reason (hub-only host, missing catalog row, not installed), fall back to
   `wrk spawn` with the same `-c -m -p -w -l --t --task --owner --job --report --host`
   arguments. Use exactly one launcher per task — never submit the same live task twice.
6. **Landing check.** Confirm the brief was received (`spawn-worker` §4-2), then stay idle
   until the worker's READY/ESC arrives. No polling loops.
7. **On READY**, run the merge gate (below). Pass → merge. Fail → §BLOCKED.
8. **Merge** (repo session only; workers never merge):
   ```sh
   gh pr merge <n> --repo <owner>/<repo> --squash
   ```
   Then close the hk task and reap the pane: `runtug reap` (or `wrk reap`) as a preview,
   then again with `--apply`.

## Merge gate

All must hold on the current PR head:

- Required checks green — the names in `.mergewake/policy.yaml` `required_checks`:
  `gh pr checks <n> --repo <owner>/<repo> --required`.
- No unresolved critical/high finding. Every review thread is fixed or replied to; list
  open threads with
  ```sh
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved path comments(first:1){nodes{body}}}}}}}' \
    -F o=<owner> -F r=<repo> -F n=<n>
  ```
- Blocking paths: if the diff touches any `blocking[].paths` entry in
  `.mergewake/policy.yaml`, two independent reviews are required — the mergewake review
  plus a second lens (a reviewer from a family other than the author's and the first
  reviewer's, briefed on the policy's `reason` for that path). Both must be clean.
- The review covered the head being merged (or later commits only answer its findings).

The repo session (or the mergewake daemon's READY/BLOCKED notice, once shipped) checks
CI. Workers do not.

## BLOCKED

CI red, an unresolved critical/high finding, or a missing second review on a blocking
path. Spawn a **fix worker** on the same branch with a new job id and the findings in
its brief (same loop from step 3). Never re-prompt a finished worker's pane — it is
terminal; reap it. If the fix needs a decision, escalate instead.

## Escalation and notifications

- Decisions (scope, trade-offs, anything irreversible) go to the operator directly from
  the repo session. Workers escalate to their parent lane:
  `runtug escalate <job> --question '<text>'` (or a `panewire emit --kind lane.event`
  with an `ESC` text).
- Deploys and infra go to the desk lane. The repo session does not deploy.
- Completion/READY/ESC reach the parent lane. Inbox-capable CLIs may block on
  `panewire inbox wait` once shipped; otherwise the message arrives as pane text.

## Worker brief

Copy, fill every `<…>`, delete nothing else.

````markdown
# Brief — <repo>: <title> — hk task <id>

Worktree: ~/work/<repo>.<slug> (branch wk/<slug>, base origin/main). Grade <G>, <T>.
Expected: <duration>  (hk task --expected; quota stops wait only if the reset falls within it)

## Do
<numbered instructions>

## Acceptance (1:1 with Do)
<numbered observable checks: command → expected output>

## Rules
- Small PR. No direct merge. Tests narrowly; anything over 1 min via `runtug heavy -- <cmd>`.
- Commit and PR body end with these trailers:
  Mergewake-Author-Family: <anthropic|openai|google|…>
  Mergewake-Author-Profile: <launch profile>
  Mergewake-Task: <id>
- Review once: after opening the PR run exactly once
  `GITHUB_TOKEN=$(gh auth token) mergewake review --repo <owner>/<repo> --pr <n> --author-family <family> --apply`.
  Fix or reply to every finding, then push. Do not re-run the review.
- Do not wait for CI. Done = pushed + one review + every finding handled + report + one READY.
- Decisions: stop and escalate to <parent-lane>; do not guess.

## Done
Write ~/work/herdr-inbox/jobs/<job>/report.md (outside the worktree — it does not affect
`git status`; do not delete it): PR URL, head SHA (`git ls-remote`), tests run with output,
each finding and how it was handled. Then emit exactly once:
panewire emit --kind lane.event --lane <parent-lane> --event-id <job>-ready --text '[<job>] READY | <pr> | ~/work/herdr-inbox/jobs/<job>/report.md'
````
