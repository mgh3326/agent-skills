#!/bin/bash
# agent-skills 설치 — 심링크 생성 + 의존성 검사
# 사용: ./install.sh [--check [--probe]]
#   (repo는 ~/.agents/skills 에 clone되어 있어야 함 — codex가 이 경로를 직접 스캔)
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LINK_TARGETS=("$HOME/.claude/skills" "$HOME/.kiro/skills" "$HOME/.gemini/skills" "$HOME/.config/opencode/skills")

run_scopefuel() {
  local timeout_s="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$timeout_s" "$@"
  else
    "$@"
  fi
}

check_agent_clis() {
  local kind
  local kinds
  kinds="$(sed -n 's/.*PROFILE_KIND=\([a-z][a-z]*\).*/\1/p' "$REPO_DIR/bin/wrk" | sort -u)"
  echo "== 에이전트 CLI =="
  if [ -z "$kinds" ]; then
    echo "  ⚠️  bin/wrk에서 PROFILE_KIND를 파생하지 못함"
    return 0
  fi
  while IFS= read -r kind; do
    [ -n "$kind" ] || continue
    if command -v "$kind" >/dev/null 2>&1; then
      echo "  ✓ $kind ($(command -v "$kind"))"
    else
      echo "  · $kind — 미설치 (사용 가능한 풀로 배정)"
    fi
  done <<< "$kinds"
}

check_scopefuel_pools() {
  local probe="$1"
  local scopefuel_cmd
  local pools
  local pool
  local output
  local pool_names=()
  local cached_names=""
  local cache_path
  local chunk

  echo "== 풀 인증·쿼타 상태 =="
  scopefuel_cmd="$(command -v scopefuel || true)"
  if [ -z "$scopefuel_cmd" ] || [ ! -x "$scopefuel_cmd" ]; then
    echo "  ⚠️  scopefuel 미설치 — 풀 상태 미측정"
    return 0
  fi
  pools="$("$scopefuel_cmd" --list-providers 2>/dev/null || true)"
  if [ -z "$pools" ]; then
    echo "  ⚠️  scopefuel 풀 목록 조회 실패 — 풀 상태 미측정"
    return 0
  fi

  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    pool_names+=("$pool")
    if [ "$probe" = 1 ]; then
      cached_names="${cached_names:+$cached_names,}$pool"
    else
      # This is the scopefuel snapshot location, not a credential file.  We
      # only inspect whether a provider key exists; scopefuel renders status.
      cache_path="${SCOPEFUEL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/scopefuel/snapshots.json}"
      if [ -r "$cache_path" ] && grep -q '"'"$pool"'"[[:space:]]*:' "$cache_path"; then
        cached_names="${cached_names:+$cached_names,}$pool"
      fi
    fi
  done <<< "$pools"

  output=""
  if [ "$probe" = 1 ]; then
    output="$("$scopefuel_cmd" --brief --no-color --no-cache --only "$cached_names" 2>&1 || true)"
  elif [ -n "$cached_names" ]; then
    # A very long TTL makes this call cache-only after the key existence check.
    output="$("$scopefuel_cmd" --brief --no-color --cache-ttl 999999999 --only "$cached_names" 2>&1 || true)"
  fi
  output="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

  for pool in "${pool_names[@]}"; do
    if [ "$probe" = 0 ] && ! printf '%s\n' ",${cached_names}," | grep -q ",$pool,"; then
      echo "  · $pool: 미측정 (캐시 없음; --check --probe로 실측)"
      continue
    fi
    chunk="$(printf '%s' "$output" | sed -E "s/^\[[^]]+\][[:space:]]*//; s/.*(^|\\|)[[:space:]]*$pool[[:space:]]*/$pool /; s/[[:space:]]*\\|.*$//")"
    if [ -n "$chunk" ] && [ "$chunk" != "$output" ]; then
      echo "  $pool: $chunk"
    elif [ -n "$output" ] && printf '%s' "$output" | grep -q "$pool"; then
      echo "  $pool: $output"
    else
      echo "  ⚠️  $pool: scopefuel 조회 실패 — 미측정"
    fi
  done
}

check_deps() {
  local ok=0
  local probe=0
  [ "${2:-}" = "--probe" ] && probe=1
  [ "${1:-}" = "--probe" ] && probe=1
  echo "== 의존성 검사 =="
  for tool in "herdr:$HOME/.local/bin/herdr" "scopefuel:$(command -v scopefuel || true)" \
              "wrk:$HOME/.local/bin/wrk"; do
    name="${tool%%:*}"; path="${tool#*:}"
    if [ -n "$path" ] && [ -x "$path" ]; then echo "  ✓ $name ($path)"
    else
      echo "  ✗ $name — 미설치 (스킬 내 폴백 절차 참조)"
      # D2: quota/auth diagnostics are advisory and fail-open when scopefuel
      # is absent. herdr and wrk remain the required dependency gates.
      [ "$name" = scopefuel ] || ok=1
    fi
  done
  command -v wt >/dev/null 2>&1 || type wt >/dev/null 2>&1 \
    && echo "  ✓ wt" || echo "  △ wt — 셸 함수라 비로그인 셸에선 안 보일 수 있음 (폴백: git worktree add + 수동 .env)"
  if [ -n "${AGENT_SKILLS_DOMAIN:-}" ] && [ -d "$AGENT_SKILLS_DOMAIN" ]; then
    echo "  ✓ 도메인 오버레이: 있음 ($AGENT_SKILLS_DOMAIN)"
  else
    echo "  · 도메인 오버레이: 없음 (미설정 — 정상, 추상 규칙만 적용)"
  fi
  check_agent_clis
  check_scopefuel_pools "$probe"
  return $ok
}

if [ "${1:-}" = "--check" ]; then check_deps "$@"; exit $?; fi

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
