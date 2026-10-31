# agent-skills — 크로스에이전트 오케스트레이션 스킬 정본

멀티에이전트 오케스트레이션(herdr 대장-워커 체계)에서 반복되는 절차를 SKILL.md 포맷으로
표준화하고, admission control(`arbiter`)까지 도구로 구현한 묶음이다.
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

`wake`·`ops`의 규칙 상당수는 특정 실행 환경(되돌릴 수 없는 외부
mutation 등)의 구체 사례에서 뽑아 도메인 무관 형태로 추상화했다. 그 사례 원문은
이 repo가 아니라
개인/사설 저장소에 있다. `$AGENT_SKILLS_DOMAIN` 환경변수가 가리키는 디렉토리에
`ops.md` 파일이 있으면 `ops`는 적용 전에 그 파일을 먼저 읽는다. 옛 스킬 이름의 오버레이
(`spawn-worker.md`·`relay-handoff.md`·`linear-archive.md`)는 더 이상 읽히지 않는다 — `ops.md`로 합친다.
`AGENT_SKILLS_DOMAIN` 미설정이나 해당 디렉토리 부재는 정상 상태다(추상 규칙만 적용) —
경고 없음. `./install.sh --check`가 오버레이 설정 여부를 한 줄로 보여준다. 같은
검사에서 `scopefuel`의 캐시된 풀별 인증·쿼타 요약도 보여준다. 캐시가 없으면 빠르게 미측정으로
넘어가며, 실측이 필요할 때만 `./install.sh --check --probe`를 사용한다.

## 스킬 목록

| 스킬 | 용도 |
|---|---|
| `wake` | repo 세션의 PR 루프(wake method) — 티어·T3 분할·브리프 규칙·머지 게이트·위임 PR 좌석까지 자족. 작은 PR → mergewake review 1회 → 지적 처리 → CI green → repo 세션 머지. tester 라운드 없음, 워커 브리프 템플릿 포함 |
| `fleet-review` | 리뷰 지적 처리 — fix/dismiss/defer 기준표, repo별 학습 skip 패턴(`.mergewake/triage-patterns.md`), "판정은 SHA가 아니라 패치를 덮는다"(patch-id), poteto-mode 3원칙(목표 재진술·데이터 모양·실물 증명), 벤더링한 pstack보다 fleet 브리프·`wake`가 우선한다는 선언 |
| `ops` | 레인 기계학 — 스폰·착지 확인, 릴레이·주입(5요소·`comms-contract: v1`), 자문, 결정 요청, 결정 ESC(pane 질문 금지), 폴링 없는 대기, 회수, 배포 1건(installer 좌석, operator-desk 직속). `SKILL.md`는 라우팅 표, 절차는 `ops/references/` |

스킬 간 관계: `wake`는 무엇을 언제 끝낼지(티어·브리프·머지 게이트)를, `ops`는 그 과정의 기계학을 담당한다.
`wake`는 `ops`의 reference를 가리키고, `ops`는 `wake`로 되돌아가지 않는다.
**대상 세션 부재 시 공통 규칙: 자동 재생성 없음 — 실패 보고 + 운영자 에스컬레이션.**

### 은퇴한 스킬 (hk 2290, 2026-10-29)

`planner`·`architect`·`linear-archive`·`node-ops`·`checker`·`director`·`installer`·`relay-handoff`·
`consult-advisor`·`spawn-worker`·`builder`는 삭제됐다(호환 stub 없음). 옮겨 간 곳:
relay-handoff → `ops/references/relay.md`(+`session-questions.md`), consult-advisor → `consult.md`,
installer → `deploy.md`(+`deploy-checklist.md`), spawn-worker §4·§4.x·§6 → `spawn.md`·`spawn-hosts.md`·
`reap.md`, director 결정 요청·감시 → `decision-request.md`·`watching.md`·`panewire-events.md`,
spawn-worker §1~§3·builder 루프·director 권한·머지 게이트 → `wake`. planner·architect·linear-archive·node-ops·
checker와 tester 라운드 규칙은 옮기지 않았다. wrk 와 wrk 에 의존하던 `director/` 게이트(tester-eligible·merge-precheck)는 runtug 로 대체되며 삭제됐다. `director/gate_policy.json` 은 `local_sources` 해시 핀(ci.yml docs-only 분류기와 wake 가 읽음)만 남겼다.
원문 복원: `git log --diff-filter=D --format=%H -1 -- <스킬>/SKILL.md`로 삭제 커밋을 찾고
`git show <그 커밋>^:<스킬>/SKILL.md`.

