# Round-extension procedure

Record the extension approval and open the extra round with `wrk round open JOB
--head SHA --extend hk:doc/<key>`. The existing issuer, round-cap and grant checks
remain in force; this spawn grant does not itself create or consume extra rounds.

After a round-extension document exists, the next round's tester/reviewer/counsel
may use codex-astra xhigh or fable without a per-spawn operator request (operator
standing grant 2026-10-18, hk:doc owner/fleet/decision/2026-10-18/round-ext-astra-fable).

Use `--role tester|reviewer|counsel --purpose round-extension --round-ext REF
--parent-job JOB`. Accepted REF keys are `round-extension/JOB`, `round-ext/JOB`,
or `<project>/round-ext/JOB`, where project matches `[a-z0-9-]+` and JOB matches
`[A-Za-z0-9._-]+`. We implement exact equality with the explicit parent job,
rather than accepting another job on the task. The hk task's job binding must
also equal that parent. This keeps another task's document from unlocking a spawn,
including when local job metadata is absent. Missing documents, unreachable hk,
malformed replies and ownership failures refuse before catalog/quota calls.
Task bypass is unavailable for this path. Builder/worker roles are refused;
codex-astra is pinned to xhigh and other efforts are refused. Quota still applies.

Prefer a provider family different from the builder: Anthropic builder → astra;
OpenAI builder → fable. If astra is refused, use codex-sol xhigh; if fable is
refused, use opus xhigh. Report the refusal reason up. These choices are director
practice and must not become automatic fallback logic.

Tester eligibility evidence carries top-level `round_ext_ref` through pre-spawn,
post-landing and pre-merge receipts. Only codex-astra and fable gain the tester
role on T1/T2/T3 from a correctly shaped ref. Their grades and contributor-role
restrictions remain unchanged; wrk verifies document existence and ownership.
