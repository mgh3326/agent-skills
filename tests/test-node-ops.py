#!/usr/bin/env python3
"""Hermetic tests for bin/node-ops. All commands use temporary HOME fixtures."""

import contextlib
import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from types import SimpleNamespace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bin" / "node-ops"
SPEC = importlib.util.spec_from_loader("node_ops", SourceFileLoader("node_ops", str(SCRIPT)))
NODE_OPS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NODE_OPS)
REAL_GIT = shutil.which("git")


HK_STUB_TEMPLATE = r'''#!/bin/sh
for arg do printf '%s\0' "$arg" >> "$HOME/hk-calls.bin"; done
printf '\n' >> "$HOME/hk-calls.bin"
if [ "$#" -eq 1 ] && [ "$1" = version ]; then IFS= read -r output < "$HOME/hk-version"; printf '%s' "$output"; exit 0; fi
if [ "$#" -eq 3 ] && [ "$1" = doc ] && [ "$2" = get ]; then
  file="$HOME/docs/$3"
  [ -f "$file" ] || exit 1
  IFS= read -r output < "$file"
  printf '%s' "$output"
  exit 0
fi
if [ "$#" -eq 8 ] && [ "$1" = doc ] && [ "$2" = put ]; then
  key="$4"
  body_file="$8"
  IFS= read -r body < "$body_file"
  printf '%s' "$body" > "$HOME/put-docs/$key"
  IFS= read -r machine < "$HOME/machine"
  printf '{"document":{"created_by":"%s"}}' "$machine"
  exit 0
fi
exit 2
'''


PANEWIRE_STUB = r'''#!/bin/sh
for arg do printf '%s\0' "$arg" >> "$HOME/panewire-calls.bin"; done
printf '\n' >> "$HOME/panewire-calls.bin"
if [ "$#" -eq 1 ] && [ "$1" = version ]; then IFS= read -r output < "$HOME/panewire-version"; printf '%s' "$output"; exit 0; fi
exit 2
'''


HERDR_STUB = r'''#!/bin/sh
for arg do printf '%s\0' "$arg" >> "$HOME/herdr-calls.bin"; done
printf '\n' >> "$HOME/herdr-calls.bin"
if [ "$#" -eq 2 ] && [ "$1" = pane ] && [ "$2" = list ]; then IFS= read -r output < "$HOME/herdr.json"; printf '%s' "$output"; exit 0; fi
exit 2
'''


def write_executable(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def git_raw(args, env=None):
    completed = subprocess.run(
        [REAL_GIT] + list(args),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        shell=False,
        env=env,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError("git fixture command failed: {}".format(completed.stderr))
    return completed.stdout.strip()


_SHARED_FIXTURE = None


def create_shared_fixture():
    global _SHARED_FIXTURE
    if _SHARED_FIXTURE is not None:
        return _SHARED_FIXTURE
    temp = tempfile.TemporaryDirectory()
    root = Path(temp.name)
    home = root / "home"
    home.mkdir()
    bin_dir = home / ".local" / "bin"
    bin_dir.mkdir(parents=True)
    repo = home / ".agents" / "skills"
    repo.mkdir(parents=True)
    stub_dir = root / "stubs"
    stub_dir.mkdir()
    for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
        (home / name.lower()).mkdir()
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / "xdg_config_home"),
            "XDG_DATA_HOME": str(home / "xdg_data_home"),
            "XDG_CACHE_HOME": str(home / "xdg_cache_home"),
            "XDG_STATE_HOME": str(home / "xdg_state_home"),
            "PATH": str(stub_dir) + os.pathsep + os.environ.get("PATH", ""),
        }
    )
    fixture_env = env.copy()
    fixture_env["PATH"] = os.environ.get("PATH", "")
    write_executable(bin_dir / "handoffkeep", HK_STUB_TEMPLATE)
    write_executable(bin_dir / "panewire", PANEWIRE_STUB)
    write_executable(stub_dir / "herdr", HERDR_STUB)
    git_stub = "#!/bin/sh\n" + (
        "for arg do printf '%s\\0' \"$arg\" >> \"$HOME/git-calls.bin\"; done\n"
        "printf '\\n' >> \"$HOME/git-calls.bin\"\n"
        "exec " + shlex.quote(REAL_GIT) + " \"$@\"\n"
    )
    write_executable(stub_dir / "git", git_stub)

    origin = root / "origin.git"
    (repo / "bin").mkdir()
    shutil.copyfile(SCRIPT, repo / "bin" / "node-ops")
    (repo / "bin" / "node-ops").chmod(0o755)
    (repo / "README.md").write_text("fixture\n", encoding="utf-8")
    git_raw(["init", "--bare", "--initial-branch=main", str(origin)], fixture_env)
    git_raw(["init", "--initial-branch=main", str(repo)], fixture_env)
    git_raw(["-C", str(repo), "add", "."], fixture_env)
    git_raw(
        ["-c", "user.email=node-ops@example.invalid", "-c", "user.name=Node Ops Test", "-C", str(repo), "commit", "-m", "fixture"],
        fixture_env,
    )
    git_raw(["-C", str(repo), "remote", "add", "origin", str(origin)], fixture_env)
    git_raw(["-C", str(repo), "push", "-u", "origin", "main"], fixture_env)
    base_sha = git_raw(["-C", str(repo), "rev-parse", "HEAD"], fixture_env)
    _SHARED_FIXTURE = {
        "temp": temp,
        "root": root,
        "home": home,
        "bin_dir": bin_dir,
        "repo": repo,
        "stub_dir": stub_dir,
        "origin": origin,
        "env": env,
        "fixture_env": fixture_env,
        "base_sha": base_sha,
    }
    return _SHARED_FIXTURE


