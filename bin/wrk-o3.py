#!/usr/bin/env python3
"""O3 journal adapter. No HTTP or credential loading lives in this module.

The installed handoffkeep CLI is the sole transport. Both shell commands and
the C2 consumers use Client; local intents/projections are never authority.
Contract: designs/hk1873/b1873a-sol-r4, sections 2, 5, 6 and 6b.
"""
import argparse
import base64
import binascii
from contextlib import contextmanager, nullcontext, redirect_stdout
from datetime import datetime, timezone
import errno
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import stat
import subprocess
import sys
import uuid

CONTRACT = "hk1873.v1"
SCHEMA_SHA = "99e78d7e326f598174ee3f3cf47827ce9a32454105b599f0af5c9b65879bc9f4"
SAFE_INT = 9007199254740991
ZERO_HASH = "0" * 64
OVERRIDE_KEYS = frozenset(("HANDOFFKEEP_URL", "HANDOFFKEEP_TOKEN",
                           "HANDOFFKEEP_CF_ACCESS_CLIENT_ID",
                           "HANDOFFKEEP_CF_ACCESS_CLIENT_SECRET"))
EXIT_CODES = {
    **dict.fromkeys(("round_cap",), 78),
    **dict.fromkeys(("wrk_unavailable", "wrk_recovery_required", "transport_unavailable",
                     "transport_indeterminate", "protocol_invalid", "o3_unsupported",
                     "history_regressed"), 75),
    **dict.fromkeys(("unauthorized", "scope_denied", "host_mismatch"), 77),
    "not_found": 66,
    **dict.fromkeys(("invalid_request", "invalid_cursor", "invalid_verdict", "invalid_path",
                     "grant_before_cap", "request_too_large", "method_not_allowed",
                     "unsupported_media_type"), 65),
    **dict.fromkeys(("idempotency_conflict", "sequence_conflict", "claim_conflict",
                     "job_ended", "review_sealed", "round_not_open", "round_has_verdict",
                     "round_voided", "head_mismatch", "duplicate_path", "duplicate_content",
                     "duplicate_head", "grant_invalid", "grant_consumed", "grant_expired",
                     "zero_rounds", "review_incomplete", "blocker_unresolved",
                     "wrk_receipt_required", "import_unsealed", "import_sealed",
                     "migration_frozen"), 73),
    "cli_usage": 2, "intent_invalid": 74, "intent_io": 74,
}
# These are completely validated CLI representations of definite HTTP 4xx.
# All protocol/transport/503 outcomes remain pending, regardless of process exit.
DEFINITE = frozenset(k for k, v in EXIT_CODES.items() if v in (65, 66, 73, 77, 78))
HISTORY_RESULTS = frozenset(("not_found", "generation_regressed", "seq_regressed"))
PROJECTED_COMMANDS = {
    "round_open": "wrk round open", "verdict": "wrk round verdict", "void": "wrk round void",
    "completed": "wrk o3 completed", "joined": "wrk o3 joined",
}


class Refusal(Exception):
    def __init__(self, code):
        self.code = code
        self.exit = EXIT_CODES[code]
        super().__init__(code)


class TypedCommandRequired(Refusal):
    def __init__(self, kind):
        super().__init__("cli_usage")
        self.command = PROJECTED_COMMANDS.get(
            kind, "the typed wrk command (wrk round, wrk o3 completed/joined, or central desk tooling)")

    def line(self):
        return "wrk o3: cli_usage; use " + self.command + "\n"


class HistoryFault(Refusal):
    def __init__(self, result):
        super().__init__("history_regressed")
        self.result = result


class EndedHistoryFault(HistoryFault):
    def __init__(self, job, key, end, result):
        super().__init__(result)
        self.job, self.key, self.end = job, key, end

    def line(self):
        fields = (self.job, self.key or "none", self.end, self.result)
        return "wrk o3: history_regressed job=%s key=%s local_end=%s GET_result=%s\n" % tuple(
            shlex.quote(str(value)).replace("\n", "\\n").replace("\r", "\\r") for value in fields)


class ModeRefusal(Refusal):
    def __init__(self, component):
        super().__init__("cli_usage")
        self.component = str(component)

    def line(self):
        quoted = shlex.quote(self.component).replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        return "wrk o3: cli_usage component=" + quoted + "\n"


def strict_json(raw, code="protocol_invalid"):
    def pairs(items):
        out = {}
        for key, value in items:
            if key in out:
                raise ValueError("duplicate key")
            out[key] = value
        return out
    try:
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "strict")
        return json.loads(raw, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError, RecursionError):
        raise Refusal(code) from None


def read_request_stdin():
    raw = sys.stdin.buffer.read(1048577)
    if len(raw) > 1048576:
        raise Refusal("request_too_large")
    return strict_json(raw, "invalid_request")


def canonical(value):
    """RFC8785 for this contract's closed, safe-integer JSON vocabulary.

    No wire field allows a floating-point number. Sort keys by UTF-16 code
    units, retain Unicode bytes and reject lone surrogates/non-safe integers.
    """
    def encode(v):
        if v is None or type(v) is bool:
            return json.dumps(v)
        if type(v) is int and -SAFE_INT <= v <= SAFE_INT:
            return str(v)
        if isinstance(v, str):
            v.encode("utf-8", "strict")
            return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
        if isinstance(v, list):
            return "[" + ",".join(encode(x) for x in v) + "]"
        if isinstance(v, dict) and all(isinstance(k, str) for k in v):
            keys = sorted(v, key=lambda k: k.encode("utf-16be", "strict"))
            return "{" + ",".join(encode(k) + ":" + encode(v[k]) for k in keys) + "}"
        raise ValueError("outside contract JSON vocabulary")
    try:
        return encode(value).encode("utf-8")
    except (ValueError, UnicodeError, RecursionError):
        raise Refusal("invalid_request") from None


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def request_digest(job, request):
    return digest({"method": "POST", "path": "/v1/wrk/jobs/" + job + "/records",
                   "body": request})


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def job_name(job):
    if not isinstance(job, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", job):
        raise Refusal("cli_usage")
    return job


def seq_arg(value):
    if not re.fullmatch(r"[0-9]+", value, re.ASCII) or int(value) > SAFE_INT:
        raise Refusal("cli_usage")
    return int(value)


def positive_seq_arg(value):
    result = seq_arg(value)
    if result == 0:
        raise Refusal("cli_usage")
    return result


def cursor_arg(value):
    # Cursor meaning belongs to the server; only wire representability is local.
    if type(value) is int:
        result = value
    elif isinstance(value, str) and re.fullmatch(r"[+-]?[0-9]+", value, re.ASCII):
        digits = value.lstrip("+-").lstrip("0") or "0"
        if len(digits) > 16:
            raise Refusal("cli_usage")
        result = int(digits) * (-1 if value.startswith("-") else 1)
    else:
        raise Refusal("cli_usage")
    if not -SAFE_INT <= result <= SAFE_INT:
        raise Refusal("cli_usage")
    return result


class Schema:
    """The exact fixed contract, with its finite JSON-Schema keyword subset.

    No optional dependency or downloaded schema is used on an installed host.
    The bundle is byte-pinned independently of the vendored test vectors.
    """
    def __init__(self):
        raw = Path(__file__).with_name("wrk-o3-contract.json").read_bytes()
        if hashlib.sha256(raw).hexdigest() != SCHEMA_SHA:
            raise Refusal("protocol_invalid")
        self.bundle = strict_json(raw)

    def check(self, name, value, code="protocol_invalid"):
        if not self.matches(self.bundle["$defs"][name], value):
            raise Refusal(code)

    def matches(self, s, v):
        if "$ref" in s:
            return self.matches(self.bundle["$defs"][s["$ref"].split("/")[-1]], v)
        if "oneOf" in s and sum(self.matches(x, v) for x in s["oneOf"]) != 1:
            return False
        if "anyOf" in s and not any(self.matches(x, v) for x in s["anyOf"]):
            return False
        if "const" in s and (type(v) is not type(s["const"]) or v != s["const"]):
            return False
        if "enum" in s and not any(type(v) is type(x) and v == x for x in s["enum"]):
            return False
        kinds = {"object": dict, "array": list, "string": str, "integer": int,
                 "boolean": bool, "null": type(None)}
        if "type" in s and type(v) is not kinds[s["type"]]:
            return False
        if isinstance(v, dict):
            props = s.get("properties", {})
            if not set(s.get("required", ())).issubset(v):
                return False
            for k, x in v.items():
                rule = props.get(k, s.get("additionalProperties", True))
                if rule is False or isinstance(rule, dict) and not self.matches(rule, x):
                    return False
        if isinstance(v, list):
            if s.get("uniqueItems") and len({canonical(x) for x in v}) != len(v):
                return False
            if "items" in s and not all(self.matches(s["items"], x) for x in v):
                return False
        if type(v) is int and not s.get("minimum", -SAFE_INT) <= v <= s.get("maximum", SAFE_INT):
            return False
        if isinstance(v, str):
            try:
                v.encode("utf-8", "strict")
            except UnicodeError:
                return False
            if not s.get("minLength", 0) <= len(v) <= s.get("maxLength", sys.maxsize):
                return False
            if "pattern" in s and not re.fullmatch(s["pattern"], v, re.ASCII):
                return False
            if s.get("format") == "uuid" and not valid_uuid(v):
                return False
            if s.get("format") == "date-time":
                try:
                    if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z", v):
                        return False
                    datetime.fromisoformat(v.replace("Z", "+00:00"))
                except ValueError:
                    return False
            if s.get("format") == "uri" and not re.match(r"[A-Za-z][A-Za-z0-9+.-]*:", v):
                return False
        return True


class Resolver:
    def __init__(self):
        # Execute ONLY the already-shared Python decision block, never a shell,
        # and never hk_bin. This is the PR242 implementation, not a second policy.
        wrk = Path(__file__).with_name("wrk").read_text(encoding="utf-8")
        begin = wrk.index("# --- trust paths: begin")
        end = wrk.index("# --- trust paths: end ---", begin)
        self.guard = {"os": os, "shutil": __import__("shutil"), "stat": stat}
        exec(compile(wrk[begin:end], "wrk PR242 trust block", "exec"), self.guard)

    def resolve(self, central=None, need_hk=True):
        try:
            home = pwd.getpwuid(os.getuid()).pw_dir
        except (KeyError, OSError):
            home = ""
        test = os.environ.get("WRK_TEST_MODE") == "1"
        fixtures = str(Path(__file__).resolve().parents[1] / "tests/fixtures")
        try:
            chosen = self.guard["trust_resolve"](os.environ, home, os.getuid(), test, need_hk, fixtures)
            chosen["home"] = os.environ.get("HOME", "") if test else home
            if central is not None:
                if central not in ("director-1", "operator-desk"):
                    raise Refusal("cli_usage")
                wrapper = os.path.join(chosen["home"], ".local", "bin", "hk-" + central)
                chosen["hk"] = self.guard["trust_secure_binary"](wrapper, os.getuid())
            return chosen
        except self.guard["TrustRefusal"]:
            # No caller-selected path or environment value is exposed.
            raise Refusal("cli_usage") from None


def records_mode(resolver):
    test = os.environ.get("WRK_TEST_MODE") == "1"
    if test and not os.environ.get("HOME"):
        return "legacy"  # discovery only; Client.call still runs the guard
    try:
        home = resolver.resolve(need_hk=False)["home"] if test else pwd.getpwuid(os.getuid()).pw_dir
    except (KeyError, OSError):
        raise Refusal("cli_usage") from None
    directory = Path(home)
    parent = directory.parent
    if not parent.is_dir() or not os.access(parent, os.X_OK):
        raise ModeRefusal(parent)
    for component in (directory, directory / ".config", directory / ".config/wrk"):
        try:
            info = component.lstat()
        except FileNotFoundError:
            return "legacy"  # its preceding parent was proved searchable
        except OSError:
            raise ModeRefusal(component) from None
        if not stat.S_ISDIR(info.st_mode) or not os.access(component, os.X_OK):
            raise ModeRefusal(component)
    path = Path(home) / ".config/wrk/records-mode"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return "legacy"
    except OSError:
        raise Refusal("cli_usage") from None
    try:
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise Refusal("cli_usage")
            value = stream.read(32).decode("ascii").strip()
    except (OSError, UnicodeError):
        raise Refusal("cli_usage") from None
    if value not in ("legacy", "shadow", "required"):
        raise Refusal("cli_usage")
    return value


def secure_open(name, flags, dir_fd, create=False):
    try:
        try:
            fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK,
                         0o600, dir_fd=dir_fd)
        except FileNotFoundError:
            if not flags & os.O_CREAT or flags & os.O_EXCL:
                raise
            # Match wrk's position_guard_open: a peer creating the same
            # lock can race with O_CREAT on macOS. Reopen the existing inode
            # once, without creation or symlink following; validate it below.
            fd = os.open(name, (flags & ~os.O_CREAT) | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=dir_fd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            raise Refusal("intent_invalid") from None
        raise
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
        os.close(fd)
        raise Refusal("intent_invalid")
    # Nonblocking open protects the type check from a planted FIFO. Once
    # this descriptor is proven regular, its reads and locking use blocking IO.
    try:
        os.set_blocking(fd, True)
    except OSError:
        os.close(fd)
        raise
    return fd


def atomic_json(dir_fd, name, data):
    temp = ".o3-" + str(uuid.uuid4())
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=dir_fd)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical(data) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        os.fsync(dir_fd)
    finally:
        try:
            os.unlink(temp, dir_fd=dir_fd)
        except FileNotFoundError:
            pass


