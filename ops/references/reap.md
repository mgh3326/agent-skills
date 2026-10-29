# reap — 끝난 워커 회수

## 6. 워커 회수 — 스폰한 주체가 거둔다

**만든 곳이 회수한다.** 워커가 언제 끝났는지, 그게 "끝"인지 "대기"인지 아는 것은
job 맥락을 가진 스폰 주체뿐이다. orch 뿐 아니라 **직접 스폰한 어떤 세션에도 적용된다.**

### 6-1. 트리거 — 깨어날 때마다 1회

**orch 는 워커 완료를 자동으로 알지 못한다**(2026-08-02 실측: 워커를 스폰한 뒤 1분 45초 만에
턴을 반환하고, 워커 둘이 도는 중에 `done→idle` 로 내려갔다. 주기적으로 상태를 조회하지 않는다).
따라서 회수는 **깨어난 순간에 확인해서** 한다 — 새 릴레이를 받았을 때, terminal 을 선언할 때,
운영자가 깨웠을 때. 확인 비용은 몇 초이고 그때 너는 이미 깨어 있다.

```bash
arbiter status --lane <내 세션 이름> --json     # 내 job 목록 (세션 기억 아님)
# 각 job → jobs/<job_id>/events/*job.claim.json 의 agent_label
wrk find <agent_label>                          # → pane_id · status
herdr pane close <pane_id>                      # 회수
```
🔴 **세션 기억으로 목록을 만들지 마라.** compact 되면 사라진다. 정본은 arbiter + job 이벤트다.

### 6-2. 회수 조건 — 셋 다 만족할 때만

1. **job 이 terminal** — 머지·close·escalation **완료**. 이건 네 판단이다.
2. **산출물이 파일로 확보** — `jobs/<job_id>/` 에 최종 보고가 있다. 화면에만 있으면 닫는
   순간 증거가 소실된다.
3. **pane 이 비-working**.

### 6-3. 🔴 비-working 은 회수 사유가 아니다

**라운드가 끝났을 뿐 결정을 기다리는 중일 수 있다.** 그 세션에 재주입할 예정이면 남겨라.
2026-08-02 실사례: `uber-elig-worker` 가 r3 에서 `NEEDS_INFO` 로 정지해 idle 이었는데,
운영자 결정이 나온 뒤 **같은 세션에 재주입**해 이어갔다. 컨텍스트가 자산이었다 —
그때 "idle 이니까 정리"했으면 처음부터 다시 올려야 했다.

### 6-4. `pane close` 만 쓴다

`herdr tab close` 는 쓰지 마라 — 같은 탭에 분할된 다른 pane 이 함께 죽는다
(2026-07-20 실사고: 수동 스폰한 캡틴 pane 동반 사망; 당시 캡틴 = 현 빌더). `pane close` 는 그 pane 만 닫는다.

### 6-5. 죽은 탭 스윕 — `agent list` 로는 안 보인다

🔴 **`herdr agent list` 는 살아 있는 에이전트만 보여준다.** 스폰이 실패했거나 에이전트가
종료된 탭은 거기 없다 — 그래서 agent list 기준 정리는 죽은 탭을 영원히 못 걷는다
(2026-08-05 실측: w16 에 살아 있는 에이전트 7개, 실제 pane 18개 — 나머지 11개가
셸 프롬프트만 남은 죽은 탭이었고 스폰 재시도 잔해 krb0-v 만 3개였다).

**스윕은 `herdr pane list` 에서 시작한다**:

```
herdr pane list → 해당 workspace pane 전수
분류:
  ① 살아 있는 에이전트 pane (agent list 와 대조)     → §6-2/6-3 규칙대로
  ② terminal_title 이 셸 프롬프트(<user>@…)          → 죽은 탭 후보. 그 pane 의 job 이 terminal 이고
                                                         보고서가 지정 경로에 있을 때만 닫는다. 아니면 둔다
  ③ 그 외 (판별 불가)                                 → 화면을 읽고 판단
```
- 스폰이 실패하면 job 디렉토리(`jobs/<id>/spawn-failure-screen.txt`)에 실패 pane 의
  화면 캡처가 남고, `WRK_KEEP_FAILED_PANE=1` 이면 수동 확인용으로 pane 자체도 닫지 않고 남는다.
