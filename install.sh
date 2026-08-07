#!/bin/bash
# agent-skills 설치 — 심링크 생성 + 의존성 검사
# 사용: ./install.sh [--check]
#   (repo는 ~/.agents/skills 에 clone되어 있어야 함 — codex가 이 경로를 직접 스캔)
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LINK_TARGETS=("$HOME/.claude/skills" "$HOME/.kiro/skills" "$HOME/.gemini/skills" "$HOME/.config/opencode/skills")

check_deps() {
  local ok=0
  echo "== 의존성 검사 =="
  for tool in "herdr:$HOME/.local/bin/herdr" "scopefuel:$(command -v scopefuel || true)" \
              "wrk:$HOME/.local/bin/wrk"; do
    name="${tool%%:*}"; path="${tool#*:}"
    if [ -n "$path" ] && [ -x "$path" ]; then echo "  ✓ $name ($path)"
    else echo "  ✗ $name — 미설치 (스킬 내 폴백 절차 참조)"; ok=1; fi
  done
  command -v wt >/dev/null 2>&1 || type wt >/dev/null 2>&1 \
    && echo "  ✓ wt" || echo "  △ wt — 셸 함수라 비로그인 셸에선 안 보일 수 있음 (폴백: git worktree add + 수동 .env)"
  if [ -n "${AGENT_SKILLS_DOMAIN:-}" ] && [ -d "$AGENT_SKILLS_DOMAIN" ]; then
    echo "  ✓ 도메인 오버레이: 있음 ($AGENT_SKILLS_DOMAIN)"
  else
    echo "  · 도메인 오버레이: 없음 (미설정 — 정상, 추상 규칙만 적용)"
  fi
  return $ok
}

if [ "${1:-}" = "--check" ]; then check_deps; exit $?; fi

if [ "$REPO_DIR" != "$HOME/.agents/skills" ]; then
  echo "⚠️  이 repo는 ~/.agents/skills 에 있어야 codex가 직접 스캔한다. 현재: $REPO_DIR" >&2
fi

echo "== bin/ 도구 심링크 =="
mkdir -p "$HOME/.local/bin"
for tool in "$REPO_DIR"/bin/*; do
  [ -x "$tool" ] && ln -sfn "$tool" "$HOME/.local/bin/$(basename "$tool")" \
    && echo "  ~/.local/bin/$(basename "$tool") -> $tool"
done

echo "== 심링크 생성 =="
for target in "${LINK_TARGETS[@]}"; do
  mkdir -p "$target"
  for skill in "$REPO_DIR"/*/; do
    name="$(basename "$skill")"
    [ -f "$skill/SKILL.md" ] || continue
    ln -sfn "$REPO_DIR/$name" "$target/$name"
    echo "  $target/$name -> $REPO_DIR/$name"
  done
done

check_deps || true
echo "완료. 각 에이전트 세션은 재시작 후 스킬 목록에 반영된다 (본문은 호출 시점에 읽힘)."
