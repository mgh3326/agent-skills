# Review of the vendored pstack skills against fleet rules

Source: `PINNED` (pstack-claude at `5851c89`). Reviewed 2026-10-31 by reading the skills and grepping the
tree; this is a conflict list, not a security audit. Redo it on every version bump.

## Neutraliser

`fleet-review/SKILL.md` §Precedence: **the fleet brief (runtug brief-policy, host-safety block) and the
`wake` skill override any vendored pstack skill.** The wake worker-brief template repeats the line, so a
worker sees it in the brief before it reads any vendored text. Install is an allowlist
(`INSTALL`, operator-desk decision: 48 skills — every `principle-*`, `how`, `why`, `architect`,
`blast-radius`, `tdd`, `interrogate`, `reflect`, `statechart`, the verification skills and the
writing skills). The router and its playbooks (`poteto-mode`) and the other excluded skills
(below) are never in a session's skill list; they are reachable only by a relative link from an
installed skill. Scripts are not vendored (`PINNED` lists them), so a step that runs one cannot run.
Ten vendored skills are neither installed nor excluded by name (`babysit`, `deslop`, `fix-ci`,
`fix-merge-conflicts`, `get-pr-comments`, `make-pr-easy-to-review`, `thermos`, `thermo-nuclear-review`,
`thermo-nuclear-code-quality-review`, `what-did-i-get-done`): they stay vendored and out of the list
until someone asks for them.

## Installed skills that route to excluded ones

Excluded: `poteto-mode`, `poteto-help`, `setup-pstack`, `swarm`, `arena`, `automate-me`,
`ketchup`, `ketchup-video`, `bro` (`make-bot-ui` is not in this pin). An installed skill that sends the
reader there gets the fleet-review/wake precedence, not the excluded skill's instructions:

| Installed skill | Routes to (excluded) | What to do instead |
|---|---|---|
| `architect`, `interrogate`, `figure-it-out` | `arena` (multi-model bakeoff), `poteto-mode`, `setup-pstack` | Skip the arena/panel step; sketch and judge inline, read-only. Runners come from nobody: runtug picks models. |
| `how`, `why`, `reflect` | `poteto-mode` (Subagents section), `setup-pstack` (model sheet) | Skip explorer/explainer spawns; explore yourself. No model sheet exists. |
| `teach`, `recall`, `typescript-best-practices`, `no-comments`, `show-me-your-work`, `create-verification-skill`, `maintain-verification-skill`, `create-formal-verification-skill`, `maintain-formal-verification-skill` | `poteto-mode` (platform mapping, playbooks, references) | The relative link resolves into the vendored tree and is readable; treat it as background only. |

Every installed skill opens with "read the platform mapping" under `poteto-mode/references/`; that is
Cursor/Codex/Copilot tool-name translation and grants nothing.

Where a row says *skip the step*, the worker does the work itself read-only, or leaves the step out and
says so in the report.

## Conflicts

