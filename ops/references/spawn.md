# spawn — 기동·주입·착지·task 연결

**launcher 는 `runtug` 하나다.** 한 task 에는 한 번만 제출한다(같은 live claim 의 재제출은 rc 74).
플래그 정본은 `runtug <cmd> --help` 와 runtug README·`DESIGN.md`·`docs/config.md`(exit code 표)다.

| 일 | 명령 |
|---|---|
| 스폰 | `runtug spawn` (`--dry-run` 미리보기, `--wait` 블로킹 대기) |
| 완료·ESC 기록 | `runtug done <job> [--report P]` · `runtug escalate <job> --question '<text>'` |
| 풀린 잡을 기존 pane 에 되묶기 | `runtug restore <job>` |
| 회수 | `runtug reap` · `runtug prune` (`reap.md`) |
| 무거운 실행 | `runtug heavy -- <cmd>` (`heavy.md`) |
| 레인 감사 | `runtug lanes-missing` |
| 대상 찾기·이름 복구 | `runtug find <이름\|라벨> [--pane-only]` · `runtug name-sync [--apply]` |
| 호스트·프로필 | `runtug hosts` · `runtug profiles` (`spawn-hosts.md`) |
| 산출물 이동·정리 | `runtug artifacts move\|sweep` (`--apply` 없으면 미리보기) |

runtug 에는 `round`·`joined`·`worktree-reap`·o3·takeover·grant·`--landing-strict` 가 없다 — tester
라운드는 폐지됐고 review·landing 은 mergewake 몫이며, worktree 정리는 `runtug reap --worktrees` 와
mergewake reap 이 한다.

## 무인 실행·task 기록

- kiro 워커: "Linear는 읽기만, 이슈·코멘트 변경 금지" 필수(kiro Linear MCP는 write 가능).
- 무인 워커의 승인 우회 플래그는 runtug 하네스 launch 에 내장돼 있다. mock 레인은 `-L mock` +
  `MOCK_MCP_PROFILE` + `WRK_MOCK_MCP_CONFIG` 이고 claude·codex 만 된다(그 외·원격 mock 은 rc 79).
- **스폰 = handoffkeep tasks 기록 의무**: runtug spawn 은 숫자 task binding 없이는 거부한다. 자기
  task 는 `--task <id>`, 아니면 부모 잡을 상속한다 — `--parent-job <부모잡>`, 아무것도 안 주면 pane
  의 `ARBITER_JOB`(스폰된 pane 에 실린다). 잡 상속은 `--report` 가 필수이고 task 를 다시 claim 하지
  않는다. 둘 다 없으면 `HK_TASK_ID` 를 `--task` 처럼 쓴다. claim·`refs.job_id` 바인딩은 브리프 제출
  확인 뒤 runtug 가 `tasks claim --by <라벨> --job-id <잡>` 한 번으로 쓴다 — 호출자가 따로
  `tasks claim`·`tasks next` 를 치지 않는다. task 가 다른 잡에 묶였거나 `merged`·`dropped`·`hold`·`needs_decision` 이면
  rc 2. handoffkeep 이 안 닿으면 rc 70 이고 `--task-hk-bypass` 는 그 가용성 장애만 뚫는다(읽힌 거절은
  못 뚫고, 오버라이드는 잡 메타에 기록된다). 이후의 `transition`·`refs`(`--pr`/`--head-sha`/
  `--report-path`) 기록 의무는 그대로다. 태스크 상태의 정본은 세션 기억이 아니라 **tasks 큐**다 —
  놓침 방지의 근간. **워커 단위 트래커 이슈는 만들지 않는다.**
- **task 제목 표식**: `(grade X, Tn)` 이 없으면 rc 77, `--t` 가 표식의 T 와 다르면 rc 77 이다 — 상속
  스폰(자문 포함)도 부모 task 의 T 를 쓴다.

## 4. 기동·주입·감시