class IntentStore:
    def __init__(self, client, job):
        self.client, self.job = client, job_name(job)

    @contextmanager
    def locked(self):
        root = Path(self.client.resolver.resolve(self.client.central)["inbox"])
        directory = root / self.job
        dir_fd = lock_fd = None
        self.io_stage = "mkdir"
        try:
            root.mkdir(parents=True, exist_ok=True)
            directory.mkdir(mode=0o700, exist_ok=True)
            self.io_stage = "open_directory"
            dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            # Persist a new reviewer intent directory before the first send.
            parent_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                self.io_stage = "fsync_parent"
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
            self.io_stage = "open_lock"
            lock_fd = secure_open("o3-intents.lock", os.O_RDWR | os.O_CREAT, dir_fd)
            self.io_stage = "flock"
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            self.dir_fd = dir_fd
            try:
                self.io_stage = "read_intents"
                fd = secure_open("o3-intents.json", os.O_RDONLY, dir_fd)
            except FileNotFoundError:
                data = {"version": 1, "intents": []}
            else:
                with os.fdopen(fd, "rb") as stream:
                    data = strict_json(stream.read(), "intent_invalid")
            self.validate(data)
            self.io_stage = "transaction"
            yield data
        except Refusal:
            raise
        except OSError as exc:
            failure = Refusal("intent_io")
            failure.io_stage, failure.os_errno = self.io_stage, exc.errno
            raise failure from None
        finally:
            if lock_fd is not None:
                os.close(lock_fd)
            if dir_fd is not None:
                os.close(dir_fd)

    def validate(self, data):
        if (not isinstance(data, dict) or set(data) != {"version", "intents"}
                or type(data["version"]) is not int or data["version"] != 1
                or not isinstance(data["intents"], list)):
            raise Refusal("intent_invalid")
        ids, keys = set(), set()
        for item in data["intents"]:
            fields = {"local_id", "job_id", "idempotency_key", "request", "request_sha256",
                      "state", "receipt", "error"}
            if not isinstance(item, dict) or set(item) not in (fields, fields | {"history_regressed"}):
                raise Refusal("intent_invalid")
            if (not valid_uuid(item["local_id"]) or not valid_uuid(item["idempotency_key"])
                    or item["local_id"] in ids or item["idempotency_key"] in keys
                    or item["job_id"] != self.job):
                raise Refusal("intent_invalid")
            if "history_regressed" in item:
                note = item["history_regressed"]
                if (not isinstance(note, dict) or set(note) != {"observed_at", "get_result"}
                        or not isinstance(note["get_result"], str)
                        or note["get_result"] not in HISTORY_RESULTS
                        or not isinstance(note["observed_at"], str)
                        or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|\+00:00)", note["observed_at"])):
                    raise Refusal("intent_invalid")
                try:
                    datetime.fromisoformat(note["observed_at"].replace("Z", "+00:00"))
                except ValueError:
                    raise Refusal("intent_invalid") from None
            ids.add(item["local_id"]); keys.add(item["idempotency_key"])
            self.client.schema.check("Request", item["request"], "intent_invalid")
            if request_digest(self.job, item["request"]) != item["request_sha256"]:
                raise Refusal("intent_invalid")
            state, receipt, error = item["state"], item["receipt"], item["error"]
            if state == "accepted":
                if not valid_receipt(receipt, self.job) or error is not None:
                    raise Refusal("intent_invalid")
            elif state == "pending":
                if receipt is not None or error is not None:
                    raise Refusal("intent_invalid")
            elif state == "rejected":
                if receipt is not None or error not in DEFINITE:
                    raise Refusal("intent_invalid")
            else:
                raise Refusal("intent_invalid")

    def save(self, data):
        self.validate(data)
        self.io_stage = "write_intents"
        atomic_json(self.dir_fd, "o3-intents.json", data)


def valid_receipt(receipt, job):
    return (isinstance(receipt, dict)
            and set(receipt) == {"job_id", "seq", "record_hash", "store_generation"}
            and receipt["job_id"] == job and type(receipt["seq"]) is int
            and 1 <= receipt["seq"] <= SAFE_INT
            and isinstance(receipt["record_hash"], str)
            and re.fullmatch(r"[0-9a-f]{64}", receipt["record_hash"])
            and valid_uuid(receipt["store_generation"]))


def receipt_for(record):
    return {key: record[key] for key in ("job_id", "seq", "record_hash", "store_generation")}


