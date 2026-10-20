"""Strict pane model labels and component billing provenance (no pane I/O)."""
from __future__ import annotations

import re

ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
BORDER = re.compile(r"^[│┃╭╰─\s]*")
EFFORT = r"(?:Low|Medium|High|Xhigh|Max)"
# A family/version followed by optional branding and an effort is a label.
# Prose such as 'Devin update available', 'Opus is thinking', or a prompt
# beginning with a model word cannot satisfy this anchored grammar.
PART = rf"(?:GPT[- ]\d+(?:\.\d+)*(?:[ -](?:Sol|Luna|Terra|Fast))*|(?:Claude\s+)?(?:Opus|Sonnet|Haiku|Fable)\s+\d+(?:\.\d+)*|SWE-\d+(?:\.\d+)*|DeepSeek\s+V\d+(?:\.\d+)*\s+(?:Flash|Pro)|GLM-\d+(?:\.\d+)*|Gemini\s+\d+(?:\.\d+)*\s+Argon|Grok\s+\d+(?:\.\d+)*|Kimi\s+K\d+(?:\.\d+)*)"
LABEL = re.compile(rf"{PART}(?:\s+(?:\({EFFORT}\)|{EFFORT}))?", re.IGNORECASE)
UNKNOWN_PART = re.compile(rf"[A-Za-z][A-Za-z0-9.-]*(?:\s+[A-Za-z0-9.-]+){{0,3}}\s+{EFFORT}", re.IGNORECASE)
# Role-specific tables, not a list of complete Fusion labels. 'anthropic'
# is the gate's canonical spelling for the Claude contributor family.
LEADS = (
    (r"GPT[- ]", "codex", "openai", None, "devin-linked"),
    (r"(?:Claude\s+)?(?:Opus|Sonnet|Haiku|Fable)\b", "devin", "anthropic", None, None),
)
SIDECARS = (
    (r"SWE-2(?=\s|$)", "devin", "cognition", "free", None),
    (r"GPT[- ]", "codex", "openai", None, "devin-linked"),
)
PLAIN = LEADS + (
    (r"SWE-2(?=\s|$)", "devin", "cognition", "free", None),
    (r"SWE-1\.7(?=\s|$)", "devin", "cognition", None, None),
    (r"DeepSeek\b", "devin", "deepseek", None, None),
    (r"GLM-", "devin", "zhipu", None, None),
    (r"Gemini\b", "devin", "google", None, None),
)


def label_body(raw: str) -> str:
    return BORDER.sub("", ANSI.sub("", raw)).strip().rstrip("│┃ ")


def _components(raw: str) -> list[str] | None:
    body = label_body(raw)
    fusion = re.fullmatch(r"Fusion\s*[·|—]\s*(.+?)\s*[◆•/]\s*(.+?)(?:\s+·\s+.*)?", body, re.IGNORECASE)
    if fusion:
        parts = list(fusion.groups())
        if all(LABEL.fullmatch(part) or UNKNOWN_PART.fullmatch(part) for part in parts):
            return parts
        return None
    # Ordinary harness footers carry path/mode metadata after the separator.
    model = body.split(" · ", 1)[0]
    if LABEL.fullmatch(model):
        return [model]
    return None


def latest_model_line(snapshot: str) -> str | None:
    """Newest genuine label in the caller's bounded last lines, retaining bytes."""
    return next((line for line in reversed(snapshot.splitlines()) if _components(line)), None)


def parse_model_line(raw: str) -> dict:
    labels = _components(raw)
    parts = []
    for index, label in enumerate(labels or []):
        table = PLAIN if len(labels) == 1 else LEADS if index == 0 else SIDECARS
        mapping = next((row[1:] for row in table if LABEL.fullmatch(label) and
                        re.match(row[0], label, re.IGNORECASE)), None)
        pool, family, bucket, account = mapping or (None, None, None, None)
        parts.append(dict(role="model" if len(labels) == 1 else "lead" if index == 0 else "sidekick",
                          label=label, pool=pool, family=family, bucket=bucket, account=account))
    attributed = bool(parts) and all(part["pool"] for part in parts)
    return dict(raw_line=raw, parts=parts, attributed=attributed,
                pools=sorted({part["pool"] for part in parts}) if attributed else [],
                families=sorted({part["family"] for part in parts}) if attributed else [])


def model_tokens(raw: str) -> list[str]:
    parts = _components(raw)
    return re.findall(r"[a-z0-9]+", " ".join(parts or [label_body(raw)]).casefold())


EXPECTED = {
    "devin-swe2": "SWE-2 High", "devin-swe2-medium": "SWE-2 Medium", "devin-swe2-max": "SWE-2 Max",
    "devin-swe17": "SWE-1.7", "devin-glm52": "GLM-5.2",
    "devin-ds41": "DeepSeek V4.1 Flash High", "devin-ds41-max": "DeepSeek V4.1 Flash Max",
    "devin-fusion-opus55": "Fusion · Claude Opus 5.5 ◆ SWE-2 Medium",
    "devin-fusion-sonnet55": "Fusion · Claude Sonnet 5.5 ◆ SWE-2 Medium",
    "devin-fusion-sol61": "Fusion · GPT-6.1 Sol ◆ SWE-2 Medium",
    "devin-fusion-sol61-xhigh": "Fusion · GPT-6.1 Sol ◆ SWE-2 Medium",
    "devin-argon": "Gemini 4 Argon High", "devin-argon-medium": "Gemini 4 Argon Medium",
    "devin-argon-low": "Gemini 4 Argon Low",
}


def expected_label(profile: str) -> str | None:
    return EXPECTED.get(profile.replace("builder-devin", "devin-swe2").replace("builder-ds41", "devin-ds41"))
