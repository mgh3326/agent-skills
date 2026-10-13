# M1 operations without SSH

## Issue an instruction

Write the instruction JSON as an hk note at `ops/node/<machine>/instr/<id>`. Use a fresh id matching `YYYYMMDD-NNNN-suffix`, and set `v` to 1, `machine` to the target identity, and the requested action fields. Emit a `lane.event` to lane `m1-ops` with text `node-ops apply KEY`. Check that the event has `delivered_at`, then read `ops/node/<machine>/receipt/<id>`. Accept a repo update only when the receipt has `created_by` equal to `mac-work`, the matching id, and `after` equal to the requested sha.

If no receipt arrives within 15 minutes, send a status instruction and then escalate to the operator.

## Check status from mbp

Use `panewire hub-status`, `panewire sessions find`, and `panewire fleet-census` to check the hub, sessions, and fleet. The status instruction reports revisions, binary versions, pane metadata, and free disk space; it does not report pane text.

## Hand off files

Use git branches for code. Use hk docs for small text. Use hk attach for files up to 20 MB, recording the sha256 in an hk doc. For files above 20 MB, use Drive and record its path and sha256 in hk.

A node-ops-free helper example is `handoffkeep attach put <file>` (it prints the sha256). On the other machine run `handoffkeep attach get <sha> -o <file>`, then compare sha256. The 1 MB round trip is for desk after merge and deploy; it is not part of this PR.

## Keep lanes separate

`m1-ops` is separate from `pa-m1`, which is pa-integrator's lane on mac-work wW:p1 with parent pa-integrator. It is also separate from `mac-work-default`.

## Tailscale-only work

Use Tailscale for interactive debugging, reading pane screens, installs outside node-ops, and recovery of the pane or daemon.

## Set up the pane

The operator sets up the `m1-ops` pane locally on M1. Its cwd is `$HOME/.agents/skills`, so `bin/node-ops` resolves there. The agent loads the node-ops skill.
