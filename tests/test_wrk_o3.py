"""hk 1926 (O3 C1): the wrk journal adapter, its projections and the import tooling.

Design: hk:doc designs/hk1873/b1873a-sol-r4, body sha256 DESIGN_SHA below. The
M1 pack (handoffkeep testdata/o3 at 28c34a6, the hk 2049 revision) is vendored byte-exact under
tests/fixtures/o3/pack and pinned by its MANIFEST sha.

Every run is hermetic: WRK_TEST_MODE=1, HOME, every XDG dir, CODEX_HOME,
ARBITER_INBOX_ROOT and TMPDIR under one temp root, and the transport is the
stub CLI tests/fixtures/o3/handoffkeep (it refuses to run outside test mode or
with paths outside a temp root). The production-resolution cases run bin/wrk
outside test mode against a fake passwd home (tests/fixtures/trust-home, the
PR 242 hook) with the trust tripwire armed. Spawns stop every detached writer
with tests/lib/tmp-writers.sh before the temp root is removed.

Mutants are applied to a copy of bin/ at the real call site; each named
invariant must turn its named scenario RED.
"""
import base64
import hashlib
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "bin"
STUB = ROOT / "tests" / "fixtures" / "o3" / "handoffkeep"
PACK = ROOT / "tests" / "fixtures" / "o3" / "pack"
TASKS_FIXTURE = ROOT / "tests" / "fixtures" / "handoffkeep"
TRUST_HOOK = ROOT / "tests" / "fixtures" / "trust-home"
DESIGN_SHA = "ce4f6efbe39514bb0bced2d0a66510e646058a66d0d28bbb417af180f375c19d"
PINNED_MANIFEST_SHA = "ee0bbf869e3c62017471f1389e9e4b3113f8d8c02a090ad40e57588193df6d55"
REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir
SENTINEL = "o3-sentinel-value-must-not-leak"
SCRUBBED = ("HANDOFFKEEP_URL", "HANDOFFKEEP_TOKEN", "HANDOFFKEEP_CF_ACCESS_CLIENT_ID",
            "HANDOFFKEEP_CF_ACCESS_CLIENT_SECRET")

sys.path.insert(0, str(ROOT / "tests" / "lib"))


