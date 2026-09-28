"""Assertion-RED guard mutants, on fake fixtures only (no crash evidence)."""
import asyncio
import json
from pathlib import Path
import re
import subprocess
import time
import unittest

import test_wrk_mock_mcp as fixtures
from test_wrk_mock_mcp import PROFILE, load


class GuardMutants(unittest.TestCase):
    def test_stalled_call_disconnect_cleanup_mutant(self):
        rig = self.rig()
        rig.test_stalled_call_disconnect_stops_gateway_and_owned_upstream()
        rig = self.rig()
        source = rig.helper.read_text().replace(
            "                if owns_attach:\n                    stop.set()",
            "                if False:\n                    stop.set()", 1)
        rig.helper.write_text(source)
        self.red("stalled-call-disconnect-cleanup", rig.test_stalled_call_disconnect_stops_gateway_and_owned_upstream)

    def test_stalled_call_explicit_stop_cleanup_mutant(self):
        rig = self.rig()
        rig.test_stalled_call_explicit_stop_stops_gateway_and_owned_upstream()
        rig = self.rig()
        source = rig.helper.read_text().replace(
            "            for task in tuple(client_tasks):\n                task.cancel()",
            "            for task in tuple(client_tasks):\n                pass", 1)
        rig.helper.write_text(source)
        self.red("stalled-call-explicit-stop-cleanup",
                 rig.test_stalled_call_explicit_stop_stops_gateway_and_owned_upstream)
        # The mutant uses an eight-second owned fixture stall. Wait for that
        # fixture to finish so this RED probe leaves no background process.
        socket = Path(json.loads(Path(rig.plans[-1]).read_text())["socket"])
        for _ in range(100):
            if not socket.exists():
                break
            time.sleep(0.1)
        self.assertFalse(socket.exists(), "mutant fixture did not clean up after its bounded stall")

    def test_mutable_plan_binding_consumer_and_startup_mutants(self):
        rig = self.rig()
        rig.test_consumer_mutated_plan_refuses_extra_connection_before_start_or_brief()
        rig = self.rig()
        self.skip_reason(rig, "prepared connection binding changed")
        extra_log = rig.mutate_plan_before_consumer_extraction()
        result, log = rig.consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agent prompt ", log)
        self.assertTrue(extra_log.exists())
        catalogs = json.loads((rig.base / "connected").read_text())
        self.assertIn("kis_live_place_order", catalogs["unchecked_fixture"])
        self.red("consumer-plan-binding-refusal", lambda: rig.assertRefused(result))
        self.red("consumer-plan-binding-injection-absent",
                 lambda: self.assertNotIn("agent prompt ", log, "forbidden brief was injected"))
        rig = self.rig()
        rig.test_mutated_plan_before_daemon_load_never_starts_upstream()
        rig = self.rig()
        self.skip_reason(rig, "prepared connection binding changed")
        self.red("plan-binding-before-upstream", rig.test_mutated_plan_before_daemon_load_never_starts_upstream)

    def test_external_profile_catalog_and_selector_mutants(self):
        rig = self.rig()
        rig.test_external_codex_profiles_refuse_consumer_and_late_attachment()
        rig = self.rig()
        source = rig.helper.read_text().replace('paths += sorted(conf_home.glob("*.config.toml"))', 'paths += []')
        rig.helper.write_text(source)
        home = Path(rig.env["CODEX_HOME"])
        home.mkdir()
        (home / "hidden.config.toml").write_text('[mcp_servers.hidden_fixture]\ncommand="/fixture/never-start"\n')
        result, log = rig.consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("agent prompt ", log)
        self.red("consumer-external-profile-refusal", lambda: rig.assertRefused(result))
        self.red("consumer-external-profile-injection-absent", lambda: self.assertNotIn("agent prompt ", log))
        rig = self.rig()
        args = ["prepare", "--kind", "codex", "--cwd", str(rig.cwd), "--profile", PROFILE,
                "--config", str(rig.config), "--", "--profile", "hidden"]
        rig.assertRefused(rig.run_helper(*args))
        self.skip_reason(rig, "Codex profile selector cannot prove exclusive MCP catalog")
        result = rig.run_helper(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        rig.plans.append(result.stdout.strip())
        self.red("external-profile-selector", lambda: rig.assertRefused(result))

    def test_tool_call_must_not_inherit_catalog_timeout_mutant(self):
        rig = self.rig()
        rig.test_tool_call_outlives_catalog_deadline_and_preserves_next_response()
        rig = self.rig()
        source = rig.helper.read_text().replace("result = await rpc(method, params, timeout=None)",
                                               "result = await rpc(method, params)")
        rig.helper.write_text(source)
        self.red("tool-call-catalog-timeout", rig.test_tool_call_outlives_catalog_deadline_and_preserves_next_response)

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
        for name in ("submit_ticket_alias", "kis_live_modify_order", "place_order",
                     "toss_place_order", "toss_modify_order", "toss_cancel_order",
                     "toss_reconcile_orders", "live_reconcile_orders", "place_order_v2",
                     "mcp__auto_trader__place_order", "kis-live-place-order", "KisLivePlaceOrder"):
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

    def test_live_name_normalization_and_safe_mock_mutants(self):
        rig = self.rig()
        m = load(rig.helper)
        for name in ("KisLivePlaceOrder", "kis-live-place-order", "mcp__auto_trader__place_order"):
            self.assertTrue(m.live_order_surface(name))
        self.assertFalse(m.live_order_surface("kis_mock_place_order"))
        source = rig.helper.read_text().replace(
            'normalized = re.sub(r"[^a-z0-9]+", "_", snake.lower()).strip("_")',
            'normalized = name.lower()', 1)
        rig.helper.write_text(source)
        mutant = load(rig.helper)
        self.red("live-name-case-normalization", lambda: self.assertTrue(mutant.live_order_surface("KisLivePlaceOrder")))
        self.red("live-name-separator-normalization", lambda: self.assertTrue(mutant.live_order_surface("kis-live-place-order")))
        rig = self.rig()
        source = rig.helper.read_text().replace(
            'if normalized in {"kis_mock_place_order", "kis_mock_modify_order", "kis_mock_cancel_order"}:',
            'if False:', 1)
        rig.helper.write_text(source)
        mutant = load(rig.helper)
        self.red("safe-mock-order-remains-allowed", lambda: self.assertFalse(mutant.live_order_surface("kis_mock_place_order")))

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
