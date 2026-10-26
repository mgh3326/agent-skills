#!/usr/bin/env python3
"""hk 1926 (O3 C1): the one wrk adapter for the canonical handoffkeep wrk CLI.

Design: hk:doc designs/hk1873/b1873a-sol-r4 (sections 2, 4, 5, 6 and 6b).
The handoffkeep server is the authority for claims, rounds, verdicts, grants
and joins of an enrolled job. This module is the only place wrk talks to it:

* transport (6b): argv only, no shell, exactly the five "handoffkeep wrk"
  subcommands, through the binary the PR 242 trust guard selects. The guard is
  re-run before EVERY call, including each later cursor page, and its source is
  read from the sibling bin/wrk, never from the environment. The four
  HANDOFFKEEP_* override keys are removed from the child environment by key.
  No token or config file is read here, nothing speaks HTTP, and there is no
  curl or env-token fallback.
* durable intents (6b): <canonical job dir>/o3-intents.json, mode 0600, no
  symlink, serialized by o3-intents.lock, written by atomic rename with file
  and directory fsync before every send. An unknown outcome keeps the intent
  pending and is retried with its original key and body; only a validated 4xx
  stable code rejects it.
* exit map (6b): every stable code keeps its process exit; round_cap stays 78.
* reads (5): GET job plus every records page at one fixed snapshot, with seq
  continuity, the hash chain, each record_hash and the retained receipts
  checked before any decision.
* commands: the section 6 round commands, the spawn handshake, the completed
  and joined adapter operations and the central desk tooling.

The real wrk round/spawn commands call this file; wrk itself keeps every O2
guard for reads O3 does not replace.
"""
import base64
import datetime
import errno
import fcntl
import hashlib
import json
import os
import pwd
import re
import stat
import subprocess
import sys
import uuid

CONTRACT = "hk1873.v1"
HERE = os.path.dirname(os.path.realpath(__file__))
WRK_SOURCE = os.path.join(HERE, "wrk")

# 6b: stable code -> process exit. One code always maps to one exit.
EXIT = {"round_cap": 78, "wrk_unavailable": 75, "wrk_recovery_required": 75}
for _code in ("unauthorized", "scope_denied", "host_mismatch"):
    EXIT[_code] = 77
EXIT["not_found"] = 66
for _code in ("invalid_request", "invalid_cursor", "invalid_verdict", "invalid_path", "grant_before_cap",
              "request_too_large", "method_not_allowed", "unsupported_media_type"):
    EXIT[_code] = 65
SERVER_409 = ("idempotency_conflict", "sequence_conflict", "claim_conflict", "job_ended", "review_sealed",
              "round_not_open", "round_has_verdict", "round_voided", "head_mismatch", "duplicate_path",
              "duplicate_content", "duplicate_head", "grant_invalid", "grant_consumed", "grant_expired",
              "zero_rounds", "review_incomplete", "blocker_unresolved", "wrk_receipt_required",
              "import_unsealed", "import_sealed", "migration_frozen")
for _code in SERVER_409:
    EXIT[_code] = 73
EXIT["cli_usage"] = 2
for _code in ("transport_unavailable", "transport_indeterminate", "protocol_invalid", "o3_unsupported",
              "history_regressed"):
    EXIT[_code] = 75
EXIT["intent_invalid"] = 74
EXIT["intent_io"] = 74
# wrk-local refusals that are not handoffkeep codes: the PR 242 trust-path
# refusal and an unusable records-mode file both answer 2 before any exec.
EXIT["trust_path"] = 2
EXIT["records_mode_invalid"] = 2
EXIT["usage"] = 2
# 6 step 3: the receipt is stored but the local projection did not land.
EXIT["projection_pending"] = 75
# Codes the server returns with an HTTP 4xx: a validated one is a definite
# rejection. 503 codes and every local transport/protocol code are not.
SERVER_CODES = set(EXIT) - {"cli_usage", "transport_unavailable", "transport_indeterminate", "protocol_invalid",
                            "o3_unsupported", "history_regressed", "intent_invalid", "intent_io", "trust_path",
                            "records_mode_invalid", "usage", "projection_pending"}
DEFINITE = SERVER_CODES - {"wrk_unavailable", "wrk_recovery_required"}
CLI_CODES = SERVER_CODES | {"cli_usage", "transport_unavailable", "transport_indeterminate", "protocol_invalid",
                            "o3_unsupported", "history_regressed", "intent_invalid", "intent_io"}
# The four keys a caller could use to point the child at another endpoint or identity.
SCRUB = ("HANDOFFKEEP_URL", "HANDOFFKEEP_TOKEN", "HANDOFFKEEP_CF_ACCESS_CLIENT_ID",
         "HANDOFFKEEP_CF_ACCESS_CLIENT_SECRET")
CENTRAL_ROLES = ("director-1", "operator-desk")
REVIEW_ROLES = ("tester", "reviewer", "counsel")
WRITE_KINDS = ("claim", "activate", "round_open", "verdict", "void", "joined", "completed", "grant",
               "grant_cancel", "end", "import", "import_begin", "import_seal")
RECORD_KEYS = {"job_id", "seq", "record_id", "store_generation", "claim_seq", "actor_client_id",
               "idempotency_key", "request_sha256", "imported", "source", "received_at", "previous_hash",
               "record_hash", "kind", "payload"}
PAYLOAD_KEYS = {
    "claim": {"created_at", "host_client_id", "job_id", "owner_lane", "parent_lane", "policy_sha256",
              "predecessor_job_id", "review_of", "role", "supersedes", "task_id", "tier"},
    "activate": {"baseline_used", "mode", "reason_code", "seal_seq"},
    "round_open": {"extension_grant_seq", "head", "repeat_grant_seq", "round_no", "tester_job_id"},
    "verdict": {"content_sha256", "head", "path", "round_no", "size_bytes", "tester_job_id", "verdict"},
    "void": {"grant_seq", "reason_code", "round_no"},
    "joined": {"head", "pr", "report_sha256", "report_size_bytes", "verdict_seqs", "waiver_grant_seq"},
    "completed": {"report_sha256", "report_size_bytes", "warnings"},
    "grant": {"earlier_round_no", "expires_at", "extra", "grant_type", "head", "reason_code", "round_no",
              "tester_job_id"},
    "grant_cancel": {"grant_seq", "reason_code"},
    "end": {"end_type", "reason_code"},
    "import": {"legacy_kind", "original_actor_client_id", "original_at", "source_locator", "source_sha256"},
    "import_begin": {"reason_code", "shadow_cutoff_seq"},
    "import_seal": {"baseline_used", "begin_seq", "expected_import_count", "manifest_sha256",
                    "numbering_floor", "reason_code", "shadow_cutoff_seq"},
}
SUMMARY_KEYS = {"job_id", "claim_seq", "snapshot_seq", "state", "baseline_used", "used", "cap", "next_round_no",
                "open_rounds", "last_verdict_seq", "active_grants", "warnings", "store_generation", "tail_hash"}
STATES = ("shadow", "importing", "sealed", "active", "joined", "ended")
SAFE_MAX = 9007199254740991
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
HEAD_RE = re.compile(r"^[0-9a-f]{40}$")
JOB_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
LANE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
CODE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
ZERO_HASH = "0" * 64
MAX_CONTENT = 262144
INTENTS = "o3-intents.json"
INTENTS_LOCK = "o3-intents.lock"
SNAPSHOT = "o3-snapshot.json"
MODES = ("legacy", "shadow", "required")
# 5: the strict first-line verdict grammar (an O3 submission never uses the
# O2 anywhere-in-file parser).
VERDICT_HEADER = re.compile(r"^VERDICT: (PASS|BLOCKER) @([0-9a-fA-F]{40})[ \t]*\r?$")


class Fail(Exception):
    """A refusal with a stable code; the process exits with EXIT[code]."""

    def __init__(self, code, detail=""):
        Exception.__init__(self, code)
        self.code = code
        self.detail = detail


class CliFail(Exception):
    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def test_mode():
    return os.environ.get("WRK_TEST_MODE") == "1"


def test_hook(name):
    """Crash and fault seams for the suites; inert outside WRK_TEST_MODE=1."""
    if not test_mode():
        return False
    wanted = os.environ.get("WRK_O3_TEST_FAULT", "")
    return name in wanted.split(",")


def crash_point(name):
    if test_hook("crash_" + name):
        os._exit(137)


# ── canonical JSON (RFC 8785 for the integer/string/bool/null data O3 uses) ──