def load_adapter(path=BIN / "wrk_o3.py"):
    import importlib.util
    spec = importlib.util.spec_from_file_location("wrk_o3_under_test_%s" % uuid.uuid4().hex, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ADAPTER = load_adapter()


def safe_path():
    root = os.path.join(REAL_HOME, ".local", "bin")
    keep = [e for e in os.environ.get("PATH", "").split(os.pathsep)
            if e and not os.path.normpath(os.path.abspath(e)).startswith(root)]
    return os.pathsep.join(keep)


def write_exec(path, body, mode=0o755):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(mode)


def mutate(text, old, new):
    if text.count(old) != 1:
        raise AssertionError("mutant anchor must occur exactly once (found %d): %r" % (text.count(old), old))
    return text.replace(old, new)


class World(object):
    """One hermetic temp root: inbox, home, stub server, central wrappers, repo."""

    def __init__(self, case, bindir=BIN, production=False):
        self.case = case
        self.bindir = Path(bindir)
        self.wrk = self.bindir / "wrk"
        self.adapter_py = self.bindir / "wrk_o3.py"
        self.production = production
        parent = os.environ.get("TMPDIR") or "/tmp"
        self.base = Path(os.path.realpath(tempfile.mkdtemp(prefix="o3-", dir=parent)))
        case.addCleanup(self.cleanup)
        self.tmp = self.base / "tmp"
        self.tmp.mkdir()
        if production:
            # The fake passwd home answers pwd.getpwuid (trust-home hook); no
            # override names anything else, so the guard takes canonical paths.
            self.home = self.base / "pwhome"
            self.inbox = self.home / "work" / "herdr-inbox" / "jobs"
            self.hk = self.home / ".local" / "bin" / "handoffkeep"
        else:
            self.home = self.base / "home"
            self.inbox = self.base / "inbox"
            self.hk = self.base / "bin" / "handoffkeep"
        self.inbox.mkdir(parents=True)
        (self.home / ".config" / "wrk").mkdir(parents=True)
        self.state = self.base / "stub.json"
        self.log = self.base / "stub.log"
        self.tasks_state = self.base / "tasks.json"
        self.tasks_log = self.base / "tasks.log"
        # The canonical binary: a 0755 wrapper this uid owns. In production mode
        # it re-enters test mode only for the stub child, which refuses otherwise.
        write_exec(self.hk, "#!/bin/sh\nWRK_TEST_MODE=1 exec python3 '%s' \"$@\"\n" % STUB)
        for role in ("director-1", "operator-desk"):
            write_exec(self.home / ".local" / "bin" / ("hk-" + role),
                       "#!/bin/sh\nO3_STUB_CLIENT=%s exec '%s' \"$@\"\n" % (role, self.hk))
        self.spy_dir = self.base / "spy"
        self.spy_log = self.base / "spy.log"
        write_exec(self.spy_dir / "handoffkeep",
                   "#!/bin/sh\necho \"$*\" >>'%s'\necho 'handoffkeep wrk: transport_unavailable' >&2\nexit 75\n"
                   % self.spy_log)
        self.repo = self.base / "repo"
        self.heads = self._repo()
        self.prompt = self.base / "prompt.md"
        self.prompt.write_text("fixture prompt\n")
        subprocess.run([str(TASKS_FIXTURE), "tasks", "add", "--id", "2400", "--title", "t", "--lane", "fixture"],
                       env=dict(os.environ, HK_STATE=str(self.tasks_state)), check=True,
                       stdout=subprocess.DEVNULL)

    def _repo(self):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True, env=env)
        heads = []
        for i in range(6):
            subprocess.run(["git", "-C", str(self.repo), "-c", "user.email=t@t", "-c", "user.name=t", "commit",
                            "-q", "--allow-empty", "-m", "c%d" % i], check=True, env=env)
            heads.append(subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], check=True, env=env,
                                        stdout=subprocess.PIPE, text=True).stdout.strip())
        return heads

    def cleanup(self):
        script = ". '%s'; TW_TMP='%s'; tmp_writers_stop" % (ROOT / "tests" / "lib" / "tmp-writers.sh", self.base)
        subprocess.run(["bash", "-c", script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(self.base, True)

    # -- environment --

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items()
               if k not in ("ARBITER_JOB", "HK_TASK_ID", "WRK_O3_TEST_FAULT") and not k.startswith("HANDOFFKEEP")
               and not k.startswith("O3_STUB")}
        env.update({"PATH": safe_path(), "TMPDIR": str(self.tmp), "XDG_CONFIG_HOME": str(self.base / "xdg-config"),
                    "XDG_CACHE_HOME": str(self.base / "xdg-cache"), "XDG_STATE_HOME": str(self.base / "xdg-state"),
                    "CODEX_HOME": str(self.base / "codex"), "O3_STUB_STATE": str(self.state),
                    "O3_STUB_LOG": str(self.log), "HK_STATE": str(self.tasks_state), "HK_LOG": str(self.tasks_log),
                    "WRK_NO_SLEEP": "1", "WRK_JOB_DELEGATE": "0", "PANEWIRE_BIN": str(self.base / "no-panewire"),
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"})
        if self.production:
            env.pop("WRK_TEST_MODE", None)
            env.update({"HOME": str(self.home), "PYTHONPATH": str(TRUST_HOOK), "TRUST_FAKE_HOME": str(self.home),
                        "TRUST_TRIPWIRE_LOG": str(self.base / "tripwire.log")})
            for key in ("ARBITER_INBOX_ROOT", "XDG_DATA_HOME"):
                env.pop(key, None)
        else:
            env.update({"WRK_TEST_MODE": "1", "HOME": str(self.home), "ARBITER_INBOX_ROOT": str(self.inbox),
                        "XDG_DATA_HOME": str(self.base / "xdg-data"), "HANDOFFKEEP_BIN": str(self.hk)})
        for key, value in extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        return env

    def mode(self, word):
        path = self.home / ".config" / "wrk" / "records-mode"
        if word is None:
            if path.exists():
                path.unlink()
        else:
            path.write_text(word + "\n")

    def run(self, *args, **extra):
        stdin = extra.pop("stdin", None)
        return subprocess.run([str(self.wrk)] + [str(a) for a in args], env=self.env(**extra), input=stdin,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=240)

    def adapter(self, *args, **extra):
        return subprocess.run([sys.executable, str(self.adapter_py)] + [str(a) for a in args], env=self.env(**extra),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=240)

    def spawn(self, *args, model="codex-luna", label="fixture", tier="T1", **extra):
        env = dict(HERDR_BIN=ROOT / "tests" / "fixtures" / "herdr", SCOPEFUEL_BIN=ROOT / "tests" / "fixtures" / "scopefuel",
                   ARBITER_BIN=BIN / "arbiter", WRK_COMPLETION_INTERVAL_S=3600, WRK_FIXTURE_SCENARIO="spawn",
                   WRK_FIXTURE_LOG=self.base / "herdr.log", WRK_SCOPEFUEL_LOG=self.base / "scopefuel.log",
                   WRK_REFRESH_LOG=self.base / "refresh.log", WRK_REFRESH_PID_LOG=self.base / "refresh.pids",
                   WRK_REFRESH_TIMEOUT_S=5, WRK_HOSTS_CONFIG=self.base / "no-hosts.toml",
                   CLINEPASS_GATE_KEY_FILE=self.base / "gate-key", HK_MODE="new")
        (self.base / "gate-key").write_text("fixture-gate-key\n")
        env.update(extra)
        return self.run("spawn", "-c", ROOT, "-m", model, "-p", self.prompt, "-w", "w", "-l", label, "--t", tier,
                        *args, **env)

    def herdr_calls(self):
        path = self.base / "herdr.log"
        return path.read_text().splitlines() if path.exists() else []

    # -- stub state and log --

    def stub(self):
        return json.loads(self.state.read_text()) if self.state.exists() else {}

    def set_stub(self, **updates):
        state = self.stub()
        state.setdefault("client_id", "desktop")
        state.setdefault("generation", str(uuid.uuid4()))
        state.setdefault("policy_sha256", hashlib.sha256(b"policy").hexdigest())
        state.setdefault("jobs", {})
        state.update(updates)
        self.state.write_text(json.dumps(state))

    def fault(self, op, action, kind=None, times=1, page=None):
        state = self.stub()
        state.setdefault("faults", []).append({"op": op, "action": action, "kind": kind, "times": times, "page": page})
        self.set_stub(**state)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    def appends(self, kind=None, job=None):
        rows = []
        for call in self.calls():
            argv = call["argv"]
            if argv[:2] == ["wrk", "append"] and (kind is None or argv[argv.index("--kind") + 1] == kind) \
                    and (job is None or argv[2] == job):
                rows.append(call)
        return rows

    def rewrite_records(self, job, change):
        """Apply change(records) to the stub's journal and re-chain every hash,
        as a restored or regressed server would serve it."""
        state = self.stub()
        records = change(state["jobs"][job]["records"])
        previous = "0" * 64
        for record in records:
            record["previous_hash"] = previous
            record["record_hash"] = ADAPTER.record_hash(record)
            previous = record["record_hash"]
        state["jobs"][job]["records"] = records
        self.set_stub(**state)

    def records(self, job):
        return self.stub().get("jobs", {}).get(job, {}).get("records", [])

    def seed(self, job, kind, payload, client="director-1"):
        records = self.records(job)
        claims = [r for r in records if r["kind"] == "claim"]
        args = [str(STUB), "wrk", "append", job, "--kind", kind, "--idempotency-key", str(uuid.uuid4()),
                "--expected-seq", str(len(records)), "--claim-seq", str(claims[-1]["seq"] if claims else 0)]
        env = self.env(WRK_TEST_MODE=1, O3_STUB_CLIENT=client)
        proc = subprocess.run(args, input=json.dumps(payload).encode(), env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
        assert proc.returncode == 0, proc.stderr
        # Seeding is not a client call under test.
        if self.log.exists():
            kept = [line for line in self.log.read_text().splitlines() if json.loads(line)["client"] != client]
            self.log.write_text("".join(line + "\n" for line in kept))
        return json.loads(proc.stdout)["record"]

    def enroll(self, job, host="desktop", role="builder", activate=True, owner="b2400-a", parent="director-1",
               task=2400, tier="T2", review_of=None):
        if not self.state.exists():
            self.set_stub()
        self.seed(job, "claim", {"job_id": job, "owner_lane": owner, "parent_lane": parent, "task_id": task,
                                 "host_client_id": host, "role": role, "tier": tier, "review_of": review_of,
                                 "predecessor_job_id": None, "supersedes": None})
        if activate:
            self.seed(job, "activate", {"reason_code": "initial_activation", "seal_seq": None})

    def grant(self, job, gtype, round_no=None, head=None, earlier=None, tester=None):
        return self.seed(job, "grant", {"grant_type": gtype, "round_no": round_no, "head": head,
                                        "extra": 1 if gtype == "extension" else 0, "earlier_round_no": earlier,
                                        "tester_job_id": tester, "expires_at": "2026-10-30T00:00:00Z",
                                        "reason_code": "test_grant"})

    def local_claim(self, job, owner="b2400-a", parent="director-1", role="builder"):
        events = self.inbox / job / "events"
        events.mkdir(parents=True, exist_ok=True)
        (events / "00001-job.claim.json").write_text(json.dumps({
            "kind": "job.claim", "job_id": job, "created_at": "2026-10-24T00:00:00Z", "owner_lane": owner,
            "label": "lbl", "pane_id": "w:p1", "parent_lane": parent, "role": role, "repo": str(self.repo),
            "task_id": 2400}) + "\n")

    def events(self, job, kind=None):
        directory = self.inbox / job / "events"
        rows = []
        if directory.is_dir():
            for path in sorted(directory.iterdir()):
                if path.suffix == ".json":
                    doc = json.loads(path.read_text())
                    if kind is None or doc.get("kind") == kind:
                        rows.append(doc)
        return rows

    def intents(self, job):
        path = self.inbox / job / "o3-intents.json"
        return json.loads(path.read_text())["intents"] if path.exists() else []

    def verdict_file(self, name, head, verdict="PASS", body="notes\n"):
        path = self.base / name
        path.write_text("VERDICT: %s @%s\n%s" % (verdict, head, body))
        return path

    def enforced_builder(self, job="job-a", mode="required", **kwargs):
        self.mode(mode)
        self.enroll(job, **kwargs)
        self.local_claim(job)
        return job


class O3Case(unittest.TestCase):
    maxDiff = None

    def world(self, **kwargs):
        return World(self, **kwargs)

    def assertRc(self, proc, rc, code=None):
        self.assertEqual(proc.returncode, rc, "stdout=%s\nstderr=%s" % (proc.stdout, proc.stderr))
        if code is not None:
            self.assertIn("o3 %s" % code, proc.stderr)

    def assertNoLeak(self, world, *texts):
        for text in texts:
            self.assertNotIn(SENTINEL, text)
        for path in world.base.rglob("*"):
            if path.is_file() and path.name not in ("stub.log",) and path.stat().st_size < 2_000_000:
                try:
                    self.assertNotIn(SENTINEL, path.read_text(errors="replace"), str(path))
                except (OSError, UnicodeDecodeError):
                    pass


# ── 1. the vendored M1 pack ───────────────────────────────────────────────────


class PackCase(O3Case):
    def test_manifest_is_pinned_and_every_file_matches(self):
        raw = (PACK / "MANIFEST.json").read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), PINNED_MANIFEST_SHA)
        manifest = json.loads(raw)
        self.assertEqual(manifest["design"]["body_sha256"], DESIGN_SHA)
        self.assertEqual(manifest["design"]["key"], "designs/hk1873/b1873a-sol-r4")
        on_disk = sorted(str(p.relative_to(PACK)) for p in PACK.rglob("*") if p.is_file())
        self.assertEqual(sorted(set(manifest["files"]) | {"MANIFEST.json"}), on_disk)
        for name, entry in manifest["files"].items():
            data = (PACK / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"], name)
            self.assertEqual(len(data), entry["bytes"], name)

    def test_adapter_canonical_json_reproduces_every_pack_record_hash(self):
        count = 0
        for path in sorted((PACK / "vectors").glob("*.json")):
            for case in json.loads(path.read_text())["cases"]:
                for record in (case.get("given") or {}).get("records") or []:
                    self.assertEqual(ADAPTER.record_hash(record), record["record_hash"], (path.name, case["name"]))
                    count += 1
        self.assertGreater(count, 400)

    def test_exit_map_matches_the_pack_and_every_server_code(self):
        cli = json.loads((PACK / "cli.json").read_text())
        for row in cli["exit_map"]:
            for code in row["codes"]:
                self.assertEqual(ADAPTER.EXIT[code], row["exit"], code)
        contract = json.loads((PACK / "contract.json").read_text())
        for code in contract["$defs"]["Error"]["properties"]["error"]["enum"]:
            self.assertIn(code, ADAPTER.EXIT, code)
            self.assertIn(code, ADAPTER.SERVER_CODES, code)
        self.assertEqual(ADAPTER.EXIT["round_cap"], 78)
        self.assertEqual(ADAPTER.DEFINITE & {"wrk_unavailable", "wrk_recovery_required"}, set())

    def test_every_pack_request_is_a_valid_durable_intent(self):
        """Each HTTP request body of the pack round-trips through the intent
        validator with its section 5 request digest."""
        seen = 0
        for path in sorted((PACK / "vectors").glob("*.json")):
            for case in json.loads(path.read_text())["cases"]:
                request = case["request"]
                if request.get("type") != "http" or request.get("method") != "POST":
                    continue
                job = request["path"].split("/")[4]
                body = request["body"]
                intent = {"local_id": str(uuid.uuid4()), "job_id": job, "idempotency_key": request["idempotency_key"],
                          "request": body, "request_sha256": ADAPTER.request_sha256(job, body), "state": "pending",
                          "receipt": None, "error": None}
                ADAPTER.check_intents_doc({"version": 1, "intents": [intent]}, job)
                seen += 1
        self.assertGreater(seen, 80)

    def test_contract_payload_key_sets_match_the_adapter(self):
        defs = json.loads((PACK / "contract.json").read_text())["$defs"]
        for kind, keys in ADAPTER.PAYLOAD_KEYS.items():
            self.assertEqual(set(defs["Payload_" + kind]["properties"]), keys, kind)
        self.assertEqual(set(defs["Record"]["oneOf"][0]["properties"]), ADAPTER.RECORD_KEYS)
        self.assertEqual(set(defs["Summary"]["properties"]), ADAPTER.SUMMARY_KEYS)


# The director-1 ruling (pack vs design, E1 to E7): a pack vector that
# contradicts design r4 is a pack defect. Each divergent client-relevant case is
# asserted at the design result and listed here, keyed by file and case. The
# pin below fails if a listed case stops differing (the pack was fixed: drop the
# entry) or if an unlisted case differs.
PACK_DIVERGENCE = {}


class TransportVectorCase(O3Case):
    """Section 6b transport and intents vectors (transport-intents.json),
    each run against the adapter through the real wrk command."""

    observed = {}

    @classmethod
    def tearDownClass(cls):
        vectors = json.loads((PACK / "vectors" / "transport-intents.json").read_text())["cases"]
        if len(cls.observed) != len(vectors):
            return  # a partial run (one test selected) cannot judge the table
        mismatched = set()
        for case in vectors:
            key = ("transport-intents.json", case["name"])
            seen = cls.observed[case["name"]]
            for field in ("exit_code", "stderr_code"):
                if field in case["expect"] and field in seen:
                    allowed = {case["expect"][field], case["expect"].get(field.replace("code", "code_alt"))}
                    if field == "stderr_code" and case["expect"].get("stderr_code_alt"):
                        allowed.add(case["expect"]["stderr_code_alt"])
                    if seen[field] not in allowed:
                        mismatched.add(key)
                        assert PACK_DIVERGENCE.get(key, {}).get(field) == field or \
                            PACK_DIVERGENCE.get(key, {}).get("field") == field, (key, field, seen[field])
        assert mismatched == set(PACK_DIVERGENCE), (mismatched, set(PACK_DIVERGENCE))

    def note(self, name, **seen):
        type(self).observed[name] = seen

    def test_v01_fake_path_or_overridden_binary_refused(self):
        w = self.world(production=True)
        w.enforced_builder()
        shim = w.base / "evil" / "handoffkeep"
        write_exec(shim, "#!/bin/sh\necho called >>'%s'\nexit 0\n" % (w.base / "evil.log"))
        out = w.run("round", "status", "job-a", HANDOFFKEEP_BIN=shim)
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertIn("HANDOFFKEEP_BIN", out.stderr)
        self.assertIn("o3 cli_usage: refusing a trust-bearing operation", out.stderr)
        self.assertFalse((w.base / "evil.log").exists(), "the overriding binary must never run")
        # An innocuous fake PATH entry alone is ignored and the canonical CLI runs.
        out = w.run("round", "status", "job-a", PATH="%s:%s" % (w.spy_dir, safe_path()))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertFalse(w.spy_log.exists(), "the PATH handoffkeep must never run")
        self.assertTrue(w.calls())
        # A group-writable canonical binary is refused before exec.
        os.chmod(w.hk, 0o775)
        before = len(w.calls())
        out = w.run("round", "status", "job-a")
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertIn("group- or world-writable", out.stderr)
        self.assertEqual(len(w.calls()), before)
        self.note("path-fake-or-overridden-binary-refused", exit_code=2, stderr_code="cli_usage")

    def scenario_cursor_pages_use_the_canonical_binary(self, bindir):
        w = self.world(production=True, bindir=bindir)
        w.enforced_builder()
        w.set_stub(page_limit=1)
        for i in range(3):
            w.grant("job-a", "join_waiver", head=w.heads[i])
        out = w.run("round", "status", "job-a", PATH="%s:%s" % (w.spy_dir, safe_path()))
        pages = [c for c in w.calls() if c["argv"][:2] == ["wrk", "records"]]
        return out, w, pages

    def test_v02_every_cursor_page_runs_the_guarded_canonical_binary(self):
        out, w, pages = self.scenario_cursor_pages_use_the_canonical_binary(BIN)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertGreaterEqual(len(pages), 5)
        self.assertTrue(all(c["exe"].endswith("tests/fixtures/o3/handoffkeep") for c in pages))
        self.assertFalse(w.spy_log.exists(), "a cursor page reached the PATH handoffkeep")
        snapshots = {c["argv"][c["argv"].index("--snapshot-seq") + 1] for c in pages if "--snapshot-seq" in c["argv"]}
        self.assertEqual(len(snapshots), 1, "the snapshot must stay fixed across pages")
        self.note("unguarded-hk-bin-lookup-rejected", outcome="spy_rejects")

    def test_v03_env_token_with_cli_unavailable_has_no_fallback(self):
        w = self.world()
        w.enforced_builder()
        out = w.run("round", "open", "job-a", "--head", w.heads[0], HANDOFFKEEP_BIN=w.base / "absent" / "handoffkeep",
                    HANDOFFKEEP_TOKEN=SENTINEL)
        self.assertRc(out, 75, "transport_unavailable")
        self.assertEqual(w.events("job-a", "job.round"), [])
        self.assertNoLeak(w, out.stdout, out.stderr)
        # Production: a missing canonical binary is the trust-path refusal.
        p = self.world(production=True)
        p.enforced_builder()
        p.hk.unlink()
        out = p.run("round", "open", "job-a", "--head", p.heads[0], HANDOFFKEEP_TOKEN=SENTINEL)
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertEqual(p.events("job-a", "job.round"), [])
        self.note("env-token-with-cli-unavailable-no-fallback", exit_code=75, stderr_code="transport_unavailable")

    def stable_refusal(self, code, rc, name):
        w = self.world()
        w.enforced_builder()
        w.fault("append", "error:" + code, kind="round_open")
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, rc, code)
        self.assertNotIn("OK job=", out.stdout)
        self.assertEqual(w.events("job-a", "job.round"), [])
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["rejected"])
        self.assertEqual(w.intents("job-a")[0]["error"], code)
        self.note(name, exit_code=rc, stderr_code=code)
        return w, out

    def test_v04_host_mismatch_exit_77(self):
        self.stable_refusal("host_mismatch", 77, "server-host-mismatch-exit-77")

    def test_v05_round_cap_exit_78_with_the_parent_escalate(self):
        w, out = self.stable_refusal("round_cap", 78, "server-round-cap-exit-78")
        self.assertEqual(len(w.events("job-a", "job.escalate")), 1)

    def test_v06_sequence_conflict_exit_73(self):
        self.stable_refusal("sequence_conflict", 73, "server-sequence-conflict-exit-73")

    def test_v07_lost_response_then_changed_file_resends_the_original(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        vfile = w.verdict_file("v.md", w.heads[0])
        original = vfile.read_bytes()
        w.fault("append", "commit_then:transport_indeterminate", kind="verdict")
        out = w.run("round", "verdict", "job-a", "--file", vfile)
        self.assertRc(out, 75, "transport_indeterminate")
        self.assertEqual(w.events("job-a", "job.verdict"), [])
        pending = [i for i in w.intents("job-a") if i["request"]["kind"] == "verdict"]
        self.assertEqual([i["state"] for i in pending], ["pending"])
        vfile.write_text("VERDICT: BLOCKER @%s\nchanged after the lost reply\n" % w.heads[0])
        out = w.run("round", "verdict", "job-a", "--file", vfile)
        self.assertRc(out, 0)
        sends = w.appends("verdict")
        self.assertEqual(len(sends), 2)
        self.assertEqual(sends[0]["argv"], sends[1]["argv"])
        self.assertEqual(sends[0]["stdin_sha256"], sends[1]["stdin_sha256"])
        verdicts = [r for r in w.records("job-a") if r["kind"] == "verdict"]
        self.assertEqual(len(verdicts), 1)
        self.assertEqual(verdicts[0]["payload"]["content_sha256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(verdicts[0]["payload"]["verdict"], "PASS")
        self.assertEqual([e["content_sha256"] for e in w.events("job-a", "job.verdict")],
                         [hashlib.sha256(original).hexdigest()])
        self.assertIn("original bytes", out.stderr)
        self.note("commit-then-response-lost-file-changed", exit_code=0)

    def test_v08_definitive_sequence_conflict_then_refresh(self):
        w = self.world()
        w.enforced_builder()
        w.fault("append", "error:sequence_conflict", kind="round_open")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 73, "sequence_conflict")
        first = w.intents("job-a")[0]
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, 0)
        intents = w.intents("job-a")
        self.assertEqual(intents[0], first, "the rejected original stays immutable")
        self.assertEqual([i["state"] for i in intents], ["rejected", "accepted"])
        self.assertNotEqual(intents[1]["idempotency_key"], first["idempotency_key"])
        self.note("definitive-sequence-conflict-then-refresh", exit_code=73, stderr_code="sequence_conflict")

    def test_v09_crash_before_send_after_commit_after_fsync(self):
        w = self.world()
        w.enforced_builder()
        # Crash before send: the saved intent is retried once by its key.
        out = w.run("round", "open", "job-a", "--head", w.heads[0], WRK_O3_TEST_FAULT="crash_before_send")
        self.assertEqual(out.returncode, 137)
        self.assertEqual(w.appends("round_open"), [])
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["pending"])
        key = w.intents("job-a")[0]["idempotency_key"]
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        self.assertEqual([c["argv"][c["argv"].index("--idempotency-key") + 1] for c in w.appends("round_open")], [key])
        # Crash after commit: the replay returns the committed record; no new key.
        out = w.run("round", "open", "job-a", "--head", w.heads[1], WRK_O3_TEST_FAULT="crash_after_send")
        self.assertEqual(out.returncode, 137)
        self.assertEqual(len([r for r in w.records("job-a") if r["kind"] == "round_open"]), 2)
        out = w.run("round", "open", "job-a", "--head", w.heads[1])
        self.assertRc(out, 0)
        self.assertIn("resent=pending", out.stdout)
        self.assertEqual(len([r for r in w.records("job-a") if r["kind"] == "round_open"]), 2)
        sends = w.appends("round_open")
        self.assertEqual(sends[-1]["argv"], sends[-2]["argv"])
        # Crash after the accepted-intent fsync: GET-based projection repair.
        out = w.run("round", "open", "job-a", "--head", w.heads[2], WRK_O3_TEST_FAULT="crash_after_accept")
        self.assertEqual(out.returncode, 137)
        self.assertEqual(len(w.events("job-a", "job.round")), 2)
        appends_before = len(w.appends())
        out = w.run("round", "status", "job-a")
        out = w.run("round", "verdict", "job-a", "--file", w.verdict_file("r1.md", w.heads[0]))
        self.assertRc(out, 0)
        rounds = w.events("job-a", "job.round")
        self.assertEqual(len(rounds), 3)
        self.assertEqual(rounds[-1]["o3_provenance"], "server_repair")
        self.assertEqual(len(w.appends()), appends_before + 1, "repair never submits a new operation")
        self.note("crash-before-send-after-commit-after-fsync", outcome="intent_retry")

    def test_v10_intent_file_tricks_refuse_before_send(self):
        def fresh():
            w = self.world()
            w.enforced_builder()
            self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
            return w, w.inbox / "job-a" / "o3-intents.json"

        cases = []
        w, path = fresh()
        target = w.base / "elsewhere.json"
        target.write_text(path.read_text())
        os.chmod(target, 0o600)
        path.unlink()
        path.symlink_to(target)
        cases.append((w, "symlink"))
        w, path = fresh()
        os.chmod(path, 0o644)
        cases.append((w, "mode"))
        w, path = fresh()
        path.write_text("{not json")
        os.chmod(path, 0o600)
        cases.append((w, "malformed"))
        w, path = fresh()
        doc = json.loads(path.read_text())
        doc["intents"][0]["request"]["payload"]["head"] = w.heads[5]
        path.write_text(json.dumps(doc))
        cases.append((w, "edited"))
        for w, label in cases:
            with self.subTest(label):
                before = len(w.appends())
                out = w.run("round", "open", "job-a", "--head", w.heads[1])
                self.assertRc(out, 74, "intent_invalid")
                self.assertEqual(len(w.appends()), before)
                self.assertEqual(len(w.events("job-a", "job.round")), 1)
        w = self.world()
        w.enforced_builder()
        out = w.run("round", "open", "job-a", "--head", w.heads[0], WRK_O3_TEST_FAULT="fsync_fail")
        self.assertRc(out, 74, "intent_io")
        self.assertEqual(w.appends("round_open"), [], "nothing is sent before the intent is durable")
        self.assertEqual(w.events("job-a", "job.round"), [])
        self.note("intent-symlink-mode-malformed-fsync-fails", exit_code=74, stderr_code="intent_invalid")

    def test_v10b_deleted_intent_file_keeps_the_server_authoritative(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        (w.inbox / "job-a" / "o3-intents.json").unlink()
        out = w.run("round", "status", "job-a")
        self.assertRc(out, 0)
        self.assertIn("rounds=1", out.stdout)

    def test_v11_inconsistent_cursor_pages_stop_every_decision(self):
        for action, code, limit, page in (("tamper_hash", "protocol_invalid", 1, 2),
                                          ("snapshot_shift", "protocol_invalid", 1, 2),
                                          ("gap", "protocol_invalid", 500, 1),
                                          ("generation", "history_regressed", 1, 2)):
            with self.subTest(action):
                w = self.world()
                w.enforced_builder()
                w.set_stub(page_limit=limit)
                w.fault("records", action, page=page)
                out = w.run("round", "open", "job-a", "--head", w.heads[0])
                self.assertRc(out, 75, code)
                self.assertEqual(w.appends("round_open"), [])
                self.assertEqual(w.events("job-a", "job.round"), [])
        self.note("cursor-page-inconsistent-history-regressed", exit_code=75, stderr_code="protocol_invalid")

    def test_v12_redirect_html_missing_namespace_unknown_code(self):
        for action, code in (("html", "protocol_invalid"), ("garbage", "protocol_invalid"),
                             ("noisy_stderr", "protocol_invalid"), ("unknown_code", "protocol_invalid")):
            with self.subTest(action):
                w = self.world()
                w.enforced_builder()
                w.fault("job", action)
                out = w.run("round", "open", "job-a", "--head", w.heads[0])
                self.assertRc(out, 75, code)
                for leak in ("html", "Location", "elsewhere", "brand_new_code"):
                    self.assertNotIn(leak, out.stderr + out.stdout)
        w = self.world()
        w.enforced_builder()
        w.set_stub(namespace=False)
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, 75, "o3_unsupported")
        self.assertEqual(w.events("job-a", "job.round"), [])
        # On append the intent stays pending and the next run retries its key.
        w = self.world()
        w.enforced_builder()
        w.fault("append", "html", kind="round_open")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 75, "protocol_invalid")
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["pending"])
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        keys = {c["argv"][c["argv"].index("--idempotency-key") + 1] for c in w.appends("round_open")}
        self.assertEqual(len(keys), 1)
        self.note("redirect-html-namespace-unknown-code", exit_code=75, stderr_code="protocol_invalid")

    def scenario_env_keys_scrubbed(self, bindir):
        w = self.world(bindir=bindir)
        w.enforced_builder()
        extra = {key: SENTINEL for key in SCRUBBED}
        out = w.run("round", "open", "job-a", "--head", w.heads[0], **extra)
        return w, out

    def test_v13_caller_env_overrides_scrubbed(self):
        w, out = self.scenario_env_keys_scrubbed(BIN)
        self.assertRc(out, 0)
        calls = w.calls()
        self.assertTrue(calls)
        for call in calls:
            for key in SCRUBBED:
                self.assertNotIn(key, call["env_keys"], call["argv"])
        self.assertNoLeak(w, out.stdout, out.stderr)
        self.note("caller-env-overrides-scrubbed", outcome="env_scrubbed")

    def test_v14_commit_then_proxy_5xx_keeps_the_intent_pending(self):
        for action in ("commit_then:protocol_invalid", "commit_then:wrk_unavailable"):
            with self.subTest(action):
                w = self.world()
                w.enforced_builder()
                w.fault("append", action, kind="round_open")
                self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 75)
                self.assertEqual([i["state"] for i in w.intents("job-a")], ["pending"])
                self.assertEqual(w.events("job-a", "job.round"), [])
                out = w.run("round", "open", "job-a", "--head", w.heads[0])
                self.assertRc(out, 0)
                self.assertEqual(len([r for r in w.records("job-a") if r["kind"] == "round_open"]), 1)
                self.assertIn("resent=pending", out.stdout)
        self.note("commit-then-proxy-5xx-pending-intent", exit_code=75, stderr_code="protocol_invalid")


