# agent-skills — 크로스에이전트 오케스트레이션 스킬 정본

멀티에이전트 오케스트레이션(herdr 대장-워커 체계)의 반복 절차를 SKILL.md 포맷으로 표준화한
묶음. **이 디렉토리(`~/.agents/skills/`)가 정본**이고, 각 에이전트는 심링크 또는 직접 스캔으로
동일 내용을 로드한다.

## 스킬 목록

| 스킬 | 용도 |
|---|---|
| `relay-handoff` | 세션 간 작업·분석·지시 전달 — 핸드오프 5요소 템플릿 + herdr 주입·제출검증 |
| `spawn-worker` | 워커/검증자 스폰 전 과정 — worktree 준비, 쿼타 확인·계열 라우팅, 티어맵, 브리프, 적대검증 루프, ls-remote 대조 |
| `ask-session` | 상존 세션에 질문 보내고 답변 회수(왕복) — 답변 파일 계약 + 타임아웃·무응답 처리 |
| `consult-advisor` | 강모델 자문 — 티어로 자문처 지정, headless 1회성 우선, 교차 자문. 자문=참고 의견(승인 아님) |

스킬 간 관계: `relay-handoff`(단방향 전달) ⊂ `ask-session`(답변 계약 붙은 왕복) ⊂
`consult-advisor`(자문처 해석+headless 폴백). `spawn-worker`는 주입 단계에서 relay-handoff를
참조. **대상 세션 부재 시 공통 규칙: 자동 재생성 없음 — 실패 보고 + 운영자 에스컬레이션**
(orch/캡틴 재생성은 운영자 결정; 새 세션은 같은 cwd `claude --continue`+메모리+Linear+inbox로
상태 복원).

## 로드 경로 (2026-07-29 실측)

| 에이전트 | 스캔 경로 | 연결 방식 |
|---|---|---|
| codex | `~/.agents/skills/` | **직접 스캔** (심링크 불요) |
| claude | `~/.claude/skills/` | 심링크 |
| kiro | `~/.kiro/skills/` | 심링크 |
| agy | `~/.gemini/skills/` | 심링크 |

새 머신 설치: 이 repo를 `~/.agents/skills`로 clone 후 `./install.sh` (심링크 생성 + 의존성 검사).

## 의존 도구

| 도구 | 용도 | 폴백 |
|---|---|---|
| `herdr` (`~/.local/bin/herdr`) | 세션 스폰·주입·감시 — **하드 의존** | 없음 (스킬 자체가 herdr 체계용) |
| `scopefuel` | 스폰 전 쿼타·pace 확인 | `~/bin/ai-quota` |
| `wt` (worktrunk) | worktree 생성 + .env 자동 연결 | raw `git worktree add` + 수동 .env 심링크 |
| `~/bin/herdr-spawn` | worktree+탭+기동+주입 원샷, auto 쿼타 라우팅 | `herdr agent start` 수동 시퀀스 |

## 설계 원칙

1. **정본 1개 + 심링크** — 내용 이중화 금지. 파일 하나를 고치면 전 에이전트에 동시 반영.
2. **측정과 정책의 분리** — scopefuel은 잔량 측정(사실), 티어맵·라우팅 임계는 스킬(정책).
   정책은 실험 결과로 계속 바뀌므로 이 repo에서 버전관리한다.
3. **절차에는 실사고 근거를 첨부** — 각 스킬 말미의 실사례가 규칙의 존재 이유. 규칙을 완화할
   때는 그 사례가 재발하지 않는 근거를 PR에 적는다.
4. **변경은 PR로** — 스킬 본문은 호출 시점에 읽히므로 머지 즉시 전 세션에 적용된다.