class NodeOpsCase(unittest.TestCase):
    def setUp(self):
        fixture = create_shared_fixture()
        self.temp = fixture["temp"]
        self.root = fixture["root"]
        self.home = fixture["home"]
        self.bin_dir = fixture["bin_dir"]
        self.repo = fixture["repo"]
        self.stub_dir = fixture["stub_dir"]
        self.origin = fixture["origin"]
        self.env = fixture["env"].copy()
        self.fixture_env = fixture["fixture_env"].copy()
        self.script = self.repo / "bin" / "node-ops"
        self.base_sha = fixture["base_sha"]
        self.reset_repo_after = False

        self.write_state({"machine": "mac-work", "docs": {}, "hk_version": "handoffkeep v-test", "panewire_version": "panewire v-test"})
        self.write_herdr({"panes": []})
        for backup in self.bin_dir.glob("handoffkeep.bak-*"):
            backup.unlink()
        write_executable(self.bin_dir / "handoffkeep", HK_STUB_TEMPLATE)
        write_executable(self.bin_dir / "panewire", PANEWIRE_STUB)
        write_executable(self.stub_dir / "herdr", HERDR_STUB)
        for name in ("hk-calls.bin", "panewire-calls.bin", "herdr-calls.bin", "git-calls.bin"):
            path = self.home / name
            if path.exists():
                path.unlink()
        self.instruction_id = "20261012-0001-test"
        self.instruction_key = "ops/node/mac-work/instr/" + self.instruction_id
        self.receipt_key = "ops/node/mac-work/receipt/" + self.instruction_id

    def tearDown(self):
        if not self.reset_repo_after:
            return
        for entry in self.repo.iterdir():
            if entry.name == ".git" or entry.name in ("README.md", "bin"):
                continue
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        git_raw(["-C", str(self.repo), "checkout", "-f", "-B", "main", self.base_sha], self.fixture_env)
        refs = self.repo / ".git" / "refs" / "remotes" / "origin"
        refs.mkdir(parents=True, exist_ok=True)
        (refs / "main").write_text(self.base_sha + "\n", encoding="utf-8")
        remote_ref = self.origin / "refs" / "heads" / "main"
        remote_ref.parent.mkdir(parents=True, exist_ok=True)
        remote_ref.write_text(self.base_sha + "\n", encoding="utf-8")

    def read_state(self):
        state = json.loads((self.home / "hk-state.json").read_text(encoding="utf-8"))
        put_docs = self.home / "put-docs"
        if put_docs.exists():
            for path in put_docs.rglob("*"):
                if path.is_file():
                    key = path.relative_to(put_docs).as_posix()
                    state["docs"][key] = {
                        "created_by": state.get("machine", "mac-work"),
                        "body": path.read_text(encoding="utf-8"),
                    }
        return state

    def write_state(self, state):
        (self.home / "hk-state.json").write_text(json.dumps(state), encoding="utf-8")
        (self.home / "machine").write_text(str(state.get("machine", "mac-work")), encoding="utf-8")
        (self.home / "hk-version").write_text(state.get("hk_version", "handoffkeep test"), encoding="utf-8")
        (self.home / "panewire-version").write_text(state.get("panewire_version", "panewire test"), encoding="utf-8")
        docs = self.home / "docs"
        put_docs = self.home / "put-docs"
        shutil.rmtree(docs, ignore_errors=True)
        shutil.rmtree(put_docs, ignore_errors=True)
        docs.mkdir()
        (put_docs / "ops" / "node" / "mac-work" / "receipt").mkdir(parents=True)
        (put_docs / "ops" / "node").mkdir(parents=True, exist_ok=True)
        for key, document in state.get("docs", {}).items():
            path = docs / key
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"document": document}), encoding="utf-8")

    def write_herdr(self, value):
        (self.home / "herdr.json").write_text(json.dumps(value), encoding="utf-8")

    def put_instruction(self, body, key=None, created_by="operator-desk", omit_creator=False):
        if key is None:
            key = self.instruction_key
        state = self.read_state()
        doc = {"body": json.dumps(body, separators=(",", ":"))}
        if not omit_creator:
            doc["created_by"] = created_by
        state["docs"][key] = doc
        self.write_state(state)
        return key

    def base_body(self, **updates):
        body = {
            "v": 1,
            "id": self.instruction_id,
            "machine": "mac-work",
            "action": "repo-ff",
            "repo": "agent-skills",
            "sha": self.base_sha,
        }
        body.update(updates)
        return body

    def run_cli(self, key=None, timeout=30):
        if key is None:
            key = self.instruction_key
        output = io.StringIO()
        with contextlib.redirect_stdout(output), unittest.mock.patch.dict(os.environ, self.env, clear=True):
            code = NODE_OPS.main([str(self.script), "apply", key])
        return SimpleNamespace(returncode=code, stdout=output.getvalue(), stderr="")

    def run_cli_process(self, key=None, timeout=30):
        if key is None:
            key = self.instruction_key
        try:
            return subprocess.run(
                [str(self.script), "apply", key],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
                timeout=timeout,
                shell=False,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(
                "node-ops timed out; hk calls {}; git calls {}; stdout {}; stderr {}".format(
                    self.calls("hk-calls.jsonl"),
                    self.calls("git-calls.jsonl"),
                    exc.stdout,
                    exc.stderr,
                )
            ) from exc

    def run_apply_in_process(self, key=None, fetcher=None):
        if key is None:
            key = self.instruction_key
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.ExitStack() as stack:
            stack.enter_context(unittest.mock.patch.dict(os.environ, self.env, clear=True))
            if fetcher is not None:
                stack.enter_context(unittest.mock.patch.object(NODE_OPS, "production_fetcher", fetcher))
            code = NODE_OPS.main([str(self.script), "apply", key])
        return code, output.getvalue()

    def calls(self, filename):
        path = self.home / filename.replace(".jsonl", ".bin")
        if not path.exists():
            return []
        result = []
        for record in path.read_bytes().split(b"\n"):
            if record:
                args = record.split(b"\0")
                if args and args[-1] == b"":
                    args.pop()
                result.append([arg.decode("utf-8") for arg in args])
        return result

    def receipt(self):
        document = self.read_state()["docs"].get(self.receipt_key)
        self.assertIsNotNone(document)
        return json.loads(document["body"])

    def head(self):
        return git_raw(["-C", str(self.repo), "rev-parse", "HEAD"], self.fixture_env)

    def merge_calls(self):
        return [args for args in self.calls("git-calls.jsonl") if "merge" in args]

    def advance_origin(self, replacement=None):
        self.reset_repo_after = True
        old = self.base_sha
        if replacement is not None:
            (self.repo / "bin" / "node-ops").write_text(replacement, encoding="utf-8")
        else:
            (self.repo / "README.md").write_text("next\n", encoding="utf-8")
        git_raw(
            ["-c", "user.email=node-ops@example.invalid", "-c", "user.name=Node Ops Test", "-C", str(self.repo), "commit", "-am", "next"],
            self.fixture_env,
        )
        target = self.head()
        git_raw(["-C", str(self.repo), "push", "origin", "main"], self.fixture_env)
        git_raw(["-C", str(self.repo), "reset", "--hard", old], self.fixture_env)
        return target


class TestIssuerAndIdentity(NodeOpsCase):
    def test_issuer_forged_desk_refused(self):
        self.put_instruction(self.base_body(), created_by="forged-desk")
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertIn("result=refused", result.stdout)
        self.assertEqual(self.calls("git-calls.jsonl"), [])
        self.assertEqual(self.receipt()["reason"], "invalid_issuer")

    def test_issuer_operator_desk_suffix_refused(self):
        self.put_instruction(self.base_body(), created_by="operator-desk-x")
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "invalid_issuer")
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_issuer_missing_created_by_refused(self):
        self.put_instruction(self.base_body(), omit_creator=True)
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "invalid_issuer")
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_issuer_operator_desk_accepted(self):
        self.put_instruction(self.base_body(sha="deadbeef"), created_by="operator-desk")
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["result"], "refused")
        self.assertEqual(self.receipt()["reason"], "invalid_sha")
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_issuer_operator_accepted(self):
        self.put_instruction(self.base_body(), created_by="operator")
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.receipt()["result"], "ok")
        self.assertTrue(any("status" in args for args in self.calls("git-calls.jsonl")))

    def test_machine_probe_wins_over_body_machine(self):
        self.put_instruction(self.base_body(machine="other-host"))
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "machine_mismatch")
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_key_and_doc_cannot_supply_machine_identity(self):
        other_key = "ops/node/other-host/instr/" + self.instruction_id
        self.put_instruction(self.base_body(machine="other-host"), key=other_key)
        result = self.run_cli(other_key)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "machine_mismatch")
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_invalid_probe_machine_refuses_without_receipt_put(self):
        state = self.read_state()
        state["machine"] = "bad machine"
        self.write_state(state)
        self.put_instruction(self.base_body())
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout.strip(), "RECEIPT key=- result=refused")
        puts = [args for args in self.calls("hk-calls.jsonl") if args[:2] == ["doc", "put"]]
        self.assertEqual([args[3] for args in puts], ["ops/node/_identity"])

    def test_missing_instruction_has_no_probe_or_receipt_put(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), "RECEIPT key=- result=failed")
        self.assertEqual([args for args in self.calls("hk-calls.jsonl") if args[:2] == ["doc", "put"]], [])


