#!/usr/bin/env bash
# #736: assignment defaults contract (operator decision 2026-09-26, decision
# 4088 B + note/2026-09-26/grade-cost-table id 4098 — the FINAL rule is
# "among candidates whose grade is at least the task grade, pick the lowest
# cost per task"; the listed model/effort pairs are its current output, not a
# hard-coded list; Sonnet=T2 is withdrawn). hk 2290 retired the skill copies
# of that block (the catalog is pacelever/scopefuel, not a skill); what stays
# here is the launcher side: bin/wrk must not refuse a max rung on a builder seat
# (hk 1864, operator 2026-10-23, superseding the 09-26 no-max rule; ultra stays
# refused) and still default builder-sol to high; gate_policy.json must agree;
# the README must not claim a marked rung needs a REF. Every mutant weakens one
# row in-memory and must go RED by assertion — repository files are never
# modified.
set -euo pipefail
# hk 1894: trust-bearing wrk and arbiter commands honour this suite's temp-dir overrides
# (HOME, ARBITER_INBOX_ROOT, XDG_DATA_HOME, HANDOFFKEEP_BIN) only in test mode.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json
import os
import re
import sys

root = Path(sys.argv[1])
paths = {
    "readme": root / "README.md",
    "wrk": root / "bin/wrk",
    "policy": root / "director/gate_policy.json",
}
docs = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}



def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


KIMI_IMPORT_GUARD_ERROR = (
    "wrk: the kimi resolver must import tomllib inside kimi_clone_resolved_effort"
)


def kimi_resolver_body(text: str) -> str:
    match = re.search(
        r"(?ms)^kimi_clone_resolved_effort\(\) \{\n(?P<body>.*?)^\}", text
    )
    return match.group("body") if match else ""


def has_kimi_tomllib_import(text: str) -> bool:
    body = kimi_resolver_body(text)
    return bool(body and re.search(r"(?m)^[ \t]*import[ \t]+tomllib\b", body))






# hk 1864: the launcher's help and comments must not claim a builder seat
# never takes a max rung or that the max spellings are closed.
WRK_FORBIDDEN = [
    ("wrk-max-seat-closed",
     r"a builder seat never takes a max rung|builder seats never take a max rung|max-rung E6 spellings\s+\(builder-sonnet-max[^)]*\) are closed|no-max rule[^\n]{0,80}?named exception|seat rule's only named exception|inert for builders since the seat rule|seat-rule exemption in resolve_profile"),
]

# #748 (post-#740 codex tester finding): on an explicit --effort rung the
# installed gate judges quota rules and shows the escalation tag — it never
# enforces a --operator-request REF there (scopefuel #716). The stale claim
# that a marked rung "needs a REF" is forbidden wherever it appeared; the
# negated forms ("요구하지 않는다", "no ... enforced") stay legal.
REF_REQUIRED_FORBIDDEN = [
    ("ref-required-en",
     r"(?:needs?|requires?|demands?|must)\s+(?:an?\s+|the\s+|a\s+)?--operator-request"),
    ("ref-required-en-passive",
     r"--operator-request`?\s+(?:is|are)\s+(?:required|needed|mandatory)"),
    ("ref-required-ko",
     r"--operator-request`?\s*가\s*(?:추가로\s+)?필요(?:하다|함)|--operator-request`?\s*를\s*요구한다"),
    ("ref-required-escalation",
     r"에스컬레이션[^\n]{0,40}?--operator-request[^\n]{0,15}?추가"),
]

EXPLICIT_RUNG_NO_REF = (
    r"명시[^\n]{0,20}?--effort[^\n]{0,60}?--operator-request[^\n]{0,40}?요구하지 않는다"
)