def canonical(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ",".join(canonical(item) for item in value) + "]"
    if isinstance(value, dict):
        keys = sorted(value, key=lambda key: key.encode("utf-16-be"))
        return "{" + ",".join(json.dumps(key, ensure_ascii=False) + ":" + canonical(value[key]) for key in keys) + "}"
    raise ValueError("value outside the O3 JSON domain")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def request_sha256(job, request):
    """5: SHA256(RFC8785({method, path, body})) with the entire Request as body."""
    document = {"method": "POST", "path": "/v1/wrk/jobs/" + job + "/records", "body": request}
    return sha256_hex(canonical(document).encode("utf-8"))


def record_hash(record):
    return sha256_hex(canonical({k: v for k, v in record.items() if k != "record_hash"}).encode("utf-8"))


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _no_constant(value):
    raise ValueError("non-JSON constant")


def strict_loads(text):
    return json.loads(text, object_pairs_hook=_unique, parse_constant=_no_constant,
                      parse_float=lambda _v: (_ for _ in ()).throw(ValueError("float")))


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


# ── contract shape checks for CLI stdout (anything else is protocol_invalid) ──

def _int(value, low=0):
    return isinstance(value, int) and not isinstance(value, bool) and low <= value <= SAFE_MAX


def _opt_int(value, low=1):
    return value is None or _int(value, low)


def _opt_job(value):
    return value is None or (isinstance(value, str) and JOB_RE.match(value) is not None)


def _need(condition):
    if not condition:
        raise CliFail("protocol_invalid")


def check_summary(summary, job):
    _need(isinstance(summary, dict) and set(summary) == SUMMARY_KEYS)
    _need(summary["job_id"] == job)
    _need(_int(summary["claim_seq"], 1) and _int(summary["snapshot_seq"], 1))
    _need(summary["state"] in STATES and summary["cap"] == 3)
    _need(_int(summary["baseline_used"]) and _int(summary["used"]) and _int(summary["next_round_no"], 1))
    _need(isinstance(summary["open_rounds"], list) and all(_int(n, 1) for n in summary["open_rounds"]))
    _need(isinstance(summary["active_grants"], list) and all(_int(n, 1) for n in summary["active_grants"]))
    _need(_opt_int(summary["last_verdict_seq"]))
    _need(isinstance(summary["warnings"], list) and all(isinstance(w, str) and CODE_RE.match(w)
                                                        for w in summary["warnings"]))
    _need(isinstance(summary["store_generation"], str) and UUID_RE.match(summary["store_generation"]))
    _need(isinstance(summary["tail_hash"], str) and HEX64_RE.match(summary["tail_hash"]))
    return summary


def check_payload(kind, payload):
    _need(isinstance(payload, dict) and set(payload) == PAYLOAD_KEYS[kind])
    if kind == "claim":
        _need(isinstance(payload["job_id"], str) and JOB_RE.match(payload["job_id"]))
        _need(payload["role"] in ("builder", "worker") + REVIEW_ROLES)
        _need(_int(payload["task_id"], 1) and payload["tier"] in ("T0", "T1", "T2", "T3"))
        _need(isinstance(payload["owner_lane"], str) and isinstance(payload["parent_lane"], str))
        _need(isinstance(payload["host_client_id"], str))
        review = payload["review_of"]
        _need(review is None or (isinstance(review, dict) and set(review) == {"job_id", "round_no"}
                                 and _opt_job(review["job_id"]) and _int(review["round_no"], 1)))
    elif kind == "round_open":
        _need(_int(payload["round_no"], 1) and isinstance(payload["head"], str) and HEAD_RE.match(payload["head"]))
        _need(_opt_job(payload["tester_job_id"]))
        _need(_opt_int(payload["extension_grant_seq"]) and _opt_int(payload["repeat_grant_seq"]))
    elif kind == "verdict":
        _need(_int(payload["round_no"], 1) and isinstance(payload["head"], str) and HEAD_RE.match(payload["head"]))
        _need(payload["verdict"] in ("PASS", "BLOCKER") and isinstance(payload["path"], str))
        _need(isinstance(payload["content_sha256"], str) and HEX64_RE.match(payload["content_sha256"]))
        _need(_int(payload["size_bytes"], 1) and _opt_job(payload["tester_job_id"]))
    elif kind == "void":
        _need(_int(payload["round_no"], 1) and _int(payload["grant_seq"], 1))
    elif kind == "grant":
        _need(payload["grant_type"] in ("extension", "void", "head_repeat", "join_waiver"))
        _need(_opt_int(payload["round_no"]) and _opt_int(payload["earlier_round_no"]))
        _need(payload["head"] is None or (isinstance(payload["head"], str) and HEAD_RE.match(payload["head"])))
        _need(_opt_job(payload["tester_job_id"]))
    elif kind == "joined":
        _need(isinstance(payload["verdict_seqs"], list) and all(_int(n, 1) for n in payload["verdict_seqs"]))
        _need(_opt_int(payload["waiver_grant_seq"]))
    elif kind == "import":
        _need(isinstance(payload["source_locator"], str) and isinstance(payload["source_sha256"], str))
    elif kind == "import_begin":
        _need(_int(payload["shadow_cutoff_seq"]))
    elif kind == "import_seal":
        # 5: numbering_floor = max(baseline_used, ...); a seal below its own
        # baseline is not a server answer this client can trust.
        _need(_int(payload["baseline_used"]) and _int(payload["numbering_floor"]))
        _need(payload["numbering_floor"] >= payload["baseline_used"])
    elif kind == "end":
        _need(payload["end_type"] in ("revoked", "reaped", "handed_off"))


def check_record(record, job):
    _need(isinstance(record, dict) and set(record) == RECORD_KEYS)
    _need(record["job_id"] == job and _int(record["seq"], 1) and _int(record["claim_seq"]))
    for key in ("record_id", "store_generation", "idempotency_key"):
        _need(isinstance(record[key], str) and UUID_RE.match(record[key]) is not None)
    for key in ("request_sha256", "previous_hash", "record_hash"):
        _need(isinstance(record[key], str) and HEX64_RE.match(record[key]) is not None)
    _need(isinstance(record["actor_client_id"], str) and JOB_RE.match(record["actor_client_id"]))
    _need(isinstance(record["imported"], bool) and isinstance(record["received_at"], str))
    _need(record["kind"] in PAYLOAD_KEYS)
    source = record["source"]
    if record["kind"] == "import":
        _need(isinstance(source, dict) and set(source) == {"source_locator", "source_sha256"})
    else:
        _need(source is None)
    check_payload(record["kind"], record["payload"])
    # 2: record_hash covers every record field except itself.
    _need(record_hash(record) == record["record_hash"])
    return record


def check_write(obj, job):
    _need(set(obj) == {"contract", "created", "record", "summary"} and obj["contract"] == CONTRACT)
    _need(isinstance(obj["created"], bool))
    check_record(obj["record"], job)
    check_summary(obj["summary"], job)
    return obj


def check_job(obj, job):
    _need(set(obj) == {"contract", "claim", "summary"} and obj["contract"] == CONTRACT)
    check_record(obj["claim"], job)
    _need(obj["claim"]["kind"] == "claim")
    check_summary(obj["summary"], job)
    _need(obj["claim"]["seq"] == obj["summary"]["claim_seq"])
    return obj


def check_records(obj, job):
    _need(set(obj) == {"contract", "snapshot_seq", "next_after_seq", "has_more", "records", "summary"})
    _need(obj["contract"] == CONTRACT and _int(obj["snapshot_seq"], 1) and _int(obj["next_after_seq"]))
    _need(isinstance(obj["has_more"], bool) and isinstance(obj["records"], list))
    for record in obj["records"]:
        check_record(record, job)
    check_summary(obj["summary"], job)
    return obj


def check_capabilities(obj):
    _need(set(obj) == {"contract", "store_generation", "client_id", "policy_sha256", "writes_available"})
    _need(obj["contract"] == CONTRACT and isinstance(obj["writes_available"], bool))
    _need(isinstance(obj["client_id"], str) and JOB_RE.match(obj["client_id"]))
    _need(isinstance(obj["store_generation"], str) and UUID_RE.match(obj["store_generation"]))
    _need(isinstance(obj["policy_sha256"], str) and HEX64_RE.match(obj["policy_sha256"]))
    return obj


def check_content(obj, job, seq):
    _need(set(obj) == {"job_id", "seq", "content_b64", "content_sha256", "size_bytes"})
    _need(obj["job_id"] == job and obj["seq"] == seq and isinstance(obj["content_b64"], str))
    try:
        data = base64.b64decode(obj["content_b64"].encode("ascii"), validate=True)
    except (ValueError, UnicodeEncodeError):
        raise CliFail("protocol_invalid")
    _need(base64.b64encode(data).decode("ascii") == obj["content_b64"])
    _need(len(data) == obj["size_bytes"] and sha256_hex(data) == obj["content_sha256"])
    return data


# ── the PR 242 guard, re-run before every exec ───────────────────────────────

def _embedded(name):
    """The single-quoted python block NAME='...' from the sibling bin/wrk."""
    try:
        with open(WRK_SOURCE, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise Fail("trust_path", "cannot read the wrk trust guard source (%s)" % (exc.strerror or exc))
    match = re.search(r"^%s='\n(.*?)^'$" % name, text, re.S | re.M)
    if match is None:
        raise Fail("trust_path", "bin/wrk carries no %s block" % name)
    return match.group(1)


_TRUST = None


def trust_ns():
    global _TRUST
    if _TRUST is None:
        namespace = {"__name__": "wrk_o3_trust"}
        exec(compile(_embedded("WRK_TRUST_PY"), "bin/wrk:WRK_TRUST_PY", "exec"), namespace)
        _TRUST = namespace
    return _TRUST


def passwd_home():
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except (KeyError, OSError):
        return ""


def fixtures_root():
    candidate = os.path.join(HERE, "..", "tests", "fixtures")
    return os.path.realpath(candidate) if os.path.isdir(candidate) else ""


class Decision(object):
    def __init__(self, hk, inbox, home):
        self.hk = hk
        self.inbox = inbox
        self.home = home


def guard(need_hk=True):
    """Run the PR 242 decision now. Returns the binary, the inbox and the account
    home the child gets. A refusal is the trust-path exit 2, before any exec."""
    ns = trust_ns()
    home = passwd_home()
    testing = test_mode()
    try:
        decision = ns["trust_resolve"](os.environ, home, os.getuid(), testing, need_hk, fixtures_root())
    except ns["TrustRefusal"] as exc:
        raise Fail("trust_path", str(exc))
    # Test mode never uses the canonical home: the child gets HOME, which must
    # itself resolve under a temp root like every other test override.
    child_home = account_home() if testing else home
    return Decision(decision["hk"], decision["inbox"], child_home)


def central_wrapper(role):
    """Q1 (esc-1 ruling): <account home>/.local/bin/hk-<role>, with the PR 242
    secure-binary checks; the wrapper loads its own authentication."""
    if role not in CENTRAL_ROLES:
        raise Fail("usage", "--as accepts only %s" % " or ".join(CENTRAL_ROLES))
    guard(need_hk=False)
    path = os.path.join(account_home(), ".local", "bin", "hk-" + role)
    ns = trust_ns()
    if test_mode():
        resolved = os.path.realpath(path)
        roots = ns["trust_temp_roots"](os.environ, passwd_home())
        if not any(ns["trust_under"](resolved, root) for root in roots):
            raise Fail("trust_path", "the central wrapper %s resolves outside the temp roots" % path)
        if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
            raise Fail("transport_unavailable", "the central wrapper hk-%s is not installed" % role)
        return resolved
    try:
        return ns["trust_secure_binary"](path, os.getuid())
    except ns["TrustRefusal"] as exc:
        raise Fail("trust_path", str(exc))


def account_home():
    """The home the guard decides from: the passwd home of the uid, or in test
    mode HOME, which must resolve under a temp root. Only this home is judged
    here, so a command that is not otherwise trust-bearing (spawn) can read its
    deployment mode without the other trust levers being judged first."""
    ns = trust_ns()
    home = passwd_home()
    if not test_mode():
        if not home or not os.path.isabs(home):
            raise Fail("trust_path", "the passwd home of uid %d cannot be determined" % os.getuid())
        return home
    candidate = os.environ.get("HOME", "")
    roots = ns["trust_temp_roots"](os.environ, home)
    if (not candidate or not os.path.isabs(candidate)
            or not any(ns["trust_under"](os.path.realpath(candidate), root) for root in roots)):
        raise Fail("trust_path", "test mode needs HOME under a temp root (%s)" % " ".join(roots))
    return candidate


def records_mode():
    """Q2 (esc-1 ruling): one word in <account home>/.config/wrk/records-mode.
    Missing means legacy; unreadable or unknown fails closed."""
    path = os.path.join(account_home(), ".config", "wrk", "records-mode")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return "legacy"
    except OSError as exc:
        raise Fail("records_mode_invalid", "cannot read %s (%s)" % (path, exc.strerror or exc))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise Fail("records_mode_invalid", "%s is not a regular file" % path)
        raw = os.read(fd, 64)
    finally:
        os.close(fd)
    try:
        word = raw.decode("ascii").strip()
    except UnicodeDecodeError:
        word = ""
    if word not in MODES:
        raise Fail("records_mode_invalid", "%s must hold legacy, shadow or required" % path)
    return word


# ── transport ────────────────────────────────────────────────────────────────

def child_env(home):
    env = os.environ.copy()
    for key in SCRUB:
        env.pop(key, None)
    env["HOME"] = home
    return env


def timeout_s():
    if test_mode():
        try:
            return float(os.environ.get("WRK_O3_TIMEOUT_S", "30"))
        except ValueError:
            return 30.0
    return 30.0


def run_cli(args, stdin=b"", write=False, binary=None):
    """One handoffkeep wrk invocation. Returns the stdout object or raises CliFail.

    binary None means the guard-selected canonical handoffkeep, resolved now;
    the central desk commands pass their checked wrapper instead."""
    decision = guard(need_hk=True)
    if binary is None:
        binary = decision.hk
        if not binary:
            raise CliFail("transport_unavailable")
    try:
        proc = subprocess.run([binary, "wrk"] + list(args), input=stdin, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=child_env(decision.home), timeout=timeout_s(),
                              close_fds=True)
    except subprocess.TimeoutExpired:
        raise CliFail("transport_indeterminate" if write else "transport_unavailable")
    except OSError:
        raise CliFail("transport_unavailable")
    if proc.returncode == 0:
        out = proc.stdout
        if not out.endswith(b"\n"):
            raise CliFail("protocol_invalid")
        try:
            obj = strict_loads(out[:-1].decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise CliFail("protocol_invalid")
        if not isinstance(obj, dict):
            raise CliFail("protocol_invalid")
        return obj
    match = re.match(rb"\Ahandoffkeep wrk: ([a-z][a-z0-9_]{0,63})\n\Z", proc.stderr)
    if proc.stdout or match is None:
        raise CliFail("protocol_invalid")
    code = match.group(1).decode("ascii")
    if code not in CLI_CODES or EXIT[code] != proc.returncode:
        raise CliFail("protocol_invalid")
    raise CliFail(code)


def capabilities():
    return check_capabilities(run_cli(["capabilities"]))


def get_job(job):
    """The canonical claim and summary, or None when the server has no such job."""
    try:
        return check_job(run_cli(["job", job]), job)
    except CliFail as exc:
        if exc.code == "not_found":
            return None
        raise


def get_content(job, seq):
    return check_content(run_cli(["content", job, str(seq)]), job, seq)


class State(object):
    """One snapshot-consistent canonical history of a job."""

    def __init__(self, job, claim, summary, records):
        self.job = job
        self.claim = claim
        self.summary = summary
        self.records = records
        self.snapshot_seq = summary["snapshot_seq"]
        self.generation = summary["store_generation"]

    def kinds(self, kind):
        return [r for r in self.records if r["kind"] == kind and not r["imported"]]

    @property
    def claim_payload(self):
        return self.claim["payload"]

    @property
    def activated(self):
        return bool(self.kinds("activate"))

    @property
    def receipt_required(self):
        """2: an activate record, or any canonical review-role claim with review_of."""
        if self.activated:
            return True
        return any(r["payload"]["role"] in REVIEW_ROLES and r["payload"]["review_of"] is not None
                   for r in self.kinds("claim"))

    def open_heads(self):
        heads = {}
        opens = {r["payload"]["round_no"]: r["payload"] for r in self.kinds("round_open")}
        for number in self.summary["open_rounds"]:
            if number in opens:
                heads[number] = opens[number]
        return heads

    def ended(self):
        return bool(self.kinds("end"))


def read_state(job, retained=()):
    """GET job, then every records page at the first page's snapshot."""
    job_obj = get_job(job)
    if job_obj is None:
        return None
    records = []
    snapshot = None
    after = 0
    summary = None
    while True:
        args = ["records", job, "--after-seq", str(after), "--limit", "500"]
        if snapshot is not None:
            args += ["--snapshot-seq", str(snapshot)]
        page = check_records(run_cli(args), job)
        if snapshot is None:
            snapshot = page["snapshot_seq"]
            summary = page["summary"]
            if summary["snapshot_seq"] != snapshot:
                raise CliFail("protocol_invalid")
        elif page["snapshot_seq"] != snapshot or page["summary"]["snapshot_seq"] != snapshot:
            raise CliFail("protocol_invalid")
        if page["summary"]["store_generation"] != summary["store_generation"]:
            raise CliFail("history_regressed")
        for record in page["records"]:
            expected = len(records) + 1
            if record["seq"] != expected:
                raise CliFail("protocol_invalid")
            previous = records[-1]["record_hash"] if records else ZERO_HASH
            if record["previous_hash"] != previous or record["store_generation"] != summary["store_generation"]:
                raise CliFail("protocol_invalid")
            records.append(record)
        last = records[-1]["seq"] if records else 0
        if page["records"] and page["next_after_seq"] != last:
            raise CliFail("protocol_invalid")
        if not page["records"] and page["next_after_seq"] != after:
            raise CliFail("protocol_invalid")
        if not page["has_more"]:
            break
        if not page["records"]:
            raise CliFail("protocol_invalid")
        after = last
    if not records or records[-1]["seq"] != snapshot or summary["tail_hash"] != records[-1]["record_hash"]:
        raise CliFail("protocol_invalid")
    claim = records[summary["claim_seq"] - 1] if summary["claim_seq"] <= len(records) else None
    if claim is None or claim["kind"] != "claim":
        raise CliFail("protocol_invalid")
    if job_obj["summary"]["store_generation"] != summary["store_generation"]:
        raise CliFail("history_regressed")
    state = State(job, claim, summary, records)
    check_history(state, retained)
    return state


def check_history(state, retained):
    """5: a retained receipt outside, absent from or different in the returned
    history is local history_regressed and stops authority use."""
    for receipt in retained:
        if receipt["store_generation"] != state.generation or receipt["seq"] > state.snapshot_seq:
            raise CliFail("history_regressed")
        if state.records[receipt["seq"] - 1]["record_hash"] != receipt["record_hash"]:
            raise CliFail("history_regressed")


# ── durable intents ──────────────────────────────────────────────────────────

def check_intents_doc(document, job):
    if not isinstance(document, dict) or set(document) != {"version", "intents"} or document["version"] != 1:
        raise Fail("intent_invalid", "o3-intents.json has the wrong shape")
    if not isinstance(document["intents"], list):
        raise Fail("intent_invalid", "o3-intents.json intents is not a list")
    keys = set()
    for intent in document["intents"]:
        ok = (isinstance(intent, dict)
              and set(intent) == {"local_id", "job_id", "idempotency_key", "request", "request_sha256",
                                  "state", "receipt", "error"}
              and intent["job_id"] == job
              and isinstance(intent["local_id"], str) and UUID_RE.match(intent["local_id"])
              and isinstance(intent["idempotency_key"], str) and UUID_RE.match(intent["idempotency_key"])
              and intent["state"] in ("pending", "accepted", "rejected"))
        if ok:
            request = intent["request"]
            ok = (isinstance(request, dict) and set(request) == {"kind", "claim_seq", "expected_seq", "payload"}
                  and request["kind"] in WRITE_KINDS and _int(request["claim_seq"]) and _int(request["expected_seq"])
                  and isinstance(request["payload"], dict))
        if ok:
            try:
                ok = intent["request_sha256"] == request_sha256(job, request)
            except ValueError:
                ok = False
        if ok:
            receipt, error = intent["receipt"], intent["error"]
            if intent["state"] == "accepted":
                ok = (isinstance(receipt, dict) and set(receipt) == {"job_id", "seq", "record_hash", "store_generation"}
                      and receipt["job_id"] == job and _int(receipt["seq"], 1)
                      and isinstance(receipt["record_hash"], str) and HEX64_RE.match(receipt["record_hash"])
                      and isinstance(receipt["store_generation"], str) and UUID_RE.match(receipt["store_generation"])
                      and error is None)
            elif intent["state"] == "rejected":
                ok = receipt is None and error in CLI_CODES
            else:
                ok = receipt is None and error is None
        if not ok or intent["idempotency_key"] in keys:
            raise Fail("intent_invalid", "o3-intents.json holds an invalid or edited intent")
        keys.add(intent["idempotency_key"])
    return document


def safe_job_dir(inbox, job):
    if not JOB_RE.match(job):
        raise Fail("usage", "job id %r is not an O3 job id" % job)
    return os.path.join(inbox, job)


def ensure_dir(path):
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        info = os.lstat(path)
    except OSError as exc:
        raise Fail("intent_io", "cannot create the job directory (%s)" % (exc.strerror or exc))
    if not stat.S_ISDIR(info.st_mode):
        raise Fail("intent_invalid", "the canonical job directory %s is not a directory" % path)


def atomic_write(directory, name, document):
    """Write DIR/NAME by temp file, fsync, rename and directory fsync."""
    data = (json.dumps(document, sort_keys=True, indent=1, ensure_ascii=False) + "\n").encode("utf-8")
    temporary = os.path.join(directory, ".%s.%s.tmp" % (name, uuid.uuid4().hex))
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
            if name == INTENTS and test_hook("fsync_fail"):
                raise OSError(errno.EIO, "injected fsync failure")
            os.fsync(fd)
        finally:
            os.close(fd)
        os.rename(temporary, os.path.join(directory, name))
        dirfd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    except OSError as exc:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise Fail("intent_io", "cannot persist %s (%s)" % (name, exc.strerror or exc))


def read_private(path):
    """Bytes of a 0600 regular file owned by this uid, or None when absent."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Fail("intent_invalid", "%s cannot be opened safely (%s)" % (os.path.basename(path), exc.strerror or exc))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
            raise Fail("intent_invalid", "%s must be a regular 0600 file owned by this user" % os.path.basename(path))
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    except OSError as exc:
        raise Fail("intent_io", "cannot read %s (%s)" % (os.path.basename(path), exc.strerror or exc))
    finally:
        os.close(fd)


class Intents(object):
    """o3-intents.json of one canonical job directory, held under its lock."""

    def __init__(self, inbox, job):
        self.job = job
        self.dir = safe_job_dir(inbox, job)
        self.path = os.path.join(self.dir, INTENTS)
        self.lock_fd = None
        self.doc = None

    def __enter__(self):
        ensure_dir(self.dir)
        try:
            self.lock_fd = os.open(os.path.join(self.dir, INTENTS_LOCK), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            if not stat.S_ISREG(os.fstat(self.lock_fd).st_mode):
                raise Fail("intent_invalid", "o3-intents.lock is not a regular file")
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX)
        except OSError as exc:
            raise Fail("intent_invalid" if exc.errno == errno.ELOOP else "intent_io",
                       "cannot take o3-intents.lock (%s)" % (exc.strerror or exc))
        self.load()
        return self

    def __exit__(self, *exc):
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None
        return False

    def load(self):
        raw = read_private(self.path)
        if raw is None:
            self.doc = {"version": 1, "intents": []}
            return
        try:
            document = strict_loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise Fail("intent_invalid", "o3-intents.json is not strict JSON")
        self.doc = check_intents_doc(document, self.job)

    def save(self):
        check_intents_doc(self.doc, self.job)
        atomic_write(self.dir, INTENTS, self.doc)

    @property
    def intents(self):
        return self.doc["intents"]

    def pending(self):
        return [i for i in self.intents if i["state"] == "pending"]

    def receipts(self):
        return [i["receipt"] for i in self.intents if i["state"] == "accepted"]

    def new(self, request):
        intent = {"local_id": str(uuid.uuid4()), "job_id": self.job, "idempotency_key": str(uuid.uuid4()),
                  "request": request, "request_sha256": request_sha256(self.job, request), "state": "pending",
                  "receipt": None, "error": None}
        self.intents.append(intent)
        return intent


# ── snapshot cache (Q3: display and offline routing only, never authority) ──

def snapshot_doc(state):
    payload = state.claim_payload
    return {"version": 1, "job_id": state.job, "read_at": now_utc(), "store_generation": state.generation,
            "snapshot_seq": state.snapshot_seq, "tail_hash": state.summary["tail_hash"], "summary": state.summary,
            "receipt_required": state.receipt_required, "activated": state.activated, "role": payload["role"],
            "review_of": payload["review_of"], "claim_seq": state.summary["claim_seq"],
            "open_heads": {str(k): v["head"] for k, v in state.open_heads().items()},
            "open_testers": {str(k): v["tester_job_id"] for k, v in state.open_heads().items()}}


def write_snapshot(directory, state):
    atomic_write(directory, SNAPSHOT, snapshot_doc(state))


def load_snapshot(directory, job):
    raw = read_private(os.path.join(directory, SNAPSHOT))
    if raw is None:
        return None
    try:
        document = strict_loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise Fail("intent_invalid", "o3-snapshot.json is not strict JSON")
    if not isinstance(document, dict) or document.get("version") != 1 or document.get("job_id") != job:
        raise Fail("intent_invalid", "o3-snapshot.json has the wrong shape")
    return document


def advance_snapshot(directory, job, outcome):
    """After an accepted write, move the cached read forward by that one record
    when it is the next seq (display and offline routing only)."""
    try:
        snapshot = load_snapshot(directory, job)
    except Fail:
        return
    record = outcome.record
    if snapshot is None or snapshot.get("snapshot_seq") != record["seq"] - 1 or not outcome.created:
        return
    if snapshot.get("tail_hash") != record["previous_hash"]:
        return
    heads, testers = dict(snapshot.get("open_heads", {})), dict(snapshot.get("open_testers", {}))
    if record["kind"] == "round_open":
        heads[str(record["payload"]["round_no"])] = record["payload"]["head"]
        testers[str(record["payload"]["round_no"])] = record["payload"]["tester_job_id"]
    open_rounds = {str(n) for n in outcome.summary["open_rounds"]}
    snapshot.update({"read_at": now_utc(), "snapshot_seq": record["seq"], "tail_hash": record["record_hash"],
                     "summary": outcome.summary, "claim_seq": outcome.summary["claim_seq"],
                     "open_heads": {k: v for k, v in heads.items() if k in open_rounds},
                     "open_testers": {k: v for k, v in testers.items() if k in open_rounds}})
    try:
        atomic_write(directory, SNAPSHOT, snapshot)
    except Fail:
        pass


def retained_receipts(directory, job):
    """Accepted receipts of this job's intents, read without the lock (a
    witness only; a broken file is refused where intents are used)."""
    try:
        raw = read_private(os.path.join(directory, INTENTS))
        if raw is None:
            return []
        document = check_intents_doc(strict_loads(raw.decode("utf-8")), job)
    except (Fail, UnicodeDecodeError, ValueError):
        return []
    return [i["receipt"] for i in document["intents"] if i["state"] == "accepted"]


def snapshot_regressed(snapshot, state):
    """The cached read is a retained witness too."""
    if snapshot is None:
        return False
    seq = snapshot.get("snapshot_seq")
    if snapshot.get("store_generation") != state.generation or not _int(seq, 1) or seq > state.snapshot_seq:
        return True
    return state.records[seq - 1]["record_hash"] != snapshot.get("tail_hash")


# ── local event projections (6 step 3) ───────────────────────────────────────

_EVENTS = None


def events_ns():
    global _EVENTS
    if _EVENTS is None:
        namespace = {"__name__": "wrk_o3_events"}
        exec(compile(_embedded("WRK_EVENTS_PY"), "bin/wrk:WRK_EVENTS_PY", "exec"), namespace)
        _EVENTS = namespace
    return _EVENTS


def receipt_of(record):
    return {"job_id": record["job_id"], "seq": record["seq"], "record_hash": record["record_hash"],
            "store_generation": record["store_generation"]}


def projected_keys(events):
    ns = events_ns()
    keys = set()
    for _name, document, _mtime in ns["wrk_events_ordered"](events):
        if isinstance(document, dict) and isinstance(document.get("idempotency_key"), str):
            keys.add(document["idempotency_key"])
    return keys


def projection(record, mode, meta, provenance):
    """Today's event for an accepted record, plus o3_mode, wrk_receipt and the key."""
    payload = record["payload"]
    base = {"job_id": record["job_id"], "owner_lane": meta.get("owner", ""), "label": meta.get("label", ""),
            "pane_id": meta.get("pane", ""), "parent_lane": meta.get("parent", ""), "epoch": 1,
            "o3_mode": mode, "wrk_receipt": receipt_of(record), "idempotency_key": record["idempotency_key"],
            "o3_provenance": provenance}
    if record["kind"] == "round_open":
        base.update({"kind": "job.round", "head": payload["head"], "round": payload["round_no"]})
        for key in ("tester_job_id", "extension_grant_seq", "repeat_grant_seq"):
            if payload[key] is not None:
                base[key] = payload[key]
        return "job.round", base
    if record["kind"] == "verdict":
        base.update({"kind": "job.verdict", "verdict": payload["verdict"], "head": payload["head"],
                     "path": payload["path"], "content_sha256": payload["content_sha256"],
                     "round": payload["round_no"]})
        if payload["tester_job_id"] is not None:
            base["tester_job_id"] = payload["tester_job_id"]
        return "job.verdict", base
    if record["kind"] == "void":
        base.update({"kind": "job.round_void", "round": payload["round_no"], "reason": payload["reason_code"],
                     "ref": "o3:grant/%d" % payload["grant_seq"], "grant_seq": payload["grant_seq"]})
        return "job.round_void", base
    return None, None


PROJECTED_KINDS = ("round_open", "verdict", "void")


def write_projections(inbox, job, records, mode, meta, provenance):
    """Project accepted records not yet projected; True when all landed."""
    events = os.path.join(safe_job_dir(inbox, job), "events")
    ns = events_ns()
    try:
        os.makedirs(events, exist_ok=True)
        if test_hook("projection_fail"):
            raise OSError(errno.EIO, "injected projection failure")
        lock = ns["wrk_events_locked"](events)
        try:
            done = projected_keys(events)
            for record in records:
                if record["kind"] not in PROJECTED_KINDS or record["idempotency_key"] in done:
                    continue
                kind, event = projection(record, mode, meta, provenance)
                ns["wrk_event_commit"](events, kind, event)
                done.add(record["idempotency_key"])
        finally:
            lock.close()
    except OSError:
        return False
    return True


def write_warning(inbox, job, code, operation, key=None):
    """One job.o3_warning: code, key and operation only."""
    events = os.path.join(safe_job_dir(inbox, job), "events")
    ns = events_ns()
    try:
        os.makedirs(events, exist_ok=True)
        lock = ns["wrk_events_locked"](events)
        try:
            record = {"kind": "job.o3_warning", "job_id": job, "code": code, "operation": operation, "epoch": 1}
            if key:
                record["idempotency_key"] = key
            ns["wrk_event_commit"](events, "job.o3_warning", record)
        finally:
            lock.close()
    except OSError:
        sys.stderr.write("wrk: warning: o3 job.o3_warning not written for %s\n" % job)


# ── the append transaction ───────────────────────────────────────────────────

class Outcome(object):
    def __init__(self, intent, record, summary, created, resent=False):
        self.intent = intent
        self.record = record
        self.summary = summary
        self.created = created
        self.resent = resent


def send(store, intent, binary=None):
    """Send one saved intent with its original key and body."""
    request = intent["request"]
    args = ["append", store.job, "--kind", request["kind"], "--idempotency-key", intent["idempotency_key"],
            "--expected-seq", str(request["expected_seq"]), "--claim-seq", str(request["claim_seq"])]
    # Canonical bytes: a resend after a crash or lost reply is byte-identical.
    body = canonical(request["payload"]).encode("utf-8")
    try:
        obj = run_cli(args, body, write=True, binary=binary)
    except CliFail as exc:
        if exc.code in DEFINITE or exc.code == "cli_usage":
            intent["state"], intent["error"] = "rejected", exc.code
            store.save()
        # Every other outcome (503, transport, protocol, unknown) may have
        # committed: the intent stays pending for an exact-key retry.
        raise Fail(exc.code, "%s %s" % (request["kind"], intent["idempotency_key"]))
    crash_point("after_send")
    try:
        check_write(obj, store.job)
        record = obj["record"]
        _need(record["idempotency_key"] == intent["idempotency_key"] and record["kind"] == request["kind"])
        _need(record["request_sha256"] == intent["request_sha256"])
    except CliFail as exc:
        raise Fail(exc.code, "%s %s" % (request["kind"], intent["idempotency_key"]))
    intent["state"], intent["receipt"] = "accepted", receipt_of(record)
    try:
        store.save()
    except Fail:
        # Known acceptance without a durable receipt: never publish success.
        intent["state"], intent["receipt"] = "pending", None
        raise
    crash_point("after_accept")
    return Outcome(intent, record, obj["summary"], obj["created"])


def resume(store, binary=None):
    """Retry every pending intent of this job, oldest first, by its own key."""
    outcomes = []
    for intent in list(store.pending()):
        try:
            outcomes.append(send(store, intent, binary))
        except Fail as exc:
            if intent["state"] == "rejected":
                sys.stderr.write("wrk: warning: o3 pending %s %s was rejected on retry: %s\n"
                                 % (intent["request"]["kind"], intent["idempotency_key"], exc.code))
                continue
            raise
    return outcomes


def transact(store, kind, build, binary=None, state_reader=None):
    """Resume pending intents, read the current state, build, save, send.

    build(state) returns (claim_seq, expected_seq, payload). A pending intent of
    the same kind that the resume settles as accepted is the answer: the new
    request is not sent and the caller reports the original."""
    for outcome in resume(store, binary):
        if outcome.intent["request"]["kind"] == kind:
            outcome.resent = True
            return outcome
    state = state_reader() if state_reader else None
    claim_seq, expected_seq, payload = build(state)
    request = {"kind": kind, "claim_seq": claim_seq, "expected_seq": expected_seq, "payload": payload}
    intent = store.new(request)
    store.save()
    crash_point("before_send")
    return send(store, intent, binary)


# ── command helpers ──────────────────────────────────────────────────────────

class Ctx(object):
    """One command: the mode, the guarded inbox and the per-job stores."""

    def __init__(self):
        self.mode = records_mode()
        self.inbox = guard(need_hk=False).inbox

    def jobdir(self, job):
        return safe_job_dir(self.inbox, job)

    def state(self, job, store=None):
        """A fresh complete canonical read, checked against the negative
        witnesses: retained receipts and the last complete snapshot. A witness
        can only refuse (director-1 regressed-history ruling): a job it shows
        enrolled that now reads not_found, or a changed generation or lower seq,
        is history_regressed with one job.o3_warning and no legacy fallback."""
        directory = self.jobdir(job)
        retained = store.receipts() if store is not None else retained_receipts(directory, job)
        snapshot = load_snapshot(directory, job) if os.path.isdir(directory) else None
        try:
            state = read_state(job, retained)
            if state is None and (retained or snapshot is not None):
                raise CliFail("history_regressed")
            if state is not None and snapshot_regressed(snapshot, state):
                raise CliFail("history_regressed")
        except CliFail as exc:
            if exc.code == "history_regressed":
                write_warning(self.inbox, job, "history_regressed", "canonical read")
            raise
        if state is not None:
            ensure_dir(directory)
            write_snapshot(directory, state)
        return state


def cli_guard(fn):
    def wrapped(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except CliFail as exc:
            raise Fail(exc.code)
    return wrapped


def o3_mode_name(state):
    return "enforced" if state.receipt_required else "shadow"


def head_arg(value):
    if not isinstance(value, str) or not re.match(r"^[0-9a-fA-F]{40}$", value):
        raise Fail("usage", "--head requires a full 40-hex SHA")
    return value.lower()


def seq_arg(value, flag):
    if value is None:
        return None
    if not re.match(r"^[1-9][0-9]{0,15}$", value) or int(value) > SAFE_MAX:
        raise Fail("usage", "%s requires a positive record seq" % flag)
    return int(value)


def job_arg(value, flag):
    if value is None:
        return None
    if not JOB_RE.match(value):
        raise Fail("usage", "%s requires a job id matching [a-z0-9][a-z0-9._-]{0,127}" % flag)
    return value


def code_arg(value, flag):
    if not CODE_RE.match(value):
        raise Fail("usage", "%s requires a reason code matching [a-z][a-z0-9_]{0,63}" % flag)
    return value


def lexical_path(path):
    """2: POSIX lexical normalization of an absolute path; no symlink resolution.
    Only the schema length makes a path unsendable here; invalid_path is the
    server's answer (director-1 C1 ruling: no client pre-emption)."""
    absolute = path if path.startswith("/") else os.path.join(os.getcwd(), path)
    parts = []
    for part in absolute.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    normalized = "/" + "/".join(parts)
    if len(normalized.encode("utf-8")) > 4096:
        raise Fail("invalid_request", "the verdict path is longer than 4096 bytes")
    return normalized


def parse_verdict(data):
    """The verdict and head fields the request needs, from the first physical
    line only (5 grammar). A header that yields no fields leaves the request
    unsendable; every other grammar rule (BOM, UTF-8 in the body, a later
    VERDICT: line) is the server's invalid_verdict (director-1 C1 ruling)."""
    first = data.split(b"\n", 1)[0]
    try:
        line = first.decode("utf-8")
    except UnicodeDecodeError:
        line = ""
    match = VERDICT_HEADER.match(line)
    if match is None:
        raise Fail("invalid_verdict", "the first line is not 'VERDICT: PASS|BLOCKER @<40-hex sha>'; no head to "
                   "submit")
    return match.group(1), match.group(2).lower()


def read_once(path, what):
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_CONTENT + 1)
    except OSError as exc:
        raise Fail("usage", "cannot read the %s (%s)" % (what, exc.strerror or exc))
    if not data:
        raise Fail("invalid_request", "the %s is empty" % what)
    if len(data) > MAX_CONTENT:
        raise Fail("request_too_large", "the %s is larger than %d bytes" % (what, MAX_CONTENT))
    return data


def b64(data):
    return base64.b64encode(data).decode("ascii")


def emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def warn(text):
    sys.stderr.write("wrk: warning: %s\n" % text)


def offline_codes():
    return ("transport_unavailable", "transport_indeterminate", "wrk_unavailable", "wrk_recovery_required",
            "protocol_invalid", "o3_unsupported")


# ── routing (Q2/Q3) ──────────────────────────────────────────────────────────

def refuse_o2_ref(opts, operation):
    """Q4 (esc-1 ruling): an enrolled job never takes a free hk:doc/hk:task ref."""
    if opts.get("--o2-ref"):
        raise Fail("usage", "%s: an O3 job takes a typed server grant (seq), never the free ref %s"
                   % (operation, opts["--o2-ref"]))


class Route(object):
    def __init__(self, kind, state=None, snapshot=None, code=None):
        self.kind = kind          # legacy | o3 | offline_shadow
        self.state = state
        self.snapshot = snapshot
        self.code = code


def route(ctx, job, operation, store=None, offline_formed=False):
    """legacy, o3 (with a fresh canonical state) or offline_shadow; else Fail.

    offline_shadow is the section 6 step-2 P1 branch: shadow mode, server
    unreachable, and the last canonical read showed an unactivated
    builder/worker subject. No cached read, or one that showed
    receipt_required, fails closed; with offline_formed the caller gets the
    cached read (offline_formed) to form its exact request as a pending intent
    before it fails closed (director-1 offline-verdict ruling)."""
    if ctx.mode == "legacy":
        return Route("legacy")
    try:
        state = ctx.state(job, store)
    except CliFail as exc:
        if exc.code in offline_codes():
            directory = ctx.jobdir(job)
            snapshot = load_snapshot(directory, job) if os.path.isdir(directory) else None
            if exc.code in ("protocol_invalid", "o3_unsupported") and snapshot is None:
                raise Fail(exc.code, "%s: the server has no usable O3 namespace; refusing (no legacy fallback)"
                           % operation)
            if (ctx.mode == "shadow" and snapshot is not None and not snapshot.get("receipt_required")
                    and not snapshot.get("activated") and snapshot.get("role") in ("builder", "worker")
                    and snapshot.get("summary", {}).get("state") == "shadow"):
                return Route("offline_shadow", snapshot=snapshot, code=exc.code)
            if offline_formed and snapshot is not None:
                return Route("offline_formed", snapshot=snapshot, code=exc.code)
            raise Fail(exc.code, "%s: no canonical read; refusing" % operation)
        raise Fail(exc.code)
    if state is None:
        if ctx.mode == "required":
            raise Fail("not_found", "%s: job %s is not enrolled and records mode is required" % (operation, job))
        write_warning(ctx.inbox, job, "not_enrolled", operation)
        return Route("legacy")
    return Route("o3", state=state)


# ── round commands ───────────────────────────────────────────────────────────

def meta_from(opts):
    return {"owner": opts.get("--owner", ""), "label": opts.get("--label", ""), "pane": opts.get("--pane", ""),
            "parent": opts.get("--parent", "")}


def finish_projection(ctx, job, state_or_records, mode, meta, provenance, ok_line, outcome=None):
    records = state_or_records
    if outcome is not None:
        advance_snapshot(ctx.jobdir(job), job, outcome)
    if not write_projections(ctx.inbox, job, records, mode, meta, provenance):
        emit("projection_pending job=%s" % job)
        raise Fail("projection_pending", "the receipt is stored; the local event is repaired from server records "
                   "on the next run")
    emit(ok_line)


def repair(ctx, job, store, state, meta):
    """Read repair: project every accepted intent of this job still missing its event."""
    accepted = {i["receipt"]["seq"] for i in store.intents if i["state"] == "accepted"}
    records = [r for r in state.records if r["seq"] in accepted]
    if records and not write_projections(ctx.inbox, job, records, o3_mode_name(state), meta, "server_repair"):
        raise Fail("projection_pending", "read repair could not write the local events")


def offline_intent(ctx, job, kind, payload_from_snapshot, operation):
    """P1 warning branch: save the intent from the cached claim/tail, try once,
    and on unavailability leave it pending with one job.o3_warning."""
    with Intents(ctx.inbox, job) as store:
        snapshot = load_snapshot(ctx.jobdir(job), job)
        request = {"kind": kind, "claim_seq": snapshot["claim_seq"], "expected_seq": snapshot["snapshot_seq"],
                   "payload": payload_from_snapshot(snapshot)}
        intent = store.new(request)
        store.save()
        crash_point("before_send")
        try:
            return send(store, intent)
        except Fail as exc:
            if intent["state"] == "rejected":
                raise
            write_warning(ctx.inbox, job, exc.code, operation, intent["idempotency_key"])
            warn("o3 server unavailable (%s) for shadow job %s: intent %s stays pending; O2 local event only"
                 % (exc.code, job, intent["idempotency_key"]))
            emit("LEGACY")
            return None


def round_open(ctx, job, opts):
    head = head_arg(opts.get("--head"))
    ext = seq_arg(opts.get("--extension-grant"), "--extension-grant")
    rep = seq_arg(opts.get("--repeat-grant"), "--repeat-grant")
    tester = job_arg(opts.get("--tester"), "--tester")
    meta = meta_from(opts)
    payload = {"head": head, "tester_job_id": tester, "extension_grant_seq": ext, "repeat_grant_seq": rep}
    with Intents(ctx.inbox, job) as store:
        decision = route(ctx, job, "round open", store)
        if decision.kind == "legacy":
            emit("LEGACY")
            return
    refuse_o2_ref(opts, "round open")
    if decision.kind == "offline_shadow":
        outcome = offline_intent(ctx, job, "round_open", lambda _s: payload, "round open")
        if outcome is None:
            return
        mode = "shadow"
    else:
        with Intents(ctx.inbox, job) as store:
            state = decision.state
            mode = o3_mode_name(state)
            repair(ctx, job, store, state, meta)

            def build(fresh):
                return fresh.summary["claim_seq"], fresh.snapshot_seq, payload
            outcome = cli_guard(transact)(store, "round_open", build,
                                          state_reader=cli_guard(lambda: ctx.state(job, store)))
    record = outcome.record
    note = " resent=pending" if outcome.resent else ""
    if outcome.resent:
        warn("o3 a pending round_open %s was resent and accepted; the new request was not sent"
             % outcome.intent["idempotency_key"])
    finish_projection(ctx, job, [record], mode, meta, "receipt",
                      "OK job=%s round=%d cap=3 head=%s o3=%s seq=%d%s" % (
                          job, record["payload"]["round_no"], record["payload"]["head"], mode, record["seq"], note),
                      outcome)


def verdict_round(state, head):
    """hk 1506: the oldest open round on the verdict's own head."""
    heads = state.open_heads()
    for number in sorted(heads):
        if heads[number]["head"] == head:
            return number, heads[number]["tester_job_id"]
    return None, None


def round_verdict(ctx, job, opts):
    path = opts.get("--file")
    tester_flag = job_arg(opts.get("--tester"), "--tester")
    meta = meta_from(opts)
    with Intents(ctx.inbox, job) as store:
        decision = route(ctx, job, "round verdict", store, offline_formed=True)
        if decision.kind == "legacy":
            emit("LEGACY")
            return
    # Bytes are read once: the digest, the base64 and the asserted head all come
    # from this one read. A pending original is resent unchanged (6b).
    data = read_once(path, "verdict file")
    verdict, head = parse_verdict(data)
    vpath = lexical_path(path)

    def payload_for(number, tester):
        return {"round_no": number, "head": head, "verdict": verdict, "path": vpath,
                "content_sha256": sha256_hex(data), "content_b64": b64(data),
                "tester_job_id": tester_flag if tester_flag is not None else tester}
    if decision.kind in ("offline_shadow", "offline_formed"):
        snapshot = decision.snapshot
        numbers = sorted(int(n) for n, h in snapshot.get("open_heads", {}).items() if h == head)
        testers = snapshot.get("open_testers", {})
        if not numbers or str(numbers[0]) not in testers:
            # No complete request can be formed without inventing a field: no intent.
            raise Fail(decision.code, "round verdict: no canonical read and no cached open round for head %s; "
                       "nothing recorded" % head)
        tester = testers[str(numbers[0])]
        if decision.kind == "offline_formed":
            # Enforced: the exact request is formed from the last canonical read
            # and kept pending; nothing is sent and nothing is accepted.
            with Intents(ctx.inbox, job) as store:
                request = {"kind": "verdict", "claim_seq": snapshot["claim_seq"],
                           "expected_seq": snapshot["snapshot_seq"], "payload": payload_for(numbers[0], tester)}
                intent = store.new(request)
                store.save()
            raise Fail(decision.code, "round verdict: no canonical read; the verdict bytes are kept in pending "
                       "intent %s for the next run" % intent["idempotency_key"])
        outcome = offline_intent(ctx, job, "verdict", lambda _s: payload_for(numbers[0], tester), "round verdict")
        if outcome is None:
            return
        mode = "shadow"
    else:
        with Intents(ctx.inbox, job) as store:
            state = decision.state
            mode = o3_mode_name(state)
            repair(ctx, job, store, state, meta)

            def build(fresh):
                number, tester = verdict_round(fresh, head)
                if number is None:
                    # No open round on this head: the server answers (round_not_open
                    # or head_mismatch); the client never pre-empts it.
                    opens = sorted(fresh.summary["open_rounds"])
                    number = opens[0] if opens else fresh.summary["next_round_no"]
                    warn("o3 no open round on head %s for %s; the server decides" % (head, job))
                return fresh.summary["claim_seq"], fresh.snapshot_seq, payload_for(number, tester)
            outcome = cli_guard(transact)(store, "verdict", build,
                                          state_reader=cli_guard(lambda: ctx.state(job, store)))
    record = outcome.record
    if outcome.resent:
        warn("o3 a pending verdict %s was resent with its original bytes; the current file was not sent"
             % outcome.intent["idempotency_key"])
    payload = record["payload"]
    finish_projection(ctx, job, [record], mode, meta, "receipt",
                      "OK job=%s verdict=%s head=%s round=%d o3=%s seq=%d" % (
                          job, payload["verdict"], payload["head"], payload["round_no"], mode, record["seq"]),
                      outcome)


def round_void(ctx, job, opts):
    with Intents(ctx.inbox, job) as store:
        decision = route(ctx, job, "round void", store)
        if decision.kind == "legacy":
            emit("LEGACY")
            return
    refuse_o2_ref(opts, "round void")
    number = seq_arg(opts.get("--round"), "round number")
    grant = seq_arg(opts.get("--grant"), "--grant")
    if number is None or grant is None:
        raise Fail("usage", "round void: an O3 job needs a round number and --grant SEQ")
    reason = code_arg(opts.get("--reason-code") or "builder_void", "--reason-code")
    meta = meta_from(opts)
    payload = {"round_no": number, "grant_seq": grant, "reason_code": reason}
    if decision.kind == "offline_shadow":
        # A typed void has no O2 equivalent, so there is no warning branch.
        raise Fail(decision.code, "round void: no canonical read; a typed void waits for the server")
    with Intents(ctx.inbox, job) as store:
        state = decision.state
        repair(ctx, job, store, state, meta)

        def build(fresh):
            return fresh.summary["claim_seq"], fresh.snapshot_seq, payload
        outcome = cli_guard(transact)(store, "void", build, state_reader=cli_guard(lambda: ctx.state(job, store)))
    record = outcome.record
    finish_projection(ctx, job, [record], o3_mode_name(state), meta, "receipt",
                      "OK job=%s VOIDED round=%d grant=%d o3=%s seq=%d" % (
                          job, record["payload"]["round_no"], grant, o3_mode_name(state), record["seq"]),
                      outcome)


def status_line(state):
    summary = state.summary
    verdicts = state.kinds("verdict")
    last = verdicts[-1]["payload"] if verdicts else None
    voids = ",".join("round %d void (o3:grant/%d)" % (r["payload"]["round_no"], r["payload"]["grant_seq"])
                     for r in state.kinds("void")) or "-"
    return ("rounds=%d\topen=%s\tlast_verdict=%s\tlast_findings=%s\tvoided=%s\to3=%s\tstate=%s"
            "\tseq=%d\tgeneration=%s" % (
                summary["used"], ",".join(str(n) for n in summary["open_rounds"]) or "-",
                "%s@%s" % (last["verdict"], last["head"]) if last else "-", last["path"] if last else "-",
                voids, o3_mode_name(state), summary["state"], state.snapshot_seq, state.generation))


def round_status(ctx, job, opts):
    if ctx.mode == "legacy":
        emit("LEGACY")
        return
    try:
        state = ctx.state(job)
    except CliFail as exc:
        if exc.code not in offline_codes():
            raise Fail(exc.code)
        directory = ctx.jobdir(job)
        snapshot = load_snapshot(directory, job) if os.path.isdir(directory) else None
        if snapshot is None and exc.code in ("o3_unsupported", "protocol_invalid") and ctx.mode == "shadow":
            # 6 matrix, old server column: local status only, explicitly O2.
            write_warning(ctx.inbox, job, exc.code, "round status")
            emit("UNSUPPORTED code=%s" % exc.code)
            return
        if snapshot is None:
            raise Fail(exc.code, "round status: no canonical read and no cached snapshot")
        write_warning(ctx.inbox, job, exc.code, "round status")
        summary = snapshot["summary"]
        emit("STALE rounds=%d\topen=%s\tstale=true\tgeneration=%s\tseq=%d\tread_at=%s\tlabel=O2-unverified" % (
            summary["used"], ",".join(str(n) for n in summary["open_rounds"]) or "-",
            snapshot["store_generation"], snapshot["snapshot_seq"], snapshot["read_at"]))
        return
    if state is None:
        if ctx.mode == "required":
            raise Fail("not_found", "round status: job %s is not enrolled" % job)
        emit("LEGACY")
        return
    emit("O3 " + status_line(state))


def audit_job(ctx, job, opts):
    """One audit row source for a job dir that holds O3 state (Q3)."""
    if ctx.mode == "legacy":
        emit("LEGACY")
        return
    directory = ctx.jobdir(job)
    if not (os.path.exists(os.path.join(directory, INTENTS)) or os.path.exists(os.path.join(directory, SNAPSHOT))):
        emit("LEGACY")
        return
    try:
        state = ctx.state(job)
    except CliFail as exc:
        emit("STALE code=%s" % exc.code)
        return
    if state is None:
        emit("LEGACY")
        return
    summary = state.summary
    zero = (state.claim_payload["role"] == "builder" and summary["used"] == 0
            and summary["state"] in ("shadow", "active"))
    emit("O3 role=%s used=%d state=%s zero=%d o3=%s" % (
        state.claim_payload["role"], summary["used"], summary["state"], 1 if zero else 0, o3_mode_name(state)))


# ── spawn handshake (6, Q1=A: verify only, never mint a central claim) ───────

def verify_subject_claim(state, opts, client_id):
    payload = state.claim_payload
    role = opts["--role"]
    problems = []
    if payload["role"] != role:
        problems.append("role %s != %s" % (payload["role"], role))
    if str(payload["task_id"]) != opts.get("--task", ""):
        problems.append("task %s != %s" % (payload["task_id"], opts.get("--task") or "-"))
    if payload["owner_lane"] != opts.get("--lane", ""):
        problems.append("owner_lane %s != %s" % (payload["owner_lane"], opts.get("--lane") or "-"))
    if role == "builder" and payload["parent_lane"] != opts.get("--parent", ""):
        problems.append("parent_lane %s != %s" % (payload["parent_lane"], opts.get("--parent") or "-"))
    if payload["tier"] != opts.get("--tier", ""):
        problems.append("tier %s != %s" % (payload["tier"], opts.get("--tier") or "-"))
    if payload["host_client_id"] != client_id:
        problems.append("host %s != this host %s" % (payload["host_client_id"], client_id))
    if payload["review_of"] is not None:
        problems.append("the canonical claim is a review assignment")
    return problems


def spawn_subject(ctx, job, opts):
    with Intents(ctx.inbox, job) as store:
        decision = route(ctx, job, "spawn", store)
    if decision.kind == "legacy":
        emit("LEGACY")
        return
    if decision.kind == "offline_shadow":
        raise Fail(decision.code, "spawn: no canonical read; no new pane without a verified canonical claim")
    state = decision.state
    caps = cli_guard(capabilities)()
    problems = verify_subject_claim(state, opts, caps["client_id"])
    if problems:
        raise Fail("claim_conflict", "spawn: the canonical claim for %s does not match: %s" % (job, "; ".join(problems)))
    summary_state = state.summary["state"]
    if summary_state in ("joined", "ended") or state.ended():
        raise Fail("job_ended", "spawn: canonical job %s is %s" % (job, summary_state))
    if summary_state == "importing":
        raise Fail("migration_frozen", "spawn: canonical job %s is importing" % job)
    if summary_state == "sealed":
        raise Fail("import_sealed", "spawn: canonical job %s is sealed and not activated" % job)
    if summary_state == "shadow" and ctx.mode != "shadow":
        raise Fail("claim_conflict", "spawn: canonical job %s is not activated; records mode %s starts no pane "
                   "from a shadow claim" % (job, ctx.mode))
    emit("OK o3=%s job=%s state=%s claim_seq=%d" % (o3_mode_name(state), job, summary_state,
                                                    state.summary["claim_seq"]))


def live_review_claim(state, subject, role, task_id):
    payload = state.claim_payload
    review = payload["review_of"]
    return (payload["role"] == role and review is not None and review["job_id"] == subject
            and payload["task_id"] == task_id and not state.ended())


def spawn_reviewer(ctx, job, opts, write):
    """The section 6 reviewer order. write=False (the verify phase, before any
    legacy task probe) reads and checks only; write=True (the commit phase,
    just before the local claim and pane) mints, GET-verifies and opens."""
    subject = job_arg(opts.get("--subject"), "--parent-job")
    role = opts["--role"]
    with Intents(ctx.inbox, subject) as store:
        decision = route(ctx, subject, "spawn", store)
    if decision.kind == "legacy":
        # The subject is not enrolled: the reviewer job is checked on its own.
        if write:
            emit("LEGACY")
        else:
            spawn_subject(ctx, job, opts)
        return
    if decision.kind == "offline_shadow":
        raise Fail(decision.code, "spawn: no canonical read of subject %s; no reviewer pane" % subject)
    target = decision.state
    target_claim = target.claim_payload
    if target_claim["role"] not in ("builder", "worker") or target_claim["review_of"] is not None:
        raise Fail("claim_conflict", "spawn: subject %s is not a builder/worker job" % subject)
    if target.summary["state"] in ("joined",):
        raise Fail("review_sealed", "spawn: subject %s is joined" % subject)
    if target.summary["state"] in ("ended",) or target.ended():
        raise Fail("job_ended", "spawn: subject %s has ended" % subject)
    if target.summary["state"] in ("importing", "sealed"):
        raise Fail("migration_frozen" if target.summary["state"] == "importing" else "import_sealed",
                   "spawn: subject %s is %s" % (subject, target.summary["state"]))
    head = head_arg(opts.get("--head"))
    ext = seq_arg(opts.get("--extension-grant"), "--extension-grant")
    rep = seq_arg(opts.get("--repeat-grant"), "--repeat-grant")
    heads = target.open_heads()
    attach = None
    for number in sorted(heads):
        if heads[number]["head"] == head and heads[number]["tester_job_id"] in (None, job):
            attach = number
            break
    review_round = attach if attach is not None else target.summary["next_round_no"]
    caps = cli_guard(capabilities)()
    existing = cli_guard(lambda: ctx.state(job))()
    matching = existing is not None and live_review_claim(existing, subject, role, target_claim["task_id"])
    if matching and existing.claim_payload["host_client_id"] != caps["client_id"]:
        raise Fail("host_mismatch", "spawn: assignment %s is placed on host %s, not this host %s"
                   % (job, existing.claim_payload["host_client_id"], caps["client_id"]))
    if target.summary["state"] == "shadow":
        # P1 (6): a central precreated assignment is required; a host never mints
        # against a shadow subject and never falls back after a 409.
        if not matching:
            raise Fail("claim_conflict", "spawn: subject %s is a P1 shadow job; reviewer %s needs a centrally "
                       "precreated live %s assignment before its pane starts" % (subject, job, role))
        review_round = existing.claim_payload["review_of"]["round_no"]
        if review_round in heads:
            attach = review_round
        elif review_round == target.summary["next_round_no"]:
            attach = None
        else:
            raise Fail("claim_conflict", "spawn: assignment %s names round %d of %s, which is neither open nor next"
                       % (job, review_round, subject))
    elif not matching:
        # A fresh id (or one the server will refuse: a reused id, a self-reference,
        # a cross-host subject) goes to the server as the exact scoped claim; its
        # claim_conflict / sequence_conflict / host_mismatch is reported, never
        # pre-empted here (director-1 C1 ruling).
        if not write:
            emit("OK o3=reviewer-verified job=%s subject=%s round=%d mint=pending" % (job, subject, review_round))
            return
        mint = {"job_id": job, "owner_lane": target_claim["owner_lane"],
                "parent_lane": target_claim["owner_lane"], "task_id": target_claim["task_id"],
                "host_client_id": caps["client_id"], "role": role, "tier": target_claim["tier"],
                "review_of": {"job_id": subject, "round_no": review_round}, "predecessor_job_id": None,
                "supersedes": None}
        # The mint intent lives in the NEW reviewer job's canonical dir (6b).
        with Intents(ctx.inbox, job) as store:
            cli_guard(transact)(store, "claim", lambda _s: (0, 0, mint))
        existing = cli_guard(lambda: ctx.state(job))()
        if existing is None or not live_review_claim(existing, subject, role, target_claim["task_id"]):
            raise Fail("claim_conflict", "spawn: the canonical assignment %s does not match subject %s" % (job, subject))
        review_round = existing.claim_payload["review_of"]["round_no"]
        attach = review_round if review_round in heads else None
    else:
        review_round = existing.claim_payload["review_of"]["round_no"]
        attach = review_round if review_round in heads else None
    if not write:
        emit("OK o3=reviewer-verified job=%s subject=%s round=%d" % (job, subject, review_round))
        return
    opened = review_round
    if attach is None:
        payload = {"head": head, "tester_job_id": job, "extension_grant_seq": ext, "repeat_grant_seq": rep}
        meta = meta_from(opts)
        with Intents(ctx.inbox, subject) as store:
            outcome = cli_guard(transact)(store, "round_open",
                                          lambda fresh: (fresh.summary["claim_seq"], fresh.snapshot_seq, payload),
                                          state_reader=cli_guard(lambda: ctx.state(subject, store)))
        record = outcome.record
        if record["payload"]["tester_job_id"] != job:
            raise Fail("claim_conflict", "spawn: the accepted round_open names %s, not %s"
                       % (record["payload"]["tester_job_id"], job))
        opened = record["payload"]["round_no"]
        if not write_projections(ctx.inbox, subject, [record], o3_mode_name(target), meta, "receipt"):
            raise Fail("projection_pending", "round_open receipt stored for %s" % subject)
    emit("OK o3=reviewer job=%s subject=%s round=%d" % (job, subject, opened))


def spawn_verify(ctx, job, opts):
    role = opts.get("--role", "")
    phase = opts.get("--phase", "verify")
    if phase not in ("verify", "commit"):
        raise Fail("usage", "spawn handshake: --phase is verify or commit")
    if role in REVIEW_ROLES and opts.get("--subject"):
        spawn_reviewer(ctx, job, opts, phase == "commit")
    elif role in ("builder", "worker") + REVIEW_ROLES:
        if phase == "commit":
            emit("OK o3=verified job=%s" % job)
        else:
            spawn_subject(ctx, job, opts)
    else:
        raise Fail("usage", "spawn handshake: unknown role %r" % role)


# ── completed / joined adapter operations (C2 wires them into done/joined) ───

def completed(ctx, job, opts):
    data = read_once(opts.get("--report"), "report")
    payload = {"report_b64": b64(data), "report_sha256": sha256_hex(data)}
    with Intents(ctx.inbox, job) as store:
        state = cli_guard(lambda: ctx.state(job, store))()
        if state is None:
            raise Fail("not_found", "completed: job %s is not enrolled" % job)
        if state.claim_payload["role"] in ("builder", "worker") and (
                state.summary["open_rounds"] or state.summary["used"] == 0):
            warn("o3 rounds incomplete for %s (open=%s used=%d); completed is an observation, never a join"
                 % (job, state.summary["open_rounds"], state.summary["used"]))
        outcome = cli_guard(transact)(store, "completed",
                                      lambda fresh: (fresh.summary["claim_seq"], fresh.snapshot_seq, payload),
                                      state_reader=cli_guard(lambda: ctx.state(job, store)))
    emit("RECEIPT " + json.dumps(receipt_of(outcome.record), sort_keys=True))


def pr_arg(value):
    """Shape only (4096 bytes); the https/no-userinfo rule is the server's."""
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 4096:
        raise Fail("usage", "--pr requires a URL of at most 4096 bytes")
    return value


def joined(ctx, job, opts):
    head = head_arg(opts.get("--head"))
    pr = pr_arg(opts.get("--pr"))
    waiver = seq_arg(opts.get("--waiver-grant"), "--waiver-grant")
    if opts.get("--rounds-waived"):
        raise Fail("usage", "joined: an O3 job takes only a typed join_waiver grant (--waiver-grant SEQ), never a "
                   "free waiver ref")
    data = read_once(opts.get("--report"), "report")
    payload = {"head": head, "pr": pr, "report_b64": b64(data), "report_sha256": sha256_hex(data),
               "waiver_grant_seq": waiver}

    def build(fresh):
        if fresh is None:
            raise Fail("not_found", "joined: job %s is not enrolled" % job)
        # The waiver's type, head and use are judged by the server (grant_invalid,
        # grant_consumed, zero_rounds), never pre-empted here.
        return fresh.summary["claim_seq"], fresh.snapshot_seq, payload
    with Intents(ctx.inbox, job) as store:
        outcome = cli_guard(transact)(store, "joined", build, state_reader=cli_guard(lambda: ctx.state(job, store)))
    emit("RECEIPT " + json.dumps(receipt_of(outcome.record), sort_keys=True))


# ── central desk tooling (Q1=A) ──────────────────────────────────────────────

def central(ctx, op, job, opts):
    role = opts.get("--as", "")
    wrapper = central_wrapper(role)

    def write(kind, build, read=True):
        with Intents(ctx.inbox, job) as store:
            reader = cli_guard(lambda: ctx.state(job, store)) if read else None
            outcome = cli_guard(transact)(store, kind, build, binary=wrapper, state_reader=reader)
        emit("OK central=%s kind=%s job=%s seq=%d%s" % (role, kind, job, outcome.record["seq"],
                                                         " resent=pending" if outcome.resent else ""))
        return outcome

    if op in ("claim", "assign"):
        supersedes = seq_arg(opts.get("--supersedes"), "--supersedes")
        if op == "claim":
            task = seq_arg(opts.get("--task"), "--task")
            payload = {"job_id": job, "owner_lane": opts.get("--owner-lane", ""),
                       "parent_lane": opts.get("--parent-lane", ""), "task_id": task,
                       "host_client_id": opts.get("--host", ""), "role": opts.get("--role", ""),
                       "tier": opts.get("--tier", ""), "review_of": None,
                       "predecessor_job_id": job_arg(opts.get("--predecessor"), "--predecessor"),
                       "supersedes": supersedes}
            if payload["role"] not in ("builder", "worker"):
                raise Fail("usage", "central claim mints builder or worker claims; use assign for review roles")
        else:
            target = job_arg(opts.get("--target"), "--target")
            number = seq_arg(opts.get("--round"), "--round")
            if opts.get("--role") not in REVIEW_ROLES or target is None or number is None:
                raise Fail("usage", "central assign needs --target JOB --round N --role tester|reviewer|counsel")
            subject = cli_guard(lambda: read_state(target))()
            if subject is None:
                raise Fail("not_found", "central assign: target %s is not enrolled" % target)
            claim = subject.claim_payload
            payload = {"job_id": job, "owner_lane": claim["owner_lane"], "parent_lane": claim["owner_lane"],
                       "task_id": claim["task_id"], "host_client_id": opts.get("--host") or claim["host_client_id"],
                       "role": opts["--role"], "tier": claim["tier"],
                       "review_of": {"job_id": target, "round_no": number}, "predecessor_job_id": None,
                       "supersedes": None}
        for key, pattern in (("owner_lane", LANE_RE), ("parent_lane", LANE_RE)):
            if not pattern.match(payload[key]):
                raise Fail("usage", "central %s: %s must match %s" % (op, key, pattern.pattern))
        if payload["task_id"] is None or payload["tier"] not in ("T0", "T1", "T2", "T3"):
            raise Fail("usage", "central %s needs --task N and --tier T0..T3" % op)
        if payload["host_client_id"] not in ("desktop", "mac-dev", "mac-work", "rpi", "mac-personal"):
            raise Fail("usage", "central %s: --host must be a host client id" % op)
        if supersedes is None:
            write("claim", lambda _s: (0, 0, payload), read=False)
        else:
            write("claim", lambda fresh: (fresh.summary["claim_seq"], fresh.snapshot_seq, payload))
    elif op == "activate":
        seal = seq_arg(opts.get("--seal-seq"), "--seal-seq")
        reason = code_arg(opts.get("--reason-code") or "central_activate", "--reason-code")
        write("activate", lambda fresh: (fresh.summary["claim_seq"], fresh.snapshot_seq,
                                         {"reason_code": reason, "seal_seq": seal}))
    elif op == "import-begin":
        reason = code_arg(opts.get("--reason-code") or "legacy_import", "--reason-code")
        write("import_begin", lambda fresh: (fresh.summary["claim_seq"], fresh.snapshot_seq, {"reason_code": reason}))
    elif op == "import":
        for path, data in archive_files(opts.get("--events-dir")):
            current = cli_guard(lambda: read_state(job))()
            if current is None:
                raise Fail("not_found", "central import: job %s has no canonical claim" % job)
            imported = {(r["payload"]["source_locator"], r["payload"]["source_sha256"])
                        for r in current.records if r["kind"] == "import"}
            if (path, sha256_hex(data)) in imported:
                continue
            payload = import_payload(path, data)
            write("import", lambda fresh, p=payload: (fresh.summary["claim_seq"], fresh.snapshot_seq, p))
    elif op == "import-seal":
        reason = code_arg(opts.get("--reason-code") or "legacy_import", "--reason-code")
        local = {(path, sha256_hex(data)) for path, data in archive_files(opts.get("--events-dir"))}

        def build(fresh):
            begins = [r for r in fresh.records if r["kind"] == "import_begin"]
            if len(begins) != 1:
                raise Fail("import_unsealed", "central import-seal: job %s has no single import_begin" % job)
            manifest = [{"seq": r["seq"], "source_locator": r["payload"]["source_locator"],
                         "source_sha256": r["payload"]["source_sha256"]}
                        for r in fresh.records if r["kind"] == "import" and r["seq"] > begins[0]["seq"]]
            server = {(m["source_locator"], m["source_sha256"]) for m in manifest}
            if server != local:
                # Desk safety, not the server's import_unsealed: a seal pins only the
                # archive actually supplied, so an incomplete import is not sealed.
                # Each file present on one side only is named (esc-3 I5).
                lines = ["only on the server: %s (sha256 %s)" % item for item in sorted(server - local)]
                lines += ["only in --events-dir: %s (sha256 %s)" % item for item in sorted(local - server)]
                raise Fail("usage", "central import-seal: the server's imports differ from the archive in "
                           "--events-dir; nothing sealed\n  " + "\n  ".join(lines))
            return fresh.summary["claim_seq"], fresh.snapshot_seq, {
                "begin_seq": begins[0]["seq"], "expected_import_count": len(manifest),
                "manifest_sha256": sha256_hex(canonical(manifest).encode("utf-8")), "reason_code": reason}
        write("import_seal", build)
    else:
        raise Fail("usage", "wrk o3 central accepts claim, activate, assign, import-begin, import or import-seal")


def archive_files(directory):
    if not directory or not os.path.isdir(directory):
        raise Fail("usage", "--events-dir requires the archived legacy events directory")
    rows = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(os.path.abspath(directory), name)
        if name.startswith(".") or not name.endswith(".json") or not os.path.isfile(path) or os.path.islink(path):
            continue
        data = read_once(path, "archived event")
        rows.append((path, data))
    return rows


RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")


def import_payload(path, data):
    kind, at = "unparseable", None
    try:
        document = strict_loads(data.decode("utf-8"))
        if isinstance(document, dict):
            if isinstance(document.get("kind"), str) and 0 < len(document["kind"]) <= 64:
                kind = document["kind"]
            for value in (document.get("created_at"), document.get("at")):
                if isinstance(value, str) and RFC3339.match(value):
                    at = value
                    break
    except (UnicodeDecodeError, ValueError):
        pass
    if len(path.encode("utf-8")) > 4096:
        raise Fail("invalid_request", "the archive path is longer than 4096 bytes")
    return {"source_locator": path, "source_sha256": sha256_hex(data), "original_actor_client_id": None,
            "original_at": at, "legacy_kind": kind, "content_b64": b64(data)}


# ── entry point ──────────────────────────────────────────────────────────────

FLAGS = {"--head", "--extension-grant", "--repeat-grant", "--tester", "--file", "--grant", "--reason-code",
         "--round", "--owner", "--label", "--pane", "--parent", "--role", "--task", "--lane", "--tier",
         "--subject", "--report", "--pr", "--waiver-grant", "--rounds-waived", "--as", "--owner-lane",
         "--parent-lane", "--host", "--predecessor", "--supersedes", "--target", "--seal-seq", "--events-dir",
         "--o2-ref", "--phase"}


def parse(argv):
    opts, positional = {}, []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in FLAGS:
            if index + 1 >= len(argv) or token in opts:
                raise Fail("usage", "%s requires one value" % token)
            opts[token] = argv[index + 1]
            index += 2
        elif token.startswith("--"):
            raise Fail("usage", "unknown option %s" % token)
        else:
            positional.append(token)
            index += 1
    return opts, positional


OPS = {"round-open": round_open, "round-verdict": round_verdict, "round-void": round_void,
       "round-status": round_status, "audit-job": audit_job, "spawn-verify": spawn_verify,
       "completed": completed, "joined": joined}


def main(argv):
    try:
        if not argv:
            raise Fail("usage", "wrk_o3.py OP ...")
        op = argv[0]
        if op == "mode":
            emit(records_mode())
            return 0
        opts, positional = parse(argv[1:])
        if op == "central":
            if len(positional) != 2:
                raise Fail("usage", "wrk o3 central OP JOB [options]")
            central(Ctx(), positional[0], job_arg(positional[1], "JOB"), opts)
            return 0
        if op not in OPS or len(positional) != 1:
            raise Fail("usage", "unknown adapter operation or missing job id")
        job = positional[0]
        if not JOB_RE.match(job):
            raise Fail("usage", "job id %r is not an O3 job id" % job)
        OPS[op](Ctx(), job, opts)
        return 0
    except Fail as exc:
        if exc.code == "trust_path":
            # 6b: a noncanonical override is the trust-path refusal, exit 2 before
            # exec; its stable code is cli_usage (M1 transport vector 1), followed
            # by the PR 242 refusal text.
            sys.stderr.write("wrk: o3 cli_usage: refusing a trust-bearing operation: %s\n" % exc.detail)
        else:
            detail = (": " + exc.detail) if exc.detail else ""
            sys.stderr.write("wrk: o3 %s%s\n" % (exc.code, detail))
        return EXIT.get(exc.code, 2)
    except CliFail as exc:
        sys.stderr.write("wrk: o3 %s\n" % exc.code)
        return EXIT.get(exc.code, 75)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
