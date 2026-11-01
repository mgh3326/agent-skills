---
name: fleet-review
description: How a worker or the desk triages mergewake review findings so a PR converges — what is in scope (the closed contract plus regressions the change introduces), the fix/dismiss/defer rubric, the per-repo learned skip-pattern file (.mergewake/triage-patterns.md), review rounds after fixes, reviewer independence (same-family passes are reference-only), and "a verdict covers a patch" (patch-id) evidence reuse. Use when you receive review findings, when you write or read a verdict, and when you decide whether a review pass counts or must be repeated. Triggers - "review finding", "mergewake review", "triage", "patch-id", "base_stale", "dismiss or fix", "same family", "review round".
---

# fleet-review — scope, triage, rounds, independence

A review loop converges when the contract is closed and each finding gets one disposition.
It does not converge when every new head earns a fresh open-ended hunt. This skill is the
worker- and desk-side half; the enforcement half (severity gate, patch-id keyed verdicts,
delta review) is mergewake's code. Where mergewake does not yet do something below, the
desk applies it by hand when it reads the merge gate.

Vendored pstack skills follow the fleet adapter in `robin-mode` (rstack) §Fleet adapter for
vendored pstack.

## Closed contract

A PR is judged against the **Acceptance (closed contract)** section of its brief **and the
existing invariants on the paths it changes**. A finding inside that scope is a defect. New
features, taste and unrelated pre-existing defects are **advisory**: they get a disposition
(usually dismiss or defer) and never block. **A regression this change introduces is in scope
even when the brief does not list the invariant it breaks** — a closed contract stops feature
creep; it is not a regression waiver. Do not widen scope to answer a finding; if the contract
itself is wrong or needs an exception, the owner decides (ESC), not the author.

## Triage rubric

Severity decides blocking. Disposition is what you do about it.

| Severity | Blocks? | Allowed dispositions |
|---|---|---|
| critical, high | yes | **fix**; or **dismiss** only with evidence (a command and its output, or the exact code line that disproves it) — the desk checks it |
| medium, low | no | **fix** (cheap and inside the contract), **dismiss** (one-line reason), or **defer** (follow-up hk task id) |

- **fix** — a plausible correctness, security, privacy, data-loss, auth, idempotency, race or
  shipped-behavior defect inside the contract. Fix it, reply with the commit SHA.
- **dismiss** — the code or context proves no change is needed, or it matches a skip pattern
  below. Reply with the reason. A dismissed finding stays dismissed unless a later review
  re-raises it with new evidence on changed lines.
- **defer** — real but outside the contract or the PR's size. Create the hk task first, cite
  its id in the reply.
- A resolved finding is resolved. Never push a commit only to unblock a gate, quiet a bot or
  add a test for a dismissed finding. Never churn code to satisfy a reviewer's taste.
- **Never skip, whatever the pattern file says:** security, privacy, auth, permission
  boundary, money or order paths, irreversible external mutation, migrations, data loss.
  These are fix, or ESC to the desk — never a self-dismiss.
- Every finding gets a line in the report: `id · severity · disposition · reason or SHA`.
  Unanswered findings do not count as handled.

## Learned skip patterns — `.mergewake/triage-patterns.md`

Per repo, optional. A pattern is a standing reason to **dismiss** a recurring non-issue
without re-deriving it. It never lowers a severity and never covers the never-skip list. The
file sits under `.mergewake/`, so changing it is a policy-path change: its own small PR.

```markdown
### <short pattern name>

- Confidence: candidate | recurring | strong
- Skip when: <conditions that must all be true>
- Do not skip when: <risk boundaries>
- Example signal: <phrases or code context that identify the pattern>
- Source: <PR/comment URL or short historical note>
```

`candidate` = one or two examples, a hint only: verify before dismissing. `recurring` =
several real dismissals. `strong` = narrow, repeatedly verified, low-risk. Add a pattern when
you dismiss the same thing the second time; promote only on repeated verified dismissals.
Read the file before triaging; if it is absent, triage from the rubric alone.

## Rounds

Review is not capped at one pass. The whole diff is reviewed once. **After fixes, a later round
checks only the open findings, the fix delta and its impact paths**, with the prior findings and
their dispositions in the reviewer's context and an instruction not to reopen them. Every lens
the PR needs (for example correctness and state-risk on `blocking[].paths`) runs in the same
round; lenses and transport retries are not extra rounds. **A round count never waives an open
critical/high.** A third round is a signal to re-diagnose the cause or re-scope the PR (the desk
decides), not an approval line. A change-caused defect found with new evidence is not dismissed
only because it lies outside the delta.

## Independence

Wherever independent review is required — the `wake` merge gate requires it for every PR — a pass
counts only when its reviewer's family differs from **every material author family** of the
change: each family whose code the PR carries (commits, subagent or delegate output), not the
family of whoever started the review. **A same-family pass is reference evidence only and does
not satisfy the gate**; the PR still needs a qualifying pass. A fallback path (pane → headless)
keeps the same qualification and evidence; if no qualifying reviewer runs, the result is
`REVIEW_UNAVAILABLE`, not a pass. The report lists the author families; until mergewake
checks them all, the desk does. Which reviewer is routed is hk
`policy/model-routing`.

## A verdict covers a patch, not a SHA

Review evidence identifies the patch it saw, the base and dependency context it was read
against, and the acceptance and policy versions. **It carries over only while that meaning
holds**; what changed is re-checked and nothing else. CI and the merge are always pinned to the
current head (`wake` §Merge gate). Key the patch with:

```sh
git diff "$(git merge-base origin/<base> <head>)" <head> | git patch-id --stable
```

- **Same patch-id as the reviewed head** (a merge of the base, a rebase before first push,
  an amended message): the verdict and all dispositions carry over, and `base_stale` means
  "re-run CI". Check once that the patch still applies cleanly and that the changed base files
  do not feed it — its callers, config or dependencies. If they do, review those impact paths
  (§Rounds), not the whole diff.
- **Different patch-id:** the next round reviews the delta since the last reviewed head and its
  impact paths (§Rounds).
- Tests-, docs- or lint-only differences still count as a different patch; the delta review
  is then small by construction.

## Openers

Before nontrivial work, run the `robin-mode` (rstack) openers and prove the result as its §Done
says.