def check(d: dict) -> None:
    # The launcher text must not claim a closed max-rung builder opens.
    wrk_flat = flat(d["wrk"])
    for row, pattern in WRK_FORBIDDEN:
        assert not re.search(pattern, wrk_flat), (
            f"wrk: forbidden wording reintroduced ({row}): "
            f"{re.search(pattern, wrk_flat).group(0)!r}"
        )
    # #748: the stale "marked rung needs a REF" claim may not appear in any
    # scanned doc, and the corrected #716 wording must be where the rungs are
    # documented (README note, wrk help).
    for name in ("wrk", "readme"):
        for row, pattern in REF_REQUIRED_FORBIDDEN:
            assert not re.search(pattern, flat(d[name])), (
                f"{name}: stale REF-required claim reintroduced ({row}): "
                f"{re.search(pattern, flat(d[name])).group(0)!r}"
            )
    for name in ("readme",):
        assert re.search(EXPLICIT_RUNG_NO_REF, flat(d[name])), (
            f"{name}: #716 explicit-rung no-REF wording missing"
        )
    assert re.search(
        r"explicit --effort rung[^\n]{0,80}?quota rules[^\n]{0,80}?no --operator-request[^\n]{0,40}?enforced",
        wrk_flat,
    ), "wrk: help must say explicit rungs are quota-judged with no REF enforced"

    # bin/wrk: the builder-seat rule (ultra only since hk 1864) must sit on the
    # resolved effort, and builder-sol must resolve/catalog-pin at high. The kimi home read below
    # is what lets the unflagged kimi spellings reach the same case arm.
    wrk = flat(d["wrk"])
    assert "builder seats never take an ultra rung" in wrk, (
        "wrk: builder-seat ultra refusal message missing"
    )
    assert "builder seats never take a max rung" not in wrk, (
        "wrk: the repealed builder-seat max refusal text is back"
    )
    assert re.search(
        r"ROLE:-worker.{0,40}?builder.{0,60}?local seat_effort=\"\$EFFECTIVE_EFFORT\".{0,900}?case \"\$seat_effort\" in ultra\)",
        wrk,
    ), (
        "wrk: the seat rule must gate on role=builder and refuse resolved ultra only (max is open since hk 1864)"
    )
    # #748: builder-kimi/kimi-k3 leave EFFECTIVE_EFFORT empty — the seat rule
    # must read the kimi home's resolved effort or a max home slips through.
    assert re.search(
        r"-z \"\$seat_effort\" && \"\$PROFILE_KIND\" == kimi.{0,900}?kimi_clone_resolved_effort \"\$\{KIMI_TRUST_HOME:-\}/config\.toml\" \"\$kimi_model\"",
        wrk,
    ), (
        "wrk: an empty resolved effort on a kimi profile must read the home's resolved effort for the seat rule"
    )
    # #748r2 (tester round 1): the resolution must honour TOML literal
    # (single-quoted) strings and the model default_effort fallback with
    # support_efforts membership — a double-quote-only scan or a
    # thinking-only read leaves valid max homes admitted.
    assert "default_effort" in wrk and "support_efforts" in wrk, (
        "wrk: the kimi seat read must fall back to the model's default_effort honouring support_efforts"
    )
    assert re.search(
        r"m_seen && \(t == \"\" \|\| \(s_seen && !\(t in S\)\)\)\) r = d",
        wrk,
    ), "wrk: the kimi resolver must substitute default_effort for missing/unsupported requests"
    assert re.search(r"substr\(s, 1, 1\) == sq", wrk), (
        "wrk: the kimi resolver must parse TOML literal (single-quoted) strings"
    )
    # #748r3 (tester round 2): the resolution must be a real TOML parse —
    # dotted keys, inline tables, escapes, multiline strings and indented
    # headers are equivalent spellings an awk scan cannot fully cover — plus
    # the documented env overlay, Thinking disabled→off_effort, and the
    # [models."<id>".overrides] table.
    assert has_kimi_tomllib_import(d["wrk"]), KIMI_IMPORT_GUARD_ERROR
    assert re.search(
        r"resolved not in support\)\): resolved = default",
        wrk,
    ), "wrk: the kimi resolver must fall back to default_effort for missing/unsupported requests"
    assert 'env_eff="${KIMI_MODEL_THINKING_EFFORT:-}"' in wrk, (
        "wrk: the kimi resolver must honour the KIMI_MODEL_THINKING_EFFORT overlay"
    )
    assert 'thinking.get("enabled") is False' in wrk, (
        "wrk: the kimi resolver must resolve disabled Thinking to off_effort"
    )
    assert 'model.get("overrides")' in wrk, (
        "wrk: the kimi resolver must honour the model overrides table"
    )
    assert 'pick("off_effort")' in wrk, (
        "wrk: the kimi resolver must read the model off_effort"
    )
    # always-thinking also arrives as a capabilities tag, not only a boolean
    # field; effort="off" is a valid off spelling; and the env overlay is
    # bounded to documented rung spellings before it is honoured.
    assert '"always_thinking" in caps' in wrk, (
        "wrk: the kimi resolver must honour the always_thinking capability tag"
    )
    assert 'if effort == "off" and not always:' in wrk, (
        "wrk: the kimi resolver must treat effort=off as Thinking off"
    )
    assert '"xhigh", "max", "ultra", "off", "on"' in wrk, (
        "wrk: the kimi resolver must bound the env overlay to documented rung spellings"
    )
    # CodeRabbit #153: with no readable config the env value alone resolves —
    # it must be bounded and normalized like the real parse or MAX bypasses
    # the case-sensitive seat match; the E6 pinned clone must exist before
    # its effort is compared (the env overlay cannot stand in for it); and
    # the awk overrides strip must anchor at the suffix, not eat the model
    # id's closing quote.
    assert re.search(
        r'! -r "\$cfg".{0,600}?tr .\[:upper:\]. .\[:lower:\].',
        wrk,
    ), "wrk: the no-config env path must normalize the effort value"
    assert 'minimal|low|medium|high|xhigh|max|ultra|off|on) printf' in wrk, (
        "wrk: the no-config env path must bound the effort value to documented rungs"
    )
    assert 'printf \'%s\\n\' "$norm"' in wrk, (
        "wrk: the no-config env path must print the normalized value, not the raw env"
    )
    assert re.search(
        r'-r "\$KIMI_TRUST_HOME/config\.toml".{0,200}?config\.toml missing',
        wrk,
    ), "wrk: the E6 pinned kimi clone must fail closed on a missing config.toml"
    assert 'sub(/\\.overrides$/, "", mh)' in wrk, (
        "wrk: the awk overrides strip must anchor at the suffix, not eat the closing quote"
    )
    assert re.search(
        r"builder-sol\|captain-sol\)\s*PROFILE_KIND=codex;\s*PROFILE_MODEL=gpt-6\.1-sol;\s*DEFAULT_EFFORT=high",
        wrk,
    ), "wrk: builder-sol must default to effort high"
    assert "builder-sol|captain-sol) CATALOG_PROFILE=codex-sol; CATALOG_EFFORT_PIN=high" in d["wrk"], (
        "wrk: builder-sol must consult the catalog at the high rung"
    )

    # gate_policy.json agrees: builder-sol/captain-sol default high.
    policy = json.loads(d["policy"])
    for alias in ("builder-sol", "captain-sol"):
        assert policy["profiles"][alias]["default_effort"] == "high", (
            f"gate_policy: {alias} default_effort must be high (builder seats default high)"
        )


