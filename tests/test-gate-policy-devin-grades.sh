#!/usr/bin/env bash
# #1330: gate_policy.json devin grades must agree with the scopefuel catalog.
#
# scopefuel is the grade canon; gate_policy.json is a static snapshot consumed
# by gate_common.resolve_profile/tester-eligible. It drifted once already
# (swe2-max C while the catalog's devin-swe2-max@max rung is A+, swe2-medium C
# while the catalog row is A), so the devin rows are pinned here against a
# table transcribed from the catalog.
#
# Single-source decision: the expectation MUST be a pinned copy, not read from
# scopefuel at test time — installed scopefuel is forbidden in tests and CI
# has no scopefuel checkout, so the two cannot derive from one source here.
# The pin names its source commit; a scopefuel catalog change that promotes or
# demotes a devin rung turns this test RED until the pin is re-transcribed.
#
# Pinned from scopefuel origin/main 5e9177b (hk 1380 Part A catalog rows
# merged there; earlier rows transcribed at 5d911c4aac0e9b5b77b11d6614560338770867eb,
# "recommend: scope the Sonnet estimate sentence to estimated rungs (#1305)",
# line numbers at that commit):
#   recommend.py GRADE_TABLE:
#     A+  devin-swe2      (:887 _devin_swe2_profile effort-less row,
#                          :907 devin-swe2@high rung — #1297, operator 2026-10-08)
#     A+  devin-swe2-max  (:915 devin-swe2-max@max rung — #1297;
#                          launch.py:285 ARM_GRADE_OVERRIDES restates A+)
#     A+  devin-ds41      (:888 — hk:doc 2227 reps 3/3)
#     A   devin-swe2-medium (:1009 — #787, operator 2026-09-27, hk:doc 5177;
#                          launch.py:261 ARM_GRADE_OVERRIDES restates A)
#     C   devin-ds41-max  (:1283 — unmeasured effort-variant row)
#     C   devin-glm52     (:1271 — unmeasured)
#     C   devin-swe17     (:1272 — unmeasured)
#   hk 1380 fusion rows (5e9177b, `scopefuel policy launch <name> --json` —
#   billing=paid, pool=devin, unmeasured):
#     B   devin-fusion-opus55    (model fusion-claude-opus-5-5-high-sidekick-swe-2-medium)
#     B   devin-fusion-sonnet55  (model fusion-claude-sonnet-5-5-high-sidekick-swe-2-medium)
#   launch.py:84-91 LAUNCH_MODEL_IDS maps each catalog profile to the devin
#   --model id the gate profile carries; devin encodes effort in the model id
#   (#635), so devin-swe2-max IS the max rung and takes the @max grade A+.
#   Every gate spelling that launches a model (worker devin-* and builder
#   builder-*/builder-devin-* aliases) must carry the same grade.
#
# Vocabulary note (N1): the catalog calls the fusion rows' family "claude"
# while gate_policy.json says "anthropic" — same family, different names
# (anthropic is the value every existing Claude profile uses here).
# Nothing cross-reads the two strings.
#
# Every mutant reverts or moves one devin grade and must go RED by assertion.
set -euo pipefail

ROOT="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
python3 - "$ROOT" <<'PY'
from datetime import datetime, timezone
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "director"))
import gate_common as common

loader = importlib.machinery.SourceFileLoader(
    "tester_eligible", str(root / "director/bin/tester-eligible"))
spec = importlib.util.spec_from_loader(loader.name, loader)
eligible = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = eligible
loader.exec_module(eligible)

# devin --model id -> catalog grade (scopefuel 5e9177b, table above).
EXPECTED = {
    "swe-2": "A+",
    "swe-2-max": "A+",
    "swe-2-medium": "A",
    "deepseek-v4-1-flash-high": "A+",
    "deepseek-v4-1-flash-max": "C",
    "glm-5-2": "C",
    "swe-1-7": "C",
    # hk 1380 paid fusion spellings — unmeasured; the merged catalog rows
    # (5e9177b) list both at B.
    "fusion-claude-opus-5-5-high-sidekick-swe-2-medium": "B",
    "fusion-claude-sonnet-5-5-high-sidekick-swe-2-medium": "B",
}

# Policy validity window per gate_policy.json effective_at/expires_at.
NOW = datetime(2026, 9, 26, tzinfo=timezone.utc)


def devin_profiles(policy: dict) -> dict:
    return {name: spec for name, spec in policy["profiles"].items()
            if spec.get("launcher") == "devin"}


def check(policy: dict) -> None:
    profiles = devin_profiles(policy)
    assert profiles, "no devin profiles found"
    models = {spec["model"] for spec in profiles.values()}
    assert models == set(EXPECTED), (
        f"devin model set drifted: extra={sorted(models - set(EXPECTED))} "
        f"missing={sorted(set(EXPECTED) - models)} — re-pin EXPECTED from "
        "scopefuel recommend.py GRADE_TABLE and cite the new source commit")
    for name, spec in sorted(profiles.items()):
        want = EXPECTED[spec["model"]]
        assert spec["grades"] == {"": want}, (
            f"{name}: gate grade {spec['grades']} != scopefuel catalog "
            f"{want} for model {spec['model']} (see pin header)")
        role = "builder" if name.startswith(("builder-", "captain-")) else "worker"
        resolved, outcome = common.resolve_profile(
            name, policy, actual_model=spec["model"],
            actual_effort=spec["default_effort"], role=role, root=root)
        assert outcome["status"] == "PASS", f"{name}: resolve_profile {outcome}"
        assert resolved["grade"] == want, (
            f"{name}: resolved grade {resolved['grade']} != {want}")


