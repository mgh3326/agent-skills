#!/usr/bin/env python3
"""Passively record Devin free-model rate-limit text once per job/reset."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from wrk_pane_models import expected_label, latest_model_line, model_tokens, parse_model_line


DEVIN_RUNGS = {
    "devin-swe2",
    "devin-swe2-medium",
    "devin-swe2-max",
    "builder-devin",
    "builder-devin-medium",
    "builder-devin-max",
    "devin-glm52",
    "devin-swe17",
    "devin-ds41",
    "devin-ds41-max",
    "builder-ds41",
    "builder-ds41-max",
    "devin-fusion-opus55",
    "devin-fusion-sonnet55",
    "devin-fusion-sol61",
    "devin-fusion-sol61-xhigh",
    "devin-argon",
    "devin-argon-medium",
    "devin-argon-low",
}
RATE_LIMIT = re.compile(r"^Reached\s+free\s+model\s+rate\s+limit", re.IGNORECASE)
BANNER = re.compile(r"^[ \t]*\u25b2[ \t]+Something went wrong[ \t]*$", re.IGNORECASE)
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ABSOLUTE = re.compile(r"\bat\s+(\d(?:\s*\d)?)\s*:\s*(\d(?:\s*\d)?)\s+UTC\b", re.IGNORECASE)
RELATIVE = re.compile(r"\breset\s+in\s+(\d+)\s+minutes?\b", re.IGNORECASE)
# Devin free-window notices seen in the field advertise a reset within about
# an hour of the notice, so a genuine reset is never more than 24h - GRACE
# ahead of the observation: a stated UTC reset that far out cannot be the
# window the notice meant. Either side of UTC midnight the most recent
# occurrence of the stated HH:MM is the candidate that already passed, and
# when it lies within GRACE behind the observation the window simply ended
# before the pane was read (slept host, late sentinel, notice printed with
# under a minute left) and no hold is recorded. Only a stated reset further
# back than GRACE rolls to the next day. Six hours is far above the ~1h
# notice horizon and well under the 24h rollover cap.
GRACE = dt.timedelta(hours=6)
# Relative and absolute spellings of the same reset are allowed to differ by
# rounding; beyond this they disagree and the earlier reset wins.
DISAGREE = dt.timedelta(minutes=5)


def aware_utc(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def iso_utc(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_rate_limit(transcript: str, observed: dt.datetime) -> dict[str, object] | None:
    """Parse a reset only from an indented rate-limit body after Devin's banner."""
    cleaned = ANSI.sub("", transcript).replace("\r\n", "\n").replace("\r", "\n")
    lines = cleaned.splitlines()
    blocks: list[str] = []
    for index, line in enumerate(lines):
        if not BANNER.fullmatch(line):
            continue
        body: list[str] = []
        for following in lines[index + 1 :]:
            if not following.strip() or not re.match(r"^[ \t]{3,}\S", following):
                break
            body.append(following.strip())
        normalized = " ".join(" ".join(body).split())
        match = RATE_LIMIT.match(normalized)
        if match is not None:
            blocks.append(normalized)
    if not blocks:
        return None

    notice = blocks[-1]
    match = RATE_LIMIT.match(notice)
    assert match is not None
    observed = observed.astimezone(dt.timezone.utc)
    details = notice[match.end() : match.end() + 320]

    absolute = ABSOLUTE.search(details)
    absolute_reset: dt.datetime | None = None
    absolute_expired = False
    absolute_signature = ""
    if absolute:
        hour, minute = (int(re.sub(r"\s+", "", part)) for part in absolute.groups())
        if hour < 24 and minute < 60:
            stated = observed.replace(hour=hour, minute=minute, second=0, microsecond=0)
            previous = stated if stated <= observed else stated - dt.timedelta(days=1)
            if observed - previous <= GRACE:
                # The stated window already ended; the notice was read late.
                absolute_reset = previous
                absolute_expired = True
            elif stated > observed:
                absolute_reset = stated
            else:
                absolute_reset = stated + dt.timedelta(days=1)
            # A wall-clock reset is at most one day away after the rollover.
            absolute_reset = min(absolute_reset, observed + dt.timedelta(hours=24))
            absolute_signature = hashlib.sha256(
                f"free-limit|utc|{hour:02d}:{minute:02d}".encode()
            ).hexdigest()

    relative = RELATIVE.search(details)
    relative_reset: dt.datetime | None = None
    relative_signature = ""
    if relative:
        raw_minutes = int(relative.group(1))
        relative_reset = observed + dt.timedelta(minutes=min(raw_minutes, 24 * 60))
        relative_signature = hashlib.sha256(
            f"free-limit|relative|{raw_minutes}".encode()
        ).hexdigest()

    disagreement = ""
    if absolute_reset is not None and relative_reset is not None:
        if abs(absolute_reset - relative_reset) > DISAGREE:
            disagreement = (
                f"absolute:{iso_utc(absolute_reset)};relative:{iso_utc(relative_reset)}"
            )
            use_absolute = absolute_reset <= relative_reset
        else:
            use_absolute = True
    else:
        use_absolute = relative_reset is None

    if absolute_reset is not None and use_absolute:
        return {
            "signature": absolute_signature,
            "reset": iso_utc(absolute_reset),
            "observed": iso_utc(observed),
            "unparsed": False,
            "expired": absolute_expired,
            "disagreement": disagreement,
        }
    if relative_reset is not None:
        return {
            "signature": relative_signature,
            "reset": iso_utc(relative_reset),
            "observed": iso_utc(observed),
            "unparsed": False,
            "expired": False,
            "disagreement": disagreement,
        }

    reset = observed + dt.timedelta(hours=1)
    signature = hashlib.sha256(b"free-limit|unparsed").hexdigest()
    return {
        "signature": signature,
        "reset": iso_utc(reset),
        "observed": iso_utc(observed),
        "unparsed": True,
        "expired": False,
        "disagreement": "",
    }