## 벤더링한 pstack (`third_party/pstack/`)

[michael-denyer/pstack-claude](https://github.com/michael-denyer/pstack-claude)(MIT) 커밋 `5851c89`의 Claude Code 빌드 스킬을
복사했다(심링크·서브모듈 아님, `PINNED` 참조). 실행 파일(bun/TypeScript 도구·훅·셸 스크립트)은 싣지 않았고 제외 목록은 `PINNED`에 있다.
충돌하는 지시와 그 무력화 방법은 `third_party/pstack/REVIEW.md`. 버전 올림은 diff를 코드처럼 리뷰한다.
`install.sh`는 `third_party/pstack/INSTALL`에 적힌 48개 스킬(`principle-*` 전부, `how`·`why`·`architect`·`blast-radius`·`tdd` 등)만 링크한다.
`poteto-mode`·`poteto-help`·`setup-pstack`·`swarm`·`arena`·`automate-me`·`ketchup`·`ketchup-video`·`bro`는 제외 — 나머지는 상대 링크로 읽을 수만 있다.
스킬 설명이 매 세션 컨텍스트에 실리는 비용은 운영자 결정으로 감수한다(`REVIEW.md` 참조).
`./install.sh --dry-run`은 아무것도 쓰지 않고 만들 링크만 보여준다(codex는 `~/.agents/skills`를 직접 스캔하고, 중첩된 벤더링 스킬은 `~/.codex/skills`에 따로 링크).

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
| `arbiter` | 작업 조정(admission control) — `claim`(job 등록·중복 거부) · `lease`/`release`(path·linear_permit의 fencing lease + quota_pool의 비배타 실행 기록) · `status`(읽기 전용) · `gc`(배타 lease 만료 전이 + 설치된 `herdr agent list`와 대조해 stale 기록 정리; JSON 경로 fixture도 지원) · `event`(인박스 제출). 저장소는 `$XDG_DATA_HOME/arbiter/state.db`(scopefuel DB와 분리). 전 명령 `--json`. **fail-closed** — 우회 플래그 없음 |
| `fleet-rev` | 5호스트 설치 버전 점검(**읽기 전용**) — 호스트별 scopefuel·agent-skills·panewire·handoffkeep의 설치 커밋을 GitHub main과 대조해 current/behind/diverged를 표로 출력. 호스트당 ssh 1회 + 고정 POSIX sh probe(key=value만 출력); 설치·재시작·쓰기 명령 없음. `--extra NAME=ALIAS` · `--skip NAME` · `--only NAME[,NAME]` · `--timeout` · `--json` |

> `wrk`(세션 스폰·reap·heavy CLI)는 runtug 로 대체되어 은퇴했다(hk 2323). runtug 는 `~/.config/wrk/hosts.toml` 을 그대로 읽는다.

## 의존 도구

| 도구 | 용도 | 폴백 |
|---|---|---|
| `herdr` (`~/.local/bin/herdr`) | 세션 스폰·주입·감시 — **하드 의존** | 없음 (스킬 자체가 herdr 체계용) |
| `scopefuel` | 스폰 전 쿼타·pace 확인, 급별 후보 추천(`--recommend`), 스폰 게이트(`gate`) | 없음(정본) |
| `wt` (worktrunk) | worktree 생성 + .env 자동 연결 | raw `git worktree add` + 수동 .env 심링크 |

## Local ShellCheck

Run local checks through `scripts/shellcheck-capped`, which reads ShellCheck options from the CI workflow and applies a 2048 MB memory cap by default. The `--changed` mode only knows `bin/wrk`, which was retired, so it no longer selects anything. CI continues to run its existing direct ShellCheck step.

```sh
scripts/shellcheck-capped tests/test-ci-suites.sh
```

## 설치 점검 (fleet-rev)

머지마다 데스크가 5대 호스트에 네 도구를 손으로 재설치한다. `bin/fleet-rev`는
각 호스트의 설치 커밋을 GitHub main과 대조해 어느 호스트가 아직 옛 빌드인지
한 표로 보여준다. **읽기 전용** — 설치·재시작·파일 쓰기는 절대 하지 않으며
설치 자체는 데스크의 일로 남는다.

정본 호출(desk = 이 Mac, hosts.toml의 활성 `[hosts.*]` 전부 + M1은 `--extra`로,
연결 불가인 oci는 `--skip`으로 제외):

```bash
bin/fleet-rev --extra mac-work=m1 --skip oci
```

probe 대상 = `local`(ssh 없이 직접 probe) + `WRK_HOSTS_CONFIG`
(기본 `~/.config/wrk/hosts.toml`)의 활성 `[hosts.NAME]` 테이블 전부. 주석 처리된
테이블은 호스트가 아니다. 5대 = 이 Mac(local) + m1b + desktop + Pi +
M1(`--extra mac-work=m1`).

각 호스트에는 `ssh -o BatchMode=yes -o ConnectTimeout=10 <alias> sh -s` 한 번으로
고정 POSIX sh probe만 보낸다(stdin의 스크립트, key=value 줄만 출력). probe는
`PATH`에 `~/.local/bin ~/go/bin /opt/homebrew/bin /usr/local/bin`을 앞에 붙인 뒤
uv receipt·`~/.agents/skills` git·`panewire version`·`handoffkeep version --json`
(없으면 `go version -m` 폴백)만 읽는다. 환경 파일·토큰·설정은 읽지 않는다.

status(호스트×도구):

| status | 뜻 |
|---|---|
| `current` | 설치 커밋 = GitHub main(짧은 sha는 main의 접두사일 때만 인정) |
| `current+modified` | current + 작업트리 수정(agent-skills dirty>0, handoffkeep vcs.modified) |
| `behind N` | main이 설치본보다 N커밋 앞섬(compare status ahead) |
| `diverged` | compare status diverged, 또는 설치 sha를 GitHub이 모름(404) |
| `unknown` | probe가 설치본을 판독 못함(파일은 있는데 rev 없음 등) |
| `absent` | 바이너리·파일 자체가 없음 |
| `unreachable` | 그 호스트의 ssh 실패·타임아웃(그 호스트 전 칸) |

exit code: `0` 전부 current · `1` behind/diverged 하나라도 있음 ·
`3` stale 없지만 unknown/absent/unreachable 있음 · `2` 사용법·설정 오류.
`--json`은 `{"main": {repo: sha}, "hosts": [{"host","alias","reachable","tools"}],
"rc"}` 한 객체를 출력하고 rc 필드는 종료코드와 같다.

뒤처진 칸의 호스트별 재설치(데스크가 실행 — fleet-rev는 하지 않는다):

- **scopefuel**: `uv tool install --force git+https://github.com/mgh3326/scopefuel@<sha>`
  — 이 `@<sha> --force` 형식은 fleet-rev의 권장 설치 형식이다(scopefuel README에는
  rev 없는 `uv tool install git+…` 만 있고 핀 재설치 형식은 따로 문서화되어 있지 않다).
- **agent-skills**: `git -C ~/.agents/skills pull --ff-only` 후 `./install.sh`
- **panewire**: panewire repo의 [`docs/runbooks/node-update.md`](https://github.com/mgh3326/panewire/blob/main/docs/runbooks/node-update.md) 런북을 따른다.
- **handoffkeep**: CLI 설치 절차는 handoffkeep repo에 문서화되어 있지 않다
  (repo에는 서버용 `deploy/systemd/` 유닛과 `docs/README.md` 운영 절차만 있다).

## 도메인 경계 (ROB-1199 — 위반 금지)

```text
scopefuel   쿼타·급·정책     "얼마 남았나"    ← arbiter 가 읽는 입력원
(호출자)    세션 수명주기    "어떻게 띄우나"  (runtug)
arbiter     작업 조정        "누가 점유했나"
```

호출 방향은 `호출자 → arbiter → scopefuel --json` 한 방향이다. 호출자는 `scopefuel gate`
통과 직후 arbiter로 job을 claim하고 quota pool 실행 기록을 남긴다 — **pool 매핑은 호출자에 없다.**
arbiter가 scopefuel이 내놓은 gate 출력에서 pool을 읽고 `scopefuel --json`의 provider 목록과
대조한다. `arbiter gc`는
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
