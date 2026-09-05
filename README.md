# agent-skills — 크로스에이전트 오케스트레이션 스킬 정본

멀티에이전트 오케스트레이션(herdr 대장-워커 체계)에서 반복되는 절차를 SKILL.md 포맷으로
표준화하고, 스폰 게이트(`wrk`)와 admission control(`arbiter`)까지 도구로 구현한 묶음이다.
기반 도구는 [herdr](https://github.com/herdrdev/herdr)(세션 스폰·주입·감시),
[worktrunk](https://github.com/max-sixty/worktrunk)(worktree 관리),
[scopefuel](https://github.com/mgh3326/scopefuel)(쿼타·급 판단) — 전부 공개 repo다.
`arbiter`는 SQLite 기반 fencing lease + admission control이며, `tests/test-arbiter.sh`가
fencing token 단조성·stale/replay release 거부·GC가 `unknown` 기록을 추측 않고 거부하는
것까지 인수 테스트로 검증한다.

**이 디렉토리(`~/.agents/skills/`)가 정본**이고, 각 에이전트는 심링크 또는 직접 스캔으로
동일 내용을 로드한다 — codex는 이 경로를 직접 스캔하므로 `install.sh`도 repo가
`~/.agents/skills`에 있음을 전제한다(다른 경로면 `install.sh` 실행 시 경고).

> ROB-NNN 은 비공개 이슈 트래커 참조이며, 각 규칙 옆 본문이 근거를 자립 설명한다.

## 도메인 오버레이

`spawn-worker`·`linear-archive`·`relay-handoff`는 특정 실행 환경(되돌릴 수 없는 외부
mutation 등)의 구체 사례에서 규칙을 뽑아 도메인 무관 형태로 추상화했다. 그 사례 원문은
이 repo가 아니라
개인/사설 저장소에 있다. `$AGENT_SKILLS_DOMAIN` 환경변수가 가리키는 디렉토리에
`<skill-name>.md` 파일이 있으면 각 스킬은 적용 전에 그 파일을 먼저 읽는다.
`AGENT_SKILLS_DOMAIN` 미설정이나 해당 디렉토리 부재는 정상 상태다(추상 규칙만 적용) —
경고 없음. `./install.sh --check`가 오버레이 설정 여부를 한 줄로 보여준다. 같은
검사에서 `bin/wrk`의 `PROFILE_KIND`에서 에이전트 CLI를 파생해 설치 여부를 표시하고,
`scopefuel`의 캐시된 풀별 인증·쿼타 요약도 보여준다. 캐시가 없으면 빠르게 미측정으로
넘어가며, 실측이 필요할 때만 `./install.sh --check --probe`를 사용한다.

## 스킬 목록

| 스킬 | 용도 |
|---|---|
| `orchestrate` | 완성된 설계·운영자 결정을 받아 워커 스폰~완료 검증까지 전체 루프 구동 — spawn-worker 위층 진입점 |
| `relay-handoff` | 세션 간 작업·분석·지시 전달 — 핸드오프 5요소 템플릿 + herdr 주입·제출검증 |
| `spawn-worker` | 워커/검증자 스폰 전 과정 — worktree 준비, 쿼타 확인·계열 라우팅, 티어맵, 브리프, 적대검증 루프, ls-remote 대조 |
| `captain` | PR 한 건의 워커 브리프→검증→fix→JOIN 루프 소유 — 상위 레인 에스컬레이션과 parent-pane 이벤트 계약 포함 |
| `ask-session` | 상존 세션에 질문 보내고 답변 회수(왕복) — 답변 파일 계약 + 타임아웃·무응답 처리 |
| `consult-advisor` | 강모델 자문 — 티어로 자문처 지정, headless 1회성 우선, 교차 자문. 자문=참고 의견(승인 아님) |

스킬 간 관계: `orchestrate`(설계+결정 → 루프 전체 구동) 는 `spawn-worker`(스폰 기계학)를
호출한다. `relay-handoff`(단방향 전달) ⊂ `ask-session`(답변 계약 붙은 왕복) ⊂
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
| opencode | `~/.config/opencode/skills/` | 심링크 (07-30 추가 — 4스킬 인식 실측) |

새 머신 설치: 이 repo를 `~/.agents/skills`로 clone 후 `./install.sh` (심링크 생성 + 의존성 검사).

## 동봉 도구 (bin/ — install.sh가 ~/.local/bin에 심링크)

| 도구 | 용도 |
|---|---|
| `rob-lookup` | Linear 이슈 통합 조회 — `ROB-NNN`(active+soft-archived Linear API+Obsidian 아카이브 섹션) · `--search <키워드>`(아카이브 전문 검색 — **삭제분 내용 검색의 유일 경로**) · `--count`(쿼타 미터, 상한 275). 실측: 30일+ 경과 삭제분은 Linear에서 purge됨(ROB-383) — Obsidian이 유일 소스 |
| `wrk` | 세션 오케스트레이션 CLI. `spawn`(worktree+탭+기동+주입 원샷, `-m` 필수·모르는 인자 거부) · `reap`(끝난 pane 회수, 기본 dry-run) · `find`(이름→라벨 폴백+화면 미리보기) · `name-sync`(탭 라벨→agent 이름 동기화, 무인자=미리보기·`--apply`=전체·`<라벨>`=지정). `wrk --help` 로 전체 확인 |
| `arbiter` | 작업 조정(admission control) — `claim`(job 등록·중복 거부) · `lease`/`release`(path·linear_permit의 fencing lease + quota_pool의 비배타 실행 기록) · `status`(읽기 전용) · `gc`(배타 lease 만료 전이 + 설치된 `herdr agent list`와 대조해 stale 기록 정리; JSON 경로 fixture도 지원) · `event`(인박스 제출). 저장소는 `$XDG_DATA_HOME/arbiter/state.db`(scopefuel DB와 분리). 전 명령 `--json`. **fail-closed** — 우회 플래그 없음 |

## 의존 도구

| 도구 | 용도 | 폴백 |
|---|---|---|
| `herdr` (`~/.local/bin/herdr`) | 세션 스폰·주입·감시 — **하드 의존** | 없음 (스킬 자체가 herdr 체계용) |
| `scopefuel` | 스폰 전 쿼타·pace 확인, 급별 후보 추천(`--recommend`), 스폰 게이트(`gate`) | 없음(정본) |
| `wt` (worktrunk) | worktree 생성 + .env 자동 연결 | raw `git worktree add` + 수동 .env 심링크 |
| `~/bin/herdr-spawn` | **deprecated** — `wrk spawn` 으로 위임하는 shim(옛 경로 호환용) | `wrk spawn` |

## `wrk` 사용법

```text
wrk spawn -c CWD -m MODEL -p PROMPT_FILE -w WORKSPACE -l LABEL --t T0..T3
          [-L live|mock] [--effort LEVEL] [--job ID]
wrk spawn --role captain --lane CAPTAIN_LANE --parent PARENT_LANE ... -m captain-opus|captain-sol
wrk done JOB [--report PATH]
wrk escalate JOB --question TEXT [--report PATH]
wrk joined JOB --pr URL --head SHA --report PATH
wrk reap [--lane LANE] [--grace 10m] [--apply] [--include-captains]
wrk find <이름|라벨> [--pane-only]
wrk name-sync [--apply|<라벨>...]
```

`-m`은 필수이며 `codex-terra`, `codex-luna`, `codex-sol`처럼 모델을 드러내는
canonical 이름과 기존 codex 별칭을 함께 지원한다. 쿼터 판정은 설치된
`scopefuel gate`에 위임한다. 은퇴한 agy TUI 프로필의 비상 headless 백업은
`agy -p "$(cat PROMPT_FILE)"`이다.

`--t`는 **필수**다(ROB-1198 §③). 빠지면 게이트·claim·스폰 어느 것도 하지 않고
`NEEDS_CLASSIFICATION`으로 거부한다 — 기본값을 만들면 분류하지 않은 값이 arbiter에
사실로 기록되기 때문이다. `--job`은 생략하면 `-l LABEL`을 쓴다.

캡틴은 `captain-opus`(Opus effort high) 또는 `captain-sol`만 쓴다. 캡틴 spawn의 `--lane`은
arbiter claim의 `owner_lane`, `--parent`는 상위 보고 레인으로 기록된다. `wrk escalate`와
`wrk joined`는 완료 이벤트와 같은 평면 레코드를 남기되 `owner_lane`을 그 parent 레인으로
설정한다. panewire R19a는 `job.escalate`·`job.joined`를 parent pane으로 전달한다.

`wrk done`, `wrk joined`, 그리고 보고서가 지정된 `wrk escalate`는 보고서를
`reports/<job>/<basename>` 키로 handoffkeep CLI에 올린다. CLI는
`HANDOFFKEEP_URL`/`HANDOFFKEEP_TOKEN` 또는 `~/.config/handoffkeep/config.env`에서 자격증명을
읽으며, 업로드 실패는 경고만 남기고 완료 레코드는 계속 쓴다. 성공 시 마지막 줄의
`doc:<key>` 접미를 웹 콘솔이 문서 링크로 연다.

## 완료 센티널 판정표

`wrk spawn`은 job이 arbiter에 등록되면 완료 센티널을 분리 기동한다. 센티널은
`herdr agent get <pane>` 관측을 **3분류**하고, 판정 1건마다 잡 디렉토리의
`completion-sentinel.log`에 한 줄씩 남긴다
(`<ts> status=<상태|empty|err:code> transient=<n> action=<none|completed|lost:reason>`).

| 관측 | 분류 | 판정 |
|---|---|---|
| `agent_not_found` 등 pane/terminal 부재 에러 코드 | 확정 소멸 | 즉시 `job.lost` (`reason=agent_not_found`) |
| 빈 출력 · 비정상 종료 · JSON 파싱 실패 · 소켓 에러 | 일시 장애 | `WRK_COMPLETION_INTERVAL_S`(기본 30s) 간격 재시도. **연속** `WRK_SENTINEL_TRANSIENT_MAX`(기본 10회 ≈5분) 초과 시에만 `job.lost` (`reason=herdr_unreachable`) |
| 정상 상태(`working`/`idle`/`done`) | 관측 성공 | 일시 장애 카운터 리셋. `idle`·`done` + 새 report면 `job.completed` |
| `WRK_COMPLETION_TIMEOUT_S`(기본 6h) 경과 | 감시 창 만료 | `job.lost` (`reason=timeout`) |

**빈 값은 소멸의 증거가 아니다.** 2026-09-04 소켓 일시 정지와 비기본 herdr 세션
때문에 그날 스폰한 거의 모든 잡이 스폰 30초 뒤 `job.lost`로 찍혔고, 센티널이 죽어
워커가 정상 완료해도 `job.completed`를 아무도 쓰지 못했다(수동 전달 3회).

`job.lost`를 쓴 뒤에도 센티널은 즉시 끝나지 않는다. `WRK_SENTINEL_LOST_GRACE`
(기본 1800초) 동안 계속 감시해 그 사이 report가 생기고 상태가 `done`/`idle`이 되면
`job.completed`를 **추가로** 쓰고 종료한다(panewire가 completed를 relay한다).

분리된 센티널은 터미널에서 유도되는 herdr 세션 컨텍스트를 잃는다. 그래서 wrk는
스폰 시점의 `HERDR_SESSION`·`HERDR_SOCKET_PATH`·`HERDR_BIN(_PATH)`를 센티널 환경에
명시적으로 박아 넣는다. 서버가 비기본 세션에 사는 호스트에서는
`WRK_SENTINEL_HERDR_SESSION`/`WRK_SENTINEL_HERDR_SOCKET`로 스폰 측이 직접 지정한다.

```bash
WRK_SENTINEL_HERDR_SESSION=worker wrk spawn -c ... -m ... --job <id>
```

## `wrk reap` — 끝난 pane 회수

워커·검증자가 끝나도 pane은 herdr에 남아 하루 40~60개가 쌓이고, 그만큼 herdr 서버
부하(fd·구독)가 된다. `wrk reap`은 인박스를 읽어 **끝난 것이 증명된** 잡의 탭만 닫는다.

```bash
wrk reap --lane lane-a              # dry-run: 닫을 목록만 출력
wrk reap --lane lane-a --apply      # 실제로 herdr tab close
```

회수 조건(**전부** 충족해야 후보):

- terminal 이벤트(`job.completed`·`job.joined`·`job.revoked`)가 있다
- 그 terminal 이벤트가 `--grace`(기본 10m)보다 오래됐다
- `job.spawned`의 `pane_id`가 herdr에 살아 있고 상태가 `idle`·`done`이다
- 아직 회수된 적이 없다(`job.reaped` 이벤트 없음)

`working`/`blocked` pane, terminal 이벤트 없는 잡, herdr가 해석하지 못하는 pane은
건드리지 않는다(해석 실패는 소켓 문제일 수 있고, 확인 못한 탭을 닫는 편이 더 나쁘다).
캡틴 pane(claim `role: captain`)은 `--include-captains` 없이는 제외한다. 기본은
**dry-run**이며, `--apply`로 닫은 잡에만 평면 `job.reaped` 이벤트(`pane_id`·`tab_id`·`at`)를
남긴다. `wrk spawn`은 이를 위해 `job.spawned` payload에 `tab_id`를 함께 기록한다
(기존 필드는 그대로 — 구형 herdr로 만들어져 `tab_id`가 없는 잡은 `agent get`으로 해석한다).

## 도메인 경계 (ROB-1199 — 위반 금지)

```text
scopefuel   쿼타·급·정책     "얼마 남았나"    ← arbiter 가 읽는 입력원
wrk         세션 수명주기    "어떻게 띄우나"
arbiter     작업 조정        "누가 점유했나"
```

호출 방향은 `wrk → arbiter → scopefuel --json` 한 방향이다. `wrk spawn`은 `scopefuel gate`
통과 직후 arbiter로 job을 claim하고 quota pool 실행 기록을 남긴다 — **pool 매핑은 wrk에 없다.**
arbiter가 scopefuel이 내놓은 gate 출력에서 pool을 읽고 `scopefuel --json`의 provider 목록과
대조한다. 배타 lease 획득 실패는 스폰 거부(exit 3)이고, quota_pool 기록의 claim·준비·기록
실패는 경고 후 진행한다. 스폰 실패 시 성공한 quota_pool 기록은 반납한다. `arbiter gc`는
설치된 `herdr agent list`를 기본으로 읽어 exact claim-event identity와 대조한다. `working`이
아닌 `idle`·`blocked`·`done` 기록은 감사 이벤트와 함께 정리하지만, `unknown` 또는 매핑 없는
구형 기록은 추측하지 않고 GC를 거부한다. 테스트에서는 JSON 경로를 넘길 수 있다. 우회
플래그는 만들지 않는다.

## 설계 원칙

1. **정본 1개 + 심링크** — 내용 이중화 금지. 파일 하나를 고치면 전 에이전트에 동시 반영.
2. **측정과 정책의 분리** — scopefuel은 잔량 측정(사실), 티어맵·라우팅 임계는 스킬(정책).
   정책은 실험 결과로 계속 바뀌므로 이 repo에서 버전관리한다.
3. **절차에는 실사고 근거를 첨부** — 각 스킬 말미의 실사례가 규칙의 존재 이유. 규칙을 완화할
   때는 그 사례가 재발하지 않는 근거를 PR에 적는다.
4. **변경은 PR로** — 스킬 본문은 호출 시점에 읽히므로 머지 즉시 전 세션에 적용된다.