class ErrorMapCase(O3Case):
    """Every stable code the CLI can print keeps its exit; 4xx rejects the
    intent, 503 and local transport codes leave it pending (section4-rules)."""

    def test_every_errmap_code_through_append(self):
        rules = json.loads((PACK / "vectors" / "section4-rules.json").read_text())["cases"]
        codes = [c["expect"]["error"] for c in rules if c["name"].startswith("errmap-")]
        self.assertEqual(len(codes), 37)
        w = self.world()
        w.enforced_builder()
        for code in codes:
            with self.subTest(code):
                w.fault("append", "error:" + code, kind="round_open")
                out = w.run("round", "open", "job-a", "--head", w.heads[0])
                self.assertEqual(out.returncode, ADAPTER.EXIT[code], out.stderr)
                self.assertIn("o3 %s" % code, out.stderr)
                last = w.intents("job-a")[-1]
                if code in ("wrk_unavailable", "wrk_recovery_required"):
                    self.assertEqual(last["state"], "pending")
                    # Settle the pending intent so the next code starts clean.
                    self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
                    self.assertRc(w.run("round", "verdict", "job-a", "--file",
                                        w.verdict_file("v-%s.md" % code, w.heads[0])), 0)
                    w.heads = w.heads[1:] + w.heads[:1]
                else:
                    self.assertEqual((last["state"], last["error"]), ("rejected", code))
                self.assertEqual(w.events("job-a", "job.o3_warning"), [])

    def test_every_errmap_code_through_reads(self):
        w = self.world()
        w.enforced_builder()
        for code in sorted(ADAPTER.CLI_CODES - {"intent_invalid", "intent_io", "history_regressed"}):
            with self.subTest(code):
                w.fault("job", "error:" + code)
                out = w.run("round", "status", "job-a")
                if code == "not_found":
                    self.assertRc(out, 66, "not_found")
                    continue
                if code in ("transport_unavailable", "transport_indeterminate", "wrk_unavailable",
                            "wrk_recovery_required", "protocol_invalid", "o3_unsupported"):
                    # Offline read with a cached snapshot: stale and labelled only.
                    if out.returncode == 0:
                        self.assertIn("stale=true", out.stdout)
                        self.assertIn("label=O2-unverified", out.stdout)
                        continue
                self.assertEqual(out.returncode, ADAPTER.EXIT[code], (code, out.stderr))


# ── 2. the section 6 matrix ───────────────────────────────────────────────────


