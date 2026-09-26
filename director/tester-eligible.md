# Shadow tester eligibility

The command reads a policy snapshot, a Git diff, wrk job records, and a tester
report. It writes one JSON receipt and one summary line. It detects missing or
conflicting evidence. It cannot prevent a spawn or merge outside the command.

The shared policy loader, profile resolver, CI attempt reader, and receipt writer are in
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
diffs are UNVERIFIED. pr may be absent before the PR exists. Pre-merge requires
pr, trial_merge_tree, and ci. It recomputes the trial merge tree, reads the
exact GitHub Actions run and attempt, checks its PR head and base, and requires
the policy-listed jobs to succeed. It also checks the current GitHub head and
remote base. The declared repo name must match origin. An auto_trader
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
effort. The quota launch model and grade must match the resolved tester, and
its profile must permit tester use on the declared surface. If actual provenance
cannot be established, the result is UNVERIFIED.

For same-family verification, same_family contains reversible,
excluded_surface, directed_brief_ref, independent_counterexample_ref,
qualification_ref, ci_run_id, ci_attempt, ci_status=success, and report_phrase. T3 has no
same-family exception. Missing exclusion proof is UNVERIFIED; a gate or
delivery path is excluded even when the evidence claims otherwise. The
required grade and actual implementation grade must both be A+ or below.

A T3 task split into a core part and peripheral parts is declared in
split. split contains parent_task (never the task itself), part=core or
peripheral, and the core approval-boundary list boundary={paths, symbols}
(paths and symbols that are core: guard wiring, safety DB constraints,
error paths, lock/transaction lifetime, state/DB/exception boundary).
parent_task must be a string or integer and parent_t, when given, must
be T3. A peripheral part must also name split.contract_path: a
repo-relative JSON file present at head whose contents supply the
boundary (a top-level boundary object or bare paths/symbols). A contract
is a reviewed, versioned source for the boundary; a self-declared inline
boundary cannot approve a peripheral part on its own, though an inline
boundary may be given alongside the contract and must then match it
member-for-member. A core part may rely on an inline boundary. Paths are
normalized before comparison (a leading ./, doubled slashes, and empty
segments collapse; absolute paths, .., backslashes, and control
characters are rejected), and path and symbol lists are sorted before
hashing so reordered members are the same boundary. Optional
split.behaviour_checks lists {id, result, ref} evidence where result is
pass or fail.

For a peripheral part the command compares the changed paths, the changed
symbols and call relations (a changed call site into a core symbol counts,
including added or removed lines and the enclosing-function hunk context),
removed definitions still referenced from boundary paths at head, and the
boundary from the contract. Identifiers bound to a boundary module or
symbol at head — an import alias (from boundary import x as y, import
boundary.mod as m) or an assignment whose value names a boundary symbol
or module — count as boundary names too, so calls through an alias are
still touches. Touching the boundary — a boundary path, the contract
file, a core symbol or bound alias, an import of a boundary module, or a
removed symbol still referenced from core — is FAIL with reason
PERIPHERAL_TOUCHES_CORE and the part must be re-run as T3. A missing or
unusable boundary or contract, an unreadable diff, a binary or
uninspectable change, a dynamically assembled name (a non-literal
getattr/setattr/delattr, exec, eval, __import__, importlib, globals, or
vars use that cannot be resolved to a literal), a failed or malformed
behaviour check, or anything else that cannot be classified is
UNVERIFIED with NEEDS_CLASSIFICATION or SPLIT_BOUNDARY_MISSING — never
a lower T. The boundary is required for both parts; a core declaration
without a usable boundary is SPLIT_BOUNDARY_MISSING. A clean peripheral
keeps its declared T subject to the existing surface floor. A core part
always raises the floor to T3 regardless of the diff shape. The receipt
records the split verbatim and split_analysis with the parent task, the
part, the boundary list hash, the contract path and hash, the paths
checked, the detected core touches, and the unclassifiable paths; the
split declaration is bound to the previous receipt, so a changed
declaration invalidates earlier stages.

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
action IDs. The merged PR head and repository must match the receipt. A spawn
event without a repository or head is matched only if its job directory
contains a same-job eligibility evidence file that supplies the missing
identity; otherwise it counts as missing. Use
--jobs-dir and --receipt-dir for other snapshots. Older wrk spawn events do
not identify tester roles, so the spawn count includes all jobs in the chosen
window and is an upper bound on tester bypasses.