class Client:
    def __init__(self, central=None):
        self._event_contexts = {}
        self._current_intents = {}
        self.central = central
        self.resolver, self.schema = Resolver(), Schema()

    def call(self, args, schema, payload=None):
        if not args or args[0] not in ("capabilities", "append", "job", "records", "content"):
            raise Refusal("cli_usage")
        # Revalidate for EVERY operation, including retries and cursor pages.
        chosen = self.resolver.resolve(self.central)
        # Index only retained keys: even overridden credential values are never read.
        child_env = {key: os.environ[key] for key in os.environ if key not in OVERRIDE_KEYS}
        child_env["HOME"] = chosen["home"]
        try:
            result = subprocess.run([chosen["hk"], "wrk", *args],
                                    input=canonical(payload) if payload is not None else b"",
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=child_env, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise Refusal("transport_indeterminate" if payload is not None else "transport_unavailable") from None
        if result.returncode:
            match = re.fullmatch(rb"handoffkeep wrk: ([a-z][a-z0-9_]*)\n", result.stderr)
            code = match[1].decode("ascii") if match else "protocol_invalid"
            if result.stdout or code not in EXIT_CODES or EXIT_CODES[code] != result.returncode:
                code = "protocol_invalid"
            raise Refusal(code)
        if result.stderr or not result.stdout.endswith(b"\n") or result.stdout.count(b"\n") != 1:
            raise Refusal("protocol_invalid")
        value = strict_json(result.stdout)
        self.schema.check(schema, value)
        return value

    def capabilities(self):
        return self.call(["capabilities"], "Capabilities")

    def check_record(self, record, job, generation=None):
        self.schema.check("Record", record)
        if generation is not None and record["store_generation"] != generation:
            raise HistoryFault("generation_regressed")
        unhashed = {key: value for key, value in record.items() if key != "record_hash"}
        if (record["job_id"] != job or record["record_hash"] != digest(unhashed)
                or generation is not None and record["store_generation"] != generation):
            raise HistoryFault("seq_regressed")
        if record["kind"] == "import_seal":
            seal = record["payload"]
            if seal["numbering_floor"] < seal["baseline_used"]:
                # Director-1 E7 ruling: reject inconsistent seals; do not repair
                # a defective fixture by max(floor,baseline).
                raise Refusal("protocol_invalid")

    def enrollment_witnesses(self, job):
        # Retained receipts and complete snapshots can only veto a read.
        # They never supply positive authority or replace fresh records.
        store = IntentStore(self, job)
        with store.locked() as intents:
            return (self.snapshot_locked(store),
                    [item["receipt"] for item in intents["intents"] if item["receipt"] is not None])

    def protected_witness(self, job):
        store = IntentStore(self, job)
        with store.locked() as intents:
            snapshot = self.snapshot_locked(store)
            return (snapshot is not None and snapshot["receipt_required"]
                    or any(item["state"] == "accepted" and receipt_required([item["request"]])
                           for item in intents["intents"]))

    def history_warning(self, job, result="seq_regressed"):
        with self.events_locked(job) as local:
            end = local.ns["wrk_end_declaration"](local.events)
            if not end:
                self.warning(job, "history_regressed", "history")
                return
            key = None
            current = self._current_intents.get(job)
            if current is not None:
                store = IntentStore(self, job)
                with store.locked() as data:
                    item = next((x for x in data["intents"] if x["local_id"] == current), None)
                    if item is not None:
                        key = item["idempotency_key"]
                        if "history_regressed" not in item:
                            item["history_regressed"] = dict(
                                observed_at=datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
                                get_result=result)
                            store.save(data)  # durable observation, never an event or a state rollback
            raise EndedHistoryFault(job, key, end, result)

    def job(self, job):
        snapshot, receipts = self.enrollment_witnesses(job)
        try:
            return self.read_job(job)
        except Refusal as exc:
            if isinstance(exc, EndedHistoryFault):
                raise
            if exc.code == "not_found" and (snapshot is not None or receipts):
                self.history_warning(job, "not_found")
                raise HistoryFault("not_found") from None
            if exc.code == "history_regressed":
                self.history_warning(job, getattr(exc, "result", "seq_regressed"))
            raise

    def read_job(self, job):
        job_name(job)
        value = self.call(["job", job], "JobResponse")
        self.check_record(value["claim"], job, value["summary"]["store_generation"])
        if (value["claim"]["kind"] != "claim" or value["summary"]["job_id"] != job
                or value["claim"]["seq"] != value["summary"]["claim_seq"]):
            raise Refusal("protocol_invalid")
        # Fetch complete fixed-snapshot history before a summary drives a
        # decision. Retained receipts/snapshots can only veto that fresh read.
        history = self.records(job)
        if history["summary"]["store_generation"] != value["summary"]["store_generation"]:
            raise HistoryFault("generation_regressed")
        if (history["summary"]["snapshot_seq"] < value["summary"]["snapshot_seq"]
                or history["summary"]["store_generation"] != value["summary"]["store_generation"]):
            raise HistoryFault("seq_regressed")
        canonical_claim = next((r for r in history["records"]
                                if r["seq"] == history["summary"]["claim_seq"]), None)
        if canonical_claim is None or canonical_claim["kind"] != "claim":
            raise Refusal("protocol_invalid")
        return {"contract": CONTRACT, "claim": canonical_claim,
                "summary": history["summary"], "records": history["records"]}

    def records(self, job, limit=None):
        snapshot, receipts = self.enrollment_witnesses(job)
        try:
            return self.read_records(job, limit)
        except Refusal as exc:
            if isinstance(exc, EndedHistoryFault):
                raise
            if exc.code == "not_found" and (receipts or snapshot is not None):
                self.history_warning(job, "not_found")
                raise HistoryFault("not_found") from None
            if exc.code == "history_regressed":
                self.history_warning(job, getattr(exc, "result", "seq_regressed"))
            raise

    def read_records(self, job, limit=None):
        job_name(job)
        after, cursor_after, snapshot, generation, previous = 0, None, None, None, ZERO_HASH
        records = []
        while True:
            page = self._record_page(job, after_seq=cursor_after, snapshot_seq=snapshot, limit=limit)
            summary = page["summary"]
            if snapshot is None:
                snapshot, generation = page["snapshot_seq"], summary["store_generation"]
                frozen_summary = summary
            if (page["snapshot_seq"] != snapshot or summary != frozen_summary
                    or summary["snapshot_seq"] != snapshot or summary["job_id"] != job
                    or not page["records"]):
                raise Refusal("protocol_invalid")
            for record in page["records"]:
                self.check_record(record, job, generation)
                if record["seq"] != after + 1 or record["previous_hash"] != previous or record["seq"] > snapshot:
                    raise HistoryFault("seq_regressed")
                records.append(record)
                after, previous = record["seq"], record["record_hash"]
            if page["next_after_seq"] != after or page["has_more"] != (after < snapshot):
                raise Refusal("protocol_invalid")
            if not page["has_more"]:
                if previous != summary["tail_hash"]:
                    raise HistoryFault("seq_regressed")
                break
            cursor_after = after
        self.cache_history(job, records, frozen_summary)
        return {"contract": CONTRACT, "snapshot_seq": snapshot, "summary": frozen_summary,
                "records": records}

    def cache_history(self, job, records, summary):
        generation, snapshot, previous = summary["store_generation"], summary["snapshot_seq"], summary["tail_hash"]
        store = IntentStore(self, job)
        with store.locked() as intents:
            cached = self.snapshot_locked(store)
            if cached is not None:
                if cached["store_generation"] != generation:
                    raise HistoryFault("generation_regressed")
                seq = cached["snapshot_seq"]
                if (cached["store_generation"] != generation or seq > snapshot
                        or records[seq - 1]["record_hash"] != cached["tail_hash"]
                        or cached["receipt_required"] and not receipt_required(records)):
                    raise HistoryFault("seq_regressed")
            for item in intents["intents"]:
                receipt = item["receipt"]
                if receipt is not None:
                    if receipt["store_generation"] != generation:
                        raise HistoryFault("generation_regressed")
                    seq = receipt["seq"]
                    if (receipt["store_generation"] != generation or seq > snapshot
                            or records[seq - 1]["record_hash"] != receipt["record_hash"]):
                        raise HistoryFault("seq_regressed")
            claims = [r for r in records if r["kind"] == "claim"]
            if not claims or claims[-1]["seq"] != summary["claim_seq"]:
                raise Refusal("protocol_invalid")
            snapshot_value = dict(summary=summary, store_generation=generation,
                                  snapshot_seq=snapshot, tail_hash=previous,
                                  receipt_required=receipt_required(records),
                                  role=claims[-1]["payload"]["role"],
                                  read_at=datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"))
            self.save_snapshot(job, snapshot_value)

    def _record_page(self, job, after_seq=None, snapshot_seq=None, limit=None):
        args = ["records", job_name(job)]
        for flag, value in (("--after-seq", after_seq), ("--limit", limit), ("--snapshot-seq", snapshot_seq)):
            if value is not None:
                args.extend([flag, str(cursor_arg(value))])
        return self.call(args, "RecordsResponse")

    def record_page(self, job, after_seq=None, snapshot_seq=None, limit=None):
        """Wire/display page. Decisions use records(), which verifies every page."""
        cached, receipts = self.enrollment_witnesses(job)
        try:
            page = self._record_page(job, after_seq=after_seq, snapshot_seq=snapshot_seq, limit=limit)
            summary, snapshot = page["summary"], page["snapshot_seq"]
            after = 0 if after_seq is None else cursor_arg(after_seq)
            if (summary["job_id"] != job or summary["snapshot_seq"] != snapshot
                    or snapshot_seq is not None and cursor_arg(snapshot_seq) != snapshot
                    or after < 0 or after > snapshot):
                raise Refusal("protocol_invalid")
            previous, end = ZERO_HASH if after == 0 else None, after
            for record in page["records"]:
                self.check_record(record, job, summary["store_generation"])
                if (record["seq"] != end + 1 or record["seq"] > snapshot
                        or previous is not None and record["previous_hash"] != previous):
                    raise HistoryFault("seq_regressed")
                end, previous = record["seq"], record["record_hash"]
            if (page["next_after_seq"] != end or page["has_more"] != (end < snapshot)
                    or page["has_more"] and not page["records"]):
                raise Refusal("protocol_invalid")
            if page["records"] and not page["has_more"] and previous != summary["tail_hash"]:
                raise HistoryFault("seq_regressed")
            witnesses = list(receipts)
            if cached is not None:
                witnesses.append(dict(store_generation=cached["store_generation"], seq=cached["snapshot_seq"],
                                      record_hash=cached["tail_hash"]))
            hashes = {record["seq"]: record["record_hash"] for record in page["records"]}
            for witness in witnesses:
                if witness["store_generation"] != summary["store_generation"]:
                    raise HistoryFault("generation_regressed")
                if (witness["store_generation"] != summary["store_generation"] or witness["seq"] > snapshot
                        or witness["seq"] in hashes and hashes[witness["seq"]] != witness["record_hash"]):
                    raise HistoryFault("seq_regressed")
            if after == 0 and not page["has_more"]:
                self.cache_history(job, page["records"], summary)
            return page
        except Refusal as exc:
            if isinstance(exc, EndedHistoryFault):
                raise
            if exc.code == "not_found" and (cached is not None or receipts):
                self.history_warning(job, "not_found")
                raise HistoryFault("not_found") from None
            if exc.code == "history_regressed":
                self.history_warning(job, getattr(exc, "result", "seq_regressed"))
            raise

    def save_snapshot(self, job, snapshot):
        # Caller holds the intents lock; obtain the same canonical directory,
        # but never recursively acquire its flock.
        directory = Path(self.resolver.resolve(self.central)["inbox"]) / job
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                old_fd = secure_open("o3-snapshot.json", os.O_RDONLY, fd)
            except FileNotFoundError:
                pass
            else:
                os.close(old_fd)
            atomic_json(fd, "o3-snapshot.json", snapshot)
        finally:
            os.close(fd)

    def snapshot(self, job):
        """Routing/display or a negative witness; never authorizes a write."""
        store = IntentStore(self, job)
        with store.locked():
            return self.snapshot_locked(store)

    def snapshot_locked(self, store):
        try:
            fd = secure_open("o3-snapshot.json", os.O_RDONLY, store.dir_fd)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "rb") as stream:
            value = strict_json(stream.read(), "intent_invalid")
        fields = {"summary", "store_generation", "snapshot_seq", "tail_hash",
                  "receipt_required", "role", "read_at"}
        if not isinstance(value, dict) or set(value) != fields:
            raise Refusal("intent_invalid")
        self.schema.check("Summary", value["summary"], "intent_invalid")
        if (value["summary"]["job_id"] != store.job
                or type(value["receipt_required"]) is not bool
                or value["role"] not in ("builder", "worker", "tester", "reviewer", "counsel")
                or not isinstance(value["read_at"], str)
                or any(value[k] != value["summary"][k] for k in ("store_generation", "snapshot_seq", "tail_hash"))):
            raise Refusal("intent_invalid")
        return value

    def content(self, job, seq, record=None):
        job_name(job)
        if type(seq) is not int or not 1 <= seq <= SAFE_INT:
            raise Refusal("cli_usage")
        value = self.call(["content", job, str(seq)], "ContentResponse")
        raw = decode_content(value["content_b64"], "protocol_invalid")
        if (value["job_id"] != job or value["seq"] != seq or value["size_bytes"] != len(raw)
                or value["content_sha256"] != hashlib.sha256(raw).hexdigest()):
            raise Refusal("protocol_invalid")
        if record is not None:
            payload = record["payload"]
            expected = payload.get("content_sha256", payload.get("report_sha256", payload.get("source_sha256")))
            if expected != value["content_sha256"]:
                raise HistoryFault("seq_regressed")
        return value

    def append_public(self, job, request=None, resume=None):
        """Raw CLI writes cannot replace a typed C1 command or its O2 veto."""
        self._current_intents.pop(job, None)
        if resume is not None:
            with IntentStore(self, job).locked() as data:
                item = next((x for x in data["intents"] if x["local_id"] == resume), None)
                if item is None:
                    raise Refusal("intent_invalid")
                checked = item["request"]
                self._current_intents[job] = resume
        else:
            checked = request
            self.schema.check("Request", checked, "invalid_request")
        if checked["kind"] in PROJECTED_COMMANDS:
            raise TypedCommandRequired(checked["kind"])
        try:
            current = self.job(job)
        except Refusal as exc:
            if exc.code != "not_found":
                raise
            raise TypedCommandRequired(checked["kind"]) from None
        if not receipt_required(current["records"]):
            raise TypedCommandRequired(checked["kind"])
        return self.append(job, request, resume=resume, public=True)

    def append(self, job, request=None, resume=None, replay_accepted=False, public=False):
        try:
            return self._append(job, request, resume, replay_accepted, public)
        except HistoryFault as exc:
            if not isinstance(exc, EndedHistoryFault):
                self.history_warning(job, exc.result)
            raise

    def _append(self, job, request=None, resume=None, replay_accepted=False, public=False):
        """One durable send. No implicit network retry, CAS refresh or key rewrite."""
        job_name(job)
        store = IntentStore(self, job)
        with store.locked() as data:
            if resume is not None:
                item = next((x for x in data["intents"] if x["local_id"] == resume), None)
                if item is None:
                    raise Refusal("intent_invalid")
            else:
                self.schema.check("Request", request, "invalid_request")
                validate_evidence(request)
                sha = request_digest(job, request)
                item = next((x for x in data["intents"] if x["request_sha256"] == sha
                             and x["state"] != "rejected"), None)
                if item is None:
                    item = dict(local_id=str(uuid.uuid4()), job_id=job,
                                idempotency_key=str(uuid.uuid4()), request=request,
                                request_sha256=sha, state="pending", receipt=None, error=None)
                    data["intents"].append(item)
            # Recheck the actual retained request under the send lock: a
            # concurrent edit must not switch an approved raw replay to a
            # projecting kind between classification and this locked read.
            if public and item["request"]["kind"] in PROJECTED_COMMANDS:
                raise TypedCommandRequired(item["request"]["kind"])
            self._current_intents[job] = item["local_id"]
            if item["state"] == "rejected":
                raise Refusal(item["error"])
            if item["state"] == "accepted" and not replay_accepted:
                # Normally repair through fresh reads; P1 end reconciliation
                # explicitly resends the original acceptance before refusing.
                return self.repair_record(job, item["receipt"])
            store.save(data)  # MUST complete file+directory fsync before send.
            req = item["request"]
            args = ["append", job, "--kind", req["kind"], "--idempotency-key", item["idempotency_key"],
                    "--expected-seq", str(req["expected_seq"]), "--claim-seq", str(req["claim_seq"])]
            try:
                response = self.call(args, "WriteResponse", req["payload"])
                record = response["record"]
                self.check_record(record, job, response["summary"]["store_generation"])
                if (record["kind"] != req["kind"] or record["request_sha256"] != item["request_sha256"]
                        or record["idempotency_key"] != item["idempotency_key"]
                        or record["seq"] != req["expected_seq"] + 1
                        or record["claim_seq"] != (record["seq"] if req["kind"] == "claim" else req["claim_seq"])
                        or response["summary"]["claim_seq"] != record["claim_seq"]
                        or response["summary"]["job_id"] != job
                        or response["summary"]["snapshot_seq"] != record["seq"]
                        or response["summary"]["tail_hash"] != record["record_hash"]):
                    raise Refusal("protocol_invalid")
                if any(record["payload"].get(k) != v for k, v in req["payload"].items()
                       if k not in ("content_b64", "report_b64")):
                    raise Refusal("protocol_invalid")
                if any(x["receipt"] is not None and x["receipt"]["store_generation"] != record["store_generation"]
                       for x in data["intents"]):
                    raise HistoryFault("generation_regressed")
                if item["receipt"] is not None and receipt_for(record) != item["receipt"]:
                    raise HistoryFault("seq_regressed")
            except Refusal as exc:
                if exc.code in DEFINITE and item["state"] != "accepted":
                    item.update(state="rejected", error=exc.code)
                    store.save(data)
                raise
            item.update(state="accepted", receipt=receipt_for(record), error=None)
            store.save(data)  # MUST persist accepted receipt before projection.
            return response

    def repair_record(self, job, receipt):
        # Called with the intent lock held; avoid recursive records() locking.
        try:
            page = self.call(["records", job, "--after-seq", str(receipt["seq"] - 1),
                              "--snapshot-seq", str(receipt["seq"]), "--limit", "1"], "RecordsResponse")
        except Refusal as exc:
            if exc.code == "not_found":
                raise HistoryFault("not_found") from None
            raise
        if page["summary"]["store_generation"] != receipt["store_generation"]:
            raise HistoryFault("generation_regressed")
        if (page["snapshot_seq"] != receipt["seq"]
                or page["summary"]["snapshot_seq"] != receipt["seq"]
                or page["summary"]["job_id"] != job
                or page["summary"]["store_generation"] != receipt["store_generation"]
                or page["summary"]["tail_hash"] != receipt["record_hash"]
                or page["next_after_seq"] != receipt["seq"] or page["has_more"]):
            raise Refusal("protocol_invalid")
        if len(page["records"]) != 1:
            raise HistoryFault("seq_regressed")
        record = page["records"][0]
        self.check_record(record, job, receipt["store_generation"])
        if receipt_for(record) != receipt:
            raise HistoryFault("seq_regressed")
        return {"contract": CONTRACT, "created": False, "record": record, "summary": page["summary"]}

    def pending(self, job, kind, **identity):
        with IntentStore(self, job).locked() as data:
            found = [x for x in data["intents"] if x["state"] == "pending"
                     and x["request"]["kind"] == kind
                     and all(x["request"]["payload"].get(k) == v for k, v in identity.items())]
            if len(found) > 1:
                raise Refusal("intent_invalid")
            return found[0]["local_id"] if found else None

    def unfinished(self, job, kind, **identity):
        """Find a pending send or a durable acceptance needing read repair."""
        events = Path(self.resolver.resolve(self.central)["inbox"]) / job / "events"
        projected = set()
        if events.is_dir():
            for path in events.glob("*.json"):
                try:
                    record = strict_json(path.read_bytes())
                    if isinstance(record, dict) and record.get("idempotency_key"):
                        projected.add(record["idempotency_key"])
                except (OSError, Refusal, KeyError):
                    continue
        with IntentStore(self, job).locked() as data:
            found = [x for x in data["intents"]
                     if (x["state"] == "pending" or x["state"] == "accepted" and x["idempotency_key"] not in projected)
                     and x["request"]["kind"] == kind
                     and all(x["request"]["payload"].get(k) == v for k, v in identity.items())]
            if len(found) > 1:
                raise Refusal("intent_invalid")
            return found[0]["local_id"] if found else None

    def evidence(self, job, kind, path, expected_seq, claim_seq, **fields):
        identity = {"path": str(path)} if kind == "verdict" else {}
        if kind == "import":
            identity = {"source_locator": fields["source_locator"]}
        if kind == "verdict":
            identity["round_no"] = fields["round_no"]
        pending = self.pending(job, kind, **identity)
        if pending:
            return self.append(job, resume=pending)
        raw = read_evidence(path)
        payload = dict(fields)
        if kind == "verdict":
            verdict, head = verdict_header(raw)
            payload.update(path=str(path), head=head, verdict=verdict)
        prefix = "content" if kind in ("verdict", "import") else "report"
        payload[prefix + "_b64"] = base64.b64encode(raw).decode("ascii")
        payload[("source" if kind == "import" else prefix) + "_sha256"] = hashlib.sha256(raw).hexdigest()
        return self.append(job, dict(kind=kind, expected_seq=expected_seq, claim_seq=claim_seq, payload=payload))

    @contextmanager
    def events_locked(self, job):
        """Share the unchanged O2 events lock with validation and projection."""
        if job in self._event_contexts:
            yield self._event_contexts[job]
            return
        chosen = self.resolver.resolve(self.central)
        events = Path(chosen["inbox"]) / job_name(job) / "events"
        events.mkdir(parents=True, exist_ok=True)
        source = Path(__file__).with_name("wrk").read_text(encoding="utf-8")
        code = re.search(r"^WRK_EVENTS_PY='\n(.*?)^'$", source, re.M | re.S)
        if code is None:
            raise Refusal("protocol_invalid")
        ns = {}
        exec(compile(code[1], "wrk shared events", "exec"), ns)
        with ns["wrk_events_locked"](str(events)):
            context = LocalRounds(str(events), ns, source, job)
            self._event_contexts[job] = context
            try:
                yield context
            finally:
                del self._event_contexts[job]

    def project(self, response, mode, history=None):
        """After durable acceptance only; C2 owns done/joined consumer wiring."""
        record = response["record"]
        kinds = {"round_open": "job.round", "verdict": "job.verdict", "void": "job.round_void",
                 "joined": "job.joined", "completed": "job.completed"}
        if record["kind"] not in kinds:
            return
        projection = dict(record["payload"])
        projection.update(kind=kinds[record["kind"]], job_id=record["job_id"], epoch=1,
                          o3_mode=mode, wrk_receipt=receipt_for(record),
                          idempotency_key=record["idempotency_key"])
        if "round_no" in projection:
            projection["round"] = projection.pop("round_no")
        if not response["created"]:
            projection["provenance"] = "server_repair"
        try:
            with self.events_locked(record["job_id"]) as local:
                # An O2 observation remains the same observation after replay.
                if local.has_key(record["idempotency_key"], projection["kind"]):
                    return
                grants = (("extension_grant_seq", "extension_grant_record_hash"),
                          ("repeat_grant_seq", "repeat_grant_record_hash")) if record["kind"] == "round_open" else (("grant_seq", "grant_record_hash"),) if record["kind"] == "void" else ()
                for seq_field, hash_field in grants:
                    grant_seq = record["payload"].get(seq_field)
                    if grant_seq is None:
                        projection.pop(seq_field, None)
                        continue
                    history = history or self.records(record["job_id"])
                    fields = local.grant_fields(history["records"], record["claim_seq"], grant_seq)
                    projection.update({seq_field: grant_seq, hash_field: fields["hash"]})
                    if record["kind"] == "void":
                        projection.update(ref=fields["ref"], issuer=fields["issuer"],
                                          reason=record["payload"]["reason_code"])
                    elif seq_field == "extension_grant_seq":
                        projection["approval"] = dict(ref=fields["ref"], issuer=fields["issuer"],
                                                      extra=fields["extra"])
                        projection["reason"] = fields["reason"]
                if record["kind"] == "verdict" and history is not None:
                    permission = local.repeat_permission(history, record["payload"])
                    if permission:
                        projection.update(head_repeat=permission[0], head_repeat_issuer=permission[1])
                self.event(record["job_id"], projection)
        except (OSError, Refusal):
            raise ProjectionPending() from None

    def event(self, job, record):
        with self.events_locked(job) as local:
            if record["kind"] == "job.o3_warning" and local.ns["wrk_end_declaration"](local.events):
                return
            if record.get("idempotency_key") and local.has_key(record["idempotency_key"], record["kind"]):
                return
            records = local.records()
            if record.get("wrk_receipt"):
                if any(r.get("wrk_receipt") == record["wrk_receipt"] and r.get("kind") == record["kind"] for r in records):
                    return
            if record["kind"] == "job.o3_warning":
                if any(all(r.get(k) == record.get(k) for k in ("kind", "code", "operation", "idempotency_key")) for r in records):
                    return
            claims = [r.get("payload", r) for r in records if r.get("kind") in ("job.claim", "job.reclaim")]
            meta = claims[-1] if claims else {}
            for field in ("owner_lane", "parent_lane", "label", "pane_id"):
                record.setdefault(field, meta.get(field, ""))
            local.ns["wrk_event_commit"](local.events, record["kind"], record)

    def warning(self, job, code, operation, key=None):
        self.event(job, dict(kind="job.o3_warning", job_id=job, code=code,
                             operation=operation, idempotency_key=key, o3_mode="shadow", epoch=1))

    def retry_pending(self, job, kind, **identity):
        # Only an existing operational intent selects this branch. Absence
        # never infers enrollment or creates a local claim/pane reservation.
        directory = Path(self.resolver.resolve(self.central)["inbox"]) / job_name(job)
        if os.path.lexists(directory / "o3-intents.json"):
            pending = self.pending(job, kind, **identity)
            if pending:
                return self.append(job, resume=pending)
        return None

    def spawn_check(self, job, role, tier, task=None, owner=None, parent=None,
                    subject=None, head=None, extension=None, repeat=None, mode="required", predecessor=None, repo=None):
        if role in ("tester", "reviewer", "counsel") and subject:
            with self.events_locked(job_name(subject)):
                return self._spawn_check(job, role, tier, task, owner, parent,
                                         subject, head, extension, repeat, mode, predecessor, repo)
        return self._spawn_check(job, role, tier, task, owner, parent,
                                 subject, head, extension, repeat, mode, predecessor, repo)

    def _spawn_check(self, job, role, tier, task=None, owner=None, parent=None,
                     subject=None, head=None, extension=None, repeat=None, mode="required", predecessor=None, repo=None):
        """C1 admission handshake only; no quota, pane, link/rebind or release.

        Central claim/activation are desk operations. A host may mint only
        the exact same-host scoped reviewer assignment defined by section 2.
        """
        job_name(job)
        if role in ("tester", "reviewer", "counsel") and subject:
            if subject == job:
                raise Refusal("claim_conflict")  # before target lookup
            # A prior unknown claim/open must reconcile before fresh target
            # liveness, CAS or local Git checks can refuse the new attempt.
            self.retry_pending(job, "claim", job_id=job)
            with IntentStore(self, subject).locked() as data:
                backlog = [x["local_id"] for x in data["intents"] if x["state"] == "pending"]
            recovered = []
            for intent in backlog:
                try:
                    recovered.append(self.append(subject, resume=intent))
                except Refusal as exc:
                    if exc.code not in DEFINITE:
                        raise
            target = self.job(subject)
            target_enforced = receipt_required(target["records"])
            local = self._event_contexts[subject]
            if not target_enforced:
                local.end("open", recovered[0]["record"]["idempotency_key"] if recovered else None)
            for response in recovered:
                if response["record"]["kind"] in ("round_open", "verdict", "void"):
                    self.project(response, "enforced" if target_enforced else "shadow", target)
            canonical = target["claim"]["payload"]
            state = target["summary"]["state"]
            if canonical["role"] not in ("builder", "worker") or state not in ("active", "shadow"):
                raise Refusal("round_not_open")
            if state == "shadow" and mode != "shadow":
                raise Refusal("wrk_receipt_required")
            if tier != canonical["tier"] or task is not None and task != canonical["task_id"]:
                raise Refusal("claim_conflict")
            if not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{40}", head):
                raise Refusal("cli_usage")
            if repo is not None:
                validate_head(self, subject, head, repo)
            live = [r for r in target["records"] if r["kind"] == "round_open"
                    and r["payload"]["round_no"] in target["summary"]["open_rounds"]
                    and r["payload"]["head"] == head
                    and r["payload"]["tester_job_id"] in (None, job)]
            existing_open = min(live, key=lambda r: r["payload"]["round_no"]) if live else None
            round_no = existing_open["payload"]["round_no"] if existing_open else target["summary"]["next_round_no"]
            capabilities = self.capabilities()
            if not capabilities["writes_available"]:
                raise Refusal("wrk_unavailable")
            local_host = capabilities["client_id"]
            claim = dict(job_id=job, owner_lane=canonical["owner_lane"],
                         parent_lane=canonical["owner_lane"], task_id=canonical["task_id"],
                         host_client_id=local_host, role=role, tier=tier,
                         review_of=dict(job_id=subject, round_no=round_no),
                         predecessor_job_id=None, supersedes=None)
            try:
                assignment = self.job(job)
            except Refusal as exc:
                if exc.code != "not_found":
                    raise
                if state == "shadow":
                    # P1 central precreation is mandatory, never host mint
                    # followed by a business-409 warning/fallback.
                    raise Refusal("claim_conflict") from None
                if canonical["host_client_id"] != local_host:
                    raise Refusal("host_mismatch") from None
                pending = self.pending(job, "claim", job_id=job)
                if pending:
                    self.append(job, resume=pending)
                else:
                    self.append(job, dict(kind="claim", expected_seq=0, claim_seq=0, payload=claim))
                assignment = self.job(job)  # GET verify AFTER claim acknowledgement
            assigned = assignment["claim"]["payload"]
            if (assignment["summary"]["state"] == "ended"
                    or any(r["kind"] == "end" for r in assignment["records"])):
                raise Refusal("job_ended")
            for field, value in claim.items():
                # Central cross-host assignments are accepted, but the new
                # reviewer MUST belong to this authenticated execution host.
                if assigned.get(field) != value:
                    raise Refusal("host_mismatch" if field == "host_client_id" else "claim_conflict")
            if owner is not None and owner != assigned["owner_lane"]:
                raise Refusal("claim_conflict")
            if existing_open is None:
                request = dict(kind="round_open", expected_seq=target["summary"]["snapshot_seq"],
                               claim_seq=target["summary"]["claim_seq"],
                               payload=dict(head=head, tester_job_id=job,
                                            extension_grant_seq=extension, repeat_grant_seq=repeat))
                if not target_enforced:
                    local.validate("open", request["payload"], target)
                    local.check_number(target["summary"]["next_round_no"])
                pending = self.unfinished(subject, "round_open", head=head, tester_job_id=job)
                opened = self.append(subject, resume=pending) if pending else self.append(subject, request)
            else:
                opened = dict(contract=CONTRACT, created=False, record=existing_open, summary=target["summary"])
            self.project(opened, "enforced" if target_enforced else "shadow", target)
            return dict(task_id=assigned["task_id"], owner_lane=assigned["owner_lane"],
                        parent_lane=assigned["parent_lane"], inherited=True, receipt_required=True,
                        claim_receipt=receipt_for(assignment["claim"]))
        capabilities = self.capabilities()
        if not capabilities["writes_available"]:
            raise Refusal("wrk_unavailable")
        current = route_job(self, job, mode)
        if current is None:
            return None
        if current.get("offline"):
            # Shadow observations can fail open; a new pane cannot.
            raise Refusal("transport_unavailable")
        claim = current["claim"]["payload"]
        if current["summary"]["state"] not in ("active", "shadow"):
            raise Refusal("job_ended" if current["summary"]["state"] in ("ended", "joined") else "migration_frozen")
        if current["summary"]["state"] != "active" and mode != "shadow":
            raise Refusal("wrk_receipt_required")
        if current["summary"]["state"] == "active" and not any(r["kind"] == "activate" for r in current["records"]):
            raise Refusal("protocol_invalid")
        if claim["role"] in ("tester", "reviewer", "counsel"):
            raise Refusal("claim_conflict")  # reviewer handshake requires --parent-job and --head
        if claim["host_client_id"] != capabilities["client_id"]:
            raise Refusal("host_mismatch")
        if (claim["role"] != role or claim["tier"] != tier
                or task is not None and claim["task_id"] != task
                or owner is not None and claim["owner_lane"] != owner
                or parent is not None and claim["parent_lane"] != parent
                or predecessor is not None and claim["predecessor_job_id"] != predecessor):
            raise Refusal("claim_conflict")
        return dict(task_id=claim["task_id"], owner_lane=claim["owner_lane"],
                    parent_lane=claim["parent_lane"], inherited=claim["predecessor_job_id"] is not None,
                    receipt_required=receipt_required(current["records"]), claim_receipt=receipt_for(current["claim"]))


class LocalRefusal(Refusal):
    def __init__(self, message, exit_code=2):
        self.code, self.exit = "local_o2_refusal", exit_code
        Exception.__init__(self, message)
        self.message = message


class LocalRounds:
    """Execute the existing O2 validators without changing their decisions.

    The fixed sibling wrk owns these validators. Only their lock wrapper and
    commit sink are substituted: the caller already holds that same lock and
    the candidate must wait for the canonical append. Verdict bytes come from
    the one captured request, never a second read of the reviewer's file.
    """
    def __init__(self, events, ns, source, job):
        self.events, self.ns, self.source, self.job = events, ns, source, job

    def records(self):
        return [r for _, r, _ in self.ns["wrk_events_ordered"](self.events) if isinstance(r, dict)]

    def has_key(self, key, kind):
        return any(r.get("idempotency_key") == key and r.get("kind") == kind for r in self.records())

    def audit(self):
        # Reuse the unchanged O2 readers. These observations are display
        # findings only; they never establish enrollment or supply a receipt.
        _, _, scan = self.run_guard("job_events_scan", [])
        owner = scan["owner"] or "-"
        lines = []
        recorded, _ = self.ns["wrk_round_census"](self.events, self.job)
        if (self.ns["wrk_claim_role"](self.events) in ("builder", "captain")
                and not scan["ended"] and recorded == 0):
            lines.append("zero-rounds job=%s lane=%s" % (self.job, owner))
        _, blocks, _ = self.run_guard("wrk_join_blocks", [str(Path(self.events).parent), self.job])
        for line in blocks.splitlines():
            if line.startswith("unmatched\t"):
                lines.append("unmatched-verdict job=%s file=%s" % (self.job, line.split("\t", 1)[1]))
        return owner, [line + " label=O2-unverified" for line in lines]

    def end(self, operation, key=None):
        name = self.ns["wrk_end_declaration"](self.events)
        if name:
            prefix = "warning key=%s " % key if key else ""
            raise LocalRefusal(prefix + "round %s: refused after end record %s" % (operation, name))

    def run_guard(self, function, args, raw=None):
        body = self.source.split(function + "() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        body = body.replace('exec(os.environ["WRK_EVENTS_PY"])', '')
        body = body.replace('with open(lock_path, "w", encoding="utf-8") as lock:\n    fcntl.flock(lock, fcntl.LOCK_EX)',
                            'with nullcontext():')
        body = body.replace('with open(vfile, "rb") as raw:', 'with io.BytesIO(_o3_evidence) as raw:')
        captured, output = [], io.StringIO()
        ns = dict(self.ns, nullcontext=nullcontext, _o3_evidence=raw,
                  wrk_event_commit=lambda events, kind, record: captured.append(record))
        original = sys.argv
        try:
            sys.argv = ["wrk O2 validation", self.events, *map(str, args)]
            with redirect_stdout(output):
                try:
                    exec(compile(body, "wrk existing " + function, "exec"), ns)
                except SystemExit as exc:
                    if exc.code:
                        raise Refusal("protocol_invalid") from None
        finally:
            sys.argv = original
        return captured, output.getvalue().strip(), ns

    def next_round(self):
        _, _, ns = self.run_guard("round_scan", [])
        return max(ns["used"], max(ns["round_numbers"], default=0)) + 1

    def check_number(self, server_next):
        local_next = self.next_round()
        if local_next != server_next:
            raise LocalRefusal("job=%s local_next_round=%d server_next_round=%d orphaned local round=%d; director decision required" %
                               (self.job, local_next, server_next, local_next - 1), 75)

    def grant_fields(self, records, claim_seq, grant_seq):
        grant = next((r for r in records if r["seq"] == grant_seq and r["kind"] == "grant"), None)
        claim = next((r for r in records if r["seq"] == claim_seq and r["kind"] == "claim"), None)
        if grant is None or claim is None or grant["actor_client_id"] not in ("director-1", "operator-desk"):
            raise Refusal("protocol_invalid")
        ref = "hk:task/" + str(claim["payload"]["task_id"])
        consumed = {r.get("extension_grant_seq") for r in self.records()
                    if r.get("kind") == "job.round" and (r.get("approval") or {}).get("ref") == ref}
        consumed.discard(None)
        return dict(ref=ref, issuer=grant["actor_client_id"], hash=grant["record_hash"],
                    reason=grant["payload"]["reason_code"], extra=len(consumed - {grant_seq}) + 1 + sum(1 for r in self.records()
                          if r.get("kind") == "job.round" and not r.get("extension_grant_seq")
                          and (r.get("approval") or {}).get("ref") == ref))

    def repeat_permission(self, history, payload):
        local = self.records()
        number, head = payload["round_no"], payload["head"]
        opened = next((r for r in local if r.get("kind") == "job.round" and r.get("round") == number), None)
        if not opened or not opened.get("repeat_grant_seq") or not opened.get("repeat_grant_record_hash"):
            return None
        grant = next((r for r in history["records"] if r["kind"] == "grant" and r["seq"] == opened["repeat_grant_seq"]), None)
        if (grant is None or grant["record_hash"] != opened["repeat_grant_record_hash"]
                or grant["actor_client_id"] not in ("director-1", "operator-desk")):
            return None
        earlier = []
        for verdict in local:
            if verdict.get("kind") != "job.verdict" or verdict.get("head") != head:
                continue
            if any(r.get("kind") == "job.round_void" and r.get("round") == verdict.get("round")
                   and isinstance(r.get("ref"), str) and r["ref"].startswith(("hk:task/", "hk:doc/")) for r in local):
                continue
            earlier.append(verdict.get("round"))
        consumed = next((r for r in history["records"] if r["kind"] == "round_open"
                         and r["payload"]["round_no"] == number and r["payload"]["head"] == head
                         and r["payload"]["repeat_grant_seq"] == grant["seq"]), None)
        frozen = grant["payload"]
        if (consumed is None or not earlier or frozen["grant_type"] != "head_repeat" or frozen["round_no"] != number
                or frozen["head"] != head or frozen["earlier_round_no"] != earlier[0]):
            return None
        # An opaque canonical record hash identifies this one-use permission;
        # it is never a caller-supplied approval reference.
        return "o3:" + grant["record_hash"], grant["actor_client_id"], str(number)

    def validate(self, operation, payload, history=None, raw=None):
        self.end(operation)
        meta = [r.get("payload", r) for r in self.records() if r.get("kind") in ("job.claim", "job.reclaim")]
        meta = meta[-1] if meta else {}
        owner, label, pane, parent = [meta.get(k, "") for k in ("owner_lane", "label", "pane_id", "parent_lane")]
        ref, issuer, extra = "", "", 0
        grant = payload.get("extension_grant_seq") if operation == "open" else payload.get("grant_seq")
        if grant:
            # O2 needs a compatible reference/count for its local veto only.
            # The server validates the typed grant and its issuer/consumption.
            task = meta.get("task_id", "unknown")
            if history is not None:
                claim = next(r for r in history["records"] if r["seq"] == history["summary"]["claim_seq"])
                task = claim["payload"]["task_id"]
            ref = "hk:task/" + str(task)
            extra = 1 + sum(1 for r in self.records() if (r.get("approval") or {}).get("ref") == ref)
        if operation == "open":
            args = [self.job, owner, label, pane, parent, payload["head"], 3, ref, extra, issuer]
        elif operation == "void":
            args = [self.job, payload["round_no"], ref, payload["reason_code"], issuer]
        else:
            permission = self.repeat_permission(history, payload) if history is not None else None
            args = [self.job, owner, label, pane, parent, payload["path"], "commit", *(permission or ("", "", ""))]
        function = "round_verdict_decide" if operation == "verdict" else "round_" + operation + "_cmd"
        candidates, result, _ = self.run_guard(function, args, raw)
        if candidates:
            return candidates[0]
        if result.startswith("CAP "):
            raise LocalRefusal("round cap 3 reached for " + self.job, 78)
        raise LocalRefusal("round %s: %s" % (operation, result))

    def veto(self, args):
        self.end(args.command)
        raw = None
        if args.command == "open":
            payload = dict(head=(args.head or "").lower(), extension_grant_seq=args.extension_grant)
        elif args.command == "void":
            payload = dict(round_no=args.number, grant_seq=args.grant, reason_code=args.reason_code)
        else:
            raw = read_evidence(os.path.abspath(args.file))
            payload = dict(path=os.path.abspath(args.file))
        self.validate(args.command, payload, raw=raw)


class ProjectionPending(Refusal):
    def __init__(self):
        super().__init__("transport_indeterminate")


TEMPORARY = frozenset(("transport_unavailable", "transport_indeterminate", "wrk_unavailable", "wrk_recovery_required"))
LEGACY_ROUTE = 90  # internal dispatch only, never a handoffkeep/adapter error


def route_job(client, job, mode):
    try:
        return client.job(job)
    except Refusal as exc:
        if exc.code == "not_found" and mode == "shadow":
            client.warning(job, exc.code, "legacy_route")
            return None
        if exc.code not in TEMPORARY:
            raise
        snapshot = client.snapshot(job)
        if (snapshot is None or mode != "shadow" or client.protected_witness(job)
                or snapshot["role"] not in ("builder", "worker") or snapshot["summary"]["state"] != "shadow"):
            raise Refusal("transport_unavailable") from None
        return dict(summary=snapshot["summary"], records=[], offline=True)


def validate_head(client, job, head, fallback=None):
    if not re.fullmatch(r"[0-9a-f]{40}", head or ""):
        raise Refusal("cli_usage")
    candidates = []
    events = Path(client.resolver.resolve()["inbox"]) / job / "events"
    source = Path(__file__).with_name("wrk").read_text()
    code = re.search(r"^WRK_EVENTS_PY='\n(.*?)^'$", source, re.M | re.S)
    ns = {}
    exec(compile(code[1], "wrk shared events", "exec"), ns)
    claims = [r.get("payload", r) for _, r, _ in ns["wrk_events_ordered"](str(events))
              if isinstance(r, dict) and r.get("kind") in ("job.claim", "job.reclaim")]
    if claims:
        candidates.extend(claims[-1].get(k) for k in ("repo", "worktree", "cwd"))
    candidates.append(fallback)
    env = {key: os.environ[key] for key in os.environ if key not in OVERRIDE_KEYS}
    env["GIT_TERMINAL_PROMPT"] = "0"
    repo = None
    for candidate in candidates:
        if not isinstance(candidate, str) or not candidate:
            continue
        try:
            out = subprocess.run(["git", "-C", candidate, "rev-parse", "--show-toplevel"],
                                 capture_output=True, timeout=5, env=env, check=False)
            if out.returncode == 0:
                repo = out.stdout.decode().strip()
                break
        except (OSError, subprocess.TimeoutExpired, UnicodeError):
            continue
    if repo is None:
        raise Refusal("cli_usage")
    def run(args, timeout):
        try:
            return subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=timeout, env=env, check=False).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False
    check = ["git", "-C", repo, "cat-file", "-e", head + "^{commit}"]
    if not run(check, 10):
        run(["git", "-C", repo, "fetch", "origin"], 30)
        if not run(check, 10):
            raise Refusal("cli_usage")


def round_cli(client, argv, mode):
    parser = Parser(prog="wrk round", allow_abbrev=False)
    parser.add_argument("command", choices=("open", "verdict", "void", "status", "audit"))
    parser.add_argument("job", nargs="?")
    parser.add_argument("number", nargs="?", type=positive_seq_arg)
    parser.add_argument("--head")
    parser.add_argument("--repo")
    parser.add_argument("--file")
    parser.add_argument("--extension-grant", type=positive_seq_arg)
    parser.add_argument("--repeat-grant", type=positive_seq_arg)
    parser.add_argument("--tester")
    parser.add_argument("--grant", type=positive_seq_arg)
    parser.add_argument("--reason-code", default="builder_void")
    parser.add_argument("--lane")
    # Parse the legacy ref options only so an unknown shadow job can retain
    # its existing O2 path. They are refused for every canonical enrollment.
    parser.add_argument("--extend")
    parser.add_argument("--by")
    parser.add_argument("--head-repeat")
    parser.add_argument("--reason")
    args = parser.parse_args(argv)
    if args.command == "audit":
        if args.job is not None:
            raise Refusal("cli_usage")
        root = Path(client.resolver.resolve()["inbox"])
        lines = []
        for directory in sorted(root.iterdir()) if root.is_dir() else []:
            if not directory.is_dir() or directory.is_symlink():
                continue
            result = LEGACY_ROUTE
            # Q3 markers select audit reads only; their absence never proves
            # non-enrollment. Unqueried observations remain explicitly O2.
            if any((directory / marker).exists() for marker in ("o3-intents.json", "o3-snapshot.json")):
                result = round_cli(client, ["status", directory.name], mode)
            if result == LEGACY_ROUTE or "stale=true" in result.split():
                with client.events_locked(directory.name) as local:
                    owner, findings = local.audit()
                # The local lane filters display/offline routing only. Every
                # positive canonical line below still needs the complete GET.
                if args.lane and owner != args.lane:
                    continue
                lines.extend(findings if result == LEGACY_ROUTE else [result])
            else:
                if args.lane and "lane=" + args.lane not in result.split():
                    continue
                lines.append(result)
        return "\n".join(lines)
    job = job_name(args.job)
    client._current_intents.pop(job, None)
    if args.command == "status":
        try:
            current = client.job(job)
        except Refusal as exc:
            if exc.code == "not_found" and mode == "shadow":
                client.warning(job, exc.code, "status")
                return LEGACY_ROUTE
            if exc.code not in TEMPORARY:
                raise
            snapshot = client.snapshot(job)
            if snapshot is None:
                raise Refusal("transport_unavailable") from None
            client.warning(job, exc.code, "status")
            return ("job=%s used=%d stale=true generation=%s seq=%d read_at=%s label=O2-unverified" %
                    (job, snapshot["summary"]["used"], snapshot["store_generation"],
                     snapshot["snapshot_seq"], snapshot["read_at"]))
        s = current["summary"]
        return "job=%s lane=%s cap=3 rounds=%d open=%s generation=%s seq=%d stale=false label=O3 unmatched_verdicts=%d" % (
            job, current["claim"]["payload"]["owner_lane"], s["used"], ",".join(map(str, s["open_rounds"])) or "-",
            s["store_generation"], s["snapshot_seq"], unmatched_evidence(client, job, current["records"]))
    with client.events_locked(job) as local:
        return round_mutation(client, local, args, mode)


def round_mutation(client, local, args, mode):
    job = local.job
    operation = {"open": "round_open", "verdict": "verdict", "void": "void"}[args.command]
    if args.command == "verdict" and not args.file:
        raise Refusal("cli_usage")
    if args.command == "open" and not re.fullmatch(r"[0-9a-fA-F]{40}", args.head or ""):
        raise Refusal("cli_usage")
    if args.command == "void" and (args.number is None or args.grant is None):
        raise Refusal("cli_usage")
    identity = ({"head": (args.head or "").lower(), "tester_job_id": args.tester} if args.command == "open"
                else {"round_no": args.number, "grant_seq": args.grant} if args.command == "void"
                else {"path": os.path.abspath(args.file)})
    unfinished = client.unfinished(job, operation, **identity)
    with IntentStore(client, job).locked() as data:
        pending = [dict(x) for x in data["intents"] if x["state"] == "pending"]
    replayed, matched, matched_error, attempt_keys = [], None, None, []
    # Resolve the entire ordered backlog before classification or a new append.
    # A definite refusal can leave an orphaned O2 observation; never renumber it.
    for item in pending:
        attempt_keys.append(item["idempotency_key"])
        try:
            response = client.append(job, resume=item["local_id"])
        except Refusal as exc:
            if exc.code not in DEFINITE:
                raise
            if item["local_id"] == unfinished:
                matched_error = exc
        else:
            replayed.append(response)
            if item["local_id"] == unfinished:
                matched = response
    if unfinished and not matched and not matched_error:
        # A stored acceptance after a local end must be replayed, too. Ordinary
        # accepted read repair still uses records, with its original receipt.
        with IntentStore(client, job).locked() as data:
            attempt_keys.append(next(x["idempotency_key"] for x in data["intents"] if x["local_id"] == unfinished))
        response = client.append(job, resume=unfinished,
                                 replay_accepted=bool(local.ns["wrk_end_declaration"](local.events)))
        replayed.append(response)
        matched = response
    try:
        current = route_job(client, job, mode)
    except Refusal as exc:
        if exc.code in TEMPORARY and not client.protected_witness(job):
            local.veto(args)
        raise
    if current is None:
        local.end(args.command)
        return LEGACY_ROUTE
    if args.extend is not None or args.by is not None or args.reason is not None or args.head_repeat is not None:
        raise Refusal("cli_usage")
    enforced = not current.get("offline") and receipt_required(current["records"])
    projection_mode = "enforced" if enforced else "shadow"
    if not enforced:
        key = attempt_keys[0] if attempt_keys else None
        local.end(args.command, key)
    if current.get("offline"):
        # A stale shadow cache cannot classify a new mutation. O2 guards are
        # only a veto, and a snapshot never supplies positive authority.
        local.veto(args)
        raise Refusal("transport_unavailable")
    for response in replayed:
        if response["record"]["kind"] in ("round_open", "verdict", "void"):
            client.project(response, projection_mode, current)
    if matched_error:
        raise matched_error
    if matched:
        return round_result(job, matched, projection_mode)
    summary = current["summary"]
    raw = None
    if args.command == "open":
        head = (args.head or "").lower()
        validate_head(client, job, head, args.repo)
        payload = dict(head=head, tester_job_id=args.tester,
                       extension_grant_seq=args.extension_grant, repeat_grant_seq=args.repeat_grant)
    elif args.command == "void":
        payload = dict(round_no=args.number, grant_seq=args.grant, reason_code=args.reason_code)
    else:
        path = os.path.abspath(args.file)
        raw = read_evidence(path)  # Exact bytes captured ONCE.
        verdict, head = verdict_header(raw)
        opens = [r for r in current["records"] if r["kind"] == "round_open"
                 and r["payload"]["round_no"] in summary["open_rounds"]]
        matching = [r for r in opens if r["payload"]["head"] == head]
        target = min(matching or opens, key=lambda r: r["payload"]["round_no"], default=None)
        # An absent matching open is semantic evidence for the server. A
        # complete canonical read still supplies the exact fallback round.
        number = target["payload"]["round_no"] if target else summary["next_round_no"]
        assigned = target["payload"]["tester_job_id"] if target else None
        tester = args.tester if args.tester is not None else assigned
        payload = dict(round_no=number, head=head, verdict=verdict,
                       path=path, content_b64=base64.b64encode(raw).decode("ascii"),
                       content_sha256=hashlib.sha256(raw).hexdigest(), tester_job_id=tester)
    candidate = None
    if not enforced:
        # Same O2 guards and same lock as legacy commands, before intent/send.
        candidate = local.validate(args.command, payload, current, raw)
        local.check_number(summary["next_round_no"])
        if args.command == "verdict" and candidate["round"] != payload["round_no"]:
            raise LocalRefusal("job=%s head=%s local_target_round=%d server_target_round=%d orphaned local round=%d; director decision required" %
                               (job, payload["head"], candidate["round"], payload["round_no"], candidate["round"]), 75)
    request = dict(kind=operation, claim_seq=summary["claim_seq"],
                   expected_seq=summary["snapshot_seq"], payload=payload)
    try:
        response = client.append(job, request)
    except Refusal as exc:
        uses_grant = any(payload.get(k) is not None for k in ("grant_seq", "extension_grant_seq", "repeat_grant_seq"))
        if (not enforced and mode == "shadow" and summary["state"] == "shadow"
                and exc.code in TEMPORARY and not uses_grant):
            pending_id = client.pending(job, operation, **identity)
            with IntentStore(client, job).locked() as data:
                item = next(x for x in data["intents"] if x["local_id"] == pending_id)
                candidate.update(o3_mode="shadow", wrk_receipt=None, idempotency_key=item["idempotency_key"])
                client.event(job, candidate)
                client.warning(job, exc.code, operation, item["idempotency_key"])
            return "OK job=%s label=O2-unverified pending=true" % job
        raise
    client.project(response, projection_mode, current)
    return round_result(job, response, projection_mode)


def round_result(job, response, mode):
    record = response["record"]
    return "OK job=%s round=%s kind=%s seq=%d o3_mode=%s" % (
        job, record["payload"].get("round_no", "-"), record["kind"], record["seq"], mode)


def decode_content(value, code="invalid_request"):
    try:
        raw = base64.b64decode(value, validate=True)
        if base64.b64encode(raw).decode("ascii") != value or not raw or len(raw) > 262144:
            raise ValueError()
        return raw
    except (ValueError, binascii.Error):
        raise Refusal(code) from None


def verdict_header(raw):
    # Extract only fields needed to form Input_verdict. Body UTF-8, extra
    # headers and all semantic evidence checks belong to the canonical
    # server, after its authentication/permission ordering.
    first, lf, _body = raw.partition(b"\n")
    try:
        line = first.decode("ascii", "strict")
    except UnicodeError:
        raise Refusal("invalid_verdict") from None
    match = re.fullmatch(r"VERDICT: (PASS|BLOCKER) @([0-9a-fA-F]{40})[ \t]*(?:\r)?", line, re.ASCII)
    if match is None or first.endswith(b"\r") and not lf:
        raise Refusal("invalid_verdict")
    return match[1], match[2].lower()


def validate_evidence(request):
    kind, payload = request["kind"], request["payload"]
    field = "content_b64" if kind in ("verdict", "import") else "report_b64"
    if field not in payload:
        return
    # Only unsendable input is rejected here. Director-1's 2026-10-26
    # ordering ruling: scope/permission and duplicate path/content can
    # precede semantic digest/head checks. The canonical server owns them.
    decode_content(payload[field])


def read_evidence(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise Refusal("invalid_path")
            raw = stream.read(262145)
    except OSError:
        raise Refusal("invalid_path") from None
    if not raw or len(raw) > 262144:
        raise Refusal("request_too_large" if raw else "invalid_request")
    return raw


def unmatched_evidence(client, job, records):
    directory = Path(client.resolver.resolve()["inbox"]) / job
    verdicts = [r["payload"] for r in records if r["kind"] == "verdict"]
    paths = {v["path"] for v in verdicts}
    hashes = {v["content_sha256"] for v in verdicts}
    count = 0
    for path in directory.iterdir():
        if path.is_symlink() or not path.is_file():
            continue
        try:
            with path.open("rb") as stream:
                first = stream.readline(4096)
                if not re.fullmatch(rb"VERDICT: (PASS|BLOCKER) @[0-9a-fA-F]{40}[ \t]*\r?\n?", first):
                    continue
                rest = stream.read(262145)
            sha = hashlib.sha256(first + rest).hexdigest()
            if str(path.absolute()) not in paths and sha not in hashes:
                count += 1
        except OSError:
            continue
    return count


def receipt_required(records):
    return any(r["kind"] == "activate" or r["kind"] == "claim"
               and r["payload"]["role"] in ("tester", "reviewer", "counsel")
               and r["payload"]["review_of"] is not None for r in records)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("cli_usage")

    def parse_args(self, args=None, namespace=None):
        tokens = list(sys.argv[1:] if args is None else args)
        flags = [x.split("=", 1)[0] for x in tokens if x.startswith("--")]
        if len(flags) != len(set(flags)):
            raise Refusal("cli_usage")
        return super().parse_args(tokens, namespace)


def central_cli(argv):
    parser = Parser(prog="wrk o3 central", allow_abbrev=False)
    parser.add_argument("command", choices=("claim", "activate", "assign", "import-begin", "import", "import-seal"))
    parser.add_argument("job")
    parser.add_argument("--role", choices=("director-1", "operator-desk"), required=True)
    parser.add_argument("--expected-seq", type=int, required=True)
    parser.add_argument("--claim-seq", type=int, required=True)
    parser.add_argument("--resume")
    parser.add_argument("--file")
    parser.add_argument("--source-locator")
    parser.add_argument("--legacy-kind")
    parser.add_argument("--original-actor")
    parser.add_argument("--original-at")
    parser.add_argument("--begin-seq", type=int)
    parser.add_argument("--reason-code", default="desk_import")
    args = parser.parse_args(argv)
    client = Client(central=args.role)
    job_name(args.job)
    if args.resume:
        return client.append(args.job, resume=args.resume)
    kind = {"assign": "claim", "import-begin": "import_begin", "import-seal": "import_seal"}.get(args.command, args.command)
    if kind == "import":
        if not args.file or not args.source_locator or not args.legacy_kind:
            raise Refusal("cli_usage")
        return client.evidence(args.job, kind, args.file, args.expected_seq, args.claim_seq,
                               source_locator=args.source_locator, legacy_kind=args.legacy_kind,
                               original_actor_client_id=args.original_actor, original_at=args.original_at)
    if kind == "import_seal":
        pending = client.retry_pending(args.job, kind, begin_seq=args.begin_seq)
        if pending is not None:
            return pending
        history = client.records(args.job)
        if history["snapshot_seq"] != args.expected_seq:
            raise Refusal("sequence_conflict")
        begin = next((r for r in history["records"] if r["seq"] == args.begin_seq and r["kind"] == "import_begin"), None)
        if begin is None:
            raise Refusal("import_unsealed")
        manifest = [dict(seq=r["seq"], source_locator=r["payload"]["source_locator"],
                         source_sha256=r["payload"]["source_sha256"])
                    for r in history["records"] if r["kind"] == "import" and r["seq"] > args.begin_seq]
        payload = dict(begin_seq=args.begin_seq, expected_import_count=len(manifest),
                       manifest_sha256=digest(manifest), reason_code=args.reason_code)
    else:
        payload = read_request_stdin()
        if args.command == "assign" and (payload.get("role") not in ("tester", "reviewer", "counsel") or payload.get("review_of") is None):
            raise Refusal("invalid_request")
    return client.append(args.job, dict(kind=kind, expected_seq=args.expected_seq,
                                       claim_seq=args.claim_seq, payload=payload))


def typed_completion_cli(argv):
    parser = Parser(prog="wrk o3", allow_abbrev=False)
    parser.add_argument("kind", choices=("completed", "joined"))
    parser.add_argument("job")
    parser.add_argument("--file", required=True)
    parser.add_argument("--head")
    parser.add_argument("--pr")
    parser.add_argument("--waiver-grant", type=positive_seq_arg)
    args = parser.parse_args(argv)
    if args.kind == "joined" and (not args.head or not args.pr):
        raise Refusal("cli_usage")
    client = Client()
    unfinished = client.unfinished(args.job, args.kind)
    if unfinished:
        return client.append(args.job, resume=unfinished)
    current = client.job(args.job)
    s = current["summary"]
    fields = {}
    if args.kind == "joined":
        fields = dict(head=(args.head or "").lower(), pr=args.pr, waiver_grant_seq=args.waiver_grant)
    elif args.head is not None or args.pr is not None or args.waiver_grant is not None:
        raise Refusal("cli_usage")
    return client.evidence(args.job, args.kind, args.file, s["snapshot_seq"], s["claim_seq"], **fields)


def spawn_cli(argv):
    parser = Parser(prog="wrk o3 spawn-check", allow_abbrev=False)
    parser.add_argument("job")
    parser.add_argument("--repo")
    parser.add_argument("--role", required=True, choices=("builder", "worker", "tester", "reviewer", "counsel"))
    parser.add_argument("--tier", required=True)
    parser.add_argument("--task", type=int)
    parser.add_argument("--owner")
    parser.add_argument("--parent")
    parser.add_argument("--parent-job")
    parser.add_argument("--head")
    parser.add_argument("--extension-grant", type=int)
    parser.add_argument("--repeat-grant", type=int)
    parser.add_argument("--takeover-from")
    args = parser.parse_args(argv)
    client = Client()
    result = client.spawn_check(args.job, args.role, args.tier, task=args.task,
                                owner=args.owner, parent=args.parent, subject=args.parent_job,
                                head=(args.head or "").lower() or None, extension=args.extension_grant,
                                repeat=args.repeat_grant, mode=records_mode(client.resolver), predecessor=args.takeover_from, repo=args.repo)
    if result is None:
        return LEGACY_ROUTE
    return "%d\t%s\t%s\t%s" % (result["task_id"], result["owner_lane"], result["parent_lane"],
                                  "inherited" if result["inherited"] else "already_linked")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv in (["--help"], ["-h"], []):
        sys.stdout.write("""Usage: wrk o3 capabilities | job JOB | content JOB SEQ
       wrk o3 records JOB [--after-seq N] [--snapshot-seq S] [--limit L]
       wrk o3 completed JOB --file REPORT
       wrk o3 joined JOB --file REPORT --head SHA --pr HTTPS_URL [--waiver-grant SEQ]
       wrk o3 central claim|activate|assign|import-begin JOB
           --role director-1|operator-desk --expected-seq N --claim-seq N
           (exact Input_KIND JSON on stdin)
       wrk o3 central import JOB --role ROLE --expected-seq N --claim-seq N
           --file EVENT --source-locator LOCATOR --legacy-kind KIND
           [--original-actor ID] [--original-at TIME]
       wrk o3 central import-seal JOB --role ROLE --expected-seq N --claim-seq N
           --begin-seq SEQ [--reason-code CODE]
       wrk o3 append JOB [--resume LOCAL_UUID] (exact Request JSON on stdin)

Central commands use only the fixed account-home hk-director-1 or
hk-operator-desk wrapper. Import seal hashes all server import records in
the fixed snapshot; it never treats local event files as authority.
Records prints one cursor page; follow snapshot_seq and next_after_seq.
Raw append requires a receipt_required job and a kind without a C1 local
projection. Rounds and completed/joined must use their typed commands.
Completed/joined are typed adapter operations; C2 wires the main done/joined
commands and delegated consumers. These operations do no local cleanup.
""")
        return 0
    if argv and argv[0] == "spawn-check":
        value = spawn_cli(argv[1:])
        if value == LEGACY_ROUTE:
            return LEGACY_ROUTE
        sys.stdout.write(value + "\n")
        return 0
    if argv and argv[0] == "round":
        client = Client()
        value = round_cli(client, argv[1:], records_mode(client.resolver))
        if value == LEGACY_ROUTE:
            return LEGACY_ROUTE
        sys.stdout.write(value + "\n")
        return 0
    if argv and argv[0] == "central":
        value = central_cli(argv[1:])
        sys.stdout.buffer.write(canonical(value) + b"\n")
        return 0
    if argv and argv[0] in ("completed", "joined"):
        value = typed_completion_cli(argv)
        sys.stdout.buffer.write(canonical(value) + b"\n")
        return 0
    parser = Parser(description=__doc__, allow_abbrev=False)
    parser.add_argument("operation", choices=("capabilities", "job", "records", "content", "append"))
    parser.add_argument("job", nargs="?")
    parser.add_argument("seq", nargs="?", type=int)
    parser.add_argument("--resume")
    parser.add_argument("--limit", type=cursor_arg)
    parser.add_argument("--after-seq", type=cursor_arg)
    parser.add_argument("--snapshot-seq", type=cursor_arg)
    args = parser.parse_args(argv)
    client = Client()
    if args.operation != "append" and not sys.stdin.isatty() and sys.stdin.buffer.read(1):
        raise Refusal("invalid_request")
    if args.operation != "content" and args.seq is not None:
        raise Refusal("cli_usage")
    if args.operation != "append" and args.resume is not None:
        raise Refusal("cli_usage")
    if args.operation != "records" and any(value is not None for value in (args.limit, args.after_seq, args.snapshot_seq)):
        raise Refusal("cli_usage")
    if args.operation == "capabilities":
        if args.job is not None:
            raise Refusal("cli_usage")
        value = client.capabilities()
    else:
        job_name(args.job)
        if args.operation == "job":
            value = client.job(args.job)
        elif args.operation == "records":
            value = client.record_page(args.job, limit=args.limit, after_seq=args.after_seq, snapshot_seq=args.snapshot_seq)
        elif args.operation == "content":
            value = client.content(args.job, args.seq)
        else:
            value = client.append_public(args.job, read_request_stdin()
                                         if args.resume is None else None, resume=args.resume)
    sys.stdout.buffer.write(canonical(value) + b"\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EndedHistoryFault as error:
        sys.stderr.write(error.line())
        raise SystemExit(error.exit)
    except ModeRefusal as error:
        sys.stderr.write(error.line())
        raise SystemExit(error.exit)
    except TypedCommandRequired as error:
        sys.stderr.write(error.line())
        raise SystemExit(error.exit)
    except LocalRefusal as error:
        sys.stderr.write("wrk: " + error.message + "\n")
        raise SystemExit(error.exit)
    except ProjectionPending:
        sys.stderr.write("wrk o3: projection_pending\n")
        raise SystemExit(75)
    except Refusal as error:
        detail = (" stage=%s errno=%s" % (error.io_stage, error.os_errno)
                  if hasattr(error, "io_stage") else "")
        sys.stderr.write("wrk o3: " + error.code + detail + "\n")
        raise SystemExit(error.exit)
    except Exception:
        sys.stderr.write("wrk o3: protocol_invalid\n")
        raise SystemExit(75)