def grade_verdict(policy: dict, policy_check: dict, alias: str, model: str,
                  role: str, assigned: str) -> tuple:
    """The tester-eligible implementer-grade verdict for one devin contributor."""
    evidence = {
        "declared_t": "T1", "required_grade": assigned,
        "implementation_grade": assigned,
        "contributors": [{"profile": alias, "model": model, "effort": "",
                          "role": role, "kind": "initial",
                          "session": "pin-session", "worktree": "/tmp/pin-wt"}],
        "tester": {"planned_profile": "opus", "planned_effort": "high"},
    }
    checks, _ = eligible.evaluate(evidence, "pre-spawn", policy, policy_check,
                                  root=root)
    assert checks["contributors"]["status"] == "PASS", (
        f"{alias}: contributor unresolved {checks['contributors']}")
    return checks["grade"]["status"], checks["grade"]["reason_code"]


def check_gate(policy: dict, policy_check: dict) -> None:
    cases = [
        # #1330: the measured defect — a swe2-max builder/contributor on A or B
        # work must not trip IMPLEMENTER_GRADE_LOW now that the rung is A+.
        ("devin-swe2-max", "swe-2-max", "worker", "A", ("PASS", "GRADE_SUFFICIENT")),
        ("devin-swe2-max", "swe-2-max", "worker", "B", ("PASS", "GRADE_SUFFICIENT")),
        ("builder-devin-max", "swe-2-max", "builder", "A", ("PASS", "GRADE_SUFFICIENT")),
        ("devin-swe2-medium", "swe-2-medium", "worker", "A", ("PASS", "GRADE_SUFFICIENT")),
        ("builder-devin-medium", "swe-2-medium", "builder", "A", ("PASS", "GRADE_SUFFICIENT")),
        # medium is A, not A+: A+ work still refuses it.
        ("devin-swe2-medium", "swe-2-medium", "worker", "A+", ("FAIL", "IMPLEMENTER_GRADE_LOW")),
        # Unmeasured devin rows stay C.
        ("devin-ds41-max", "deepseek-v4-1-flash-max", "worker", "B", ("FAIL", "IMPLEMENTER_GRADE_LOW")),
        ("devin-glm52", "glm-5-2", "worker", "B", ("FAIL", "IMPLEMENTER_GRADE_LOW")),
        ("devin-swe17", "swe-1-7", "worker", "B", ("FAIL", "IMPLEMENTER_GRADE_LOW")),
        ("devin-ds41-max", "deepseek-v4-1-flash-max", "worker", "C", ("PASS", "GRADE_SUFFICIENT")),
        # hk 1380: the fusion rows list at the catalog's unmeasured B — B work
        # passes, A work refuses.
        ("devin-fusion-opus55", "fusion-claude-opus-5-5-high-sidekick-swe-2-medium", "worker", "B", ("PASS", "GRADE_SUFFICIENT")),
        ("devin-fusion-sonnet55", "fusion-claude-sonnet-5-5-high-sidekick-swe-2-medium", "worker", "A", ("FAIL", "IMPLEMENTER_GRADE_LOW")),
    ]
    for alias, model, role, assigned, want in cases:
        got = grade_verdict(policy, policy_check, alias, model, role, assigned)
        assert got == want, f"{alias} on {assigned}: grade check {got} != {want}"


def mutate(policy: dict, name: str, grade) -> dict:
    changed = json.loads(json.dumps(policy))
    changed["profiles"][name]["grades"] = {"": grade}
    return changed


policy, policy_check = common.load_policy(now=NOW)
assert policy_check["status"] == "PASS", (
    f"policy must load clean inside its window, got {policy_check}")
check(policy)
print(f"PASS devin-grades-pin profiles={len(devin_profiles(policy))} "
      f"models={len(EXPECTED)}/{len(EXPECTED)}")
check_gate(policy, policy_check)
print("PASS devin-gate-verdicts cases=12/12")

mutants = {
    # Reverting this one row is exactly the #1330 defect.
    "swe2-max-back-to-C": mutate(policy, "devin-swe2-max", "C"),
    "builder-swe2-max-back-to-C": mutate(policy, "builder-devin-max", "C"),
    "swe2-medium-back-to-C": mutate(policy, "devin-swe2-medium", "C"),
    "builder-swe2-medium-back-to-C": mutate(policy, "builder-devin-medium", "C"),
    "swe2-medium-overpromoted": mutate(policy, "devin-swe2-medium", "A+"),
    "swe2-demoted": mutate(policy, "devin-swe2", "A"),
    "ds41-demoted": mutate(policy, "devin-ds41", "A"),
    "ds41-max-promoted": mutate(policy, "devin-ds41-max", "B"),
    "glm52-promoted": mutate(policy, "devin-glm52", "A"),
    "swe17-promoted": mutate(policy, "devin-swe17", "B"),
    "spellings-split": mutate(policy, "builder-devin", "A"),
    # N2: the fusion rows are pinned at the catalog B — demoting either to the
    # old unmeasured-C placeholder must go RED.
    "fusion-opus-back-to-C": mutate(policy, "devin-fusion-opus55", "C"),
    "fusion-sonnet-back-to-C": mutate(policy, "devin-fusion-sonnet55", "C"),
}
added = json.loads(json.dumps(policy))
added["profiles"]["devin-swe3"] = {
    "default_effort": "", "family": "cognition", "grades": {"": "A+"},
    "launcher": "devin", "launcher_model_token": "--model swe-3",
    "model": "swe-3", "roles": ["builder", "worker", "tester"],
    "surfaces": ["T1", "T2"],
}
mutants["unpinned-model-added"] = added
for name, doc in mutants.items():
    try:
        check(doc)
    except AssertionError:
        print(f"RED {name}")
        continue
    raise SystemExit(f"mutant {name} did not go RED")
print(f"PASS mutants assertion-red={len(mutants)}/{len(mutants)}")
PY
