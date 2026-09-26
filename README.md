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
| `spawn-worker` | 워커/tester 스폰 전 과정 — worktree 준비, 쿼타 확인·계열 라우팅, 티어맵, 브리프, 적대검증 루프, ls-remote 대조 |
| `director` | 운영자 직속 최상위 역할 — 머지·배포·큐 권한, 빌더 브리프·스폰·독립 검증 판정 |
| `checker` | director 보좌·사전 머지 검사 역할 — 릴레이 수신, 셀 수 있는 게이트·큐·레인 정리 |
| `builder` | PR 한 건의 워커 브리프→검증→fix→JOIN 루프 소유 — 상위 레인 에스컬레이션과 parent-pane 이벤트 계약 포함 |
| `architect` | director 자문 역할 — 읽기 전용 독립 의견과 shadow ruling |
| `planner` | 상류 분석 상주 역할 — 판단을 durable하게 기록하고 실행에는 제안만 전달 |
| `ask-session` | 상존 세션에 질문 보내고 답변 회수(왕복) — 답변 파일 계약 + 타임아웃·무응답 처리 |
| `consult-advisor` | 강모델 자문 — 티어로 자문처 지정, headless 1회성 우선, 교차 자문. 자문=참고 의견(승인 아님) |
| `installer` | 배포 1건 전담(비상주, 배포 1회=세션 1개) — director 직속(스폰·보고 모두 director), 고정 9단계 절차(마지막 = 배포 기록)·판단 없음 |

구 이름 `admiral`·`flag`·`captain`·`counsel`·`strategist`·`bosun`은 별칭 stub으로 남아 있으며 정본은 각각 새 이름이다. 제거는 별도 태스크다.

