"""hk 2188 r3 (309-b): the fixture scopefuel must answer `policy launch` for the
pi/cmd credit rows exactly like the real canon, per seat. A fixture that drifts
from the real tool is how the round-2 and round-3 false greens happened.

The parity half needs a real scopefuel (set WRK_REAL_SCOPEFUEL to its binary,
for example the PR 219 build in a temp venv); without it only the fixture's
own seat contract is checked.
"""

from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "scopefuel"

# (profile, effort) rungs the canon places for the credit lanes, with the
# expected seat outcome per role: True = admitted (rc 0), False = refused (rc 3).
CASES = [
    ("cmd-dsflash41", "high", {"worker": True, "tester": True, "builder": True, "": False}),
    ("pi-sonnet55", "xhigh", {"worker": True, "tester": True, "builder": True, "": False}),
    ("pi-sonnet55", "high", {"worker": True, "tester": True, "builder": True, "": False}),
    ("pi-opus55", "high", {"worker": True, "tester": True, "builder": True, "": False}),
    ("pi-opus55", "max", {"worker": True, "tester": True, "builder": False, "": False}),
]


def launch(binary: str, profile: str, effort: str, role: str) -> tuple[int, dict | None]:
    argv = [binary, "policy", "launch", profile, "--effort", effort, "--json"]
    if role:
        argv += ["--role", role]
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)
    payload = None
    if proc.returncode == 0:
        try:
            payload = json.loads(proc.stdout)
        except ValueError:
            payload = None
    return proc.returncode, payload


class FixtureSeatContract(unittest.TestCase):
    def test_fixture_answers_each_seat_like_the_canon(self):
        for profile, effort, seats in CASES:
            for role, admitted in seats.items():
                with self.subTest(profile=profile, effort=effort, role=role):
                    rc, payload = launch(str(FIXTURE), profile, effort, role)
                    if admitted:
                        self.assertEqual(rc, 0)
                        self.assertIsNotNone(payload)
                    else:
                        self.assertNotEqual(rc, 0)


@unittest.skipUnless(os.environ.get("WRK_REAL_SCOPEFUEL"), "set WRK_REAL_SCOPEFUEL to a real scopefuel binary")
class FixtureMatchesRealScopefuel(unittest.TestCase):
    def test_fixture_and_real_agree_per_seat(self):
        real = os.environ["WRK_REAL_SCOPEFUEL"]
        for profile, effort, seats in CASES:
            for role in seats:
                with self.subTest(profile=profile, effort=effort, role=role):
                    real_rc, real_payload = launch(real, profile, effort, role)
                    fix_rc, fix_payload = launch(str(FIXTURE), profile, effort, role)
                    self.assertEqual(real_rc == 0, fix_rc == 0, (real_rc, fix_rc))
                    if real_rc == 0:
                        for key in ("gate", "grade", "effort"):
                            self.assertEqual(real_payload.get(key), fix_payload.get(key), key)


if __name__ == "__main__":
    unittest.main()