check(docs)
print(
    "PASS assignment-defaults wrk+readme+policy consistent"
)


def mutate(name: str, old: str, new: str) -> dict:
    doc = dict(docs)
    assert doc[name].count(old) >= 1, f"fixture: {old!r} not in {name}"
    doc[name] = doc[name].replace(old, new, 1)
    return doc


def disable_kimi_parser_imports(doc: dict) -> dict:
    mutant = dict(doc)
    text = mutant["wrk"]
    match = re.search(
        r"(?ms)^kimi_clone_resolved_effort\(\) \{\n(?P<body>.*?)^\}", text
    )
    assert match, "fixture: kimi_clone_resolved_effort function missing"
    body = match.group("body")
    for old in ("    import tomllib\n", "    import tomli as tomllib\n"):
        assert body.count(old) == 1, f"fixture: expected one Kimi import {old!r}"
        body = body.replace(old, "    parser = None\n", 1)
    mutant["wrk"] = text[: match.start("body")] + body + text[match.end("body") :]
    return mutant


def add_import_in_function(doc: dict, function: str, anchor: str, line: str) -> dict:
    mutant = dict(doc)
    text = mutant["wrk"]
    match = re.search(
        rf"(?ms)^{re.escape(function)}\(\) \{{\n(?P<body>.*?)^\}}", text
    )
    assert match, f"fixture: {function} function missing"
    body = match.group("body")
    assert body.count(anchor) == 1, f"fixture: {anchor!r} is not unique in {function}"
    body = body.replace(anchor, anchor + line + "\n", 1)
    mutant["wrk"] = text[: match.start("body")] + body + text[match.end("body") :]
    return mutant