class MatrixCase(O3Case):
    """Rows: claim/spawn, round open, verdict, void, status/audit, joined, done.
    Columns: new wrk + enforced server (A), old wrk + new server (B, legacy
    mode), new wrk + old server or missing namespace (C), offline/5xx (D)."""

    # -- round open --
    def test_open_A_receipt_then_projection(self):
        w = self.world()
        w.enforced_builder()
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, 0)
        self.assertIn("round=1", out.stdout)
        event = w.events("job-a", "job.round")[0]
        record = w.records("job-a")[-1]
        self.assertEqual(event["wrk_receipt"], {"job_id": "job-a", "seq": record["seq"],
                                                "record_hash": record["record_hash"],
                                                "store_generation": record["store_generation"]})
        self.assertEqual(event["o3_mode"], "enforced")
        self.assertEqual(event["idempotency_key"], record["idempotency_key"])
        self.assertEqual(event["round"], 1)

    def test_open_B_legacy_mode_never_calls_the_server(self):
        w = self.world()
        w.mode(None)
        w.enroll("job-a")
        w.local_claim("job-a")
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, 0)
        self.assertEqual([c for c in w.calls() if c["argv"][:1] == ["wrk"]], [])
        self.assertNotIn("wrk_receipt", w.events("job-a", "job.round")[0])
        for argv in (["--extension-grant", "4"], ["--tester", "job-t"]):
            self.assertEqual(w.run("round", "open", "job-a", "--head", w.heads[1], *argv).returncode, 2)

    def test_open_C_old_server_refuses_without_local_event(self):
        w = self.world()
        w.enforced_builder()
        w.set_stub(namespace=False)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 75, "o3_unsupported")
        self.assertEqual(w.events("job-a", "job.round"), [])

    def test_open_D_offline_fails_closed_and_keeps_the_intent(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "status", "job-a"), 0)
        w.fault("append", "error:transport_unavailable", kind="round_open", times=1)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 75, "transport_unavailable")
        self.assertEqual(w.events("job-a", "job.round"), [])
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["pending"])
        self.assertEqual(w.events("job-a", "job.o3_warning"), [], "no warning branch once receipt_required")

    def test_open_refuses_free_refs_for_an_o3_job(self):
        w = self.world()
        w.enforced_builder()
        out = w.run("round", "open", "job-a", "--head", w.heads[0], "--extend", "hk:doc/some-grant")
        self.assertEqual(out.returncode, 2)
        self.assertIn("typed server grant", out.stderr)
        self.assertEqual(w.appends(), [])

    # -- round verdict --
    def test_verdict_A_binds_the_oldest_open_round_on_its_head(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 0)
        out = w.run("round", "verdict", "job-a", "--file", w.verdict_file("v2.md", w.heads[1]))
        self.assertRc(out, 0)
        self.assertIn("round=2", out.stdout)
        send = w.appends("verdict")[0]
        payload = json.loads(base64.b64decode(send["stdin_b64"]))
        self.assertEqual(payload["round_no"], 2)
        self.assertEqual(base64.b64decode(payload["content_b64"]), (w.base / "v2.md").read_bytes())
        self.assertEqual(payload["path"], str(w.base / "v2.md"))
        self.assertEqual(w.events("job-a", "job.verdict")[0]["round"], 2)

    def test_verdict_strict_first_line_grammar(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        bad = w.base / "bad.md"
        bad.write_text("preamble\nVERDICT: PASS @%s\n" % w.heads[0])
        self.assertRc(w.run("round", "verdict", "job-a", "--file", bad), 65, "invalid_verdict")
        bad.write_bytes(b"\xef\xbb\xbfVERDICT: PASS @" + w.heads[0].encode() + b"\n")
        self.assertRc(w.run("round", "verdict", "job-a", "--file", bad), 65, "invalid_verdict")
        self.assertEqual(w.appends("verdict"), [], "a header with no head leaves the request unsendable")
        # Every other grammar rule is the server's (director-1 C1 ruling): a
        # later VERDICT: line is sent and the server's invalid_verdict reported.
        bad.write_text("VERDICT: PASS @%s\nVERDICT: BLOCKER @%s\n" % (w.heads[0], w.heads[0]))
        self.assertRc(w.run("round", "verdict", "job-a", "--file", bad), 65, "invalid_verdict")
        self.assertEqual(len(w.appends("verdict")), 1)
        self.assertEqual(w.events("job-a", "job.verdict"), [])

    def scenario_refused_verdict_writes_no_event(self, bindir):
        w = self.world(bindir=bindir)
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        w.fault("append", "error:duplicate_path", kind="verdict")
        out = w.run("round", "verdict", "job-a", "--file", w.verdict_file("v.md", w.heads[0]))
        return w, out

    def test_verdict_A_refusal_writes_no_local_verdict(self):
        w, out = self.scenario_refused_verdict_writes_no_event(BIN)
        self.assertRc(out, 73, "duplicate_path")
        self.assertEqual(w.events("job-a", "job.verdict"), [])

    def test_verdict_C_old_server_refuses_and_preserves_the_file(self):
        w = self.world()
        w.enforced_builder()
        vfile = w.verdict_file("v.md", w.heads[0])
        w.set_stub(namespace=False)
        self.assertRc(w.run("round", "verdict", "job-a", "--file", vfile), 75, "o3_unsupported")
        self.assertTrue(vfile.exists())
        self.assertEqual(w.events("job-a", "job.verdict"), [])

    def test_verdict_D_offline_preserves_bytes_and_pending_intent(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        vfile = w.verdict_file("v.md", w.heads[0])
        w.fault("append", "error:wrk_unavailable", kind="verdict")
        self.assertRc(w.run("round", "verdict", "job-a", "--file", vfile), 75, "wrk_unavailable")
        pending = [i for i in w.intents("job-a") if i["request"]["kind"] == "verdict"][0]
        self.assertEqual(pending["state"], "pending")
        self.assertEqual(base64.b64decode(pending["request"]["payload"]["content_b64"]), vfile.read_bytes())
        self.assertEqual(w.events("job-a", "job.verdict"), [])

    def test_verdict_D_unreadable_server_forms_the_intent_only_from_a_cached_round(self):
        w = self.world()
        w.enforced_builder()
        vfile = w.verdict_file("v.md", w.heads[0])
        # No snapshot holds the round head: fail closed and record no intent.
        w.fault("job", "error:transport_unavailable")
        self.assertRc(w.run("round", "verdict", "job-a", "--file", vfile), 75, "transport_unavailable")
        self.assertEqual(w.intents("job-a"), [])
        # A cached open round on this head (and its tester): the exact request is
        # formed and stays pending; nothing is sent or projected.
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        before = len(w.appends())
        w.fault("job", "error:transport_unavailable")
        self.assertRc(w.run("round", "verdict", "job-a", "--file", vfile), 75, "transport_unavailable")
        pending = [i for i in w.intents("job-a") if i["state"] == "pending"]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["request"]["payload"]["round_no"], 1)
        self.assertIsNone(pending[0]["request"]["payload"]["tester_job_id"])
        self.assertEqual(base64.b64decode(pending[0]["request"]["payload"]["content_b64"]), vfile.read_bytes())
        self.assertEqual(len(w.appends()), before)
        self.assertEqual(w.events("job-a", "job.verdict"), [])
        # Recovery resends that exact intent by its key.
        out = w.run("round", "verdict", "job-a", "--file", vfile)
        self.assertRc(out, 0)
        self.assertEqual(w.appends("verdict")[-1]["argv"][w.appends("verdict")[-1]["argv"].index("--idempotency-key") + 1],
                         pending[0]["idempotency_key"])

    # -- round void --
    def test_void_A_typed_grant_then_projection(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        grant = w.grant("job-a", "void", round_no=1)
        out = w.run("round", "void", "job-a", "1", "--grant", grant["seq"])
        self.assertRc(out, 0)
        event = w.events("job-a", "job.round_void")[0]
        self.assertEqual((event["round"], event["grant_seq"], event["o3_mode"]), (1, grant["seq"], "enforced"))
        out = w.run("round", "void", "job-a", "1", "--by", "hk:doc/free")
        self.assertEqual(out.returncode, 2)
        self.assertIn("typed server grant", out.stderr)

    def test_void_B_legacy_refuses_typed_grant(self):
        w = self.world()
        w.mode(None)
        w.local_claim("job-a")
        out = w.run("round", "void", "job-a", "1", "--grant", "3")
        self.assertEqual(out.returncode, 2)
        self.assertIn("O2 path", out.stderr)

    def test_void_C_and_D_refuse_and_keep_the_count(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        grant = w.grant("job-a", "void", round_no=1)
        w.fault("append", "error:transport_unavailable", kind="void")
        self.assertRc(w.run("round", "void", "job-a", "1", "--grant", grant["seq"]), 75)
        self.assertEqual(w.events("job-a", "job.round_void"), [])
        w.set_stub(namespace=False)
        self.assertRc(w.run("round", "void", "job-a", "1", "--grant", grant["seq"]), 75, "o3_unsupported")
        self.assertEqual(w.events("job-a", "job.round_void"), [])

    # -- round status / audit --
    def test_status_A_canonical_summary_and_local_unmatched_warning(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        (w.inbox / "job-a" / "stray.md").write_text("VERDICT: PASS @%s\n" % w.heads[3])
        out = w.run("round", "status", "job-a")
        self.assertRc(out, 0)
        self.assertIn("o3=enforced", out.stdout)
        self.assertIn("open=1", out.stdout)
        self.assertIn("unmatched tester verdict file", out.stderr)

    def test_status_C_old_server_local_status_only_with_o2_label(self):
        w = self.world()
        w.mode("shadow")
        w.local_claim("job-a")
        w.set_stub(namespace=False)
        out = w.run("round", "status", "job-a")
        self.assertRc(out, 0)
        self.assertIn("o3=unsupported", out.stdout)
        self.assertIn("label=O2-unverified", out.stdout)
        w.mode("required")
        self.assertRc(w.run("round", "status", "job-a"), 75, "o3_unsupported")

    def test_status_D_cached_snapshot_is_stale_and_labelled(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        w.fault("job", "error:transport_unavailable")
        out = w.run("round", "status", "job-a")
        self.assertRc(out, 0)
        for token in ("stale=true", "label=O2-unverified", "generation=", "seq=", "read_at="):
            self.assertIn(token, out.stdout)
        self.assertEqual(len(w.events("job-a", "job.o3_warning")), 1)
        # Never used for a decision: an open still fails closed.
        w.fault("job", "error:transport_unavailable")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 75)

    def test_audit_reads_the_server_only_for_o3_job_dirs(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "status", "job-a"), 0)
        w.local_claim("legacy-b")
        out = w.run("round", "audit")
        self.assertRc(out, 0)
        self.assertIn("zero-rounds job=job-a lane=b2400-a o3=canonical", out.stdout)
        self.assertIn("zero-rounds job=legacy-b lane=b2400-a\n", out.stdout)
        jobs = {c["argv"][2] for c in w.calls() if c["argv"][:2] in (["wrk", "job"], ["wrk", "records"])}
        self.assertEqual(jobs, {"job-a"})

    # -- joined / done (adapter operations; hk 1927 wires done/joined) --
    def test_joined_A_typed_waiver_and_report_bytes(self):
        w = self.world()
        w.enforced_builder()
        grant = w.grant("job-a", "join_waiver", head=w.heads[0])
        report = w.base / "report.md"
        report.write_text("joined report\n")
        out = w.adapter("joined", "job-a", "--pr", "https://github.com/o/r/pull/1", "--head", w.heads[0],
                        "--report", report, "--waiver-grant", grant["seq"])
        self.assertRc(out, 0)
        self.assertIn("RECEIPT", out.stdout)
        payload = json.loads(base64.b64decode(w.appends("joined")[0]["stdin_b64"]))
        self.assertEqual(base64.b64decode(payload["report_b64"]), b"joined report\n")
        self.assertEqual(payload["waiver_grant_seq"], grant["seq"])

    def scenario_free_waiver_refused(self, adapter_py):
        w = self.world()
        w.enforced_builder()
        report = w.base / "report.md"
        report.write_text("r\n")
        return w, subprocess.run([sys.executable, str(adapter_py), "joined", "job-a", "--pr",
                                  "https://github.com/o/r/pull/1", "--head", w.heads[0], "--report", str(report),
                                  "--rounds-waived", "hk:doc/waiver"], env=w.env(), stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)

    def test_joined_A_free_waiver_ref_refused(self):
        w, out = self.scenario_free_waiver_refused(BIN / "wrk_o3.py")
        self.assertEqual(out.returncode, 2)
        self.assertIn("typed join_waiver", out.stderr)
        self.assertEqual(w.appends("joined"), [])

    def test_joined_A_non_waiver_grant_refused_and_server_refusals_surface(self):
        w = self.world()
        w.enforced_builder()
        ext = w.grant("job-a", "void", round_no=1)
        report = w.base / "report.md"
        report.write_text("r\n")
        base = ["joined", "job-a", "--pr", "https://github.com/o/r/pull/1", "--head", w.heads[0], "--report", report]
        self.assertRc(w.adapter(*base, "--waiver-grant", ext["seq"]), 73, "grant_invalid")
        self.assertEqual(len(w.appends("joined")), 1, "the waiver type is judged by the server")
        self.assertRc(w.adapter(*base), 73, "zero_rounds")

    def test_joined_C_D_fail_closed(self):
        w = self.world()
        w.enforced_builder()
        report = w.base / "report.md"
        report.write_text("r\n")
        base = ["joined", "job-a", "--pr", "https://github.com/o/r/pull/1", "--head", w.heads[0], "--report", report]
        w.fault("append", "error:wrk_unavailable", kind="joined")
        self.assertRc(w.adapter(*base), 75, "wrk_unavailable")
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["pending"])
        w.set_stub(namespace=False)
        self.assertRc(w.adapter(*base), 75, "o3_unsupported")

    def test_done_A_completed_observation_with_exact_bytes(self):
        w = self.world()
        w.enforced_builder()
        report = w.base / "report.md"
        report.write_bytes(b"done report \xe2\x9c\x93\n")
        out = w.adapter("completed", "job-a", "--report", report)
        self.assertRc(out, 0)
        self.assertIn("rounds incomplete", out.stderr)
        payload = json.loads(base64.b64decode(w.appends("completed")[0]["stdin_b64"]))
        self.assertEqual(base64.b64decode(payload["report_b64"]), report.read_bytes())

    def test_done_D_unavailable_is_75_with_pending_intent(self):
        w = self.world()
        w.enforced_builder()
        report = w.base / "report.md"
        report.write_text("r\n")
        w.fault("append", "error:transport_unavailable", kind="completed")
        self.assertRc(w.adapter("completed", "job-a", "--report", report), 75, "transport_unavailable")
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["pending"])
        self.assertEqual(w.events("job-a"), [w.events("job-a")[0]], "no local completion")
        w.set_stub(namespace=False)
        self.assertRc(w.adapter("completed", "job-a", "--report", report), 75, "o3_unsupported")


class ShadowCase(O3Case):
    """Section 6 dual-write: the P1 warning branch and its limits."""

    def shadow_subject(self, mode="shadow"):
        w = self.world()
        w.mode(mode)
        w.enroll("job-a", activate=False)
        w.local_claim("job-a")
        self.assertRc(w.run("round", "status", "job-a"), 0)
        return w

    def test_shadow_subject_dual_writes_with_o3_mode_shadow(self):
        w = self.shadow_subject()
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, 0)
        self.assertEqual(w.events("job-a", "job.round")[0]["o3_mode"], "shadow")

    def test_unavailable_shadow_subject_takes_the_p1_warning_branch(self):
        w = self.shadow_subject()
        w.fault("job", "error:transport_unavailable")
        w.fault("append", "error:transport_unavailable", kind="round_open")
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, 0)
        self.assertIn("OK job=job-a round=1", out.stdout)
        rounds = w.events("job-a", "job.round")
        self.assertEqual(len(rounds), 1)
        self.assertNotIn("wrk_receipt", rounds[0])
        warning = w.events("job-a", "job.o3_warning")
        self.assertEqual(len(warning), 1)
        self.assertEqual(set(warning[0]) - {"at"}, {"kind", "job_id", "code", "operation", "idempotency_key", "epoch"})
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["pending"])

    def test_business_refusal_never_falls_back_even_in_shadow(self):
        w = self.shadow_subject()
        w.fault("append", "error:scope_denied", kind="round_open")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 77, "scope_denied")
        self.assertEqual(w.events("job-a", "job.round"), [])

    def test_required_mode_has_no_warning_branch(self):
        w = self.shadow_subject(mode="required")
        w.fault("job", "error:transport_unavailable")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 75)
        self.assertEqual(w.events("job-a", "job.round"), [])

    def scenario_review_role_job_never_warns(self, bindir):
        """A host-minted reviewer is receipt_required from its claim even while
        its summary.state is shadow: its own completed cannot fail open."""
        w = self.world(bindir=bindir)
        w.mode("shadow")
        w.enroll("job-a")
        w.seed("rev-a", "claim", {"job_id": "rev-a", "owner_lane": "b2400-a", "parent_lane": "b2400-a",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "tester", "tier": "T2",
                                  "review_of": {"job_id": "job-a", "round_no": 1}, "predecessor_job_id": None,
                                  "supersedes": None}, client="desktop")
        w.local_claim("rev-a", role="builder")
        self.assertRc(w.run("round", "status", "rev-a"), 0)
        snapshot = json.loads((w.inbox / "rev-a" / "o3-snapshot.json").read_text())
        self.assertTrue(snapshot["receipt_required"])
        self.assertEqual(snapshot["summary"]["state"], "shadow")
        w.fault("job", "error:transport_unavailable")
        w.fault("append", "error:transport_unavailable", kind="round_open")
        out = w.run("round", "open", "rev-a", "--head", w.heads[0])
        return w, out

    def test_review_role_shadow_job_never_takes_the_warning_branch(self):
        w, out = self.scenario_review_role_job_never_warns(BIN)
        self.assertRc(out, 75)
        self.assertEqual(w.events("rev-a", "job.round"), [])
        self.assertEqual(w.events("rev-a", "job.o3_warning"), [])

    def test_r4_reviewer_done_on_5xx_is_75_with_zero_local_completion(self):
        w = self.world()
        w.mode("shadow")
        w.enroll("job-a")
        w.seed("rev-a", "claim", {"job_id": "rev-a", "owner_lane": "b2400-a", "parent_lane": "b2400-a",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "tester", "tier": "T2",
                                  "review_of": {"job_id": "job-a", "round_no": 1}, "predecessor_job_id": None,
                                  "supersedes": None}, client="desktop")
        report = w.base / "report.md"
        report.write_text("tester report\n")
        w.fault("append", "error:wrk_unavailable", kind="completed")
        out = w.adapter("completed", "rev-a", "--report", report)
        self.assertRc(out, 75, "wrk_unavailable")
        self.assertEqual([i["state"] for i in w.intents("rev-a")], ["pending"])
        self.assertEqual(w.events("rev-a", "job.completed"), [])

    def test_not_enrolled_job_in_shadow_is_legacy_with_one_warning_required_refuses(self):
        w = self.world()
        w.mode("shadow")
        w.set_stub()
        w.local_claim("job-z")
        out = w.run("round", "open", "job-z", "--head", w.heads[0])
        self.assertRc(out, 0)
        self.assertNotIn("wrk_receipt", w.events("job-z", "job.round")[0])
        self.assertEqual([e["code"] for e in w.events("job-z", "job.o3_warning")], ["not_enrolled"])
        w.mode("required")
        self.assertRc(w.run("round", "open", "job-z", "--head", w.heads[1]), 66, "not_found")

    def test_test_mode_with_home_unset_is_legacy_and_reads_no_path(self):
        """director-1 parity note. bin/wrk itself needs HOME (line 5 predates
        O3), so the two mode readers are run directly: the adapter's and the
        bash mode-file check extracted from bin/wrk."""
        w = self.world()
        w.mode("enforce-please")
        out = w.adapter("mode", HOME=None)
        self.assertRc(out, 0)
        self.assertEqual(out.stdout.strip(), "legacy")
        text = (BIN / "wrk").read_text()
        start = text.index("o3_mode_file_present() {")
        function = text[start:text.index("\n}\n", start) + 3]
        probe = subprocess.run(["bash", "-c", function + "o3_mode_file_present"], env=w.env(HOME=None),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(probe.returncode, 1, probe.stderr)
        probe = subprocess.run(["bash", "-c", function + "o3_mode_file_present"], env=w.env(),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(probe.returncode, 0, "with HOME set the mode file is found")
        # Outside test mode only the passwd home decides, whatever HOME says.
        p = self.world(production=True)
        p.mode("enforce-please")
        out = p.adapter("mode", HOME=p.base / "elsewhere")
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertIn("records_mode_invalid", out.stderr)

    def test_records_mode_file_fails_closed(self):
        w = self.world()
        w.local_claim("job-a")
        w.mode("enforce-please")
        out = w.run("round", "status", "job-a")
        self.assertEqual(out.returncode, 2)
        self.assertIn("records_mode_invalid", out.stderr)


class RegressedHistoryCase(O3Case):
    """director-1 regressed-history ruling: retained intents and the last
    complete snapshot are negative witnesses; they can only refuse."""

    def witnessed(self, mode="shadow"):
        w = self.world()
        w.mode(mode)
        w.enroll("job-a", activate=False)
        w.local_claim("job-a")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        return w

    def scenario_not_found_after_a_receipt(self, bindir):
        w = self.world(bindir=bindir)
        w.mode("shadow")
        w.enroll("job-a", activate=False)
        w.local_claim("job-a")
        assert w.run("round", "open", "job-a", "--head", w.heads[0]).returncode == 0
        state = w.stub()
        del state["jobs"]["job-a"]
        w.set_stub(**state)
        out = w.run("round", "open", "job-a", "--head", w.heads[1])
        return w, out

    def test_not_found_after_a_receipt_is_history_regressed_never_legacy(self):
        w, out = self.scenario_not_found_after_a_receipt(BIN)
        self.assertRc(out, 75, "history_regressed")
        self.assertEqual(len(w.events("job-a", "job.round")), 1, "no legacy fallback for a witnessed job")
        self.assertEqual([e["code"] for e in w.events("job-a", "job.o3_warning")], ["history_regressed"])
        snapshot = json.loads((w.inbox / "job-a" / "o3-snapshot.json").read_text())
        self.assertEqual(snapshot["snapshot_seq"], 2, "the cached read is never downgraded")
        self.assertRc(w.run("round", "status", "job-a"), 75, "history_regressed")

    def test_not_found_with_only_a_snapshot_witness_also_refuses(self):
        w = self.witnessed()
        (w.inbox / "job-a" / "o3-intents.json").unlink()
        state = w.stub()
        del state["jobs"]["job-a"]
        w.set_stub(**state)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 75, "history_regressed")

    def test_generation_regression_keeps_the_pending_intent(self):
        w = self.witnessed(mode="required")
        w.fault("append", "error:wrk_unavailable", kind="round_open")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 75, "wrk_unavailable")
        generation = str(uuid.uuid4())
        w.rewrite_records("job-a", lambda records: [dict(r, store_generation=generation) for r in records])
        w.set_stub(generation=generation)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 75, "history_regressed")
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["accepted", "pending"])
        self.assertEqual(len(w.events("job-a", "job.o3_warning")), 1)

    def test_seq_regression_refuses(self):
        w = self.witnessed()
        w.rewrite_records("job-a", lambda records: records[:1])
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 75, "history_regressed")
        self.assertEqual(len(w.events("job-a", "job.round")), 1)

    def test_no_witness_shadow_unknown_job_still_takes_the_legacy_path(self):
        w = self.world()
        w.mode("shadow")
        w.set_stub()
        w.local_claim("job-z")
        out = w.run("round", "open", "job-z", "--head", w.heads[0])
        self.assertRc(out, 0)
        self.assertNotIn("wrk_receipt", w.events("job-z", "job.round")[0])
        self.assertEqual([e["code"] for e in w.events("job-z", "job.o3_warning")], ["not_enrolled"])


