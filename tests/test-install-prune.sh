#!/usr/bin/env bash
# hk 2290: install.sh removes the links it created once their target is gone,
# so a host self-cleans on the next install after skills are deleted.
#   1. the repo's skill set is exactly wake + ops (regrowth is a deliberate act);
#   2. in a temporary HOME, a deleted skill dir, a skill dir that lost its
#      SKILL.md and a deleted bin/ tool lose their links in all targets, while
#      live links, links pointing outside the repo, and regular entries stay;
#   3. a rerun prunes nothing;
#   4. mutants of install.sh (prune call removed, repo-prefix guard removed,
#      SKILL.md check removed) go RED by assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── 1. skill set ─────────────────────────────────────────────────────────
skills="$(cd "$ROOT" && for d in */; do if [ -f "$d/SKILL.md" ]; then echo "${d%/}"; fi; done | sort | tr '\n' ' ')"
[[ "$skills" == "ops wake " ]] || fail "skill set must be exactly ops + wake, got: $skills"
echo "PASS skill-set ops+wake"

TARGETS=(.claude/skills .kiro/skills .gemini/skills .config/opencode/skills)

# make_repo DIR INSTALL_SH: a fake repo laid out like this one.
make_repo() {
  local repo="$1" script="$2"
  mkdir -p "$repo/bin"
  cp "$script" "$repo/install.sh"
  for s in wake ops oldskill gutted; do
    mkdir -p "$repo/$s"
    printf -- '---\nname: %s\n---\n' "$s" >"$repo/$s/SKILL.md"
  done
  mkdir -p "$repo/docs"   # no SKILL.md: never linked
  printf '#!/bin/sh\n' >"$repo/bin/tool-keep"
  printf '#!/bin/sh\n' >"$repo/bin/tool-gone"
  chmod +x "$repo/bin/"*
}

run_install() { # run_install REPO HOME -> stdout of install.sh
  env -i PATH=/usr/bin:/bin HOME="$2" bash "$1/install.sh" 2>/dev/null
}

# scenario SCRIPT LABEL: install, delete, reinstall; prints problems, one per line.
scenario() {
  local script="$1" label="$2" out t
  local repo="$TMP/$label/repo" home="$TMP/$label/home"
  make_repo "$repo" "$script"
  mkdir -p "$home/.claude/skills/user-dir"
  ln -s "$TMP/elsewhere/missing" "$home/.claude/skills/foreign"
  run_install "$repo" "$home" >/dev/null
  for t in "${TARGETS[@]}"; do
    [[ -L "$home/$t/oldskill" && -L "$home/$t/gutted" ]] || echo "setup: $t links missing"
  done
  rm -rf "$repo/oldskill" "$repo/bin/tool-gone"
  rm "$repo/gutted/SKILL.md"
  out="$(run_install "$repo" "$home")"
  for t in "${TARGETS[@]}"; do
    [[ -e "$home/$t/oldskill" || -L "$home/$t/oldskill" ]] && echo "$t/oldskill not pruned"
    [[ -L "$home/$t/gutted" ]] && echo "$t/gutted not pruned"
    [[ -L "$home/$t/wake" && -f "$home/$t/wake/SKILL.md" ]] || echo "$t/wake link lost"
    [[ -L "$home/$t/ops" ]] || echo "$t/ops link lost"
    [[ -e "$home/$t/docs" ]] && echo "$t/docs linked"
  done
  [[ -L "$home/.local/bin/tool-gone" ]] && echo "bin/tool-gone not pruned"
  [[ -L "$home/.local/bin/tool-keep" ]] || echo "bin/tool-keep link lost"
  [[ -L "$home/.claude/skills/foreign" ]] || echo "foreign link removed"
  [[ -d "$home/.claude/skills/user-dir" && ! -L "$home/.claude/skills/user-dir" ]] || echo "user dir removed"
  grep -q "pruned $home/.claude/skills/oldskill" <<<"$out" || echo "no pruned line for oldskill"
  out="$(run_install "$repo" "$home")"
  grep -q 'pruned ' <<<"$out" && echo "rerun pruned again"
  return 0
}

# ── 2./3. real install.sh ────────────────────────────────────────────────
problems="$(scenario "$ROOT/install.sh" real)"
[[ -z "$problems" ]] || fail "install.sh prune: $problems"
echo "PASS install prune: deleted, gutted and gone-bin links pruned in ${#TARGETS[@]} targets + ~/.local/bin; live, foreign and regular entries kept; rerun idempotent"

# ── 4. mutants ───────────────────────────────────────────────────────────
mutant() { # mutant LABEL SED-EXPR
  local copy="$TMP/install-$1.sh"
  sed "$2" "$ROOT/install.sh" >"$copy"
  cmp -s "$copy" "$ROOT/install.sh" && fail "fixture: mutant $1 did not change install.sh"
  [[ -n "$(scenario "$copy" "$1")" ]] || fail "mutant $1 did not go RED"
  echo "RED $1"
}
# The sed expressions match install.sh text literally; nothing should expand.
# shellcheck disable=SC2016
mutant prune-call-removed 's/^  prune_links "\$target" skill$/  :/'
mutant repo-prefix-guard-removed 's/^      \*) continue ;;$/      *) ;;/'
# shellcheck disable=SC2016
mutant skill-md-check-removed 's|^      \[ -f "\$dest/SKILL.md" \] && continue$|      [ -e "$dest" ] \&\& continue|'
# shellcheck disable=SC2016
mutant bin-prune-removed 's/^prune_links "\$HOME\/.local\/bin" bin$/:/'
echo "PASS mutants assertion-red=4/4"