def atomic_json(path: Path, document: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        os.chmod(path, 0o600)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def load_events(path: Path) -> list[dict[str, object]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        events = document.get("events") if isinstance(document, dict) else None
        if isinstance(events, list):
            return [event for event in events if isinstance(event, dict)]
    except (OSError, UnicodeError, json.JSONDecodeError):
        pass
    return []


def observe(args: argparse.Namespace, transcript: str) -> str:
    if args.pane_kind != "devin" or args.rung not in DEVIN_RUNGS:
        return ""
    try:
        observed = aware_utc(args.observed) if args.observed else dt.datetime.now(dt.timezone.utc)
    except (ValueError, OverflowError):
        return "observer-failed-invalid-time"
    event = parse_rate_limit(transcript, observed)
    if event is None:
        return ""

    state_path = Path(args.state)
    lock_path = state_path.with_name(state_path.name + ".lock")
    state_path.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        with os.fdopen(lock_fd, "r+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            events = load_events(state_path)
            matching = next((item for item in events if item.get("signature") == event["signature"]), None)
            if matching is not None:
                return ""

            suffix = f" disagreement={event['disagreement']}" if event["disagreement"] else ""

            if event["expired"]:
                # The stated reset already passed: record no hold, keep the
                # signature so later polls of the same pane do not re-trigger.
                record = {
                    "signature": event["signature"],
                    "reset": event["reset"],
                    "observed": event["observed"],
                    "unparsed": event["unparsed"],
                    "rung": args.rung,
                    "result": "expired",
                }
                if event["disagreement"]:
                    record["disagreement"] = event["disagreement"]
                events.append(record)
                atomic_json(state_path, {"version": 1, "events": events})
                return f"observer-expired-reset={event['reset']}{suffix}"

            # This state belongs to one job. The rate-limit phrase is required
            # before a reset can reach this branch, so unrelated pane messages
            # cannot be mistaken for a previously observed window.
            same_reset = next((item for item in events if item.get("reset") == event["reset"]), None)
            if same_reset is not None:
                events.append(
                    {
                        "signature": event["signature"],
                        "reset": same_reset["reset"],
                        "observed": same_reset.get("observed", event["observed"]),
                        "unparsed": same_reset.get("unparsed", event["unparsed"]),
                        "rung": args.rung,
                        "result": "duplicate-reset",
                    }
                )
                atomic_json(state_path, {"version": 1, "events": events})
                return ""

            record = {
                "signature": event["signature"],
                "reset": event["reset"],
                "observed": event["observed"],
                "unparsed": event["unparsed"],
                "rung": args.rung,
                "result": "pending",
            }
            if event["disagreement"]:
                record["disagreement"] = event["disagreement"]
            events.append(record)
            atomic_json(state_path, {"version": 1, "events": events})

            scopefuel = args.scopefuel or shutil.which("scopefuel")
            if not scopefuel:
                record["result"] = "missing-cli"
                atomic_json(state_path, {"version": 1, "events": events})
                return f"observer-failed-missing-cli-reset={event['reset']}{suffix}"
            command = [
                scopefuel,
                "observe",
                "devin-free-limit",
                "--reset",
                str(event["reset"]),
                "--observed",
                str(event["observed"]),
                "--rung",
                args.rung,
                "--source",
                f"job:{args.job}",
            ]
            if event["unparsed"]:
                command.append("--unparsed")
            try:
                result = subprocess.run(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                    check=False,
                )
                rc = result.returncode
            except (OSError, subprocess.TimeoutExpired):
                rc = 127
            record["result"] = f"rc-{rc}"
            atomic_json(state_path, {"version": 1, "events": events})
            outcome = "ok" if rc == 0 else f"failed-rc-{rc}"
            return f"observer-{outcome}-reset={event['reset']}{suffix}"
    except OSError:
        return "observer-failed-state-io"


# Two poll intervals (30s each) plus one minute for scheduling/render latency.
# This is deliberately time based, so a delayed poll cannot hide a stale pane.
STALL_MARGIN = dt.timedelta(minutes=2)
OBSERVER_KINDS = {"job.model_observed", "quota_pool.drift", "job.stalled_free_limit"}


def job_events(jobdir: Path) -> list[dict]:
    rows = []
    for path in (jobdir / "events").glob("*.json"):
        try:
            doc = json.loads(path.read_text())
            if isinstance(doc, dict):
                stamp = doc.get("created_at", doc.get("at", ""))
                rows.append((stamp if isinstance(stamp, str) else "", path.stat().st_mtime_ns, path.name, doc))
        except (OSError, ValueError):
            continue
    return [row[-1] for row in sorted(rows)]


def payload(doc: dict) -> dict:
    return doc.get("payload") if isinstance(doc.get("payload"), dict) else doc


def commit_event(jobdir: Path, job: str, kind: str, key: str, data: dict, now: str) -> None:
    # An independent namespace avoids either arbiter or wrk's numeric writer.
    # Deterministic keys make retries after a state-write failure idempotent.
    path = jobdir / "events" / f"observer-{key}-{kind}.json"
    if not path.exists():
        atomic_json(path, dict(job_id=job, kind=kind, created_at=now, payload=data))


def billing_account_tag() -> str | None:
    # Read only scopefuel's credential-free policy field. Never open an agent
    # configuration or fall back to the host's codex account/snapshot.
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "scopefuel/config.toml"
    try:
        text = config.read_text(encoding="utf-8")
        try:
            import tomllib
        except ImportError:
            # macOS's system python3 can precede 3.11. Accept only the exact
            # section/key spelling emitted by scopefuel's policy writer there;
            # a missing, duplicate or noncanonical declaration stays untagged.
            sections = list(re.finditer(r"(?m)^\s*\[pools\.codex\][ \t]*(?:#[^\n]*)?$", text))
            if len(sections) != 1:
                return None
            body = re.split(r"(?m)^\s*\[", text[sections[0].end():], maxsplit=1)[0]
            declarations = re.findall(r"(?m)^[ \t]*fusion_billing_fp[ \t]*=[ \t]*(.*)$", body)
            if len(declarations) != 1:
                return None
            match = re.fullmatch(r"([\"'])([0-9a-f]{16})\1[ \t]*(?:#[^\n]*)?", declarations[0])
            fp = match.group(2) if match else None
        else:
            fp = tomllib.loads(text).get("pools", {}).get("codex", {}).get("fusion_billing_fp")
        return fp[:8] if isinstance(fp, str) and re.fullmatch(r"[0-9a-f]{16}", fp) else None
    except (OSError, ValueError, AttributeError):
        return None


def active_protocol_error(transcript: str) -> str | None:
    lines = ANSI.sub("", transcript).splitlines()
    for index in range(len(lines) - 1, -1, -1):
        if not BANNER.fullmatch(lines[index]):
            continue
        body = []
        trailing = []
        in_body = True
        for line in lines[index + 1:]:
            if in_body and re.match(r"^[ \t]{3,}\S", line):
                body.append(line.strip())
            else:
                in_body = False
                if line.strip():
                    trailing.append(line)
        # A retained banner above subsequent work is not the last error.
        if any(latest_model_line(line) is None and line.strip() != "? for shortcuts" for line in trailing):
            return None
        text = " ".join(body)
        match = re.match(r"(?:\[|\()?invalid_argument(?:\]|\))?(?=[: \t]|$)", text)
        return "invalid_argument" if match else None
    return None


def emit_stall(args: argparse.Namespace, jobdir: Path, pending: dict) -> bool:
    owner = getattr(args, "owner_lane", "")
    if not owner:
        for doc in reversed(job_events(jobdir)):
            owner = payload(doc).get("owner_lane", "")
            if owner:
                break
    if not owner:
        return False
    command = [os.environ.get("PANEWIRE_BIN", "panewire"), "emit", "--kind", "lane.event",
               "--lane", owner, "--event-id", f"stall-{args.job}-{pending['signature']}",
               "--text", f"job.stalled_free_limit job={args.job} error_class={pending['error_class']} reset={pending['reset']}",
               "--inbox-root", str(jobdir.parent.parent)]
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, timeout=5, check=False)
        return result.returncode == 0 or b"duplicate event_id" in result.stderr
    except (OSError, subprocess.TimeoutExpired):
        return False


def observe_pane(args: argparse.Namespace, transcript: str) -> None:
    if args.pane_kind != "devin":
        return
    observed = aware_utc(args.observed) if args.observed else dt.datetime.now(dt.timezone.utc)
    now = iso_utc(observed)
    jobdir = Path(args.state).parent
    jobdir.mkdir(parents=True, exist_ok=True)
    state_path = jobdir / "pane-observer.json"
    with (jobdir / ".pane-observer.lock").open("a+") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            state = json.loads(state_path.read_text())
        except (OSError, ValueError):
            state = {}
        if not isinstance(state, dict):
            state = {}
        events = job_events(jobdir)
        progress_events = [doc for doc in events if doc.get("kind") not in OBSERVER_KINDS]
        event_digest = hashlib.sha256(json.dumps(progress_events, sort_keys=True).encode()).hexdigest()
        content_digest = hashlib.sha256(transcript.encode()).hexdigest()
        progressed = bool(state) and (state.get("content") != content_digest or state.get("events") != event_digest)
        if progressed or not state:
            state["last_progress"] = now
        state.update(content=content_digest, events=event_digest)

        raw = latest_model_line("\n".join(transcript.splitlines()[-5:]))
        previous = next((doc for doc in reversed(events) if doc.get("kind") == "job.model_observed"), None)
        if raw is not None and (previous is None or payload(previous).get("raw_line") != raw):
            model = parse_model_line(raw)
            expected = expected_label(args.rung)
            model.update(spawned_profile=args.rung, expected_label=expected,
                         drift=expected is None or model_tokens(raw) != model_tokens(expected), time=now)
            tag = billing_account_tag()
            for part in model["parts"]:
                if part["account"] == "devin-linked":
                    part["account_tag"] = tag
            key = hashlib.sha256(json.dumps([previous, raw], sort_keys=True).encode()).hexdigest()
            commit_event(jobdir, args.job, "job.model_observed", key, model, now)
            quota = next((payload(doc) for doc in reversed(events) if doc.get("kind") == "quota_pool.record"), {})
            from_pool = quota.get("pool") or quota.get("resource")
            # With no quota record, provenance still names the observed pools;
            # absence of a recorded source pool is never guessed from the host.
            if model["drift"] and model["attributed"] and from_pool and any(pool != from_pool for pool in model["pools"]):
                commit_event(jobdir, args.job, "quota_pool.drift", key,
                             dict(from_pool=from_pool, to_pool=model["pools"], parts=model["parts"],
                                  spawned_profile=args.rung, time=now, lease_changed=False), now)

        notice = parse_rate_limit(transcript, observed)
        protocol = active_protocol_error(transcript)
        if protocol:
            notice = dict(signature=hashlib.sha256((protocol + transcript).encode()).hexdigest(),
                          observed=now, reset=now, error_class=protocol)
        elif notice:
            notice["error_class"] = "free_model_rate_limit"
        pending = state.get("pending")
        signatures = state.setdefault("notices", [])
        if notice and notice["signature"] not in signatures:
            signatures.append(notice["signature"])
            pending = {key: notice[key] for key in ("signature", "observed", "reset", "error_class")}
            pending["last_progress"] = state["last_progress"]
            state["pending"] = pending
        elif pending and progressed and not pending.get("flagged"):
            # Work after the notice clears this candidate; a retained notice
            # must not re-arm itself on a later quiet poll.
            state.pop("pending", None)
            pending = None
        if pending and not pending.get("flagged") and not progressed:
            threshold = max(aware_utc(pending["reset"]), aware_utc(state["last_progress"])) + STALL_MARGIN
            if observed >= threshold:
                commit_event(jobdir, args.job, "job.stalled_free_limit", pending["signature"],
                             dict(notice_time=pending["observed"], reset=pending["reset"],
                                  last_progress_time=state["last_progress"], error_class=pending["error_class"], time=now), now)
                pending["flagged"] = True
        if pending and pending.get("flagged") and not pending.get("lane_sent"):
            pending["lane_sent"] = emit_stall(args, jobdir, pending)
        atomic_json(state_path, state)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    parser.add_argument("--rung", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--scopefuel", default="")
    parser.add_argument("--pane-kind", required=True)
    parser.add_argument("--observed", default="")
    parser.add_argument("--owner-lane", default="")
    args = parser.parse_args(argv)
    try:
        transcript = sys.stdin.read()
        pane_failure = ""
        try:
            observe_pane(args, transcript)
        except (OSError, UnicodeError, ValueError, TypeError, AttributeError):
            # A damaged audit state must not disable the existing quota hold.
            pane_failure = "pane-observer-failed-state-io"
        output = " ".join(part for part in (observe(args, transcript), pane_failure) if part)
    except (OSError, UnicodeError, ValueError):
        output = "observer-failed-input"
    if output:
        print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