# ── 3. spawn orders ───────────────────────────────────────────────────────────


def spawn_builder(w, *extra, label="new-builder", job="new-builder"):
    return w.spawn("--role", "builder", "--lane", "new-lane", "--parent", "director-1", "--task", "2400",
                   "--job", job, *extra, model="builder-sol", label=label)


class SpawnCase(O3Case):
    def builder(self, w, *extra, label="new-builder", job="new-builder"):
        return spawn_builder(w, *extra, label=label, job=job)

    def test_builder_spawn_verifies_the_precreated_active_claim_then_panes(self):
        w = self.world()
        w.mode("required")
        w.enroll("new-builder", owner="new-lane", tier="T1")
        out = self.builder(w)
        self.assertRc(out, 0)
        self.assertIn("OK pane=", out.stdout)
        calls = [c["argv"][:2] for c in w.calls()]
        self.assertIn(["wrk", "job"], calls)
        self.assertIn(["wrk", "capabilities"], calls)
        self.assertEqual(w.appends(), [], "a host spawn never mints a central claim or activation")
        self.assertTrue(w.herdr_calls())
        self.assertFalse(any(c["argv"][:1] == ["tasks"] for c in w.calls()), "no unguarded hk_bin task call")
        task_links = [e for e in w.events("new-builder") if e.get("kind") == "job.task_link"]
        self.assertTrue(task_links)
        self.assertEqual(task_links[0]["payload"]["status"], "already_linked")

    def test_builder_spawn_refuses_before_any_pane_or_task_write(self):
        cases = {
            "not enrolled": dict(enroll=False, code="not_found", rc=66),
            "shadow claim": dict(activate=False, code="claim_conflict", rc=73),
            "other host": dict(host="mac-dev", code="claim_conflict", rc=73),
            "other task": dict(task=9999, code="claim_conflict", rc=73),
            "other tier": dict(tier="T3", code="claim_conflict", rc=73),
            "other lane": dict(owner="other-lane", code="claim_conflict", rc=73),
        }
        for label, spec in cases.items():
            with self.subTest(label):
                w = self.world()
                w.mode("required")
                w.set_stub()
                if spec.get("enroll", True):
                    w.enroll("new-builder", owner=spec.get("owner", "new-lane"), tier=spec.get("tier", "T1"),
                             host=spec.get("host", "desktop"), task=spec.get("task", 2400),
                             activate=spec.get("activate", True))
                out = self.builder(w)
                self.assertRc(out, spec["rc"], spec["code"])
                self.assertEqual(w.herdr_calls(), [])
                self.assertFalse(any(c["argv"][:1] == ["tasks"] for c in w.calls()))
                self.assertFalse((w.inbox / "new-builder" / "events").exists() and
                                 any(e.get("kind") == "job.claim" for e in w.events("new-builder")))

    def test_spawn_C_old_server_refuses_with_no_pane(self):
        w = self.world()
        w.mode("required")
        w.set_stub(namespace=False)
        out = self.builder(w)
        self.assertRc(out, 75, "o3_unsupported")
        self.assertEqual(w.herdr_calls(), [])

    def test_spawn_D_offline_fails_closed_before_any_pane(self):
        w = self.world()
        w.mode("required")
        w.enroll("new-builder", owner="new-lane", tier="T1")
        w.fault("job", "error:transport_unavailable")
        out = self.builder(w)
        self.assertRc(out, 75, "transport_unavailable")
        self.assertEqual(w.herdr_calls(), [])
        self.assertEqual(len(w.records("new-builder")), 2, "the central claim stays visible")

    def test_o3_refusals_name_their_code_and_legacy_74_75_name_none(self):
        """esc-3 I6: 74 and 75 are shared with the legacy spawn exits, so every
        O3 refusal names its code and the legacy paths name none."""
        cases = {66: ("not_found", dict(enroll=False)), 73: ("claim_conflict", dict(tier="T3")),
                 75: ("o3_unsupported", dict(namespace=False)), 77: ("host_mismatch", dict(reviewer=True))}
        for rc, (code, spec) in cases.items():
            with self.subTest(rc):
                w = self.world()
                w.mode("required")
                w.set_stub(namespace=spec.get("namespace", True))
                if spec.get("reviewer"):
                    w.enroll("job-a", host="mac-dev", tier="T1")
                    w.local_claim("job-a")
                    out = self.spawn_tester(w)
                elif spec.get("enroll", True):
                    if spec.get("namespace", True):
                        w.enroll("new-builder", owner="new-lane", tier=spec.get("tier", "T1"))
                    out = self.builder(w)
                else:
                    out = self.builder(w)
                self.assertRc(out, rc, code)
                self.assertIn("wrk: o3 %s" % code, out.stderr)
        # Legacy 74: an active arbiter duplicate.
        w = self.world()
        w.mode(None)
        env = w.env(ARBITER_BIN=BIN / "arbiter")
        subprocess.run([str(BIN / "arbiter"), "claim", "--job", "dup-a", "--agent-label", "incumbent", "--lane",
                        "incumbent-lane", "--t", "T1"], env=env, check=True, stdout=subprocess.DEVNULL)
        out = w.spawn("--task", "2400", "--job", "dup-a")
        self.assertEqual(out.returncode, 74, out.stderr)
        self.assertNotIn("wrk: o3 ", out.stderr)
        # Legacy 75: the duplicate state lookup is unreadable.
        subprocess.run([str(BIN / "arbiter"), "claim", "--job", "dup-b", "--agent-label", "incumbent", "--lane",
                        "incumbent-lane", "--t", "T1"], env=env, check=True, stdout=subprocess.DEVNULL)
        out = w.spawn("--task", "2400", "--job", "dup-b", ARBITER_BIN=ROOT / "tests" / "fixtures" / "arbiter-proxy",
                      REAL_ARBITER=BIN / "arbiter", WRK_ARBITER_PROXY_MODE="job-get-fails")
        self.assertEqual(out.returncode, 75, out.stderr)
        self.assertNotIn("wrk: o3 ", out.stderr)

    def scenario_legacy_spawn_makes_both_task_calls(self, bindir):
        w = self.world(bindir=bindir)
        w.mode(None)
        out = spawn_builder(w)
        return w, out

    def test_legacy_spawn_keeps_both_legacy_task_calls(self):
        w, out = self.scenario_legacy_spawn_makes_both_task_calls(BIN)
        self.assertRc(out, 0)
        log = w.tasks_log.read_text() if w.tasks_log.exists() else ""
        self.assertIn("claim id=2400", log)
        shows = [c for c in w.calls() if c["argv"][:2] == ["tasks", "show"]]
        self.assertTrue(shows, "the legacy precheck must still run")
        self.assertEqual([c for c in w.calls() if c["argv"][:1] == ["wrk"]], [])

    def subject_with_head(self, w, owner="b2400-a"):
        w.mode("required")
        w.enroll("job-a", owner=owner, tier="T1")
        w.local_claim("job-a", owner=owner)

    def spawn_tester(self, w, *extra, job="rev-a", head=None):
        return w.spawn("--role", "tester", "--parent-job", "job-a", "--job", job, "--head", head or w.heads[0],
                       *extra, label=job)

    def test_reviewer_order_mint_verify_open_then_pane(self):
        w = self.world()
        self.subject_with_head(w)
        out = self.spawn_tester(w)
        self.assertRc(out, 0)
        sequence = []
        for call in w.calls():
            argv = call["argv"]
            if argv[:2] == ["wrk", "append"]:
                sequence.append("append:%s:%s" % (argv[argv.index("--kind") + 1], argv[2]))
        self.assertEqual(sequence, ["append:claim:rev-a", "append:round_open:job-a"])
        claim = w.records("rev-a")[0]["payload"]
        self.assertEqual(claim["review_of"], {"job_id": "job-a", "round_no": 1})
        self.assertEqual((claim["owner_lane"], claim["parent_lane"], claim["task_id"], claim["tier"]),
                         ("b2400-a", "b2400-a", 2400, "T1"))
        opened = [r for r in w.records("job-a") if r["kind"] == "round_open"][0]
        self.assertEqual(opened["payload"]["tester_job_id"], "rev-a")
        self.assertEqual([i["request"]["kind"] for i in w.intents("rev-a")], ["claim"],
                         "the mint intent lives in the new reviewer job's directory")
        self.assertEqual(w.events("job-a", "job.round")[0]["tester_job_id"], "rev-a")
        self.assertTrue(w.herdr_calls())
        self.assertFalse(any(c["argv"][:1] == ["tasks"] for c in w.calls()))

    def test_reviewer_attaches_to_an_open_round_without_a_tester(self):
        w = self.world()
        self.subject_with_head(w)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        out = self.spawn_tester(w)
        self.assertRc(out, 0)
        self.assertEqual([c["argv"][c["argv"].index("--kind") + 1] for c in w.appends()], ["round_open", "claim"])
        self.assertEqual(w.records("rev-a")[0]["payload"]["review_of"]["round_no"], 1)

    def test_failure_after_the_server_claim_leaves_it_visible_and_no_pane(self):
        w = self.world()
        self.subject_with_head(w)
        w.fault("append", "error:round_cap", kind="round_open")
        out = self.spawn_tester(w)
        self.assertRc(out, 78, "round_cap")
        self.assertEqual(len(w.records("rev-a")), 1, "the minted claim stays visible")
        self.assertEqual(w.herdr_calls(), [])

    def test_p1_shadow_subject_without_central_assignment_pauses_before_pane(self):
        w = self.world()
        w.mode("shadow")
        w.enroll("job-a", activate=False, tier="T1")
        w.local_claim("job-a")
        out = self.spawn_tester(w)
        self.assertRc(out, 73, "claim_conflict")
        self.assertEqual(w.appends(), [], "no host mint is attempted against a shadow subject")
        self.assertEqual(w.herdr_calls(), [])

    def test_p1_central_assignment_then_shadow_open_then_pane(self):
        w = self.world()
        w.mode("shadow")
        w.enroll("job-a", activate=False, tier="T1")
        w.local_claim("job-a")
        out = w.run("o3", "central", "assign", "rev-a", "--as", "director-1", "--target", "job-a", "--round", "1",
                    "--role", "tester")
        self.assertRc(out, 0)
        out = self.spawn_tester(w)
        self.assertRc(out, 0)
        self.assertEqual([c["argv"][c["argv"].index("--kind") + 1] for c in w.appends() if c["client"] != "director-1"],
                         ["round_open"])
        self.assertTrue(w.herdr_calls())

    def test_cross_host_subject_needs_a_central_assignment(self):
        w = self.world()
        w.mode("required")
        w.enroll("job-a", host="mac-dev", tier="T1")
        w.local_claim("job-a")
        out = self.spawn_tester(w)
        self.assertRc(out, 77, "host_mismatch")
        self.assertEqual(len(w.appends("claim")), 1, "the scoped mint reaches the server, which refuses it")
        self.assertEqual(w.appends("round_open"), [])
        self.assertEqual(w.herdr_calls(), [])