- ②를 닫아도 잃는 것은 종료된 에이전트의 스크롤백뿐이다 — 산출물 정본은
  `jobs/<id>/` 파일이다(§6-2 조건 2 가 이래서 선행한다).
- worktree 는 pane 과 별개다 — pane 을 닫아도 worktree 는 남는다(정리는 별도 판단).

(ROB-1214 로 wrk 가 스폰 실패 시 자기 pane 을 닫게 됐으므로 신규 누수는 줄지만,
비정상 종료·수동 스폰 잔해는 계속 생긴다 — 스윕은 여전히 필요하다.)

### 6-6. `wrk reap` — 끝난 pane 일괄 회수

수동 회수는 놓친다. 2026-09-04 하루에 40~60개 pane 이 쌓였고 ~50개를 사람이 손으로
닫았다(pane 누적은 herdr 서버 fd·구독 부하로 직결된다). `wrk reap` 은 **인박스가
증명한 것만** 닫는다 — 세션 기억도, `agent list` 추측도 아니다.

```bash
wrk reap --lane <내 세션 이름>              # dry-run: 닫을 목록만
wrk reap --lane <내 세션 이름> --apply      # 실제 회수
```

후보 조건(전부 충족): terminal 이벤트(`job.completed`·`job.joined`·`job.revoked`)가 있고,
그 **뒤에** `job.claim`·`job.reclaim`·`job.spawned`·`job.reprompted` 가 없고(끝난 뒤 다시 잡힌
잡은 살아 있는 작업 — `reason=reclaimed-after-terminal`), 그 이벤트가 `--grace`(기본 10m)보다
오래됐고, **가장 늦은** `job.spawned` 영수증의 pane 이 herdr 에 살아 있고 상태가 `idle`·`done`
이고, claim·reclaim·spawn 영수증에 `keep: true`(`wrk spawn --keep`)가 없고(`reason=protected`), herdr 가 말하는 그 pane 의 탭이 기록된 탭과 같고(`reason=tab-mismatch`), close 직전에 다시
읽은 `herdr tab list` 가 그 탭의 pane 을 **정확히 1개로 확인**하고(조회 실패·파싱 실패·탭 누락·
비정수는 닫지 않는다 — `reason=tab-count-unknown`), 아직 `job.reaped` 가 없을 것. 🔴 `--apply` 는 `--lane` 없이
거부된다(전역 회수 금지). `working`·`blocked` pane, terminal
이벤트 없는 잡, herdr 가 해석 못 하는 pane 은 건드리지 않는다. 빌더 pane(legacy captain payload 포함)은
`--include-builders` 없이는 제외한다(`--include-captains`는 legacy 별칭). 닫은 잡에는 `job.reaped`(`pane_id`·`tab_id`·`at`)를 남긴다.

🔴 `wrk reap` 은 §6-4 의 예외가 아니라 그 규칙이 적용되는 좁은 경로다. 닫는 대상은
`wrk spawn` 이 **그 잡을 위해 직접 만든 탭**(`job.spawned` 의 `tab_id`)뿐이다 — 손으로
스폰했거나 사람이 pane 을 분할해 붙인 탭은 `job.spawned` 기록이 없어 후보가 되지 않는다.
수동 회수는 여전히 `pane close` 다.

🔴 `wrk reap` 은 §6-2 의 **1번(job 이 terminal 인가)을 대신 판단하지 않는다.** terminal
이벤트를 쓰는 것은 여전히 너의 판단이고, reap 은 그 판단이 파일로 남은 잡만 거둔다.
결정을 기다리며 idle 인 세션(§6-3)에는 terminal 이벤트가 없으므로 자동으로 제외된다.

### 6-7. 백스톱

회수를 놓친 잔여는 계속 생긴다(세션 사망·compact·`--owner` 미지정 이력).
**운영자 요청 시 스윕**은 이 규칙과 별개로 유지한다 — 자동화가 아니라 이중화다.

