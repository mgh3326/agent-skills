#!/usr/bin/env python3
"""Focused tests for the passive per-job Devin free-window observer."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
import argparse


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
import wrk_free_limit_observer as observer  # noqa: E402
import wrk_pane_models as models  # noqa: E402


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
            "XDG_RUNTIME_DIR": str(self.root / "runtime"),
            "TMPDIR": str(self.root / "tmp"),
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

    def pane_observe(self, text, at, rung="devin-swe2", job="drift-job"):
        args = argparse.Namespace(pane_kind="devin", rung=rung, job=job,
                                  state=str(self.root / job / "free-limit-observer.json"),
                                  observed=at, owner_lane="owner")
        with mock.patch.dict(os.environ, self.dirs, clear=True):
            observer.observe_pane(args, text)
        return observer.job_events(self.root / job)

    def test_strict_shared_parser_labels_status_and_unknown_parts(self):
        labels = ["Fusion · GPT-6.1 Sol ◆ SWE-2 Medium",
                  "Fusion · GPT-6.1 Sol ◆ GPT-6 Luna High",
                  "SWE-2 High", "DeepSeek V4.1 Flash High"]
        for raw in labels:
            parsed = models.parse_model_line(raw)
            self.assertTrue(parsed["attributed"], raw)
            self.assertEqual(models.latest_model_line(raw), raw)
        sidekick = models.parse_model_line(labels[0])["parts"][1]
        self.assertEqual((sidekick["pool"], sidekick["bucket"]), ("devin", "free"))
        for status in ("Devin update available", "Opus is thinking about it", "Fusion mode enabled",
                       "GPT-6.1 Sol please fix this", "> SWE-2 High", "Fusion · please use GPT-6.1 Sol ◆ SWE-2 Medium"):
            self.assertEqual(models.latest_model_line(labels[0] + "\n" + status), labels[0])
        self.assertEqual(models.latest_model_line(labels[0] + "\n" + labels[2]), labels[2])
        for unknown in ("NewModel High", "SWE-2.9 Medium", "Claude Opus 5.5"):
            parsed = models.parse_model_line("Fusion · GPT-6.1 Sol ◆ " + unknown)
            self.assertFalse(parsed["attributed"])
            self.assertEqual(parsed["pools"], [])
            self.assertIsNone(parsed["parts"][-1]["pool"])
        for lead in ("Claude Opus 5.5", "Opus 5.5", "Sonnet 5.5"):
            parsed = models.parse_model_line("Fusion · " + lead + " ◆ SWE-2 Medium")
            self.assertEqual(parsed["families"], ["anthropic", "cognition"])
            self.assertEqual(parsed["pools"], ["devin"])

    def test_system_python_without_tomllib_keeps_observer_and_account_tag(self):
        config = Path(self.dirs["XDG_CONFIG_HOME"]) / "scopefuel/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[pools.codex]\nfusion_billing_fp = "0123456789abcdef" # billing\n[pools.devin]\n')
        # Reproduce the macOS PATH-selected interpreter without tomllib, both
        # importing the actual helper and executing the CLI (not just the tag).
        blocker = self.root / "no-tomllib"
        blocker.mkdir()
        (blocker / "sitecustomize.py").write_text("import sys\nsys.modules['tomllib'] = None\n")
        proc = subprocess.run([sys.executable, str(ROOT / "bin/wrk_free_limit_observer.py"),
            "--pane-kind", "devin", "--rung", "devin-swe2", "--job", "old-python",
            "--state", str(self.root / "old-python/free-limit-observer.json"),
            "--scopefuel", str(self.scopefuel), "--observed", "2026-10-20T07:00:00Z"],
            input=provider_notice("Reached free model rate limit reset in 1 minute") +
                  "Fusion · GPT-6.1 Sol ◆ GPT-6 Luna High\n",
            text=True, capture_output=True, timeout=10,
            env=self.call_env(PYTHONPATH=str(blocker)), check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("observer-ok-reset", proc.stdout)
        observations = [observer.payload(doc) for doc in observer.job_events(self.root / "old-python")
                        if doc["kind"] == "job.model_observed"]
        self.assertEqual([part["account_tag"] for part in observations[0]["parts"]], ["01234567"] * 2)
        with mock.patch.dict(sys.modules, {"tomllib": None}), mock.patch.dict(os.environ, self.dirs, clear=True):
            config.write_text('[pools.other]\nfusion_billing_fp="0123456789abcdef"\n[pools.codex]\n')
            self.assertIsNone(observer.billing_account_tag())
            config.write_text('[pools.codex]\nfusion_billing_fp="0123456789abcdef"\nfusion_billing_fp="fedcba9876543210"\n')
            self.assertIsNone(observer.billing_account_tag())

    def test_model_change_records_parts_pool_drift_account_and_no_repeat(self):
        jobdir = self.root / "drift-job"
        observer.atomic_json(jobdir / "events/00001-quota_pool.record.json",
                             dict(kind="quota_pool.record", payload=dict(pool="devin")))
        config = Path(self.dirs["XDG_CONFIG_HOME"]) / "scopefuel/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[pools.codex]\nfusion_billing_fp = "0123456789abcdef"\n')
        at = "2026-10-20T07:00:00Z"
        self.pane_observe("SWE-2 High", at)
        self.pane_observe("SWE-2 High", "2026-10-20T07:00:30Z")
        sol = "Fusion · GPT-6.1 Sol ◆ SWE-2 Medium"
        self.pane_observe(sol, "2026-10-20T07:01:00Z")
        self.pane_observe(sol, "2026-10-20T07:01:30Z")
        events = self.pane_observe("Fusion · GPT-6.1 Sol ◆ GPT-6 Luna High", "2026-10-20T07:02:00Z")
        observed = [observer.payload(doc) for doc in events if doc["kind"] == "job.model_observed"]
        self.assertEqual(len(observed), 3)
        self.assertEqual([doc["drift"] for doc in observed], [False, True, True])
        self.assertEqual(observed[-1]["pools"], ["codex"])
        self.assertEqual(observed[-1]["families"], ["openai"])
        self.assertEqual([part["account"] for part in observed[-1]["parts"]], ["devin-linked"] * 2)
        self.assertEqual([part["account_tag"] for part in observed[-1]["parts"]], ["01234567"] * 2)
        drifts = [observer.payload(doc) for doc in events if doc["kind"] == "quota_pool.drift"]
        self.assertEqual([(doc["from_pool"], doc["to_pool"]) for doc in drifts],
                         [("devin", ["codex", "devin"]), ("devin", ["codex"])])
        self.assertEqual(json.loads((jobdir / "events/00001-quota_pool.record.json").read_text())["payload"], {"pool": "devin"})
        for rung in ("devin-swe2", "builder-devin-max", "devin-ds41", "devin-fusion-sol61-xhigh"):
            events = self.pane_observe(models.expected_label(rung), at, rung=rung, job=rung)
            self.assertFalse(observer.payload(events[-1])["drift"])
        events = self.pane_observe("Fusion · GPT-6.1 Sol ◆ Unknown High", "2026-10-20T07:03:00Z")
        self.assertFalse(observer.payload(events[-1])["attributed"])

    def test_model_return_a_to_b_to_a_records_each_change(self):
        a, b = "SWE-2 High", "Fusion · GPT-6.1 Sol ◆ SWE-2 Medium"
        for raw, at in ((a, "07:00:00"), (b, "07:01:00"), (a, "07:02:00")):
            events = self.pane_observe(raw, "2026-10-20T" + at + "Z")
        self.assertEqual([observer.payload(doc)["raw_line"] for doc in events
                          if doc["kind"] == "job.model_observed"], [a, b, a])

    def test_deeply_nested_audit_event_does_not_disable_hold(self):
        events = self.root / "deep-event/events"
        events.mkdir(parents=True)
        (events / "00009-bad.json").write_text("[" * 200000)
        result = self.run_helper(provider_notice("Reached free model rate limit reset in 1 minute"),
                                 "2026-10-20T07:00:00Z", job="deep-event")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("observer-ok-reset=2026-10-20T07:01:00Z", result.stdout)
        self.assertIn("pane-observer-skipped-recursion-error", result.stdout)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][:2], ["observe", "devin-free-limit"])

    def test_free_stall_reset_margin_once_and_progress_clears(self):
        text = provider_notice("Reached free model rate limit reset in 1 minute") + "SWE-2 High\n"
        start = "2026-10-20T07:00:00Z"
        with mock.patch.object(observer, "emit_stall", return_value=True) as emit:
            self.pane_observe(text, start)
            events = self.pane_observe(text, "2026-10-20T07:02:59Z")
            self.assertFalse(any(doc["kind"] == "job.stalled_free_limit" for doc in events))
            events = self.pane_observe(text, "2026-10-20T07:03:00Z")
            self.pane_observe(text, "2026-10-20T07:06:00Z")
            stalls = [observer.payload(doc) for doc in events if doc["kind"] == "job.stalled_free_limit"]
            self.assertEqual(len(stalls), 1)
            self.assertEqual(stalls[0]["reset"], "2026-10-20T07:01:00Z")
            self.assertEqual(stalls[0]["notice_time"], start)
            self.assertEqual(stalls[0]["error_class"], "free_model_rate_limit")
            self.assertEqual(emit.call_count, 1)
            for job, progress in (("content-progress", True), ("event-progress", False)):
                self.pane_observe(text, start, job=job)
                if not progress:
                    observer.atomic_json(self.root / job / "events/00002-job.progress.json", dict(kind="job.progress"))
                changed = text + "work resumed\n" if progress else text
                self.pane_observe(changed, "2026-10-20T07:01:30Z", job=job)
                events = self.pane_observe(changed, "2026-10-20T07:10:00Z", job=job)
                self.assertFalse(any(doc["kind"] == "job.stalled_free_limit" for doc in events))

    def test_protocol_stall_last_error_only_and_lane_command(self):
        text = provider_notice("invalid_argument: malformed tool response")
        self.assertEqual(observer.active_protocol_error(text), "invalid_argument")
        self.assertIsNone(observer.active_protocol_error(text + "work resumed\n"))
        self.pane_observe(text, "2026-10-20T07:00:00Z")
        with mock.patch.object(observer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stderr=b"")) as run:
            events = self.pane_observe(text, "2026-10-20T07:02:00Z")
            self.pane_observe(text, "2026-10-20T07:03:00Z")
            self.assertEqual(run.call_count, 1)
            argv = run.call_args.args[0]
            self.assertEqual(argv[:6], ["panewire", "emit", "--kind", "lane.event", "--lane", "owner"])
            self.assertNotIn("send-text", argv)
            self.assertNotIn("prompt", argv)
        stalls = [observer.payload(doc) for doc in events if doc["kind"] == "job.stalled_free_limit"]
        self.assertEqual(stalls[0]["error_class"], "invalid_argument")

    def test_invariant_mutants_fail_by_assertion(self):
        label = "Fusion · GPT-6.1 Sol ◆ SWE-2 Medium"
        def strict_footer():
            self.assertEqual(models.latest_model_line(label + "\nDevin update available"), label)
        strict_footer()
        original = models._components
        with mock.patch.object(models, "_components", side_effect=lambda raw: [raw] if raw == "Devin update available" else original(raw)):
            with self.assertRaises(AssertionError):
                strict_footer()
        def unknown_stays_unattributed():
            self.assertFalse(models.parse_model_line("Fusion · GPT-6.1 Sol ◆ SWE-2.9 Medium")["attributed"])
        unknown_stays_unattributed()
        with mock.patch.object(models, "SIDECARS", ((r"SWE-", "devin", "cognition", "free", None),) + models.SIDECARS):
            with self.assertRaises(AssertionError):
                unknown_stays_unattributed()
        def record_change(job):
            self.pane_observe("SWE-2 High", "2026-10-20T07:00:00Z", job=job)
            events = self.pane_observe(label, "2026-10-20T07:00:30Z", job=job)
            changes = [observer.payload(doc)["raw_line"] for doc in events if doc["kind"] == "job.model_observed"]
            self.assertEqual(changes, ["SWE-2 High", label])
        record_change("mutant-green")
        with mock.patch.object(observer, "commit_event"):
            with self.assertRaises(AssertionError):
                record_change("mutant-red")

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

    def test_stated_reset_at_or_just_past_observation_records_no_hold(self) -> None:
        notice = provider_notice("Reached free model rate limit (at 08:01 UTC)")
        for observed, job in (
            ("2026-10-19T08:01:00Z", "equality-job"),
            ("2026-10-19T08:01:30Z", "plus-30s-job"),
            ("2026-10-19T09:00:00Z", "plus-59min-job"),
        ):
            with self.subTest(observed=observed):
                event = observer.parse_rate_limit(notice, when(observed))
                self.assertTrue(event["expired"])
                self.assertEqual(event["reset"], "2026-10-19T08:01:00Z")
                result = self.run_helper(notice, observed, job=job)
                self.assertEqual(result.returncode, 0)
                self.assertIn("observer-expired-reset=2026-10-19T08:01:00Z", result.stdout)
                state = json.loads(
                    (self.root / job / "free-limit-observer.json").read_text()
                )
                self.assertEqual(len(state["events"]), 1)
                self.assertEqual(state["events"][0]["result"], "expired")
                again = self.run_helper(notice, observed, job=job)
                self.assertEqual(again.stdout, "")
        self.assertEqual(self.calls(), [])

    def test_grace_boundary_then_next_day_roll(self) -> None:
        notice = provider_notice("Reached free model rate limit (at 08:01 UTC)")
        edge = self.run_helper(notice, "2026-10-19T14:01:00Z", job="grace-edge")
        self.assertIn("observer-expired-reset=2026-10-19T08:01:00Z", edge.stdout)
        past = self.run_helper(notice, "2026-10-19T14:02:00Z", job="grace-past")
        self.assertIn("observer-ok-reset=2026-10-20T08:01:00Z", past.stdout)
        self.assertEqual(len(self.calls()), 1)
        args = self.calls()[0]
        self.assertEqual(args[args.index("--reset") + 1], "2026-10-20T08:01:00Z")

    def test_midnight_notice_rolls_and_post_reset_read_expires(self) -> None:
        notice = provider_notice("Reached free model rate limit (at 00:30 UTC)")
        late = self.run_helper(notice, "2026-10-19T23:59:00Z", job="midnight-late")
        self.assertIn("observer-ok-reset=2026-10-20T00:30:00Z", late.stdout)
        after = self.run_helper(notice, "2026-10-20T00:35:00Z", job="midnight-after")
        self.assertIn("observer-expired-reset=2026-10-20T00:30:00Z", after.stdout)
        self.assertEqual(len(self.calls()), 1)

    def test_fusion_sol_notice_is_recorded_with_its_observed_rung(self) -> None:
        notice = provider_notice(
            "Reached free model rate limit. Upgrade to Max for higher limits. "
            "Your limit will reset in 50 minutes (at 08:01 UTC)."
        )
        for rung in ("devin-fusion-sol61", "devin-fusion-sol61-xhigh"):
            with self.subTest(rung=rung):
                result = self.run_helper(
                    notice,
                    "2026-10-19T07:11:00Z",
                    job=f"fusion-sol-observation-{rung}",
                    rung=rung,
                    pane_kind="devin",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(self.calls()), 1)
                args = self.calls()[0]
                self.assertEqual(args[:2], ["observe", "devin-free-limit"])
                self.assertEqual(args[args.index("--rung") + 1], rung)
                self.assertEqual(args[args.index("--reset") + 1], "2026-10-19T08:01:00Z")
                self.call_log.unlink(missing_ok=True)

    def test_stale_notice_just_after_midnight_records_no_hold(self) -> None:
        notice = provider_notice("Reached free model rate limit (at 23:59 UTC)")
        for observed, job in (
            ("2026-10-20T00:00:00Z", "just-midnight-job"),
            ("2026-10-20T00:30:00Z", "after-midnight-30-job"),
            ("2026-10-20T05:58:00Z", "after-midnight-558-job"),
        ):
            with self.subTest(observed=observed):
                event = observer.parse_rate_limit(notice, when(observed))
                self.assertTrue(event["expired"])
                self.assertEqual(event["reset"], "2026-10-19T23:59:00Z")
                result = self.run_helper(notice, observed, job=job)
                self.assertEqual(result.returncode, 0)
                self.assertIn("observer-expired-reset=2026-10-19T23:59:00Z", result.stdout)
                state = json.loads(
                    (self.root / job / "free-limit-observer.json").read_text()
                )
                self.assertEqual(len(state["events"]), 1)
                self.assertEqual(state["events"][0]["result"], "expired")
        self.assertEqual(self.calls(), [])

    def test_previous_day_candidate_beyond_grace_takes_todays_reset(self) -> None:
        notice = provider_notice("Reached free model rate limit (at 23:59 UTC)")
        event = observer.parse_rate_limit(notice, when("2026-10-20T06:00:00Z"))
        self.assertFalse(event["expired"])
        self.assertEqual(event["reset"], "2026-10-20T23:59:00Z")
        result = self.run_helper(notice, "2026-10-20T06:00:00Z", job="beyond-grace-job")
        self.assertIn("observer-ok-reset=2026-10-20T23:59:00Z", result.stdout)
        self.assertEqual(len(self.calls()), 1)
        args = self.calls()[0]
        self.assertEqual(args[args.index("--reset") + 1], "2026-10-20T23:59:00Z")

    def test_expired_post_midnight_signature_does_not_suppress_new_notice(self) -> None:
        stale = provider_notice("Reached free model rate limit (at 23:59 UTC)")
        first = self.run_helper(stale, "2026-10-20T00:30:00Z", job="midnight-renewed")
        self.assertIn("observer-expired", first.stdout)
        fresh = provider_notice("Reached free model rate limit (at 01:15 UTC)")
        second = self.run_helper(fresh, "2026-10-20T00:40:00Z", job="midnight-renewed")
        self.assertIn("observer-ok-reset=2026-10-20T01:15:00Z", second.stdout)
        self.assertEqual(len(self.calls()), 1)
        state = json.loads(
            (self.root / "midnight-renewed" / "free-limit-observer.json").read_text()
        )
        self.assertEqual([event["result"] for event in state["events"]], ["expired", "rc-0"])

    def test_disagreeing_relative_and_absolute_pick_earlier_reset(self) -> None:
        absolute_earlier = provider_notice(
            "Reached free model rate limit; reset in 130 minutes (at 08:01 UTC)"
        )
        result = self.run_helper(absolute_earlier, "2026-10-19T07:11:00Z", job="abs-earlier")
        self.assertIn("observer-ok-reset=2026-10-19T08:01:00Z", result.stdout)
        self.assertIn(
            "disagreement=absolute:2026-10-19T08:01:00Z;relative:2026-10-19T09:21:00Z",
            result.stdout,
        )
        state = json.loads((self.root / "abs-earlier" / "free-limit-observer.json").read_text())
        expected = hashlib.sha256(b"free-limit|utc|08:01").hexdigest()
        self.assertEqual(state["events"][0]["signature"], expected)

        relative_earlier = provider_notice(
            "Reached free model rate limit; reset in 50 minutes (at 09:30 UTC)"
        )
        result = self.run_helper(relative_earlier, "2026-10-19T07:11:00Z", job="rel-earlier")
        self.assertIn("observer-ok-reset=2026-10-19T08:01:00Z", result.stdout)
        self.assertIn(
            "disagreement=absolute:2026-10-19T09:30:00Z;relative:2026-10-19T08:01:00Z",
            result.stdout,
        )
        state = json.loads((self.root / "rel-earlier" / "free-limit-observer.json").read_text())
        expected = hashlib.sha256(b"free-limit|relative|50").hexdigest()
        self.assertEqual(state["events"][0]["signature"], expected)
        args = self.calls()[-1]
        self.assertEqual(args[args.index("--reset") + 1], "2026-10-19T08:01:00Z")

    def test_agreeing_relative_and_absolute_prefer_absolute_silently(self) -> None:
        notice = provider_notice(
            "Reached free model rate limit; reset in 52 minutes (at 08:01 UTC)"
        )
        event = observer.parse_rate_limit(notice, when("2026-10-19T07:11:00Z"))
        self.assertEqual(event["reset"], "2026-10-19T08:01:00Z")
        self.assertEqual(event["disagreement"], "")
        result = self.run_helper(notice, "2026-10-19T07:11:00Z", job="agree-job")
        self.assertIn("observer-ok-reset=2026-10-19T08:01:00Z", result.stdout)
        self.assertNotIn("disagreement", result.stdout)

    def test_stale_notice_with_both_spellings_still_records_no_hold(self) -> None:
        notice = provider_notice(
            "Reached free model rate limit; reset in 50 minutes (at 08:01 UTC)"
        )
        result = self.run_helper(notice, "2026-10-19T08:05:00Z", job="stale-both")
        self.assertIn("observer-expired-reset=2026-10-19T08:01:00Z", result.stdout)
        self.assertIn(
            "disagreement=absolute:2026-10-19T08:01:00Z;relative:2026-10-19T08:55:00Z",
            result.stdout,
        )
        self.assertEqual(self.calls(), [])

    def test_expired_signature_does_not_suppress_a_new_notice(self) -> None:
        stale = provider_notice("Reached free model rate limit (at 08:01 UTC)")
        first = self.run_helper(stale, "2026-10-19T08:05:00Z", job="renewed-job")
        self.assertIn("observer-expired", first.stdout)
        fresh = provider_notice("Reached free model rate limit (at 09:15 UTC)")
        second = self.run_helper(fresh, "2026-10-19T08:10:00Z", job="renewed-job")
        self.assertIn("observer-ok-reset=2026-10-19T09:15:00Z", second.stdout)
        self.assertEqual(len(self.calls()), 1)
        args = self.calls()[0]
        self.assertEqual(args[args.index("--reset") + 1], "2026-10-19T09:15:00Z")
        state = json.loads(
            (self.root / "renewed-job" / "free-limit-observer.json").read_text()
        )
        self.assertEqual([event["result"] for event in state["events"]], ["expired", "rc-0"])

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
        pane_text: str | None = None,
        owner: str = "worker",
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
            STUB_PANE_TEXT=pane_text or provider_notice("Reached free model rate limit; reset in 50 minutes"),
        )
        # Capture the real sentinel-to-helper argv without changing the helper.
        shimdir = self.root / (job + "-bin")
        shimdir.mkdir()
        shim = shimdir / "python3"
        shim.write_text("#!" + sys.executable + "\nimport json, os, sys\n"
                        "if any(a.endswith('wrk_free_limit_observer.py') for a in sys.argv[1:]):\n"
                        "    with open(os.environ['HELPER_ARGV_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                        "os.execv(sys.executable, [sys.executable] + sys.argv[1:])\n")
        shim.chmod(0o700)
        env.update(PATH=str(shimdir) + os.pathsep + os.defpath,
                   HELPER_ARGV_LOG=str(self.root / (job + "-helper.jsonl")))
        args = [
            str(wrk_path or ROOT / "bin" / "wrk"),
            "sentinel",
            job,
            owner,
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

    def test_sentinel_real_callsite_records_latest_model_parts_without_pane_input(self):
        label = "Fusion · GPT-6.1 Sol ◆ GPT-6 Luna High"
        text = "SWE-2 High\n" + label + "\nDevin update available"
        result, log = self.run_sentinel("model-callsite", "devin", "devin-swe2", pane_text=text, owner="owner-lane-x")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads((self.root / "model-callsite-helper.jsonl").read_text().splitlines()[0])
        self.assertIn("--owner-lane", argv)
        self.assertEqual(argv[argv.index("--owner-lane") + 1], "owner-lane-x")
        observed = [observer.payload(doc) for doc in observer.job_events(self.root / "jobs/model-callsite")
                    if doc["kind"] == "job.model_observed"]
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["raw_line"], label)
        self.assertEqual([part["label"] for part in observed[0]["parts"]], ["GPT-6.1 Sol", "GPT-6 Luna High"])
        entries = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertTrue(all(entry[:2] in (["agent", "get"], ["agent", "read"]) for entry in entries))

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