# ── 4. central desk tooling and import ────────────────────────────────────────


class CentralCase(O3Case):
    def test_central_writes_run_only_the_fixed_wrapper_with_scrubbed_env(self):
        w = self.world()
        w.mode("required")
        w.set_stub()
        out = w.run("o3", "central", "claim", "job-c", "--as", "operator-desk", "--owner-lane", "c-lane",
                    "--parent-lane", "director-1", "--task", "2400", "--host", "desktop", "--role", "builder",
                    "--tier", "T2", **{k: SENTINEL for k in SCRUBBED})
        self.assertRc(out, 0)
        call = w.appends("claim")[0]
        self.assertEqual(call["client"], "operator-desk")
        for key in SCRUBBED:
            self.assertNotIn(key, call["env_keys"])
        self.assertEqual(w.events("job-c"), [], "central tooling writes no local authority")
        self.assertNoLeak(w, out.stdout, out.stderr)
        self.assertEqual(w.run("o3", "central", "activate", "job-c", "--as", "pa-integrator").returncode, 2)

    def test_central_wrapper_outside_the_temp_roots_or_missing_is_refused(self):
        w = self.world()
        w.mode("required")
        w.set_stub()
        wrapper = w.home / ".local" / "bin" / "hk-director-1"
        wrapper.unlink()
        out = w.run("o3", "central", "activate", "job-c", "--as", "director-1")
        self.assertRc(out, 75, "transport_unavailable")
        p = self.world(production=True)
        p.mode("required")
        p.set_stub()
        os.chmod(p.home / ".local" / "bin" / "hk-director-1", 0o777)
        out = p.run("o3", "central", "activate", "job-c", "--as", "director-1")
        self.assertEqual(out.returncode, 2)
        self.assertIn("group- or world-writable", out.stderr)

    def test_import_begin_records_seal_then_activate_floors_the_budget(self):
        w = self.world()
        w.mode("required")
        w.set_stub()
        w.seed("job-i", "claim", {"job_id": "job-i", "owner_lane": "b2400-a", "parent_lane": "director-1",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "builder", "tier": "T2",
                                  "review_of": None, "predecessor_job_id": None, "supersedes": None})
        archive = w.base / "archive"
        shutil.copytree(PACK / "legacy" / "inflight" / "events", archive)
        for args in (["import-begin"], ["import", "--events-dir", archive], ["import", "--events-dir", archive],
                     ["import-seal", "--events-dir", archive]):
            out = w.run("o3", "central", args[0], "job-i", "--as", "director-1", *args[1:])
            self.assertRc(out, 0)
        imports = [r for r in w.records("job-i") if r["kind"] == "import"]
        self.assertEqual(len(imports), len(list(archive.glob("*.json"))), "a rerun imports nothing twice")
        for record in imports:
            data = Path(record["payload"]["source_locator"]).read_bytes()
            self.assertEqual(record["payload"]["source_sha256"], hashlib.sha256(data).hexdigest())
        seal = [r for r in w.records("job-i") if r["kind"] == "import_seal"][0]
        out = w.run("o3", "central", "activate", "job-i", "--as", "director-1", "--seal-seq", seal["seq"])
        self.assertRc(out, 0)
        self.assertEqual(w.events("job-i"), [])
        w.local_claim("job-i")
        out = w.run("round", "open", "job-i", "--head", w.heads[0])
        self.assertRc(out, 78, "round_cap")
        status = w.run("round", "status", "job-i")
        self.assertIn("rounds=3", status.stdout)
        self.assertIn("state=active", status.stdout)

    def test_import_seal_names_each_file_present_on_one_side_only(self):
        for direction in ("dir has extra", "server has extra"):
            with self.subTest(direction):
                w = self.world()
                w.mode("required")
                w.set_stub()
                w.seed("job-i", "claim", {"job_id": "job-i", "owner_lane": "b2400-a", "parent_lane": "director-1",
                                          "task_id": 2400, "host_client_id": "desktop", "role": "builder",
                                          "tier": "T2", "review_of": None, "predecessor_job_id": None,
                                          "supersedes": None})
                archive = w.base / "archive"
                shutil.copytree(PACK / "legacy" / "planted" / "events", archive)
                self.assertRc(w.run("o3", "central", "import-begin", "job-i", "--as", "director-1"), 0)
                self.assertRc(w.run("o3", "central", "import", "job-i", "--as", "director-1", "--events-dir",
                                    archive), 0)
                if direction == "dir has extra":
                    odd = archive / "00009-job.round.json"
                    odd.write_text('{"kind":"job.round","round":9}\n')
                    want = "only in --events-dir: %s" % odd
                else:
                    odd = sorted(archive.glob("*.json"))[0]
                    odd.unlink()
                    want = "only on the server: %s" % odd
                out = w.run("o3", "central", "import-seal", "job-i", "--as", "director-1", "--events-dir", archive)
                self.assertRc(out, 2)
                self.assertIn(want, out.stderr)
                self.assertEqual([r for r in w.records("job-i") if r["kind"] == "import_seal"], [])

    def test_import_seal_refuses_when_the_archive_differs(self):
        w = self.world()
        w.mode("required")
        w.set_stub()
        w.seed("job-i", "claim", {"job_id": "job-i", "owner_lane": "b2400-a", "parent_lane": "director-1",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "builder", "tier": "T2",
                                  "review_of": None, "predecessor_job_id": None, "supersedes": None})
        archive = w.base / "archive"
        shutil.copytree(PACK / "legacy" / "planted" / "events", archive)
        self.assertRc(w.run("o3", "central", "import-begin", "job-i", "--as", "director-1"), 0)
        self.assertRc(w.run("o3", "central", "import", "job-i", "--as", "director-1", "--events-dir", archive), 0)
        (archive / "00009-job.round.json").write_text('{"kind":"job.round","round":9}\n')
        out = w.run("o3", "central", "import-seal", "job-i", "--as", "director-1", "--events-dir", archive)
        self.assertRc(out, 2)
        self.assertIn("differ from the archive", out.stderr)
        self.assertEqual([r for r in w.records("job-i") if r["kind"] == "import_seal"], [])


# ── 5. the director-1 rule list (client-observable side) ─────────────────────


