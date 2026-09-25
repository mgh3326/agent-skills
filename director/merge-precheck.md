# Shadow merge precheck

Run from this repository with Python 3.9 or newer:

    python3 director/merge_precheck.py mgh3326/agent-skills 144 --task 727 \
      --job 727-merge-precheck-20260925-1545 \
      --tester-report /absolute/path/to/tester-report.md \
      --builder-report /absolute/path/to/builder-report.md \
      --tester-report-sha256 EXPECTED_REPORT_SHA256

The command writes one immutable JSON receipt to the directory named by
`--receipt-dir` (default: `~/work/herdr-inbox/receipts`) and prints one summary
line. Exit 0 requires PASS or policy-referenced N/A for every check. FAIL is an
explicit violation; UNVERIFIED means evidence is missing, stale, conflicting,
or failed to load. The command is shadow detection. It never spawns, merges,
updates a branch, or transitions a task. A bypass remains possible.

The receipt records action ID, kind, task, job, repo, PR, current H/B, trial
merge tree M and its commit, policy path/revision/SHA256, tool version, issuer/time, per-check
status and reason code, report path/SHA256, and CI run ID/attempt/job ID. A
named report is read in full. A standalone `VERDICT: PASS @<full H>` after any
brief/prompt section is accepted; quoted and fenced lines are ignored. The
report must also name TASK, REPO, PR, TESTER_JOB, and TESTER_SESSION. A builder
JOIN is not a tester PASS. A supplied `--eligibility-receipt` is bound to the
same identifiers and its PASS/N/A checks. The optional expected report SHA256
arguments detect a report changed after its earlier handoff.

Required CI is evaluated by the importable entry point
`director/ci_canonical.py:evaluate_required_ci(policy, repo, H, B, runs,
jobs_by_run, protection_contexts)`. Task #723 should import that entry point.
The required set is in `director/gate-policy.v1.json`; it contains only the
repository's own test and build jobs. Every entry must have an actually run,
successful GitHub Actions job at H with a run ID, attempt, and tested base SHA.
Missing branch protection is UNVERIFIED, not an empty required set. A skipped
job is FAIL. A later red run supersedes older green evidence.

The versioned policy artifact is loaded by `director/gate_common.py`, which
also provides `write_receipt` and `resolve_profile` for task #726. Its source
references include decision 3231, advice 3243, the task #723 CI decision,
and decision 2227. Decision 2227 only supports A+ reversible T1/T2 verification;
it does not authorize T3, deployment, or safety work. An unknown, conflicting,
or expired policy is UNVERIFIED. The sibling task should rebase and reuse this
module and policy artifact, not copy them into a second loader.

## Runtime receipt

If a changed path maps to executed service code or dependencies, G9 requires
an independently produced JSON host observation. Unknown service maps and
ambiguous targets are UNVERIFIED. The current policy seeds the
auto_trader-operator NCP runner entry with the Python 3.11 interpreter from
task #695. This tool does not contact NCP. A receipt has this shape:

    {
      "kind": "host-runtime", "repo": "mgh3326/auto_trader-operator",
      "PR": 94, "H": "FULL_40_HEX_SHA", "target": "NCP",
      "service": "ncp-operator-runners", "issuer": "operator-desk",
      "observed_at": "2026-09-25T08:00:00Z",
      "exec_start": "/usr/bin/python3.11 /srv/auto-trader-operator/runners/h1_pilot_runner.py",
      "interpreter": "/usr/bin/python3.11", "version": "3.11.9",
      "os": "linux", "arch": "x86_64", "lock_ref": "uv.lock@H",
      "dependencies_ref": "pyproject.toml@H", "proof_ref": "host-observation/ID"
    }

The receipt is accepted only at the same H/PR/service/target, when observed
within 24 hours by an issuer other than the precheck issuer, and when its
ExecStart contains the mapped absolute interpreter. A PATH-based `python3
--version` observation alone is never proof of the service interpreter.
Installers still need a fresh predeployment comparison.

If a PR body or deploy note cites an artifact SHA256, G10 requires a separate
JSON receipt with kind `artifact-hash`, repo, PR, H, issuer, sha256, and
artifact_ref. The issuer must be independent. This gate does not verify
post-merge binary hashes.

## Remote head and base race

G2 reads H from the PR and its remote head ref. G4 reads the remote base ref B,
uses the GitHub compare API for behind, and checks the trial merge commit's
parents before recording its tree as M. It rejects a
CI run tied to an older B. A passing receipt includes this command:

    gh pr merge PR -R OWNER/REPO --merge --match-head-commit H

The match-head option guards a head race. It does not atomically lock the base
branch. The director must re-read H and B immediately before merging; a base
advance after the receipt can still race that merge path.

G5 scans every GitHub compare patch with gitleaks and local location-only
patterns, and flags newly added build artifacts. Failed commands, omitted
patches, or the 300-file API ceiling are UNVERIFIED. Hit output contains only
file:line and class. Zero hits are not proof of no secrets.

## Bypass audit

    python3 director/merge_precheck.py audit --since 2026-09-25T06:17:38Z

Audit anti-joins JSON receipts against GitHub merged PRs for policy repos and
local wrk `job.spawned` event records. It counts actions without receipts,
receipts issued after the action, and reused receipts. Lookup failure is
UNVERIFIED. The audit detects bypasses; it cannot prevent them.

Run fixtures with `bash tests/test-merge-precheck.sh`. The three recorded
read-only replays in `tests/fixtures/merge-precheck-replays.json` are merges
from 2026-09-25 in scopefuel, panewire, and auto_trader. Their actual gate
merged; a retrospective precheck says UNVERIFIED or FAIL because current base
and historical evidence differ. A retrospective receipt is never retroactive
permission for that merge.
