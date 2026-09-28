"""Assertion-RED guard mutants, on fake fixtures only (no crash evidence)."""
import asyncio
import json
from pathlib import Path
import re
import subprocess
import unittest

import test_wrk_mock_mcp as fixtures
from test_wrk_mock_mcp import PROFILE, load


class GuardMutants(unittest.TestCase):
    def rig(self):
        rig = fixtures.IsolationTests(methodName="test_supported_harnesses_exact_connection_and_single_upstream")
        rig.setUp()
        self.addCleanup(rig.tearDown)
        return rig

    def skip_reason(self, rig, reason):
        source = rig.helper.read_text()
        source = source.replace("if not ok:\n", "if not ok and reason != " + repr(reason) + ":\n", 1)
        rig.helper.write_text(source)
        return load(rig.helper)

    def expect_refusal(self, module, call):
        try:
            call()
        except module.Refused:
            return
        # Other exceptions propagate and do NOT count as mutation evidence.
        raise AssertionError("guard admitted the forbidden behavior")

    def red(self, name, probe):
        with self.assertRaises(AssertionError) as caught:
            probe()
        print("ASSERTION-RED " + name + ": " + str(caught.exception).splitlines()[0][:180], flush=True)

    def test_missing_unknown_default_full_profile_mutants(self):
        for value in ("", "unknown", "default", "full"):
            rig = self.rig()
            original = load(rig.helper)
            self.expect_refusal(original, lambda: original.policy(value))
            source = rig.helper.read_text().replace("def policy(profile):\n", "def policy(profile):\n    profile = " + repr(PROFILE) + "\n")
            rig.helper.write_text(source)
            m = load(rig.helper)
            self.red("explicit-profile-" + (value or "missing"), lambda: self.expect_refusal(m, lambda: m.policy(value)))

    def test_manifest_env_and_transport_mutants(self):
        rig = self.rig()
        rig.connection["server"]["env"] = {}
        rig.write_connection()
        m = load(rig.helper)
        self.expect_refusal(m, lambda: m.descriptor(rig.config, PROFILE))
        m = self.skip_reason(rig, "missing explicit server profile env propagation")
        self.red("explicit-upstream-env", lambda: self.expect_refusal(m, lambda: m.descriptor(rig.config, PROFILE)))
        rig = self.rig()
        rig.connection = {"profile":PROFILE,"server":{"url":"https://example.invalid/mcp"}}
        rig.write_connection()
        m = load(rig.helper)
        self.expect_refusal(m, lambda: m.descriptor(rig.config, PROFILE))
        source = rig.helper.read_text().replace("def descriptor(path, profile):\n", "def descriptor(path, profile):\n    return read_json(path)\n")
        rig.helper.write_text(source)
        m = load(rig.helper)
        self.red("stdio-transport-no-URL-fallback", lambda: self.expect_refusal(m, lambda: m.descriptor(rig.config, PROFILE)))

    def test_policy_pin_alias_and_live_surface_mutants(self):
        for name in ("submit_ticket_alias", "kis_live_modify_order", "place_order"):
            rig = self.rig()
            path = rig.repo / "wrk-mcp/profiles.json"
            d = json.loads(path.read_text())
            d["profiles"][PROFILE][0].append(name)
            path.write_text(json.dumps(d))
            if name != "submit_ticket_alias":
                import hashlib
                rig.helper.write_text(re.sub(r'POLICY_SHA256 = "[a-f0-9]+"', 'POLICY_SHA256 = "' + hashlib.sha256(path.read_bytes()).hexdigest() + '"', rig.helper.read_text()))
                reason = "live order surface in reviewed profile table"
            else:
                reason = "reviewed profile table changed (including aliases); review required"
            m = load(rig.helper)
            self.expect_refusal(m, lambda: m.policy(PROFILE))
            m = self.skip_reason(rig, reason)
            self.red("policy-" + name, lambda: self.expect_refusal(m, lambda: m.policy(PROFILE)))

    def test_unexpected_catalog_and_duplicate_mutants(self):
        for name in ("kis_live_place_order", "submit_ticket_alias", "duplicate"):
            rig = self.rig()
            m = load(rig.helper)
            variants = m.policy(PROFILE)
            names = variants[0] + ([variants[0][0]] if name == "duplicate" else [name])
            tools = [{"name":n} for n in names]
            reason = "invalid tool catalog" if name == "duplicate" else "unexpected tool/alias or missing tool; selected profile catalog does not match (no full fallback)"
            self.expect_refusal(m, lambda: m.catalog(tools, variants))
            m = self.skip_reason(rig, reason)
            self.red("catalog-" + name, lambda: self.expect_refusal(m, lambda: m.catalog(tools, variants)))

    def test_global_project_plugin_managed_and_unsupported_mutants(self):
        cases = ["global", "project", "plugin", "managed", "unsupported", "claude-policy"]
        for case in cases:
            rig = self.rig()
            kind = "codex"
            if case in {"global", "project"}:
                path = (rig.fixture_home if case == "global" else rig.cwd.parent) / ".codex/config.toml"
                path.parent.mkdir(exist_ok=True)
                path.write_text('[mcp_servers.extra]\nurl="https://example.invalid/mcp"')
                reason = "conflicting global/project MCP or plugin configuration"
            elif case == "plugin":
                path = rig.fixture_home / ".codex/plugins"
                path.mkdir(parents=True)
                (path / "installed.json").write_text('{}')
                reason = "plugin MCP catalog cannot prove isolation"
            elif case == "managed":
                path = rig.fixture_home / ".codex/managed_config.toml"
                path.parent.mkdir()
                path.write_text('')
                reason = "managed MCP/config override cannot prove isolation"
            elif case == "unsupported":
                kind = "grok"
                reason = "unsupported mock harness: no exclusive MCP configuration option; leader and project/plugin catalogs merge"
            else:
                kind = "claude"
                path = rig.fixture_home / ".claude/remote-settings.json"
                path.parent.mkdir()
                path.write_text('opaque fixture policy')
                reason = "Claude OAuth/remote policy context cannot prove exclusive MCP catalog"
            m = load(rig.helper)
            self.expect_refusal(m, lambda: m.isolation(kind, rig.cwd))
            m = self.skip_reason(rig, reason)
            self.red("harness-" + case, lambda: self.expect_refusal(m, lambda: m.isolation(kind, rig.cwd)))

    def test_exact_argv_harness_env_artifact_and_config_drift_mutants(self):
        for case in ("argv", "env", "cwd", "artifact", "config-drift"):
            rig = self.rig()
            r = rig.prepare()
            self.assertEqual(r.returncode, 0, r.stderr)
            path = r.stdout.strip()
            p = json.loads(Path(path).read_text())
            argv = p["argv"][:]
            cwd = p["cwd"]
            evidence = ["--wrk-pane-env", "--env", "MCP_PROFILE=" + PROFILE]
            for k, v in p["env"].items():
                evidence += ["--env", k + "=" + v]
            if case == "argv":
                argv += ["-c", 'mcp_servers.other.url="https://example.invalid/mcp"']
                reason = "checked harness argv differs from the loaded connection"
            elif case == "env":
                evidence = ["--wrk-pane-env"]
                reason = "missing/conflicting harness config env propagation"
            elif case == "artifact":
                Path(next(iter(p["artifacts"]))).write_text('{}')
                reason = "generated connection configuration changed"
            elif case == "cwd":
                cwd = str(rig.base)
                reason = "checked cwd differs from loaded harness cwd"
            else:
                # A harmless new config still changes the inspected layer set.
                (rig.cwd / ".mcp.json").write_text('{"mcpServers":{}}')
                reason = "harness config changed after connection generation"
            m = load(rig.helper)
            self.expect_refusal(m, lambda: m.verify(path, argv + evidence, cwd=cwd))
            m = self.skip_reason(rig, reason)
            self.red("connection-" + case, lambda: self.expect_refusal(m, lambda: m.verify(path, argv + evidence, cwd=cwd)))

    def test_consumer_catalog_guard_mutant_injects_forbidden_brief(self):
        rig = self.rig()
        rig.connection["server"]["args"].append("--ignore-env")
        rig.write_connection()
        reason = "unexpected tool/alias or missing tool; selected profile catalog does not match (no full fallback)"
        self.skip_reason(rig, reason)
        r, log = rig.consumer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("agent prompt ", log)
        self.red("consumer-catalog-refusal", lambda: rig.assertRefused(r))
        self.red("consumer-catalog-injection-absent", lambda: self.assertTrue("agent prompt " not in log, "forbidden brief was injected"))

    def test_consumer_pre_injection_recheck_mutant(self):
        rig = self.rig()
        source = rig.wrk.read_text().replace('  mock_mcp_verify --require-attached || return "$WRK_EXIT_MOCK_MCP_REFUSED"\n  spawn_deliver_brief', '  :\n  spawn_deliver_brief')
        rig.wrk.write_text(source)
        hook = "printf '%s' '{\"mcpServers\":{\"extra\":{\"command\":\"fake\"}}}' > '" + str(rig.cwd / '.mcp.json') + "'"
        r, log = rig.consumer(hook=hook)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("agent prompt ", log)
        self.red("consumer-pre-injection-refusal", lambda: rig.assertRefused(r))
        self.red("consumer-pre-injection-injection-absent", lambda: self.assertTrue("agent prompt " not in log, "forbidden brief was injected"))

    def test_consumer_required_connection_attachment_mutant(self):
        rig = self.rig()
        self.skip_reason(rig, "required MCP connection was not loaded by the session")
        r, log = rig.consumer(load_mcp=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("agent prompt ", log)
        self.red("consumer-required-connection-loaded", lambda: rig.assertRefused(r))

    def test_pagination_guard_mutant(self):
        rig = self.rig()
        rig.connection["server"]["args"].append("--page-live")
        rig.write_connection()
        rig.assertRefused(rig.prepare())
        source = rig.helper.read_text().replace('cursor = page.get("nextCursor")', 'cursor = None')
        rig.helper.write_text(source)
        r = rig.prepare()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.red("full-catalog-pagination", lambda: rig.assertRefused(r))

    def test_runtime_tool_call_method_and_catalog_revalidation_mutants(self):
        for case in ("tool-call", "method", "drift"):
            rig = self.rig()
            tools = rig.base / "tools.json"
            safe = json.loads((rig.repo / "wrk-mcp/profiles.json").read_text())["profiles"][PROFILE][0]
            tools.write_text(json.dumps(safe))
            rig.connection["server"]["args"].append(str(tools))
            rig.write_connection()
            source = rig.helper.read_text()
            if case == "tool-call":
                source = source.replace("if not ok:\n", "if not ok and reason != 'unapproved tool/alias call':\n", 1)
            elif case == "method":
                source = source.replace('raise Refused("only reviewed tools are exposed; MCP method refused")', 'result = await rpc(method, q.get("params", {}))')
            else:
                source = source.replace('params.get("name") in catalog(await list_tools(), variants)', 'params.get("name") in set().union(*map(set, variants))')
            rig.helper.write_text(source)
            r = rig.prepare()
            self.assertEqual(r.returncode, 0, r.stderr)
            p = json.loads(Path(r.stdout.strip()).read_text())

            async def call_mutant():
                reader, writer = await asyncio.open_unix_connection(p["socket"])
                async def request(method, params=None):
                    writer.write((json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params or {}})+'\n').encode())
                    await writer.drain()
                    return json.loads(await reader.readline())
                await request("wrk/attach")
                if case == "drift":
                    tools.write_text(json.dumps(safe + ["place_order"]))
                if case == "method":
                    result = await request("resources/read", {"uri":"fake:order-channel"})
                else:
                    result = await request("tools/call", {"name":"kis_live_place_order" if case == "tool-call" else "kis_mock_place_order", "arguments":{}})
                writer.close()
                await writer.wait_closed()
                return result
            result = asyncio.run(call_mutant())
            self.assertIn("result", result)
            self.red("runtime-" + case, lambda: self.assertIn("error", result, "forbidden upstream request was forwarded"))

    def test_remote_explicit_and_auto_host_mutants(self):
        rig = self.rig()
        source = rig.wrk.read_text().replace('if [[ "$requested" != auto && "$requested" != local && "$requested_lane" == mock ]]; then', 'if false; then')
        rig.wrk.write_text(source)
        (rig.base / "hosts.toml").write_text('[hosts.fakehost]\nvia="ssh"\n')
        r, log = rig.consumer(host="fakehost")
        self.assertEqual(r.returncode, 0, r.stderr)  # admission fallback is fake local only
        self.red("explicit-remote-no-downgrade", lambda: rig.assertRefused(r))
        rig = self.rig()
        original = rig.wrk.read_text()
        router = original[original.index("spawn_router_cmd() {"):original.index("\nhosts_cmd() {")]
        stubs = r'''
WRK_EXIT_MOCK_MCP_REFUSED=79
WRK_EXIT_ACTIVE_JOB_DUPLICATE=74
WRK_EXIT_JOB_STATE_UNREADABLE=75
wrk_option_token() { return 1; }
arbiter_preflight_active_duplicate() { return 0; }
spillover_config() { echo "$FIXTURE_CONFIG"; }
spillover_hub_placement() { SPILL_HUB_HOST=fakehost; SPILL_HUB_REASON=fixture; SPILL_HUB_CANDIDATES=(); return 0; }
spillover_hosts() { echo fakehost; }
spillover_host_via() { echo hub; }
spillover_log() { :; }
spillover_hub_spawn() { echo forbidden-brief-delegation; }
'''
        args = ['bash', '-c', stubs + router + '\nspawn_router_cmd -c /fixture -p /fixture/brief -m codex-sol -L mock --t T1 -l fixture']
        (rig.base / "hosts.toml").write_text('fixture')
        env = dict(rig.env, FIXTURE_CONFIG=str(rig.base / "hosts.toml"))
        r = subprocess.run(args,env=env,text=True,capture_output=True)
        rig.assertRefused(r)
        args[2] = args[2].replace('if [[ "$selected" != local && "$execution_lane" == mock ]]; then', 'if false; then')
        r = subprocess.run(args,env=env,text=True,capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("forbidden-brief-delegation", r.stdout)
        self.red("auto-remote-execution-host", lambda: rig.assertRefused(r))


if __name__ == "__main__":
    unittest.main()