class RuleCase(O3Case):
    """Design rules the defective M1 vectors leave untested (director-1 list)."""

    def test_r1_duplicate_path_after_a_void_is_refused_and_not_projected(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        vfile = w.verdict_file("same.md", w.heads[0])
        self.assertRc(w.run("round", "verdict", "job-a", "--file", vfile), 0)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 0)
        grant = w.grant("job-a", "void", round_no=2)
        self.assertRc(w.run("round", "void", "job-a", "2", "--grant", grant["seq"]), 0)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[1]), 0)
        vfile.write_text("VERDICT: PASS @%s\nsame path, new bytes\n" % w.heads[1])
        out = w.run("round", "verdict", "job-a", "--file", vfile)
        self.assertRc(out, 73, "duplicate_path")
        self.assertEqual(len(w.events("job-a", "job.verdict")), 1)

    def test_r2_reviewer_end_after_an_accepted_pass_does_not_block_joined(self):
        w = self.world()
        w.enforced_builder()
        w.seed("rev-b", "claim", {"job_id": "rev-b", "owner_lane": "b2400-a", "parent_lane": "b2400-a",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "tester", "tier": "T2",
                                  "review_of": {"job_id": "job-a", "round_no": 1}, "predecessor_job_id": None,
                                  "supersedes": None}, client="desktop")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0], "--tester", "rev-b"), 0)
        self.assertRc(w.run("round", "verdict", "job-a", "--file", w.verdict_file("p.md", w.heads[0])), 0)
        w.seed("rev-b", "end", {"end_type": "reaped", "reason_code": "test_end"})
        report = w.base / "report.md"
        report.write_text("joined after reviewer cleanup\n")
        out = w.adapter("joined", "job-a", "--pr", "https://github.com/o/r/pull/1", "--head", w.heads[0],
                        "--report", report)
        self.assertRc(out, 0)
        self.assertIn("RECEIPT", out.stdout)

    def seal_world(self):
        w = self.world()
        w.mode("required")
        w.set_stub()
        w.seed("job-n", "claim", {"job_id": "job-n", "owner_lane": "b2400-a", "parent_lane": "director-1",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "builder", "tier": "T2",
                                  "review_of": None, "predecessor_job_id": None, "supersedes": None})
        archive = w.base / "archive"
        shutil.copytree(PACK / "legacy" / "inflight" / "events", archive)
        for args in (["import-begin"], ["import", "--events-dir", archive], ["import-seal", "--events-dir", archive]):
            self.assertRc(w.run("o3", "central", args[0], "job-n", "--as", "director-1", *args[1:]), 0)
        seal = [r for r in w.records("job-n") if r["kind"] == "import_seal"][0]
        self.assertRc(w.run("o3", "central", "activate", "job-n", "--as", "director-1", "--seal-seq", seal["seq"]), 0)
        w.local_claim("job-n")
        return w, seal

    def test_r10_post_import_numbering_round_4_with_the_extension(self):
        w, seal = self.seal_world()
        self.assertEqual((seal["payload"]["baseline_used"], seal["payload"]["numbering_floor"]), (3, 3))
        self.assertRc(w.run("round", "open", "job-n", "--head", w.heads[0]), 78, "round_cap")
        ext = w.grant("job-n", "extension", round_no=4, head=w.heads[0])
        out = w.run("round", "open", "job-n", "--head", w.heads[0], "--extension-grant", ext["seq"])
        self.assertRc(out, 0)
        self.assertIn("round=4", out.stdout)
        self.assertEqual(w.events("job-n", "job.round")[-1]["round"], 4)

    def test_r10_a_seal_with_floor_below_baseline_fails_closed(self):
        w, seal = self.seal_world()
        state = w.stub()
        records = state["jobs"]["job-n"]["records"]
        records[seal["seq"] - 1]["payload"]["numbering_floor"] = 2
        previous = records[seal["seq"] - 2]["record_hash"]
        for record in records[seal["seq"] - 1:]:
            record["previous_hash"] = previous
            record["record_hash"] = ADAPTER.record_hash(record)
            previous = record["record_hash"]
        w.set_stub(**state)
        (w.inbox / "job-n" / "o3-snapshot.json").unlink()
        (w.inbox / "job-n" / "o3-intents.json").unlink()
        out = w.run("round", "open", "job-n", "--head", w.heads[0])
        self.assertRc(out, 75, "protocol_invalid")
        self.assertEqual(w.events("job-n", "job.round"), [])

    def test_r4_consumed_extension_grant_is_grant_consumed(self):
        w = self.world()
        w.enforced_builder()
        for i in range(3):
            self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[i]), 0)
            self.assertRc(w.run("round", "verdict", "job-a", "--file", w.verdict_file("c%d.md" % i, w.heads[i])), 0)
        ext = w.grant("job-a", "extension", round_no=4, head=w.heads[3])
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[3], "--extension-grant", ext["seq"]), 0)
        out = w.run("round", "open", "job-a", "--head", w.heads[4], "--extension-grant", ext["seq"])
        self.assertRc(out, 73, "grant_consumed")
        self.assertEqual(len(w.events("job-a", "job.round")), 4)

    def test_r5_planted_events_activated_job_joined_is_zero_rounds(self):
        w = self.world()
        w.mode("required")
        w.set_stub()
        w.seed("job-p", "claim", {"job_id": "job-p", "owner_lane": "b2400-a", "parent_lane": "director-1",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "builder", "tier": "T2",
                                  "review_of": None, "predecessor_job_id": None, "supersedes": None})
        archive = w.base / "archive"
        shutil.copytree(PACK / "legacy" / "planted" / "events", archive)
        for args in (["import-begin"], ["import", "--events-dir", archive], ["import-seal", "--events-dir", archive]):
            self.assertRc(w.run("o3", "central", args[0], "job-p", "--as", "director-1", *args[1:]), 0)
        seal = [r for r in w.records("job-p") if r["kind"] == "import_seal"][0]
        self.assertRc(w.run("o3", "central", "activate", "job-p", "--as", "director-1", "--seal-seq", seal["seq"]), 0)
        report = w.base / "report.md"
        report.write_text("r\n")
        out = w.adapter("joined", "job-p", "--pr", "https://github.com/o/r/pull/1", "--head", w.heads[0],
                        "--report", report)
        self.assertRc(out, 73, "zero_rounds")

    def test_r6_director_joined_is_scope_denied_exit_77(self):
        w = self.world()
        w.enforced_builder()
        w.set_stub(client_id="director-1")
        report = w.base / "report.md"
        report.write_text("r\n")
        out = w.adapter("joined", "job-a", "--pr", "https://github.com/o/r/pull/1", "--head", w.heads[0],
                        "--report", report)
        self.assertRc(out, 77, "scope_denied")
        self.assertEqual(w.intents("job-a")[-1]["error"], "scope_denied")

    def test_r7_second_tester_on_a_head_needs_the_repeat_grant(self):
        w = self.world()
        w.enforced_builder()
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        self.assertRc(w.run("round", "verdict", "job-a", "--file", w.verdict_file("a.md", w.heads[0])), 0)
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 73, "duplicate_head")
        claim = w.records("job-a")[0]
        w.seed("rev-r", "claim", {"job_id": "rev-r", "owner_lane": "b2400-a", "parent_lane": "b2400-a",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "tester", "tier": "T2",
                                  "review_of": {"job_id": "job-a", "round_no": 2}, "predecessor_job_id": None,
                                  "supersedes": None}, client="desktop")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0], "--tester", "rev-r", "--repeat-grant",
                            claim["seq"]), 73, "grant_invalid")
        rep = w.grant("job-a", "head_repeat", round_no=2, head=w.heads[0], earlier=1, tester="rev-r")
        out = w.run("round", "open", "job-a", "--head", w.heads[0], "--tester", "rev-r", "--repeat-grant", rep["seq"])
        self.assertRc(out, 0)
        self.assertIn("round=2", out.stdout)

    def test_r8_verdict_for_another_assigned_tester_fails_the_assignment(self):
        w = self.world()
        w.enforced_builder()
        w.seed("rev-b", "claim", {"job_id": "rev-b", "owner_lane": "b2400-a", "parent_lane": "b2400-a",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "tester", "tier": "T2",
                                  "review_of": {"job_id": "job-a", "round_no": 1}, "predecessor_job_id": None,
                                  "supersedes": None}, client="desktop")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0], "--tester", "rev-b"), 0)
        out = w.run("round", "verdict", "job-a", "--file", w.verdict_file("v.md", w.heads[0]), "--tester", "rev-c")
        self.assertRc(out, 73, "round_not_open")
        self.assertEqual(w.events("job-a", "job.verdict"), [])
        # A reviewer ended before its verdict append: round_not_open, no verdict.
        w.seed("rev-b", "end", {"end_type": "reaped", "reason_code": "test_end"})
        out = w.run("round", "verdict", "job-a", "--file", w.verdict_file("v2.md", w.heads[0]))
        self.assertRc(out, 73, "round_not_open")
        self.assertEqual(w.events("job-a", "job.verdict"), [])

    def test_r3_reused_job_id_and_self_reference_reach_the_server_and_map_its_code(self):
        w = self.world()
        w.mode("required")
        w.enroll("job-a", tier="T1")
        w.local_claim("job-a")
        w.enroll("other-b", tier="T1", owner="other-lane")
        for job in ("other-b", "job-a"):
            with self.subTest(job):
                before = len(w.appends("claim"))
                out = w.spawn("--role", "tester", "--parent-job", "job-a", "--job", job, "--head", w.heads[0],
                              label=job)
                # The server answers (stale zero CAS on an existing id gives
                # sequence_conflict first, else claim_conflict); wrk reports it.
                self.assertEqual(out.returncode, 73, out.stderr)
                self.assertTrue("o3 sequence_conflict" in out.stderr or "o3 claim_conflict" in out.stderr, out.stderr)
                self.assertEqual(len(w.appends("claim")), before + 1)
                self.assertEqual(w.appends("round_open"), [])
                self.assertEqual(w.herdr_calls(), [])

    def test_r9_scoped_mint_for_another_host_is_host_mismatch_and_a_missing_subject_not_found(self):
        w = self.world()
        w.mode("required")
        w.enroll("job-a", host="mac-dev", tier="T1")
        w.local_claim("job-a")
        w.local_claim("job-missing")
        out = w.spawn("--role", "tester", "--parent-job", "job-a", "--job", "rev-a", "--head", w.heads[0],
                      label="rev-a")
        self.assertRc(out, 77, "host_mismatch")
        self.assertEqual(len(w.appends("claim")), 1)
        out = w.spawn("--role", "tester", "--parent-job", "job-missing", "--job", "rev-m", "--head", w.heads[0],
                      label="rev-m")
        self.assertRc(out, 66, "not_found")
        self.assertEqual(len(w.appends("claim")), 1)
        self.assertEqual(w.herdr_calls(), [])

    def test_r11_r12_replay_after_end_and_changed_body(self):
        w = self.world()
        w.enforced_builder()
        w.fault("append", "commit_then:transport_indeterminate", kind="round_open")
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 75)
        w.seed("job-a", "end", {"end_type": "revoked", "reason_code": "test_end"})
        out = w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertRc(out, 0)
        self.assertIn("resent=pending", out.stdout)
        doc = json.loads((w.inbox / "job-a" / "o3-intents.json").read_text())
        intent = doc["intents"][0]
        intent["state"] = "pending"
        intent["receipt"] = None
        changed = json.loads(json.dumps(intent))
        changed["local_id"] = str(uuid.uuid4())
        changed["request"]["payload"]["head"] = w.heads[1]
        changed["request_sha256"] = ADAPTER.request_sha256("job-a", changed["request"])
        doc["intents"] = [changed]
        (w.inbox / "job-a" / "o3-intents.json").write_text(json.dumps(doc))
        os.chmod(w.inbox / "job-a" / "o3-intents.json", 0o600)
        out = w.run("round", "open", "job-a", "--head", w.heads[1])
        # The same key with a changed body is idempotency_conflict (a definite
        # rejection that consumes no key); the fresh request then meets the end.
        self.assertIn("rejected on retry: idempotency_conflict", out.stderr)
        self.assertEqual(w.intents("job-a")[0]["error"], "idempotency_conflict")
        self.assertRc(out, 73, "job_ended")


class ServerOrderCase(O3Case):
    """director-1 C1 ruling: path/content identity, digest and scope checks are
    the server's; the client sends the request and reports the server's code."""

    def vector(self, name, table):
        cases = json.loads((PACK / "vectors" / table).read_text())["cases"]
        return next(c for c in cases if c["name"] == name)

    def verdict_vector_reaches_the_server(self, name, table):
        vec = self.vector(name, table)
        code = vec["expect"]["error"]
        w = self.world()
        w.enforced_builder()
        payload = vec["request"]["body"]["payload"]
        head = payload["head"]
        self.assertRc(w.run("round", "open", "job-a", "--head", w.heads[0]), 0)
        vfile = w.base / "vector.md"
        vfile.write_bytes(base64.b64decode(payload["content_b64"]).replace(head.encode(), w.heads[0].encode()))
        w.fault("append", "error:" + code, kind="verdict")
        out = w.run("round", "verdict", "job-a", "--file", vfile)
        self.assertRc(out, ADAPTER.EXIT[code], code)
        self.assertEqual(len(w.appends("verdict")), 1, "the request reached the server")
        self.assertEqual(w.events("job-a", "job.verdict"), [])
        self.assertEqual(w.intents("job-a")[-1]["error"], code)

    def test_replay_old_verdict_fresh_key_same_path_is_the_servers_duplicate_path(self):
        self.verdict_vector_reaches_the_server("replay-old-verdict-fresh-key-same-path", "failure-abuse.json")

    def test_same_bytes_fresh_path_is_the_servers_duplicate_content(self):
        self.verdict_vector_reaches_the_server("same-bytes-fresh-path-duplicate-content", "transition.json")

    def test_reviewer_import_is_the_servers_scope_denied(self):
        vec = self.vector("r-import-scope-denied", "r4-review-lifecycle.json")
        self.assertEqual(vec["expect"]["error"], "scope_denied")
        w = self.world()
        w.mode("required")
        w.enroll("job-a")
        w.seed("rev-a", "claim", {"job_id": "rev-a", "owner_lane": "b2400-a", "parent_lane": "b2400-a",
                                  "task_id": 2400, "host_client_id": "desktop", "role": "tester", "tier": "T2",
                                  "review_of": {"job_id": "job-a", "round_no": 1}, "predecessor_job_id": None,
                                  "supersedes": None}, client="desktop")
        archive = w.base / "archive"
        shutil.copytree(PACK / "legacy" / "completed" / "events", archive)
        out = w.run("o3", "central", "import", "rev-a", "--as", "director-1", "--events-dir", archive)
        self.assertRc(out, 77, "scope_denied")
        self.assertEqual(len(w.appends("import")), 1, "the import reached the server")
        self.assertEqual(w.intents("rev-a")[-1]["error"], "scope_denied")


def synth_response(job, request, idem, given, expect):
    """A contract-valid WriteResponse for a pack 2xx vector: the expected
    payload over defaults derived from the request, hashed like the server."""
    kind = request["kind"]
    payload = {k: v for k, v in request["payload"].items() if k not in ("content_b64", "report_b64")}
    content = request["payload"].get("content_b64") or request["payload"].get("report_b64")
    size = len(base64.b64decode(content)) if content else 1
    defaults = {"claim": {"policy_sha256": "0" * 64, "created_at": "2026-10-24T00:00:00.000001Z"},
                "activate": {"baseline_used": 0, "mode": "enforced"}, "round_open": {"round_no": 1},
                "verdict": {"size_bytes": size}, "completed": {"report_size_bytes": size, "warnings": []},
                "joined": {"report_size_bytes": size, "verdict_seqs": []}, "import_begin": {"shadow_cutoff_seq": 0},
                "import_seal": {"shadow_cutoff_seq": 0, "baseline_used": 3, "numbering_floor": 3}}
    payload.update(defaults.get(kind, {}))
    payload.update(((expect.get("record") or {}).get("payload")) or {})
    payload = {k: v for k, v in payload.items() if k in ADAPTER.PAYLOAD_KEYS[kind]}
    generation = given[-1]["store_generation"] if given else "00000000-0000-4000-8000-ffff00000001"
    seq = len(given) + 1
    claims = [r["seq"] for r in given if r["kind"] == "claim"]
    record = {"job_id": job, "seq": seq, "record_id": str(uuid.uuid4()), "store_generation": generation,
              "claim_seq": seq if kind == "claim" else (claims[-1] if claims else 1), "actor_client_id": "desktop",
              "idempotency_key": idem, "request_sha256": ADAPTER.request_sha256(job, request),
              "imported": kind == "import", "received_at": "2026-10-24T00:00:01.000000Z",
              "source": ({"source_locator": request["payload"]["source_locator"],
                          "source_sha256": request["payload"]["source_sha256"]} if kind == "import" else None),
              "previous_hash": given[-1]["record_hash"] if given else "0" * 64, "kind": kind, "payload": payload}
    record["record_hash"] = ADAPTER.record_hash(record)
    summary = {"job_id": job, "claim_seq": record["claim_seq"], "snapshot_seq": seq, "state": "active",
               "baseline_used": 0, "used": 0, "cap": 3, "next_round_no": 1, "open_rounds": [], "last_verdict_seq": None,
               "active_grants": [], "warnings": [], "store_generation": generation, "tail_hash": record["record_hash"]}
    summary.update({k: v for k, v in (expect.get("summary") or {}).items() if k in summary})
    return {"contract": "hk1873.v1", "created": bool(expect.get("created", expect["http_status"] == 201)),
            "record": record, "summary": summary}


class PackHttpVectorCase(O3Case):
    """Every POST vector of the pack through the adapter's real send: the
    server's answer is scripted to the pack's expected result; a 4xx code is a
    definite rejection with its exit, a 503 keeps the intent pending, a 2xx is
    an accepted receipt. No vector is pre-empted by a client check."""

    def test_every_post_vector_maps_through_the_adapter(self):
        w = self.world()
        w.mode("required")
        seen = 0
        saved = dict(os.environ)
        env = w.env()
        os.environ.clear()
        os.environ.update(env)
        try:
            for path in sorted((PACK / "vectors").glob("*.json")):
                for vec in json.loads(path.read_text())["cases"]:
                    request = vec["request"]
                    if request.get("type") != "http" or request.get("method") != "POST":
                        continue
                    with self.subTest((path.name, vec["name"])):
                        seen += 1
                        job = request["path"].split("/")[4]
                        body = request["body"]
                        expect = vec["expect"]
                        w.state.unlink() if w.state.exists() else None
                        shutil.rmtree(w.inbox / job, True)
                        w.set_stub()
                        status = expect["http_status"]
                        if status in (200, 201):
                            response = w.base / "response.json"
                            response.write_text(json.dumps(synth_response(
                                job, body, request["idempotency_key"], vec["given"].get("records") or [], expect)))
                            w.fault("append", "respond_file:%s" % response, kind=body["kind"])
                        else:
                            w.fault("append", "error:" + expect["error"], kind=body["kind"])
                        with ADAPTER.Intents(str(w.inbox), job) as store:
                            intent = store.new(body)
                            intent["idempotency_key"] = request["idempotency_key"]
                            store.save()
                            if status in (200, 201):
                                outcome = ADAPTER.send(store, intent)
                                self.assertEqual(intent["state"], "accepted")
                                self.assertEqual(outcome.created, status == 201)
                            else:
                                with self.assertRaises(ADAPTER.Fail) as ctx:
                                    ADAPTER.send(store, intent)
                                self.assertEqual(ctx.exception.code, expect["error"])
                                self.assertEqual(intent["state"], "pending" if status == 503 else "rejected")
                        sent = w.appends()[-1]
                        self.assertEqual(json.loads(base64.b64decode(sent["stdin_b64"])), body["payload"])
                        argv = sent["argv"]
                        self.assertEqual((argv[argv.index("--expected-seq") + 1], argv[argv.index("--claim-seq") + 1]),
                                         (str(body["expected_seq"]), str(body["claim_seq"])))
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertGreater(seen, 80)


