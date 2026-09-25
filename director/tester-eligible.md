# Shadow tester eligibility

The command reads a policy snapshot, a Git diff, wrk job records, and a tester
report. It writes one JSON receipt and one summary line. It detects missing or
conflicting evidence. It cannot prevent a spawn or merge outside the command.

The shared policy loader, profile resolver, and receipt writer are in
director/gate_common.py. Merge-precheck should import this module. The sole
versioned policy artifact is director/gate_policy.json. It pins local source
hashes and expires after the shadow week. A source change requires a reviewed
new revision. Provider family means the model provider, never the launcher.

Run each call from the checkout:

    python3 director/bin/tester-eligible check --stage pre-spawn --evidence /path/evidence.json
    python3 director/bin/tester-eligible check --stage post-landing --evidence /path/evidence.json
    python3 director/bin/tester-eligible check --stage pre-merge --evidence /path/evidence.json

The default receipt directory is ~/work/herdr-inbox/receipts. Supply
--receipt-dir to override it. Keep each receipt and give the next call its path
in previous_receipt. A changed head, base, diff, contributor union, policy,
planned profile, or actual profile invalidates the earlier verdict.

The evidence JSON includes task, contract_revision, job, repo, repo_path, head,
base, issuer, declared_t, required_grade, implementation_grade, contributors,
and tester. repo_path is the absolute checkout; head and base are full commit
SHAs. The command derives a floor from their diff. Empty or unclassifiable
diffs are UNVERIFIED. The optional fields pr, trial_merge_tree, and ci are
preserved in the receipt. Pre-merge requires pr and checks the current GitHub
head and remote base. The declared repo name must match origin. An auto_trader
diff gets T2 only when every path is on the versioned nontrading path list;
unknown paths are UNVERIFIED. T0 additionally requires local_only=true.

Contributors is an array of initial, fix, and prescription contributors. Each
entry includes profile, model, effort, role, kind, session, and worktree. The
tester has planned_profile and planned_effort at pre-spawn. Later calls also
need actual_profile, actual_model, actual_effort, session, worktree, pane,
job_record_dir, model_observation_path, and model_observation_sha256. The job
directory contains wrk job.spawned and quota_pool.record events. The model
observation is a retained JSON record with source=pane, job, pane, model, and
effort. The command also reads the live pane footer and compares its model and
effort. If actual provenance cannot be established, the result is UNVERIFIED.

For same-family verification, same_family contains reversible,
excluded_surface, directed_brief_ref, independent_counterexample_ref,
qualification_ref, ci_run_id, ci_attempt, ci_status=success, and report_phrase. T3 has no
same-family exception.

At pre-merge the tester provides report_path and report_sha256. The report
includes exact lines TASK, JOB, REPO, TESTED_HEAD, and TESTER_SESSION matching
the current input. Its last nonempty line is VERDICT: PASS @ followed by the
full tested head. Quoted or fenced verdicts do not count. Keep the report
outside the worktree.

The exit code is zero only when every check is PASS or an explicit N/A with a
reason and policy reference. The post-merge artifact hash is N/A here: the
binary hash incident requires an independent build or delivery receipt.

## Audit

    python3 director/bin/tester-eligible audit --repo owner/agent-skills --since 2026-09-25T00:00:00Z

Audit compares gh merged PRs and wrk job.spawned events with receipts. It
counts actions without receipts, receipts later than actions, and reused
action IDs. Use --jobs-dir and --receipt-dir for other snapshots. Older wrk
spawn events do not identify tester roles, so the spawn count includes all
jobs in the chosen window and is an upper bound on tester bypasses.
