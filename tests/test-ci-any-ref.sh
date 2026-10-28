#!/usr/bin/env bash
# Dry-run harness for .github/workflows/ci-any-ref.yml (hk 2190).
# Proves, without a real GitHub run:
#   (a) checkout is exactly the input ref with no merge
#   (b) the commit status is posted on the resolved target sha, not the dispatch sha
#   (c) a non-resolving ref is refused
#   (d) the permissions block is minimal
# and that two mutants (merge main first; post on the dispatch sha) are RED.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
wf = (root / ".github/workflows/ci-any-ref.yml").read_text(encoding="utf-8")
ci = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")


def top_block(text: str, key: str) -> str:
    match = re.search(rf"(?m)^{key}:\n((?:  .*\n| *#.*\n|\s*\n)*)", text)
    assert match, f"missing top-level block {key!r}"
    return match.group(1)


def validate(wf_text: str, ci_text: str) -> None:
    on_block = top_block(wf_text, "on")
    triggers = re.findall(r"(?m)^  (\w[\w-]*):", on_block)
    assert triggers == ["workflow_dispatch"], f"ci-any-ref must be dispatch-only, got {triggers}"

    assert re.search(r"(?m)^      ref:\n(?:        .*\n)*        required: true", wf_text), \
        "input ref must be required"

    perms = top_block(wf_text, "permissions")
    perm_keys = dict(re.findall(r"(?m)^  (\w[\w-]*): (\w+)", perms))
    assert perm_keys == {"contents": "read", "statuses": "write"}, \
        f"permissions must be exactly contents:read + statuses:write, got {perm_keys}"

    conc = top_block(wf_text, "concurrency")
    assert "inputs.ref" in conc, "concurrency group must key on the target ref"
    assert "cancel-in-progress: true" in conc

    assert "uses: ./.github/workflows/ci.yml" in wf_text, \
        "must reuse ci.yml via workflow_call, not copy jobs"
    assert "ref: ${{ needs.resolve.outputs.sha }}" in wf_text, \
        "reusable call must pass the resolved sha"
    assert "suite: ${{ inputs.suite }}" in wf_text

    # status target: must be the resolved sha, never github.sha / the dispatch sha.
    assert "statuses/${TARGET_SHA}" in wf_text, "status must post to statuses/<target sha>"
    assert "TARGET_SHA: ${{ needs.resolve.outputs.sha }}" in wf_text
    status_section = wf_text.split("status:", 1)[1]
    assert "github.sha" not in status_section and "github.event" not in status_section, \
        "status job must not derive its target from github.sha"

    # exact checkout: every checkout in ci.yml honors inputs.ref; no merge anywhere.
    n_checkout = len(re.findall(r"uses: actions/checkout@v4", ci_text))
    n_ref = len(re.findall(r"ref: \$\{\{ inputs\.ref \}\}", ci_text))
    assert n_checkout > 0 and n_checkout == n_ref, \
        f"every checkout must pin inputs.ref ({n_ref}/{n_checkout})"
    assert "git merge" not in ci_text and "git pull" not in ci_text, \
        "workflow must not merge main into the checkout"
    assert "workflow_call:" in ci_text
    assert "actions/checkout" not in wf_text.split("ci:", 1)[1].split("status:", 1)[0], \
        "the reusable call must not re-checkout"
    assert "git merge" not in wf_text and "git pull" not in wf_text


validate(wf, ci)

# Mutant 1: merge main into the checkout -> must be RED.
mutant_merge = ci.replace(
    "          ref: ${{ inputs.ref }}",
    "          ref: ${{ inputs.ref }}\n      - run: git merge origin/main",
    1,
)
try:
    validate(wf, mutant_merge)
except AssertionError:
    pass
else:
    raise AssertionError("mutant(merge-main) went undetected")

# Mutant 2: post the status on the dispatch sha -> must be RED.
mutant_status = wf.replace(
    "TARGET_SHA: ${{ needs.resolve.outputs.sha }}",
    "TARGET_SHA: ${{ github.sha }}",
)
try:
    validate(wf, mutant_status)
except AssertionError:
    pass
else:
    raise AssertionError("mutant(status-on-dispatch-sha) went undetected")

print("structural checks ok (incl. 2 mutants)")
PY

# --- live-ish harness: resolver + checkout simulation against a fixture repo ---
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixture: base commit A, then main advances to B. Target sha = A.
fixture="$tmp/fixture"
git init -q -b main "$fixture"
(
  cd "$fixture"
  git config user.email t@t && git config user.name t
  echo base > file.txt
  git add file.txt && git commit -qm base
  echo newer > newer.txt
  git add newer.txt && git commit -qm main-advance
)
SHA_A="$(git -C "$fixture" rev-parse HEAD~1)"
SHA_B="$(git -C "$fixture" rev-parse HEAD)"

# Fake gh: resolves refs from a map; unknown refs fail like the real API.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
arg="\$*"
case "\$arg" in
  "api repos/o/r/commits/$SHA_A --jq .sha") echo "$SHA_A" ;;
  "api repos/o/r/commits/old-branch --jq .sha") echo "$SHA_A" ;;
  "api repos/o/r/statuses/"*) echo "\$arg" > "$tmp/status-call" ;;
  *) echo "Not Found" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# (c) resolution: sha, branch name, and a refusal.
[[ "$("$root/scripts/resolve-ci-ref" "$SHA_A" o/r)" == "$SHA_A" ]]
[[ "$("$root/scripts/resolve-ci-ref" old-branch o/r)" == "$SHA_A" ]]
if "$root/scripts/resolve-ci-ref" does-not-exist o/r >/dev/null 2>&1; then
  echo "non-resolving ref was not refused" >&2; exit 1
fi

# (a) exact checkout simulation: clone, checkout resolved sha -> detached at A.
git clone -q "$fixture" "$tmp/co" 2>/dev/null
git -C "$tmp/co" -c advice.detachedHead=false checkout -q "$SHA_A"
[[ "$(git -C "$tmp/co" rev-parse HEAD)" == "$SHA_A" ]]
[[ -f "$tmp/co/file.txt" && ! -f "$tmp/co/newer.txt" ]]  # old base content, not main's

# mutant sanity: merging main first moves HEAD off A.
git -C "$tmp/co" -c advice.detachedHead=false checkout -qb mutant "$SHA_A"
git -C "$tmp/co" merge -qm mutant "$SHA_B" >/dev/null
[[ "$(git -C "$tmp/co" rev-parse HEAD)" != "$SHA_A" ]]

# (b) status target: simulate the status step against the resolved sha.
TARGET_SHA="$SHA_A"
gh api "repos/o/r/statuses/${TARGET_SHA}" -f state=success -f context=ci-ok -f target_url=run-url >/dev/null
grep -q "statuses/$SHA_A" "$tmp/status-call"
if grep -q "statuses/$SHA_B" "$tmp/status-call"; then
  echo "status was posted on the dispatch sha, not the target" >&2; exit 1
fi

echo "harness checks ok"