# ── 6. adapter unit checks ────────────────────────────────────────────────────


class CursorCase(O3Case):
    """director-1 cursor ruling: limit, after_seq and snapshot_seq pass through
    unchanged when they are safe integers; the server answers invalid_cursor."""

    def test_cursor_boundaries(self):
        w = self.world()
        w.mode("required")
        w.enroll("job-a")
        cases = [("--limit", "0", 65), ("--limit", "-1", 65), ("--limit", "1", 0), ("--limit", "500", 0),
                 ("--limit", "501", 65), ("--limit", str(2 ** 53 - 1), 65), ("--limit", str(2 ** 53), 2),
                 ("--limit", "1.5", 2), ("--limit", "1e3", 2), ("--limit", "0x10", 2), ("--limit", " 5", 2),
                 ("--limit", "", 2), ("--limit", str(-(2 ** 53 - 1)), 65), ("--limit", str(-(2 ** 53)), 2),
                 ("--after-seq", "-1", 65), ("--after-seq", "0", 0), ("--after-seq", str(2 ** 53), 2),
                 ("--snapshot-seq", "0", 65), ("--snapshot-seq", "1", 0), ("--snapshot-seq", "1.0", 2)]
        for flag, value, rc in cases:
            with self.subTest((flag, value)):
                before = len(w.calls())
                out = w.adapter("records", "job-a", flag, value)
                self.assertEqual(out.returncode, rc, out.stderr)
                sent = w.calls()[before:]
                if rc == 2:
                    self.assertIn("o3 cli_usage", out.stderr)
                    self.assertEqual(sent, [], "nothing is sent for an unsendable cursor")
                else:
                    self.assertEqual(len(sent), 1)
                    self.assertEqual(sent[0]["argv"], ["wrk", "records", "job-a", flag, value], "passed unchanged")
                    if rc == 65:
                        self.assertIn("o3 invalid_cursor", out.stderr)
        before = len(w.calls())
        out = w.adapter("records", "job-a")
        self.assertRc(out, 0)
        self.assertEqual(w.calls()[before]["argv"], ["wrk", "records", "job-a"], "omitted flags are not sent")
        self.assertEqual(json.loads(out.stdout)["snapshot_seq"], 2)


class AdapterUnitCase(O3Case):
    def test_canonical_json_sorts_by_utf16_and_rejects_floats(self):
        self.assertEqual(ADAPTER.canonical({"b": 1, "a": [True, None, "é"], "\U0001f600": 0, "￿": 1}),
                         '{"a":[true,null,"é"],"b":1,"\U0001f600":0,"￿":1}')
        with self.assertRaises(ValueError):
            ADAPTER.canonical(1.5)

    def test_cli_output_parsing_is_strict(self):
        cases = [(0, b'{"a":1}', b"", None), (0, b'{"a":1}\n', b"", {"a": 1}),
                 (0, b'{"a":1,"a":2}\n', b"", "protocol_invalid"), (0, b"[1]\n", b"", "protocol_invalid"),
                 (73, b"", b"handoffkeep wrk: round_cap\n", "protocol_invalid"),
                 (78, b"", b"handoffkeep wrk: round_cap\n", "round_cap"),
                 (78, b"x", b"handoffkeep wrk: round_cap\n", "protocol_invalid"),
                 (75, b"", b"handoffkeep wrk: transport_indeterminate\n", "transport_indeterminate")]
        for rc, out, err, want in cases:
            with self.subTest((rc, out, err)):
                w = self.world()
                script = w.base / "fake.py"
                script.write_text("import sys,os\nsys.stdout.buffer.write(%r)\nsys.stderr.buffer.write(%r)\n"
                                  "sys.exit(%d)\n" % (out, err, rc))
                write_exec(w.hk, "#!/bin/sh\nexec python3 '%s'\n" % script)
                env = w.env()
                saved = dict(os.environ)
                os.environ.clear()
                os.environ.update(env)
                try:
                    if isinstance(want, dict):
                        self.assertEqual(ADAPTER.run_cli(["capabilities"]), want)
                    else:
                        with self.assertRaises(ADAPTER.CliFail) as ctx:
                            ADAPTER.run_cli(["capabilities"])
                        self.assertEqual(ctx.exception.code, want or "protocol_invalid")
                finally:
                    os.environ.clear()
                    os.environ.update(saved)

    def test_receipt_required_predicate(self):
        def state(kinds):
            records = []
            for kind, payload in kinds:
                records.append({"kind": kind, "imported": False, "payload": payload})
            return ADAPTER.State("j", records[0], {"snapshot_seq": len(records), "store_generation": "g"}, records)
        builder = {"role": "builder", "review_of": None}
        self.assertFalse(state([("claim", builder)]).receipt_required)
        self.assertTrue(state([("claim", builder), ("activate", {})]).receipt_required)
        self.assertTrue(state([("claim", {"role": "tester", "review_of": {"job_id": "a", "round_no": 1}})])
                        .receipt_required)
        self.assertFalse(state([("claim", {"role": "tester", "review_of": None})]).receipt_required)


# ── 7. mutants at the real call sites ─────────────────────────────────────────


class MutantCase(O3Case):
    def mutant_bin(self, mutations):
        root = Path(os.path.realpath(tempfile.mkdtemp(prefix="o3m-", dir=os.environ.get("TMPDIR") or "/tmp")))
        self.addCleanup(shutil.rmtree, root, True)
        target = root / "bin"
        shutil.copytree(BIN, target)
        for name, old, new in mutations:
            path = target / name
            path.write_text(mutate(path.read_text(), old, new))
        return target

    def test_m1_later_cursor_page_through_path_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''    decision = guard(need_hk=True)
    if binary is None:
        binary = decision.hk''', '''    decision = guard(need_hk=True)
    if binary is None:
        binary = decision.hk
        if "--snapshot-seq" in args:
            import shutil as _sh
            binary = _sh.which("handoffkeep", path=os.environ.get("PATH")) or binary''')])
        out, w, pages = TransportVectorCase.scenario_cursor_pages_use_the_canonical_binary(self, bindir)
        self.assertTrue(w.spy_log.exists(), "the mutant's later page must reach the PATH spy")

    def test_m1b_hk_bin_helper_for_reads_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''    decision = guard(need_hk=True)
    if binary is None:
        binary = decision.hk''', '''    decision = guard(need_hk=True)
    if binary is None:
        binary = subprocess.run(["bash", "-c", 'command -v "${HANDOFFKEEP_BIN:-handoffkeep}"'],
                                stdout=subprocess.PIPE, text=True).stdout.strip() or decision.hk''')])
        out, w, pages = TransportVectorCase.scenario_cursor_pages_use_the_canonical_binary(self, bindir)
        self.assertTrue(w.spy_log.exists())

    def test_m2_send_before_the_intent_fsync_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''    intent = store.new(request)
    store.save()
    crash_point("before_send")
    return send(store, intent, binary)''', '''    intent = store.new(request)
    try:
        return send(store, intent, binary)
    finally:
        store.save()''')])
        w = self.world(bindir=bindir)
        w.enforced_builder()
        w.run("round", "open", "job-a", "--head", w.heads[0], WRK_O3_TEST_FAULT="fsync_fail")
        self.assertNotEqual(w.appends("round_open"), [], "the mutant sends an unsaved intent")

    def test_m3_retry_with_a_fresh_key_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''    for outcome in resume(store, binary):
        if outcome.intent["request"]["kind"] == kind:''', '''    for intent in store.pending():
        intent["state"], intent["error"] = "rejected", "sequence_conflict"
    for outcome in []:
        if outcome.intent["request"]["kind"] == kind:''')])
        w = self.world(bindir=bindir)
        w.enforced_builder()
        w.fault("append", "commit_then:transport_indeterminate", kind="round_open")
        w.run("round", "open", "job-a", "--head", w.heads[0])
        w.run("round", "open", "job-a", "--head", w.heads[0])
        keys = {c["argv"][c["argv"].index("--idempotency-key") + 1] for c in w.appends("round_open")}
        self.assertEqual(len(keys), 2, "the mutant retried with a new key")

    def test_m4_reject_on_5xx_or_malformed_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''        if exc.code in DEFINITE or exc.code == "cli_usage":''',
                                   '''        if exc.code in DEFINITE or exc.code in ("cli_usage", "wrk_unavailable", "protocol_invalid"):''')])
        w = self.world(bindir=bindir)
        w.enforced_builder()
        w.fault("append", "commit_then:wrk_unavailable", kind="round_open")
        w.run("round", "open", "job-a", "--head", w.heads[0])
        self.assertEqual([i["state"] for i in w.intents("job-a")], ["rejected"])

    def test_m5_local_verdict_before_receipt_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''        with Intents(ctx.inbox, job) as store:
            state = decision.state
            mode = o3_mode_name(state)
            repair(ctx, job, store, state, meta)

            def build(fresh):
                number, tester = verdict_round(fresh, head)''', '''        with Intents(ctx.inbox, job) as store:
            state = decision.state
            mode = o3_mode_name(state)
            repair(ctx, job, store, state, meta)
            _n, _t = verdict_round(state, head)
            _fake = {"kind": "verdict", "job_id": job, "seq": 0, "record_hash": "0" * 64, "store_generation": "",
                     "idempotency_key": "early", "payload": dict(payload_for(_n or 1, _t), size_bytes=1)}
            write_projections(ctx.inbox, job, [_fake], mode, meta, "early")

            def build(fresh):
                number, tester = verdict_round(fresh, head)''')])
        w, out = MatrixCase.scenario_refused_verdict_writes_no_event(self, bindir)
        self.assertNotEqual(w.events("job-a", "job.verdict"), [], "the mutant wrote job.verdict before the receipt")

    def test_m6_warning_branch_for_a_review_role_job_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''            if (ctx.mode == "shadow" and snapshot is not None and not snapshot.get("receipt_required")
                    and not snapshot.get("activated") and snapshot.get("role") in ("builder", "worker")''',
                                   '''            if (ctx.mode == "shadow" and snapshot is not None
                    and not snapshot.get("activated")''')])
        w, out = ShadowCase.scenario_review_role_job_never_warns(self, bindir)
        self.assertTrue(w.events("rev-a", "job.o3_warning") or w.events("rev-a", "job.round"))

    def test_m7_free_waiver_ref_accepted_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''    if opts.get("--rounds-waived"):
        raise Fail(''', '''    if opts.get("--rounds-waived") and False:
        raise Fail(''')])
        w, out = MatrixCase.scenario_free_waiver_refused(self, bindir / "wrk_o3.py")
        self.assertNotEqual(out.returncode, 2, "the mutant accepted the free waiver ref")

    def test_m8_one_override_key_passed_through_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py", '''SCRUB = ("HANDOFFKEEP_URL", "HANDOFFKEEP_TOKEN", "HANDOFFKEEP_CF_ACCESS_CLIENT_ID",
         "HANDOFFKEEP_CF_ACCESS_CLIENT_SECRET")''', '''SCRUB = ("HANDOFFKEEP_URL", "HANDOFFKEEP_CF_ACCESS_CLIENT_ID",
         "HANDOFFKEEP_CF_ACCESS_CLIENT_SECRET")''')])
        w, out = TransportVectorCase.scenario_env_keys_scrubbed(self, bindir)
        self.assertTrue(any("HANDOFFKEEP_TOKEN" in c["env_keys"] for c in w.calls()))

    def test_m10_ignoring_the_enrollment_witness_goes_red(self):
        bindir = self.mutant_bin([("wrk_o3.py",
                                   "            if state is None and (retained or snapshot is not None):\n",
                                   "            if state is None and False:\n")])
        w, out = RegressedHistoryCase.scenario_not_found_after_a_receipt(self, bindir)
        self.assertEqual(out.returncode, 0, "the mutant fell back to the legacy path")
        self.assertEqual(len(w.events("job-a", "job.round")), 2)

    def test_m9_legacy_spawn_skipping_the_legacy_task_calls_goes_red(self):
        bindir = self.mutant_bin([("wrk", '''  elif [[ "$O3_SPAWN_VERIFIED" != 1 ]]; then
    hk_task_precheck
  fi''', '''  elif [[ "$O3_SPAWN_VERIFIED" == 1 ]]; then
    hk_task_precheck
  else
    TASK_LINK_STATUS=already_linked
  fi'''), ("wrk", '''  [[ "$O3_SPAWN_VERIFIED" == 1 ]] ||
  hk_task_link''', '''  :''')])
        w, out = SpawnCase.scenario_legacy_spawn_makes_both_task_calls(self, bindir)
        log = w.tasks_log.read_text() if w.tasks_log.exists() else ""
        self.assertNotIn("claim id=2400", log, "the mutant must have skipped the legacy link")


if __name__ == "__main__":
    unittest.main()