mutants = {}
mutants["wrk-help-max-closed-back"] = mutate(
    "wrk",
    "were closed by that decision;",
    "are closed — a builder seat never takes a max rung, marker or not;",
)
mutants["wrk-help-max-closed-list-back"] = mutate(
    "wrk",
    "builder-kimi-max,\n                     builder-haiku-max) are open builder\n                     seats since hk 1863 (the 2026-09-26 no-max refusal is\n                     removed)",
    "builder-kimi-max,\n                     builder-haiku-max) are closed builder\n                     seats (the 2026-09-26 no-max refusal is\n                     removed)",
)
mutants["wrk-seat-rule-removed"] = mutate(
    "wrk",
    'if [[ "${ROLE:-worker}" == builder ]]; then',
    "if false; then",
)
mutants["wrk-seat-rule-ultra-dropped"] = mutate(
    "wrk",
    '    case "$seat_effort" in\n      ultra)',
    '    case "$seat_effort" in\n      never)',
)
# hk 1864: restoring the repealed max refusal must go RED.
mutants["wrk-seat-rule-max-restored"] = mutate(
    "wrk",
    '    case "$seat_effort" in\n      ultra)',
    '    case "$seat_effort" in\n      max|ultra)',
)
mutants["wrk-seat-rule-max-message-restored"] = mutate(
    "wrk",
    "builder seats never take an ultra rung (max is allowed since hk 1863)",
    "builder seats never take a max rung (operator decision 2026-09-26)",
)
# #748: a seat rule that stops reading the kimi home leaves the unflagged
# kimi spellings blind to a max-effort home.
mutants["wrk-seat-rule-kimi-blind"] = mutate(
    "wrk",
    'seat_effort="$(kimi_clone_resolved_effort "${KIMI_TRUST_HOME:-}/config.toml" "$kimi_model")"',
    'seat_effort=""',
)
# #748r2: dropping the default_effort fallback or the literal-string parse
# reopens the tester-found max-home paths.
mutants["wrk-seat-rule-no-model-default"] = mutate(
    "wrk",
    'if (m_seen && (t == "" || (s_seen && !(t in S)))) r = d',
    'r = t',
)
mutants["wrk-seat-rule-no-literal-string"] = mutate(
    "wrk",
    "if (substr(s, 1, 1) == sq && substr(s, length(s), 1) == sq)\n        return substr(s, 2, length(s) - 2)",
    'return ""',
)
# #748r3: dropping the real TOML parse, the env overlay, disabled-Thinking or
# the overrides table reopens the round-2 paths. The python
# `resolved = default` is the primary-path default fallback the awk `r = d`
# mutant above covers for the degraded path.
mutants["wrk-seat-rule-no-real-toml"] = mutate(
    "wrk",
    "    import tomllib",
    "    import os as tomllib",
)
# The guard is about the parser import inside the Kimi resolver. Keep the
# original no-real-TOML mutant red, then prove unrelated placements cannot
# satisfy it after every real Kimi parser import is removed.
kimi_without_parsers = disable_kimi_parser_imports(docs)
mutants["wrk-kimi-parser-no-parser"] = kimi_without_parsers
mutants["wrk-kimi-parser-codex-p1"] = add_import_in_function(
    kimi_without_parsers,
    "codex_seed_project_trust",
    "    import importlib\n",
    "    import tomllib as _placement_probe",
)
mutants["wrk-kimi-parser-codex-p2"] = add_import_in_function(
    kimi_without_parsers,
    "codex_seed_project_trust",
    "    import importlib\n",
    "    import tomllib as parser",
)
mutants["wrk-kimi-parser-claude-placement"] = add_import_in_function(
    kimi_without_parsers,
    "claude_seed_folder_trust",
    "import json\n",
    "import tomli as tomllib",
)
KIMI_IMPORT_GUARD_MUTANTS = {
    "wrk-seat-rule-no-real-toml",
    "wrk-kimi-parser-no-parser",
    "wrk-kimi-parser-codex-p1",
    "wrk-kimi-parser-codex-p2",
    "wrk-kimi-parser-claude-placement",
}
mutants["wrk-seat-rule-py-no-model-default"] = mutate(
    "wrk",
    "    resolved = default",
    "    resolved = effort",
)
mutants["wrk-seat-rule-env-blind"] = mutate(
    "wrk",
    'env_eff="${KIMI_MODEL_THINKING_EFFORT:-}"',
    'env_eff=""',
)
mutants["wrk-seat-rule-enabled-ignored"] = mutate(
    "wrk",
    'if thinking.get("enabled") is False and not always:',
    "if False:",
)
mutants["wrk-seat-rule-overrides-dropped"] = mutate(
    "wrk",
    'over = table(model.get("overrides"))',
    "over = {}",
)
# The capabilities-tag always shape, the bounded env list and effort=off all
# gate refusal paths; dropping any reopens a round-3 attack.
mutants["wrk-seat-rule-no-cap-always"] = mutate(
    "wrk",
    '"always_thinking" in caps',
    "False",
)
mutants["wrk-seat-rule-env-unbounded"] = mutate(
    "wrk",
    'if env_eff in {"minimal", "low", "medium", "high", "xhigh", "max", "ultra", "off", "on"}:',
    "if env_eff:",
)
mutants["wrk-seat-rule-off-ignored"] = mutate(
    "wrk",
    'if effort == "off" and not always:',
    "if False:",
)
# CodeRabbit #153: an unbounded env passthrough on the no-config path, an env
# stand-in for a missing pinned clone, and a quote-eating overrides strip
# each reopen a refusal path the tester or reviewer already demonstrated.
mutants["wrk-seat-rule-env-unbounded-nocfg"] = mutate(
    "wrk",
    "minimal|low|medium|high|xhigh|max|ultra|off|on",
    "minimal|low|medium|high",
)
mutants["wrk-e6-clone-env-standin"] = mutate(
    "wrk",
    '        [[ -r "$KIMI_TRUST_HOME/config.toml" ]] ||\n'
    '          die "$MODEL needs a $GATE_EFFORT_PIN-effort Kimi clone at $KIMI_TRUST_HOME (config.toml missing); refresh it with: bin/kimi-clone-home --effort $GATE_EFFORT_PIN"\n',
    "",
)
mutants["wrk-seat-rule-env-raw-nocfg"] = mutate(
    "wrk",
    'printf \'%s\\n\' "$norm"',
    'printf \'%s\\n\' "$env_eff"',
)
mutants["wrk-seat-rule-awk-overrides-quote"] = mutate(
    "wrk",
    'sub(/\\.overrides$/, "", mh)',
    'sub(/[."]?\\.overrides.*$/, "", mh)',
)
mutants["readme-ref-required-back"] = mutate(
    "readme",
    "`--operator-request` REF를 요구하지 않는다",
    "`--operator-request` 추가",
)
mutants["wrk-ref-required-back"] = mutate(
    "wrk",
    "so no --operator-request REF is enforced there",
    "additionally need --operator-request REF",
)
mutants["wrk-builder-sol-back-to-max"] = mutate(
    "wrk",
    "builder-sol|captain-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6.1-sol; DEFAULT_EFFORT=high",
    "builder-sol|captain-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6.1-sol; DEFAULT_EFFORT=max",
)
mutants["policy-builder-sol-back-to-max"] = mutate(
    "policy",
    '"builder-sol": {\n      "default_effort": "high"',
    '"builder-sol": {\n      "default_effort": "max"',
)

