---
name: fleet-review
description: How a worker or the desk triages mergewake review findings so a PR converges — fix/dismiss/defer rubric, the per-repo learned skip-pattern file (.mergewake/triage-patterns.md), "a verdict covers a patch" (patch-id) semantics, and poteto-mode's three openers (restate the goal, name the data shape, prove it against the real artifact). Also states that the fleet brief and the wake skill override every vendored pstack skill. Use when you receive review findings, when you write or read a verdict, before a nontrivial design, and whenever a vendored pstack skill (third_party/pstack) is in play. Triggers - "review finding", "mergewake review", "triage", "patch-id", "base_stale", "dismiss or fix", "pstack".
---

# fleet-review — triage, verdicts, openers

A review loop converges when the contract is closed and each finding gets one disposition.
It does not converge when every new head earns a fresh open-ended hunt. This skill is the
worker- and desk-side half; the enforcement half (severity gate, patch-id keyed verdicts,
delta review) is mergewake's code. Where mergewake does not yet do something below, the
desk applies it by hand when it reads the merge gate.

## Precedence

**The fleet brief (runtug brief-policy, host-safety block) and the `wake` skill override any
vendored pstack skill under `third_party/pstack/`.** Where they differ, follow the fleet.
From pstack take method only: triage, `how`, `architect`, `blast-radius`, `tdd`, the
principles. These pstack sections do **not** apply here:

- **Autonomy** ("use any MCP tool", external actions without asking, "going to bed" overrides):
  the brief's Rules and the wake Authority section decide what needs the operator.
- **Subagents / model choice / `pstack-models.md` / `/setup-pstack`:** runtug spawns,
  pacelever and runtug choose models, and `wake` §Subagent vs worker says when a subagent is
  allowed. Skip a pstack step that says "spawn", "arena", "swarm" or "explorers"; do the
  step yourself, read-only, or leave it out and say so in the report.
- **Merging, arming auto-merge, babysit/shipping playbooks:** the desk merges, pinned to the
  gated head (`wake` step 8). A worker never merges or arms anything.
- **AskUserQuestion / "ask the user":** never ask in a pane; emit the decision ESC.

`third_party/pstack/REVIEW.md` lists each conflict and its neutralisation.

## Closed contract

A PR is judged against the **Acceptance (closed contract)** section of its brief, nothing
wider. A finding inside it is a defect. A finding outside it is **advisory**: it gets a
disposition (usually dismiss or defer) and never blocks. Do not widen scope to answer a
finding; if the contract itself is wrong, that is a decision (ESC), not a fix.

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

## A verdict covers a patch, not a SHA

Key a review result by the patch it saw:

```sh
git diff "$(git merge-base origin/<base> <head>)" <head> | git patch-id --stable
```

- **Same patch-id as the reviewed head** (a merge of the base, a rebase before first push,
  an amended message): the verdict and all dispositions carry over. `base_stale` then means
  "re-run CI", never "re-review". Check once that the patch still applies cleanly to the
  new base and that the changed base files do not feed it.
- **Different patch-id:** review the **delta since the last reviewed head**, with the prior
  findings and their dispositions in the reviewer's context and an instruction not to
  reopen them. Round one reviews the whole diff; later rounds do not.
- **Budget:** after three full rounds only critical/high from the delta blocks, and the desk
  decides. The number is a guess; the desk tunes it from measured rounds per PR.
- Tests-, docs- or lint-only differences still count as a different patch; the delta review
  is then small by construction.

## poteto-mode's three openers

Do these before any nontrivial work, in this order, in the report's first lines:

1. **Restate the goal** in your own words: the problem being solved and the smallest change
   that meets it. If the evidence rules out the requested change, show it and stop (ESC).
2. **Name the data shape** before writing code: the types, rows, messages or files the change
   reads and writes, and what owns each.
3. **Prove it against the real artifact**: run the changed thing the way its user runs it —
   the real binary, script, install dry-run or rendered file — not only a unit test or the
   diff. Quote the command and its output. If the real artifact cannot run in this
   environment, say UNVERIFIED rather than substituting a mock.

For a nontrivial design read, in this order of need: `how` (what exists), `architect` (sketch
before code), `blast-radius` (what else this touches), `tdd` (red before green). They live in
the agent skill directories (`~/.claude/skills/`, `~/.codex/skills/`) after `install.sh`; the
rest of the vendored set is readable under `third_party/pstack/skills/`. Their spawn and model steps are skipped per
Precedence.
