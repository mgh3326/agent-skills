"""C1 transport, journal-intent and projection contracts (no network/agents)."""
import ast
import copy
import hashlib
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
TEST_PARENT = Path("/tmp")
PACK = ROOT / "tests/fixtures/o3"
ADAPTER = ROOT / "bin/wrk-o3.py"
WRK = ROOT / "bin/wrk"
MANIFEST_SHA = "ee0bbf869e3c62017471f1389e9e4b3113f8d8c02a090ad40e57588193df6d55"
PACK_COMMIT = "28c34a670da0dd95a3b578be959732c85f0405a2"
DESIGN_SHA = "ce4f6efbe39514bb0bced2d0a66510e646058a66d0d28bbb417af180f375c19d"
GEN = "00000000-0000-4000-8000-ffff00000001"
SCRUB = ("HANDOFFKEEP_URL", "HANDOFFKEEP_TOKEN", "HANDOFFKEEP_CF_ACCESS_CLIENT_ID",
         "HANDOFFKEEP_CF_ACCESS_CLIENT_SECRET")

# Director-1 ruling, 2026-10-26: design r4 wins over pack defects. Entries
# are (file, case) -> {section, design_expect}; retain only mechanically
# demonstrated differences. The stale-entry/unlisted-difference gate below
# must fail when M1 is corrected. No pack file is edited.
pack_divergence = {}
# hk 2049 / M1r fixed the eight seal histories in 28c34a6. Director-1's
# update ruling requires this table empty, with stale-entry protection kept.

CLI_VECTOR_TESTS = {
    "path-fake-or-overridden-binary-refused": "TransportTests.test_production_resolver_ignores_path_and_refuses_unsafe_binary",
    "unguarded-hk-bin-lookup-rejected": "ReadTests.test_every_later_page_revalidates_the_binary",
    "env-token-with-cli-unavailable-no-fallback": "TransportTests.test_env_only_token_has_no_fallback_when_cli_is_unavailable",
    "server-host-mismatch-exit-77": "TransportTests.test_stable_error_codes_are_not_success",
    "server-round-cap-exit-78": "TransportTests.test_stable_error_codes_are_not_success",
    "server-sequence-conflict-exit-73": "TransportTests.test_stable_error_codes_are_not_success",
    "commit-then-response-lost-file-changed": "IntentTests.test_unknown_reply_retains_key_body_and_original_evidence",
    "definitive-sequence-conflict-then-refresh": "IntentTests.test_definite_sequence_conflict_requires_explicit_refresh_and_new_key",
    "crash-before-send-after-commit-after-fsync": "CrashTests.test_crashes_before_send_after_commit_and_after_accepted_fsync",
    "intent-symlink-mode-malformed-fsync-fails": "IntentTests.test_bad_intent_files_refuse_before_send",
    "cursor-page-inconsistent-history-regressed": "ReadTests.test_records_with_bad_hash_or_sequence_never_return_partial_history",
    "redirect-html-namespace-unknown-code": "TransportTests.test_malformed_or_unsupported_response_is_safe",
    "caller-env-overrides-scrubbed": "TransportTests.test_override_environment_keys_absent",
    "commit-then-proxy-5xx-pending-intent": "IntentTests.test_only_definite_refusals_reject_intents",
}
MATRIX_TESTS = {
    "claim/spawn": ("SpawnHandshakeTests.test_real_o3_spawn_never_calls_legacy_hk_bin",
                    "MatrixModeTests.test_local_o2_files_do_not_prove_enrollment",
                    "MatrixModeTests.test_old_namespace_fails_closed_for_every_command",
                    "SpawnHandshakeTests.test_failure_after_review_claim_leaves_claim_visible_and_no_local_claim"),
    "round open": ("RoundCommandTests.test_real_round_open_verdict_and_void_transport",
                   "MatrixModeTests.test_local_o2_files_do_not_prove_enrollment",
                   "MatrixModeTests.test_old_namespace_fails_closed_for_every_command",
                   "MatrixModeTests.test_first_get_outage_creates_no_invented_intent"),
    "round verdict": ("RoundCommandTests.test_real_round_open_verdict_and_void_transport",
                      "MatrixModeTests.test_local_o2_files_do_not_prove_enrollment",
                      "MatrixModeTests.test_old_namespace_fails_closed_for_every_command",
                      "RoundCommandTests.test_stable_refusal_cannot_publish_a_verdict"),
    "round void": ("RoundCommandTests.test_real_typed_void_projects_only_after_acceptance",
                   "MatrixModeTests.test_local_o2_files_do_not_prove_enrollment",
                   "MatrixModeTests.test_old_namespace_fails_closed_for_every_command",
                   "MatrixModeTests.test_first_get_outage_creates_no_invented_intent"),
    "round status/audit": ("ReadTests.test_pagination_is_fixed_snapshot_and_cache_is_not_authority",
                           "MatrixModeTests.test_local_o2_files_do_not_prove_enrollment",
                           "MatrixModeTests.test_old_namespace_fails_closed_for_every_command",
                           "RoundCommandTests.test_offline_status_is_explicitly_stale_and_unverified"),
    "joined": ("TypedAdapterTests.test_joined_is_adapter_only",
               "MatrixModeTests.test_local_o2_files_do_not_prove_enrollment",
               "MatrixModeTests.test_old_namespace_fails_closed_for_every_command",
               "MatrixModeTests.test_first_get_outage_creates_no_invented_intent"),
    "done": ("TypedAdapterTests.test_completed_is_adapter_only",
             "MatrixModeTests.test_local_o2_files_do_not_prove_enrollment",
             "MatrixModeTests.test_old_namespace_fails_closed_for_every_command",
             "MatrixModeTests.test_first_get_outage_creates_no_invented_intent"),
}


class PackTests(unittest.TestCase):
    def test_matrix_and_transport_coverage_tables_are_complete(self):
        matrix = json.loads((PACK / "matrix.json").read_text())
        self.assertEqual(set(MATRIX_TESTS), {r["command"] for r in matrix["commands"]})
        self.assertTrue(all(len(tests) == len(matrix["mode_columns"]) == 4 for tests in MATRIX_TESTS.values()))
        cli = json.loads((PACK / "vectors/transport-intents.json").read_text())
        self.assertEqual(set(CLI_VECTOR_TESTS), {c["name"] for c in cli["cases"]})
        for name in set(CLI_VECTOR_TESTS.values()) | {x for row in MATRIX_TESTS.values() for x in row}:
            klass, method = name.split(".")
            self.assertTrue(callable(getattr(globals()[klass], method)), name)
    def test_manifest_pins_every_byte(self):
        raw = (PACK / "MANIFEST.json").read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), MANIFEST_SHA)
        manifest = json.loads(raw)
        self.assertEqual(manifest["design"]["body_sha256"], DESIGN_SHA)
        actual = {str(p.relative_to(PACK)) for p in PACK.rglob("*") if p.is_file()}
        self.assertEqual(actual, set(manifest["files"]) | {"MANIFEST.json"})
        for name, pin in manifest["files"].items():
            with self.subTest(name=name):
                body = (PACK / name).read_bytes()
                self.assertEqual(len(body), pin["bytes"])
                self.assertEqual(hashlib.sha256(body).hexdigest(), pin["sha256"])

    def test_pack_divergence_table_is_exhaustive_and_stale_entries_fail(self):
        observed = {}
        for path in (PACK / "vectors").glob("*.json"):
            for case in json.loads(path.read_text())["cases"]:
                seals = [r for r in case["given"].get("records", []) if r["kind"] == "import_seal"]
                bad = [r for r in seals if r["payload"]["numbering_floor"] < r["payload"]["baseline_used"]]
                if bad:
                    key = (path.name, case["name"])
                    observed[key] = "protocol_invalid"
                    pack_result = case["expect"].get("error", "accepted")
                    self.assertNotEqual(pack_result, observed[key], "pack fix requires removal of stale divergence")
        self.assertEqual(observed, pack_divergence, "new divergences require an explicit director ruling")


class Harness(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="o3-", dir=TEST_PARENT)).resolve()
        self.addCleanup(self.cleanup)
        self.home = self.root / "home"
        self.hk = self.home / ".local/bin/handoffkeep"
        self.hk.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "tests/fixtures/wrk-o3/handoffkeep", self.hk)
        self.hk.chmod(0o700)
        self.script = self.root / "script.json"
        self.env = {key: os.environ[key] for key in os.environ
                    if key not in SCRUB and key not in ("ARBITER_JOB", "HK_TASK_ID", "BASH_ENV", "ENV",
                                                        "CLAUDE_CONFIG_DIR", "HANDOFFKEEP_TEST_DB_URL")}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.root),
                        XDG_CONFIG_HOME=str(self.root / "config"),
                        XDG_CONFIG_DIRS=str(self.root / "config"),
                        XDG_DATA_DIRS=str(self.root / "data"),
                        XDG_CACHE_HOME=str(self.root / "cache"),
                        XDG_STATE_HOME=str(self.root / "state"),
                        XDG_DATA_HOME=str(self.root / "data"),
                        XDG_RUNTIME_DIR=str(self.root / "runtime"),
                        CODEX_HOME=str(self.root / "codex"),
                        ARBITER_INBOX_ROOT=str(self.root / "jobs"),
                        HANDOFFKEEP_BIN=str(self.hk), WRK_TEST_MODE="1",
                        WRK_O3_STUB_SCRIPT=str(self.script))
        # Only fixture paths and OS tools. No installed agent/handoffkeep lookup.
        path_tools = self.root / "path-tools"
        path_tools.mkdir()
        (path_tools / "python3").symlink_to(sys.executable)
        trap = path_tools / "handoffkeep"
        trap.write_text("#!/bin/sh\n[ \"$WRK_TEST_MODE\" = 1 ] || exit 98\nexit 99\n")
        trap.chmod(0o700)
        self.env["PATH"] = str(path_tools) + ":/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
                    "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "CODEX_HOME", "ARBITER_INBOX_ROOT"):
            Path(self.env[key]).mkdir(parents=True, exist_ok=True)

    def cleanup(self):
        result = subprocess.run(["bash", "-c", '. "$1"; TW_TMP="$2"; ROOT="$3"; tmp_writers_stop',
                                 "o3-teardown", str(ROOT / "tests/lib/tmp-writers.sh"), str(self.root), str(WRK.parent.parent)],
                                cwd=ROOT, env=getattr(self, "env", None), capture_output=True, text=True, timeout=30)
        if result.returncode:
            self.fail("owned writers not stopped; retained " + str(self.root) + ": " + result.stderr)
        shutil.rmtree(self.root)

    def responses(self, *responses):
        self.script.write_text(json.dumps({"responses": list(responses), "calls": []}))

    def success(self, value):
        return {"stdout": json.dumps(value) + "\n"}

    def run_adapter(self, *args, stdin=""):
        return subprocess.run([sys.executable, str(ADAPTER), *args], input=stdin,
                              text=True, capture_output=True, env=self.env, timeout=15)

    def calls(self):
        return json.loads(self.script.read_text())["calls"]

    def capabilities(self):
        return dict(contract="hk1873.v1", store_generation=GEN, client_id="desktop",
                    policy_sha256="a" * 64, writes_available=True)

    @contextlib.contextmanager
    def client(self):
        spec = importlib.util.spec_from_file_location("wrk_o3_under_test", ADAPTER)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        with mock.patch.dict(os.environ, self.env, clear=True):
            yield self.module.Client()

    def seed(self, *responses):
        data = json.loads((PACK / "vectors/transition.json").read_text())
        records = data["cases"][0]["given"]["records"]
        self.script.write_text(json.dumps(dict(responses=list(responses), calls=[], journal=records)))
        return records

    def round_request(self, expected=2, head="1" * 40):
        return dict(kind="round_open", claim_seq=1, expected_seq=expected,
                    payload=dict(head=head, tester_job_id=None,
                                 extension_grant_seq=None, repeat_grant_seq=None))

    def intent_file(self, job="job-a"):
        return Path(self.env["ARBITER_INBOX_ROOT"]) / job / "o3-intents.json"

    def mode(self, mode):
        path = self.home / ".config/wrk/records-mode"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(mode + "\n")

    def run_wrk(self, *args, stdin=""):
        return subprocess.run(["bash", str(WRK), *args], input=stdin, text=True,
                              capture_output=True, env=self.env, timeout=180)

    def events(self, job="job-a"):
        return [json.loads(p.read_text()) for p in sorted(self.intent_file(job).parent.glob("events/*.json"))]

    def more_responses(self, *responses):
        data = json.loads(self.script.read_text())
        data["responses"].extend(responses)
        self.script.write_text(json.dumps(data))


class TransportTests(Harness):

    def test_capabilities_argv_and_empty_stdin(self):
        value = self.capabilities()
        self.responses(self.success(value))
        result = self.run_adapter("capabilities")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), value)
        self.assertEqual(self.calls()[0]["argv"], ["wrk", "capabilities"])
        self.assertEqual(self.calls()[0]["stdin"], "")

    def test_override_environment_keys_absent(self):
        self.env.update({key: "synthetic-override" for key in SCRUB})
        self.responses(self.success(self.capabilities()))
        result = self.run_adapter("capabilities")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(set(SCRUB) & set(self.calls()[0]["environment_keys"]))
        self.assertNotIn("synthetic-override", result.stdout + result.stderr)

    def test_stable_error_codes_are_not_success(self):
        for row in json.loads((PACK / "cli.json").read_text())["exit_map"]:
            for code in row["codes"]:
                with self.subTest(code=code):
                    self.responses({"exit": row["exit"], "stderr": f"handoffkeep wrk: {code}\n"})
                    result = self.run_adapter("capabilities")
                    self.assertEqual(result.returncode, row["exit"], result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(result.stderr, f"wrk o3: {code}\n")

    def test_malformed_or_unsupported_response_is_safe(self):
        for response in ({"stdout": "<html>synthetic-evidence</html>\n"},
                         {"stdout": "{}\n"}, {"stdout": "{}\n{}\n"},
                         {"exit": 77, "stderr": "handoffkeep wrk: unknown_code\n"},
                         {"exit": 0, "stderr": "synthetic-evidence\n", "stdout": "{}\n"}):
            with self.subTest(response=response):
                self.responses(response)
                result = self.run_adapter("capabilities")
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "wrk o3: protocol_invalid\n")

    def test_production_resolver_ignores_path_and_refuses_unsafe_binary(self):
        with self.client() as client:
            self.env["WRK_TEST_MODE"] = "0"
            self.env["ARBITER_INBOX_ROOT"] = str(self.home / "work/herdr-inbox/jobs")
            self.env["XDG_DATA_HOME"] = str(self.home / ".local/share")
            self.env.pop("HANDOFFKEEP_BIN")
            fake = self.root / "fake-path"
            fake.mkdir()
            (fake / "handoffkeep").write_text("#!/bin/sh\nexit 99\n")
            (fake / "handoffkeep").chmod(0o700)
            self.env["PATH"] = str(fake) + os.pathsep + self.env["PATH"]
            with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(self.module.pwd, "getpwuid", return_value=type("Account", (), {"pw_dir": str(self.home)})()):
                success = subprocess.CompletedProcess([], 0, (json.dumps(self.capabilities()) + "\n").encode(), b"")
                with mock.patch.object(self.module.subprocess, "run", return_value=success) as execute:
                    self.assertEqual(client.capabilities()["client_id"], "desktop")
                    self.assertEqual(execute.call_args.args[0][0], str(self.hk))
                    with mock.patch.dict(os.environ, {"HANDOFFKEEP_BIN": str(fake / "handoffkeep")}):
                        with self.assertRaises(self.module.Refusal) as error:
                            client.capabilities()
                        self.assertEqual(error.exception.exit, 2)
                    for mode in (0o722, 0o777):
                        self.hk.chmod(mode)
                        with self.assertRaises(self.module.Refusal) as error:
                            client.capabilities()
                        self.assertEqual(error.exception.exit, 2)
                    self.hk.chmod(0o700)
                    original_stat = os.stat
                    def foreign(path, *args, **kwargs):
                        info = original_stat(path, *args, **kwargs)
                        if str(path) == str(self.hk):
                            return type("Foreign", (), {"st_mode": info.st_mode, "st_uid": os.getuid() + 1})()
                        return info
                    with mock.patch.object(self.module.os, "stat", side_effect=foreign):
                        with self.assertRaises(self.module.Refusal) as error:
                            client.capabilities()
                        self.assertEqual(error.exception.exit, 2)
                    self.assertEqual(execute.call_count, 1, "all invalid binary/override probes must stop before exec")

    def test_env_only_token_has_no_fallback_when_cli_is_unavailable(self):
        self.env["HANDOFFKEEP_TOKEN"] = "synthetic-env-only"
        self.hk.unlink()
        self.responses()
        result = self.run_adapter("capabilities")
        self.assertEqual(result.returncode, 75)
        self.assertEqual(result.stderr, "wrk o3: transport_unavailable\n")
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls(), [])

    def test_content_is_json_validated_and_bound_to_exact_bytes(self):
        raw = b"immutable evidence\r\n"
        content = dict(job_id="job-a", seq=3, content_b64=base64.b64encode(raw).decode(),
                       content_sha256=hashlib.sha256(raw).hexdigest(), size_bytes=len(raw))
        self.responses(self.success(content))
        with self.client() as client:
            result = client.content("job-a", 3)
            self.assertEqual(base64.b64decode(result["content_b64"]), raw)
            self.assertEqual(self.calls()[0]["argv"], ["wrk", "content", "job-a", "3"])
            content["content_sha256"] = "0" * 64
            self.responses(self.success(content))
            with self.assertRaises(self.module.Refusal) as error:
                client.content("job-a", 3)
            self.assertEqual(error.exception.code, "protocol_invalid")

    def test_read_stdin_and_duplicate_or_extra_arguments_are_refused(self):
        for args, stdin, rc in ((["capabilities"], "nonempty", 65), (["job", "job-a", "extra"], "", 2),
                                (["records", "job-a", "--limit", "1", "--limit", "2"], "", 2),
                                (["capabilities", "--resume", str(uuid.uuid4())], "", 2)):
            with self.subTest(args=args):
                self.responses()
                result = self.run_adapter(*args, stdin=stdin)
                self.assertEqual(result.returncode, rc, result.stderr)
                self.assertEqual(self.calls(), [])