class TestReplayAndInstructionValidation(NodeOpsCase):
    def test_idempotency_existing_ok_receipt_short_circuits_forged_issuer(self):
        self.put_instruction(self.base_body(), created_by="forged-desk")
        state = self.read_state()
        original = {"created_by": "mac-work", "body": json.dumps({"id": self.instruction_id, "result": "ok"})}
        state["docs"][self.receipt_key] = original
        self.write_state(state)
        before = self.head()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "RECEIPT key={} result=ok".format(self.receipt_key))
        self.assertEqual(self.head(), before)
        self.assertEqual(self.read_state()["docs"][self.receipt_key], original)
        puts = [args for args in self.calls("hk-calls.jsonl") if args[:2] == ["doc", "put"]]
        self.assertEqual([args[3] for args in puts], ["ops/node/_identity"])
        self.assertEqual(self.calls("git-calls.jsonl"), [])

        self.instruction_id = "20261012-0002-default"
        self.instruction_key = "ops/node/mac-work/instr/" + self.instruction_id
        self.receipt_key = "ops/node/mac-work/receipt/" + self.instruction_id
        self.put_instruction(self.base_body(), created_by="forged-desk")
        state = self.read_state()
        state["docs"][self.receipt_key] = {"created_by": "mac-work", "body": json.dumps({"id": self.instruction_id})}
        self.write_state(state)
        before = self.head()
        for filename in ("hk-calls.bin", "git-calls.bin"):
            path = self.home / filename
            if path.exists():
                path.unlink()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "RECEIPT key={} result=failed".format(self.receipt_key))
        self.assertEqual(self.head(), before)
        self.assertEqual(
            self.read_state()["docs"][self.receipt_key],
            {"created_by": "mac-work", "body": json.dumps({"id": self.instruction_id})},
        )
        puts = [args for args in self.calls("hk-calls.jsonl") if args[:2] == ["doc", "put"]]
        self.assertEqual([args[3] for args in puts], ["ops/node/_identity"])
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_malformed_and_non_ok_replay_receipts_never_report_ok(self):
        self.put_instruction(self.base_body(), created_by="forged-desk")
        cases = [
            ([], "failed"),
            ({"created_by": "mac-work", "body": "{"}, "failed"),
            ({"created_by": "mac-work", "body": json.dumps({"result": ["ok"]})}, "failed"),
            ({"created_by": "mac-work", "body": json.dumps({"result": "refused"})}, "refused"),
            ({"created_by": "mac-work", "body": json.dumps({"result": "failed"})}, "failed"),
        ]
        before = self.head()
        for stored_document, expected_result in cases:
            with self.subTest(stored_document=stored_document):
                for filename in ("hk-calls.bin", "git-calls.bin"):
                    path = self.home / filename
                    if path.exists():
                        path.unlink()
                state = self.read_state()
                state["docs"][self.receipt_key] = stored_document
                self.write_state(state)
                result = self.run_cli()
                self.assertEqual(result.returncode, 0)
                self.assertEqual(
                    result.stdout.strip(),
                    "RECEIPT key={} result={}".format(self.receipt_key, expected_result),
                )
                self.assertEqual(self.head(), before)
                self.assertEqual(self.read_state()["docs"][self.receipt_key], stored_document)
                puts = [args for args in self.calls("hk-calls.jsonl") if args[:2] == ["doc", "put"]]
                self.assertEqual([args[3] for args in puts], ["ops/node/_identity"])
                self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_invalid_id_refuses_without_receipt(self):
        body = self.base_body(id="bad-id")
        self.put_instruction(body)
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout.strip(), "RECEIPT key=- result=refused")
        self.assertNotIn(self.receipt_key, self.read_state()["docs"])

    def test_invalid_body_version_is_refused(self):
        body = self.base_body(v=True)
        self.put_instruction(body)
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "invalid_body")

    def test_key_must_match_probe_machine_and_instruction_id(self):
        wrong_key = "ops/node/mac-work/instr/20261012-9999-other"
        self.put_instruction(self.base_body(), key=wrong_key)
        result = self.run_cli(wrong_key)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "key_mismatch")
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_unknown_action_is_refused(self):
        self.put_instruction(self.base_body(action="run-anything"))
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "unknown_action")
        self.assertEqual(self.calls("git-calls.jsonl"), [])


