# Round-extension procedure

Record the extension approval and open the extra round with `wrk round open JOB
--head SHA --extend hk:doc/<key>`. The existing issuer, round-cap and grant checks
remain in force; this spawn grant does not itself create or consume extra rounds.

After a round-extension document exists, the next round's tester/reviewer/counsel
may use codex-astra xhigh or fable without a per-spawn operator request (operator
standing grant 2026-10-18, hk:doc owner/fleet/decision/2026-10-18/round-ext-astra-fable).

Use `--role tester|reviewer|counsel --purpose round-extension --round-ext REF
--parent-job JOB`. Accepted REF keys are `round-extension/JOB`, `round-ext/JOB`,
or `<project>/round-ext/JOB`, where project matches `[a-z0-9][a-z0-9-]*` and JOB follows
the generic document segment rule `[a-z0-9][a-z0-9._-]*`. The entire REF is at most
128 ASCII characters. Uppercase, leading punctuation and dot-only JOBs are refused.
We implement exact equality with the explicit parent job,
rather than accepting another job on the task. The hk task's job binding must
also equal that parent. This keeps another task's document from unlocking a spawn,
including when local job metadata is absent. Missing documents, unreachable hk,
malformed replies and ownership failures refuse before catalog/quota calls.
The document's server-set created_by must match the existing round-open issuer
policy: operator or operator-desk, or director-1/pa-integrator when that identity
is the parent job's recorded parent lane. The fixed allow-lists are reused;
client-provided session/by text cannot authorize a document. pa-integrator also
requires the server task to be ParkingArcade. Missing task fields, ambiguous JSON
and control characters in state, claimed_by or refs refuse; an empty claimed_by
is valid when refs.job_id binds the correct parent.
Task bypass is unavailable for this path. Worker roles are refused;
codex-astra is pinned to xhigh and other efforts are refused. Quota still applies.
Astra/fable tester and reviewer seats require this grant for every purpose.
wrk forwards --role to both scopefuel gate and policy launch; ordinary counsel
seats keep their existing purpose rules. Without an explicit --role, eligible
astra architect/director/operator-request calls and operator-requested fable
calls normalize to counsel before role validation and catalog/gate transport.
This normalization never applies with --purpose round-extension or --round-ext:
those spawns still require an explicit role. Explicit worker remains refused.

The additional standing grant of 2026-10-19 (hk 1672, hk:doc
owner/fleet/decision/2026-10-19/round-ext-builder-astra-fable) also permits a
replacement builder using exactly codex-astra xhigh or fable. Use `--role builder
--purpose round-extension --round-ext REF --task ID --job JOB --lane BUILDER
--parent PARENT`. The document JOB, spawn JOB and explicit task's current keyed
`refs.job_id` must all match. An unbound task, another job/task/project, ambiguous
task JSON or an unauthorized document issuer refuses before catalog/quota.
For builders, project-prefixed documents must match the server task's project
(case-insensitive); existing inherited tester/reviewer/counsel paths keep their
previous namespace handling.
The existing issuer lists, newest recorded parent lane and pa-integrator's
ParkingArcade restriction apply to builders too. A builder-created or mac-dev
document cannot authorize a seat, and no task bypass is available. Ownership and
issuer are checked again before pane creation, immediately before each actual
agent-start attempt after shell readiness, and before brief handoff after the
agent boot wait. Each actual panewire/direct-herdr handoff also takes fresh reads.
A refusal closes any already-created pane through the existing EXIT trap. These
reads detect changes across admission, tab creation, readiness and boot waits;
they are not an atomic server reservation, and ownership can change after a read.

Reuse the existing released same-job reclaim, with its builder lease and lane
registration. This grant introduces no takeover or new-job replacement path.
The scopefuel JSON launch answer must admit the approved model/effort AND carry
`round_extension_builder` evidence exactly binding `policy=hk1672/v1`, profile,
`role=builder`, `purpose=round-extension` and the requested ref. Only these
conditional builder responses add that field; ordinary launch/recommend output
stays byte-identical. hk 1632 scopefuel admits the same model/effort without this
evidence, so wrk must reject that actual old response too. Unavailable, unreadable,
refusing or unsupported installations fail closed for this builder exception.
Astra uses builder-sol's Codex sandbox/approval flags at xhigh; fable uses
builder-opus's permission flags with literal `claude-fable-5-1`. Removed builder-astra/captain-astra aliases stay removed;
there is no builder-fable profile. Ordinary defaults and recommendations do not
change, and recommendation candidates never include these exceptional seats.

Prefer a provider family different from the builder: Anthropic builder → astra;
OpenAI builder → fable. If astra is refused, use codex-sol xhigh; if fable is
refused, use opus xhigh. Report the refusal reason up. These choices are director
practice and must not become automatic fallback logic.

Tester eligibility evidence carries top-level `round_ext_ref` through pre-spawn,
post-landing and pre-merge receipts. Only codex-astra and fable gain the tester
and builder roles on T1/T2/T3 from a correctly shaped ref. Both resolve to grade
S+; wrk verifies document existence, issuer and current task ownership. Builder
contributors require this evidence too. Apply the usual T1–T3 family separation:
astra builders need a non-OpenAI tester and fable builders a non-Anthropic tester.
This builder-only restriction does not remove the existing T1/T2 same-family
exception for counsel/prescription contributors.

Delivery order is agent-skills FIRST, then scopefuel, under director-1's
hk:doc rulings/b1672-sol/r1 (including the accepted gate-owner addendum).
The measured old/new matrix uses real archived hk 1632 scopefuel and current CLI:
new wrk with old scopefuel preserves implicit counsel and tester seats for both
models while refusing the new builders before gate/pane for missing hk1672/v1
evidence. Existing tester seats also pass with old wrk/new scopefuel; implicit
counsel fails in that reverse window. Old/old and new/new controls were measured.
This satisfies the ruling's condition for changing delivery order; PR creation
order remains scopefuel #154 then agent-skills #209. It grants no installation
or merge authority.
