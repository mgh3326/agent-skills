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

Not for: T0 work (`spawn-worker` §2-1 — not spawned; the repo session does it directly
and still opens a PR), deploys or infra changes (send to the desk lane), work routed
through a director/builder (use `builder` / `spawn-worker`), or decisions (ask the operator).

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
7. **On READY**, record the head (`H=$(gh pr view <n> --repo <owner>/<repo> --json headRefOid --jq .headRefOid)`)
   and run the merge gate (below) against it. Pass → step 8. Checks still pending →
   wait (`gh pr checks <n> --repo <owner>/<repo> --watch`) and rerun the gate; that is
   not BLOCKED. Fail → §BLOCKED.
8. **Merge** (repo session only; workers never merge), pinned to the gated head:
   ```sh
   gh pr merge <n> --repo <owner>/<repo> --squash --match-head-commit "$H"
   gh pr view <n> --repo <owner>/<repo> --json state --jq .state   # must print MERGED
   ```
   A refused merge (head moved, conflict) means rerun the gate on the new head; do not
   clean up. Only after `MERGED`: close the hk task and reap the pane — `runtug reap`
   (or `wrk reap`) as a preview, then again with `--apply`.

## Merge gate

All must hold for head `$H`:

- Every name in `.mergewake/policy.yaml` `required_checks` passed — read the names from
  the policy, not from GitHub's required flag. For each `<check>`:
  `gh pr checks <n> --repo <owner>/<repo> --json name,bucket --jq '.[]|select(.name=="<check>")|.bucket'`
  prints `pass`. `pending`, or nothing while other checks still run (an aggregate check
  appears late) → wait. `fail`, or still absent after every check finished → BLOCKED.
- No unresolved critical/high finding. Every review thread is fixed or replied to; list
  unresolved threads across all pages with
  ```sh
  gh api graphql --paginate -F o=<owner> -F r=<repo> -F n=<n> -f query='query($o:String!,$r:String!,$n:Int!,$endCursor:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor}nodes{isResolved path comments(first:1){nodes{body}}}}}}}' \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved|not)'
  ```
- The mergewake review completed. On a PR touching any `blocking[].paths` entry in
  `.mergewake/policy.yaml`, that one `mergewake review --apply` posts two passes
  (correctness lens, then state-risk lens); both must be posted. Check for the done marker:
  `gh api repos/<owner>/<repo>/git/matching-refs/mergewake/reviews/<n>/ --jq '.[].ref'`
  lists `…/<reviewed head>-done`. No done marker → the repo session reruns
  `mergewake review` for that head (it resumes the missing pass); this is not a fix-worker job.
- Commits after the reviewed head only answer its findings.

The repo session (or the mergewake daemon's READY/BLOCKED notice, once shipped) checks
CI. Workers do not.

## BLOCKED

A required check failed, or a critical/high finding is unresolved. Spawn a **fix worker**:
create a follow-up hk task (`<title> — fix PR #<n>`, with `--expected`), and run the loop
from step 3 on the same branch with a new job id, that new task, and the failing checks or
findings in its brief. Do not reuse the original task id — it is still bound to the
finished job, and `wrk` refuses a `--task` bound to another job. Never re-prompt a
finished worker's pane — it is terminal; reap it. If the fix needs a decision, escalate
instead.

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