class TestRunArgv(NodeOpsCase):
    def test_run_argv_uses_a_bounded_timeout(self):
        self.assertEqual(NODE_OPS.ARGV_TIMEOUT_SECONDS, 60)
        with unittest.mock.patch.object(NODE_OPS, "ARGV_TIMEOUT_SECONDS", 0.1):
            with self.assertRaises(subprocess.TimeoutExpired):
                NODE_OPS.run_argv([sys.executable, "-c", "import time; time.sleep(1)"])


class TestRepoFastForward(NodeOpsCase):
    def assert_refused_without_merge(self, body, setup=None):
        if setup is not None:
            setup()
        self.put_instruction(body)
        before = self.head()
        result = self.run_cli()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.head(), before)
        self.assertEqual(self.merge_calls(), [])
        self.assertEqual(self.receipt()["result"], "refused")

    def test_unknown_repo_is_refused_before_git(self):
        self.put_instruction(self.base_body(repo="scopefuel"))
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.receipt()["reason"], "unknown_repo")
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_non_hex_sha_refused_before_git(self):
        self.put_instruction(self.base_body(sha="z" * 40))
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls("git-calls.jsonl"), [])
        self.assertEqual(self.head(), git_raw(["-C", str(self.repo), "rev-parse", "HEAD"], self.fixture_env))

    def test_short_sha_refused_before_git(self):
        self.put_instruction(self.base_body(sha="deadbeef"))
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls("git-calls.jsonl"), [])

    def test_side_branch_sha_is_refused_before_merge(self):
        def make_side_sha():
            self.reset_repo_after = True
            git_raw(["-C", str(self.repo), "checkout", "-b", "side"], self.fixture_env)
            (self.repo / "side.txt").write_text("side\n", encoding="utf-8")
            git_raw(["-C", str(self.repo), "add", "side.txt"], self.fixture_env)
            git_raw(
                ["-c", "user.email=node-ops@example.invalid", "-c", "user.name=Node Ops Test", "-C", str(self.repo), "commit", "-m", "side"],
                self.fixture_env,
            )
            self.side_sha = self.head()
            git_raw(["-C", str(self.repo), "checkout", "main"], self.fixture_env)

        make_side_sha()
        self.put_instruction(self.base_body(sha=self.side_sha))
        before = self.head()
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.head(), before)
        self.assertEqual(self.merge_calls(), [])
        self.assertEqual(self.receipt()["reason"], "sha_not_ancestor_of_origin_main")

    def test_dirty_tree_is_refused(self):
        def dirty():
            self.reset_repo_after = True
            (self.repo / "README.md").write_text("dirty\n", encoding="utf-8")

        self.assert_refused_without_merge(self.base_body(), dirty)

    def test_untracked_file_is_refused(self):
        def untracked():
            self.reset_repo_after = True
            (self.repo / "untracked.txt").write_text("untracked\n", encoding="utf-8")

        self.assert_refused_without_merge(self.base_body(), untracked)

    def test_non_main_branch_is_refused(self):
        def branch():
            self.reset_repo_after = True
            git_raw(["-C", str(self.repo), "checkout", "-b", "other"], self.fixture_env)

        self.assert_refused_without_merge(self.base_body(), branch)

    def test_success_receipt_has_before_after_and_sha_reason(self):
        target = self.advance_origin()
        self.put_instruction(self.base_body(sha=target, path="/tmp/ignored-checkout"))
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        receipt = self.receipt()
        self.assertEqual(receipt["result"], "ok")
        self.assertTrue(receipt["before"])
        self.assertTrue(receipt["after"])
        self.assertEqual(receipt["after"], target)
        self.assertEqual(receipt["reason"], "after_eq_sha=true")
        self.assertEqual(
            set(receipt),
            {"id", "action", "result", "reason", "before", "after", "checked_at"},
        )
        self.assertRegex(receipt["checked_at"], r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
        git_calls = self.calls("git-calls.jsonl")
        self.assertTrue(git_calls)
        self.assertTrue(all(args[1] == str(self.repo) for args in git_calls))

    def test_self_fast_forward_finishes_loaded_script_and_receipt(self):
        broken = "import sys\nsys.exit(9)\n"
        target = self.advance_origin(replacement=broken)
        self.put_instruction(self.base_body(sha=target))
        result = self.run_cli_process(timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(), target)
        self.assertEqual(self.receipt()["after"], target)
        self.assertTrue(result.stdout.strip().endswith("result=ok"))


class TestHkCliInstall(NodeOpsCase):
    TAG = "v1.2.3"

    def install_body(self, content, **extra):
        body = {
            "v": 1,
            "id": self.instruction_id,
            "machine": "mac-work",
            "action": "hk-cli-install",
            "tag": self.TAG,
            "os_arch": "darwin_arm64",
            "sha256": hashlib.sha256(content).hexdigest(),
        }
        body.update(extra)
        return body

    def fake_binary(self, version_line):
        state = self.read_state()
        state["hk_version"] = version_line
        self.write_state(state)
        return HK_STUB_TEMPLATE.replace("#!/bin/sh\n", "#!/bin/sh\n# downloaded fixture binary\n", 1).encode("utf-8")

    def install_in_process(self, content, body=None, fetcher=None):
        if body is None:
            body = self.install_body(content)
        self.put_instruction(body)
        if fetcher is None:
            fetcher = lambda url, max_bytes: [content]
        return self.run_apply_in_process(fetcher=fetcher)

    def test_sha256_mismatch_keeps_binary_and_creates_no_backup(self):
        old = (self.bin_dir / "handoffkeep").read_bytes()
        content = self.fake_binary("release=" + self.TAG)
        body = self.install_body(content, sha256="0" * 64)
        code, output = self.install_in_process(content, body=body)
        self.assertEqual(code, 2)
        self.assertIn("result=refused", output)
        self.assertEqual((self.bin_dir / "handoffkeep").read_bytes(), old)
        self.assertEqual(list(self.bin_dir.glob("handoffkeep.bak-*")), [])

    def test_smoke_requires_exact_release_token(self):
        old = (self.bin_dir / "handoffkeep").read_bytes()
        content = self.fake_binary("rev=abc release=v1.2.30")
        code, output = self.install_in_process(content)
        self.assertEqual(code, 2)
        self.assertIn("result=refused", output)
        self.assertEqual((self.bin_dir / "handoffkeep").read_bytes(), old)
        self.assertEqual(list(self.bin_dir.glob("handoffkeep.bak-*")), [])

    def test_success_installs_exact_token_ignores_url_fields_and_keeps_backup(self):
        old = (self.bin_dir / "handoffkeep").read_bytes()
        content = self.fake_binary("rev=abc release=v1.2.3 channel=stable")
        urls = []

        def fetcher(url, max_bytes):
            urls.append(url)
            self.assertEqual(max_bytes, 64 * 1024 * 1024)
            return [content]

        body = self.install_body(
            content,
            url="https://evil.example/attacker",
            host="evil.example",
            SHA256SUMS="https://example.invalid/SHA256SUMS",
        )
        code, output = self.install_in_process(content, body=body, fetcher=fetcher)
        self.assertEqual(code, 0, output)
        self.assertEqual((self.bin_dir / "handoffkeep").read_bytes(), content)
        backups = list(self.bin_dir.glob("handoffkeep.bak-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), old)
        self.assertRegex(backups[0].name, r"^handoffkeep\.bak-[0-9]{8}T[0-9]{6}Z$")
        self.assertTrue(os.access(self.bin_dir / "handoffkeep", os.X_OK))
        self.assertEqual(self.receipt()["result"], "ok")
        self.assertIn("release=v1.2.3", self.receipt()["reason"])
        self.assertEqual(self.receipt()["before"], str(self.bin_dir / "handoffkeep"))
        self.assertEqual(self.receipt()["after"], str(self.bin_dir / "handoffkeep"))
        self.assertEqual(
            urls,
            ["https://github.com/mgh3326/handoffkeep/releases/download/v1.2.3/handoffkeep_darwin_arm64"],
        )
        self.assertFalse(any("SHA256SUMS" in url for url in urls))

    def test_redirect_policy_allows_only_supported_hosts_and_schemes(self):
        self.assertFalse(NODE_OPS.valid_redirect_url("https://evil.example/a"))
        self.assertFalse(NODE_OPS.valid_redirect_url("http://github.com/a"))
        self.assertFalse(NODE_OPS.valid_redirect_url("https://github.com/a?x=1"))
        self.assertFalse(NODE_OPS.valid_redirect_url("https://github.com/a#"))
        self.assertTrue(NODE_OPS.valid_redirect_url("https://github.com/a"))
        self.assertTrue(NODE_OPS.valid_redirect_url("https://objects.githubusercontent.com/a?sig=1"))
        self.assertTrue(NODE_OPS.valid_redirect_url("https://release-assets.githubusercontent.com/a?sig=1"))
        self.assertFalse(NODE_OPS.valid_redirect_url("https://release-assets.githubusercontent.com.evil.example/a"))
        self.assertFalse(NODE_OPS.valid_redirect_url("http://release-assets.githubusercontent.com/a"))
        self.assertFalse(NODE_OPS.valid_redirect_url("https://user@release-assets.githubusercontent.com/a"))
        self.assertFalse(NODE_OPS.valid_redirect_url("https://release-assets.githubusercontent.com/a#fragment"))
        self.assertFalse(NODE_OPS.valid_redirect_url("https://release-assets.githubusercontent.com:444/a"))

    def test_download_cap_is_64_mib_and_rejects_overflow(self):
        self.assertEqual(NODE_OPS.MAX_DOWNLOAD_BYTES, 64 * 1024 * 1024)
        old = (self.bin_dir / "handoffkeep").read_bytes()
        content = self.fake_binary("release=" + self.TAG)
        body = self.install_body(content)
        self.put_instruction(body)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.ExitStack() as stack:
            stack.enter_context(unittest.mock.patch.dict(os.environ, self.env, clear=True))
            stack.enter_context(unittest.mock.patch.object(NODE_OPS, "MAX_DOWNLOAD_BYTES", 8))
            stack.enter_context(unittest.mock.patch.object(NODE_OPS, "production_fetcher", lambda url, max_bytes: [content]))
            result = NODE_OPS.apply_instruction(self.instruction_key)
        self.assertEqual(result, 2, output.getvalue())
        self.assertIn("result=refused", output.getvalue())
        self.assertEqual((self.bin_dir / "handoffkeep").read_bytes(), old)
        self.assertEqual(list(self.bin_dir.glob("handoffkeep.bak-*")), [])


class TestStatusSkillAndSelfcheck(NodeOpsCase):
    def test_status_receipt_has_allowlisted_fields_without_pane_text(self):
        (self.bin_dir / "panewire").unlink()
        self.write_herdr(
            {
                "panes": [
                    {"id": "p1", "agent": "haiku", "status": "ready", "label": "m1-ops", "text": "SECRET_SCROLLBACK"}
                ]
            }
        )
        body = self.base_body(action="status")
        self.put_instruction(body)
        result = self.run_cli()
        self.assertEqual(result.returncode, 0)
        receipt_text = self.read_state()["docs"][self.receipt_key]["body"]
        receipt = json.loads(receipt_text)
        self.assertEqual(receipt["result"], "ok")
        self.assertEqual(
            set(receipt["after"]),
            {"repos", "wrk", "handoffkeep", "panewire", "panes", "disk_free_bytes"},
        )
        self.assertEqual(receipt["after"]["panes"], [{"id": "p1", "agent": "haiku", "status": "ready", "label": "m1-ops"}])
        self.assertNotIn("SECRET_SCROLLBACK", receipt_text)
        self.assertIsNone(receipt["before"])
        self.assertEqual(receipt["after"]["wrk"], self.head())
        self.assertEqual(receipt["after"]["panewire"], "missing")
        self.assertEqual(receipt["after"]["handoffkeep"], "handoffkeep v-test")
        self.assertGreater(receipt["after"]["disk_free_bytes"], 0)
        identity = self.read_state()["docs"]["ops/node/_identity"]
        self.assertEqual(identity["body"], '{"v":1,"purpose":"identity"}')
        puts = [args for args in self.calls("hk-calls.jsonl") if args[:2] == ["doc", "put"]]
        self.assertEqual(puts[0][3:7], ["ops/node/_identity", "--kind", "note", "--file"])
        self.assertEqual([args[3] for args in puts], ["ops/node/_identity", self.receipt_key])

    def test_injection_values_never_become_command_arguments(self):
        value = ";$( )`id`\n-leading"
        body = self.base_body(sha=value)
        self.put_instruction(body)
        result = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls("git-calls.jsonl"), [])
        self.assertTrue(all(value not in " ".join(args) for args in self.calls("hk-calls.jsonl")))

    def test_skill_file_has_narrow_message_and_command_rules(self):
        skill = (ROOT / "node-ops" / "SKILL.md").read_text(encoding="utf-8")
        self.assertLess(len(skill.splitlines()), 80)
        self.assertIn("node-ops apply", skill)
        self.assertIn("operator-desk", skill)
        for forbidden in ("eval", "sh -c", "os.system"):
            self.assertNotIn(forbidden, skill)

    def test_runbook_covers_required_operations(self):
        runbook = (ROOT / "docs" / "runbooks" / "m1-no-ssh.md").read_text(encoding="utf-8")
        for required in (
            "Issue an instruction",
            "15 minutes",
            "panewire hub-status",
            "up to 20 MB",
            "Drive",
            "pa-m1",
            "Tailscale",
            "operator sets up",
            "handoffkeep attach put",
        ):
            self.assertIn(required, runbook)

    def test_selfcheck_prints_map_without_any_put(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), unittest.mock.patch.dict(os.environ, self.env, clear=True):
            code = NODE_OPS.main([str(self.script), "selfcheck"])
        self.assertEqual(code, 0)
        self.assertIn("agent-skills=", output.getvalue())
        self.assertIn("identity=not-written", output.getvalue())
        self.assertIn("handoffkeep=", output.getvalue())
        self.assertIn("panewire=", output.getvalue())
        self.assertEqual([args for args in self.calls("hk-calls.jsonl") if args[:2] == ["doc", "put"]], [])


if __name__ == "__main__":
    unittest.main()