for name, doc in mutants.items():
    try:
        check(doc)
    except AssertionError as exc:
        if name in KIMI_IMPORT_GUARD_MUTANTS:
            assert str(exc) == KIMI_IMPORT_GUARD_ERROR, (
                f"{name} went RED for the wrong reason: {exc}"
            )
            print(f"RED {name} (Kimi parser guard)")
        else:
            print(f"RED {name}")
        continue
    raise SystemExit(f"mutant {name} did not go RED")
print(f"PASS mutants assertion-red={len(mutants)}/{len(mutants)}")
PY

# ---------------------------------------------------------------------------
# Runtime half: the seat rule and the new builder-sol default must hold in a
# real spawn against the fixtures (the mutants above cover text drift only).
# ---------------------------------------------------------------------------
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
TMP="$(mktemp -d)"
# shellcheck disable=SC1091
. "$ROOT/tests/lib/tmp-writers.sh"
export TW_TMP="$TMP"
# wrk spawn's refresh_quota_pool leaves a detached supervisor — `( python3 -
# … ) &` -> fork + setsid -> `scopefuel refresh <pool> --background` — which
# appends WRK_REFRESH_LOG. It names itself in <job>/quota-refresh.pid, and
# the scopefuel child logs its own pid to WRK_REFRESH_PID_LOG. A dentry
# recreated while rm walks the tree exits `rm -rf` with "Directory not empty"
# (CI runs 36283072131/36288704921), so tests/lib/tmp-writers.sh reaps every
# tracked writer by exact verified pid before the rm — never a process-table
# pattern match or another process's environment.
cleanup() {
  local tw_rc=0
  tmp_writers_stop || tw_rc=$?
  (( tw_rc == 0 )) && rm -rf "$TMP"
  if [[ "$tw_rc" -ne 0 || -n "${TW_LEFTOVER_PIDS:-}" ]]; then
    echo "FAIL: tracked writers survived teardown:${TW_LEFTOVER_PIDS:-}" >&2
    exit 1
  fi
}
trap cleanup EXIT
PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"
export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/xdg-data"
export XDG_CACHE_HOME="$TMP/xdg-cache"
export XDG_CONFIG_HOME="$TMP/xdg-config"
export XDG_STATE_HOME="$TMP/xdg-state"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"

