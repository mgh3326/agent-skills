# Codex auto_trader project attachment (Q-41)

Move auto_trader out of the user-wide Codex catalog so ordinary sessions do not
spend context on tools they do not need. This is a context-saving migration.
Normal operator capability and the separate mandatory mock isolation contract
retain their existing purposes. This PR supplies a render-only planner; desk
applies reviewed replacements after merge. No active configuration is changed
by the planner or by development tests.

## Supported configuration and project evidence

Validated against locally installed codex-cli 0.157.1 on 2026-09-28. Builder's
desktop reported codex-cli 0.158.0; the targeted test accepts a semantic CLI
version and still runs the full isolated configuration enumeration. A version
proxy exercises the 0.158.0 output while delegating enumeration to the local
installed binary; the desktop full suite must verify the real 0.158.0 binary.
Codex loads trusted project .codex/config.toml. Project .mcp.json is not the
Codex route. CLI overrides
take precedence, followed by nearest trusted project configuration, selected
profile, user configuration, cloud-managed defaults and system configuration.
[Official OpenAI configuration basics](https://learn.chatgpt.com/docs/config-file/config-basic).

HTTP connections support bearer_token_env_var and env_http_headers; stdio has
command/args/env. enabled_tools restricts the catalog, disabled_tools applies
after it, and tools.<name>.approval_mode preserves individual approval rules.
[Official OpenAI MCP configuration](https://developers.openai.com/codex/mcp),
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

The pinned [reviewed registry](../wrk-mcp/codex-projects.json) reflects builder's
2026-09-28 inventory of canonical checkouts under work and services. It contains
logical project IDs and evidence, without private endpoints or machine roots.

| Selected project | Evidence of direct need | Connection scope |
| --- | --- | --- |
| auto_trader-operator | AGENTS.md:24-30 requires operating briefing and four-lane routing; mock/CLAUDE.md:94-104 specifies profiles | Current approved read tool connection for the explicitly reviewed operator root. Mock work remains separately guarded. |
| auto_trader | Source 0cde15ddbee104bc527b45543a22f3d86544da10 app/mcp_server/main.py:54,185; app/mcp_server/README.md:2601-2613 documents Codex analysis MCP | Explicit development/analysis root, current approved read restrictions |
| strategy-lab | Source f226278cd2da002a85fc8d7e5c18c00733b33473 CLAUDE.md:23-25,41-44; .kickoff-brief.md:5 | Analysis only; current approved read restrictions; no order/proposal/watch/policy mutation |

tradingcodex-desk has a runtime caller, but its source
6cbd0b871ba7713fe7380d0393ab683047eaa622 AGENTS.md:47-49 requires the canonical
TradingCodex provider boundary. A direct Codex broker connector would conflict
with that rule. tradingcodex only has historical adapter references; prefect
uses CLI scheduling. agent-skills, admiral and handoffkeep have no demonstrated
ordinary-session MCP need in the inventory and receive no attachment. New
projects require reviewed evidence and a registry/pin update in code review.

There is no directory-name search or ancestor allow rule. Desk explicitly maps
each selected ID to one canonical, reviewed Git root. The tool checks root
markers and boundaries; desk must verify repository identity against inventory.
Each worktree needs its own project configuration review. Codex 0.157.1 can
inherit trust from the main repository for a linked worktree: if that worktree
has its own .codex/config.toml, the attachment can load without a separate
trust entry. Desk must inspect effective trust and configuration for every
worktree. Prepare a separate plan for each worktree before global replacement;
duplicate IDs and overlapping roots refuse. Never trust or attach a shared
work/services ancestor.

## Render-only migration contract

Use Python 3.11+. bin/wrk-codex-mcp-plan reads ONLY an explicit private input
bundle. It never discovers, reads or writes active user/project config contents,
looks up credentials, starts a command, connects to MCP, or grants trust. It
checks target file existence to require an explicit existing-project snapshot.
All validation precedes creating a new stage; every directory is mode 700 and
every file is mode 600. An existing stage refuses instead of overwriting it.

Desk prepares these owned mode-600 files inside a mode-700 bundle, outside
repositories and active configuration homes:

- global.toml: current user config snapshot, retaining unrelated settings and
  servers. Use the current restricted table with 30 enabled read tools; an old
  unrestricted backup is not the baseline.
- connection.toml: the exact current mcp_servers.auto_trader table plus all its
  nested tables, explicitly supplied by desk. Do not substitute the example
  template. It must match the global snapshot semantically, including every
  transport/auth, allow/deny list, enabled/required flag, timeout and approval.
- selection.json: the exact global target and reviewed project roots, using
  the schema below. root_reviewed is desk's repository/trust-location review,
  not an automatic grant of trust.
- projects/<id>.toml: snapshot of an existing selected project config. Use a
  null snapshot only when the target has no config. The planner never reads
  that target; it refuses a missing snapshot when the target already exists.

Generic selection example (paths are placeholders):

~~~json
{
  "schema": 1,
  "global_target": "/home/operator/.codex/config.toml",
  "projects": [
    {
      "id": "strategy-lab",
      "root": "/work/strategy-lab",
      "snapshot": "projects/strategy-lab.toml",
      "root_reviewed": true
    }
  ]
}
~~~

[The secrets-free project template](../wrk-mcp/codex-project.config.example.toml)
illustrates the supported HTTP/env-backed shape. Its single placeholder tool
and disabled server deliberately make it unsuitable as a migration input.
The planner copies desk's complete existing table instead of inventing tool
names, weakening approvals, or widening the approved 30-tool list. It enforces
the list's count and uniqueness and exact baseline equality; desk verifies that
the supplied names are the currently approved read tools.

Run from the reviewed checkout with a new output directory:

~~~sh
python3.11 bin/wrk-codex-mcp-plan \
  --input-dir /private/operator/q41-input-1 \
  --stage /private/operator/q41-proposals-1
~~~

Output contains global/config.toml, projects/<id>/.codex/config.toml and a private
manifest.json with proposed filenames, desk-only targets and content hashes.
The global proposal removes only the top-level auto_trader table and its nested
tables. Each project proposal preserves its unrelated settings and appends the
entire connection table. Both results must equal the expected parsed TOML.
Table spelling/comments and unrelated bytes are retained without reserialization.
Any forms the section splitter cannot prove losslessly, such as inline/dotted
server definitions or header-like multiline text, refuse with exit 79. Desk can
prepare reviewed explicit-table snapshots; the tool never falls back to a
partial transfer. Profile/plugin shadow attachments, project collisions,
unknown IDs, missing reviews, symlinks and staging overlapping active config,
inputs or the implementation repository also refuse. Error output withholds
input contents. Outputs may preserve sensitive unrelated user settings, so
keep the complete bundle and stage private and out of Git and reports.

The planner requires a still-attached current global baseline. After its removal,
future attachment changes require a new desk review; this tool does not infer a
connection from a backup, project, credential cache or arbitrary cwd.

## Non-root desk activation checklist after merge

1. Record nonzero id -u, installed Codex version, reviewed PR head, registry pin,
   exact global target and selected repository/worktree roots. Recheck inventory
   evidence and ancestor project, profile, managed and plugin layers. This plan
   removes only the user table; another layer can still expose auto_trader.
2. Prepare private snapshots and explicit connection. Verify the current 30
   approved read names, deny list and every approval/transport/auth field.
   No secret or endpoint values belong in public evidence. Do not use old full
   backups. Do not read prod env files or pass env-file paths to a process.
3. Render all worktree plans into new private stages. Review diffs and manifest
   hashes: only auto_trader leaves global; unrelated user/project metadata and
   all existing tool restrictions remain. Confirm targets and snapshot freshness
   against current files before applying anything. The planner supplies no apply
   or overwrite option.
4. Desk manually applies the reviewed global replacement and selected project
   files after merge. Review and grant trust only for each exact intended Git
   root through the installed client's supported trust workflow. Keep project
   settings private when they contain machine-specific connection details.
   Do not add a connector to agent-skills or broad ancestors.
5. Check effective config from an unrelated cwd, selected trusted roots and each
   worktree using the installed client's config enumeration. Record names/counts
   only. Config enumeration is not a real server tools/list or capability test;
   any such operation belongs to separately authorized activation work.
6. Desk manages existing-session restart/resume review. Removing config does not
   revoke already-loaded tools or change another harness's catalog. Recheck the
   actual loaded session configuration after activation; migration is not retroactive.
7. On NCP, the non-root desk account repeats exact host/root/version/config/trust
   checks locally. The implementation worker never SSHs, deploys or activates it.
   Use the [mock NCP checklist](mock-mcp-isolation.md) for mock sessions.

## Mock availability and fake verification

The [mock isolation guard](mock-mcp-isolation.md) remains mandatory. An attached
project auto_trader table, any competing global server, profile/plugin catalog,
or unresolved managed source refuses before harness start/brief injection.
Moving only auto_trader out of global does not make a user with other global
MCP servers eligible for a guarded mock spawn. This PR supplies no exclusive
adapter for simultaneous inherited catalogs, no guard bypass and no automatic
authentication migration. Codex/clean-local-context Claude adapters retain their
documented limits; six other kinds and remote spill-over still refuse. A clean
separately reviewed root/context is needed for the supported mock path.

Three targeted files, fakes/fixtures only:

~~~sh
python3.11 -m unittest discover -s tests -p 'test_wrk_*mcp*.py' -v
~~~

Q-41 tests check exact global/project transfer, HTTP env auth and approvals
offline, private staging/no active writes, attached-project mock refusal with
absent start/brief, and assertion-RED guard mutants. HOME, CODEX_HOME, Claude,
Kimi variants, Kiro and XDG homes are isolated before consumer spawns. Installed
Codex mcp list --json enumerates ONLY fake stdio definitions in fixture
homes: unrelated/untrusted roots lack auto_trader, the trusted selected Git
root and child cwd see its configured command/env. It starts no fake server or
API request. The locally observed 0.157.1 list JSON omits enabled_tools;
parsed proposal equality proves the exact tool/approval preservation
separately. Without an installed Codex binary that integration check skips
explicitly; desk must
verify its installed version. Full-suite execution belongs to builder's desktop
wrk heavy lane; never run it on this Mac with heavy_max=0.