- 기동 — 미리보기 후 `--dry-run` 을 빼고 실행한다:
  ```bash
  runtug spawn -c <worktree> -m auto -p <브리프파일> -w <워크스페이스> -l <라벨> --t <T0..T3> \
    --task <id> --role worker --owner <내 레인> --host auto [--tags a,b] \
    [--report ~/work/herdr-inbox/jobs/<라벨>/report.md] [--effort <레벨>] [-L live|mock] --dry-run
  ```
  `--dry-run` 은 고른 호스트·프로필·selection 기록과 host-safety preamble 이 붙은 최종 브리프를
  보이고 pane·lease·claim 을 만들지 않는다. 모르는 인자는 무시되지 않고 rc 2 다. 수동 기동은
  `herdr agent start <유일이름> --workspace <ws> --cwd <worktree> --no-focus -- <argv>`.
- **모델은 runtug 가 고른다**(`-m auto` 또는 생략): 쿼타 카탈로그 rung 을 task 의 grade·role·
  `--tags` 로 거르고, pool-order 정책(free → WASTE 구독 → credit → ranked; urgent 는 free 가 맨 뒤,
  urgency 는 `--urgency` 또는 hk priority 1–2)으로 줄 세운 뒤 presence 와 quota gate 를 통과한 첫
  후보를 쓴다. unknown·stale 증거는 탈락이다(fail closed). 명시 `-m <프로필>`·`--host <이름|local>`
  은 `--override-reason '<사유>'` 가 필수이고 기록되며, quota gate 는 그대로 적용된다.
  escalation·consult_only rung 은 `--allow-escalation` 없이 자동 후보가 아니다. 추천 목록에서
  모델을 고르지 않는다.
- 쿼타 확인은 `pacelever --json`(공유 쿼타는 handoffkeep 경유), 낡은 풀은 `pacelever refresh <풀>`.
- 🔴 **워커의 `-c` 는 그 PR 의 worktree 다**(먼저 만든다) — mergewake reap 은 pane cwd 가 그 PR
  worktree 인 것으로 워커를 찾는다. `-l` 은 잡 id 의 기본값이자 pane 이름이고 mergewake 는
  `<jobs>/<pane 이름>` 이 있어야 닫으므로 `--job` 을 라벨과 다르게 주지 않는다.
- 신규 workspace 규약: workers(herdr workspace w16)는 worker 신규 세션에, orchs 는 상주 세션에
  쓴다. 기존 세션은 이동하지 않으며, 이슈별 -w 값을 생략하거나 추측하지 않는다.
- 🔴 **`--owner <내 레인>` 을 항상 붙여라**(ROB-1206). arbiter 의 `owner_lane` 으로 기록되어 회수
  조회 키(`reap.md`)이자 worker 레인의 parent 가 된다. 빠뜨리면 `default` 로 들어가 네 워커를
  다시 찾을 수 없고 완료 push 도 오지 않는다 — 2026-08-02 에 기록 22건이 전부 `default` 라 잔여
  세션 11개를 손으로 걷어냈다. `-L live|mock` 은 **실행 레인**이고 `--owner` 는 **스폰 주체**다.
- 🔴 **`--role builder`(위임 좌석)는 `--lane`+`--parent`+`--task` 가 필수이고 `--owner` 를
  거부한다**(rc 2). ESC·완료는 `--parent` 로 간다 — `--parent` 가 틀린 좌석은 PR 을 올려도 부모가
  모른다(2026-09-16 사고: push 후 2시간 동안 아무도 몰랐다).
- **effort 는 인자로 준다** — 같은 모델도 effort 로 급이 바뀐다(실측: Luna Light 42 → Ultra 75).
  프로필 이름에 effort 를 박지 말고 `--effort` 를 쓴다(자동 선택은 rung 의 effort 를 쓴다).
  🔴 effort 별 실사용 건수는 `quota_pool_records.profile` 이 아니라 events payload 의
  **`launch_profile`** 으로 센다(ROB-1213). 정규화 컬럼은 effort 를 뭉갠다.
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
- **완료 감시자**: `--report` 를 준 잡에는 runtug 가 잡별 감시자를 분리 기동한다. report 가 두 번의
  관측 동안 안정되면 `runtug done` 과 같은 경로로 기록·relay 하고, pane 이 두 번 연속 안 보이면
  소실을 기록하고 quota 를 푼다. 수명은 `WRK_COMPLETION_TIMEOUT_S`(기본 3600초)이고 만료는 잡을
  남긴다. `--report` 는 절대경로이고 잡(또는 부모 잡) 디렉터리 안이어야 한다(아니면 rc 2). 같은
  경로를 갱신한 후속 라운드는 `runtug done` 이 중복 내용을 거르고 바뀐 내용을 스냅샷 경로로
  relay 한다 — relay 실패는 `job.relay_failed` 와 `relay=file-only` 로 남는다. herdr 서버가 비기본
  세션에 사는 호스트에서는 `HERDR_SESSION` 을 넘긴다. 감시자의 공개 판정 로그나 상태 파일은 없다 —
  판정은 잡 이벤트로 본다.
