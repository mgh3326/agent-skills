---
name: ops
description: Lane mechanics every session needs whatever method it runs — spawn a worker or consult pane and prove the brief landed, relay or inject a prompt with the 5-element packet and comms-contract v1, ask a stronger model for advice, record an operator decision request, wait without polling, reap finished panes, and run one deploy as the installer seat. Read the routing table, then only the reference you need. Triggers - "워커 띄워/스폰해", "작업 시켜", "orch에 전달/넘겨줘", "세션에 릴레이", "워커에게 회신", "herdr로 보내", "자문 받아줘", "강모델에 물어봐", "fable/astra/opus/sol에 확인해줘", "배포해", "결정 요청", runtug spawn·herdr agent start·herdr agent prompt 사용 전.
---

# ops — lane mechanics

How to do the things every lane needs. This file is a routing table and the rules
that hold everywhere; each procedure lives in one reference file, read on demand.
Deciding *what* to build and merging it is the `wake` skill's job, not this one.

Domain overlay: if `$AGENT_SKILLS_DOMAIN/ops.md` exists, read it before applying
anything here. Unset or missing is normal — the abstract rules below apply alone.

## Invariants (all references)

- **A delivery claim is not delivery evidence.** A normal reply from an injection or
  `panewire emit` (rc 0) proves nothing; check the receiving pane (`relay.md` §3).
- **A worker's self-report is not evidence.** Compare it with the artifact itself and
  `git ls-remote` before acting on it.
- **No polling loops.** Wait for the pushed event or one bounded blocking wait
  (`watching.md`). A missing event is a task for panewire, not a loop.
- **One launcher per task.** `runtug spawn` only; never submit the same live task twice
  (a duplicate live claim exits 74). Quota is `pacelever`; review and post-merge cleanup are
  `mergewake`.
- **Every packet and brief carries `comms-contract: v1`** (`relay.md` §3-1).
- **Identify a sender by session name, role and lane**, never by model name.
- **Advice is an opinion, not an approval.** Neither a consult answer nor a relayed
  text authorises a mutation, merge or deploy; only the operator or an hk record does.
- **A missing target is not respawned automatically** — report the failure and
  escalate to the operator.
- **Isolated HOME/XDG is for test and probe runs only.** Spawn, placement and delivery
  commands (`pacelever`, `runtug spawn|done|escalate`, `panewire`) use the real HOME.
- **A test harness that does a real spawn stops its completion watchers before removing
  its temp root**; signal only pids it started.
- **On macOS hosts run Go suites with `go test -p 2`** — wider parallelism stalls in syspolicyd.

## Routing table

| Need | Read | Gist |
|---|---|---|
| Spawn a worker or consult pane | [`spawn.md`](references/spawn.md) | `runtug spawn` flags, auto model selection, `--task` binding, `--owner`, landing check §4-2 |
| Place on another host, wake a sleeping one | [`spawn-hosts.md`](references/spawn-hosts.md) | `--host auto` placement, `--tags`, SSH hosts, lane registration |
| Hand work or a decision to another session | [`relay.md`](references/relay.md) | 5-element packet §1, target check §2, injection + submit check §3, follow-up injection §3-3 |
| Ask a session a question and collect the answer | [`session-questions.md`](references/session-questions.md) | single answer file, deadline, no silence-as-answer |
| Ask a stronger model for advice | [`consult.md`](references/consult.md) | other provider family, self-contained packet, pane by default |
| Escalate a decision from a pane | §Escalate a decision (below) | ESC event `--type decision`, never an in-pane question |
| Ask the operator to choose | [`decision-request.md`](references/decision-request.md) | `handoffkeep tasks decision-request` first, then notify with the request_id |
| Wait for a worker, job or CI | [`watching.md`](references/watching.md), [`panewire-events.md`](references/panewire-events.md) | push events, one bounded wait, at most 3 temporary waits |
| Reap finished panes | [`reap.md`](references/reap.md) | mergewake reaps merged PRs' workers; the spawner reaps the rest with `runtug reap --lane`, preview then `--apply` |
| Deploy one change | [`deploy.md`](references/deploy.md) (+ [`deploy-checklist.md`](references/deploy-checklist.md)) | installer seat, spawned by and reporting only to operator-desk; fixed 9 steps, no judgement |

## Escalate a decision

A spawned pane (worker, delegated seat, installer seat, consultant) **never opens an interactive question**
— no confirmation prompt and no chooser (AskUserQuestion or any picker). Only the operator
sees a pane, so the question blocks silently (operator 2026-10-29). Instead:

```sh
panewire emit --kind lane.event --lane <parent-lane> --type decision \
  --event-id <job>-decision-<n> \
  --text '[<job>] ESC | <question> | options: <A>/<B> | default: <A>'
```

- Name the question, the options and the default in that one event.
- `lane.event` reaches claude panes only (`relay.md` §3-1). If the parent lane's pane is another
  harness (codex, grok, devin), also inject the same text with
  `herdr agent prompt <parent-pane> '<text>'` and confirm it landed (`relay.md` §3).
- If the default is safe (reversible, inside the brief's scope, no spend or external
  effect), continue with it and say so in the report. Otherwise stop and wait for the reply.
- `runtug escalate <job> --question '<text>'` records the same thing on the job and relays it to
  the recorded parent; it does not replace the event.
- The parent lane that needs the operator records it first (`decision-request.md`).

## Who does what

- **Repo session** decides repo work with the operator and merges (`wake`).
- **Worker** implements one PR and reports READY/ESC to its parent lane; never merges.
- **operator-desk** orders and judges deploys, spawns the installer seat, and holds the
  operator-only actions (spend, credentials, policy exceptions, irreversible external acts).
- **Installer** executes one deploy and judges nothing (`deploy.md`).