class IntentTests(Harness):
    def test_file_and_directory_fsync_precede_send(self):
        records = self.seed({"action": "accept"})
        with self.client() as client:
            trace = []
            fsync, call = self.module.os.fsync, client.call

            def sync(fd):
                import stat
                trace.append("directory" if stat.S_ISDIR(os.fstat(fd).st_mode) else "file")
                return fsync(fd)

            def send(*args, **kwargs):
                self.assertIn("file", trace, "intent must be file-fsynced before actual append")
                self.assertEqual(trace[-1], "directory", "rename must be directory-fsynced before send")
                self.assertEqual(json.loads(self.intent_file().read_text())["intents"][0]["state"], "pending")
                return call(*args, **kwargs)

            with mock.patch.object(self.module.os, "fsync", side_effect=sync), mock.patch.object(client, "call", side_effect=send):
                response = client.append("job-a", self.round_request(len(records)))
            saved = json.loads(self.intent_file().read_text())
            self.assertEqual(saved["intents"][0]["state"], "accepted")
            self.assertEqual(self.intent_file().stat().st_mode & 0o777, 0o600)
            self.assertEqual(saved["intents"][0]["receipt"]["seq"], response["record"]["seq"])

    def test_unknown_reply_retains_key_body_and_original_evidence(self):
        records = self.seed({"action": "commit_lost"}, {"action": "accept"})
        evidence = self.root / "verdict.md"
        original = b"VERDICT: PASS @" + b"1" * 40 + b"\noriginal review\n"
        evidence.write_bytes(original)
        with self.client() as client:
            with self.assertRaises(self.module.Refusal) as error:
                client.evidence("job-a", "verdict", evidence, len(records), 1, round_no=1, tester_job_id=None)
            self.assertEqual(error.exception.code, "transport_indeterminate")
            pending = json.loads(self.intent_file().read_text())["intents"][0]
            self.assertEqual(pending["state"], "pending")
            evidence.write_text("changed file is no longer a verdict")
            try:
                response = client.evidence("job-a", "verdict", evidence, 999, 999, round_no=1, tester_job_id=None)
            except self.module.Refusal as error:
                self.fail("original key/body recovery must succeed: " + error.code)
            self.assertFalse(response["created"])
            calls = self.calls()
            self.assertEqual(calls[0]["argv"], calls[1]["argv"])
            self.assertEqual(calls[0]["stdin"], calls[1]["stdin"])
            self.assertEqual(base64.b64decode(json.loads(calls[1]["stdin"])["content_b64"]), original)
            self.assertEqual(len(json.loads(self.script.read_text())["journal"]), len(records) + 1)

    def test_only_definite_refusals_reject_intents(self):
        for code, rc, state in (("host_mismatch", 77, "rejected"), ("round_cap", 78, "rejected"),
                                ("sequence_conflict", 73, "rejected"), ("wrk_unavailable", 75, "pending"),
                                ("protocol_invalid", 75, "pending"), ("transport_indeterminate", 75, "pending")):
            with self.subTest(code=code), self.client() as client:
                job = "job-" + code
                self.responses(dict(exit=rc, stderr=f"handoffkeep wrk: {code}\n"))
                with self.assertRaises(self.module.Refusal) as error:
                    client.append(job, self.round_request())
                self.assertEqual(error.exception.code, code)
                intent = json.loads(self.intent_file(job).read_text())["intents"][0]
                self.assertEqual(intent["state"], state)

    def test_bad_intent_files_refuse_before_send(self):
        for variant in ("symlink", "mode", "malformed", "digest"):
            with self.subTest(variant=variant), self.client() as client:
                self.responses()
                job = "job-" + variant
                path = self.intent_file(job)
                path.parent.mkdir()
                if variant == "symlink":
                    target = self.root / "target"
                    target.write_text('{}')
                    path.symlink_to(target)
                else:
                    path.write_text('{"version":1,"intents":[]}' if variant != "malformed" else '{')
                    path.chmod(0o644 if variant == "mode" else 0o600)
                    if variant == "digest":
                        with mock.patch.object(client, "call", side_effect=self.module.Refusal("transport_unavailable")):
                            with self.assertRaises(self.module.Refusal):
                                client.append(job, self.round_request())
                        data = json.loads(path.read_text())
                        data["intents"][0]["request"]["payload"]["head"] = "f" * 40
                        path.write_text(json.dumps(data))
                with self.assertRaises(self.module.Refusal) as error:
                    client.append(job, self.round_request())
                self.assertEqual(error.exception.code, "intent_invalid")
                self.assertEqual(self.calls(), [])

    def test_fsync_failure_has_no_send(self):
        self.responses()
        with self.client() as client, mock.patch.object(self.module.os, "fsync", side_effect=OSError("fixture failure")):
            with self.assertRaises(self.module.Refusal) as error:
                client.append("job-a", self.round_request())
            self.assertEqual(error.exception.code, "intent_io")
        self.assertEqual(self.calls(), [])

    def test_definite_sequence_conflict_requires_explicit_refresh_and_new_key(self):
        self.seed(dict(exit=73, stderr="handoffkeep wrk: sequence_conflict\n"),
                  {"action": "read"}, {"action": "read"}, {"action": "accept"})
        with self.client() as client:
            with self.assertRaises(self.module.Refusal):
                client.append("job-a", self.round_request(expected=3))
            current = client.job("job-a")
            client.append("job-a", self.round_request(expected=current["summary"]["snapshot_seq"]))
        intents = json.loads(self.intent_file().read_text())["intents"]
        self.assertEqual([x["state"] for x in intents], ["rejected", "accepted"])
        self.assertNotEqual(intents[0]["idempotency_key"], intents[1]["idempotency_key"])
        self.assertEqual(intents[0]["request"]["expected_seq"], 3)
        self.assertEqual(intents[1]["request"]["expected_seq"], 2)

    def test_receipt_fsync_failure_preserves_original_pending_send(self):
        self.seed({"action": "accept"}, {"action": "accept"})
        with self.client() as client:
            original, calls = self.module.os.fsync, 0
            def sync(fd):
                nonlocal calls
                calls += 1
                if calls == 4:
                    raise OSError("fixture accepted-receipt fsync failure")
                return original(fd)
            with mock.patch.object(self.module.os, "fsync", side_effect=sync):
                with self.assertRaises(self.module.Refusal) as error:
                    client.append("job-a", self.round_request())
            self.assertEqual(error.exception.code, "intent_io")
            item = json.loads(self.intent_file().read_text())["intents"][0]
            self.assertEqual(item["state"], "pending")
            self.assertFalse(client.append("job-a", resume=item["local_id"])["created"])
        self.assertEqual(self.calls()[0]["argv"], self.calls()[1]["argv"])

    def test_concurrent_writers_keep_atomic_distinct_intents(self):
        self.seed({"action": "accept"}, {"action": "accept"})
        processes = []
        try:
            for head in ("a" * 40, "b" * 40):
                process = subprocess.Popen([sys.executable, str(ADAPTER), "append", "job-a"],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, env=self.env)
                process.stdin.write(json.dumps(self.round_request(head=head)))
                process.stdin.close()
                process.stdin = None
                processes.append(process)
            results = [p.communicate(timeout=30) for p in processes]
            self.assertEqual(sorted(p.returncode for p in processes), [0, 73], str(results))
            intents = json.loads(self.intent_file().read_text())["intents"]
            self.assertEqual(len(intents), 2)
            self.assertEqual(len({x["idempotency_key"] for x in intents}), 2)
            self.assertEqual(sorted(x["state"] for x in intents), ["accepted", "rejected"])
        finally:
            for process in processes:
                if process.poll() is None:
                    check = subprocess.run(["ps", "-p", str(process.pid), "-o", "args="], capture_output=True, text=True)
                    if str(ADAPTER) in check.stdout and "append job-a" in check.stdout:
                        process.terminate()
                        process.wait(timeout=10)


class CrashTests(Harness):
    def test_crashes_before_send_after_commit_and_after_accepted_fsync(self):
        child = '''import importlib.util,os,sys
spec=importlib.util.spec_from_file_location("crash_adapter",sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
c=m.Client()
if sys.argv[2]=="before_send": c.call=lambda *a,**k:os._exit(99)
request=m.strict_json(sys.stdin.buffer.read(),"invalid_request")
try: c.append("job-a",request)
except m.Refusal: os._exit(99)
os._exit(99)
'''
        for phase in ("before_send", "after_commit", "after_accepted_fsync"):
            with self.subTest(phase=phase):
                self.env["ARBITER_INBOX_ROOT"] = str(self.root / phase)
                first = {"action": "commit_lost" if phase == "after_commit" else "accept"}
                self.seed(first, {"action": "read" if phase == "after_accepted_fsync" else "accept"})
                crash = subprocess.run([sys.executable, "-c", child, str(ADAPTER), phase], env=self.env,
                                       input=json.dumps(self.round_request()), capture_output=True, text=True, timeout=30)
                self.assertEqual(crash.returncode, 99, crash.stderr)
                item = json.loads(self.intent_file().read_text())["intents"][0]
                self.assertEqual(item["state"], "accepted" if phase == "after_accepted_fsync" else "pending")
                replay = self.run_adapter("append", "job-a", "--resume", item["local_id"])
                self.assertEqual(replay.returncode, 0, replay.stderr)
                calls = self.calls()
                if phase != "before_send":
                    self.assertFalse(json.loads(replay.stdout)["created"])
                self.assertEqual(len(json.loads(self.script.read_text())["journal"]), 3)
                self.assertEqual(sum(x["argv"][1] == "append" for x in calls), 1 if phase != "after_commit" else 2)


class ReadTests(Harness):
    def test_pagination_is_fixed_snapshot_and_cache_is_not_authority(self):
        records = self.seed({"action": "read"}, {"action": "read"})
        with self.client() as client:
            result = client.records("job-a", limit=1)
        self.assertEqual(result["records"], records)
        self.assertEqual(self.calls()[0]["argv"], ["wrk", "records", "job-a", "--limit", "1"])
        self.assertEqual(self.calls()[1]["argv"], ["wrk", "records", "job-a", "--after-seq", "1", "--limit", "1", "--snapshot-seq", "2"])
        cache = self.intent_file().with_name("o3-snapshot.json")
        self.assertTrue(cache.is_file(), "a complete validated read must durably retain its offline snapshot")
        value = json.loads(cache.read_text())
        self.assertTrue(value["receipt_required"])
        self.assertEqual(value["snapshot_seq"], 2)
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)

    def test_records_with_bad_hash_or_sequence_never_return_partial_history(self):
        for variant in ("hash", "gap", "generation", "snapshot"):
            with self.subTest(variant=variant), self.client() as client:
                records = self.seed()
                summary = dict(job_id="job-a", claim_seq=1, snapshot_seq=2, state="active",
                               baseline_used=0, used=0, cap=3, next_round_no=1, open_rounds=[],
                               last_verdict_seq=None, active_grants=[], warnings=[], store_generation=GEN,
                               tail_hash=records[-1]["record_hash"])
                first = dict(contract="hk1873.v1", snapshot_seq=2, next_after_seq=1, has_more=True,
                             records=records[:1], summary=summary)
                second = dict(contract="hk1873.v1", snapshot_seq=2, next_after_seq=2, has_more=False,
                              records=records[1:], summary=summary)
                if variant == "hash":
                    second["records"][0]["record_hash"] = "f" * 64
                elif variant == "gap":
                    second["records"][0]["seq"] = 3
                elif variant == "generation":
                    second["records"][0]["store_generation"] = "00000000-0000-4000-8000-ffff00000002"
                else:
                    second["snapshot_seq"] = 3
                self.responses(self.success(first), self.success(second))
                with self.assertRaises(self.module.Refusal) as error:
                    client.records("job-a", limit=1)
                self.assertIn(error.exception.code, ("protocol_invalid", "history_regressed"))

    def test_every_later_page_revalidates_the_binary(self):
        self.seed({"action": "read"}, {"action": "read"})
        with self.client() as client:
            resolve = client.resolver.resolve
            def guarded(*args, **kwargs):
                # Storage guards may run too; replace the binary only after
                # the first real cursor page, never by counting all guards.
                if len(self.calls()) == 1:
                    raise self.module.Refusal("cli_usage")
                return resolve(*args, **kwargs)

            with mock.patch.object(client.resolver, "resolve", side_effect=guarded):
                with self.assertRaises(self.module.Refusal) as error:
                    client.records("job-a", limit=1)
                self.assertEqual(error.exception.exit, 2)
            self.assertEqual(len(self.calls()), 1, "later pages may not reuse a previously accepted binary")

    def test_review_assignment_receipt_requirement_survives_shadow_and_end(self):
        with self.client():
            claim = dict(kind="claim", payload=dict(role="tester", review_of={"job_id": "target", "round_no": 1}))
            self.assertTrue(self.module.receipt_required([claim, dict(kind="end")]))
            self.assertFalse(self.module.receipt_required([dict(kind="claim", payload=dict(role="worker", review_of=None))]))


