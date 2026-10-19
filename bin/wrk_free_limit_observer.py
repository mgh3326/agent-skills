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


FREE_RUNGS = {
    "devin-swe2",
    "devin-swe2-medium",
    "devin-swe2-max",
    "builder-devin",
    "builder-devin-medium",
    "builder-devin-max",
}
RATE_LIMIT = re.compile(r"Reached\s+free\s+model\s+rate\s+limit", re.IGNORECASE)
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ABSOLUTE = re.compile(r"\bat\s+(\d{1,2}):(\d{2})\s+UTC\b", re.IGNORECASE)
RELATIVE = re.compile(r"\breset\s+in\s+(\d+)\s+minutes?\b", re.IGNORECASE)


def aware_utc(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def iso_utc(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_rate_limit(transcript: str, observed: dt.datetime) -> dict[str, object] | None:
    """Parse one rate-limit notice from the bounded pane transcript."""
    normalized = " ".join(ANSI.sub(" ", transcript).split())
    matches = list(RATE_LIMIT.finditer(normalized))
    if not matches:
        return None

    match = matches[-1]
    # Keep the identity local to the rate-limit notice. Later pane output and
    # unrelated transcript lines must not change a relative fallback reset.
    excerpt = normalized[match.start() : match.start() + 320].strip()
    signature = hashlib.sha256(excerpt.casefold().encode("utf-8")).hexdigest()
    observed = observed.astimezone(dt.timezone.utc)
    details = normalized[match.end() : match.start() + 320]

    absolute = ABSOLUTE.search(details)
    if absolute:
        hour, minute = (int(absolute.group(1)), int(absolute.group(2)))
        if hour < 24 and minute < 60:
            reset = observed.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if reset <= observed:
                reset += dt.timedelta(days=1)
            # A wall-clock reset is at most one day away after the rollover.
            reset = min(reset, observed + dt.timedelta(hours=24))
            return {
                "signature": signature,
                "reset": iso_utc(reset),
                "observed": iso_utc(observed),
                "unparsed": False,
            }

    relative = RELATIVE.search(details)
    if relative:
        minutes = min(int(relative.group(1)), 24 * 60)
        reset = observed + dt.timedelta(minutes=minutes)
        return {
            "signature": signature,
            "reset": iso_utc(reset),
            "observed": iso_utc(observed),
            "unparsed": False,
        }

    reset = observed + dt.timedelta(hours=1)
    return {
        "signature": signature,
        "reset": iso_utc(reset),
        "observed": iso_utc(observed),
        "unparsed": True,
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
    if args.pane_kind != "devin" or args.rung not in FREE_RUNGS:
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
            events.append(record)
            atomic_json(state_path, {"version": 1, "events": events})

            scopefuel = args.scopefuel or shutil.which("scopefuel")
            if not scopefuel:
                record["result"] = "missing-cli"
                atomic_json(state_path, {"version": 1, "events": events})
                return f"observer-failed-missing-cli-reset={event['reset']}"
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
            return f"observer-{outcome}-reset={event['reset']}"
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