| # | Vendored instruction (where) | Fleet rule it breaks | How it is neutralised |
|---|---|---|---|
| 1 | **Autonomy: "Use any MCP tool. Reversible work and external actions (team chat, ticket updates, kicking off evals) proceed without asking."** (`poteto-mode/SKILL.md` §Autonomy; echoed in `principle-never-block-on-the-human`, `poteto-mode/playbooks/autonomous-run.md`) | wake §Authority: new external accounts, public posts, irreversible external actions are operator-only; an approval covers one action in one session. | Precedence line names Autonomy as not applicable. `poteto-mode` is not installed. A worker's external actions are limited to what its brief lists. |
| 2 | **"Going to bed / run until done / be fully autonomous → keep going"** session overrides (same section). | Brief Rules: on a decision emit ESC and stop unless the default is safe. | Not applicable (Precedence). |
| 3 | **Spawning subagents by default** with `run_in_background`, full tool access and an explicit `model` per role (`poteto-mode` §Subagents; `how`, `architect`, `arena`, `swarm`, `interrogate`, `why`, `reflect`, `thermos`, `no-comments`: `subagent_type` spawns). | wake §Subagent vs worker: a subagent only for read-only lookups; code, tests and PRs go to a runtug-spawned worker. Brief: runtug spawns. | Precedence: skip any "spawn", "arena", "swarm", "explorers" step; do it read-only yourself or omit and report. `how`, `why`, `architect`, `interrogate`, `reflect` and `figure-it-out` are the installed skills that carry such steps; their fleet use is "read the skill, do the thinking inline". |
| 4 | **Model choice:** `pstack-models.md` override sheet, `/setup-pstack`, role defaults (`sonnet`, `opus`, `fable`), reasoning-effort `@level` (`poteto-mode` §Models, §Reasoning effort; `## Models` in `how`, `architect`, `arena`, `swarm`, `interrogate`, `why`, `reflect`). | pacelever and runtug choose models and pools; `--effort` is an argument; grade is not lowered for quota. | Precedence. `setup-pstack` is excluded and its scripts are not vendored, so no sheet is written. Ignore every model slug in vendored text. |
| 5 | **Auto-merge and landing:** `playbooks/shipping.md` step 4 merges with `gh pr merge … --squash --match-head-commit` and may arm `--auto`; `playbooks/autopilot-full.md`, `autopilot-stack.md` land PRs. | The desk (repo session) merges, pinned to the gated head, after the merge gate. A worker never merges or arms anything. | Precedence names merging and auto-merge. The playbooks are not installed. The `--match-head-commit` pin matches wake step 8; the rest does not apply. |
| 6 | **Rebase / force-push with lease** to restack and retarget PRs (`references/merge-safety.md`, `playbooks/autopilot-full.md`, `autopilot-stack.md`, `babysit.md`). | Rules: a pushed branch catches up by `git merge origin/main`; never rebase or force-push it. | Precedence: wake and the brief win. Stacked-PR restacking does not exist in the wake method (one task = one PR). |
| 7 | **Pushing, opening PRs, replying to and resolving review threads** (`playbooks/opening-a-pr.md`, `babysit.md`, `multi-phase-plan.md`, `references/bugbot-triage.md`). | A worker opens its own PR and replies to review findings (allowed); it re-runs no review, pushes nothing only to quiet a finding, and does not babysit or poll CI. | Replying/resolving on its own PR stays allowed. `babysit` playbook (polling loops, `/loop`, wake-ups) is excluded by "do not wait for CI". The triage rubric is rewritten in `fleet-review` to match mergewake severity. |
| 8 | **Polling and loops:** `/loop`, `ScheduleWakeup`, `CronCreate`, watchers (`poteto-mode`, `babysit`, `autopilot-full`, `shipping`, `visual-parity`). | wake step 6: stay idle until READY/ESC; no polling loops. The watcher tools are not vendored. | Precedence; scripts absent. |
| 9 | **AskUserQuestion / "ask the user"** (`poteto-mode`, `setup-pstack`, `automate-me`, `babysit`, `playbooks/autonomous-run.md`). | Never ask a question in a pane; emit the decision ESC (default, stop if unsafe). | Precedence names it. |
| 10 | **Reading agent transcripts and config:** `reflect`, `show-me-your-work`, `setup-pstack`, `multi-phase-plan` read `~/.claude/projects`, `~/.codex/sessions`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`. | Brief Rules: never read real agent dotfiles (`~/.codex`, `~/.claude`, `~/.claude.json`). | `reflect`, `show-me-your-work` and `recall` are installed; their transcript-finding scripts are not vendored, but the prose still names the paths. Precedence plus the brief rule: skip any step that reads agent transcripts or config. `setup-pstack` and `automate-me` are excluded. |
| 11 | **Worktree cleanup:** `playbooks/worktree-cleanup.md` removes worktrees and branches. | mergewake removes the worktree and branch after `worktree_after`; "do not close or remove them by hand". | Playbook not installed; Precedence. |
| 12 | **Host-safety:** dev servers, installs (`bun install`/`bootstrap.ts`), formal-verification and statechart tools, benchmarks (`run`, `create-verification-skill`, `statechart`, `benchmark-checklist`). | Fleet-v1: no local database servers, changed tests only, stop every PID you started, no pattern kills. | `statechart`, `create-verification-skill`, `create-formal-verification-skill`, `benchmark-checklist` are installed, but their tools are not vendored (`statechart` is inoperative; verification skills describe launching an app or a checker). Host-safety is prepended by runtug and wins: no local database or dev server unless the brief's Environment line says so, changed tests only, stop your own PIDs. |
| 13 | **Slack, Linear, Notion, Datadog, Sentry, Databricks searches** in `why` (`references/sources/*.md`). | External services other than GitHub and hk are not in a worker's brief. | `why` is installed; Precedence limits tools to the brief — a source with no brief-listed tool is reported as a gap, as `why` itself prescribes. |
| 14 | **Reply format:** every reply opens with the goal; names each principle; "name the principle that shaped a decision" (`poteto-mode` Non-negotiables). | Context budget of a quota-gated worker. | `poteto-mode` is excluded; only the three openers are adopted, as `fleet-review` §openers. Installed skills that say "name the principle" are optional style, not a gate. |

## Residual risks (accepted)

- **Readable, not installed.** An installed skill that links into the vendored tree (for example
  `architect` → `arena`, any skill → `poteto-mode/references`) can lead a worker into an excluded one.
  Precedence is the only guard there; it is in the brief and in `fleet-review`.
- **Context cost.** 48 skill descriptions load into every session on every host. This is the operator's
  call; the consult's alternative was a two-page extract. Trim `INSTALL` if quota evidence says so.
- **Example text in vendored files** (a loopback URL in `create-verification-skill` examples) is
  verbatim upstream content, not a fleet address.
- **Unvetted prose.** Upstream changes weekly. Pin, diff on bump, never symlink a live clone.
- **No skill eval was run** on the extract (the consult asked for one before wide install). Run
  one before trusting the broad set on a quota-gated worker.
