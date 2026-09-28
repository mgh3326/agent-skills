"""Q-41 render-only migration, fake Codex enumeration, and assertion mutants."""
import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

import test_wrk_mock_mcp as mock_fixtures

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    loader = importlib.machinery.SourceFileLoader("codex_plan", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="test-q41-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.home = self.base / "user"
        self.home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.home),
                    "CODEX_HOME": str(self.home / ".codex"), "CLAUDE_CONFIG_DIR": str(self.home / ".claude"),
                    "XDG_CONFIG_HOME": str(self.home / ".config"), "XDG_DATA_HOME": str(self.home / ".local/share"),
                    "XDG_STATE_HOME": str(self.home / ".local/state"), "XDG_CACHE_HOME": str(self.home / ".cache")}
        for key in ("KIMI_CODE_HOME", "KIMI_CODE_LOW_HOME", "KIMI_CODE_HIGH_HOME", "KIMI_CODE_MAX_HOME", "KIRO_HOME"):
            self.env[key] = str(self.home / key.lower())
        self.environment = patch.dict(os.environ, self.env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.bundle = self.base / "desk-snapshots"
        self.bundle.mkdir(mode=0o700)
        self.stage = self.base / "new-proposals"
        self.project = self.base / "selected"
        self.project.mkdir()
        git = subprocess.run(["git", "init", "-q", str(self.project)], env=dict(self.env, GIT_CONFIG_NOSYSTEM="1"),
                             capture_output=True, timeout=10)
        self.assertEqual(git.returncode, 0, "owned fixture git initialization failed")
        self.target = self.home / ".codex/config.toml"
        self.target.parent.mkdir()
        self.target.write_text("# ACTIVE FIXTURE GLOBAL MUST NOT CHANGE\n")
        self.tools = ["read_fixture_" + str(i) for i in range(30)]
        self.fake = self.base / "fake-only-mcp"
        self.marker = self.base / "server-started"
        self.fake.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath(" + repr(str(self.marker)) + ").write_text('unexpected start')\n")
        self.fake.chmod(0o700)
        self.connection = ('[mcp_servers."auto_trader"] # retain spelling and comments\n'
                           'command = ' + json.dumps(str(self.fake)) + '\n'
                           'args = []\nenabled_tools = ' + json.dumps(self.tools) + '\n'
                           'disabled_tools = ["write_fixture"]\nrequired = false\n'
                           'default_tools_approval_mode = "prompt"\ntool_timeout_sec = 45\n'
                           '[mcp_servers.auto_trader.env]\nMCP_PROFILE = "fixture-readonly"\n'
                           '[mcp_servers.auto_trader.tools.read_fixture_0]\napproval_mode = "approve"\n')
        self.unrelated = '# keep user metadata byte for byte\nmodel = "fixture-model"\n[features]\napps = false\n'
        self.trailing = '[mcp_servers.unrelated]\ncommand = ' + json.dumps(str(self.fake)) + '\nargs = ["unrelated"]\n'
        self.global_text = self.unrelated + self.connection + self.trailing
        self.existing = '# keep project metadata\nmodel_reasoning_effort = "high"\n[features]\nplugins = false\n'
        self.data = {"schema": 1, "global_target": str(self.target), "projects": [
            {"id": "strategy-lab", "root": str(self.project), "snapshot": "projects/strategy-lab.toml", "root_reviewed": True}]}
        (self.bundle / "projects").mkdir(mode=0o700)
        self.put("global.toml", self.global_text)
        self.put("connection.toml", self.connection)
        self.put("projects/strategy-lab.toml", self.existing)
        self.select()
        self.module = load(ROOT / "bin/wrk-codex-mcp-plan")

    def put(self, name, text):
        path = self.bundle / name
        path.write_text(text)
        path.chmod(0o600)

    def select(self):
        self.put("selection.json", json.dumps(self.data))

    def run_cli(self):
        return subprocess.run([sys.executable, str(ROOT / "bin/wrk-codex-mcp-plan"),
                               "--input-dir", str(self.bundle), "--stage", str(self.stage)],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def assert_refused(self, call, module=None):
        module = module or self.module
        try:
            call()
        except module.Refused:
            return
        raise AssertionError("migration guard admitted forbidden behavior")

    def test_preserves_all_tables_metadata_30_tools_and_never_activates(self):
        before = {p: p.read_bytes() for p in self.bundle.rglob("*") if p.is_file()}
        active_before = self.target.read_bytes()
        project_target = self.project / ".codex/config.toml"
        project_target.parent.mkdir()
        project_target.write_text(self.existing)
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        global_proposal = (self.stage / "global/config.toml").read_text()
        project_proposal = (self.stage / "projects/strategy-lab/.codex/config.toml").read_text()
        self.assertEqual(global_proposal, self.unrelated + self.trailing)
        self.assertEqual(project_proposal, self.existing + self.connection)
        self.assertEqual(tomllib.loads(project_proposal)["mcp_servers"]["auto_trader"],
                         tomllib.loads(self.connection)["mcp_servers"]["auto_trader"])
        self.assertEqual(self.target.read_bytes(), active_before)
        self.assertEqual(project_target.read_text(), self.existing)
        self.assertEqual(before, {p: p.read_bytes() for p in self.bundle.rglob("*") if p.is_file()})
        self.assertFalse(self.marker.exists(), "rendering must never start the declared server")
        for path in [self.stage, *self.stage.rglob("*")]:
            self.assertEqual(path.stat().st_mode & 0o077, 0, str(path))
        self.assertEqual(json.loads((self.stage / "manifest.json").read_text())["enabled_tool_count"], 30)
        repeat = self.run_cli()
        self.assertEqual(repeat.returncode, 79)
        self.assertIn("new directory", repeat.stderr)

    def test_http_env_auth_and_per_tool_approval_transfer_without_connection(self):
        connection = self.connection.replace('command = ' + json.dumps(str(self.fake)) + '\nargs = []',
                                              'url = "https://example.invalid/mcp"\nbearer_token_env_var = "FIXTURE_TOKEN"\n'
                                              'env_http_headers = { "X-Tenant" = "FIXTURE_TENANT" }')
        # This is an offline TOML comparison, not a real HTTP connection.
        global_text = self.unrelated + connection + self.trailing
        remainder, moved, table = self.module.transfer(global_text, connection, 30)
        self.assertEqual(remainder, self.unrelated + self.trailing)
        self.assertEqual(moved, connection)
        self.assertEqual(table["tools"]["read_fixture_0"]["approval_mode"], "approve")
        self.assertEqual(table["bearer_token_env_var"], "FIXTURE_TOKEN")

    def test_preserves_crlf_snapshot_bytes(self):
        self.put("global.toml", self.global_text.replace("\n", "\r\n"))
        self.put("connection.toml", self.connection.replace("\n", "\r\n"))
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.stage / "global/config.toml").read_bytes(),
                         (self.unrelated + self.trailing).replace("\n", "\r\n").encode())
        self.assertEqual((self.stage / "projects/strategy-lab/.codex/config.toml").read_bytes(),
                         (self.existing + self.connection.replace("\n", "\r\n")).encode())

    def test_cli_refusal_has_reason_and_creates_no_output(self):
        self.put("connection.toml", self.connection.replace('tool_timeout_sec = 45', 'tool_timeout_sec = 99'))
        result = self.run_cli()
        self.assertEqual(result.returncode, 79)
        self.assertIn("differs from the current global baseline", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.stage.exists())
        self.put("connection.toml", self.connection)
        self.stage = self.project / ".codex"
        result = self.run_cli()
        self.assertEqual(result.returncode, 79)
        self.assertIn("staging overlaps", result.stderr)
        self.assertFalse(self.stage.exists())
        self.assertEqual(self.target.read_text(), "# ACTIVE FIXTURE GLOBAL MUST NOT CHANGE\n")

    def test_untrusted_selected_and_unrelated_codex_enumeration_fake_only(self):
        codex = shutil.which("codex")
        if not codex:
            self.skipTest("Codex CLI absent; render/consumer tests still run; desk must enumerate installed CLI")
        for system in ("/etc/codex/config.toml", "/etc/codex/managed_config.toml", "/etc/codex/requirements.toml",
                       "/Library/Application Support/Codex/managed_config.toml"):
            self.assertFalse(Path(system).exists(), "cannot enumerate an uncontrolled system catalog")
        version = subprocess.run([codex, "--version"], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(version.returncode, 0)
        self.assertEqual(version.stdout.strip(), "codex-cli 0.157.1")
        self.module.render(self.bundle, self.stage)
        # Activate ONLY the owned fixture proposals, never any user files.
        shutil.copy2(self.stage / "global/config.toml", self.target)
        project_target = self.project / ".codex/config.toml"
        project_target.parent.mkdir()
        shutil.copy2(self.stage / "projects/strategy-lab/.codex/config.toml", project_target)
        unrelated = self.base / "unrelated"
        unrelated.mkdir()
        (unrelated / ".git").mkdir()
        def enumerate_at(root):
            result = subprocess.run([codex, "-C", str(root), "mcp", "list", "--json"],
                                    cwd=root, env=self.env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, "isolated Codex enumeration failed")
            return {v["name"]: v for v in json.loads(result.stdout)}
        def trust(root, level):
            with self.target.open("a") as f:
                f.write('\n[projects.' + json.dumps(str(root)) + ']\ntrust_level = ' + json.dumps(level) + '\n')
        trust(self.project, "untrusted")
        trust(unrelated, "trusted")
        self.assertNotIn("auto_trader", enumerate_at(unrelated))
        self.assertNotIn("auto_trader", enumerate_at(self.project))
        self.target.write_text(self.target.read_text().replace('trust_level = "untrusted"', 'trust_level = "trusted"'))
        selected = enumerate_at(self.project)
        self.assertIn("auto_trader", selected)
        self.assertEqual(selected["auto_trader"]["transport"]["command"], str(self.fake))
        # CLI 0.157.1 list JSON omits tool policy; the exact table comparison in
        # the render integration above proves policy preservation independently.
        self.assertEqual(selected["auto_trader"]["transport"]["env"]["MCP_PROFILE"], "fixture-readonly")
        self.assertIn("unrelated", selected)
        nested = self.project / "subdirectory"
        nested.mkdir()
        self.assertIn("auto_trader", enumerate_at(nested))
        self.assertNotIn("auto_trader", enumerate_at(unrelated))
        self.assertFalse(self.marker.exists(), "mcp list enumerates config only; no server/API calls")

    def test_attached_project_mock_consumer_refused_before_start_or_brief(self):
        rig = mock_fixtures.IsolationTests(methodName="test_consumer_allowed_and_refused_with_injection_absent")
        rig.setUp()
        self.addCleanup(rig.tearDown)
        target = rig.cwd / ".codex/config.toml"
        target.parent.mkdir()
        target.write_text(self.connection)
        result, log = rig.consumer()
        rig.assertRefused(result, "conflicting global/project")
        self.assertNotIn("agent start ", log)
        self.assertNotIn("agent prompt ", log)
        self.assertFalse(rig.log.exists(), "guard must refuse before any fake upstream starts")

    def test_guard_mutants_assertion_red_not_exceptions(self):
        # Every new guard family is exercised intact first. Mutations bypass
        # only one require reason; a crash propagates and does NOT count as RED.
        original_source = (ROOT / "bin/wrk-codex-mcp-plan").read_text()
        registry = json.loads((ROOT / "wrk-mcp/codex-projects.json").read_text())
        table = tomllib.loads(self.connection)["mcp_servers"]["auto_trader"]
        def selected(**changes):
            data = copy.deepcopy(self.data)
            data["projects"][0].update(changes)
            return data
        parent_repo = self.base / "parent-repo"
        parent_repo.mkdir()
        (parent_repo / ".git").mkdir()
        overlap = self.project / "nested"
        overlap.mkdir()
        (overlap / ".git").mkdir()
        cases = [
            ("selection-schema", "explicit selection schema and projects required",
             lambda m: m.selection(dict(self.data, schema=2), registry)),
            ("absolute-path-format", "explicit absolute path required", lambda m: m.absolute(str(self.base / "bad\npath"))),
            ("canonical-root", "canonical path required", lambda m: m.absolute(str(self.project) + "/../selected")),
            ("target-route", "global target must identify a Codex config.toml",
             lambda m: m.selection(dict(self.data, global_target=str(self.base / "wrong.toml")), registry)),
            ("project-fields", "explicit project root and snapshot decision required",
             lambda m: m.selection(dict(self.data, projects=[dict(self.data["projects"][0], unexpected=True)]), registry)),
            ("unreviewed-project", "project absent from reviewed registry",
             lambda m: m.selection(selected(id="agent-skills", snapshot=None), registry)),
            ("duplicate-project", "duplicate logical project; review worktrees in separate plans",
             lambda m: m.selection(dict(self.data, projects=self.data["projects"] +
                 [dict(self.data["projects"][0], root=str(parent_repo))]), registry)),
            ("unreviewed-root", "reviewed concrete git project root required; no shared ancestor or agent-skills attachment",
             lambda m: m.selection(selected(root_reviewed=False), registry)),
            ("ancestor-root", "reviewed concrete git project root required; no shared ancestor or agent-skills attachment",
             lambda m: m.selection(selected(root=str(ROOT.parent)), registry)),
            ("overlap", "overlapping project roots refused",
             lambda m: m.selection(dict(self.data, projects=[self.data["projects"][0],
                 dict(self.data["projects"][0], id="auto_trader", root=str(overlap), snapshot=None)]), registry)),
            ("snapshot-membership", "project snapshot must be an explicit bundle member",
             lambda m: m.selection(selected(snapshot="../../outside.toml"), registry)),
            ("output-boundary", "staging overlaps inputs, repository, or active configuration targets",
             lambda m: m.output_boundary(self.project / "proposal", self.bundle, self.target, [("strategy-lab", self.project, None)])),
            ("output-new", "staging must be a new directory beneath an existing parent",
             lambda m: m.output_boundary(parent_repo, self.bundle, self.target, [])),
            ("connection-only", "connection snapshot must contain only mcp_servers.auto_trader",
             lambda m: m.reviewed_connection(tomllib.loads(self.global_text), tomllib.loads(self.connection + self.trailing), 30)),
            ("same-baseline", "connection differs from the current global baseline",
             lambda m: m.reviewed_connection(tomllib.loads(self.global_text),
                 tomllib.loads(self.connection.replace('tool_timeout_sec = 45', 'tool_timeout_sec = 46')), 30)),
            ("approved-allowlist", "current approved 30-tool allowlist required; no full or widened fallback",
             lambda m: m.transfer(self.global_text.replace(json.dumps(self.tools), '[]'), self.connection.replace(json.dumps(self.tools), '[]'), 30)),
            ("transport", "one explicit connection transport required",
             lambda m: m.transfer(self.global_text.replace('args = []', 'args = []\nurl = "https://example.invalid/mcp"'),
                                  self.connection.replace('args = []', 'args = []\nurl = "https://example.invalid/mcp"'), 30)),
            ("profile-shadow", "additional profile/plugin auto_trader attachment requires separate review",
             lambda m: m.transfer(self.global_text + '[profiles.shadow.mcp_servers.auto_trader]\ncommand="fixture"\n', self.connection, 30)),
            ("existing-attachment", "project already attaches auto_trader; reconcile explicitly before planning",
             lambda m: m.project_config(self.connection, "", table)),
        ]
        for name, reason, probe in cases:
            with self.subTest(name=name):
                self.assert_refused(lambda: probe(self.module))
                source = original_source.replace("if not ok:\n", "if not ok and reason != " + repr(reason) + ":\n", 1)
                path = self.base / "mutant"
                path.write_text(source)
                mutant = load(path)
                # ROOT is immutable production location; a fixture copy models it.
                mutant.ROOT = ROOT
                with self.assertRaises(AssertionError) as caught:
                    self.assert_refused(lambda: probe(mutant), mutant)
                print("ASSERTION-RED q41-" + name + ": " + str(caught.exception), flush=True)

    def test_filesystem_and_transfer_proof_mutants(self):
        source = (ROOT / "bin/wrk-codex-mcp-plan").read_text()
        def red(name, reason, probe):
            self.assert_refused(lambda: probe(self.module))
            path = self.base / "mutant-extra"
            path.write_text(source.replace("if not ok:\n", "if not ok and reason != " + repr(reason) + ":\n", 1))
            mutant = load(path)
            mutant.ROOT, mutant.REGISTRY = ROOT, ROOT / "wrk-mcp/codex-projects.json"
            with self.assertRaises(AssertionError) as caught:
                self.assert_refused(lambda: probe(mutant), mutant)
            print("ASSERTION-RED q41-" + name + ": " + str(caught.exception), flush=True)
        link = self.base / "linked"
        link.symlink_to(self.bundle, target_is_directory=True)
        red("symlink", "symlink path is not supported", lambda m: m.no_symlinks(link / "global.toml"))
        (self.bundle / "global.toml").chmod(0o644)
        red("private-snapshot", "snapshot must be an owned private regular file", lambda m: m.snapshot(self.bundle, "global.toml"))
        (self.bundle / "global.toml").chmod(0o600)
        self.bundle.chmod(0o755)
        red("private-input", "input bundle must be an owned private directory", lambda m: m.render(self.bundle, self.stage))
        self.bundle.chmod(0o700)
        shutil.rmtree(self.stage)
        # Valid TOML whose implicit table representation cannot be transferred
        # by the lossless section splitter: intact proof guard must refuse.
        inline = 'mcp_servers.auto_trader = { command="fixture", enabled_tools=' + json.dumps(self.tools) + ' }\n'
        red("lossless-transfer", "lossless table transfer could not be proved; use explicit table headers in desk snapshots",
            lambda m: m.transfer(inline, inline, 30))
        # A deliberately wrong merge yields valid TOML and a failing equality
        # assertion after bypassing just the project semantic proof.
        table = tomllib.loads(self.connection)["mcp_servers"]["auto_trader"]
        wrong_table = dict(table, tool_timeout_sec=999)
        red("project-merge-proof", "project merge changed unrelated settings or tool restrictions",
            lambda m: m.project_config(self.existing, self.connection, wrong_table))
        target = self.project / ".codex/config.toml"
        target.parent.mkdir()
        target.write_text(self.existing)
        self.data["projects"][0]["snapshot"] = None
        self.select()
        red("missing-project-snapshot", "existing project config requires an explicit snapshot",
            lambda m: m.render(self.bundle, self.stage))
        shutil.rmtree(self.stage)
        # Use an active-root bundle made exclusively inside this fixture.
        self.data["projects"][0]["snapshot"] = "projects/strategy-lab.toml"
        self.select()
        active_bundle = self.project / "desk-input"
        shutil.copytree(self.bundle, active_bundle)
        red("offline-input", "input bundle must be offline, outside active configuration roots",
            lambda m: m.render(active_bundle, self.stage))
        shutil.rmtree(self.stage)
        altered_registry = self.base / "registry.json"
        altered_registry.write_bytes((ROOT / "wrk-mcp/codex-projects.json").read_bytes() + b"\n")
        prior_registry = self.module.REGISTRY
        self.module.REGISTRY = altered_registry
        self.assert_refused(lambda: self.module.render(self.bundle, self.stage))
        self.module.REGISTRY = prior_registry
        path = self.base / "mutant-registry"
        path.write_text(source.replace("if not ok:\n", "if not ok and reason != 'reviewed project registry changed; review required':\n", 1))
        mutant = load(path)
        mutant.ROOT, mutant.REGISTRY = ROOT, altered_registry
        with self.assertRaises(AssertionError) as caught:
            self.assert_refused(lambda: mutant.render(self.bundle, self.stage), mutant)
        print("ASSERTION-RED q41-registry-pin: " + str(caught.exception), flush=True)


if __name__ == "__main__":
    unittest.main()