# #768: spawns bind an hk task — the deterministic fixture stands in for
# handoffkeep and spawn_t736 mints a fresh --task per call, which covers the
# --role builder cases (builder requires an explicit --task, never env
# inheritance).
export HANDOFFKEEP_BIN="$ROOT/tests/fixtures/handoffkeep"
export HK_STATE="$TMP/hk-state.json"

spawn_t736() {
  local model="$1"; shift
  : >"$TMP/herdr.log"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$TMP/absent-arbiter" XDG_DATA_HOME="$TMP/xdg" \
    XDG_CACHE_HOME="$TMP/xdg-cache" XDG_CONFIG_HOME="$TMP/xdg-config" \
    XDG_STATE_HOME="$TMP/xdg-state" HOME="$TMP/home" \
    ARBITER_INBOX_ROOT="$TMP/inbox" WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml" \
    PANEWIRE_BIN="$ROOT/tests/fixtures/panewire" \
    WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_LAUNCH_LOG="$TMP/launch.log" \
    WRK_REFRESH_LOG="$TMP/refresh.log" WRK_REFRESH_PID_LOG="$TMP/refresh.pids" \
    WRK_REFRESH_TIMEOUT_S=5 \
    "$ROOT/bin/wrk" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture --t T1 \
    --task "$("$HANDOFFKEEP_BIN" tasks add --title "t736 task" 2>/dev/null |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" "$@"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# builder-sol under --role builder now launches codex-sol at effort high and
# consults the catalog at high (was max before 2026-09-26).
: >"$TMP/launch.log"
spawn_t736 builder-sol --role builder --lane builder-lane --parent parent-lane \
  --job t736-builder-sol >/dev/null
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-sol must launch at effort high: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-sol effort=high' "$TMP/launch.log" ||
  fail "builder-sol must consult codex-sol at effort high: $(cat "$TMP/launch.log")"
echo "PASS builder-sol launches codex-sol@high and consults the catalog at high"

# hk 2043 item 4: builder-sol consults codex-sol@high, so an explicit --effort
# other than high is refused with one line naming the matching pinned spelling.
# This closes the silent override the hk 1864 seat-rule admission left open.
set +e
out="$(spawn_t736 builder-sol --role builder --lane builder-lane --parent parent-lane \
  --effort max --job t736-builder-sol-max 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "builder-sol --effort max must be refused (rc=$rc): $out"
grep -qF 'use builder-sol-max for --effort max' <<<"$out" ||
  fail "builder-sol --effort max refusal must name builder-sol-max: $out"
set +e
out="$(spawn_t736 builder-sol --role builder --lane builder-lane --parent parent-lane \
  --effort xhigh --job t736-builder-sol-xhigh 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "builder-sol --effort xhigh must be refused (rc=$rc): $out"
grep -qF 'use builder-sol-xhigh for --effort xhigh' <<<"$out" ||
  fail "builder-sol --effort xhigh refusal must name builder-sol-xhigh: $out"
echo "PASS builder-sol refuses an off-consult --effort and names the pinned spelling (hk 2043)"

# codex `ultra` is the max tier plus subagents — the seat rule still refuses
# it (hk 1864 opened max only).
set +e
out="$(spawn_t736 builder-sol --role builder --lane builder-lane --parent parent-lane \
  --effort ultra --job t736-builder-sol-ultra 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "builder-sol --effort ultra must die rc 2 (rc=$rc): $out"
grep -q 'builder seats never take an ultra rung' <<<"$out" ||
  fail "builder-sol --effort ultra refusal must name the seat rule: $out"
echo "PASS builder-sol --effort ultra still dies on the builder-seat rule"

# hk 2043 (operator r1026solmax): builder-sol-max is a NORMAL pinned spelling.
# It spawns with SCOPEFUEL_E6_ARM unset, gates at codex-sol@max (the S+
# gate=default row), launches max and consults the catalog at max. builder-sol-xhigh
# is the other normal pinned spelling; codex-sol@xhigh is an escalation rung at
# S+, so the gate still decides admission and the spawn carries a REF.
: >"$TMP/herdr.log"; : >"$TMP/launch.log"; : >"$TMP/scopefuel.log"
out="$(SCOPEFUEL_E6_ARM='' \
  spawn_t736 builder-sol-max --role builder --lane builder-lane --parent parent-lane \
  --job t736-e6-max 2>&1)" || fail "unmarked builder-sol-max must be admitted: $out"
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log" ||
  fail "builder-sol-max must launch at effort max: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-sol effort=max' "$TMP/launch.log" ||
  fail "builder-sol-max must consult codex-sol at max: $(cat "$TMP/launch.log")"
grep -qF 'gate -m codex-sol --effort max' "$TMP/scopefuel.log" ||
  fail "builder-sol-max must ask the gate about codex-sol@max: $(cat "$TMP/scopefuel.log")"
echo "PASS builder-sol-max spawns unmarked at the S+ gate=default row and records codex-sol@max"

: >"$TMP/herdr.log"; : >"$TMP/launch.log"; : >"$TMP/scopefuel.log"
set +e
out="$(SCOPEFUEL_E6_ARM='' \
  spawn_t736 builder-sol-xhigh --role builder --lane builder-lane --parent parent-lane \
  --job t736-sol-xhigh-bare 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 3 ]] ||
  fail "builder-sol-xhigh without --operator-request must hit the gate escalation refusal (rc=$rc): $out"
# The refused run wrote its own consult and gate lines; clear every log so the
# admitted-run assertions below can only be satisfied by the admitted run.
: >"$TMP/herdr.log"; : >"$TMP/launch.log"; : >"$TMP/scopefuel.log"
out="$(SCOPEFUEL_E6_ARM='' \
  spawn_t736 builder-sol-xhigh --role builder --lane builder-lane --parent parent-lane \
  --operator-request hk:task/2043 --job t736-sol-xhigh 2>&1)" ||
  fail "builder-sol-xhigh with an operator REF must be admitted: $out"
grep -q 'model_reasoning_effort=xhigh' "$TMP/herdr.log" ||
  fail "builder-sol-xhigh must launch at effort xhigh: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-sol effort=xhigh' "$TMP/launch.log" ||
  fail "builder-sol-xhigh must consult codex-sol at xhigh: $(cat "$TMP/launch.log")"
grep -qF 'gate -m codex-sol --effort xhigh' "$TMP/scopefuel.log" ||
  fail "builder-sol-xhigh must ask the gate about codex-sol@xhigh: $(cat "$TMP/scopefuel.log")"
echo "PASS builder-sol-xhigh spawns unmarked, records codex-sol@xhigh, and stays gate-decided at S+"

# hk 2043: builder-luna-high is an E6 measurement spelling like the low/medium
# pair — without SCOPEFUEL_E6_ARM=codex-luna@high it is refused.
set +e
out="$(SCOPEFUEL_E6_ARM='' \
  spawn_t736 builder-luna-high --role builder --lane builder-lane --parent parent-lane \
  --job t736-luna-high-bare 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "unmarked builder-luna-high must die rc 2 (rc=$rc): $out"
grep -q 'SCOPEFUEL_E6_ARM=codex-luna@high' <<<"$out" ||
  fail "unmarked builder-luna-high refusal must name the marker: $out"
: >"$TMP/herdr.log"; : >"$TMP/launch.log"
out="$(SCOPEFUEL_E6_ARM=codex-luna@high \
  spawn_t736 builder-luna-high --role builder --lane builder-lane --parent parent-lane \
  --job t736-luna-high 2>&1)" || fail "armed builder-luna-high must be admitted: $out"
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-luna-high must launch at effort high: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-luna effort=high' "$TMP/launch.log" ||
  fail "builder-luna-high must consult codex-luna at high: $(cat "$TMP/launch.log")"
echo "PASS builder-luna-high is marker-gated and records codex-luna@high"

# hk 2043 item 5b: builder-haiku-medium (r1026effdown arm B, haiku@high vs
# haiku@medium) is an E6 measurement spelling like builder-haiku-low — without
# SCOPEFUEL_E6_ARM=haiku@medium it is refused; with it the spawn gates and
# consults at haiku@medium.
set +e
out="$(SCOPEFUEL_E6_ARM='' \
  spawn_t736 builder-haiku-medium --role builder --lane builder-lane --parent parent-lane \
  --job t736-haiku-medium-bare 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "unmarked builder-haiku-medium must die rc 2 (rc=$rc): $out"
grep -q 'SCOPEFUEL_E6_ARM=haiku@medium' <<<"$out" ||
  fail "unmarked builder-haiku-medium refusal must name the marker: $out"
: >"$TMP/herdr.log"; : >"$TMP/launch.log"; : >"$TMP/scopefuel.log"
out="$(SCOPEFUEL_E6_ARM=haiku@medium \
  spawn_t736 builder-haiku-medium --role builder --lane builder-lane --parent parent-lane \
  --job t736-haiku-medium 2>&1)" || fail "armed builder-haiku-medium must be admitted: $out"
grep -q -- '--effort medium' "$TMP/herdr.log" ||
  fail "builder-haiku-medium must launch at effort medium: $(cat "$TMP/herdr.log")"
grep -q 'policy launch haiku effort=medium' "$TMP/launch.log" ||
  fail "builder-haiku-medium must consult haiku at medium: $(cat "$TMP/launch.log")"
grep -qF 'gate -m haiku --effort medium' "$TMP/scopefuel.log" ||
  fail "builder-haiku-medium must ask the gate about haiku@medium: $(cat "$TMP/scopefuel.log")"
echo "PASS builder-haiku-medium is marker-gated and records haiku@medium"

# Worker-side names keep working: a bare codex-sol worker spawn still resolves
# (the seat rule is builder-scoped), running the Sol model argv.
spawn_t736 codex-sol --job t736-worker-sol >/dev/null
grep -q -- '-m gpt-6.1-sol' "$TMP/herdr.log" ||
  fail "worker codex-sol must resolve to gpt-6.1-sol (#1026): $(cat "$TMP/herdr.log")"
echo "PASS worker codex-sol spelling still resolves"

echo "PASS test-assignment-defaults (prose contract + wrk behavior + mutants)"
