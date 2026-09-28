"""Targeted fake-only MCP isolation tests. Run with Python 3.11+.

All consumer processes use an empty fixture HOME and harness-specific homes.
No active harness/global configuration or application module is used.
"""
import asyncio
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PROFILE = "hermes-paper-kis"
FAKE = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
profile=os.environ.get('MCP_PROFILE')
if '--ignore-env' in args: profile='default'
if '--force-safe' in args: profile='hermes-paper-kis'
policy=json.loads(Path(args[0]).read_text())
tools=policy['profiles'].get(profile,[['kis_live_place_order','kis_live_modify_order','kis_live_cancel_order']])[0]
log=Path(args[1]); log.open('a').write('start '+str(os.getpid())+' '+str(profile)+'\n')
for line in sys.stdin:
 q=json.loads(line)
 if 'id' not in q:continue
 m=q['method']
 if m=='initialize':result={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'fake','version':'1'}}
 elif m=='tools/list':
  if len(args)>2 and not args[2].startswith('--'):tools=json.loads(Path(args[2]).read_text())
  result={'tools':[{'name':x,'description':'fake','inputSchema':{'type':'object'}} for x in tools]}
  if '--page-live' in args:
   if q.get('params',{}).get('cursor')=='second':result={'tools':[{'name':'kis_live_cancel_order','inputSchema':{'type':'object'}}]}
   else:result['nextCursor']='second'
 elif m=='tools/call':
  if '--stall-tool' in args:
   import time
   log.open('a').write('entered-stalled-fixture-call\n')
   time.sleep(120)
  if '--stall-tool-short' in args:
   import time
   log.open('a').write('entered-stalled-fixture-call\n')
   time.sleep(8)
  if '--slow-tool' in args:
   import time
   time.sleep(1.2)
  log.open('a').write('call '+q['params']['name']+'\n'); result={'content':[{'type':'text','text':'fake result'}]}
 else:result={}
 print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':result}),flush=True)
'''

HARNESS = r'''#!/usr/bin/env python3
# Read the ACTUAL start argv as a harness consumer, then run the declared MCP
# command. This is not a real harness, endpoint, or herdr session.
import json,os,subprocess,sys
from pathlib import Path
args=sys.argv[2:]; marker=Path(sys.argv[1])
if '--mcp-config' in args:
 servers=json.loads(Path(args[args.index('--mcp-config')+1]).read_text())['mcpServers']
else:
 values=dict(x.split('=',1) for x in args if x.startswith('mcp_servers.'))
 names={k.split('.')[1] for k in values}
 servers={name:{k:json.loads(values['mcp_servers.'+name+'.'+k]) for k in ('command','args')} for name in names}