스킬 간 관계: `orchestrate`(설계+결정 → 루프 전체 구동) 는 `spawn-worker`(스폰 기계학)를
호출한다. `relay-handoff`(단방향 전달) ⊂ `ask-session`(답변 계약 붙은 왕복) ⊂
`consult-advisor`(자문처 해석+headless 폴백). `spawn-worker`는 주입 단계에서 relay-handoff를
참조. **대상 세션 부재 시 공통 규칙: 자동 재생성 없음 — 실패 보고 + 운영자 에스컬레이션**
(orch/빌더 재생성은 운영자 결정; 새 세션은 같은 cwd `claude --continue`+메모리+Linear+inbox로
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
| `wrk` | 세션 오케스트레이션 CLI. `spawn`(worktree+탭+기동+주입 원샷, `-m` 필수·모르는 인자 거부) · `reap`(끝난 pane 회수, 기본 dry-run) · `find`(이름→라벨 폴백+화면 미리보기) · `name-sync`(탭 라벨→agent 이름 동기화, 무인자=미리보기·`--apply`=전체·`<라벨>`=지정) · `heavy`(>1분 로컬 실행의 호스트 직렬화 락, `-- <cmd>`·`status`). `wrk --help` 로 전체 확인 |
| `arbiter` | 작업 조정(admission control) — `claim`(job 등록·중복 거부) · `lease`/`release`(path·linear_permit의 fencing lease + quota_pool의 비배타 실행 기록) · `status`(읽기 전용) · `gc`(배타 lease 만료 전이 + 설치된 `herdr agent list`와 대조해 stale 기록 정리; JSON 경로 fixture도 지원) · `event`(인박스 제출). 저장소는 `$XDG_DATA_HOME/arbiter/state.db`(scopefuel DB와 분리). 전 명령 `--json`. **fail-closed** — 우회 플래그 없음 |

Shadow tester eligibility: `director/bin/tester-eligible` reads evidence and writes a receipt. Usage and audit: [director/tester-eligible.md](director/tester-eligible.md).

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
wrk spawn --role builder --lane BUILDER_LANE --parent PARENT_LANE ... -m builder-opus|builder-sol|builder-devin|builder-grok|builder-kimi
wrk done JOB [--report PATH]
wrk escalate JOB --question TEXT [--report PATH]
wrk joined JOB --pr URL --head SHA --report PATH
wrk reap [--lane LANE] [--grace 10m] [--apply] [--include-builders]
wrk find <이름|라벨> [--pane-only]
wrk name-sync [--apply|<라벨>...]
wrk heavy -- <cmd>     # 호스트당 1개, 대기 상한 20분(rc 75), nice -n 10, load5/ncpu<1.0 게이트
wrk heavy status       # 보유자·대기열
```

`-m`은 필수이며 `codex-terra`, `codex-luna`, `codex-sol`처럼 모델을 드러내는
canonical 이름과 기존 codex 별칭을 함께 지원한다. 쿼터 판정은 설치된
`scopefuel gate`에 위임한다. 은퇴한 agy TUI 프로필의 비상 headless 백업은
`agy -p "$(cat PROMPT_FILE)"`이다.

새 탭의 셸이 아직 rc 파일을 실행 중이면(부하가 높을 때 수 초) herdr는 `agent start`를
`agent_pane_busy`로 거부한다. `wrk`는 그 코드에 한해 프로필의 start 창(기본 30초, codex
120초 등) 안에서 0.25초 간격으로 재시도하고, 매 시도에 창의 남은 시간을 `--timeout`으로
넘긴다. 남은 시간이 herdr 하한(3000ms) 이하이거나 시도 상한(창/250ms)에 닿으면 빈 pane을
닫고 쿼터 기록을 해제하는 기존 fail-closed로 끝난다. 다른 오류 코드는 재시도하지 않는다.
Devin은 `pane run`이 셸 상태를 확인하지 않으므로, 그 전에 `pane process-info`를 같은
간격으로 조회해 셸이 foreground를 혼자 가진 상태(herdr의 available-shell 규칙)를 기다린다.
이 대기는 뒤의 검출·idle 대기와 같은 30초 창을 나눠 쓴다.

`devin-swe2`는 Devin 프로필이다. 현재 `wrk`는
`herdr pane run <pane_id> devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false`로
기동하고, 최대 30초 창 안에서 herdr가 그 pane을 agent로 검출할 때까지 `agent get`을
0.25초 간격으로 재조회한다(`pane run` 직후의 `agent_not_found`는 "아직 검출 전"이다;
실측 검출 0.42초). 검출 뒤 같은 창의 남은 시간 안에 idle을 기다리고,
`agent explain --format json`이 `agent=devin`과
`matched_rule.id=welcome_prompt_footer`를 함께 보고한 뒤에만 그 pane id를 agent 이름으로
rename한다. 첫 explain이 어떤 규칙에도 매치되지 않고 평가된 화면 영역이 방금
타이핑한 `devin …` 명령 줄뿐이면(m1b처럼 TUI가 아직 안 그려진 시작 중 상태)
같은 창 안에서 백오프로 재조회한다. 명령 줄이 아닌 다른 내용이 보여도 매치된
규칙이 없으면 마찬가지로 창이 닫힐 때까지 재조회한 뒤 실패한다; 매치된
규칙(신뢰 다이얼로그·권한
프롬프트·오류 화면)이나 다른 agent, 읽을 수 없는 envelope은 즉시 판정하고,
창이 닫히면 기존 fail-closed 경로와 진단 아티팩트 보존이 그대로 적용된다.
Devin에는 `--effort` 플래그가 없고 effort가 모델 id 안에 들어 있으므로,
effort 런그는 별도 프로필이다(#635): `devin-swe2-medium`(`--model swe-2-medium`)과
`devin-swe2-max`(`--model swe-2-max`)는 무료이고, `devin-ds41-max`
(`--model deepseek-v4-1-flash-max`)는 유료다. `devin-swe2`는 high 기본값을 유지한다.
quota gate에는 이름을 그대로 `devin-swe2`로
넘기고 pool 결정·기록은 scopefuel 출력과 arbiter가 소유한다.

이 분기는 herdr 0.9.1의 `agent start` 소유권 검사가 Devin 3000.11.1에서 실패하는 동안의
임시 우회다. herdr가 고쳐지면 걷어낸다. 해제 조건은 운영자가 만든 disposable pane에서
아래 명령이 Devin 3000.11.1을 대상으로 rc=0을 재현하는 것이다(`PANE_ID`는 그 pane id).

```bash
herdr agent start wrk-devin-probe --kind devin --pane "$PANE_ID" --timeout 30000 -- --model swe-2 --permission-mode dangerous --respect-workspace-trust false
```

`builder-devin`(동일 argv)과 워커 철자 `devin-swe2`·`devin-swe2-medium`·`devin-swe2-max`
모두 `--role builder`로 쓸 수 있다. #666 부터 런그별 빌더 철자도 열려 있다 —
`builder-devin-medium`·`builder-devin-max`(무료 swe-2 런그, 워커 변형과 동일 argv)와
유료 ds41 런그의 `builder-ds41`·`builder-ds41-max`(운영자 ds41-builder 정책)다.
빌더 운용 범위(A+ 급 작업의 T1·T2)의 정본은 `spawn-worker/SKILL.md` §2-2 급표의 `builder-devin` 행이다.
#704(#594 E6 측정)는 런그별 빌더 철자 `builder-opus-low`·`builder-opus-medium`·
`builder-sonnet-xhigh`·`builder-sonnet-max`·`builder-sol-high`·`builder-sol-max`·
`builder-luna-max`·`builder-terra-high`·`builder-terra-xhigh`·`builder-terra-max`·
`builder-kimi-high`·`builder-kimi-max`를 추가한다 — 이름의 마지막 구간이 고정 런그이고,
`SCOPEFUEL_E6_ARM=<게이트 프로필>@<런그>` 표식 없이는 스폰이 거부된다(에스컬레이션 런그는
`--operator-request` 추가). kimi 런그는 `bin/kimi-clone-home --effort high|max`의 클론 홈이
런그를 고정한다. #737(decision 4088)은 같은 규칙으로 grok 런그
`builder-grok-low`·`builder-grok-medium`·`builder-grok-xhigh`와 sol 런그
`builder-sol-medium`(`SCOPEFUEL_E6_ARM=codex-sol@medium`)을 추가한다 —
각각 `SCOPEFUEL_E6_ARM=grok-hi@low|medium|xhigh` 표식이 필요하고, grok·sol-medium 런그는
에스컬레이션이 아니므로 `--operator-request`는 불요다. 기존 `builder-grok`은 그대로
무표식(게이트는 `grok-hi` 기본 런그 판정), `builder-sol-high`도 #704 그대로다.
2026-09-26 운영자 결정으로 max 런그 철자 5개(`builder-sonnet-max`·
`builder-sol-max`·`builder-luna-max`·`builder-terra-max`·`builder-kimi-max`)는 닫혔다 —
빌더 좌석은 max 를 쓰지 않으므로 wrk 가 표식과 무관하게 거부한다.

`devin-glm52`·`devin-swe17`·`devin-ds41`은 같은 무인 argv에서 모델명만 바꾼 Devin
프로필이다(각각 `glm-5-2`·`swe-1-7`·`deepseek-v4-1-flash-high`). `devin-ds41-max`도
같은 argv에 모델명만 `deepseek-v4-1-flash-max`인 worker 전용 유료 변형이다. 넷 모두
scopefuel의 `devin` 풀 하나를 공유하고 worker 전용이다 — 유료 ds41 런그의 빌더
경로는 `builder-ds41`·`builder-ds41-max` 철자뿐이다. 급은 미측정 —
`devin-glm52`·`devin-swe17`은 T1, `devin-ds41`·`devin-ds41-max`는 T1/T2로 시작하며
reps 3건으로 확정한다. `devin-ds41`·`devin-ds41-max`만 유료다.

`--t`는 **필수**다(ROB-1198 §③). 빠지면 게이트·claim·스폰 어느 것도 하지 않고
`NEEDS_CLASSIFICATION`으로 거부한다 — 기본값을 만들면 분류하지 않은 값이 arbiter에
사실로 기록되기 때문이다. `--job`은 생략하면 `-l LABEL`을 쓴다.

빌더는 `builder-opus`(Opus effort high)·`builder-sol`을 쓴다. `captain-opus`·
`captain-sol`은 같은 프로필의 legacy 별칭이고, `--role captain`도 deprecation
경고 후 builder로 정규화되는 legacy 별칭이다. `builder-devin`(devin-swe2
argv, A+ 급 작업의 T1·T2 빌더 — `spawn-worker` 급표 행이 정본)와 빌더 파일럿으로 `builder-grok`(grok 4.7, effort xhigh)·`builder-kimi`(kimi-k3 argv)가 추가로 열려 있으며,
#666 의 런그별 devin 빌더 철자 `builder-devin-medium`·`builder-devin-max`·`builder-ds41`·`builder-ds41-max`(각각 워커 변형과 동일 argv)와 #704·#737 의 E6 측정 런그 철자(`builder-opus-low` 등 16개 — 위 단락 참조, `SCOPEFUEL_E6_ARM` 표식 필수)도 `--role builder`를 받는다.
파일럿이 지목한 워커 철자 `devin-swe2`·`devin-swe2-medium`·`devin-swe2-max`·`grok`/`grok-hi`·`kimi-k3`도 `--role builder`를 받는다. 빌더 spawn의 `--lane`은 arbiter claim의
`owner_lane`, `--parent`는 상위 보고 레인으로 기록된다. `wrk escalate`와 `wrk joined`는 완료
이벤트와 같은 평면 레코드를 남기되 `owner_lane`을 빌더 자신의 레인으로 설정한다. panewire
R19a는 `job.escalate`·`job.joined`를 parent pane으로 전달한다.

`wrk done`, `wrk joined`, 그리고 보고서가 지정된 `wrk escalate`는 보고서를
`reports/<job>/<basename>` 키로 handoffkeep CLI에 올린다. CLI는
`HANDOFFKEEP_URL`/`HANDOFFKEEP_TOKEN` 또는 `~/.config/handoffkeep/config.env`에서 자격증명을
읽으며, 업로드 실패는 경고만 남기고 완료 레코드는 계속 쓴다. 성공 시 마지막 줄의
`doc:<key>` 접미를 웹 콘솔이 문서 링크로 연다.

`wrk done|escalate|joined`는 설치된 panewire가 `panewire job probe`에 정확히
`panewire-job/1`로 답할 때만 같은 인자를 `panewire job <명령>`에 넘긴다(#499). 그 경로는
레코드·소켓 요청·업로드·출력을 wrk와 바이트 단위로 같게 남긴다(panewire
`testdata/job_golden`). 바이너리가 없거나, `job`을 모르는 구 panewire이거나, 답이 다르거나,
probe가 5초 안에 끝나지 않으면 지금까지의 wrk 경로를 그대로 쓴다. 넘긴 뒤에는 wrk가 아무것도
더 하지 않으므로(`exec`) 한 이벤트는 두 경로 중 한 곳에서만 쓰인다. `WRK_JOB_DELEGATE=0`은
wrk 경로를 강제한다(golden 재생성·롤백용).

## 완료 센티널 판정표

`wrk spawn`은 job이 arbiter에 등록되면 완료 센티널을 분리 기동한다. 센티널은
`herdr agent get <pane>` 관측을 **3분류**하고, 판정 1건마다 잡 디렉토리의
`completion-sentinel.log`에 한 줄씩 남긴다
(`<ts> status=<상태|empty|err:code> transient=<n> action=<none|pending|completed|lost:reason>`).

| 관측 | 분류 | 판정 |
|---|---|---|
| `agent_not_found` 등 pane/terminal 부재 에러 코드 | 확정 소멸 | 즉시 `job.lost` (`reason=agent_not_found`) |
| 빈 출력 · 비정상 종료 · JSON 파싱 실패 · 소켓 에러 | 일시 장애 | `WRK_COMPLETION_INTERVAL_S`(기본 30s) 간격 재시도. **연속** `WRK_SENTINEL_TRANSIENT_MAX`(기본 10회 ≈5분) 초과 시에만 `job.lost` (`reason=herdr_unreachable`) |
| 정상 상태(`working`/`idle`/`done`) | 관측 성공 | 일시 장애 카운터 리셋. `idle`·`done` + 새 report면 `job.completed` — 단 report의 관측 키가 한 interval 동안 그대로일 때만(첫 관측은 `action=pending`). 부분 작성 중인 파일로 먼저 나가지 않기 위함이다 |
| `WRK_COMPLETION_TIMEOUT_S`(기본 6h) 경과 | 감시 창 만료 | `job.lost` (`reason=timeout`) |

`job.completed` 레코드는 report 본문의 sha256(`report_sha256` 필드)으로 라운드를
식별한다. 같은 내용의 report에 대한 완료 기록이 이미 있으면 `wrk done`·센티널 어느
쪽이든 두 번째 레코드와 통지를 억제하고 `completion-suppressed.log`에 한 줄 남긴다
— 억제는 건수가 아니라 "이 report artifact의 완료가 이미 기록됐는가"의 멤버십 판정이다.
내용이 바뀐 report는 새 라운드로 별개 레코드가 된다.

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

워커·tester가 끝나도 pane은 herdr에 남아 하루 40~60개가 쌓이고, 그만큼 herdr 서버
부하(fd·구독)가 된다. `wrk reap`은 인박스를 읽어 **끝난 것이 증명된** 잡의 탭만 닫는다.

```bash
wrk reap --lane REAP_LANE              # dry-run: 닫을 목록만 출력
wrk reap --lane REAP_LANE --apply      # 실제로 herdr tab close
```

회수 조건(**전부** 충족해야 후보):

- terminal 이벤트(`job.completed`·`job.joined`·`job.revoked`)가 있다
- 가장 늦은 terminal 이벤트 **뒤에** `job.claim`·`job.reclaim`·`job.spawned`(·`job.reprompted`)가
  없다 — 끝난 뒤 다시 잡힌 잡은 살아 있는 작업이다(`skip … reason=reclaimed-after-terminal`).
  `job.lost`·`quota_pool.*`는 되살림이 아니다
- 그 terminal 이벤트가 `--grace`(기본 10m)보다 오래됐다
- **가장 늦은** `job.spawned` 영수증의 `pane_id`가 herdr에 살아 있고 상태가 `idle`·`done`이다.
  pane·tab은 그 영수증 하나에서 **한 벌로** 읽는다(앞선 영수증의 tab과 섞지 않고, 깨진 최신
  영수증은 `malformed-record`로 건너뛴다)
- herdr가 말하는 그 pane의 탭이 기록된 탭과 같다(다르면 `skip … reason=tab-mismatch`)
- close **직전에 다시 읽은** `herdr tab list`가 그 탭의 `pane_count`를 **정확히 1로 확인**한다. 조회 실패·JSON 파손·목록에 없음·
  `pane_count` 부재/비정수(bool 포함)·중복 항목은 "공유일 수 있음"으로 보고 닫지 않는다
  (`skip … reason=tab-count-unknown`, fail-closed). 2 이상은 기존대로 `tab-shared`
- 아직 회수된 적이 없다(`job.reaped` 이벤트 없음)

`--apply`는 `--lane` 없이 거부된다(nonzero, 아무것도 조회·종료하지 않음). 전역 회수 우회
플래그는 없다 — 레인마다 따로 돌린다. dry-run은 lane 없이도 된다.

`working`/`blocked` pane, terminal 이벤트 없는 잡, herdr가 해석하지 못하는 pane은
건드리지 않는다(해석 실패는 소켓 문제일 수 있고, 확인 못한 탭을 닫는 편이 더 나쁘다).
빌더 pane(claim `role: builder` 또는 legacy `captain`)은 `--include-builders` 없이는 제외한다.
`--include-captains`는 같은 동작의 legacy 별칭이다. 기본은 **dry-run**이며, `--apply`로 닫은 잡에만 평면 `job.reaped` 이벤트(`pane_id`·`tab_id`·`at`)를
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
