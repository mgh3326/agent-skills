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
# an hour of the notice, so a stated UTC reset already this far behind the
# observation cannot be the window that notice meant: the window simply
# ended before the pane was read (slept host, late sentinel, notice printed
# with under a minute left) and no hold should be recorded. A stated reset
# further back than GRACE must instead belong to the next day. Six hours is
# far above the ~1h notice horizon and well under the 24h rollover cap.
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
            if stated > observed:
                absolute_reset = stated
            elif observed - stated <= GRACE:
                # The stated window already ended; the notice was read late.
                absolute_reset = stated
                absolute_expired = True
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    parser.add_argument("--rung", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--scopefuel", default="")
    parser.add_argument("--pane-kind", required=True)
    parser.add_argument("--observed", default="")
    args = parser.parse_args(argv)
    try:
        output = observe(args, sys.stdin.read())
    except (OSError, UnicodeError):
        output = "observer-failed-input"
    if output:
        print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