procs=[]; catalogs={}
try:
 for name in sorted(servers,key=lambda name:name!='wrk_mock'):
  server=servers[name]
  proc=subprocess.Popen([server['command'],*server['args']],env=dict(os.environ,**server.get('env',{})),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
  procs.append(proc)
  for i,method in enumerate(('initialize','tools/list'),1):
   proc.stdin.write((json.dumps({'jsonrpc':'2.0','id':i,'method':method,'params':{}})+'\n').encode());proc.stdin.flush()
   r=json.loads(proc.stdout.readline())
   if 'error' in r:sys.exit(1)
  catalogs[name]=[tool['name'] for tool in r['result']['tools']]
 marker.write_text(json.dumps(catalogs))
 procs[0].wait()
finally:
 for proc in procs:
  if proc.poll() is None:
   proc.terminate();proc.wait(timeout=5)
'''


def load(path):
    loader = importlib.machinery.SourceFileLoader("mock_guard", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class IsolationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="test-wrk-mcp-")
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo"
        (self.repo / "bin").mkdir(parents=True)
        shutil.copytree(ROOT / "wrk-mcp", self.repo / "wrk-mcp")
        self.fixture_home = self.base / "fixture-user"
        self.fixture_home.mkdir()
        # Fixture host model only; production exposes no home/guard bypass.
        source = (ROOT / "bin/wrk-mock-mcp").read_text().replace("home = Path.home()", "home = Path(" + repr(str(self.fixture_home)) + ")")
        self.helper = self.repo / "bin/wrk-mock-mcp"
        self.helper.write_text(source)
        self.helper.chmod(0o755)
        self.wrk = self.repo / "bin/wrk"
        shutil.copy2(ROOT / "bin/wrk", self.wrk)
        self.cwd = self.base / "work"
        self.cwd.mkdir()
        self.log = self.base / "server.log"
        self.fake = self.base / "fake-mcp"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.config = self.base / "connection.json"
        self.connection = {"profile": PROFILE, "server": {"command": str(self.fake),
                           "args": [str(self.repo / "wrk-mcp/profiles.json"), str(self.log)],
                           "cwd": str(self.cwd), "env": {"MCP_PROFILE": PROFILE, "MCP_TYPE": "stdio"}}}
        self.write_connection()
        self.plans = []
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("ARBITER_", "MOCK_", "WRK_", "HK_", "CODEX_", "CLAUDE_", "KIMI_", "OPENCODE_", "GROK_", "GEMINI_", "DEVIN_"))}
        self.env["HOME"] = str(self.fixture_home)
        for name, relative in {
            "CODEX_HOME": ".codex", "CLAUDE_CONFIG_DIR": ".claude",
            "XDG_CONFIG_HOME": ".config", "XDG_DATA_HOME": ".local/share",
            "XDG_STATE_HOME": ".local/state", "XDG_CACHE_HOME": ".cache",
            "KIRO_HOME": ".kiro",
        }.items():
            self.env[name] = str(self.fixture_home / relative)
        # wrk seeds Kimi workspace trust before the unsupported-kind refusal.
        # Keep that legacy preparation inside this fixture, including variants.
        for name in ("KIMI_CODE_HOME", "KIMI_CODE_LOW_HOME", "KIMI_CODE_HIGH_HOME", "KIMI_CODE_MAX_HOME"):
            self.env[name] = str(self.fixture_home / name.lower())
        # #912: the Devin trust seeding is fail-closed on a missing store and
        # runs before the unsupported-kind refusal, so pre-seed the fixture
        # XDG store with the spawn cwd — a covered no-op that keeps the
        # consumer refusals exercised here identical. The trust contract
        # itself is tested in tests/test-wrk.sh.
        devin_cli = self.fixture_home / ".local/share/devin/cli"
        devin_cli.mkdir(parents=True)
        (devin_cli / "trusted_workspaces.json").write_text(
            json.dumps({"trusted_paths": [str(self.cwd.resolve())]}))
        python_bin = self.base / "python-bin"
        python_bin.mkdir()
        (python_bin / "python3").symlink_to(sys.executable)
        self.env["PATH"] = str(python_bin) + os.pathsep + self.env["PATH"]
        # Direct module probes must use the same isolated homes as subprocesses.
        self.environment = patch.dict(os.environ, self.env, clear=True)
        self.environment.start()

    def tearDown(self):
        for p in self.plans:
            subprocess.run([sys.executable, str(self.helper), "stop", "--plan", p],
                           env=self.env, capture_output=True, timeout=15)
            shutil.rmtree(Path(p).parent, ignore_errors=True)
        self.tmp.cleanup()
        self.environment.stop()

    def write_connection(self):
        self.config.write_text(json.dumps(self.connection))

    def mutate_plan_before_consumer_extraction(self):
        # A separate fixture process edits plan.json at wrk's first read AFTER
        # prepare returns. No guard code/check is changed by this attack hook.
        extra_log = self.base / "unchecked-server.log"
        extra = ["-c", "mcp_servers.unchecked_fixture.command=" + json.dumps(str(self.fake)),
                 "-c", "mcp_servers.unchecked_fixture.args=" + json.dumps([
                     str(self.repo / "wrk-mcp/profiles.json"), str(extra_log), "--ignore-env"])]
        python = self.base / "python-bin/python3"
        python.unlink()
        python.write_text("#!" + sys.executable + "\nimport json,os,sys\nfrom pathlib import Path\n"
                          "if len(sys.argv)>3 and sys.argv[1]=='-c' and "
                          "'print(json.load(open(sys.argv[1]))[\"cwd\"])' in sys.argv[2]:\n"
                          " p=Path(sys.argv[3]); data=json.loads(p.read_text()); data['argv'].extend(" + repr(extra) + "); p.write_text(json.dumps(data))\n"
                          "os.execv(sys.executable,[sys.executable,*sys.argv[1:]])\n")
        python.chmod(0o755)
        return extra_log

    def test_consumer_mutated_plan_refuses_extra_connection_before_start_or_brief(self):
        extra_log = self.mutate_plan_before_consumer_extraction()
        result, log = self.consumer()
        self.assertRefused(result, "binding")
        self.assertNotIn("agent start ", log)
        self.assertNotIn("agent prompt ", log)
        self.assertFalse(extra_log.exists(), "unreviewed configured server must never start")

    def test_mutated_plan_before_daemon_load_never_starts_upstream(self):
        source = self.helper.read_text().replace(
            "    process = subprocess.Popen(",
            "    changed = read_json(plan)\n    changed['argv'].append('--fixture-plan-edit')\n"
            "    plan.write_text(compact(changed))\n    process = subprocess.Popen(", 1)
        self.helper.write_text(source)
        result = self.prepare()
        self.assertRefused(result)
        self.assertFalse(self.log.exists(), "mutated startup plan launched the unbound upstream")

    def test_external_codex_profiles_refuse_consumer_and_late_attachment(self):
        home = Path(self.env["CODEX_HOME"])
        home.mkdir()
        profile = home / "hidden.config.toml"
        profile.write_text('[mcp_servers.hidden_fixture]\ncommand="/fixture/never-start"\n')
        result, log = self.consumer()
        self.assertRefused(result, "conflicting global/project")
        self.assertNotIn("agent start ", log)
        self.assertNotIn("agent prompt ", log)
        self.assertFalse(self.log.exists())
        profile.unlink()
        # A clean external layer is tracked even when not selected. Its later
        # replacement must refuse before injection after actual harness start.
        profile.write_text('model_reasoning_effort="high"\n')
        hook = "printf '%s' '[mcp_servers.hidden_fixture]\ncommand=\"/fixture/never-start\"\n' > '" + str(profile) + "'"
        result, log = self.consumer(hook=hook)
        self.assertRefused(result)
        self.assertIn("agent start ", log)
        self.assertNotIn("agent prompt ", log)

    def test_external_profile_selectors_and_symlinks_refuse(self):
        home = Path(self.env["CODEX_HOME"])
        home.mkdir()
        (home / "config.toml").write_text('profile="hidden"\n')
        self.assertRefused(self.prepare(), "profile selector")
        (home / "config.toml").unlink()
        outside = self.base / "outside-profile.toml"
        outside.write_text('model_reasoning_effort="high"\n')
        (home / "linked.config.toml").symlink_to(outside)
        self.assertRefused(self.prepare(), "regular file")
        (home / "linked.config.toml").unlink()
        for argv in (["--profile", "hidden"], ["--profile=hidden"], ["-phidden"],
                     ["-c", 'profile="hidden"'], ['--config=profile="hidden"']):
            result = self.run_helper("prepare", "--kind", "codex", "--cwd", str(self.cwd),
                                     "--profile", PROFILE, "--config", str(self.config), "--", *argv)
            self.assertRefused(result, "profile selector")
        self.assertFalse(self.log.exists(), "invalid loading selectors must fail before upstream start")

    def test_stalled_call_disconnect_stops_gateway_and_owned_upstream(self):
        self.connection["server"]["args"].append("--stall-tool")
        self.write_connection()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(Path(result.stdout.strip()).read_text())
        async def exercise():
            reader, writer = await asyncio.open_unix_connection(plan["socket"])
            writer.write(b'{"jsonrpc":"2.0","id":1,"method":"wrk/attach"}\n')
            await writer.drain()
            self.assertIn("result", json.loads(await asyncio.wait_for(reader.readline(), 5)))
            writer.write(b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"kis_mock_place_order","arguments":{}}}\n')
            await writer.drain()
            for _ in range(100):
                if "entered-stalled-fixture-call" in self.log.read_text():
                    break
                await asyncio.sleep(0.01)
            else:
                self.fail("owned fake never entered stalled call")
            writer.close()
            await writer.wait_closed()
            pid = int(self.log.read_text().splitlines()[0].split()[1])
            def alive():
                try:
                    os.kill(pid, 0)
                    return True
                except ProcessLookupError:
                    return False
            for _ in range(150):
                if not Path(plan["socket"]).exists() and not alive():
                    break
                await asyncio.sleep(0.02)
            self.assertFalse(Path(plan["socket"]).exists(), "gateway socket survives harness EOF during stalled call")
            self.assertFalse(alive(), "owned fake survives harness EOF during stalled call")
        asyncio.run(exercise())

    def test_stalled_call_explicit_stop_stops_gateway_and_owned_upstream(self):
        self.connection["server"]["args"].append("--stall-tool-short")
        self.write_connection()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan_path = result.stdout.strip()
        plan = json.loads(Path(plan_path).read_text())
        async def exercise():
            reader, writer = await asyncio.open_unix_connection(plan["socket"])
            writer.write(b'{"jsonrpc":"2.0","id":1,"method":"wrk/attach"}\n')
            await writer.drain()
            self.assertIn("result", json.loads(await asyncio.wait_for(reader.readline(), 5)))
            writer.write(b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"kis_mock_place_order","arguments":{}}}\n')
            await writer.drain()
            for _ in range(100):
                if "entered-stalled-fixture-call" in self.log.read_text():
                    break
                await asyncio.sleep(0.01)
            else:
                self.fail("owned fake never entered stalled call")
            stopped = await asyncio.to_thread(self.run_helper, "stop", "--plan", plan_path)
            self.assertEqual(stopped.returncode, 0, stopped.stderr)
            pid = int(self.log.read_text().splitlines()[0].split()[1])
            def alive():
                try:
                    os.kill(pid, 0)
                    return True
                except ProcessLookupError:
                    return False
            for _ in range(150):
                if not Path(plan["socket"]).exists() and not alive():
                    break
                await asyncio.sleep(0.02)
            try:
                self.assertFalse(Path(plan["socket"]).exists(), "explicit stop left gateway socket during stalled call")
                self.assertFalse(alive(), "explicit stop left owned fake during stalled call")
            finally:
                writer.close()
                await writer.wait_closed()
        asyncio.run(exercise())

    def run_helper(self, *args):
        return subprocess.run([sys.executable, str(self.helper), *args], env=self.env,
                              text=True, capture_output=True, timeout=20)

    def prepare(self, kind="codex", profile=PROFILE):
        r = self.run_helper("prepare", "--kind", kind, "--cwd", str(self.cwd), "--profile", profile,
                            "--config", str(self.config), "--", "--model", "fake")
        if r.returncode == 0:
            self.plans.append(r.stdout.strip())
        return r

    def verify(self, path, args=None, pane_env=None, cwd=None):
        p = json.loads(Path(path).read_text())
        evidence = ["--wrk-pane-env", "--env", "MCP_PROFILE=" + PROFILE]
        for k, v in (p["env"] if pane_env is None else pane_env).items():
            evidence += ["--env", k + "=" + v]
        return self.run_helper("verify", "--plan", path, "--cwd", str(p["cwd"] if cwd is None else cwd), "--", *(p["argv"] if args is None else args), *evidence)

    def assertRefused(self, r, reason=None):
        self.assertEqual(r.returncode, 79, r.stdout + r.stderr)
        self.assertIn("isolation refused", r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        if reason:
            self.assertIn(reason, r.stderr)

    def test_supported_harnesses_exact_connection_and_single_upstream(self):
        for kind in ("codex", "claude"):
            with self.subTest(kind=kind):
                r = self.prepare(kind)
                self.assertEqual(r.returncode, 0, r.stderr)
                path = r.stdout.strip()
                p = json.loads(Path(path).read_text())
                if kind == "claude":
                    self.assertIn("--strict-mcp-config", p["argv"])
                    loaded = json.loads(Path(p["argv"][p["argv"].index("--mcp-config") + 1]).read_text())
                    self.assertEqual(set(loaded["mcpServers"]), {"wrk_mock"})
                    gateway = loaded["mcpServers"]["wrk_mock"]
                else:
                    values = dict(x.split("=", 1) for x in p["argv"] if x.startswith("mcp_servers."))
                    self.assertEqual(values["mcp_servers.wrk_mock.required"], "true")
                    gateway = {k: json.loads(values["mcp_servers.wrk_mock." + k]) for k in ("command", "args")}
                    for feature in ("apps", "plugins", "remote_plugin", "skill_mcp_dependency_install"):
                        self.assertIn("features." + feature + "=false", p["argv"])
                self.assertIn(p["socket"], gateway["args"])
                self.assertEqual(self.verify(path).returncode, 0)
                self.assertEqual(self.verify(path).returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()), 2, "checks must reuse each harness's selected process")

    def test_env_not_propagated_refuses_fake_full_catalog(self):
        self.connection["server"]["args"].append("--ignore-env")
        self.write_connection()
        self.assertRefused(self.prepare(), "catalog")
        self.assertIn("default", self.log.read_text())

    def test_missing_env_refused_even_if_server_self_selects_safe_catalog(self):
        self.connection["server"]["env"] = {}
        self.connection["server"]["args"].append("--force-safe")
        self.write_connection()
        self.assertRefused(self.prepare(), "env propagation")
        self.assertFalse(self.log.exists(), "invalid env must fail before server start")

    def test_live_tool_on_later_catalog_page_refused(self):
        self.connection["server"]["args"].append("--page-live")
        self.write_connection()
        self.assertRefused(self.prepare(), "catalog")

    def test_unreviewed_live_alias_full_and_missing_tool_catalogs_refused(self):
        safe = json.loads((self.repo / "wrk-mcp/profiles.json").read_text())["profiles"][PROFILE][0]
        tools = self.base / "tools.json"
        self.connection["server"]["args"].append(str(tools))
        self.write_connection()
        for changed in (safe + ["kis_live_place_order"], safe + ["submit_ticket_alias"],
                        safe + ["place_order"], safe[:-1], safe + [safe[0]]):
            tools.write_text(json.dumps(changed))
            self.assertRefused(self.prepare(), "catalog")

    def test_profiles_connection_transport_and_envfile_refused(self):
        for p in ("", "default", "full", "unknown-profile", "crypto"):
            self.assertRefused(self.prepare(profile=p), "profile")
        self.connection["profile"] = "shadow-replay"
        self.write_connection()
        self.assertRefused(self.prepare(), "profile mismatch")
        self.connection = {"profile": PROFILE, "server": {"url": "https://example.invalid/mcp"}}
        self.write_connection()
        self.assertRefused(self.prepare(), "URL")
        self.setUpConnectionArgs(["--env-file", "/fixture/never-read.env"])
        self.assertRefused(self.prepare(), "env file")

    def setUpConnectionArgs(self, args):
        self.connection = {"profile": PROFILE, "server": {"command": str(self.fake), "args": args,
                           "cwd": str(self.cwd), "env": {"MCP_PROFILE": PROFILE, "MCP_TYPE": "stdio"}}}
        self.write_connection()

    def test_unreviewed_policy_alias_and_live_table_refused(self):
        path = self.repo / "wrk-mcp/profiles.json"
        d = json.loads(path.read_text())
        d["profiles"][PROFILE][0].append("submit_ticket_alias")
        path.write_text(json.dumps(d))
        self.assertRefused(self.prepare(), "table changed")
        d["profiles"][PROFILE][0][-1] = "kis_live_modify_order"
        path.write_text(json.dumps(d))
        # Independently exercise the live-name guard with a newly reviewed hash.
        source = self.helper.read_text()
        source = re.sub(r'POLICY_SHA256 = "[a-f0-9]+"', 'POLICY_SHA256 = "' + hashlib.sha256(path.read_bytes()).hexdigest() + '"', source)
        self.helper.write_text(source)
        self.assertRefused(self.prepare(), "live order")

    def test_repinned_live_order_names_refuse_before_fake_server_start(self):
        names = ("toss_place_order", "toss_modify_order", "toss_cancel_order",
                 "toss_reconcile_orders", "live_reconcile_orders", "kis-live-place-order",
                 "KisLivePlaceOrder", "place_order_v2", "mcp__auto_trader__place_order")
        path = self.repo / "wrk-mcp/profiles.json"
        original = json.loads(path.read_text())
        helper_source = self.helper.read_text()
        for name in names:
            with self.subTest(name=name):
                d = json.loads(json.dumps(original))
                d["profiles"][PROFILE][0].append(name)
                path.write_text(json.dumps(d))
                self.helper.write_text(re.sub(r'POLICY_SHA256 = "[a-f0-9]+"',
                    'POLICY_SHA256 = "' + hashlib.sha256(path.read_bytes()).hexdigest() + '"', helper_source))
                self.assertRefused(self.prepare(), "live order")
                self.assertFalse(self.log.exists(), "unsafe re-pinned catalog started a fake upstream")

    def test_all_unsupported_harnesses_refuse_before_server_start(self):
        for kind in ("devin", "grok", "kimi", "kiro", "opencode", "agy", "future-harness"):
            self.assertRefused(self.prepare(kind), "unsupported mock harness")
        self.assertFalse(self.log.exists())

    def test_claude_oauth_remote_policy_paths_refused_without_reading_credentials(self):
        conf = self.fixture_home / ".claude"
        conf.mkdir()
        for name in (".credentials.json", "remote-settings.json", "policy-limits.json"):
            path = conf / name
            path.write_text('fixture-not-readable-as-json')
            self.assertRefused(self.prepare("claude"), "OAuth/remote policy")
            path.unlink()
        self.env["CLAUDE_CODE_OAUTH_TOKEN"] = "fake-test-value"
        self.assertRefused(self.prepare("claude"), "OAuth/remote policy")
        self.env.pop("CLAUDE_CODE_OAUTH_TOKEN")
        (self.fixture_home / ".claude.json").write_text('{"oauthAccount":{"organizationUuid":"fake"}}')
        self.assertRefused(self.prepare("claude"), "OAuth account policy")
        self.assertFalse(self.log.exists())

    def test_conflicts_ancestor_layers_plugins_and_managed_configs(self):
        m = load(self.helper)
        for kind, rel, value in (("codex", ".codex/config.toml", '[mcp_servers.extra]\nurl="https://example.invalid/mcp"'),
                                 ("claude", ".claude.json", '{"mcpServers":{"extra":{"url":"https://example.invalid/mcp"}}}')):
            path = self.fixture_home / rel
            path.parent.mkdir(exist_ok=True)
            path.write_text(value)
            self.assertRefused(self.prepare(kind), "conflicting global/project")
            path.unlink()
        project = self.cwd.parent / ".codex/config.toml"
        project.parent.mkdir()
        project.write_text('[profiles.alt.mcp_servers.extra]\ncommand="fake"')
        self.assertRefused(self.prepare(), "conflicting global/project")
        project.unlink()
        plugins = self.fixture_home / ".codex/plugins"
        plugins.mkdir()
        (plugins / "installed.json").write_text('{}')
        self.assertRefused(self.prepare(), "plugin MCP")
        shutil.rmtree(plugins)
        managed = self.fixture_home / ".codex/managed_config.toml"
        managed.write_text('')
        self.assertRefused(self.prepare(), "managed")
        managed.unlink()
        # System managed path simulation is read-only; no writes to /etc.
        original = m.Path.exists
        from unittest.mock import patch
        with patch.object(m.Path, "exists", lambda p: True if str(p) == "/etc/codex/config.toml" else original(p)):
            with self.assertRaisesRegex(m.Refused, "managed"):
                m.isolation("codex", self.cwd)

    def test_loaded_argv_env_and_artifact_changes_refused(self):
        r = self.prepare()
        self.assertEqual(r.returncode, 0, r.stderr)
        path = r.stdout.strip()
        p = json.loads(Path(path).read_text())
        self.assertRefused(self.verify(path, args=p["argv"] + ["-c", 'mcp_servers.evil.url="https://example.invalid/mcp"']), "argv differs")
        self.assertRefused(self.verify(path, pane_env={}), "env propagation")
        self.assertRefused(self.verify(path, cwd=self.base), "cwd differs")
        artifact = Path(next(iter(p["artifacts"])))
        artifact.write_text('{}')
        self.assertRefused(self.verify(path), "configuration changed")

    def test_runtime_gateway_calls_aliases_other_methods_and_drift(self):
        tools = self.base / "tools.json"
        safe = json.loads((self.repo / "wrk-mcp/profiles.json").read_text())["profiles"][PROFILE][0]
        tools.write_text(json.dumps(safe))
        self.connection["server"]["args"].append(str(tools))
        self.write_connection()
        r = self.prepare()
        self.assertEqual(r.returncode, 0, r.stderr)
        path = r.stdout.strip()
        p = json.loads(Path(path).read_text())

        async def exercise():
            reader, writer = await asyncio.open_unix_connection(p["socket"])
            async def request(method, params=None):
                writer.write((json.dumps({"jsonrpc":"2.0", "id":1, "method":method, "params":params or {}})+'\n').encode())
                await writer.drain()
                return json.loads(await reader.readline())
            self.assertIn("result", await request("wrk/attach"))
            self.assertIn("result", await request("initialize"))
            self.assertEqual(len((await request("tools/list"))["result"]["tools"]), len(safe))
            self.assertIn("result", await request("tools/call", {"name":"kis_mock_place_order", "arguments":{}}))
            for name in ("kis_live_place_order", "place_order", "submit_ticket_alias"):
                self.assertIn("error", await request("tools/call", {"name":name, "arguments":{}}))
            self.assertIn("error", await request("resources/read", {"uri":"fake:orders"}))
            tools.write_text(json.dumps(safe + ["place_order"]))
            self.assertIn("error", await request("tools/call", {"name":"kis_mock_place_order", "arguments":{}}))
            writer.close()
            await writer.wait_closed()
        asyncio.run(exercise())
        self.assertEqual([x for x in self.log.read_text().splitlines() if x.startswith('call ')], ["call kis_mock_place_order"])

    def consumer(self, model="codex-sol", hook="", host="local", load_mcp=True, shell=None):
        herdr = self.base / "fixture-herdr"
        # Hook runs at the startup boundary, then the real committed fixture
        # records startup/foreground/brief behavior. No real herdr is called.
        harness = self.base / "fake-harness"
        harness.write_text(HARNESS)
        harness.chmod(0o755)
        marker = self.base / "connected"
        marker.unlink(missing_ok=True)
        launch = ':'
        if load_mcp:
            launch = "'" + str(harness) + "' '" + str(marker) + "' \"$@\" </dev/null >/dev/null 2>&1 &\nfor i in {1..100}; do [[ ! -f '" + str(marker) + "' ]] || break; sleep 0.01; done"
        herdr.write_text('#!/usr/bin/env bash\nset -euo pipefail\nif [[ "$1 $2" == "agent start" ]]; then\n' + (hook or ':') + '\n' + launch + '\nfi\nexec "' + str(ROOT / 'tests/fixtures/herdr') + '" "$@"\n')
        herdr.chmod(0o755)
        prompt = self.base / "brief.md"
        prompt.write_text("FAKE ONLY task872 fixture brief")
        env = dict(self.env, HERDR_BIN=str(herdr), SCOPEFUEL_BIN=str(ROOT / "tests/fixtures/scopefuel"),
                   ARBITER_BIN=str(self.base / "absent-arbiter"), HANDOFFKEEP_BIN=str(self.base / "absent-hk"),
                   WRK_HOSTS_CONFIG=str(self.base / "hosts.toml"), WRK_NO_SLEEP="1", WRK_FIXTURE_SCENARIO="spawn",
                   WRK_FIXTURE_LOG=str(self.base / "herdr.log"), MOCK_MCP_PROFILE=PROFILE,
                   WRK_MOCK_MCP_CONFIG=str(self.config), PANEWIRE_BIN=str(self.base / "absent-panewire"),
                   WRK_REFRESH_TIMEOUT_S="1", ARBITER_INBOX_ROOT=str(self.base / "inbox"))
        r = subprocess.run(([shell] if shell else []) + [str(self.wrk),"spawn","-c",str(self.cwd),"-m",model,"-p",str(prompt),"-w","w","-l","fixture",
                            "-L","mock","--t","T1","--task","872","--task-hk-bypass","--host",host],
                           env=env,text=True,capture_output=True,timeout=25)
        # Collect owned private plans from the fake start argv for cleanup.
        log_path = self.base / "herdr.log"
        log = log_path.read_text() if log_path.exists() else ""
        for directory in re.findall(r"(/[^\s\"\]]*/wrk-mcp-[^/\s\"\]]+)/", log):
            plan = str(Path(directory) / "plan.json")
            if Path(plan).exists() and plan not in self.plans:
                self.plans.append(plan)
        return r, log

    def test_consumer_allowed_and_refused_with_injection_absent(self):
        for model in ("codex-sol", "opus"):
            (self.base / "herdr.log").unlink(missing_ok=True)
            r, log = self.consumer(model)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("agent prompt ", log)
            self.assertIn("mcp_servers.wrk_mock.command" if model == "codex-sol" else "--strict-mcp-config", log)
        for model in ("devin-swe2", "grok", "kimi-k3", "kiro", "oc-solar4", "agy-flash"):
            (self.base / "herdr.log").unlink(missing_ok=True)
            r, log = self.consumer(model)
            self.assertRefused(r)
            self.assertNotIn("agent prompt ", log)
            self.assertNotIn("agent start ", log)
            if model == "kimi-k3":
                trust = list(Path(self.env["KIMI_CODE_HOME"]).glob("workspace-trust/wd_*"))
                self.assertEqual(len(trust), 1, "consumer trust preparation must use the isolated Kimi home")
                self.assertEqual(json.loads(trust[0].read_text())["root"], str(self.cwd.resolve()))
        self.connection["server"]["args"].append("--ignore-env")
        self.write_connection()
        (self.base / "herdr.log").unlink(missing_ok=True)
        r, log = self.consumer()
        self.assertRefused(r)
        self.assertNotIn("agent prompt ", log)
        self.assertNotIn("tab create ", log)

    def test_consumer_rechecks_after_start_before_injection(self):
        project = self.cwd / ".mcp.json"
        hook = "printf '%s' '{\"mcpServers\":{\"extra\":{\"url\":\"https://example.invalid/mcp\"}}}' > '" + str(project) + "'"
        r, log = self.consumer(hook=hook)
        self.assertRefused(r)
        self.assertIn("agent start ", log)
        self.assertNotIn("agent prompt ", log)
        self.assertIn("pane close ", log)

    def test_consumer_refuses_when_harness_does_not_load_configured_gateway(self):
        r, log = self.consumer(load_mcp=False)
        self.assertRefused(r, "not loaded")
        self.assertIn("agent start ", log)
        self.assertNotIn("agent prompt ", log)

    def test_consumer_system_bash(self):
        r, log = self.consumer(shell="/bin/bash")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("agent prompt ", log)

    def test_tool_call_outlives_catalog_deadline_and_preserves_next_response(self):
        # Scale the catalog deadline ONLY in the fixture copy. A call must not
        # inherit it; the fake takes longer, without making this test wait 10s.
        self.helper.write_text(self.helper.read_text().replace(
            "async def rpc(method, params=None, timeout=10):", "async def rpc(method, params=None, timeout=1):"))
        self.connection["server"]["args"].append("--slow-tool")
        self.write_connection()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(Path(result.stdout.strip()).read_text())
        async def exercise():
            reader, writer = await asyncio.open_unix_connection(plan["socket"])
            async def request(method, params=None):
                writer.write((json.dumps({"jsonrpc":"2.0", "id":1, "method":method, "params":params or {}}) + '\n').encode())
                await writer.drain()
                return json.loads(await asyncio.wait_for(reader.readline(), 5))
            try:
                self.assertIn("result", await request("wrk/attach"))
                self.assertIn("result", await request("tools/call", {"name":"kis_mock_place_order", "arguments":{}}))
                self.assertIn("tools", (await request("tools/list"))["result"])
            finally:
                writer.close()
                await writer.wait_closed()
        asyncio.run(exercise())

    def test_consumer_remote_ssh_and_hub_refused_without_delegation(self):
        for via in ("ssh", "hub"):
            (self.base / "hosts.toml").write_text('[hosts.fakehost]\nssh="fakehost"\nvia="' + via + '"\n')
            r, log = self.consumer(host="fakehost")
            self.assertRefused(r, "execution host")
            self.assertNotIn("agent prompt ", log)
            self.assertNotIn("agent start ", log)

    def test_all_reviewed_profiles_accept_and_malformed_layers_refuse(self):
        for profile in ("shadow-replay", "watch_repricing", "fill-watch-context"):
            self.connection["profile"] = profile
            self.connection["server"]["env"]["MCP_PROFILE"] = profile
            self.write_connection()
            r = self.prepare(profile=profile)
            self.assertEqual(r.returncode, 0, r.stderr)
        self.connection["profile"] = PROFILE
        self.connection["server"]["env"]["MCP_PROFILE"] = PROFILE
        self.write_connection()
        cfg = self.cwd / ".codex/config.toml"
        cfg.parent.mkdir()
        cfg.write_text('[not valid toml')
        self.assertRefused(self.prepare(), "invalid isolation configuration")
        cfg.unlink()
        external = self.base / "config-target.toml"
        external.write_text('')
        cfg.symlink_to(external)
        self.assertRefused(self.prepare(), "regular file")


if __name__ == "__main__":
    unittest.main()
