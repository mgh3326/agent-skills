# Mock MCP connection isolation

Task 872 makes a mock spawn fail closed before its brief reaches the harness.
Exit 79 means the selected MCP connection, catalog, or harness isolation could
not be proved. There is no bypass. This change does not activate any endpoint,
edit a global configuration, or change an existing session.

Q-41 moves ordinary Codex auto_trader attachment from global to explicitly
reviewed trusted projects for context saving. See the
[render-only project migration runbook](codex-project-mcp.md). Attached project
or remaining unrelated global MCP catalogs still refuse guarded mock spawns;
the migration does not weaken this guard or make every context eligible.

## Why task 706 saw live KIS tools

On agent-skills origin/main 1f0613b0181ca346af604cec7572293a753f55a7,
bin/wrk:6085-6087 only added MCP_PROFILE to the pane environment. Codex reads
its user config.toml and project .codex/config.toml, rather than the project's
.mcp.json. A URL connection talks to an already running server; a client env
variable cannot change that server's startup profile. Codex's supported stdio
configuration instead has explicit command, args, cwd, and env fields.
[Codex MCP configuration](https://developers.openai.com/codex/mcp).

The read-only auto_trader origin/main source at
0cde15ddbee104bc527b45543a22f3d86544da10 establishes the other half:

- app/mcp_server/main.py:54 selects the profile from the server's environment;
  line 185 passes it to register_all_tools; lines 236-248 select stdio or network
  transport. Importing this module starts application configuration/monitoring
  setup, so do not import it for offline enumeration.
- app/mcp_server/profiles.py:18 defines the profile enum; lines 45-61 resolve
  absent/empty values to DEFAULT and reject unknown values.
- app/mcp_server/tooling/registry.py:471-478 registers generic and live KIS
  order tools for DEFAULT; lines 531-534 register only mock-pinned KIS order
  tools for HERMES_PAPER_KIS.
- app/mcp_server/tooling/orders_kis_variants.py:464,469,579,605 defines the
  hard-pinned live registrar and place/cancel/modify public names.

A sanitized Mac file inspection found auto_trader as a URL connection in
~/.codex/config.toml:12-13. No URL, headers, tokens, or server request was
included in the investigation. This explains 706's combination of a mock
pane env and live tool visibility; it does not establish any order execution.

## Harness loading paths and adapters

These are the eight kinds emitted by resolve_profile in bin/wrk. Aliases and
builder spellings share their kind's behavior. An inherited environment is
potential input for a local child, but only an explicit stdio env declaration
is accepted here. None of these clients can transmit its process environment
to an already running HTTP/SSE server as that server's process environment.

| Kind | Normal configuration sources | Mock adapter / refusal |
| --- | --- | --- |
| codex | CODEX_HOME/config.toml (normally ~/.codex/config.toml), ancestor .codex/config.toml, system/managed configuration, Apps and plugins. Both stdio and URL. | CLI mcp_servers.wrk_mock command/args/required overrides point to the checked private gateway. Apps, plugin, remote plugin and automatic skill MCP dependency connections are disabled. User/project catalogs must be empty; managed or plugin configuration refuses. |
| claude | ~/.claude.json user and project-local entries, project .mcp.json, user/project/local settings, plugins, managed MCP/settings. Both stdio and HTTP/SSE. | Clean local API contexts use --strict-mcp-config --mcp-config generated.json --setting-sources empty. OAuth/remote auth context, cached remote policy, pre-existing catalogs, plugin directories and managed overrides refuse. The generated map contains only wrk_mock. [CLI reference](https://code.claude.com/docs/en/cli-reference), [managed MCP](https://code.claude.com/docs/en/managed-mcp). |
| devin | ~/.config/devin/mcp_config.json, .devin/mcp_config.json, .devin/mcp_config.local.json and plugins. User settings ~/.config/devin/config.json are a separate file. Both stdio and HTTP/SSE. | Refused: installed devin --config overrides user settings, not a proved exclusive MCP catalog. Paths and transports are reported by installed devin mcp add --help; no server was contacted. |
| grok | ~/.grok/config.toml; .grok/config.toml from cwd through Git root; compatibility ~/.claude.json, .cursor/mcp.json, project .mcp.json; plugins and leader process state. Both stdio and HTTP/SSE. | Refused: no verified exclusive catalog override in installed CLI. Config names merge and compatibility files add connections. [Grok MCP](https://docs.x.ai/build/features/mcp-servers). |
| kimi | KIMI_CODE_HOME/mcp.json (normally ~/.kimi-code/mcp.json), cwd .kimi-code/mcp.json, plugin manifests. Both stdio and HTTP/SSE. | Refused: installed Kimi Code CLI merges these catalogs and has no exclusive MCP file flag. The legacy Python kimi-cli's --mcp-config-file is a different product and is not used as evidence for the installed Kimi Code binary. [Kimi Code MCP](https://moonshotai.github.io/kimi-code/en/customization/mcp.html). |
| kiro | ~/.kiro/settings/mcp.json, .kiro/settings/mcp.json, agent mcpServers/includeMcpJson and Powers/registry sources; KIRO_HOME can relocate global state. Both stdio and URL. | Refused: no verified adapter for the installed wrk/herdr path. Agent-only selection may support a future adapter, but the CLI was absent on the development Mac. [Kiro MCP](https://kiro.dev/docs/mcp/configuration/). |
| opencode | ~/.config/opencode/opencode.json or .jsonc, project opencode.json/.jsonc, OPENCODE_CONFIG and inline overrides, .opencode directories/plugins, remote organizational and managed config. Local stdio and remote URL. | Refused: custom files are additive override layers, not proved exclusive connections. [OpenCode configuration](https://opencode.ai/docs/config/). |
| agy | ~/.gemini/config/mcp_config.json, installed legacy ~/.gemini/antigravity-cli/mcp_config.json, .agents/mcp_config.json, plugins. Local stdio and remote serverUrl. | Refused: no exclusive catalog adapter proved. Installed binary path literals also include /antigravity-cli/settings.json and /config/mcp_config.json. Version-dependent configuration paths must be rechecked by desk. [Antigravity MCP](https://www.antigravity.google/docs/cli/mcp/). |

Unsupported means refused, even if a project file appears safe. This deliberately
reduces availability until a harness adapter proves every loaded catalog source.
An upgrade, new harness, or new transport requires the same proof and fake tests.
Claude subscription/OAuth contexts are also unsupported: server-managed policy
can provide additional MCP servers regardless of ordinary file selection. The
guard checks credential/cache existence and account metadata without reading
credentials or querying account services. It does not provision an API context
or require an operator to buy one; that path is simply refused if not available.

## Connection and catalog verification

Use Python 3.11+ in the wrk execution environment (or install tomli for an older
Python). There is no best-effort TOML parser fallback. The guard uses only the
Python standard library plus that optional parser.

After final local host, harness, cwd and pane env resolution, wrk generates a
private plan outside the worktree. It then:

1. Requires explicit MOCK_MCP_PROFILE and WRK_MOCK_MCP_CONFIG. Missing, unknown,
   unreviewed, default/full profiles and URL descriptors refuse.
2. Enumerates the relevant user, ancestor/project, plugin and known managed
   sources. Any conflicting catalog, unreadable file, symlink file, managed
   override or plugin directory refuses. Checks are conservative, including
   dormant profile tables and Claude entries for other projects.
3. Starts exactly one declared stdio process with explicit MCP_PROFILE and
   MCP_TYPE=stdio. Only PATH/HOME/TMPDIR/locale/system essentials are inherited;
   ENV_FILE and credential variables are not forwarded. Descriptors cannot
   provide env-file arguments or additional environment keys.
4. Initializes that process and enumerates all tools/list pages. Duplicate
   names, cursor loops, excessive pages, missing tools, extra tools, live names,
   generic order names and unreviewed aliases refuse.
5. Generates a harness-specific connection to a private Unix socket for that
   same process. Checks argv, explicit pane config-home/profile env, file hashes,
   source configuration fingerprints and socket identity before startup and
   again before brief injection. The final check also requires the harness to
   have actually loaded/attached to the gateway. Preparing a safe connection
   while using a different connection cannot satisfy this check.
6. During the session exposes only reviewed tools. Each tools/list and
   tools/call rechecks the full upstream catalog. Tool calls outside it and
   resource/prompt/other MCP channels are not forwarded. Unexpected catalog
   changes fail the request instead of widening the capability surface.

Initialization/catalog RPCs retain a 10-second read deadline. Approved tool
calls have no gateway deadline; the harness controls its tool timeout, so a
slow call is not falsely reported as an isolation refusal while it continues
upstream. The client loop observes disconnect after an in-flight call returns;
the owned plan stop operation can interrupt a pending call during cleanup.

The reviewed offline table is wrk-mcp/profiles.json, copied as data from
auto_trader tests/mcp_server/profile_tool_snapshot.json at the source commit
above. It was not generated by importing or running the application. Accepted
profiles are hermes-paper-kis (123 or 141 tools, feature gates off/on),
shadow-replay (7), watch_repricing (18), and fill-watch-context (2). Other
recognized application profiles remain unreviewed here and refuse.

The table's SHA-256 is pinned in the helper. A new alias cannot be admitted by
editing an operator allowlist or this JSON alone; table updates require review
of the source registration semantics and an explicit code/policy change.
Live-name/generic-order checks independently reject such names even under a
new table hash. This is a closed catalog and trusted server implementation
boundary; it is not a broker sandbox for the harness's shell tools.

The socket directory is mode 0700; socket and generated files are mode 0600.
One harness may attach. Closing that connection stops its upstream; a spawn
failure stops the owned gateway; an unattached gateway expires after 180 seconds.
Plan artifacts may be retained for review, with no endpoint values in logs.
Socket absence identifies an inactive plan directory for operator cleanup.

## Descriptor and activation

This generic descriptor contains no URL, secrets or env-file path:

~~~json
{
  "profile": "hermes-paper-kis",
  "server": {
    "command": "/opt/reviewed-mcp/profile-server",
    "args": [],
    "cwd": "/opt/reviewed-mcp",
    "env": {"MCP_PROFILE": "hermes-paper-kis", "MCP_TYPE": "stdio"}
  }
}
~~~

Keep the real descriptor private to the execution host. Both prepare and a mock
spawn start its declared stdio process. During implementation and testing use
only the fake server in the targeted tests. Do not substitute an application
server, URL endpoint, broker service, env-file wrapper or production DB.

After merge, installation and activation belong to director/operator-desk.
The worker must not run install.sh or change the active wrk. Desk must review the
declared executable and its automatic configuration loading independently.
Create a dedicated harness configuration context with no other MCP/plugin
catalog rather than changing operator connections as part of this PR. This
worker neither provisions nor copies authentication or secrets.

For a separately authorized fresh local spawn, desk supplies the private
descriptor and profile in the invocation environment. Reuse the normal task,
quota and classification arguments:

~~~sh
MOCK_MCP_PROFILE=hermes-paper-kis WRK_MOCK_MCP_CONFIG=/private/operator/mock-mcp.json \
  wrk spawn --host local -L mock -c /work/reviewed-project -m codex-sol \
  -p /private/operator/brief.md -w worker -l mock-worker --t T3 --task 123
~~~

Use fresh guarded spawns for mock work. Bare harness resume/restore, attaching
to a pre-existing session, or changing connections after spawn are not covered
by this entrypoint. Existing exposed sessions require desk mitigation; this
change cannot revoke their capabilities.

SSH and hub spill-over mock spawns refuse before delegation/copy/probing. Auto
placement is checked after its final host decision, and explicit remote mock
placement refuses before an admission failure can turn it into a local spawn.
The current remote contracts cannot attest the execution host's guard/config.
Desk can separately install and verify this version on a host and invoke its
local wrk there; this PR does not do that and does not transfer descriptors.

## NCP checklist for operator-desk, as the non-root session user

The implementation worker must not SSH to NCP. Desk performs this checklist
after its own authorization and records sanitized evidence in its private inbox:

- Check id -u is nonzero, the intended account/cwd, installed wrk/helper/policy
  commit and hashes, Python/parser version, and the actual harness binary path.
  Stop on any version mismatch or unknown loading path.
- Inspect only configuration files and offline profile data. Record filenames,
  source scopes, server names, transport types and tool names/counts; redact
  URLs, headers and credential values. Do not read env/secrets files or import
  application/server main. Do not call a real server, DB or broker for this check.
- For Codex enumerate config-home, every ancestor project config, managed
  sources, plugins and Apps. For Claude enumerate user/project/local, plugin
  and managed settings/MCP, including policies supplied outside local files.
  An unresolved source is a stop condition, not proof of an empty catalog.
- Verify the selected offline table against the source registration and feature
  gates. Check live/generic/alias surfaces explicitly. A stale or different
  catalog requires a reviewed policy update before activation.
- Run the three targeted test files with fake-only fixtures. Record allowed spawn
  with a loaded gateway, ignored-env/full catalog refusal, alias/live refusal,
  conflicting-source refusal, unloaded gateway refusal and injection absence.
- Record unsupported Devin/Grok/Kimi/Kiro/OpenCode/AGY and both remote routes as
  refused. Do not replace the refusal with inherited MCP_PROFILE or a project
  .mcp.json assertion. Run full agent-skills tests only through the authorized
  desktop wrk heavy path, coordinated by the builder.
- Separate offline verification from activation. If any additional evidence
  would require a real tools/list, server start, env-file path, DB or broker
  operation, record the exact needed action and stop until separately authorized.
- After separately authorized activation, start a new guarded mock session and
  confirm its loaded gateway/profile/catalog; never test safety by placing,
  modifying or cancelling an order. Record how exposed old sessions were
  mitigated and how resume/restore is prevented. Do not publish local endpoints.

Targeted development command (three files, no full suite):

~~~sh
python3.11 -m unittest discover -s tests -p 'test_wrk_*mcp*.py' -v
~~~

The mutant suite requires assertion failures after a forbidden action is
admitted. Parser crashes, application errors or arbitrary nonzero exits do not
count as mutation evidence. It includes consumer-level refusal and absent brief
assertions, runtime tool/method/drift checks and both remote routing guards.
