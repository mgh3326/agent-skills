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
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.base), "CODEX_HOME": str(self.base / "codex"),
                    "HK_TASK_ID": "1632", "ARBITER_INBOX_ROOT": str(self.base / "jobs"),
                    "HANDOFFKEEP_BIN": str(self.base / "hk"),
                    # hk 1894: round_ext_precheck honours these temp overrides only in test mode.
                    "WRK_TEST_MODE": "1", "TMPDIR": tempfile.gettempdir(),
                    "SCOPEFUEL_BIN": str(self.base / "scopefuel"),
                    "CALL_LOG": str(self.log)}
        old = json.loads((ROOT / "tests/fixtures/scopefuel-hk1632-builder.json").read_text())
        self.env["HK1632_REPLIES"] = json.dumps(old["responses"])
        for key in ("CONFIG", "DATA", "STATE", "CACHE", "RUNTIME"):
            self.env[f"XDG_{key}_HOME" if key != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(self.base / key)
        source = (ROOT / "bin/wrk").read_text().rsplit('case "${1:-}" in', 1)[0]
        self.lib = self.base / "wrk-lib"
        self.lib.write_text(source)
        events = self.base / "jobs/b1632-sol/events"
        events.mkdir(parents=True)
        (events / "00001-job.claim.json").write_text(json.dumps({"job_id": "b1632-sol",
            "kind": "job.claim", "payload": {"task_id": "1632", "owner_lane": "fixture-builder", "parent_lane": "director-1"}}))
        self.prompt = self.base / "brief.md"
        self.prompt.write_text("inert fixture")
        self.stub("hk", '''import json, os, sys
from pathlib import Path
with Path(os.environ["CALL_LOG"]).open("a") as f: f.write(json.dumps(sys.argv[1:]) + "\\n")
mode = os.environ.get("HK_MODE", "ok")
if (Path(os.environ["CALL_LOG"]).parent / "reclaimed").exists() and os.environ.get("AUTH_CHANGE") != "issuer": mode = "wrong-owner"
if mode == "down": raise SystemExit(1)
if sys.argv[1:3] == ["doc", "get"]:
    if "DOC_REPLY" in os.environ: print(os.environ["DOC_REPLY"]); raise SystemExit(0)
    if mode == "missing": print("not_found"); raise SystemExit(1)
    if mode == "garbage": print("{}"); raise SystemExit(0)
    doc = {"key": sys.argv[3], "body": "round extension record"}
    if os.environ.get("DOC_ISSUER") != "missing-field":
        doc["created_by"] = os.environ.get("DOC_ISSUER", "director-1")
    if (Path(os.environ["CALL_LOG"]).parent / "reclaimed").exists() and os.environ.get("AUTH_CHANGE") == "issuer":
        doc["created_by"] = "builder-sol"
    print(json.dumps(doc))
elif sys.argv[1:3] == ["tasks", "show"]:
    if "TASK_REPLY" in os.environ: print(os.environ["TASK_REPLY"]); raise SystemExit(0)
    print(json.dumps({"state": "in_progress", "claimed_by": "fixture-builder",
        "project": "ParkingArcade", "id": int(sys.argv[3]),
        "refs": {"job_id": "other-task" if mode == "wrong-owner" else "b1632-sol"}}))
else: raise SystemExit("unexpected hk mutation")
''')
        self.stub("scopefuel", '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["CALL_LOG"]).open("a") as f: f.write(json.dumps(args) + "\\n")
if args[:2] == ["policy", "launch"]:
    if os.environ.get("CATALOG_MODE") == "hk1632":
        print(json.dumps(json.loads(os.environ["HK1632_REPLIES"])[args[2]])); raise SystemExit(0)
    if os.environ.get("CATALOG_MODE") == "old": raise SystemExit(2)
    if os.environ.get("CATALOG_MODE") == "refused": raise SystemExit(3)
    if os.environ.get("CATALOG_MODE") == "malformed": print("{}"); raise SystemExit(0)
    payload = {"model_id": "gpt-6-astra" if args[2] == "codex-astra" else "claude-fable-5-1",
        "effort": "xhigh" if args[2] == "codex-astra" else "",
        "catalog": {"source": "fixture", "stale": False}}
    if "--role" in args and args[args.index("--role") + 1] == "builder":
        payload["round_extension_builder"] = {"policy": "hk1672/v1", "profile": args[2],
            "role": "builder", "purpose": "round-extension", "ref": args[args.index("--operator-request") + 1]}
        if "SUPPORT_REPLY" in os.environ: payload["round_extension_builder"] = json.loads(os.environ["SUPPORT_REPLY"])
    print(json.dumps(payload))
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
                  purpose="round-extension", extra=(), environment=None, router=False, launch=False,
                  report=True, remote_preflight=False):
        self.log.unlink(missing_ok=True)
        args = ["-c", str(self.base), "-m", model, "-p", str(self.prompt), "-w", "fixture",
                "-l", "fixture-tester", "--t", "T3"]
        if role is not None:
            args += ["--role", role]
        if role == "builder":
            args += ["--task", "1632", "--job", "b1632-sol", "--lane", "fixture-builder", "--parent", "director-1"]
        else:
            args += ["--parent-job", "b1632-sol"]
            if report:
                args += ["--report", str(self.base / "jobs/b1632-sol/tester-report.md")]
        if ref is not None:
            args += ["--round-ext", ref]
        if purpose is not None:
            args += ["--purpose", purpose]
        args += list(extra)
        harness = '''source "$1"; shift
local_spawn_resolve() { LOCAL_SPAWN_ALLOWED=1; }
warn_if_canonical_off_default() { :; }
arbiter_release_held() { :; }
mock_mcp_cleanup() { :; }
arbiter_admit() { exit 91; }
'''
        if launch:
            self.stub("herdr", '''import json, os, sys
from pathlib import Path
args=sys.argv[1:]
with Path(os.environ["CALL_LOG"]).open("a") as f: f.write(json.dumps(["herdr", *args])+"\\n")
if args[:2] == ["tab", "create"]:
    if os.environ.get("RECLAIM_AT") == "tab": (Path(os.environ["CALL_LOG"]).parent / "reclaimed").touch()
    print(json.dumps({"result": {"root_pane": {"pane_id": "fixture-pane"}, "tab_id": "fixture-tab"}}))
elif args[:2] == ["agent", "start"]:
    if os.environ.get("RECLAIM_AT") == "boot": (Path(os.environ["CALL_LOG"]).parent / "boot-pending").touch()
elif args[:2] != ["pane", "close"]: raise SystemExit("unexpected herdr call")
''')
            self.env["HERDR_BIN"] = str(self.base / "herdr")
            harness += '''
arbiter_admit() {
  printf '["lease","%s","%s","%s","%s"]\\n' "${ARBITER_CLAIM_ROLE_ARGS[@]}" >>"$CALL_LOG"
  if [[ "${RACE_BINDING:-}" == 1 ]]; then export HK_MODE=wrong-owner; fi
}
quota_hub_policy_gate() { :; }
sleep_for() {
  if [[ -f "$(dirname "$CALL_LOG")/boot-pending" ]]; then
    touch "$(dirname "$CALL_LOG")/reclaimed"
    rm "$(dirname "$CALL_LOG")/boot-pending"
  fi
}
devin_wait_shell_ready() {
  if [[ "${RECLAIM_AT:-}" == ready ]]; then touch "$(dirname "$CALL_LOG")/reclaimed"; fi
}
agent_wait_foreground() { :; }
spawn_deliver_brief() { printf '["brief"]\\n' >>"$CALL_LOG"; LANDING=confirmed SPAWN_VIA=fixture; }
agent_status_for_pane() { printf ready; }
hub_lane_register() { HUB_LANE=fixture-builder HUB_LANE_MACHINE=fixture-machine; }
refresh_quota_pool() { :; }
mock_mcp_prepare() { :; }
mock_mcp_verify() { :; }
'''
        if remote_preflight:
            harness += 'spillover_resolve_remote_task "$@"; exit 91'
        else:
            harness += 'spawn_router_cmd --host local "$@"' if router else 'spawn_cmd "$@"'
        process = subprocess.run(["bash", "-c", harness, "fixture", str(self.lib), *args],
            env={**self.env, **(environment or {})}, capture_output=True, text=True, timeout=60)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return process, calls

    def assert_denied(self, **kw):
        process, calls = self.run_spawn(**kw)
        self.assertFalse(any(c[:1] in (["gate"], ["policy"]) for c in calls), calls)
        self.assertEqual(process.returncode, 2, process.stderr)
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

    def test_implicit_counsel_normalized_before_catalog_and_gate(self):
        request = ("--operator-request", "hk:doc/ordinary/request", "--requested-by", "operator")
        for model, purpose, extra in (
            ("codex-astra", None, ()),
            ("codex-astra", "architect", ()),
            ("codex-astra", "director", ()),
            ("codex-astra", "operator-request", request),
            ("fable", None, request),
        ):
            for router in (False, True):
                with self.subTest(model=model, purpose=purpose, router=router):
                    process, calls = self.run_spawn(model=model, role=None, ref=None,
                        purpose=purpose, extra=extra, router=router)
                    self.assertEqual(process.returncode, 91, process.stderr)
                    paths = [c for c in calls if c[:2] in (["policy", "launch"], ["gate", "-m"])]
                    self.assertEqual(len(paths), 2, calls)
                    for args in paths:
                        self.assertEqual(args[args.index("--role") + 1], "counsel")

    def test_remote_preflight_preserves_implicit_counsel_without_report(self):
        for model, purpose, extra in (
            ("codex-astra", None, ()),
            ("codex-astra", "architect", ()),
            ("fable", None, ("--operator-request", "hk:doc/ordinary/request",
                              "--requested-by", "operator")),
        ):
            with self.subTest(model=model, purpose=purpose):
                process, calls = self.run_spawn(model=model, role=None, ref=None,
                    purpose=purpose, extra=extra, report=False, remote_preflight=True)
                self.assertEqual(process.returncode, 91, process.stderr)
                self.assertEqual(calls, [])
        process, _ = self.run_spawn(model="codex-luna", role="worker", ref=None,
            purpose=None, report=False, remote_preflight=True)
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("requires --report", process.stderr)

    def test_parent_symlink_refuses_before_claim_read(self):
        parent = self.base / "jobs/b1632-sol"
        outside = self.base / "outside-parent"
        parent.rename(outside)
        parent.symlink_to(outside, target_is_directory=True)
        for preflight in (False, True):
            for owner in ((), ("--owner", "desk")):
                with self.subTest(preflight=preflight, owner=owner):
                    process, calls = self.run_spawn(remote_preflight=preflight,
                        extra=(*owner, "--report", str(self.base / "jobs/fixture-tester/report.md")))
                    self.assertEqual(process.returncode, 2, process.stderr)
                    self.assertIn("parent job directory must stay in the trusted inbox", process.stderr)
                    self.assertEqual(calls, [])
        # A malformed outside claim must not be read before containment either.
        (outside / "events/00001-job.claim.json").write_text("not JSON")
        process, calls = self.run_spawn(extra=("--owner", "desk"))
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("parent job directory must stay in the trusted inbox", process.stderr)
        self.assertEqual(calls, [])
        parent.unlink()
        parent.symlink_to(parent, target_is_directory=True)
        process, calls = self.run_spawn(extra=("--owner", "desk"))
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("parent job directory must stay in the trusted inbox", process.stderr)
        self.assertEqual(calls, [])

    def test_parent_owner_controls_cannot_reframe_report(self):
        for preflight in (False, True):
            with self.subTest(preflight=preflight):
                process, _ = self.run_spawn(extra=("--owner", "desk"), remote_preflight=preflight)
                self.assertEqual(process.returncode, 91, process.stderr)
                for owner in ("desk\n" + str(self.base / "outside.md"), "desk\tbad"):
                    process, _ = self.run_spawn(extra=("--owner", owner), remote_preflight=preflight)
                    self.assertEqual(process.returncode, 2, process.stderr)
                    self.assertIn("--owner", process.stderr)

    def test_parent_report_symlink_control_characters_are_refused(self):
        alias = self.base / "jobs/b1632-sol/report-alias.md"
        target = self.base / "jobs/b1632-sol/name\npart.md"
        alias.symlink_to(target)
        for preflight in (False, True):
            with self.subTest(preflight=preflight):
                process, _ = self.run_spawn(extra=("--report", str(alias)), remote_preflight=preflight)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn("--report", process.stderr)

    def test_implicit_round_extension_requires_explicit_role(self):
        for model in ("codex-astra", "fable"):
            for purpose, ref in (("round-extension", None), (None, REF), ("round-extension", REF),
                                 (" Round-Extension ", None)):
                for extra in ((), ("--operator-request", REF, "--requested-by", "operator")):
                    with self.subTest(model=model, purpose=purpose, ref=ref, extra=extra):
                        self.assert_denied(model=model, role=None, purpose=purpose, ref=ref, extra=extra)

    def test_implicit_role_does_not_grant_other_astra_purposes(self):
        for purpose in ("builder", "worker"):
            self.assert_denied(model="codex-astra", role=None, ref=None, purpose=purpose)
        for purpose in (None, "architect"):
            for extra in ((), ("--requested-by", "operator")):
                reason = self.assert_denied(model="fable", role=None, ref=None, purpose=purpose, extra=extra)
                self.assertIn("astra/fable worker role forbidden", reason)

        # Actual committed gate fixture: explicit counsel retains the original
        # orphan-requester and disallowed-purpose errors, with no pane creation.
        for model, purpose, extra, rc, reason in (
            ("fable", None, ("--requested-by", "operator"), 3, "requested_by_requires_operator_request"),
            ("codex-astra", "worker", (), 77, "role_restricted"),
        ):
            process, calls = self.run_spawn(model=model, role="counsel", ref=None,
                purpose=purpose, extra=extra, launch=True,
                environment={"SCOPEFUEL_BIN": str(ROOT / "tests/fixtures/scopefuel")})
            self.assertEqual(process.returncode, rc, process.stderr)
            self.assertIn(reason, process.stderr)
            self.assertFalse(any(c[:1] == ["herdr"] for c in calls), calls)

    def test_ordinary_implicit_worker_and_explicit_counsel_keep_roles(self):
        for model, explicit_role in (("codex-sol", "worker"), ("codex-astra", "counsel")):
            implicit, calls = self.run_spawn(model=model, role=None, ref=None, purpose=None)
            explicit, other_calls = self.run_spawn(model=model, role=explicit_role, ref=None, purpose=None)
            self.assertEqual(implicit.returncode, 91, implicit.stderr)
            self.assertEqual((implicit.returncode, implicit.stdout, implicit.stderr, calls),
                             (explicit.returncode, explicit.stdout, explicit.stderr, other_calls))

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
            {**valid, "claimed_by": "x\u200b"},
            {**valid, "refs": {"job_id": "b1632-sol", "note": "x\u2028"}},
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
        for issuer in ("mac-dev", "builder-sol", "", "pa-integrator", "missing-field"):
            with self.subTest(issuer=issuer):
                self.assertIn("issuer denied", self.assert_denied(environment={"DOC_ISSUER": issuer}))
        for issuer in ("director-1", "operator", "operator-desk"):
            with self.subTest(issuer=issuer):
                process, _ = self.run_spawn(environment={"DOC_ISSUER": issuer})
                self.assertEqual(process.returncode, 91, process.stderr)
        claim = self.base / "jobs/b1632-sol/events/00001-job.claim.json"
        claim.write_text(json.dumps({"kind": "job.claim", "payload": {
            "task_id": "1632", "owner_lane": "fixture-builder", "parent_lane": "pa-integrator"}}))
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

    def test_worker_captain_and_removed_aliases_never_unlock(self):
        for model in ("codex-astra", "fable", "builder-astra", "captain-astra"):
            for role in ("worker", "captain"):
                for ref, purpose in ((REF, "round-extension"), (None, "architect"), (None, "director"),
                                     (None, "operator-request"), (None, None)):
                    with self.subTest(model=model, role=role, ref=ref, purpose=purpose):
                        self.assert_denied(model=model, role=role, ref=ref, purpose=purpose,
                            extra=("--operator-request", "hk:doc/ordinary/request") if ref is None else ())
            if model in ("builder-astra", "captain-astra"):
                self.assertIn(f"--role builder rejects astra profile '{model}'",
                              self.assert_denied(model=model, role="builder"))

    def test_builder_requires_verified_pair_before_catalog_and_gate(self):
        for model in ("codex-astra", "fable"):
            for purpose in (None, "builder", "architect", "director", "operator-request", "round-extension"):
                with self.subTest(model=model, purpose=purpose):
                    reason = self.assert_denied(model=model, role="builder", purpose=purpose, ref=None)
                    self.assertIn("role condition, not quota", reason)
            for environment in ({"DOC_ISSUER": "mac-dev"}, {"DOC_ISSUER": "builder-sol"},
                                {"HK_MODE": "wrong-owner"}, {"HK_MODE": "missing"}):
                self.assert_denied(model=model, role="builder", environment=environment)
            self.assert_denied(model=model, role="builder", ref="hk:doc/round-ext/other-job")
            self.assert_denied(model=model, role="builder", extra=("--task-hk-bypass",))
            for flag in ("--task", "--lane", "--parent"):
                self.assert_denied(model=model, role="builder", extra=(flag, ""))
            process, calls = self.run_spawn(model=model, role="builder")
            self.assertEqual(process.returncode, 91, process.stderr)
            self.assertEqual(len([c for c in calls if c[:1] == ["policy"]]), 1)
            self.assertEqual(len([c for c in calls if c[:2] == ["gate", "-m"]]), 1)

    def test_builder_strict_current_task_binding(self):
        valid = {"id": 1632, "state": "claimed", "claimed_by": "", "project": "ParkingArcade",
                 "refs": {"job_id": "b1632-sol"}}
        replies = [
            {**valid, "id": 1633}, {**valid, "refs": {}},
            {**valid, "refs": {"job_id": "previous-job"}},
            {**valid, "state": "claimed\n"}, {**valid, "claimed_by": "x\t"},
            {**valid, "refs": {"job_id": "b1632-sol", "extra": {"x": "\u200b"}}},
            {**valid, "refs": []}, {**valid, "state": None}, {**valid, "claimed_by": None},
            {"state": "claimed", "refs": valid["refs"]},
        ]
        raw = [json.dumps(reply) for reply in replies] + ["not JSON", "[]",
            '{"state":"claimed","claimed_by":"","refs":{"job_id":"b1632-sol","job_id":"other"}}',
            json.dumps(valid)[:-1] + ',"bad":NaN}']
        for model in ("codex-astra", "fable"):
            for reply in raw:
                with self.subTest(model=model, reply=reply):
                    self.assertIn("ownership denied", self.assert_denied(model=model, role="builder",
                        environment={"TASK_REPLY": reply}))
            for state in ("merged", "dropped", "hold", "needs_decision"):
                self.assert_denied(model=model, role="builder",
                    environment={"TASK_REPLY": json.dumps({**valid, "state": state})})
            self.assert_denied(model=model, role="builder", ref="hk:doc/other/round-ext/b1632-sol",
                environment={"TASK_REPLY": json.dumps(valid)})

    def test_builder_newest_recorded_parent_and_parkingarcade_restriction(self):
        events = self.base / "jobs/b1632-sol/events"
        newest = events / "00002-job.reclaim.json"
        newest.write_text(json.dumps({"kind": "job.reclaim", "payload": {
            "task_id": "1632", "owner_lane": "fixture-builder", "parent_lane": "pa-integrator"}}))
        self.assert_denied(role="builder")  # Old director-1 parent no longer authorizes.
        for issuer in ("operator", "operator-desk", "pa-integrator"):
            process, _ = self.run_spawn(role="builder", environment={"DOC_ISSUER": issuer})
            self.assertEqual(process.returncode, 91, process.stderr)
        reply = {"state": "claimed", "claimed_by": "", "project": "other", "refs": {"job_id": "b1632-sol"}}
        self.assert_denied(role="builder", environment={"DOC_ISSUER": "pa-integrator", "TASK_REPLY": json.dumps(reply)})
        newest.write_text("not JSON")
        self.assert_denied(role="builder")
        newest.write_text(json.dumps({"kind": "job.reclaim", "payload": {
            "task_id": "1633", "parent_lane": "director-1"}}))
        for issuer in ("operator", "director-1"):
            self.assert_denied(role="builder", environment={"DOC_ISSUER": issuer})

    def test_builder_ambiguous_document_never_authorizes(self):
        for reply in ("[]", "not JSON", '{"body":"x","created_by":"operator"}',
                      '{"key":"round-ext/b1632-sol","body":"x","created_by":"builder-sol","created_by":"operator"}'):
            self.assert_denied(role="builder", environment={"DOC_REPLY": reply})

    def test_builder_exact_launch_lines_and_builder_lease(self):
        for model, kind, argv in (
            ("codex-astra", "codex", ["--yolo", "-m", "gpt-6-astra", "-c", "model_reasoning_effort=xhigh"]),
            ("fable", "claude", ["--model", "claude-fable-5-1", "--dangerously-skip-permissions"]),
        ):
            with self.subTest(model=model):
                process, calls = self.run_spawn(model=model, role="builder", launch=True)
                self.assertEqual(process.returncode, 0, process.stderr)
                starts = [c for c in calls if c[:3] == ["herdr", "agent", "start"]]
                self.assertEqual(len(starts), 1, calls)
                self.assertEqual(starts[0][:8], ["herdr", "agent", "start", "fixture-tester", "--kind", kind,
                                              "--pane", "fixture-pane"])
                self.assertEqual(starts[0][10:], ["--", *argv])
                self.assertIn(["lease", "--role", "builder", "--parent-lane", "director-1"], calls)
                self.assertFalse(any(c[:2] == ["tasks", "claim"] for c in calls))

    def test_builder_rechecks_binding_after_admission_before_pane(self):
        process, calls = self.run_spawn(role="builder", launch=True, environment={"RACE_BINDING": "1"})
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("ownership denied", process.stderr)
        self.assertTrue(any(c[:1] == ["policy"] for c in calls))
        self.assertFalse(any(c[:1] == ["herdr"] for c in calls), calls)

    def test_builder_old_scopefuel_never_falls_back_to_local_table(self):
        for mode in ("old", "refused", "malformed"):
            process, calls = self.run_spawn(role="builder", launch=True, environment={"CATALOG_MODE": mode})
            self.assertEqual(process.returncode, 2, process.stderr)
            self.assertIn("scopefuel policy launch", process.stderr)
            self.assertFalse(any(c[:1] == ["herdr"] for c in calls), calls)

    def test_actual_hk1632_response_cannot_authorize_builder(self):
        old = json.loads(self.env["HK1632_REPLIES"])
        for model, effort in (("codex-astra", "xhigh"), ("fable", "")):
            with self.subTest(model=model):
                self.assertEqual(old[model]["effort"], effort)
                self.assertEqual(old[model]["model_id"],
                    "gpt-6-astra" if model == "codex-astra" else "claude-fable-5-1")
                self.assertIn("source", old[model]["catalog"])
                self.assertNotIn("round_extension_builder", old[model])
                process, calls = self.run_spawn(model=model, role="builder", launch=True,
                    environment={"CATALOG_MODE": "hk1632"})
                self.assertFalse(any(c[:1] == ["herdr"] or c[:2] == ["gate", "-m"] for c in calls), calls)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn("hk1672/v1 support evidence", process.stderr)

    def test_builder_support_evidence_binds_the_entire_request(self):
        valid = {"policy": "hk1672/v1", "profile": "codex-astra", "role": "builder",
                 "purpose": "round-extension", "ref": REF}
        bad = [None, True, {}, {**valid, "extra": True}]
        bad += [{**valid, field: "wrong"} for field in valid]
        for reply in bad:
            with self.subTest(reply=reply):
                process, calls = self.run_spawn(role="builder", launch=True,
                    environment={"SUPPORT_REPLY": json.dumps(reply)})
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertFalse(any(c[:1] == ["herdr"] for c in calls), calls)

    def test_reclaim_during_tab_or_readiness_closes_pane_without_start_or_brief(self):
        for model in ("codex-astra", "fable"):
            for phase in ("tab", "ready"):
                for authority in ("binding", "issuer"):
                    with self.subTest(model=model, phase=phase, authority=authority):
                        (self.base / "reclaimed").unlink(missing_ok=True)
                        process, calls = self.run_spawn(model=model, role="builder", launch=True,
                            environment={"RECLAIM_AT": phase, "AUTH_CHANGE": authority})
                        self.assertFalse(any(c[:3] == ["herdr", "agent", "start"] for c in calls), calls)
                        self.assertNotIn(["brief"], calls)
                        self.assertEqual(process.returncode, 2, process.stderr)
                        if authority == "issuer":
                            self.assertIn("issuer denied", process.stderr)
                        self.assertIn(["herdr", "pane", "close", "fixture-pane"], calls)

    def test_reclaim_during_boot_closes_started_pane_before_brief(self):
        for model in ("codex-astra", "fable"):
            for authority in ("binding", "issuer"):
                with self.subTest(model=model, authority=authority):
                    (self.base / "reclaimed").unlink(missing_ok=True)
                    process, calls = self.run_spawn(model=model, role="builder", launch=True,
                        environment={"RECLAIM_AT": "boot", "AUTH_CHANGE": authority})
                    self.assertNotIn(["brief"], calls)
                    self.assertEqual(process.returncode, 2, process.stderr)
                    if authority == "issuer":
                        self.assertIn("issuer denied", process.stderr)
                    self.assertTrue(any(c[:3] == ["herdr", "agent", "start"] for c in calls))
                    self.assertIn(["herdr", "pane", "close", "fixture-pane"], calls)

    def test_project_namespace_is_builder_only_and_malformed_project_is_controlled(self):
        reply = {"state": "claimed", "claimed_by": "", "project": "Other", "refs": {"job_id": "b1632-sol"}}
        ref = "hk:doc/parkingarcade/round-ext/b1632-sol"
        for role in ("tester", "reviewer", "counsel"):
            process, _ = self.run_spawn(role=role, ref=ref, environment={"TASK_REPLY": json.dumps(reply)})
            self.assertEqual(process.returncode, 91, process.stderr)
        for project in ("Other", None, {}, 42):
            process, _ = self.run_spawn(role="builder", ref=ref,
                environment={"TASK_REPLY": json.dumps({**reply, "project": project})})
            self.assertEqual(process.returncode, 2, process.stderr)
            self.assertIn("ownership denied", process.stderr)
            self.assertNotIn("Traceback", process.stderr)

    def test_removed_alias_diagnostics_match_original_role_context(self):
        reason = ("astra is limited to director judgment, architect counsel and operator-requested advice "
                  "(hk:doc decision/2026-09-21/astra-allowed-purposes-approved)")
        for model in ("builder-astra", "captain-astra"):
            for role in ("builder", "worker", "counsel"):
                expected = (f"wrk: --role builder rejects astra profile '{model}': {reason}\n" if role == "builder"
                            else f"wrk: profile '{model}' was removed: {reason}; use codex-astra\n")
                self.assertEqual(self.assert_denied(model=model, role=role, ref=None, purpose=None), expected)

    def test_existing_released_reclaim_keeps_job_and_records_replacement_model(self):
        self.stub("arbiter", '''import json, os, sys
from pathlib import Path
args=sys.argv[1:]
with Path(os.environ["CALL_LOG"]).open("a") as f: f.write(json.dumps(args)+"\\n")
if args[:1] == ["job-get"]:
    print(json.dumps({"job_id": "b1632-sol", "state": os.environ.get("DUP_STATE", "released"),
                      "owner_lane": "old-builder", "created_at": "2026-10-18T00:00:00Z"}))
elif args[:1] not in (["claim"], ["event"]): raise SystemExit("unexpected arbiter call")
''')
        harness = '''source "$1"
ARBITER="$2" JOB_ID=b1632-sol MODEL="$3" LABEL=replacement JOB_LANE=new-builder JOB_T=T3
ROLE=builder TASK_ID=1632 TASK_LINK_MODE=owner TASK_HK_BYPASS=0 ROUND_EXT_REF="" ROUND_EXT_ISSUER=""
ARBITER_CLAIM_ROLE_ARGS=(--role builder --parent-lane director-1)
ARBITER_CLAIM_TASK_ARGS=(--task-id 1632)
hk_task_precheck
[[ "$TASK_LINK_STATUS" == already_linked ]] || exit 90
arbiter_handle_duplicate_claim
PANE=fixture-pane WS=fixture
arbiter_record_spawn_receipt
'''
        for model in ("codex-astra", "fable"):
            self.log.unlink(missing_ok=True)
            process = subprocess.run(["bash", "-c", harness, "fixture", str(self.lib),
                str(self.base / "arbiter"), model], env=self.env, text=True, capture_output=True, timeout=60)
            self.assertEqual(process.returncode, 0, process.stderr)
            calls = [json.loads(line) for line in self.log.read_text().splitlines()]
            claim = next(c for c in calls if c[:1] == ["claim"])
            self.assertEqual(claim, ["claim", "--reclaim-released", "--job", "b1632-sol", "--agent-label",
                "replacement", "--lane", "new-builder", "--t", "T3", "--role", "builder",
                "--parent-lane", "director-1", "--task-id", "1632"])
            event = next(c for c in calls if c[:1] == ["event"])
            self.assertEqual(json.loads(event[-1])["profile"], model)
        process = subprocess.run(["bash", "-c", harness, "fixture", str(self.lib),
            str(self.base / "arbiter"), "codex-astra"], env={**self.env, "DUP_STATE": "claimed"},
            text=True, capture_output=True, timeout=60)
        self.assertEqual(process.returncode, 74, process.stderr)

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

    def test_shared_scopefuel_fixture_accepts_role_contract(self):
        fixture = str(ROOT / "tests/fixtures/scopefuel")
        policy = [fixture, "policy", "launch", "codex-astra", "--json",
                  "--role", "worker", "--purpose", "architect"]
        gate = [fixture, "gate", "-m", "codex-astra", "--role", "worker", "--purpose", "architect"]
        for args, mode, expected in ((policy, "ok", 0), (gate, "ok", 0), (policy, "refused", 3)):
            with self.subTest(args=args, mode=mode):
                process = subprocess.run(args, env={**self.env, "WRK_LAUNCH_MODE": mode},
                                         capture_output=True, text=True, timeout=60)
                self.assertEqual(process.returncode, expected, process.stderr)

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