- 감시는 `agent_status` **전이 기반**(working→비working 2분 지속 시 확인). kiro/agy는 status
  플랩(작업 중 idle/done 오표시) — 완료 판정은 상태가 아니라 **산출물/화면 마커**(PR URL·
  최종보고·inbox 파일)로. 스폰 후 5분 내 실 툴호출 없으면 stuck 판정→재스폰.
- herdr 공식 시맨틱(0.8 번들 스킬, `herdr --skill` 이 정본): **`done` = 미열람 idle**
  (백그라운드 완료 후 아직 UI 에서 안 봄; CLI read 는 seen 처리 안 함) — done/idle 은 같은
  비-working 상태다. 특정 문자열 대기는 반복적인 read 루프 대신
  **`herdr pane wait-output <pane> --match <텍스트> --timeout <ms>`** 를 써라(기존 출력에도
  즉시 매치). runtug 는 잡 id·라벨을 `[A-Za-z0-9][A-Za-z0-9._-]{0,127}` 로 검증하지만 worker
  라벨은 허브 레인명도 되고 panewire 레인 규칙은 `^[a-z0-9-]{1,32}$` 다 — 그 밖의 라벨은 레인
  미등록으로 착지하므로 라벨은 소문자·숫자·`-` 32자 안에서 짓는다(#1010).

### 4-2. 🔴 착지 검증 — 스폰 직후 필수

스폰 명령이 정상 반환됐다고 해서 워커가 브리프를 실제로 받은 것은 아니다. runtug 는 idle pane 에
`herdr agent prompt` 로 브리프를 넣고(cmd 는 `pane send-text` 후 `send-keys return`), pasted-text
칩 없는 working 전이를 봐야 OK 행에 `landed=yes` 를 찍는다. 시간 안에 못 보면 submit 키를 한 번
더 보내고 다시 보며, 두 번째 사본은 붙여 넣지 않는다. 그래도 미확인이면 rc 76 이고, 커밋 전
pane 을 닫고 화면을 잡 디렉터리에 남긴다.

`landed=yes` 뒤에도 스폰한 쪽은 한 번 읽기 전용으로 확인한다 — **`relay.md` §3-1 정본에 따라**
visible 큐 표시와 `herdr agent read <pane> --source recent-unwrapped --lines 200` 의 브리프 marker 를
둘 다 본다. visible 화면에서 밀려나도 transcript 에는 남고, 큐 대기 중 주입은 `recent-unwrapped` 에
아직 안 보이므로 한쪽만 보면 미착지로 오판한다. visible 의 `Pasted text` 칩도 queued 양성 증거지만,
`working` 단독은 콜드 부트 중에도 나오므로 착지 증거가 아니다. 큐 표시 원문은 하네스마다 다르다 —
하네스별 칩·푸터의 정본은 `relay.md` §3-2 표다. 양성 증거가 없을 때만 새 prompt 파일로 panewire 를
통해 최대 한 번 재주입한다(확인 관찰이 확정 음성이어야 한다).

**runtug 의 `OK … landed=yes` 도, herdr 의 정상 JSON 응답도 착지 증거가 아니다** — 콜드 스타트
실측 4회 중 3회 유실(자동 응답은 정상이었지만 실제 화면에는 브리프가 표시되지 않은 채 워커가
idle로 멈춰 있었다). 이 원칙("자동 보고는 증거가 아니다")은 launcher 자동화가 착지를 보증하게
되더라도 별개로 유지한다 — 자동화 자체가 실패하거나 우회되는 경로는 항상 남는다.
