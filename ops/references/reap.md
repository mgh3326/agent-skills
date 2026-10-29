# reap — 끝난 워커 회수

## 6. 누가 거두나

### 6-0. 머지된 PR 의 워커 — mergewake 가 거둔다

mergewake 데몬(`reap` 역할)이 머지 직후 그 PR 의 워커 pane 을 닫고(마지막 화면은
`<jobs>/<pane 이름>/pane-screen.txt` 에 남는다), `worktree_after`(기본 168h) 동안 revert 가 없으면
worktree 와 branch 를 지운다. **repo 세션은 머지 후 pane 을 손으로 닫지 않는다.**

- 매칭은 이름이 아니라 위치다: pane cwd 가 linked worktree 이고, 현재 branch 가 PR head branch,
  checkout commit 이 PR head SHA, origin 이 그 repo 여야 한다. 그래서 워커는 PR worktree 를 `-c` 로,
  잡 id 를 라벨로 스폰한다(`spawn.md` §4).
- 닫기 전에 pane 이 `idle`·`done` 이어야 하고 `<jobs>/<pane 이름>` 이 있어야 한다(없으면
  `not-a-job`). close 직전에 다시 읽어 바뀐 pane 은 건너뛴다.
- 보호: pane 이름 `*-integrator`·`director-*`·`fleet-tooling-*`·`consult-*`·`cmd`, 이름 없는 pane,
  linked worktree 밖 pane. worktree 는 깨끗하고 regenerable 밖 gitignored 파일이 없을 때만 지운다.
- 무엇을 닫을지 보려면 `mergewake reap --repo <owner>/<repo> --pr <n> --dry-run`. acting 은 데몬
  몫이다 — 손으로 `--apply` 하지 않는다.

### 6-1. 그 밖의 pane — 스폰한 주체가 거둔다

자문·머지 안 된 PR·실패 잡의 pane 은 **만든 곳이 회수한다.** 워커가 언제 끝났는지, 그게 "끝"인지
"대기"인지 아는 것은 job 맥락을 가진 스폰 주체뿐이다. 회수는 **깨어난 순간에 확인해서** 한다 —
새 릴레이를 받았을 때, terminal 을 선언할 때, 운영자가 깨웠을 때.

```bash
arbiter status --lane <내 레인> --json     # 내 job 목록 (세션 기억 아님)
# 각 job → jobs/<job_id>/events/*job.claim.json 의 agent_label
runtug find <agent_label>                  # → pane_id · status
herdr pane close <pane_id>                 # 회수
```
🔴 **세션 기억으로 목록을 만들지 마라.** compact 되면 사라진다. 정본은 arbiter + job 이벤트다.

### 6-2. 회수 조건 — 셋 다 만족할 때만

1. **job 이 terminal** — 머지·close·escalation **완료**. 이건 네 판단이다.
2. **산출물이 파일로 확보** — `jobs/<job_id>/` 에 최종 보고가 있다. 화면에만 있으면 닫는
   순간 증거가 소실된다.
3. **pane 이 비-working**.

### 6-3. 🔴 비-working 은 회수 사유가 아니다

**라운드가 끝났을 뿐 결정을 기다리는 중일 수 있다.** 그 세션에 재주입할 예정이면 남겨라.
2026-08-02 실사례: `uber-elig-worker` 가 `NEEDS_INFO` 로 정지해 idle 이었는데, 운영자 결정이
나온 뒤 **같은 세션에 재주입**해 이어갔다. 컨텍스트가 자산이었다.

### 6-4. `pane close` 만 쓴다

`herdr tab close` 는 쓰지 마라 — 같은 탭에 분할된 다른 pane 이 함께 죽는다
(2026-07-20 실사고: 수동 스폰한 pane 동반 사망). `pane close` 는 그 pane 만 닫는다.

### 6-5. 죽은 탭 스윕 — `agent list` 로는 안 보인다

🔴 **`herdr agent list` 는 살아 있는 에이전트만 보여준다.** 스폰이 실패했거나 에이전트가
종료된 탭은 거기 없다(2026-08-05 실측: w16 에 살아 있는 에이전트 7개, 실제 pane 18개 — 나머지
11개가 셸 프롬프트만 남은 죽은 탭이었다). **스윕은 `herdr pane list` 에서 시작한다**:

```
herdr pane list → 해당 workspace pane 전수
분류:
  ① 살아 있는 에이전트 pane (agent list 와 대조)     → §6-2/6-3 규칙대로
  ② terminal_title 이 셸 프롬프트(<user>@…)          → 죽은 탭 후보. 그 pane 의 job 이 terminal 이고
                                                         보고서가 지정 경로에 있을 때만 닫는다. 아니면 둔다
  ③ 그 외 (판별 불가)                                 → 화면을 읽고 판단
```
- runtug 는 스폰 실패 시 실패 pane 의 화면을 잡 디렉터리에 남기고 그 pane 을 닫는다(남겨 두는
  옵션은 없다). 비정상 종료·수동 스폰 잔해는 계속 생기므로 스윕은 여전히 필요하다.
- ②를 닫아도 잃는 것은 종료된 에이전트의 스크롤백뿐이다 — 산출물 정본은 `jobs/<id>/` 파일이다.
- worktree 는 pane 과 별개다 — pane 을 닫아도 worktree 는 남는다.

### 6-6. `runtug reap` — 끝난 pane 일괄 회수

수동 회수는 놓친다(2026-09-04 하루에 pane 40~60개가 쌓여 ~50개를 손으로 닫았다). `runtug reap` 은
**잡 이벤트가 증명한 것만** 닫는다.

```bash
runtug reap --lane <내 레인>              # 미리보기: job=… action=reap|keep reason=…
runtug reap --lane <내 레인> --apply      # 실제 회수
```

- 후보: terminal 잡이고, 그 뒤에 새 claim·reclaim·spawn 이 없고, `--grace`(기본 10m)가 지났고,
  `--keep` 영수증이 없고(`protected`), pane 이 working 이 아니며 이름·탭이 영수증과 같을 것
  (`pane-working-or-mismatch`). close 직전에 잡 기록과 pane 을 다시 읽는다 — 잡이 되살아났으면
  건너뛰고, pane 이 바뀌었으면 rc 75 로 멈춘다. 닫은 잡은 quota 를 풀고 허브 레인을 지우고
  `job.reaped` 를 남긴다.
- 위임 좌석 pane 은 `--include-builders` 없이는 제외한다. `--worktrees` 는 깨끗하고 origin/main 에
  머지된 linked worktree 만 force 없이 지운다(branch 는 남는다).
- 🔴 runtug 는 `--apply` 에 `--lane` 을 강제하지 않는다 — 전역 회수는 금지이므로 항상
  `--lane <내 레인>` 을 준다.
- `runtug prune` 은 같은 규칙에 더해, pane 이 사라진 채 마지막 이벤트가 `--stale-age`(기본 24h)보다
  오래된 live 잡을 정리한다.
- 🔴 `runtug reap` 은 §6-4 의 예외가 아니다 — 닫는 것은 runtug 가 그 잡을 위해 만든 pane 뿐이고,
  수동 회수는 여전히 `pane close` 다. §6-2 의 **1번(job 이 terminal 인가)도 대신 판단하지 않는다**
  — 결정을 기다리며 idle 인 세션(§6-3)에는 terminal 이벤트가 없으므로 자동으로 제외된다.

### 6-7. 백스톱

회수를 놓친 잔여는 계속 생긴다(세션 사망·compact·`--owner` 미지정 이력).
**운영자 요청 시 스윕**은 이 규칙과 별개로 유지한다 — 자동화가 아니라 이중화다.
