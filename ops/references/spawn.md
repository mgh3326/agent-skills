# spawn — 기동·주입·착지·task 연결

**launcher**: `runtug` 는 shadow migration 중이다 — 기본은 `runtug spawn`, 도구 사유로 거부되면 같은
인자로 `wrk spawn` 에 폴백한다. 한 task 에는 launcher 하나만 쓴다(같은 live task 를 두 번 제출 금지).
아래 본문은 `wrk` 기준으로 쓰였다. 두 도구가 공유하는 서브커맨드:

| 일 | runtug | wrk |
|---|---|---|
| 스폰 | `runtug spawn` | `wrk spawn` |
| 완료·ESC 기록 | `runtug done` · `runtug escalate` | `wrk done` · `wrk escalate` |
| 회수 | `runtug reap` · `runtug prune` | `wrk reap` · `wrk prune` |
| 무거운 실행 | `runtug heavy -- <cmd>` | `wrk heavy -- <cmd>` |
| 레인 감사 | `runtug lanes-missing` | `wrk lanes-missing` |
| 대상 찾기 | `runtug find` · `runtug name-sync` | `wrk find` · `wrk name-sync` |

`runtug` 에는 `round`·`joined`·`worktree-reap` 이 없다 — tester 라운드는 wake 방식에서 폐지됐다.

## 무인 실행·task 기록

- kiro 워커: "Linear는 읽기만, 이슈·코멘트 변경 금지" 필수(kiro Linear MCP는 write 가능).
- 무인 워커는 승인 우회 플래그 필요(codex `--yolo`, agy `--dangerously-skip-permissions`) —
  `wrk spawn` 프로필 매핑에 내장. mock 레인은 `-L mock` + `MOCK_MCP_PROFILE` 필수.
