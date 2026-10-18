"""hk 1632: real wrk parsing/prechecks with inert admission, hk and scopefuel."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REF = "hk:doc/round-ext/b1632-sol"


class RoundExtensionSpawn(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="round-ext-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.log = self.base / "calls"
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.base),
                    "HK_TASK_ID": "1632", "ARBITER_INBOX_ROOT": str(self.base / "jobs"),
                    "HANDOFFKEEP_BIN": str(self.base / "hk"),
                    "SCOPEFUEL_BIN": str(self.base / "scopefuel"),
                    "CALL_LOG": str(self.log)}
        for key in ("CONFIG", "DATA", "STATE", "CACHE", "RUNTIME"):
            self.env[f"XDG_{key}_HOME" if key != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(self.base / key)
        source = (ROOT / "bin/wrk").read_text().rsplit('case "${1:-}" in', 1)[0]
        self.lib = self.base / "wrk-lib"
        self.lib.write_text(source)
        events = self.base / "jobs/b1632-sol/events"
        events.mkdir(parents=True)
        (events / "00001-job.claim.json").write_text(json.dumps({"job_id": "b1632-sol",
            "kind": "job.claim", "payload": {"task_id": "1632", "parent_lane": "director-1"}}))
        self.prompt = self.base / "brief.md"
        self.prompt.write_text("inert fixture")
        self.stub("hk", '''import json, os, sys
from pathlib import Path
with Path(os.environ["CALL_LOG"]).open("a") as f: f.write(json.dumps(sys.argv[1:]) + "\\n")
mode = os.environ.get("HK_MODE", "ok")
if mode == "down": raise SystemExit(1)
if sys.argv[1:3] == ["doc", "get"]:
    if mode == "missing": print("not_found"); raise SystemExit(1)
    if mode == "garbage": print("{}"); raise SystemExit(0)
    print(json.dumps({"key": sys.argv[3], "body": "round extension record",
        "created_by": os.environ.get("DOC_ISSUER", "director-1")}))
elif sys.argv[1:3] == ["tasks", "show"]:
    if "TASK_REPLY" in os.environ: print(os.environ["TASK_REPLY"]); raise SystemExit(0)
    print(json.dumps({"state": "in_progress", "claimed_by": "fixture-builder",
        "refs": {"job_id": "other-task" if mode == "wrong-owner" else "b1632-sol"}}))
else: raise SystemExit("unexpected hk mutation")
''')
        self.stub("scopefuel", '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["CALL_LOG"]).open("a") as f: f.write(json.dumps(args) + "\\n")
if args[:2] == ["policy", "launch"]:
    print(json.dumps({"model_id": "gpt-6-astra" if args[2] == "codex-astra" else "claude-fable-5-1",
        "effort": "xhigh" if args[2] == "codex-astra" else "",
        "catalog": {"source": "fixture", "stale": False}}))
elif args == ["gate", "--help"]: pass
elif args[:1] == ["gate"]:
    print("gate ok pool=fixture")
    raise SystemExit(int(os.environ.get("QUOTA_RC", "0")))
else: raise SystemExit("unexpected scopefuel command")
''')

    def stub(self, name, text):
        path = self.base / name
        path.write_text("#!/usr/bin/env python3\n" + text)
        path.chmod(0o700)

    def run_spawn(self, *, model="codex-astra", role="tester", ref=REF,
                  purpose="round-extension", extra=(), environment=None, router=False):
        self.log.unlink(missing_ok=True)
        args = ["-c", str(self.base), "-m", model, "-p", str(self.prompt), "-w", "fixture",
                "-l", "fixture-tester", "--t", "T3", "--role", role,
                "--parent-job", "b1632-sol"]
        if ref is not None:
            args += ["--round-ext", ref]
        if purpose is not None:
            args += ["--purpose", purpose]
        args += list(extra)
        harness = '''source "$1"; shift
local_spawn_resolve() { LOCAL_SPAWN_ALLOWED=1; }
warn_if_canonical_off_default() { :; }
spawn_pane_cleanup() { :; }
arbiter_release_held() { :; }
mock_mcp_cleanup() { :; }
arbiter_admit() { exit 91; }
'''
        harness += 'spawn_router_cmd --host local "$@"' if router else 'spawn_cmd "$@"'
        process = subprocess.run(["bash", "-c", harness, "fixture", str(self.lib), *args],
            env={**self.env, **(environment or {})}, capture_output=True, text=True, timeout=60)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return process, calls

    def assert_denied(self, **kw):
        process, calls = self.run_spawn(**kw)
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertFalse(any(c[:1] in (["gate"], ["policy"]) for c in calls), calls)
        return process.stderr

    def test_valid_refs_forward_to_both_scopefuel_paths(self):
        for model in ("codex-astra", "fable"):
            for role, key in zip(("tester", "reviewer", "counsel"),
                                 ("round-ext", "round-extension", "parkingarcade/round-ext")):
                with self.subTest(model=model, role=role, key=key):
                    ref = f"hk:doc/{key}/b1632-sol"
                    process, calls = self.run_spawn(model=model, role=role, ref=ref)
                    self.assertEqual(process.returncode, 91, process.stderr)
                    paths = [c for c in calls if c[:2] == ["policy", "launch"] or c[:2] == ["gate", "-m"]]
                    self.assertEqual(len(paths), 2)
                    for args in paths:
                        self.assertEqual(args[args.index("--operator-request") + 1], ref)
                        self.assertEqual(args[args.index("--purpose") + 1], "round-extension")
                        self.assertEqual(args[args.index("--role") + 1], role)

    def test_purpose_and_ref_require_each_other(self):
        self.assert_denied(ref=None)
        self.assert_denied(purpose=None)
        self.assert_denied(ref=None, purpose=" Round-Extension ",
                           extra=("--operator-request", REF))
        for purpose in ("\u2003round-extension\u2003", "round-exten\u017fion"):
            with self.subTest(purpose=purpose):
                self.assert_denied(model="fable", ref=None, purpose=purpose,
                                   extra=("--operator-request", REF))
                self.assert_denied(model="fable", ref=None, purpose=purpose,
                                   extra=("--operator-request", REF),
                                   environment={"LC_ALL": "C", "PYTHONUTF8": "1"})

    def test_wrong_ref_shape_or_job_never_calls_gate(self):
        for ref in ("hk:task/5", "hk:doc/other/b1632-sol", "hk:doc/round-ext/other-task",
                    "hk:doc/ParkingArcade/round-ext/b1632-sol", REF + "/child", REF + "\n"):
            with self.subTest(ref=ref):
                self.assert_denied(ref=ref)

    def test_narrowed_ref_grammar_refuses_before_quota(self):
        for job in ("B1632-Sol", ".job", "_job", "-job", ".", "..", "j" * 128):
            with self.subTest(job=job):
                reason = self.assert_denied(ref="hk:doc/round-ext/" + job,
                                           extra=("--parent-job", job))
                self.assertIn("lowercase JOB", reason)

    def test_task_json_must_be_unambiguous(self):
        valid = {"state": "claimed", "claimed_by": "", "refs": {"job_id": "b1632-sol"}}
        replies = [
            {"state": "claimed", "claimed_by": "x\tb1632-sol", "refs": {}},
            {"state": "x\ty\tb1632-sol", "claimed_by": "", "refs": {}},
            {**valid, "state": "claimed\n"},
            {**valid, "claimed_by": "x\x7f"},
            {**valid, "refs": {"job_id": "b1632-sol", "other": {"value": "x\t"}}},
            {"state": "claimed", "refs": valid["refs"]},
            {"claimed_by": "", "refs": valid["refs"]},
            {"state": "claimed", "claimed_by": ""},
            {**valid, "refs": []},
            {**valid, "refs": {}},
        ]
        for reply in replies:
            with self.subTest(reply=reply):
                self.assertIn("ownership denied", self.assert_denied(
                    environment={"TASK_REPLY": json.dumps(reply)}))
        for reply in ("not JSON", "[]", '{"state":"claimed","state":"open"}',
                      json.dumps(valid)[:-1] + ',"other":NaN}'):
            with self.subTest(raw=reply):
                self.assert_denied(environment={"TASK_REPLY": reply})
        process, _ = self.run_spawn(environment={"TASK_REPLY": json.dumps(valid)})
        self.assertEqual(process.returncode, 91, process.stderr)

    def test_document_server_issuer_is_required(self):
        for issuer in ("mac-dev", "builder-sol", "", "pa-integrator"):
            with self.subTest(issuer=issuer):
                self.assertIn("issuer denied", self.assert_denied(environment={"DOC_ISSUER": issuer}))
        for issuer in ("director-1", "operator", "operator-desk"):
            with self.subTest(issuer=issuer):
                process, _ = self.run_spawn(environment={"DOC_ISSUER": issuer})
                self.assertEqual(process.returncode, 91, process.stderr)
        claim = self.base / "jobs/b1632-sol/events/00001-job.claim.json"
        claim.write_text(json.dumps({"kind": "job.claim", "payload": {
            "task_id": "1632", "parent_lane": "pa-integrator"}}))
        reply = {"state": "claimed", "claimed_by": "", "project": "ParkingArcade",
                 "refs": {"job_id": "b1632-sol"}}
        process, _ = self.run_spawn(environment={"DOC_ISSUER": "pa-integrator",
                                                "TASK_REPLY": json.dumps(reply)})
        self.assertEqual(process.returncode, 91, process.stderr)
        reply["project"] = "other"
        self.assert_denied(environment={"DOC_ISSUER": "pa-integrator", "TASK_REPLY": json.dumps(reply)})

    def test_tester_reviewer_cannot_use_counsel_purposes_without_grant(self):
        for model in ("codex-astra", "fable"):
            for role in ("tester", "reviewer"):
                for purpose in (None, "architect", "director", "operator-request"):
                    with self.subTest(model=model, role=role, purpose=purpose):
                        self.assert_denied(model=model, role=role, purpose=purpose, ref=None,
                                           extra=("--operator-request", "hk:doc/ordinary/request"))
            process, _ = self.run_spawn(model=model, role="counsel", purpose="architect", ref=None,
                                       extra=("--operator-request", "hk:doc/ordinary/request"))
            self.assertEqual(process.returncode, 91, process.stderr)

    def test_worker_and_builder_seats_never_unlock(self):
        for model in ("codex-astra", "fable", "builder-astra", "captain-astra"):
            for role in ("worker", "builder", "captain"):
                with self.subTest(model=model, role=role):
                    self.assert_denied(model=model, role=role)

    def test_astra_effort_pinned(self):
        for effort in ("low", "medium", "high", "max", "ultra"):
            with self.subTest(effort=effort):
                self.assertIn("xhigh", self.assert_denied(extra=("--effort", effort)))

    def test_other_models_cannot_use_grant(self):
        self.assert_denied(model="codex-sol")
        self.assert_denied(model="opus")

    def test_hk_failures_and_cross_task_ownership_fail_closed(self):
        for mode in ("down", "missing", "garbage", "wrong-owner"):
            with self.subTest(mode=mode):
                self.assert_denied(environment={"HK_MODE": mode})
        self.assert_denied(environment={"HK_TASK_ID": "1633"})
        self.assert_denied(extra=("--task-hk-bypass",))

    def test_fable_purpose_alone_is_refused(self):
        self.assert_denied(model="fable", ref=None)

    def test_quota_refusal_still_stops_spawn(self):
        process, _ = self.run_spawn(environment={"QUOTA_RC": "3"})
        self.assertEqual(process.returncode, 3, process.stderr)

    def test_router_preserves_flag(self):
        process, calls = self.run_spawn(router=True)
        self.assertEqual(process.returncode, 91, process.stderr)
        self.assertTrue(any(REF in c for c in calls))

    def test_child_roles_keep_worker_lane_topology_and_global_role(self):
        for role in ("tester", "reviewer", "counsel", "unrecognized"):
            with self.subTest(role=role):
                process = subprocess.run(["bash", "-c", '''source "$1"
ROLE="$2" LABEL=fixture-tester LANE_DEFER=fixture-machine
hub_lane_register
printf '%s|%s|%s' "$ROLE" "$HUB_LANE" "$HUB_LANE_MACHINE"
''', "fixture", str(self.lib), role], env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(process.returncode, 0, process.stderr)
                expected = f"{role}|fixture-tester|fixture-machine" if role != "unrecognized" else role + "||"
                self.assertEqual(process.stdout, expected)

    def test_help_and_unknown_role_match_expanded_role_contract(self):
        process = subprocess.run(["bash", "-c", 'source "$1"; spawn_help', "fixture", str(self.lib)],
                                 env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("--role worker|builder|tester|reviewer|counsel (legacy alias: captain)", process.stdout)
        self.assertIn("--role accepts worker, builder, tester, reviewer or counsel (legacy alias: captain)",
                      self.assert_denied(role="observer"))

    def test_unrelated_spawn_does_not_add_a_python_prerequisite(self):
        process = subprocess.run(["bash", "-c", '''source "$1"
PURPOSE="" ROUND_EXT_REF=""
python3() { return 42; }
round_ext_validate
printf 'unrelated-pass'
''', "fixture", str(self.lib)], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stdout, "unrelated-pass")


if __name__ == "__main__":
    unittest.main()
