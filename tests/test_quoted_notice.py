#!/usr/bin/env python3
"""Require the actual Devin error banner before accepting a limit notice."""

from __future__ import annotations

import datetime as dt
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
import wrk_free_limit_observer as observer  # noqa: E402


OBSERVED = dt.datetime(2026, 10, 19, 7, 10, tzinfo=dt.timezone.utc)


def provider_block(message: str) -> str:
    body = "\n".join("   " + line for line in message.splitlines())
    return f"\n\n ▲ Something went wrong\n{body}\n"


class QuotedNoticeTests(unittest.TestCase):
    def test_numbered_source_is_not_a_provider_refusal(self) -> None:
        transcript = '106: NOTICE = "Reached free model rate limit reset in 50 minutes (at 08:01 UTC)"\nWorking on tests'
        self.assertIsNone(observer.parse_rate_limit(transcript, OBSERVED))

    def test_diff_hunk_is_not_a_provider_refusal(self) -> None:
        transcript = (
            "diff --git a/tests/example.py b/tests/example.py\n"
            "+Reached free model rate limit; reset in 50 minutes (at 08:01 UTC)\n"
            "-other output"
        )
        self.assertIsNone(observer.parse_rate_limit(transcript, OBSERVED))

    def test_code_block_is_not_a_provider_refusal(self) -> None:
        fence = chr(96) * 3
        transcript = (
            f"{fence}text\nReached free model rate limit; reset in 50 minutes "
            f"(at 08:01 UTC)\n{fence}"
        )
        self.assertIsNone(observer.parse_rate_limit(transcript, OBSERVED))

    def test_shell_echo_and_grep_are_not_provider_refusals(self) -> None:
        transcript = (
            "echo 'Reached free model rate limit; reset in 50 minutes (at 08:01 UTC)'\n"
            "grep -F 'Reached free model rate limit' tests/test_wrk_free_limit_observer.py"
        )
        self.assertIsNone(observer.parse_rate_limit(transcript, OBSERVED))

    def test_quoted_brief_or_prompt_is_not_a_provider_refusal(self) -> None:
        transcript = (
            "The brief says: “Reached free model rate limit; reset in 50 minutes "
            "(at 08:01 UTC).”\nWorking on tests"
        )
        self.assertIsNone(observer.parse_rate_limit(transcript, OBSERVED))

    def test_authoritative_real_block_accepts_variable_wrapping(self) -> None:
        messages = (
            "Reached free model rate limit. Upgrade to Max for higher limits, or switch to a different\n"
            "model. Your limit will reset in 50 minutes (at 08:01 UTC). (trace ID:\n"
            "3864aeb615ff9f2cb130e4518de194c3). Send a message to retry",
            "Reached free model rate\nlimit. Upgrade to Max; Your limit will reset in 50 minutes (at 08:\n01 UTC).",
            "Reached free model rate limit. Your limit will reset in 50 minutes (at 08:0\n1 UTC).",
        )
        for message in messages:
            with self.subTest(message=message):
                event = observer.parse_rate_limit(provider_block(message), OBSERVED)
                self.assertIsNotNone(event)
                self.assertEqual(event["reset"], "2026-10-19T08:01:00Z")
                self.assertEqual(event["observed"], "2026-10-19T07:10:00Z")

    def test_real_block_reset_wins_over_quoted_copy_before_it(self) -> None:
        transcript = (
            'Prompt quotation: "Reached free model rate limit reset in 50 minutes (at 09:41 UTC)"\n'
            + provider_block(
                "Reached free model rate limit. Your limit will reset in 50 minutes (at 08:01 UTC)."
            )
        )
        event = observer.parse_rate_limit(transcript, OBSERVED)
        self.assertIsNotNone(event)
        self.assertEqual(event["reset"], "2026-10-19T08:01:00Z")


if __name__ == "__main__":
    unittest.main(verbosity=2)
