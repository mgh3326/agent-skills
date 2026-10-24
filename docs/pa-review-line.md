# PA-REVIEW line format

The form belongs to pa-integrator. Changes go through director-1. The format and parser follow hk 1937 comments 7116, 7119, and 7129.

## Form 1, primary (v1)

PA-REVIEW v1 task=<hk id> job=<job id> head=<sha>|none outcome=<outcome> round=<K> reason=<code> [note=<free text>]

- Keys appear in exactly this order, separated by single spaces: v1, task, job, head, outcome, round, reason, then optionally note.
- task is a positive integer. job is one token with no spaces.
- head is 7 to 40 lowercase hex characters, or none. none is normal for art and Blender jobs with no repo commit; their delivery sha stays in pa-integrator's free-text comment.
- outcome is one of: accepted, rework, not-accepted, excluded.
- round is a positive integer.
- reason is one code. quality, scope and superseded are counted. quota, tooling, host and operator-cancel are uncounted. pa-integrator uses reason=quality for accepted rounds.
- note= is optional. It runs to the end of the line, is free text, and is never parsed.
- round fallback: if round= is absent from a v1 line (a v1 line that is otherwise exact), the round is the line's position among that job's lines, and the output says the round was derived.

Examples:

```text
PA-REVIEW v1 task=1942 job=asset-a head=abcdef1 outcome=accepted round=1 reason=quality note=looks good
PA-REVIEW v1 task=1942 job=asset-b head=none outcome=rework round=1 reason=scope
PA-REVIEW v1 task=1942 job=asset-c head=1234567 outcome=not-accepted round=2 reason=superseded
PA-REVIEW v1 task=1942 job=asset-d head=none outcome=excluded round=1 reason=operator-cancel
```

## Form 2, early (free text; lines already posted)

PA-REVIEW task=<hk id> job=<job id> outcome=<outcome> reason=<free text to end of line>

- Keys appear in exactly this order. reason is non-empty free text, may contain spaces, equals signs and punctuation, and is never parsed.
- There is no head and no round. The round is the line's position among that job's lines.
- Real examples:
  - PA-REVIEW task=1935 job=b1935 outcome=accepted reason=RS6 DRL corner clean + F-150 AT tread, tester PASS, QA 0 errors
  - PA-REVIEW task=1891 job=b1891 outcome=accepted reason=f5 PR #397 merged: clusters on RS6/G63/F-150 displays, G90 tips dark metal, CI pure + Unity PASS

## Shared semantics

- One line per judged round. Each rework is one bounce; a final outcome follows. The last line per job is final.
- "Last" means: ordered by comment created_at, then comment id, then position within the comment, across both forms.
- Counted or not:
  - outcome=excluded is uncounted;
  - in v1, a reason in the uncounted set is uncounted whatever the outcome;
  - a v1 line where outcome and reason disagree (for example not-accepted with reason=quota, or excluded with reason=quality) is reported as a warning, and the uncounted reading wins.
- Per task, the final outcome is that of the job whose final line is latest. The other jobs are listed under it.

## Scanner

Run `director/bin/pa-review-scan --task 1942` for TSV or add `--json` for the structured output consumed by K4. Repeat `--task` for several tasks, or use `--project ParkingArcade --state <state>` once for every state; each state is queried separately because a list response can truncate.

Only exact lines at the start of a comment or one of its lines, from an allowed author (default `pa-integrator`), and whose task id matches the posted task count. Other lines beginning with PA-REVIEW from an allowed author appear in the error output. Mentions elsewhere and lines by other authors are ignored.
