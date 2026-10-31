#!/bin/bash
# agent-skills 설치 — 심링크 생성 + 끊긴 심링크 정리 + 의존성 검사
# 사용: ./install.sh [--check [--probe] | --dry-run]
#   --dry-run: 만들 스킬 링크만 출력한다(파일·디렉토리·심링크를 쓰지 않음, 정리·의존성 검사 생략).
#   (repo는 ~/.agents/skills 에 clone되어 있어야 함 — codex가 이 경로를 직접 스캔)
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LINK_TARGETS=("$HOME/.claude/skills" "$HOME/.kiro/skills" "$HOME/.gemini/skills" "$HOME/.config/opencode/skills")
# codex scans ~/.agents/skills (this repo) directly, so top-level skills need no link there.
# Vendored skills sit nested under third_party/, which a direct scan is not known to reach,
# so they are also linked into codex's own skill dir.
CODEX_VENDOR_TARGET="$HOME/.codex/skills"
DRY_RUN=0

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
  for tool in "herdr:$HOME/.local/bin/herdr" "scopefuel:$(command -v scopefuel || true)"; do
    name="${tool%%:*}"; path="${tool#*:}"
    if [ -n "$path" ] && [ -x "$path" ]; then echo "  ✓ $name ($path)"
    else
      echo "  ✗ $name — 미설치 (스킬 내 폴백 절차 참조)"
      # D2: quota/auth diagnostics are advisory and fail-open when scopefuel
      # is absent. herdr remains the required dependency gate.
      [ "$name" = scopefuel ] || ok=1
    fi
  done
  # wake-method tools are optional until runtug leaves shadow migration.
  for name in runtug pacelever mergewake; do
    path="$(command -v "$name" || true)"
    if [ -n "$path" ]; then echo "  ✓ $name ($path)"
    else echo "  · $name — 미설치 (선택: wake 방식 도구)"; fi
  done
  command -v wt >/dev/null 2>&1 || type wt >/dev/null 2>&1 \
    && echo "  ✓ wt" || echo "  △ wt — 셸 함수라 비로그인 셸에선 안 보일 수 있음 (폴백: git worktree add + 수동 .env)"
  if [ -n "${AGENT_SKILLS_DOMAIN:-}" ] && [ -d "$AGENT_SKILLS_DOMAIN" ]; then
    echo "  ✓ 도메인 오버레이: 있음 ($AGENT_SKILLS_DOMAIN)"
  else
    echo "  · 도메인 오버레이: 없음 (미설정 — 정상, 추상 규칙만 적용)"
  fi
  check_scopefuel_pools "$probe"
  return $ok
}

# Remove the links an earlier install made that now dangle: a skill directory
# that was deleted or lost its SKILL.md, or a bin/ tool that is gone. Only
# symlinks whose target lies inside this repo are touched; regular files,
# directories and links that point elsewhere are left alone.
prune_links() {
  local dir="$1" kind="$2" link dest
  [ -d "$dir" ] || return 0
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    dest="$(readlink "$link")"
    case "$dest" in
      "$REPO_DIR"/*) ;;
      *) continue ;;
    esac
    if [ "$kind" = skill ]; then
      [ -f "$dest/SKILL.md" ] && continue
    else
      [ -e "$dest" ] && continue
    fi
    rm -f "$link" && echo "  pruned $link"
  done
}

# Vendored skills to link: the names in third_party/<vendor>/INSTALL (one per line, # comments),
# resolved to third_party/<vendor>/skills/<name>. Prints "name<TAB>dir"; a name that has no
# SKILL.md or collides with a top-level skill is reported on stderr and skipped.
vendored_skills() {
  local list name dir
  for list in "$REPO_DIR"/third_party/*/INSTALL; do
    [ -f "$list" ] || continue
    while IFS= read -r name; do
      case "$name" in ''|'#'*) continue ;; esac
      dir="$(dirname "$list")/skills/$name"
      if [ ! -f "$dir/SKILL.md" ]; then
        echo "  ⚠️  vendored skill '$name' listed in $list has no SKILL.md — skipped" >&2
      elif [ -f "$REPO_DIR/$name/SKILL.md" ]; then
        echo "  ⚠️  vendored skill '$name' collides with the top-level skill — skipped" >&2
      else
        printf '%s\t%s\n' "$name" "$dir"
      fi
    done < "$list"
  done
}

# link_skill TARGET NAME DIR: symlink DIR as TARGET/NAME (or just print it under --dry-run).
link_skill() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "  would link $1/$2 -> $3"
    return 0
  fi
  mkdir -p "$1"
  ln -sfn "$3" "$1/$2"
  echo "  $1/$2 -> $3"
}

link_skills() {
  local target skill name vname vdir
  for target in "${LINK_TARGETS[@]}"; do
    for skill in "$REPO_DIR"/*/; do
      name="$(basename "$skill")"
      [ -f "$skill/SKILL.md" ] || continue
      link_skill "$target" "$name" "$REPO_DIR/$name"
    done
    while IFS=$'\t' read -r vname vdir; do
      [ -n "$vname" ] && link_skill "$target" "$vname" "$vdir"
    done < <(vendored_skills)
  done
  for skill in "$REPO_DIR"/*/; do
    name="$(basename "$skill")"
    [ -f "$skill/SKILL.md" ] || continue
    [ "$DRY_RUN" = 1 ] && echo "  codex scans ~/.agents/skills directly: $REPO_DIR/$name"
  done
  while IFS=$'\t' read -r vname vdir; do
    [ -n "$vname" ] && link_skill "$CODEX_VENDOR_TARGET" "$vname" "$vdir"
  done < <(vendored_skills)
}

if [ "${1:-}" = "--check" ]; then check_deps "$@"; exit $?; fi
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  echo "== 심링크 생성 (dry-run: 아무것도 쓰지 않음) =="
  link_skills
  exit 0
fi

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
link_skills

echo "== 끊긴 심링크 정리 =="
prune_links "$HOME/.local/bin" bin
for target in "${LINK_TARGETS[@]}" "$CODEX_VENDOR_TARGET"; do
  prune_links "$target" skill
done

check_deps || true
echo "완료. 각 에이전트 세션은 재시작 후 스킬 목록에 반영된다 (본문은 호출 시점에 읽힘)."