- **스폰 = handoffkeep tasks 기록 의무**: 스폰의 claim·`refs.job_id` 바인딩은 `wrk spawn
  --task`가 한 번의 `tasks claim --by --job-id`로 직접 쓴다(#768) — 호출자가 따로
  `tasks claim`·`tasks next`를 치지 않는다(handoffkeep #769부터 잡 링크 없는
  `claimed`·`in_progress` 기록은 `task_job_required`로 거부; 잡 없는 decide/ops 전이는
  `--no-job <reason>`을 단다). 이후의 `transition`·`refs`(`--pr`/`--head-sha`/
  `--report-path`) 기록 의무는 그대로다. 태스크 상태의 정본은 세션 기억이 아니라
  **tasks 큐**다 — 놓침 방지의 근간. **워커 단위 트래커 이슈는 만들지 않는다.**

## 4. 기동·주입·감시

- 기동은 **`wrk spawn`** 우선(worktree+탭+기동+주입 원샷):
  ```bash
  wrk spawn -c <worktree> -m <프로필> -p <프롬프트파일> -w <워크스페이스> -l <라벨> \
            --t <T0..T3> --owner <내 세션 이름> [-L live|mock] [--effort <레벨>] [--job <id>]
  wrk --help          # 서브커맨드·옵션 전체
  ```
  🔴 **task 연결(#768, decision/2026-09-27/task-job-linkage 항목 1)**: 워커·빌더
  스폰은 반드시 hk task에 묶인다. 자기 task가 있는 스폰은 `--task <id>`를 붙인다
  (빌더는 필수 — 없으면 스폰이 usage 에러로 죽는다). tester·자문·후속 세션은
  `--task` 대신 **부모 task를 상속**한다: `--parent-job <부모잡>`을 주거나 아무것도
  안 주면 스폰한 pane의 `ARBITER_JOB` claim 메타 → `HK_TASK_ID` 환경 순으로
  해석된다(스폰된 pane에는 `HK_TASK_ID`가 자동으로 실린다 — pane 안에서의
  워커 스폰은 보통 아무 옵션 없이 상속된다). 상속된 세션은 task를 다시
  claim하지 않고 잡 메타에 `task_id`+`task_inherited_from`만 남긴다.
  handoffkeep이 안 닿으면 스폰은 거부된다 — `--task-hk-bypass`로만 뚫리고
  그 오버라이드는 잡 메타에 기록된다.
  신규 workspace 규약: workers(herdr workspace w16)는 worker/tester 신규 세션에,
  orchs는 orch류 신규 상주 세션에 사용한다. 기존 세션은 이동하지 않으며,
  이슈별 -w 값을 생략하거나 추측하지 않는다.
  `-m` 은 **필수**다(기본값 없음 — 오타가 조용히 Claude 워커를 띄우던 결함을 제거했다).
  🔴 **`--owner <내 세션 이름>` 을 항상 붙여라**(ROB-1206). 이 값이 arbiter 의 `owner_lane`
  으로 기록되어 **나중에 §6 회수의 조회 키**가 된다. 빠뜨리면 `default` 로 들어가고, 그러면
  네 워커를 다시 찾을 수 없다 — 2026-08-02 에 기록 22건이 전부 `default` 라 어느 orch 도
  자기 워커를 조회하지 못했고, 잔여 세션 11개를 운영자 세션이 손으로 걷어냈다.
  `-L live|mock` 은 **실행 레인**이고 `--owner` 는 **스폰 주체**다 — 축이 다르니 섞지 마라.
  모르는 인자는 무시되지 않고 에러가 난다. 수동 기동은 `herdr agent start <유일이름>
  --workspace <ws> --cwd <worktree> --no-focus -- <argv>`.
  🔴 **`--owner` 는 회수용이지 완료 알림 라우팅이 아니다.** `--owner` 는 §6 조회 키와
  (`--role worker` 한정) 그 워커 자신의 `job.completed` 직접 전달에만 쓰인다.
  `job.escalate`·`job.joined`(PR 제출) 는 `--owner` 로 라우팅되지 않는다 — 그건
  `--role builder --parent PARENT_LANE` 의 `--parent` 몫이고, builder 는 `--owner` 를
  아예 받지 않는다(`wrk spawn --help` 참조). **`--parent` 없이/틀리게 스폰한 builder 는
  PR 을 올려도 오케스트레이터가 알 방법이 없다** — 2026-09-16 사고(빌더가 11:01 에 push
  하고 PR 을 올렸는데 오케스트레이터는 2시간 동안 몰랐다)가 정확히 이 경로였다. `--owner`
  체크리스트만 따라가면 builder 스폰에서 이 사고가 재현된다: 완료 알림이 필요하면
  네가 스폰하는 게 worker 인지 builder 인지부터 확인하고, worker 는 `--owner`,
  builder 는 `--lane`+`--parent` 를 맞춰라.
- **effort 는 인자로 준다** — 같은 모델도 effort 로 급이 바뀐다(실측: Luna Light 42 → Ultra 75).
  프로필 이름에 effort 를 박지 말고 `--effort` 를 쓴다.
  🔴 effort 별 실사용 건수는 `quota_pool_records.profile` 이 아니라 events payload 의
  **`launch_profile`** 으로 센다(§2-2, ROB-1213). 정규화 컬럼은 effort 를 뭉갠다.
- `~/bin/herdr-spawn` 은 `wrk spawn` 으로 위임하는 shim 이다(옛 경로 호환용, 신규 사용 금지).
- 브리프 주입과 제출 검증은 **`relay.md` 절차**를 따른다(제출 검증 생략 금지,
  접수 확인 도구 1회 지시 포함).
- pane kind별 지시·중단·답변 통지 분기와 매트릭스·측정 조건·예외 삭제 조건은
  **`relay.md` §3-1 정본**을 참조한다(통지는 claude pane 에만 `lane.event`,
  비-claude pane 은 §3-1 의 직접주입 경로). **후속 라운드·보충 지시의 주입은
  `panewire prompt --uptake status-transition` 으로 한다** — `relay.md`
  §3-3 후속 라운드·보충 지시의 주입이 정본이고, 하네스별 제출 증명 차이
  (claude·codex 만 증명 가능, 그 외 하네스는 `unproven`)와 rc≠0 처리도 그 절을
  따른다. `herdr pane send-text`·`send-keys`는 복구 목적 외에 금지한다 — 제출도
  제출 확인도 없이 컴포저 적재만 한다. `panewire emit` 의 `rc=0` 은 전달 증거가
  아니며, 보낸 쪽은 `herdr agent read <pane>`로 도착을 확인한다.
- **완료 센티널**: job 이 arbiter 에 등록되면 `wrk spawn` 이 감시자를 분리 기동한다. 판정표와
  환경변수(`WRK_SENTINEL_TRANSIENT_MAX`·`WRK_SENTINEL_LOST_GRACE`·`WRK_SENTINEL_HERDR_SESSION`)는
  README "완료 센티널 판정표" 가 정본이다. 요지: **빈 `agent get` 응답은 pane 소멸의 증거가
  아니다**(소켓 일시 정지·비기본 herdr 세션). 확정 소멸 에러 코드만 즉시 `job.lost` 이고,
  일시 장애는 연속 10회(≈5분) 넘겨야 `job.lost(herdr_unreachable)` 이며, 그 뒤에도 30분
  유예 동안 감시해 report 가 나오면 `job.completed` 를 추가로 쓴다. 같은 경로의
  report 를 갱신한 후속 라운드는 내용만 바뀌어도 `<stem>-r<N>.md` 스냅샷 경로로
  relay 된다(#1014 — 같은 경로+다른 내용은 panewire emit outbox 키 충돌로
  거부된다). 이 자동 스냅샷은 이 변경이 설치된 agent-skills에만 적용된다 —
  그 전까지는 `report-r<N>.md`를 직접 쓰고 그 경로를 `wrk done`에 넘겨라
  (명시한 새 경로는 있는 그대로 relay된다). 판정은 잡 디렉토리
  `completion-sentinel.log` 에 한 줄씩 남으니 "빌더가 무한 대기" 를 의심할 땐 그 파일부터 봐라.
  🔴 원격/데스크톱처럼 herdr 서버가 비기본 세션에 사는 호스트에서는 스폰 시
  `HERDR_SESSION`(또는 `WRK_SENTINEL_HERDR_SESSION`)을 반드시 넘겨라 — 2026-09-04 에 이 값이
  센티널에 닿지 않아 그날 스폰한 거의 모든 잡이 30초 만에 오탐 `job.lost` 로 찍혔고, 워커가
  정상 완료해도 아무도 `job.completed` 를 쓰지 못해 사람이 3회 손으로 전달했다.
- 감시는 `agent_status` **전이 기반**(working→비working 2분 지속 시 확인). kiro/agy는 status
  플랩(작업 중 idle/done 오표시) — 완료 판정은 상태가 아니라 **산출물/화면 마커**(PR URL·
  최종보고·inbox 파일)로. 스폰 후 5분 내 실 툴호출 없으면 stuck 판정→재스폰.
- herdr 공식 시맨틱(0.8 번들 스킬, `herdr --skill` 이 정본): **`done` = 미열람 idle**
  (백그라운드 완료 후 아직 UI 에서 안 봄; CLI read 는 seen 처리 안 함) — done/idle 은 같은
  비-working 상태다. 특정 문자열 대기는 반복적인 read 루프 대신
  **`herdr pane wait-output <pane> --match <텍스트> --timeout <ms>`** 를 써라(기존 출력에도
  즉시 매치). 에이전트 이름/라벨은 **`[a-z][a-z0-9_-]{0,31}`** — wrk 가 스폰 전에 검증한다.
  단, 라벨이 hub 레인으로도 쓰인다: `session_machine_ids` 에 매핑된 세션에서는 라벨이
  `panewire lanes add` 의 레인명이 되는데, panewire 의 레인 규칙은 `^[a-z0-9-]{1,32}$` 라서
  `_` 가 들어간 라벨은 wrk 라벨로는 유효해도 레인명으로는 거부된다 — 그런 스폰은 한 번
  경고하고 **레인 미등록**으로 착지한다(#1010). 레인 등록이 필요하면 라벨에 `_` 를 쓰지
  말 것(라벨 규칙 자체는 그대로다).

### 4-2. 🔴 착지 검증 — 스폰 직후 필수

스폰 명령이 정상 반환됐다고 해서 워커가 브리프를 실제로 받은 것은 아니다. `wrk spawn`은
브리프를 **`panewire prompt` 한 경로**로 주입하고(uptake 없음 — working 콜드 부트 pane 도
받는다), panewire 가 제출을 증명하면(rc 0) 그대로 착지다. panewire 데몬 소켓이 없을 때(rc 4) 또는 panewire 가
설치되지 않았을 때(둘 다 보장된 미전송)만 herdr 직접 주입 1회로 폴백하고 OK 행 끝에 `via=herdr-fallback` 을 붙인다.
panewire 가 증명하지 못한 경우(claude·codex 외 하네스, 또는 실제 착지했는데 rc 6)에만 `wrk`는
**`relay.md` §3-1 정본에 따라** 읽기 전용으로 visible 큐 표시와
`herdr agent read <pane> --source recent-unwrapped --lines 200`의 브리프 marker를 둘 다
확인한다. visible 화면에서 밀려나도 transcript에는 남고, 큐 대기 중 주입은
`recent-unwrapped`에 아직 안 보이므로 한쪽만 보면 미착지로 오판한다. visible의 `Pasted text`
칩도 queued 양성 증거지만, `working` 단독은 콜드 부트 중에도 나오므로 착지 증거가 아니다.
큐 표시 원문은 하네스마다 다르다 — 하네스별 칩·푸터의 정본은 `relay.md` §3-2 표다.
일반 프로필은 30초, codex는 60초 창에서 0.5→2초로 backoff 관찰하고, 양성 증거가 없을
때만 새 prompt 파일로 panewire 를 통해 최대 한 번 재주입한다(panewire 의 rc 6 단독은 재주입 사유가
아니다 — 확인 관찰이 확정 음성이어야 한다). 자동화는 `--landing-strict`로 pane의 OK 행은 보존한 채
미착지를 exit 76으로 받을 수 있다.

**`wrk`의 `OK status=done`도, herdr의 정상 JSON 응답도 둘 다 착지 증거가 아니다** —
콜드 스타트 실측 4회 중 3회 유실(자동 응답은 정상이었지만 실제 화면에는 브리프가
표시되지 않은 채 워커가 idle로 멈춰 있었다). 이 원칙("자동 보고는 증거가 아니다")은
`wrk` 자동화가 향후 착지를 보증하게 되더라도 별개로 유지할 가치가 있다 — 자동화 자체가
실패하거나 우회되는 경로는 항상 남는다.