class ProjectionTests(Harness):
    def test_accepted_intent_survives_projection_failure_and_repairs_by_get(self):
        records = self.seed({"action": "accept"}, {"action": "read"})
        with self.client() as client:
            request = self.round_request(len(records))
            accepted = client.append("job-a", request)
            with mock.patch.object(client, "event", side_effect=OSError("fixture")):
                with self.assertRaises(self.module.ProjectionPending):
                    client.project(accepted, "enforced")
            self.assertEqual(self.events(), [])
            local_id = json.loads(self.intent_file().read_text())["intents"][0]["local_id"]
            repaired = client.append("job-a", resume=local_id)
            client.project(repaired, "enforced")
            client.project(repaired, "enforced")
            events = self.events()
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["kind"], "job.round")
            self.assertEqual(events[0]["round"], 1)
            self.assertEqual(events[0]["provenance"], "server_repair")
            self.assertEqual(events[0]["wrk_receipt"]["seq"], 3)
            self.assertEqual([c["argv"][1] for c in self.calls()], ["append", "records"])


class RoundCommandTests(Harness):
    def open_round(self):
        self.mode("required")
        self.seed({"action": "read"}, {"action": "read"}, {"action": "accept"})
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        result = self.run_wrk("round", "open", "job-a", "--head", head, "--repo", str(ROOT), "--tester", "job-a-t1")
        self.assertEqual(result.returncode, 0, result.stderr)
        return head

    def test_real_round_open_verdict_and_void_transport(self):
        head = self.open_round()
        verdict = self.root / "review.md"
        verdict.write_text("VERDICT: PASS @" + head + "\nreviewed\n")
        self.more_responses({"action": "read"}, {"action": "read"}, {"action": "accept"})
        result = self.run_wrk("round", "verdict", "job-a", "--file", str(verdict))
        self.assertEqual(result.returncode, 0, result.stderr)
        append = [x for x in self.calls() if x["argv"][1] == "append"][-1]
        self.assertEqual(json.loads(append["stdin"])["tester_job_id"], "job-a-t1")
        event = self.events()[-1]
        self.assertEqual(event["kind"], "job.verdict")
        self.assertEqual(event["content_sha256"], hashlib.sha256(verdict.read_bytes()).hexdigest())
        self.assertEqual(event["o3_mode"], "enforced")

    def test_real_typed_void_projects_only_after_acceptance(self):
        self.open_round()
        with self.client():
            data = json.loads(self.script.read_text())
            P1ReconciliationTests.grant(self, data["journal"], "void", 1)
            self.script.write_text(json.dumps(data))
        self.more_responses({"action": "read"}, {"action": "read"}, {"action": "accept"})
        result = self.run_wrk("round", "void", "job-a", "1", "--grant", "4")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(self.calls()[-1]["stdin"])
        self.assertEqual(payload, dict(round_no=1, grant_seq=4, reason_code="builder_void"))
        self.assertEqual(self.events()[-1]["kind"], "job.round_void")
        self.assertIsNotNone(self.events()[-1]["wrk_receipt"])

    def test_stable_refusal_cannot_publish_a_verdict(self):
        head = self.open_round()
        verdict = self.root / "review.md"
        verdict.write_text("VERDICT: PASS @" + head + "\nreviewed\n")
        for code, rc in (("unauthorized", 77), ("scope_denied", 77), ("sequence_conflict", 73),
                         ("wrk_unavailable", 75), ("protocol_invalid", 75)):
            with self.subTest(code=code):
                self.more_responses({"action": "read"}, {"action": "read"}, dict(exit=rc, stderr=f"handoffkeep wrk: {code}\n"))
                result = self.run_wrk("round", "verdict", "job-a", "--file", str(verdict))
                self.assertEqual(result.returncode, rc, result.stderr)
                self.assertFalse(any(e["kind"] == "job.verdict" for e in self.events()))

    def test_offline_status_is_explicitly_stale_and_unverified(self):
        self.open_round()
        self.more_responses(dict(exit=75, stderr="handoffkeep wrk: transport_unavailable\n"))
        result = self.run_wrk("round", "status", "job-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("stale=true", result.stdout)
        self.assertIn("label=O2-unverified", result.stdout)
        self.assertEqual(sum(e["kind"] == "job.o3_warning" for e in self.events()), 1)

    def test_unknown_mode_fails_before_cli_and_env_cannot_select_mode(self):
        self.mode("invalid")
        self.responses()
        self.env["WRK_O3_MODE"] = "legacy"
        result = self.run_wrk("round", "status", "job-a")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_free_ref_refused_for_enrolled_job(self):
        self.mode("required")
        self.seed({"action": "read"}, {"action": "read"})
        result = self.run_wrk("round", "open", "job-a", "--head", "1" * 40, "--extend", "hk:doc/free")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(any(x["argv"][1] == "append" for x in self.calls()))

    def test_shadow_reviewer_cannot_take_the_p1_warning_branch(self):
        self.mode("shadow")
        records = self.seed({"action": "read"}, {"action": "read"},
                            dict(exit=75, stderr="handoffkeep wrk: wrk_unavailable\n"))
        claim = records[0]
        claim["payload"].update(role="tester", review_of=dict(job_id="subject-a", round_no=1))
        with self.client() as client:
            claim["record_hash"] = self.module.digest({k: v for k, v in claim.items() if k != "record_hash"})
            data = json.loads(self.script.read_text())
            data["journal"] = [claim]
            self.script.write_text(json.dumps(data))
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            with self.assertRaises(self.module.Refusal) as error:
                self.module.round_cli(client, ["open", "job-a", "--head", head, "--repo", str(ROOT)], "shadow")
            self.assertEqual(error.exception.exit, 75)
            self.assertEqual(self.events(), [], "receipt-required reviewer never publishes an O2 warning success")


class TypedAdapterTests(Harness):
    def typed_submission(self, kind):
        self.seed({"action": "read"}, {"action": "read"}, {"action": "accept"})
        report = self.root / (kind + ".md")
        report.write_bytes(b"exact report\r\n")
        args = ["o3", kind, "job-a", "--file", str(report)]
        if kind == "joined":
            args += ["--head", "1" * 40, "--pr", "https://example.test/pr/1", "--waiver-grant", "7"]
        result = self.run_wrk(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(self.calls()[-1]["stdin"])
        self.assertEqual(base64.b64decode(payload["report_b64"]), report.read_bytes())
        if kind == "joined":
            self.assertEqual(payload["waiver_grant_seq"], 7)
        self.assertEqual(self.events(), [], "done_cmd/joined_cmd wiring is C2")

    def test_completed_is_adapter_only(self):
        self.typed_submission("completed")

    def test_joined_is_adapter_only(self):
        self.typed_submission("joined")

    def test_joined_rejects_a_free_waiver_ref(self):
        report = self.root / "join-report.md"
        report.write_text("review joined\n")
        self.seed({"action": "read"}, {"action": "read"}, {"action": "accept"})
        result = self.run_wrk("o3", "joined", "job-a", "--file", str(report),
                              "--head", "1" * 40, "--pr", "https://github.com/fixture/repo/pull/1",
                              "--waiver-grant", "hk:doc/free")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_central_wrapper_fixed_path_and_secure_permissions(self):
        wrapper = self.hk.with_name("hk-director-1")
        shutil.copyfile(self.hk, wrapper)
        wrapper.chmod(0o700)
        self.seed({"action": "accept"})
        with self.client() as client:
            central = self.module.Client(central="director-1")
            request = dict(kind="activate", claim_seq=1, expected_seq=2,
                           payload=dict(seal_seq=None, reason_code="fresh_job"))
            result = central.append("job-a", request)
            self.assertEqual(result["record"]["kind"], "activate")
            wrapper.chmod(0o722)
            with self.assertRaises(self.module.Refusal) as error:
                central.capabilities()
            self.assertEqual(error.exception.exit, 2)


class CentralToolingTests(Harness):
    def wrapper(self):
        wrapper = self.hk.with_name("hk-director-1")
        shutil.copyfile(self.hk, wrapper); wrapper.chmod(0o700)

    def claim(self, job="job-new", role="builder"):
        return dict(job_id=job, owner_lane="b-design", parent_lane="b-design" if role == "tester" else "director-1",
                    task_id=901, host_client_id="desktop", role=role, tier="T3",
                    review_of=dict(job_id="subject", round_no=1) if role == "tester" else None,
                    predecessor_job_id=None, supersedes=None)

    def test_claim_and_assignment_only_use_fixed_central_wrapper(self):
        self.wrapper()
        for command, role in (("claim", "builder"), ("assign", "tester")):
            with self.subTest(command=command):
                job = "job-" + command
                self.responses({"action": "accept"})
                result = self.run_wrk("o3", "central", command, job, "--role", "director-1",
                                      "--expected-seq", "0", "--claim-seq", "0", stdin=json.dumps(self.claim(job, role)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls()[0]["argv"][:3], ["wrk", "append", job])
                self.assertEqual(self.events(job), [])

    def test_import_begin_and_exact_archived_bytes(self):
        self.wrapper()
        self.seed({"action": "accept"}, {"action": "accept"})
        result = self.run_wrk("o3", "central", "import-begin", "job-a", "--role", "director-1",
                              "--expected-seq", "2", "--claim-seq", "1", stdin='{"reason_code":"desk_import"}')
        self.assertEqual(result.returncode, 0, result.stderr)
        event = self.root / "archived-event.json"
        event.write_bytes(b'{"kind":"job.round","round":1}\r\n')
        result = self.run_wrk("o3", "central", "import", "job-a", "--role", "director-1",
                              "--expected-seq", "3", "--claim-seq", "1", "--file", str(event),
                              "--source-locator", "archive/job-a/00003-job.round.json", "--legacy-kind", "job.round")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(self.calls()[-1]["stdin"])
        self.assertEqual(base64.b64decode(payload["content_b64"]), event.read_bytes())
        self.assertEqual(payload["source_sha256"], hashlib.sha256(event.read_bytes()).hexdigest())
        self.assertEqual(self.events(), [])

    def test_import_seal_hashes_the_exact_ordered_server_manifest(self):
        with self.client():
            records = [dict(seq=3, kind="import_begin", payload={}),
                       dict(seq=4, kind="import", payload=dict(source_locator="a", source_sha256="a" * 64)),
                       dict(seq=5, kind="import", payload=dict(source_locator="b", source_sha256="b" * 64))]
            client = mock.Mock()
            client.retry_pending.return_value = None
            client.records.return_value = dict(snapshot_seq=5, records=records)
            client.append.return_value = {"receipt": "synthetic"}
            with mock.patch.object(self.module, "Client", return_value=client):
                self.module.central_cli(["import-seal", "job-a", "--role", "director-1", "--expected-seq", "5",
                                         "--claim-seq", "1", "--begin-seq", "3"])
            sent = client.append.call_args.args[1]
            manifest = [dict(seq=r["seq"], **r["payload"]) for r in records[1:]]
            self.assertEqual(sent["payload"]["manifest_sha256"], self.module.digest(manifest))
            self.assertEqual(sent["payload"]["expected_import_count"], 2)
            self.assertEqual(sent["payload"]["begin_seq"], 3)
            self.assertEqual(sent["expected_seq"], 5)


class MatrixModeTests(Harness):
    def commands(self):
        head = "a" * 40
        report = self.root / "report.md"
        report.write_text("VERDICT: PASS @" + head + "\nfixture report\n")
        return [(["round", "open", "job-a", "--head", head, "--repo", str(ROOT)], False),
                (["round", "verdict", "job-a", "--file", str(report)], False),
                (["round", "void", "job-a", "1", "--grant", "4"], False),
                (["round", "status", "job-a"], False),
                (["o3", "completed", "job-a", "--file", str(report)], False),
                (["o3", "joined", "job-a", "--file", str(report), "--head", head, "--pr", "https://example.test/pr/1"], False),
                (SpawnHandshakeTests.spawn_environment(self), True)]

    def check_refusal_matrix(self, code, rc):
        self.mode("required")
        old = self.intent_file().parent / "events/00001-job.claim.json"
        old.parent.mkdir(parents=True, exist_ok=True)
        old.write_text(json.dumps(dict(kind="job.claim", job_id="job-a", role="builder", owner_lane="b-design", task_id=901)))
        for index, (args, spawn) in enumerate(self.commands()):
            with self.subTest(command=args[:2]):
                response = dict(exit=rc, stderr="handoffkeep wrk: " + code + "\n")
                self.responses(*([{"action": "read"}] if spawn else []), response)
                result = self.run_wrk(*args)
                # Director P1 clarification: an unavailable first classification
                # permits O2 as a veto only; these fixtures have no local open.
                expected = 2 if code == "transport_unavailable" and args[:2] in (["round", "verdict"], ["round", "void"]) else rc
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(len(self.events()), 1, "unreceipted O2 claim must not create accepted transitions")
                self.assertFalse(any(x["argv"][1] == "append" for x in self.calls()))
                self.assertFalse(self.intent_file().exists(), "no complete canonical binding means no invented Request")

    def test_local_o2_files_do_not_prove_enrollment(self):
        self.check_refusal_matrix("not_found", 66)

    def test_old_namespace_fails_closed_for_every_command(self):
        self.check_refusal_matrix("o3_unsupported", 75)

    def test_first_get_outage_creates_no_invented_intent(self):
        self.check_refusal_matrix("transport_unavailable", 75)


class SpawnHandshakeTests(Harness):
    def spawn_environment(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        subprocess.run(["git", "init", "-q", str(workspace)], env=self.env, check=True)
        brief = self.root / "brief.md"
        brief.write_text("fixture review")
        self.env.update(HERDR_BIN=str(ROOT / "tests/fixtures/herdr"),
                        SCOPEFUEL_BIN=str(ROOT / "tests/fixtures/scopefuel"),
                        ARBITER_BIN=str(ROOT / "bin/arbiter"), WRK_JOB_DELEGATE="0",
                        PANEWIRE_BIN=str(ROOT / "tests/fixtures/panewire"),
                        WRK_HOSTS_CONFIG=str(self.root / "no-hosts.toml"), WRK_NO_SLEEP="1",
                        WRK_COMPLETION_INTERVAL_S="3600", WRK_REFRESH_TIMEOUT_S="5",
                        WRK_REFRESH_PID_LOG=str(self.root / "refresh.pids"),
                        WRK_FIXTURE_LOG=str(self.root / "herdr.log"))
        return ["spawn", "--host", "local", "-c", str(workspace), "-m", "builder-sol",
                "--effort", "high", "-p", str(brief), "-w", "fixture", "-l", "job-a", "--t", "T2",
                "--role", "builder", "--lane", "b2400-a", "--parent", "director-1", "--task", "2400",
                "--report", str(self.root / "report.md")]

    def test_real_o3_spawn_never_calls_legacy_hk_bin(self):
        self.mode("required")
        self.seed(*({"action": "read"} for _ in range(3)))
        result = self.run_wrk(*self.spawn_environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tab create", (self.root / "herdr.log").read_text())
        self.assertEqual([x["argv"][1] for x in self.calls()], ["capabilities", "job", "records"])
        self.assertTrue(any(e["kind"] == "job.claim" for e in self.events()))

    def test_real_legacy_spawn_keeps_task_probe_and_link(self):
        args = self.spawn_environment()
        log = self.root / "legacy-calls.jsonl"
        fixture = ROOT / "tests/fixtures/handoffkeep"
        self.hk.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                           f"with open({str(log)!r},'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                           f"os.execv({str(fixture)!r},[{str(fixture)!r},*sys.argv[1:]])\n")
        self.env["HK_STATE"] = str(self.root / "legacy-state.json")
        subprocess.run([str(self.hk), "tasks", "add", "--id", "2400", "--title", "fixture", "--lane", "fixture"],
                       env=self.env, capture_output=True, check=True)
        result = self.run_wrk(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertTrue(any(c[:3] == ["tasks", "show", "2400"] for c in calls))
        self.assertTrue(any(c[:3] == ["tasks", "claim", "2400"] for c in calls))

    def test_subject_only_verifies_central_claim_and_activation(self):
        self.seed(*({"action": "read"} for _ in range(3)))
        with self.client() as client:
            admitted = client.spawn_check("job-a", "builder", "T2", task=2400,
                                          owner="b2400-a", parent="director-1")
        self.assertEqual(admitted["task_id"], 2400)
        self.assertTrue(admitted["receipt_required"])
        self.assertEqual([x["argv"][1] for x in self.calls()], ["capabilities", "job", "records"])
        self.assertEqual(self.events(), [])

    def test_reviewer_claim_verify_open_order_and_new_job_intents(self):
        self.seed(*({"action": "accept"} for _ in range(8)))
        with self.client() as client:
            admitted = client.spawn_check("job-review", "tester", "T2", subject="job-a", head="1" * 40)
        calls = self.calls()
        self.assertEqual([x["argv"][1] for x in calls], ["job", "records", "capabilities", "job", "append", "job", "records", "append"])
        self.assertEqual([x["argv"][2] for x in calls if x["argv"][1] == "append"], ["job-review", "job-a"])
        self.assertTrue(admitted["receipt_required"])
        claim_intent = json.loads(self.intent_file("job-review").read_text())["intents"][0]
        self.assertEqual(claim_intent["request"]["payload"]["parent_lane"], "b2400-a")
        self.assertEqual(claim_intent["request"]["payload"]["owner_lane"], "b2400-a")
        self.assertEqual(claim_intent["state"], "accepted")
        self.assertEqual(self.events()[0]["kind"], "job.round")

    def test_p1_missing_central_assignment_is_claim_conflict_without_mint(self):
        records = self.seed(*({"action": "read"} for _ in range(4)))
        data = json.loads(self.script.read_text())
        data["journal"] = records[:1]  # explicit shadow subject
        self.script.write_text(json.dumps(data))
        with self.client() as client:
            with self.assertRaises(self.module.Refusal) as error:
                client.spawn_check("job-review", "tester", "T2", subject="job-a", head="1" * 40, mode="shadow")
            self.assertEqual(error.exception.code, "claim_conflict")
        self.assertFalse(any(x["argv"][1] == "append" for x in self.calls()))

    def test_failure_after_review_claim_leaves_claim_visible_and_no_local_claim(self):
        self.seed(*({"action": "accept"} for _ in range(5)),
                  {"exit": 75, "stderr": "handoffkeep wrk: wrk_unavailable\n"})
        self.mode("required")
        workspace = self.root / "workspace"
        workspace.mkdir()
        subprocess.run(["git", "init", "-q", str(workspace)], env=self.env, check=True)
        subprocess.run(["git", "-C", str(workspace), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                        "commit", "--allow-empty", "-qm", "fixture"], env=self.env, check=True)
        head = subprocess.check_output(["git", "-C", str(workspace), "rev-parse", "HEAD"], env=self.env, text=True).strip()
        brief = self.root / "brief.md"
        brief.write_text("fixture review")
        self.env.update(HERDR_BIN=str(ROOT / "tests/fixtures/herdr"),
                        SCOPEFUEL_BIN=str(ROOT / "tests/fixtures/scopefuel"),
                        ARBITER_BIN=str(ROOT / "bin/arbiter"),
                        PANEWIRE_BIN=str(ROOT / "tests/fixtures/panewire"),
                        WRK_HOSTS_CONFIG=str(self.root / "no-hosts.toml"), WRK_NO_SLEEP="1",
                        WRK_FIXTURE_LOG=str(self.root / "herdr.log"))
        result = self.run_wrk("spawn", "--host", "local", "-c", str(workspace), "-m", "opus",
                              "-p", str(brief), "-w", "fixture", "-l", "job-review", "--t", "T2",
                              "--role", "tester", "--parent-job", "job-a", "--head", head)
        self.assertEqual(result.returncode, 75, result.stderr)
        data = json.loads(self.script.read_text())
        self.assertEqual(data["journals"]["job-review"][0]["kind"], "claim")
        self.assertFalse(any(e["kind"] in ("job.claim", "job.spawned") for e in self.events("job-review")))
        log = self.root / "herdr.log"
        self.assertFalse(log.exists() and "tab create" in log.read_text())
        self.assertTrue(all(x["argv"][0] == "wrk" for x in self.calls()), "no hk_bin legacy task call in O3 spawn")


class PackClientVectorTests(Harness):
    def test_pack_raw_policy_and_legacy_boundaries(self):
        counts = dict(http_raw=0, policy=0, legacy=0, none=0)
        with self.client() as client:
            for path in sorted((PACK / "vectors").glob("*.json")):
                for case in json.loads(path.read_text())["cases"]:
                    wire = case["request"]
                    kind = wire.get("type")
                    if kind not in counts:
                        continue
                    counts[kind] += 1
                    with self.subTest(file=path.name, case=case["name"]):
                        if kind == "policy":
                            self.assertEqual(client.schema.matches(client.schema.bundle["$defs"]["Policy"], wire["document"]), case["expect"]["policy_valid"])
                        elif kind == "http_raw":
                            self.responses()
                            with self.assertRaises(self.module.Refusal) as error:
                                client.append(wire["path"].split("/")[4], wire["body"])
                            self.assertEqual(error.exception.code, case["expect"]["error"])
                            self.assertEqual(self.calls(), [])
                        elif kind == "legacy":
                            self.responses()
                            with self.assertRaises(self.module.Refusal) as error:
                                client.call(["legacy", wire["method"], wire["path"]], "WriteResponse", wire.get("body"))
                            self.assertEqual(error.exception.exit, 2)
                            self.assertEqual(self.calls(), [], "C1 cannot express C2 legacy task/relay mutations")
                        else:
                            self.responses()
                            with self.assertRaises(self.module.Refusal) as error:
                                self.module.main(["activate", "job-a", "--o3-central"])
                            self.assertEqual(error.exception.exit, 2)
                            self.assertEqual(self.calls(), [], "desk P2 rollout is outside the host API")
        self.assertEqual(counts, dict(http_raw=3, policy=4, legacy=18, none=1))

    def test_pack_get_vectors_use_fixed_cursors_and_attribution(self):
        exercised = 0
        for path in (PACK / "vectors").glob("*.json"):
            for case in json.loads(path.read_text())["cases"]:
                wire = case["request"]
                if wire.get("type") != "http" or wire.get("method") != "GET":
                    continue
                self.env["ARBITER_INBOX_ROOT"] = str(self.root / ("get-case-" + str(exercised)))
                with self.subTest(case=case["name"]), self.client() as client:
                    exercised += 1
                    if wire["path"].endswith("capabilities"):
                        value = self.capabilities()
                        value.update(case["expect"]["capabilities"])
                        self.responses(self.success(value))
                        self.assertEqual(client.capabilities()["client_id"], "at-integrator")
                    else:
                        given = case["given"]["records"]
                        query = wire["query"]
                        # Drive the adapter over the complete supplied snapshot;
                        # the requested row must occur at its exact cursor.
                        self.script.write_text(json.dumps(dict(journal=given, responses=[{"action": "read"}] * len(given), calls=[],
                                                               initial_snapshot=query["snapshot_seq"])))
                        result = client.records(given[0]["job_id"], limit=1)
                        expected = case["expect"]["records_response"]
                        self.assertEqual(result["snapshot_seq"], expected["snapshot_seq"])
                        pages = [c["argv"] for c in self.calls()]
                        position = query["after_seq"]
                        self.assertEqual(pages[position][pages[position].index("--after-seq") + 1] if "--after-seq" in pages[position] else "0", str(position))
                        self.assertEqual(result["records"][position]["seq"], expected["record_seqs"][0])
        self.assertEqual(exercised, 3)

    def test_meta_error_map_and_request_digest_contract(self):
        with self.client() as client:
            vectors = json.loads((PACK / "vectors/section4-rules.json").read_text())["cases"]
            for case in vectors:
                if "error" in case["expect"]:
                    code = case["expect"]["error"]
                    self.assertIn(code, self.module.EXIT_CODES)
                    self.responses(dict(exit=self.module.EXIT_CODES[code], stderr="handoffkeep wrk: " + code + "\n"))
                    with self.assertRaises(self.module.Refusal) as error:
                        client.capabilities()
                    self.assertEqual(error.exception.code, code)
            request = self.round_request()
            original = self.module.request_digest("job-a", request)
            self.assertEqual(original, self.module.digest(dict(method="POST", path="/v1/wrk/jobs/job-a/records", body=request)))
            request["expected_seq"] += 1
            self.assertNotEqual(original, self.module.request_digest("job-a", request))
            with self.assertRaises(self.module.Refusal):
                self.module.strict_json('{"kind":"claim","kind":"round_open"}', "invalid_request")
            with self.assertRaises(self.module.Refusal):
                client.schema.check("Request", dict(kind="unknown"), "invalid_request")

    def test_server_semantic_order_is_not_preempted(self):
        selected = {("failure-abuse.json", "replay-old-verdict-fresh-key-same-path"): "duplicate_path",
                    ("transition.json", "same-bytes-fresh-path-duplicate-content"): "duplicate_content",
                    ("r4-review-lifecycle.json", "r-import-scope-denied"): "scope_denied"}
        with self.client() as client:
            for index, ((filename, name), code) in enumerate(selected.items()):
                with self.subTest(case=name):
                    case = next(c for c in json.loads((PACK / "vectors" / filename).read_text())["cases"] if c["name"] == name)
                    request = case["request"]
                    self.env["ARBITER_INBOX_ROOT"] = str(self.root / ("ordered-%d" % index))
                    with mock.patch.dict(os.environ, self.env, clear=True):
                        self.responses(dict(exit=self.module.EXIT_CODES[code], stderr="handoffkeep wrk: " + code + "\n"))
                        with self.assertRaises(self.module.Refusal) as error:
                            client.append(request["path"].split("/")[4], request["body"])
                        self.assertEqual(error.exception.code, code)
                        self.assertEqual(len(self.calls()), 1, "server-ordered semantic checks must reach the CLI")
                        self.assertEqual(json.loads(self.calls()[0]["stdin"]), request["body"]["payload"])

    def test_every_journal_append_vector_observed_through_adapter(self):
        exercised = 0
        for path in sorted((PACK / "vectors").glob("*.json")):
            for case in json.loads(path.read_text())["cases"]:
                wire = case["request"]
                if wire.get("type") != "http" or wire.get("method") != "POST":
                    continue  # legacy fences/policy are S1/C2, CLI vectors have directed tests below
                with self.subTest(file=path.name, case=case["name"]):
                    exercised += 1
                    self.env["ARBITER_INBOX_ROOT"] = str(self.root / ("case-%d" % exercised))
                    with self.client() as client:
                        if (path.name, case["name"]) in pack_divergence:
                            seal = next(r for r in case["given"]["records"] if r["kind"] == "import_seal"
                                        and r["payload"]["numbering_floor"] < r["payload"]["baseline_used"])
                            with self.assertRaises(self.module.Refusal) as error:
                                client.check_record(seal, seal["job_id"])
                            self.assertEqual(error.exception.code, pack_divergence[(path.name, case["name"])])
                            continue
                        expect = case["expect"]
                        job = wire["path"].split("/")[4]
                        if "error" in expect:
                            code = expect["error"]
                            self.responses(dict(exit=self.module.EXIT_CODES[code], stderr="handoffkeep wrk: " + code + "\n"))
                            with self.assertRaises(self.module.Refusal) as error:
                                client.append(job, wire["body"])
                            self.assertEqual(error.exception.code, code)
                        else:
                            self.script.write_text(json.dumps(dict(responses=[{"action": "vector"}], calls=[],
                                                                   journal=case["given"].get("records", []), vector_expect=expect)))
                            result = client.append(job, wire["body"])
                            self.assertEqual(result["created"], expect.get("created", True))
                            if "record" in expect:
                                self.assertEqual(result["record"]["kind"], expect["record"]["kind"])
                                for key, value in expect["record"].get("payload", {}).items():
                                    self.assertEqual(result["record"]["payload"][key], value)
                        self.assertEqual(self.events(job), [], "adapter vector alone cannot publish local authority")
        self.assertEqual(exercised, 102)


class DesignObservationTests(Harness):
    """Independent design-derived client cases, director-1 rules 1-12.

    S1 proves business policy. These cases prove C1 sends the exact inputs,
    observes the server's prescribed result and never projects a refusal.
    Histories and evidence here are constructed without reading M1 vectors.
    """
    def record(self, kind, payload, records):
        result = dict(job_id="job-a", seq=len(records) + 1, record_id=str(uuid.uuid4()),
                      store_generation=GEN, claim_seq=1, actor_client_id="desktop", kind=kind,
                      idempotency_key=str(uuid.uuid4()), request_sha256="b" * 64,
                      imported=kind == "import", source=None, payload=payload,
                      received_at="2026-10-26T00:00:00.000001Z",
                      previous_hash=records[-1]["record_hash"] if records else "0" * 64)
        result["record_hash"] = self.module.digest(result)
        records.append(result)
        return result

    def own_history(self, imported=False):
        records = []
        claim = dict(job_id="job-a", owner_lane="b-design", parent_lane="director-1", task_id=901,
                     host_client_id="desktop", role="builder", tier="T3", review_of=None,
                     predecessor_job_id=None, supersedes=None, policy_sha256="a" * 64,
                     created_at="2026-10-26T00:00:00.000001Z")
        self.record("claim", claim, records)
        if imported:
            self.record("import_begin", dict(reason_code="desk_import", shadow_cutoff_seq=1), records)
            self.record("import_seal", dict(begin_seq=2, expected_import_count=0,
                                            manifest_sha256=self.module.digest([]), reason_code="desk_import",
                                            shadow_cutoff_seq=1, baseline_used=3, numbering_floor=3), records)
        self.record("activate", dict(mode="enforced", baseline_used=3 if imported else 0,
                                     seal_seq=3 if imported else None, reason_code="activate"), records)
        return records

    def script_history(self, records, responses):
        self.script.write_text(json.dumps(dict(journal=records, responses=responses, calls=[])))

    def verdict_request(self, expected=8, tester="review-a"):
        raw = b"VERDICT: PASS @" + b"a" * 40 + b"\ndesign-derived review\n"
        return dict(kind="verdict", claim_seq=1, expected_seq=expected,
                    payload=dict(round_no=3, head="a" * 40, verdict="PASS", path="/synthetic/review.md",
                                 content_b64=base64.b64encode(raw).decode(),
                                 content_sha256=hashlib.sha256(raw).hexdigest(), tester_job_id=tester))

    def joined_request(self, expected):
        raw = b"design-derived final report\n"
        return dict(kind="joined", claim_seq=1, expected_seq=expected,
                    payload=dict(head="a" * 40, pr="https://example.test/pr/901", waiver_grant_seq=None,
                                 report_b64=base64.b64encode(raw).decode(), report_sha256=hashlib.sha256(raw).hexdigest()))

    def deny(self, client, request, code, job="job-a"):
        self.responses(dict(exit=self.module.EXIT_CODES[code], stderr="handoffkeep wrk: " + code + "\n"))
        with self.assertRaises(self.module.Refusal) as error:
            client.append(job, request)
        self.assertEqual(error.exception.code, code)
        self.assertEqual(json.loads(self.calls()[0]["stdin"]), request["payload"])
        self.assertEqual(self.events(job), [])
        self.assertEqual(json.loads(self.intent_file(job).read_text())["intents"][-1]["state"], "rejected")

    def test_rule_01_duplicate_path_survives_a_void(self):
        with self.client() as client:
            records = self.own_history()
            self.record("round_open", dict(round_no=1, head="a" * 40, tester_job_id="review-a", extension_grant_seq=None, repeat_grant_seq=None), records)
            p = self.verdict_request()["payload"].copy()
            p.pop("content_b64"); p.update(round_no=1, size_bytes=78)
            self.record("verdict", p, records)
            self.record("round_open", dict(round_no=2, head="b" * 40, tester_job_id="review-b", extension_grant_seq=None, repeat_grant_seq=None), records)
            self.record("void", dict(round_no=2, grant_seq=5, reason_code="cancelled"), records)
            self.deny(client, self.verdict_request(expected=len(records)), "duplicate_path")

    def test_rule_02_accepted_pass_survives_reviewer_end_at_join(self):
        with self.client() as client:
            records = self.own_history()
            self.record("round_open", dict(round_no=1, head="a" * 40, tester_job_id="review-a", extension_grant_seq=None, repeat_grant_seq=None), records)
            p = self.verdict_request()["payload"].copy()
            p.pop("content_b64"); p.update(round_no=1, size_bytes=78)
            self.record("verdict", p, records)
            request = self.joined_request(len(records))
            self.script.write_text(json.dumps(dict(journal=records, responses=[{"action": "vector"}], calls=[],
                                                   vector_expect={"created": True, "record": {"payload": {"verdict_seqs": [4]}}},
                                                   ended_reviewers=["review-a"])))
            result = client.append("job-a", request)
            self.assertEqual(result["record"]["payload"]["verdict_seqs"], [4])
            self.assertEqual([x["argv"][1] for x in self.calls()], ["append"], "no current reviewer-liveness veto at join")

    def test_rule_03_scoped_mint_reuse_and_self_reference(self):
        with self.client() as client:
            self.responses()
            with self.assertRaises(self.module.Refusal) as error:
                client.spawn_check("self-job", "tester", "T3", subject="self-job", head="a" * 40)
            self.assertEqual(error.exception.code, "claim_conflict")
            self.assertEqual(self.calls(), [], "self-reference refuses before target lookup")
            claim = self.own_history()[0]["payload"].copy()
            claim.pop("created_at"); claim.pop("policy_sha256")
            claim.update(role="tester", review_of=dict(job_id="subject", round_no=1), owner_lane="b-design", parent_lane="b-design")
            self.deny(client, dict(kind="claim", expected_seq=1, claim_seq=1, payload=claim), "claim_conflict")

    def test_rule_04_consumed_extension_including_losing_consumer(self):
        with self.client() as client:
            request = self.round_request(expected=9, head="a" * 40)
            request["payload"].update(extension_grant_seq=7, tester_job_id="review-b")
            self.deny(client, request, "grant_consumed")
            request["expected_seq"] = 10
            self.deny(client, request, "grant_consumed")

    def test_rule_05_planted_import_cannot_supply_trusted_rounds(self):
        with self.client() as client:
            history = self.own_history(imported=True)
            self.assertEqual(history[2]["payload"]["numbering_floor"], 3)
            self.deny(client, self.joined_request(len(history)), "zero_rounds")

    def test_rule_06_central_director_joined_is_scope_denied(self):
        wrapper = self.hk.with_name("hk-director-1")
        shutil.copyfile(self.hk, wrapper); wrapper.chmod(0o700)
        with self.client():
            self.deny(self.module.Client(central="director-1"), self.joined_request(4), "scope_denied")

    def test_rule_07_exact_repeat_grant_and_non_grant_pointer(self):
        with self.client() as client:
            request = self.round_request(expected=9, head="a" * 40)
            request["payload"].update(repeat_grant_seq=8, tester_job_id="review-b")
            self.script.write_text(json.dumps(dict(journal=self.own_history(), responses=[{"action": "vector"}], calls=[],
                                                   vector_expect={"record": {"payload": {"round_no": 3}}})))
            accepted = client.append("job-a", request)
            self.assertEqual(accepted["record"]["payload"]["repeat_grant_seq"], 8)
            request["expected_seq"] = 10
            request["payload"]["repeat_grant_seq"] = 1  # claim, not a grant
            self.deny(client, request, "grant_invalid")

    def test_rule_08_mismatched_or_ended_reviewer_verdict_refused(self):
        with self.client() as client:
            self.deny(client, self.verdict_request(tester="other-reviewer"), "round_not_open")
            self.deny(client, self.verdict_request(tester="ended-reviewer"), "round_not_open")

    def test_rule_09_scoped_mint_host_mismatch_and_missing_target(self):
        with self.client() as client:
            payload = self.own_history()[0]["payload"].copy()
            payload.pop("created_at"); payload.pop("policy_sha256")
            payload.update(role="tester", owner_lane="b-design", parent_lane="b-design", review_of=dict(job_id="foreign-subject", round_no=1))
            request = dict(kind="claim", expected_seq=0, claim_seq=0, payload=payload)
            self.deny(client, request, "host_mismatch")
            request["payload"]["review_of"]["job_id"] = "missing-subject"
            self.deny(client, request, "not_found")

    def test_rule_10_import_floor_3_opens_round_4_with_extension(self):
        self.mode("required")
        with self.client() as client:
            records = self.own_history(imported=True)
            P1ReconciliationTests.grant(self, records)
            self.script_history(records, [{"action": "read"}, {"action": "read"}, {"action": "accept"}])
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            self.module.round_cli(client, ["open", "job-a", "--head", head, "--repo", str(ROOT), "--extension-grant", "5"], "required")
            self.assertEqual(self.events()[0]["round"], 4)
            sent = json.loads(self.calls()[-1]["stdin"])
            self.assertEqual(sent["extension_grant_seq"], 5)
            records[2]["payload"]["numbering_floor"] = 1
            records[2]["record_hash"] = self.module.digest({k: v for k, v in records[2].items() if k != "record_hash"})
            with self.assertRaises(self.module.Refusal) as error:
                client.check_record(records[2], "job-a")
            self.assertEqual(error.exception.code, "protocol_invalid")

    def test_rule_11_replay_after_end_precedes_new_cas(self):
        with self.client() as client:
            history = self.own_history()
            self.script_history(history, [{"action": "commit_lost"}, {"action": "accept"}])
            with self.assertRaises(self.module.Refusal):
                client.append("job-a", self.round_request())
            data = json.loads(self.script.read_text())
            self.record("end", dict(end_type="reaped", reason_code="review_finished"), data["journal"])
            self.script.write_text(json.dumps(data))
            pending = json.loads(self.intent_file().read_text())["intents"][0]
            replay = client.append("job-a", resume=pending["local_id"])
            self.assertFalse(replay["created"])
            self.assertEqual(replay["record"]["seq"], 3)
            self.assertEqual(len(json.loads(self.script.read_text())["journal"]), 4)

    def test_rule_12_changed_body_same_key_is_idempotency_conflict(self):
        with self.client() as client:
            self.script_history(self.own_history(), [{"action": "commit_lost"}, {"action": "accept"}, {"action": "accept"}])
            with self.assertRaises(self.module.Refusal):
                client.append("job-a", self.round_request())
            item = json.loads(self.intent_file().read_text())["intents"][0]
            args = self.calls()[0]["argv"][1:]
            changed = self.round_request()["payload"]
            changed["head"] = "b" * 40
            with self.assertRaises(self.module.Refusal) as error:
                client.call(args, "WriteResponse", changed)
            self.assertEqual(error.exception.code, "idempotency_conflict")
            replay = client.append("job-a", resume=item["local_id"])
            self.assertFalse(replay["created"])


class RecoveryEdges(Harness):

    def test_write_reply_binds_the_expected_claim(self):
        self.seed({'action': 'accept'})
        with self.client() as client:
            call = client.call

            def wrong(*a, **k):
                value = call(*a, **k)
                value['record']['claim_seq'] = 7
                value['summary']['claim_seq'] = 7
                value['record']['record_hash'] = self.module.digest({k: v for k, v in value['record'].items() if k != 'record_hash'})
                value['summary']['tail_hash'] = value['record']['record_hash']
                return value
            with mock.patch.object(client, 'call', side_effect=wrong):
                with self.assertRaises(self.module.Refusal) as error:
                    client.append('job-a', self.round_request())
            self.assertEqual(error.exception.code, 'protocol_invalid')

    def test_accepted_repair_validates_the_requested_snapshot(self):
        self.seed({'action': 'accept'}, {'action': 'read'})
        with self.client() as client:
            client.append('job-a', self.round_request())
            item = json.loads(self.intent_file().read_text())['intents'][0]
            call = client.call

            def wrong(*a, **k):
                value = call(*a, **k)
                value['snapshot_seq'] += 1
                return value
            with mock.patch.object(client, 'call', side_effect=wrong):
                with self.assertRaises(self.module.Refusal) as error:
                    client.append('job-a', resume=item['local_id'])
            self.assertEqual(error.exception.code, 'protocol_invalid')

    def check_spawn_replay(self, phase):
        responses = [{'action': 'accept'} for _ in range(5 if phase == 'claim' else 8)]
        responses[-1] = {'action': 'commit_lost'}
        self.seed(*responses)
        with self.client() as client:
            with self.assertRaises(self.module.Refusal):
                client.spawn_check('job-review', 'tester', 'T2', subject='job-a', head='1' * 40)
            data = json.loads(self.script.read_text())
            DesignObservationTests.record(self, 'end', dict(end_type='reaped', reason_code='ended'), data['journal'])
            data['responses'] = [{'action': 'accept'}, {'action': 'read'}, {'action': 'read'}]
            data['calls'] = []
            self.script.write_text(json.dumps(data))
            with self.assertRaises(self.module.Refusal):
                client.spawn_check('job-review', 'tester', 'T2', subject='job-a', head='1' * 40)
            self.assertEqual(self.calls()[0]['argv'][1], 'append', 'unknown outcome must replay before target terminal checks')
            job = 'job-review' if phase == 'claim' else 'job-a'
            self.assertEqual(json.loads(self.intent_file(job).read_text())['intents'][0]['state'], 'accepted')

    def test_review_claim_unknown_replays_before_target_end(self):
        self.check_spawn_replay('claim')

    def test_review_open_unknown_replays_before_target_end(self):
        self.check_spawn_replay('open')

    def test_scope_refusal_is_not_preempted_by_verdict_body_validation(self):
        head = RoundCommandTests.open_round(self)
        path = self.root / 'invalid-body.md'
        path.write_bytes(('VERDICT: PASS @' + head + '\n').encode() + b'\xff')
        self.more_responses({'action': 'read'}, {'action': 'read'}, dict(exit=77, stderr='handoffkeep wrk: scope_denied\n'))
        result = self.run_wrk('round', 'verdict', 'job-a', '--file', str(path))
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertEqual(self.calls()[-1]['argv'][1], 'append')

    def test_raw_request_size_is_bounded_before_send(self):
        self.seed({'action': 'accept'})
        result = self.run_adapter('append', 'job-a', stdin=json.dumps(self.round_request()) + ' ' * 1048576)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(result.stderr, 'wrk o3: request_too_large\n')
        self.assertEqual(self.calls(), [])

class HistoryWitnessTests(Harness):

    def not_found(self):
        return dict(exit=66, stderr='handoffkeep wrk: not_found\n')

    def assert_regressed(self, client):
        try:
            result = self.module.route_job(client, 'job-a', 'shadow')
        except self.module.Refusal as error:
            self.assertEqual((error.code, error.exit), ('history_regressed', 75))
        else:
            self.fail('enrollment witness must refuse regression, got ' + repr(result))
        self.assertEqual(len([e for e in self.events() if e.get('code') == 'history_regressed']), 1)

    def test_not_found_after_receipt_never_downgrades_or_discards_pending(self):
        self.seed({'action': 'accept'}, dict(exit=75, stderr='handoffkeep wrk: transport_indeterminate\n'))
        with self.client() as client:
            client.append('job-a', self.round_request())
            try:
                client.append('job-a', self.round_request(expected=3, head='2' * 40))
            except self.module.Refusal:
                pass
            before = self.intent_file().read_bytes()
            self.more_responses(self.not_found(), self.not_found())
            self.assert_regressed(client)
            self.assert_regressed(client)
            self.assertEqual(self.intent_file().read_bytes(), before)
            self.assertEqual(json.loads(before)['intents'][-1]['state'], 'pending')

    def test_snapshot_alone_remembers_enrollment_after_intents_deleted(self):
        self.seed({'action': 'read'}, {'action': 'read'})
        with self.client() as client:
            client.job('job-a')
            snapshot = self.intent_file().with_name('o3-snapshot.json')
            before = snapshot.read_bytes()
            self.intent_file().unlink(missing_ok=True)
            self.more_responses(self.not_found())
            self.assert_regressed(client)
            self.assertEqual(snapshot.read_bytes(), before)

    def test_generation_regression_cannot_replace_complete_snapshot(self):
        self.seed({'action': 'read'}, {'action': 'read'})
        with self.client() as client:
            client.job('job-a')
            before = self.intent_file().with_name('o3-snapshot.json').read_bytes()
            data = json.loads(self.script.read_text())
            previous = '0' * 64
            for record in data['journal']:
                record['store_generation'] = '00000000-0000-4000-8000-ffff00000002'
                record['previous_hash'] = previous
                record['record_hash'] = self.module.digest({k: v for k, v in record.items() if k != 'record_hash'})
                previous = record['record_hash']
            data['responses'] = [{'action': 'read'}, {'action': 'read'}]
            self.script.write_text(json.dumps(data))
            self.assert_regressed(client)
            self.assertEqual(self.intent_file().with_name('o3-snapshot.json').read_bytes(), before)

    def test_seq_regression_cannot_replace_complete_snapshot(self):
        self.seed({'action': 'accept'}, {'action': 'read'}, {'action': 'read'})
        with self.client() as client:
            client.append('job-a', self.round_request())
            client.job('job-a')
            before = self.intent_file().with_name('o3-snapshot.json').read_bytes()
            self.intent_file().unlink()
            data = json.loads(self.script.read_text())
            data['journal'] = data['journal'][:2]
            data['responses'] = [{'action': 'read'}, {'action': 'read'}]
            self.script.write_text(json.dumps(data))
            self.assert_regressed(client)
            self.assertEqual(self.intent_file().with_name('o3-snapshot.json').read_bytes(), before)

    def test_no_witness_shadow_unknown_still_routes_legacy(self):
        self.responses(self.not_found())
        with self.client() as client:
            self.assertIsNone(self.module.route_job(client, 'job-a', 'shadow'))
        self.assertEqual([e['code'] for e in self.events()], ['not_found'])

class ProtectedOffline(Harness):

    def test_accepted_activation_is_a_negative_offline_witness(self):
        records = self.seed({'action': 'read'}, {'action': 'read'}, {'action': 'accept'}, dict(exit=75, stderr='handoffkeep wrk: transport_unavailable\n'))
        data = json.loads(self.script.read_text())
        data['journal'] = records[:1]
        self.script.write_text(json.dumps(data))
        with self.client() as client:
            client.job('job-a')
            client.append('job-a', dict(kind='activate', expected_seq=1, claim_seq=1, payload=dict(reason_code='initial_activation', seal_seq=None)))
            try:
                self.module.route_job(client, 'job-a', 'shadow')
            except self.module.Refusal as e:
                self.assertEqual(e.exit, 75)
            else:
                self.fail('accepted activation must veto stale shadow routing')

class ModeDiscoveryTests(Harness):

    def mode_block(self):
        source = WRK.read_text()
        body = source.split('wrk_o3_mode() {', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n}', 1)[0]
        begin = source.index('# --- trust paths: begin')
        end = source.index('# --- trust paths: end ---', begin)
        return (body, 'import os,stat,shutil\n' + source[begin:end])

    def discover(self):
        body, guard = self.mode_block()
        out = io.StringIO()
        with mock.patch.dict(os.environ, dict(self.env, WRK_TRUST_PY=guard), clear=True), mock.patch('pwd.getpwuid', return_value=type('Account', (), {'pw_dir': str(self.home)})()), contextlib.redirect_stdout(out):
            try:
                exec(compile(body, 'actual wrk_o3_mode Python call site', 'exec'), {})
            except SystemExit as result:
                self.assertEqual(result.code, 0)
        return out.getvalue().strip()

    def test_test_mode_unset_home_opens_no_mode_path(self):
        self.assertFalse((self.home / '.config/wrk/records-mode').exists())
        self.env.pop('HOME')
        with mock.patch.object(os, 'open', side_effect=AssertionError('mode discovery opened a path')) as opened:
            self.assertEqual(self.discover(), 'legacy')
            opened.assert_not_called()

    def test_production_unset_or_overridden_home_reads_only_passwd_mode(self):
        self.mode('required')
        self.env['WRK_TEST_MODE'] = '0'
        mode = self.home / '.config/wrk/records-mode'
        open_file = os.open
        for value in (None, str(self.root / 'caller-home')):
            if value is None:
                self.env.pop('HOME', None)
            else:
                self.env['HOME'] = value
            with self.subTest(home=value), mock.patch.object(os, 'open', wraps=open_file) as opened:
                self.assertEqual(self.discover(), 'required')
                self.assertEqual([Path(c.args[0]) for c in opened.call_args_list], [mode])

    def test_o3_call_with_unset_test_home_still_checks_guard(self):
        self.env.pop('HOME')
        self.env.pop('ARBITER_INBOX_ROOT')
        self.responses()
        result = self.run_adapter('capabilities')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.calls(), [])


class PortableIntentTests(Harness):

    def test_symlink_refusal_uses_platform_errno_constants(self):
        with self.client():
            with mock.patch.object(self.module, 'errno', mock.Mock(ELOOP=62, ENOTDIR=20), create=True), mock.patch.object(self.module.os, 'open', side_effect=OSError(62, 'fixture Darwin symlink')):
                try:
                    self.module.secure_open('o3-intents.json', 0, -1)
                except Exception as error:
                    self.assertIsInstance(error, self.module.Refusal)
                    self.assertEqual(error.code, 'intent_invalid')
                else:
                    self.fail('a symlink must be refused')

class RealFailure(Harness):

    def test_real_reviewer_refusal_after_claim_starts_no_pane(self):
        SpawnHandshakeTests.spawn_environment(self)
        workspace = self.root / 'workspace'
        subprocess.run(['git', '-C', str(workspace), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '--allow-empty', '-qm', 'fixture'], env=self.env, check=True)
        head = subprocess.check_output(['git', '-C', str(workspace), 'rev-parse', 'HEAD'], env=self.env, text=True).strip()
        self.mode('required')
        self.seed(*[{'action': 'read'}] * 7, dict(exit=75, stderr='handoffkeep wrk: wrk_unavailable\n'))
        result = self.run_wrk('spawn', '--host', 'local', '-c', str(workspace), '-m', 'opus', '--effort', 'high', '-p', str(self.root / 'brief.md'), '-w', 'fixture', '-l', 'job-review', '--t', 'T2', '--role', 'tester', '--owner', 'b2400-a', '--parent-job', 'job-a', '--head', head, '--report', str(self.root / 'review.md'))
        self.assertEqual(result.returncode, 75, result.stderr)
        data = json.loads(self.script.read_text())
        self.assertEqual(data['journals']['job-review'][0]['kind'], 'claim')
        self.assertEqual([c['argv'][1] for c in self.calls()], ['job', 'records', 'capabilities', 'job', 'append', 'job', 'records', 'append'])
        self.assertFalse((self.root / 'herdr.log').exists(), 'pane must wait for target round receipt')
        self.assertFalse(any((e.get('kind') in ('job.claim', 'job.spawned') for e in self.events('job-review'))))

class HarnessPathTests(unittest.TestCase):
    def test_symlinked_temp_parent_preserves_canonical_guard_expectations(self):
        with tempfile.TemporaryDirectory(prefix="p-", dir="/tmp") as directory:
            parent = Path(directory)
            (parent / "r").mkdir()
            (parent / "a").symlink_to(parent / "r", target_is_directory=True)
            result = unittest.TestResult()
            with mock.patch.dict(globals(), {"TEST_PARENT": parent / "a"}):
                TransportTests("test_production_resolver_ignores_path_and_refuses_unsafe_binary").run(result)
            self.assertEqual(result.testsRun, 1)
            self.assertEqual(result.errors, [])
            self.assertEqual(result.failures, [])



class CursorArgumentTests(Harness):
    # Director-1, b2041-solxh cursor ruling: shape/safe range is local;
    # semantic cursor limits belong to the canonical server (design L159).
    def isolate(self, label):
        self.env["ARBITER_INBOX_ROOT"] = str(self.root / label)

    def test_safe_integer_boundaries_reach_the_canonical_cli(self):
        values = (0, -1, 1, 500, 501, 9007199254740991)
        for field in ("limit", "after-seq", "snapshot-seq"):
            for value in values:
                with self.subTest(field=field, value=value):
                    self.isolate(field + "-" + str(value))
                    valid = (1 <= value <= 500 if field == "limit" else
                             0 <= value <= 2 if field == "after-seq" else 1 <= value <= 2)
                    response = {"action": "read"} if valid else dict(exit=65, stderr="handoffkeep wrk: invalid_cursor\n")
                    self.seed(response)
                    result = self.run_adapter("records", "job-a", "--" + field, str(value))
                    self.assertEqual(result.returncode, 0 if valid else 65, result.stderr)
                    calls = self.calls()
                    self.assertEqual(len(calls), 1)
                    self.assertEqual(calls[0]["argv"], ["wrk", "records", "job-a", "--" + field, str(value)])
                    if not valid:
                        self.assertEqual(result.stderr, "wrk o3: invalid_cursor\n")

    def test_invalid_literals_and_unsafe_integers_send_nothing(self):
        for field in ("limit", "after-seq", "snapshot-seq"):
            for literal in ("", "1.5", "1e3", "0x10", " 1", "1 ", "1 2", "9007199254740992", "-9007199254740992"):
                with self.subTest(field=field, literal=literal):
                    self.responses()
                    result = self.run_adapter("records", "job-a", "--" + field, literal)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(self.calls(), [])

    def test_omitted_cursor_fields_stay_omitted(self):
        self.seed({"action": "read"}, {"action": "read"})
        with self.client() as client:
            self.assertEqual(len(client.records("job-a")["records"]), 2)
        result = self.run_adapter("records", "job-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["argv"] for c in self.calls()], [["wrk", "records", "job-a"]] * 2)
        self.assertFalse(json.loads(result.stdout)["has_more"])

    def test_partial_page_is_never_cached_as_complete_history(self):
        self.seed({"action": "read"})
        result = self.run_adapter("records", "job-a", "--after-seq", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        page = json.loads(result.stdout)
        self.assertEqual([r["seq"] for r in page["records"]], [2])
        self.assertFalse(self.intent_file().with_name("o3-snapshot.json").exists())

    def test_page_not_found_after_receipt_is_history_regressed(self):
        self.seed({"action": "accept"})
        with self.client() as client:
            client.append("job-a", self.round_request())
        before = self.intent_file().read_bytes()
        self.more_responses(dict(exit=66, stderr="handoffkeep wrk: not_found\n"))
        result = self.run_adapter("records", "job-a", "--after-seq", "1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(result.stderr, "wrk o3: history_regressed\n")
        self.assertEqual(self.intent_file().read_bytes(), before)
        self.assertEqual([e["code"] for e in self.events()], ["history_regressed"])

    def test_complete_history_helper_preserves_server_cursor_errors(self):
        for value in (0, -1, 501, 9007199254740991):
            with self.subTest(value=value):
                self.responses(dict(exit=65, stderr="handoffkeep wrk: invalid_cursor\n"))
                with self.client() as client:
                    with self.assertRaises(self.module.Refusal) as error:
                        client.records("job-a", limit=value)
                self.assertEqual((error.exception.code, error.exception.exit), ("invalid_cursor", 65))
                self.assertEqual(self.calls()[0]["argv"], ["wrk", "records", "job-a", "--limit", str(value)])


class MutantTests(Harness):
    def test_required_invariants_turn_named_tests_red_at_real_call_sites(self):
        adapter_source = ADAPTER.read_text()
        wrk_source = WRK.read_text()
        mutations = [
            ("later-page-path", "adapter",
             '        chosen = self.resolver.resolve(self.central)\n        # Index only retained keys:',
             '        chosen = ({"hk": "handoffkeep", "home": os.environ["HOME"]} if args[0] == "records" and "--snapshot-seq" in args else self.resolver.resolve(self.central))\n        # Index only retained keys:',
             "ReadTests.test_every_later_page_revalidates_the_binary"),
            ("send-before-fsync", "adapter",
             '            store.save(data)  # MUST complete file+directory fsync before send.',
             '            pass  # mutant: send unsaved intent',
             "IntentTests.test_file_and_directory_fsync_precede_send"),
            ("fresh-key-on-unknown", "adapter",
             'args = ["append", job, "--kind", req["kind"], "--idempotency-key", item["idempotency_key"],',
             'args = ["append", job, "--kind", req["kind"], "--idempotency-key", str(uuid.uuid4()),',
             "IntentTests.test_unknown_reply_retains_key_body_and_original_evidence"),
            ("reject-indeterminate", "adapter", '                if exc.code in DEFINITE and item["state"] != "accepted":',
             '                if (exc.code in DEFINITE or exc.code in ("wrk_unavailable", "protocol_invalid")) and item["state"] != "accepted":',
             "IntentTests.test_only_definite_refusals_reject_intents"),
            ("verdict-before-receipt", "adapter", '            req = item["request"]\n            args = ["append",',
             '            req = item["request"]\n            if req["kind"] == "verdict":\n                self.event(job, dict(kind="job.verdict", job_id=job))\n            args = ["append",',
             "RoundCommandTests.test_stable_refusal_cannot_publish_a_verdict"),
            ("reviewer-shadow-warning", "adapter",
             '    enforced = not current.get("offline") and receipt_required(current["records"])',
             '    enforced = current["summary"]["state"] != "shadow"',
             "RoundCommandTests.test_shadow_reviewer_cannot_take_the_p1_warning_branch"),
            ("free-waiver", "adapter", '    parser.add_argument("--waiver-grant", type=positive_seq_arg)',
             '    parser.add_argument("--waiver-grant", type=lambda x: 7 if x.startswith("hk:") else positive_seq_arg(x))',
             "TypedAdapterTests.test_joined_rejects_a_free_waiver_ref"),
            ("token-override-inherited", "adapter",
             '        child_env = {key: os.environ[key] for key in os.environ if key not in OVERRIDE_KEYS}',
             '        child_env = {key: os.environ[key] for key in os.environ if key not in OVERRIDE_KEYS or key == "HANDOFFKEEP_TOKEN"}',
             "TransportTests.test_override_environment_keys_absent"),
            ("ignore-enrollment-witness", "adapter",
             '            if exc.code == "not_found" and (snapshot is not None or receipts):',
             '            if False:  # mutant: ignore retained enrollment witnesses',
             "HistoryWitnessTests.test_not_found_after_receipt_never_downgrades_or_discards_pending"),
            ("p1-no-local-veto", "adapter",
             '        candidate = local.validate(args.command, payload, current, raw)',
             '        candidate = {}  # mutant: bypass existing O2 guards',
             "P1ReconciliationTests.test_fresh_shadow_cap_and_oldest_head_guard_are_unchanged"),
            ("p1-skip-backlog", "adapter",
             '        pending = [dict(x) for x in data["intents"] if x["state"] == "pending"]',
             '        pending = []  # mutant: skip the older unknown operation',
             "P1ReconciliationTests.test_replay_dedupes_shadow_observation_and_round_numbers_match"),
            ("p1-grant-fallback", "adapter",
             'and exc.code in TEMPORARY and not uses_grant):',
             'and exc.code in TEMPORARY):',
             "P1ReconciliationTests.test_typed_grant_5xx_never_takes_p1_warning_fallback"),
            ("repeat-ignore-frozen-binding", "adapter",
             '        if (consumed is None or not earlier or frozen["grant_type"] != "head_repeat"',
             '        if False and (consumed is None or not earlier or frozen["grant_type"] != "head_repeat"',
             "TypedRepeatTests.test_mismatched_frozen_round_head_or_earlier_round_refuses"),
            ("p1-ignore-head-mapping", "adapter",
             '        if args.command == "verdict" and candidate["round"] != payload["round_no"]:',
             '        if False:  # mutant: conflate equal counts with equal head mappings',
             "P1MappingTests.test_same_count_divergent_head_mapping_refuses_without_append"),
            ("skip-legacy-link", "wrk", '  [[ "$O3_SPAWN_VERIFIED" -eq 1 ]] || hk_task_link',
             '  : # mutant: skip the legacy task link too',
             "SpawnHandshakeTests.test_real_legacy_spawn_keeps_task_probe_and_link"),
        ]
        driver = '''import importlib.util,io,json,sys,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location("o3_mutant_probe",sys.argv[1])
t=importlib.util.module_from_spec(spec);spec.loader.exec_module(t)
t.ADAPTER=Path(sys.argv[2])/"bin/wrk-o3.py";t.WRK=Path(sys.argv[2])/"bin/wrk"
t.TEST_PARENT=Path(sys.argv[2]).parents[1]
stream=io.StringIO();suite=unittest.defaultTestLoader.loadTestsFromName(sys.argv[3],t)
r=unittest.TextTestRunner(stream=stream).run(suite)
print(json.dumps(dict(failures=len(r.failures),errors=len(r.errors),detail=stream.getvalue())))
'''
        for name, target, old, new, probe in mutations:
            with self.subTest(invariant=name):
                source = adapter_source if target == "adapter" else wrk_source
                self.assertEqual(source.count(old), 1, "mutant must change one real production call site: " + name)
                directory = self.root / "mutants" / name
                binary = directory / "bin"
                binary.mkdir(parents=True)
                (binary / "wrk-o3.py").write_text(adapter_source)
                (binary / "wrk").write_text(wrk_source)
                (binary / "wrk").chmod(0o755)
                shutil.copyfile(ADAPTER.with_name("wrk-o3-contract.json"), binary / "wrk-o3-contract.json")
                for helper in (ROOT / "bin").iterdir():
                    if helper.is_file() and helper.name not in ("wrk", "wrk-o3.py", "wrk-o3-contract.json"):
                        (binary / helper.name).symlink_to(helper)
                control = subprocess.run([sys.executable, "-c", driver, str(Path(__file__)), str(directory), probe],
                                         capture_output=True, text=True, env=self.env, timeout=300)
                self.assertEqual(control.returncode, 0, control.stderr)
                baseline = json.loads(control.stdout)
                self.assertEqual((baseline["failures"], baseline["errors"]), (0, 0), "pristine copy must pass: " + baseline["detail"])
                (binary / ("wrk-o3.py" if target == "adapter" else "wrk")).write_text(source.replace(old, new))
                result = subprocess.run([sys.executable, "-c", driver, str(Path(__file__)), str(directory), probe],
                                        capture_output=True, text=True, env=self.env, timeout=300)
                self.assertEqual(result.returncode, 0, result.stderr)
                observation = json.loads(result.stdout)
                self.assertEqual(observation["errors"], 0, "exceptions do not count as mutant RED: " + observation["detail"])
                self.assertGreater(observation["failures"], 0, "surviving mutant: " + name + " " + observation["detail"])




class P1ReconciliationTests(Harness):
    record = DesignObservationTests.record
    def shadow(self, *responses):
        records = self.seed(*responses)
        data = json.loads(self.script.read_text()); data['journal'] = records[:1]
        self.script.write_text(json.dumps(data)); self.mode('shadow')
        return records[:1]

    def repo(self):
        directory = self.root / 'head-repo'
        if not (directory / '.git').is_dir():
            directory.mkdir()
            env = dict(self.env, GIT_CONFIG_NOSYSTEM='1')
            subprocess.run(['git', 'init', '-q', str(directory)], env=env, check=True)
            for message in ('fixture first', 'fixture second'):
                subprocess.run(['git', '-C', str(directory), '-c', 'user.name=Fixture',
                                '-c', 'user.email=fixture@example.test', '-c', 'commit.gpgsign=false',
                                'commit', '--allow-empty', '-qm', message], env=env, check=True)
        return directory

    def head(self, ref='HEAD'):
        return subprocess.check_output(['git', 'rev-parse', ref], cwd=P1ReconciliationTests.repo(self), env=self.env, text=True).strip()

    def open(self, ref='HEAD'):
        return self.run_wrk('round', 'open', 'job-a', '--head', self.head(ref), '--repo', str(P1ReconciliationTests.repo(self)))

    def ended(self):
        events = self.intent_file().parent / 'events'; events.mkdir(parents=True, exist_ok=True)
        (events/'00099-job.revoked.json').write_text(json.dumps(dict(kind='job.revoked',job_id='job-a',created_at='2099-01-01T00:00:00Z')))

    def appends(self):
        return [{k:c[k] for k in ('argv','stdin')} for c in self.calls() if c['argv'][1] == 'append']

    def test_fresh_local_end_veto_precedes_intent_and_append(self):
        self.shadow(*[{'action':'read'}]*2, {'action':'accept'}); self.ended()
        result = self.open()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('refused after end record', result.stderr)
        self.assertEqual(self.appends(), [])
        self.assertFalse(self.intent_file().exists())
        self.assertEqual(len(self.events()),1)

    def test_pending_and_accepted_after_end_replay_original_then_refuse_all_projection(self):
        for action in ('commit_lost','accept'):
            with self.subTest(state=action):
                # Each branch has its own job/temp state.
                other = P1ReconciliationTests(); other.setUp()
                try:
                    other.shadow({'action':action})
                    with other.client() as client:
                        request = other.round_request(expected=1, head=other.head())
                        try: client.append('job-a', request)
                        except other.module.Refusal as exc: self.assertEqual(exc.exit,75)
                    original = other.appends()[0]
                    other.ended(); before=other.events()
                    other.more_responses({'action':'accept'}, *[{'action':'read'}]*2)
                    result=other.open()
                    self.assertEqual(result.returncode,2,result.stderr)
                    self.assertEqual(other.events(),before)
                    self.assertEqual(other.appends(),[original,original])
                    key=original['argv'][original['argv'].index('--idempotency-key')+1]
                    self.assertIn(key,result.stderr)
                    self.assertEqual(result.stderr.count('warning key='),1)
                finally: other.doCleanups()

    def test_activated_job_ignores_planted_local_end_without_snapshot(self):
        self.seed(*[{'action':'read'}]*2, {'action':'accept'}); self.mode('required'); self.ended()
        self.assertFalse(self.intent_file().with_name('o3-snapshot.json').exists())
        result=self.open()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(self.appends()),1)
        self.assertEqual(sum(e['kind']=='job.round' for e in self.events()),1)

    def test_unavailable_classification_uses_local_end_only_as_veto(self):
        self.shadow(dict(exit=75,stderr='handoffkeep wrk: transport_unavailable\n')); self.ended()
        result=self.open()
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertEqual(self.appends(),[])
        self.assertFalse(self.intent_file().exists())

    def test_stale_shadow_snapshot_cannot_authorize_append(self):
        self.shadow(*[{'action':'read'}]*2)
        with self.client() as client: client.job('job-a')
        self.more_responses(dict(exit=75,stderr='handoffkeep wrk: transport_unavailable\n'),{'action':'accept'})
        result=self.open()
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual(self.appends(),[])
        self.assertFalse(self.intent_file().exists())

    def test_replay_dedupes_shadow_observation_and_round_numbers_match(self):
        self.shadow(*[{'action':'read'}]*2,dict(exit=75,stderr='handoffkeep wrk: wrk_unavailable\n'))
        result=self.open('HEAD^'); self.assertEqual(result.returncode,0,result.stderr)
        original=self.appends()[0]
        first=[e for e in self.events() if e['kind']=='job.round'][0]
        self.more_responses({'action':'accept'}, *[{'action':'read'}]*2, {'action':'accept'})
        result=self.open(); self.assertEqual(result.returncode,0,result.stderr)
        rounds=[e for e in self.events() if e['kind']=='job.round']
        self.assertEqual([e['round'] for e in rounds],[1,2])
        self.assertEqual(rounds[0],first)
        self.assertEqual(self.appends()[:2],[original,original])
        data=json.loads(self.script.read_text())
        self.assertEqual([r['payload']['round_no'] for r in data['journal'] if r['kind']=='round_open'],[1,2])
        self.assertTrue(all(i['state']=='accepted' for i in json.loads(self.intent_file().read_text())['intents']))

    def test_definite_replay_rejection_leaves_orphan_and_fails_closed(self):
        self.shadow(*[{'action':'read'}]*2,dict(exit=75,stderr='handoffkeep wrk: wrk_unavailable\n'))
        result=self.open('HEAD^'); self.assertEqual(result.returncode,0,result.stderr)
        original=self.appends()[0]
        self.more_responses(dict(exit=73,stderr='handoffkeep wrk: sequence_conflict\n'),*[{'action':'read'}]*2,{'action':'accept'})
        result=self.open()
        self.assertEqual(result.returncode,75,result.stderr)
        for value in ('job-a','local_next_round=2','server_next_round=1','orphaned local round=1'):
            self.assertIn(value,result.stderr)
        self.assertEqual(self.appends(),[original,original])
        self.assertEqual([e['round'] for e in self.events() if e['kind']=='job.round'],[1])

    def test_indeterminate_backlog_blocks_new_append(self):
        self.shadow(*[{'action':'read'}]*2,dict(exit=75,stderr='handoffkeep wrk: wrk_unavailable\n'))
        self.assertEqual(self.open('HEAD^').returncode,0)
        original=self.appends()[0]
        self.more_responses(dict(exit=75,stderr='handoffkeep wrk: transport_indeterminate\n'))
        result=self.open()
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual(self.appends(),[original,original])
        self.assertEqual(len(json.loads(self.intent_file().read_text())['intents']),1)

    def test_fresh_shadow_cap_and_oldest_head_guard_are_unchanged(self):
        self.shadow(*[{'action':'read'}]*2)
        directory=self.intent_file().parent/'events'; directory.mkdir(parents=True,exist_ok=True)
        for n in range(1,4):
            (directory/('%05d-job.round.json'%n)).write_text(json.dumps(dict(kind='job.round',job_id='job-a',round=n,head=str(n)*40)))
        result=self.open()
        self.assertEqual(result.returncode,78,result.stderr)
        self.assertEqual(self.appends(),[])
        self.assertFalse(self.intent_file().exists())

    def grant(self, records, kind='extension', round_no=None):
        payload=dict(grant_type=kind,round_no=round_no,head=None,extra=1 if kind=='extension' else 0,
                     earlier_round_no=None,tester_job_id=None,expires_at='2099-01-01T00:00:00Z',reason_code='desk_approved')
        record=DesignObservationTests.record(self,'grant',payload,records)
        record['actor_client_id']='director-1'
        record['record_hash']=self.module.digest({k:v for k,v in record.items() if k!='record_hash'})
        return record

    def test_typed_grant_5xx_never_takes_p1_warning_fallback(self):
        self.shadow(*[{'action':'read'}]*2,dict(exit=75,stderr='handoffkeep wrk: wrk_unavailable\n'))
        with self.client():
            data=json.loads(self.script.read_text())
            for n in range(1,4):
                self.record('round_open',dict(round_no=n,head=str(n)*40,tester_job_id=None,extension_grant_seq=None,repeat_grant_seq=None),data['journal'])
            grant=self.grant(data['journal'])
            self.script.write_text(json.dumps(data))
        events=self.intent_file().parent/'events'; events.mkdir(parents=True,exist_ok=True)
        for n in range(1,4):
            (events/('%05d-job.round.json'%n)).write_text(json.dumps(dict(kind='job.round',job_id='job-a',round=n,head=str(n)*40)))
        result=self.run_wrk('round','open','job-a','--head',self.head(),'--repo',str(P1ReconciliationTests.repo(self)),'--extension-grant',str(grant['seq']))
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual(len(self.appends()),1)
        self.assertEqual(len(self.events()),3)
        self.assertEqual(json.loads(self.intent_file().read_text())['intents'][0]['state'],'pending')

    def test_two_extension_grants_and_replay_keep_o2_cumulative_shape(self):
        self.mode('required')
        with self.client() as client:
            records=DesignObservationTests.own_history(self,imported=True)
            first_grant=self.grant(records)
            first=DesignObservationTests.record(self,'round_open',dict(round_no=4,head='a'*40,tester_job_id=None,extension_grant_seq=first_grant['seq'],repeat_grant_seq=None),records)
            second_grant=self.grant(records)
            second=DesignObservationTests.record(self,'round_open',dict(round_no=5,head='b'*40,tester_job_id=None,extension_grant_seq=second_grant['seq'],repeat_grant_seq=None),records)
            history=dict(records=records,summary={'claim_seq':1})
            for record in (first,second,first):
                client.project(dict(created=False,record=record),'enforced',history)
            rounds=[e for e in self.events() if e['kind']=='job.round']
            self.assertEqual([e['approval']['extra'] for e in rounds],[1,2])
            for event,grant in zip(rounds,(first_grant,second_grant)):
                self.assertEqual(event['approval']['ref'],'hk:task/901')
                self.assertEqual(event['approval']['issuer'],'director-1')
                self.assertEqual(event['reason'],'desk_approved')
                self.assertEqual(event['extension_grant_seq'],grant['seq'])
                self.assertEqual(event['extension_grant_record_hash'],grant['record_hash'])
                self.assertEqual(set(event['wrk_receipt']),{'job_id','seq','record_hash','store_generation'})

    def test_typed_void_projection_is_readable_by_unchanged_o2_counter(self):
        self.shadow(*[{'action':'read'}]*2,{'action':'accept'},*[{'action':'read'}]*2,{'action':'accept'})
        self.assertEqual(self.open().returncode,0)
        with self.client():
            data=json.loads(self.script.read_text()); grant=self.grant(data['journal'],'void',1)
            self.script.write_text(json.dumps(data))
        result=self.run_wrk('round','void','job-a','1','--grant',str(grant['seq']))
        self.assertEqual(result.returncode,0,result.stderr)
        event=[e for e in self.events() if e['kind']=='job.round_void'][0]
        self.assertEqual((event['ref'],event['issuer'],event['reason']),('hk:task/2400','director-1','builder_void'))
        self.assertEqual(event['grant_record_hash'],grant['record_hash'])
        with self.client() as client:
            with client.events_locked('job-a') as local:
                _,_,scan=local.run_guard('round_scan',[])
                self.assertEqual(scan['used'],0)



class ModeShellTests(Harness):
    def discover_shell(self, production=False, darwin=False):
        stub=self.root/'mode-tools';stub.mkdir(exist_ok=True)
        python=stub/'python3';python.write_text('#!/bin/sh\nexit 1\n');python.chmod(0o700)
        env=dict(self.env,PATH=str(stub)+':/usr/bin:/bin',WRK_TRUST_PY='')
        source=WRK.read_text()
        function='wrk_o3_mode() {'+source.split('wrk_o3_mode() {',1)[1].split('\n}\n',1)[0]+'\n}\n'
        if production:
            env['WRK_TEST_MODE']='0'
            caller=self.root/'caller-home'; caller.mkdir(exist_ok=True)
            caller_mode=caller/'.config/wrk/records-mode';caller_mode.parent.mkdir(parents=True,exist_ok=True)
            caller_mode.write_text('required\n')
            env['HOME']=str(caller)
            lookup=self.root/'mode-getent'
            darwin_lookup=self.root/'mode-dscacheutil'
            lookup.write_text("#!/bin/sh\nprintf 'fixture:x:%d:1:Fixture:%s:/bin/sh\\n'\n" % (os.getuid(),self.home))
            darwin_lookup.write_text("#!/bin/sh\nprintf 'uid: %d\\ndir: %s\\n'\n" % (os.getuid(),self.home))
            lookup.chmod(0o700);darwin_lookup.chmod(0o700)
            function=function.replace('/usr/bin/getent',str(self.root/'missing-getent') if darwin else str(lookup))
            function=function.replace('/usr/bin/dscacheutil',str(darwin_lookup))
        return subprocess.run(['bash','-c',function+'\nwrk_o3_mode\n'],env=env,capture_output=True,text=True)
    def test_production_absence_and_parse_routing_ignore_caller_home_on_both_os(self):
        for darwin in (False, True):
            with self.subTest(darwin=darwin):
                mode=self.home/'.config/wrk/records-mode'
                mode.unlink(missing_ok=True)
                result=self.discover_shell(production=True,darwin=darwin)
                self.assertEqual((result.returncode,result.stdout),(0,'legacy\n'),result.stderr)
                self.mode('required')
                self.assertNotEqual(self.discover_shell(production=True,darwin=darwin).returncode,0)
                mode.unlink();mode.symlink_to(self.root/'absent-mode')
                self.assertNotEqual(self.discover_shell(production=True,darwin=darwin).returncode,0)
                mode.unlink()
    def test_absent_file_needs_no_python(self):
        result=self.discover_shell()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'legacy\n')
    def test_present_file_with_broken_python_refuses(self):
        self.mode('required')
        result=self.discover_shell()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')
    def test_dangling_symlink_requires_parser_and_refuses(self):
        mode=self.home/'.config/wrk/records-mode';mode.parent.mkdir(parents=True)
        mode.symlink_to(self.root/'absent')
        result=self.discover_shell()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,'')


class TypedRepeatTests(Harness):
    record=DesignObservationTests.record
    grant=P1ReconciliationTests.grant
    head=P1ReconciliationTests.head
    appends=P1ReconciliationTests.appends
    def prepare(self, mismatch=None):
        records=self.seed(*[{'action':'read'}]*2,{'action':'accept'},*[{'action':'read'}]*2,{'action':'accept'})[:1]
        self.mode('shadow'); head=self.head()
        with self.client() as client:
            for n in range(1,4):
                opened=self.record('round_open',dict(round_no=n,head=head if n==1 else str(n)*40,tester_job_id=None,extension_grant_seq=None,repeat_grant_seq=None),records)
                client.event('job-a',dict(kind='job.round',job_id='job-a',round=n,head=opened['payload']['head']))
            old=b'VERDICT: PASS @'+head.encode()+b'\nfirst independent review\n'
            verdict=dict(round_no=1,head=head,verdict='PASS',path=str(self.root/'old-review.md'),content_sha256=hashlib.sha256(old).hexdigest(),size_bytes=len(old),tester_job_id=None)
            self.record('verdict',verdict,records)
            client.event('job-a',dict(kind='job.verdict',job_id='job-a',round=1,**{k:v for k,v in verdict.items() if k!='round_no'}))
            extension=self.grant(records,'extension',4)
            repeat=self.grant(records,'head_repeat',4)
            repeat['payload'].update(head=head,earlier_round_no=1)
            if mismatch: repeat['payload'].update(mismatch)
            repeat['record_hash']=self.module.digest({k:v for k,v in repeat.items() if k!='record_hash'})
        data=json.loads(self.script.read_text());data['journal']=records;self.script.write_text(json.dumps(data))
        result=self.run_wrk('round','open','job-a','--head',head,'--repo',str(P1ReconciliationTests.repo(self)),'--extension-grant',str(extension['seq']),'--repeat-grant',str(repeat['seq']))
        self.assertEqual(result.returncode,0,result.stderr)
        return extension,repeat
    def verdict(self, *flags):
        review=self.root/'new-review.md';review.write_text('VERDICT: PASS @'+self.head()+'\nsecond independent review\n')
        return self.run_wrk('round','verdict','job-a','--file',str(review),*flags)
    def test_both_grants_project_independently_and_allow_same_round_repeat(self):
        extension,repeat=self.prepare()
        opened=[e for e in self.events() if e['kind']=='job.round'][-1]
        self.assertEqual(opened['round'],4)
        self.assertEqual(opened['approval']['extra'],1)
        for prefix,grant in (('extension',extension),('repeat',repeat)):
            self.assertEqual(opened[prefix+'_grant_seq'],grant['seq'])
            self.assertEqual(opened[prefix+'_grant_record_hash'],grant['record_hash'])
        self.assertNotIn('grant_seq',opened)
        self.assertEqual(set(opened['wrk_receipt']),{'job_id','seq','record_hash','store_generation'})
        result=self.verdict();self.assertEqual(result.returncode,0,result.stderr)
        verdict=[e for e in self.events() if e['kind']=='job.verdict'][-1]
        self.assertEqual(verdict['round'],4)
        self.assertEqual(verdict['head_repeat'],'o3:'+repeat['record_hash'])
    def test_mismatched_frozen_round_head_or_earlier_round_refuses(self):
        for mismatch in ({'round_no':3},{'head':'f'*40},{'earlier_round_no':2}):
            with self.subTest(mismatch=mismatch):
                other=TypedRepeatTests();other.setUp()
                try:
                    other.prepare(mismatch)
                    result=other.verdict()
                    self.assertEqual(result.returncode,2,result.stderr)
                    self.assertIn('DUP_HEAD',result.stderr)
                    self.assertEqual(len(other.appends()),1)
                finally:other.doCleanups()
    def test_free_head_repeat_reference_on_enrolled_job_refuses(self):
        self.prepare()
        result=self.verdict('--head-repeat','hk:task/2400')
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertEqual(len(self.appends()),1)


class P1MappingTests(Harness):
    record=DesignObservationTests.record
    head=P1ReconciliationTests.head
    appends=P1ReconciliationTests.appends
    def mapping(self, mismatch):
        records=self.seed(*[{'action':'read'}]*2,{'action':'accept'})[:1]
        head,other=self.head(),self.head('HEAD^')
        self.mode('shadow')
        with self.client() as client:
            for n,h in ((1,head),(2,other)):
                self.record('round_open',dict(round_no=n,head=h,tester_job_id=None,extension_grant_seq=None,repeat_grant_seq=None),records)
                client.event('job-a',dict(kind='job.round',job_id='job-a',round=n,head=(other if n==1 else head) if mismatch else h))
        data=json.loads(self.script.read_text());data['journal']=records;self.script.write_text(json.dumps(data))
        review=self.root/'mapping-review.md';review.write_text('VERDICT: PASS @'+head+'\nmapping check\n')
        return self.run_wrk('round','verdict','job-a','--file',str(review)),head
    def test_same_count_divergent_head_mapping_refuses_without_append(self):
        result,head=self.mapping(True)
        self.assertEqual(result.returncode,75,result.stderr)
        for value in ('job-a',head,'local_target_round=2','server_target_round=1','orphaned local round=2'):
            self.assertIn(value,result.stderr)
        self.assertEqual(self.appends(),[])
        self.assertFalse(self.intent_file().exists())
        self.assertFalse(any(e['kind']=='job.verdict' for e in self.events()))
    def test_matching_mapping_appends_with_server_round(self):
        result,head=self.mapping(False)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(self.appends()[0]['stdin'])['round_no'],1)
        self.assertEqual([e['round'] for e in self.events() if e['kind']=='job.verdict'],[1])




class ModeAncestorTests(Harness):
    discover_shell=ModeShellTests.discover_shell
    def assert_refused(self, component):
        result=self.discover_shell()
        self.assertEqual(result.returncode,2,result.stderr+result.stdout)
        self.assertEqual(result.stdout,'')
        self.assertIn(str(component),result.stderr)
        self.assertEqual(len(result.stderr.splitlines()),1)
    def test_inaccessible_parent_is_not_absence(self):
        self.mode('required');directory=self.home/'.config/wrk';directory.chmod(0)
        try:self.assert_refused(directory)
        finally:directory.chmod(0o700)
    def test_non_directory_config_refuses(self):
        component=self.home/'.config';component.write_text('ordinary file\n')
        self.assert_refused(component)
    def test_truly_absent_wrk_under_searchable_config_is_legacy(self):
        (self.home/'.config').mkdir()
        result=self.discover_shell()
        self.assertEqual((result.returncode,result.stdout),(0,'legacy\n'),result.stderr)
    def test_symlink_ancestors_refuse_even_when_target_is_searchable(self):
        for relative in ('.config','.config/wrk'):
            with self.subTest(component=relative):
                other=ModeAncestorTests();other.setUp()
                try:
                    component=other.home/relative;component.parent.mkdir(parents=True,exist_ok=True)
                    target=other.root/'real-directory';target.mkdir();component.symlink_to(target,target_is_directory=True)
                    other.assert_refused(component)
                finally:other.doCleanups()
    def test_inaccessible_home_is_not_absence(self):
        self.home.chmod(0)
        try:self.assert_refused(self.home)
        finally:self.home.chmod(0o700)


class ModeParityTests(Harness):
    def discover_working_shell(self):
        source=WRK.read_text()
        function='wrk_o3_mode() {'+source.split('wrk_o3_mode() {',1)[1].split('\n}\n',1)[0]+'\n}\n'
        guard=ModeDiscoveryTests.mode_block(self)[1]
        env=dict(self.env,WRK_TRUST_PY=guard)
        return subprocess.run(['bash','-c',function+'\nwrk_o3_mode\n'],env=env,capture_output=True,text=True)
    def test_shell_and_python_discovery_decide_same_fixture_set(self):
        for case in ('blocked','file-config','symlink','absent','present'):
            with self.subTest(case=case):
                other=ModeParityTests();other.setUp();blocked=None
                try:
                    if case=='blocked':
                        other.mode('required');blocked=other.home/'.config/wrk';blocked.chmod(0)
                    elif case=='file-config':(other.home/'.config').write_text('not a directory')
                    elif case=='symlink':
                        target=other.root/'real-config';target.mkdir();(other.home/'.config').symlink_to(target,target_is_directory=True)
                    elif case=='absent':(other.home/'.config').mkdir()
                    else:other.mode('required')
                    # A working interpreter lets the shell take its real parse path.
                    shell=other.discover_working_shell()
                    with other.client() as client:
                        try:value=other.module.records_mode(client.resolver)
                        except other.module.Refusal as error:
                            self.assertEqual(error.code,'cli_usage')
                            self.assertEqual(error.exit,2)
                            self.assertEqual(shell.returncode,2,shell.stderr)
                            self.assertEqual(shell.stderr,error.line())
                        else:
                            if case=='present':self.assertEqual((value,shell.returncode,shell.stdout),('required',0,'required\n'),shell.stderr)
                            else:self.assertEqual((value,shell.returncode,shell.stdout),('legacy',0,'legacy\n'))
                finally:
                    if blocked is not None:blocked.chmod(0o700)
                    other.doCleanups()




class EndedHistoryTests(Harness):
    head=P1ReconciliationTests.head
    ended=P1ReconciliationTests.ended
    appends=P1ReconciliationTests.appends

    def accepted(self):
        P1ReconciliationTests.shadow(self,{'action':'accept'})
        with self.client() as client:
            client.append('job-a',self.round_request(expected=1,head=self.head()))
        return copy.deepcopy(json.loads(self.intent_file().read_text())['intents'][0])

    def prefix_response(self,records):
        source=ROOT/'tests/fixtures/wrk-o3/handoffkeep'
        tree=ast.parse(source.read_text())
        fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='summary')
        ns={};exec(compile(ast.Module(body=[fn],type_ignores=[]),str(source),'exec'),ns)
        summary=ns['summary'](records)
        return (dict(contract='hk1873.v1',claim=records[0],summary=summary),
                dict(contract='hk1873.v1',snapshot_seq=summary['snapshot_seq'],next_after_seq=summary['snapshot_seq'],has_more=False,records=records,summary=summary))

    def retry(self):
        return self.run_wrk('round','open','job-a','--head',self.head(),'--repo',str(P1ReconciliationTests.repo(self)))

    def assert_observation(self,result,before,original,kind):
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual(self.events(),before)
        self.assertEqual(len(result.stderr.splitlines()),1,result.stderr)
        for word in ('history_regressed','job-a',original['idempotency_key'],'00099-job.revoked.json',kind):
            self.assertIn(word,result.stderr)
        current=json.loads(self.intent_file().read_text())['intents'][0]
        self.assertEqual(current['state'],'accepted')
        self.assertEqual(current['receipt'],original['receipt'])
        self.assertEqual(current['request'],original['request'])
        self.assertEqual(current['idempotency_key'],original['idempotency_key'])
        self.assertEqual(set(current['history_regressed']),{'observed_at','get_result'})
        self.assertEqual(current['history_regressed']['get_result'],kind)
        self.assertTrue(current['history_regressed']['observed_at'].endswith('Z'))
        return current['history_regressed']

    def test_ended_replay_not_found_notes_without_event_and_preserves_acceptance(self):
        original=self.accepted();self.ended();before=self.events()
        self.more_responses({'action':'accept'},dict(exit=66,stderr='handoffkeep wrk: not_found\n'))
        first=self.assert_observation(self.retry(),before,original,'not_found')
        self.more_responses({'action':'accept'},dict(exit=66,stderr='handoffkeep wrk: not_found\n'))
        self.assertEqual(self.assert_observation(self.retry(),before,original,'not_found'),first)
        self.assertEqual(self.appends(),[self.appends()[0]]*3)

    def test_not_ended_history_still_writes_warning_event(self):
        self.accepted();before=self.intent_file().read_bytes()
        self.more_responses(dict(exit=66,stderr='handoffkeep wrk: not_found\n'))
        result=self.run_wrk('round','status','job-a')
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual([e['kind'] for e in self.events()],['job.o3_warning'])
        self.assertEqual(self.intent_file().read_bytes(),before)

    def test_fresh_status_with_old_intents_uses_none_and_never_notes_old_entry(self):
        self.accepted();self.ended();before=self.events();intents=self.intent_file().read_bytes()
        self.more_responses(dict(exit=66,stderr='handoffkeep wrk: not_found\n'))
        result=self.run_wrk('round','status','job-a')
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual(self.events(),before)
        self.assertEqual(self.intent_file().read_bytes(),intents)
        self.assertIn('key=none',result.stderr)
        self.assertIn('GET_result=not_found',result.stderr)

    def test_snapshot_only_ended_status_never_invents_an_intent(self):
        self.seed(*[{'action':'read'}]*2);self.mode('required')
        with self.client() as client:client.job('job-a')
        self.assertFalse(self.intent_file().exists());self.ended();before=self.events()
        self.more_responses(dict(exit=66,stderr='handoffkeep wrk: not_found\n'))
        result=self.run_wrk('round','status','job-a')
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertEqual(self.events(),before);self.assertFalse(self.intent_file().exists())
        self.assertIn('key=none',result.stderr)
        self.assertIn('00099-job.revoked.json',result.stderr)

    def test_seq_regression_during_replay_notes_the_current_intent(self):
        original=self.accepted();self.ended();before=self.events()
        records=json.loads(self.script.read_text())['journal'][:1]
        job,page=self.prefix_response(records)
        self.more_responses({'action':'accept'},self.success(job),self.success(page))
        self.assert_observation(self.retry(),before,original,'seq_regressed')

    def test_generation_regression_during_replay_notes_actual_result(self):
        original=self.accepted();self.ended();before=self.events()
        records=copy.deepcopy(json.loads(self.script.read_text())['journal'])
        with self.client():
            previous='0'*64
            for record in records:
                record['store_generation']='00000000-0000-4000-8000-ffff00000002'
                record['previous_hash']=previous
                record['record_hash']=self.module.digest({k:v for k,v in record.items() if k!='record_hash'})
                previous=record['record_hash']
        job,page=self.prefix_response(records)
        self.more_responses({'action':'accept'},self.success(job),self.success(page))
        self.assert_observation(self.retry(),before,original,'generation_regressed')

    def test_note_is_fsynced_before_integrity_refusal(self):
        self.accepted();self.ended()
        self.more_responses(dict(exit=66,stderr='handoffkeep wrk: not_found\n'))
        with self.client() as client:
            data=json.loads(self.intent_file().read_text());client._current_intents['job-a']=data['intents'][0]['local_id']
            calls=[];save=self.module.os.fsync
            def fsync(fd):calls.append(fd);return save(fd)
            with mock.patch.object(self.module.os,'fsync',side_effect=fsync):
                with self.assertRaises(self.module.EndedHistoryFault):client.job('job-a')
            self.assertGreaterEqual(len(calls),4)
            self.assertIn('history_regressed',json.loads(self.intent_file().read_text())['intents'][0])

    def test_accepted_replay_never_replaces_its_retained_receipt(self):
        original=self.accepted();self.ended();before=self.events()
        record=copy.deepcopy(json.loads(self.script.read_text())['journal'][-1])
        record['received_at']='2026-10-26T00:00:00.000002Z'
        with self.client():
            record['record_hash']=self.module.digest({k:v for k,v in record.items() if k!='record_hash'})
        records=copy.deepcopy(json.loads(self.script.read_text())['journal']);records[-1]=record
        response=dict(contract='hk1873.v1',created=False,record=record,summary=self.prefix_response(records)[0]['summary'])
        self.more_responses(self.success(response))
        self.assert_observation(self.retry(),before,original,'seq_regressed')

    def test_bad_note_shape_refuses_without_sending(self):
        original=self.accepted()
        for note in ({'observed_at':'2026-10-26T00:00:00Z','get_result':'other'},
                     {'observed_at':'2026-10-26T00:00:00Z','get_result':[]},
                     {'observed_at':'not a date','get_result':'not_found'},
                     {'observed_at':'2026-10-26T00:00:00Z','get_result':'not_found','extra':True}):
            with self.subTest(note=note):
                data=json.loads(self.intent_file().read_text());data['intents'][0]['history_regressed']=note;self.intent_file().write_text(json.dumps(data));before=len(self.calls())
                result=self.retry()
                self.assertEqual(result.returncode,74,result.stderr)
                self.assertEqual(len(self.calls()),before)



class FixtureHistoryTests(Harness):
    def test_two_heads_are_owned_fixtures_without_source_history(self):
        original=subprocess.check_output
        def check(*args,**kwargs):
            if Path(kwargs.get('cwd',Path.cwd())).resolve()==ROOT.resolve():
                raise subprocess.CalledProcessError(128,args[0])
            return original(*args,**kwargs)
        with mock.patch.object(subprocess,'check_output',side_effect=check):
            try:
                first=P1ReconciliationTests.head(self,'HEAD^')
                second=P1ReconciliationTests.head(self,'HEAD')
            except subprocess.CalledProcessError:
                self.fail('two-head fixture depends on source-checkout history')
        self.assertNotEqual(first,second)
        self.assertTrue(P1ReconciliationTests.repo(self).is_relative_to(self.root))


class RegularIOTests(Harness):
    def test_validated_regular_descriptor_uses_blocking_io(self):
        file=self.root/'regular';file.write_text('{}\n');file.chmod(0o600)
        directory=os.open(self.root,os.O_RDONLY|os.O_DIRECTORY)
        try:
            with self.client():
                fd=self.module.secure_open('regular',os.O_RDONLY,directory)
                try:self.assertTrue(os.get_blocking(fd),'validated regular IO remained nonblocking')
                finally:os.close(fd)
        finally:os.close(directory)


if __name__ == "__main__":
    unittest.main()
