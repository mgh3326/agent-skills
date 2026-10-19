#!/usr/bin/env python3
"""Focused tests for the passive per-job Devin free-window observer."""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
import wrk_free_limit_observer as observer  # noqa: E402


def when(value: str) -> dt.datetime:
    return observer.aware_utc(value)


def provider_notice(message: str) -> str:
    body = "\n".join("   " + line for line in message.splitlines())
    return f"\n ▲ Something went wrong\n{body}\n"


class FreeLimitObserverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="wrk-free-window-")
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.dirs = {
            "HOME": str(self.home),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "PATH": os.defpath,
            "LC_ALL": "C.UTF-8",
        }
        for directory in self.dirs.values():
            if directory.startswith(str(self.root)):
                Path(directory).mkdir(parents=True, exist_ok=True)
        self.call_log = self.root / "scopefuel-calls.jsonl"
        self.scopefuel = self.root / "scopefuel-stub"
        self.scopefuel.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "with open(os.environ['STUB_SCOPEFUEL_LOG'], 'a', encoding='utf-8') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "raise SystemExit(int(os.environ.get('STUB_SCOPEFUEL_RC', '0')))\n",
            encoding="utf-8",
        )
        self.scopefuel.chmod(0o700)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def call_env(self, **extra: str) -> dict[str, str]:
        return {
            **self.dirs,
            "STUB_SCOPEFUEL_LOG": str(self.call_log),
            **extra,
        }

    def run_helper(
        self,
        text: str,
        observed: str,
        *,
        job: str = "job-1690",
        rung: str = "devin-swe2",
        pane_kind: str = "devin",
        scopefuel: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        state = self.root / job / "free-limit-observer.json"
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "bin" / "wrk_free_limit_observer.py"),
                "--pane-kind",
                pane_kind,
                "--job",
                job,
                "--rung",
                rung,
                "--state",
                str(state),
                "--scopefuel",
                str(scopefuel or self.scopefuel),
                "--observed",
                observed,
            ],
            input=text,
            text=True,
            capture_output=True,
            timeout=10,
            env=self.call_env(),
            check=False,
        )

    def calls(self) -> list[list[str]]:
        if not self.call_log.exists():
            return []
        return [json.loads(line) for line in self.call_log.read_text(encoding="utf-8").splitlines()]

    def test_exact_hk_message_prefers_absolute_utc(self) -> None:
        text = provider_notice(
            "Reached free model rate limit. Upgrade to Max for higher limits, or switch to a different\n"
            "model. Your limit will reset in 50 minutes (at 08:01 UTC). (trace ID: sample). Send a message to retry"
        )
        event = observer.parse_rate_limit(text, when("2026-10-19T07:11:00Z"))
        self.assertEqual(event["reset"], "2026-10-19T08:01:00Z")
        self.assertEqual(event["observed"], "2026-10-19T07:11:00Z")
        self.assertFalse(event["unparsed"])

    def test_absolute_only_and_relative_only(self) -> None:
        absolute = observer.parse_rate_limit(
            provider_notice("Reached free model rate limit (at 08:01 UTC)"),
            when("2026-10-19T07:11:00Z"),
        )
        relative = observer.parse_rate_limit(
            provider_notice("Reached free model rate limit; reset in 50 minutes"),
            when("2026-10-19T07:11:00Z"),
        )
        self.assertEqual(absolute["reset"], "2026-10-19T08:01:00Z")
        self.assertEqual(relative["reset"], "2026-10-19T08:01:00Z")

    def test_absolute_rolls_to_next_day_and_relative_is_capped_at_24h(self) -> None:
        observed = when("2026-10-19T23:30:00Z")
        absolute = observer.parse_rate_limit(
            provider_notice("Reached free model rate limit at 08:01 UTC"), observed
        )
        relative = observer.parse_rate_limit(
            provider_notice("Reached free model rate limit reset in 9999 minutes"), observed
        )
        self.assertEqual(absolute["reset"], "2026-10-20T08:01:00Z")
        self.assertEqual(relative["reset"], "2026-10-20T23:30:00Z")
        same_minute = observer.parse_rate_limit(
            provider_notice("Reached free model rate limit at 08:01 UTC"),
            when("2026-10-19T08:01:00Z"),
        )
        self.assertEqual(same_minute["reset"], "2026-10-20T08:01:00Z")

    def test_wrapped_phrase_and_time_parse(self) -> None:
        text = provider_notice("Reached free model rate\nlimit; reset in 50 minutes (at 08:01\nUTC)")
        event = observer.parse_rate_limit(text, when("2026-10-19T07:11:00Z"))
        self.assertEqual(event["reset"], "2026-10-19T08:01:00Z")

    def test_absolute_time_wrapped_after_colon_is_preferred_in_kst_observation(self) -> None:
        text = provider_notice("Reached free model rate limit; reset in 50 minutes (at 08:\n01 UTC)")
        event = observer.parse_rate_limit(text, when("2026-10-19T16:10:00+09:00"))
        self.assertEqual(event["observed"], "2026-10-19T07:10:00Z")
        self.assertEqual(event["reset"], "2026-10-19T08:01:00Z")

    def test_garbled_notice_uses_one_hour_and_unparsed_flag(self) -> None:
        result = self.run_helper(
            provider_notice("Reached free model rate limit, reset information unavailable"),
            "2026-10-19T07:11:00Z",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("observer-ok-reset=2026-10-19T08:11:00Z", result.stdout)
        args = self.calls()[0]
        self.assertEqual(args[-1], "--unparsed")
        self.assertEqual(args[args.index("--source") + 1], "job:job-1690")

    def test_repeated_garbled_notice_does_not_slide_cooldown(self) -> None:
        text = provider_notice("Reached free model rate limit, reset details were garbled")
        first = self.run_helper(text, "2026-10-19T07:11:00Z")
        second = self.run_helper(text, "2026-10-19T07:35:00Z")
        self.assertIn("reset=2026-10-19T08:11:00Z", first.stdout)
        self.assertEqual(second.stdout, "")
        self.assertEqual(len(self.calls()), 1)

    def test_relative_repeat_does_not_slide_reset_or_call_again(self) -> None:
        text = provider_notice("Reached free model rate limit; reset in 50 minutes")
        first = self.run_helper(text, "2026-10-19T07:11:00Z")
        second = self.run_helper(text, "2026-10-19T07:20:00Z")
        self.assertIn("reset=2026-10-19T08:01:00Z", first.stdout)
        self.assertEqual(second.stdout, "")
        self.assertEqual(len(self.calls()), 1)
        state = json.loads((self.root / "job-1690" / "free-limit-observer.json").read_text())
        self.assertEqual(state["events"][0]["reset"], "2026-10-19T08:01:00Z")

    def test_relative_notice_dedupe_ignores_changed_trailing_pane_text(self) -> None:
        first = self.run_helper(
            provider_notice("Reached free model rate limit; reset in 50 minutes") + "Working A\n",
            "2026-10-19T08:00:00Z",
        )
        second = self.run_helper(
            provider_notice("Reached free model rate limit; reset in 50 minutes") + "Working B\n",
            "2026-10-19T08:02:00Z",
        )
        self.assertIn("reset=2026-10-19T08:50:00Z", first.stdout)
        self.assertEqual(second.stdout, "")
        self.assertEqual(len(self.calls()), 1)

    def test_non_devin_pane_never_persists_or_calls_even_with_same_text(self) -> None:
        for pane_kind in ("claude", "codex"):
            result = self.run_helper(
                "Reached free model rate limit; reset in 50 minutes",
                "2026-10-19T07:11:00Z",
                job=f"{pane_kind}-job",
                pane_kind=pane_kind,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
        self.assertEqual(self.calls(), [])
        for pane_kind in ("claude", "codex"):
            self.assertFalse((self.root / f"{pane_kind}-job" / "free-limit-observer.json").exists())

    def test_paid_devin_kind_records_the_actual_rung(self) -> None:
        result = self.run_helper(
            provider_notice("Reached free model rate limit; reset in 50 minutes"),
            "2026-10-19T07:11:00Z",
            rung="devin-ds41",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("observer-ok-reset=2026-10-19T08:01:00Z", result.stdout)
        args = self.calls()[0]
        self.assertEqual(args[args.index("--rung") + 1], "devin-ds41")

    def test_old_scopefuel_command_failure_is_soft_and_not_retried(self) -> None:
        text = provider_notice("Reached free model rate limit; reset in 50 minutes")
        old_cli = self.root / "old-scopefuel"
        old_cli.write_text(
            "#!" + sys.executable + "\nimport sys\nsys.exit(2)\n", encoding="utf-8"
        )
        old_cli.chmod(0o700)
        rc1 = self.run_helper(
            text,
            "2026-10-19T07:11:00Z",
            job="old-cli-job",
            scopefuel=old_cli,
        )
        rc2 = self.run_helper(
            text,
            "2026-10-19T07:12:00Z",
            job="old-cli-job",
            scopefuel=old_cli,
        )
        self.assertEqual(rc1.returncode, 0)
        self.assertIn("observer-failed-rc-2", rc1.stdout)
        self.assertEqual(rc2.stdout, "")

    def test_concurrent_same_job_reset_calls_scopefuel_once(self) -> None:
        text = provider_notice("Reached free model rate limit (at 08:01 UTC)")
        state = self.root / "concurrent-job" / "free-limit-observer.json"
        command = [
            sys.executable,
            str(ROOT / "bin" / "wrk_free_limit_observer.py"),
            "--pane-kind",
            "devin",
            "--job",
            "concurrent-job",
            "--rung",
            "devin-swe2-max",
            "--state",
            str(state),
            "--scopefuel",
            str(self.scopefuel),
            "--observed",
            "2026-10-19T07:11:00Z",
        ]
        procs = [
            subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.call_env(),
            )
            for _ in range(4)
        ]
        for proc in procs:
            stdout, stderr = proc.communicate(text, timeout=10)
            self.assertEqual(proc.returncode, 0, stderr)
            self.assertTrue(stdout == "" or "observer-ok" in stdout)
        self.assertEqual(len(self.calls()), 1)
        args = self.calls()[0]
        self.assertEqual(args[:2], ["observe", "devin-free-limit"])
        self.assertEqual(args[args.index("--reset") + 1], "2026-10-19T08:01:00Z")
        self.assertEqual(args[args.index("--observed") + 1], "2026-10-19T07:11:00Z")
        self.assertEqual(args[args.index("--source") + 1], "job:concurrent-job")
        self.assertEqual(args[args.index("--rung") + 1], "devin-swe2-max")

    def run_sentinel(
        self,
        job: str,
        pane_kind: str,
        rung: str,
        *,
        wrk_path: Path | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        pane_log = self.root / f"{job}-herdr.jsonl"
        herdr = self.root / f"{job}-herdr-stub"
        herdr.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['STUB_HERDR_LOG'], 'a', encoding='utf-8') as f:\n"
            "    f.write(json.dumps(args) + '\\n')\n"
            "if args[:2] == ['agent', 'get']:\n"
            "    print(json.dumps({'result': {'agent': {'agent_status': 'idle', 'tab_id': 't1'}}}))\n"
            "elif args[:2] == ['agent', 'read']:\n"
            "    sys.stdout.write(os.environ['STUB_PANE_TEXT'])\n"
            "else:\n"
            "    raise SystemExit(9)\n",
            encoding="utf-8",
        )
        herdr.chmod(0o700)
        env = self.call_env(
            HERDR_BIN=str(herdr),
            SCOPEFUEL_BIN=str(self.scopefuel),
            ARBITER_INBOX_ROOT=str(self.root / "jobs"),
            WRK_COMPLETION_TIMEOUT_S="0",
            WRK_SENTINEL_LOST_GRACE="0",
            WRK_SENTINEL_INTERVAL_S="0",
            STUB_HERDR_LOG=str(pane_log),
            STUB_PANE_TEXT=provider_notice("Reached free model rate limit; reset in 50 minutes"),
        )
        args = [
            str(wrk_path or ROOT / "bin" / "wrk"),
            "sentinel",
            job,
            "worker",
            "test",
            "pane-1",
            "",
            "",
            pane_kind,
            rung,
            str(self.scopefuel),
        ]
        result = subprocess.run(args, text=True, capture_output=True, timeout=15, env=env, check=False)
        return result, pane_log

    def test_sentinel_reads_passively_once_and_skips_non_devin(self) -> None:
        result, herdr_log = self.run_sentinel("devin-job", "devin", "devin-swe2-medium")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        entries = [json.loads(line) for line in herdr_log.read_text(encoding="utf-8").splitlines()]
        reads = [entry for entry in entries if entry[:2] == ["agent", "read"]]
        self.assertEqual(reads, [["agent", "read", "pane-1", "--source", "recent-unwrapped", "--lines", "200"]])
        self.assertTrue(all(entry[:2] in (["agent", "get"], ["agent", "read"]) for entry in entries))
        self.assertTrue(any("observer-ok-reset=" in line for line in (self.root / "jobs/devin-job/completion-sentinel.log").read_text().splitlines()))
        self.assertNotIn("Reached free model rate limit", (self.root / "jobs/devin-job/completion-sentinel.log").read_text())

        before = len(self.calls())
        other_result, other_log = self.run_sentinel("codex-job", "codex", "codex")
        self.assertEqual(other_result.returncode, 0, other_result.stderr)
        after_entries = [json.loads(line) for line in other_log.read_text(encoding="utf-8").splitlines()]
        self.assertFalse(any(entry[:2] == ["agent", "read"] for entry in after_entries))
        self.assertEqual(len(self.calls()), before)
        self.assertFalse((self.root / "jobs/codex-job/free-limit-observer.json").exists())

        claude_result, claude_log = self.run_sentinel("claude-job", "claude", "claude")
        self.assertEqual(claude_result.returncode, 0, claude_result.stderr)
        claude_entries = [json.loads(line) for line in claude_log.read_text(encoding="utf-8").splitlines()]
        self.assertFalse(any(entry[:2] == ["agent", "read"] for entry in claude_entries))
        self.assertEqual(len(self.calls()), before)
        self.assertFalse((self.root / "jobs/claude-job/free-limit-observer.json").exists())

        paid_result, paid_log = self.run_sentinel("paid-devin-job", "devin", "devin-ds41")
        self.assertEqual(paid_result.returncode, 0, paid_result.stderr)
        self.assertEqual(len(self.calls()), before + 1)
        paid_args = self.calls()[-1]
        self.assertEqual(paid_args[paid_args.index("--rung") + 1], "devin-ds41")
        paid_entries = [json.loads(line) for line in paid_log.read_text(encoding="utf-8").splitlines()]
        self.assertTrue(any(entry[:2] == ["agent", "read"] for entry in paid_entries))

    def test_installed_wrk_symlink_resolves_observer_helper(self) -> None:
        link = self.home / ".local" / "bin" / "wrk"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(ROOT / "bin" / "wrk")
        result, herdr_log = self.run_sentinel(
            "installed-shape-job", "devin", "devin-swe2", wrk_path=link
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        entries = [json.loads(line) for line in herdr_log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(sum(entry[:2] == ["agent", "read"] for entry in entries), 1)

    def test_spawn_callsite_passes_devin_kind_rung_and_scopefuel_to_sentinel(self) -> None:
        source = (ROOT / "bin" / "wrk").read_text(encoding="utf-8")
        start_marker = '  if [[ "$ARBITER_JOB_REGISTERED" -eq 1 ]]; then\n    OBSERVED_DEVIN_RUNG=""'
        start = source.index(start_marker)
        end = source.index("  fi\n  SPAWN_PANE_OPEN=0", start) + len("  fi")
        callsite = source[start:end]
        script = (
            "set -euo pipefail\n"
            "JOB_ID=spawn-job\nJOB_LANE=worker\nLABEL=label\nPANE=pane-1\n"
            "REPORT_PATH=\nARBITER_RESOURCE=\nARBITER_JOB_REGISTERED=1\n"
            'PROFILE_KIND="${TEST_PROFILE_KIND}"\nMODEL="${TEST_MODEL}"\n'
            'SCOPEFUEL="${TEST_SCOPEFUEL}"\n'
            'wrk_jobs_root() { printf "%s\\n" "$TEST_JOB_ROOT/jobs"; }\n'
            'start_completion_sentinel() { printf "%s\\0" "$@"; }\n'
            f"{callsite}\n"
        )

        def run_callsite(kind: str, model: str) -> list[str]:
            result = subprocess.run(
                ["bash", "-c", script],
                text=True,
                capture_output=True,
                timeout=10,
                env=self.call_env(
                    TEST_PROFILE_KIND=kind,
                    TEST_MODEL=model,
                    TEST_SCOPEFUEL=str(self.scopefuel),
                    TEST_JOB_ROOT=str(self.root),
                ),
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.split("\0")[:-1]

        devin_args = run_callsite("devin", "devin-ds41")
        self.assertEqual(
            devin_args,
            [
                str(self.root / "jobs" / "spawn-job" / "completion-sentinel.pid"),
                "spawn-job",
                "worker",
                "label",
                "pane-1",
                "",
                "",
                "devin",
                "devin-ds41",
                str(self.scopefuel),
            ],
        )
        codex_args = run_callsite("codex", "codex-luna")
        self.assertEqual(codex_args[7:], ["codex", "", str(self.scopefuel)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
