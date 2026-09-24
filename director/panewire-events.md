# director 감시 → panewire 이벤트 — 배포 판 기준 목록

정본 요건: hk:doc `task/2026-09-24/director-monitors-to-panewire` (#636). 이 표는
**범위 1(목록화)·범위 4(CI 대기 결론)** 의 산출물이다. 범위 2·3(노드 이벤트 추가)은
노드·허브 배포 일정과 묶여 별도 태스크다.

🔴 **"있음"은 배포된 판에서 실제로 되는 것만**이다. 소스(origin/main)에만 있는 것은
"미배포"로 표기하고, 이 표를 근거로 그 감시를 걷어내지 않는다.

## 배포 판 기준 (2026-09-24 실측)

| 대상 | 판 | 근거 |
|---|---|---|
| 허브 (ncp) | `pw-e401923` (#64, 09-17 머지) | hk:doc `deploy/panewire-hub/20260923T033051Z` — director-1 의 09-23 NCP 실측(서비스 ExecStart 바이너리 `panewire version`, 기동 후 교체 없음). 허브 배포는 BLOCK-3 에 묶여 옛 판 |
| 노드 (desktop) | `pw-05667f4` (#57, 09-14 머지) | 설치본 `panewire version` = `pw-05667f4` · 실행 중 데몬 argv 실측(`--inbox-root` 가 있고 `--hub-jobs-root`·`--checks-config`·`--stall-detect*` 없음 — jobsInboxRoot 는 inbox-root 기본값, cli.go:508-511 @05667f4). #574 카나리 대기로 옛 판 |
| 노드 (mac 등 나머지) | **미측정** | desktop 에서 확인 수단 없음. director pane 주입의 마지막 구간(허브→수신 노드→pane)은 수신 측 노드 판에 달린다 |
| 소스 정본 | `origin/main` `c1b9c0e` | #80(#507)까지 머지 — 허브·노드 모두 미배포 |

이벤트는 발생 측과 라우팅 측이 다른 판일 수 있다: 노드가 만들어 허브가 owner 레인으로
라우팅하는 `job.*`·`lane.event` 는 **두 판 모두가 그 kind 를 알아야** 도착한다.

## 1. 빌더·워커 감시

| 감시하던 것 | panewire 이벤트 | 배포 판 | 근거 |
|---|---|---|---|
| 잡 완료·report 파일 도착 | `job.completed`(report 경로·마지막 줄 포함) → owner lane push | **있음** | 배포 emit 집합 `emitRelayKinds`(emit.go:21 @05667f4·e401923) + 노드 스캔(hub_jobs_client.go:225 @05667f4) + report→owner pane 릴레이 `b1b890e`(#29, 두 판 모두) |
| 잡 에스컬레이션 | `job.escalate` → owner lane push | **있음** | 같은 emit/스캔 집합(단 reason 필수, hub_jobs_client.go:236 @05667f4) |
| 빌더 JOIN 후보 | `job.joined` → owner lane push | **있음** | 같은 emit/스캔 집합(escalate 와 마찬가지로 reason 필수) |
| 임의 레인 통지(사람·다른 세션의 주입 포함) | `lane.event` → owner lane push | **있음** | emit 집합 + events-lane 네임스페이스 스캔(scanHubLaneEventsWithin, hub_jobs_client.go @05667f4) |
| 워커 정지 — settled idle/done 전이 | `idle-wake` → owner lane `lane.event` 알림 | **있음 — claim·spawn 된 잡의 pane 한정** | idle_wake.go 두 판 모두; settle 경과 후 1회 알림. owner 를 해석할 수 없는 pane 은 `unknown_owner` 로 억제된다 |
| 잡 claim | `job.claim(ed)` → heartbeat `active_jobs` 등록 | **있음 — 풀**(owner lane push 없음) | 스캔은 claim 의 agent label 만 기억하고 relay 하지 않는다(hub_jobs_client.go:218-224 @05667f4); 허브는 첫 등록에 이벤트를 내지 않는다(hub_jobs.go:236-242 @e401923) |
| 허브 측 잡 상태 변화 | `job.orphaned`·`job.recovered`·`job.reassigned`·`job.revoked` 허브 broadcast | **있음 — Telegram·허브 UI(director 레인 아님)** | hub_jobs.go @e401923(:254·:383·:479·:503); `job.orphaned` 는 Telegram `SendJob` 도 보내고(:520-531) `GET /v1/jobs/orphaned` 풀도 있다(hub.go:558 @05667f4). 노드 다운으로 잡이 떨어질 때 쓸 수 있는 유일한 배포 신호다 |
| 워커 정체 — working 중 hang | stall detection v1 → `lane.event` | **미배포** | `69068b0`(#66) origin/main 만. shadow 모드이고 `--stall-detect-notify` 기본 off — 배포돼도 notify 켜기 전까지 알림 없음 |
| pane 소실·job 회수 | `job.lost`·`job.revoked` owner-lane 릴레이 | **미배포** | `c1b9c0e`(#80) origin/main 만. 배포 판 emit 집합에 두 kind 없음 — wrk sentinel 이 로컬 파일로 쓰고(bin/wrk:2103 주석) hub→node revocation 은 노드가 로컬 기록(hub_client.go:668 @05667f4)하지만, **director 에 push 되지 않는다**. idle-wake 도 pane 소실을 알리지 않는다 — `pane_missing` 은 후보 취소다(idle_wake.go:402 @05667f4). `panewire wait --agent` 도 pane 소멸에 끝나지 않고 timeout 까지 기다린다(wait.go @05667f4) |
| `job.spawned`·`job.reaped`·`job.reclaim` 등 나머지 잡 이벤트 | — | **없음** | 배포 판뿐 아니라 origin/main 의 `emitRelayKinds`·스캔 대상에도 없다 — 배포를 기다리는 항목이 아니라 새 이벤트 추가 대상이다 |
| 임의 pane 상태 전이(working→blocked 등) | — | **없음**(범위 2 — 노드가 내는 이벤트로 설계) | herdr 이벤트는 노드 로컬 store 기록·idle-wake 판정 입력일 뿐 push 경로 아님(events.go @05667f4) |
| 워커 머신 로드·메모리·쿼터·세션 | heartbeat telemetry → 허브 | **있음 — 풀**(director push 아님) | heartbeat payload `host_load`·`host_memory`·`quota`·`sessions`(hub.go:1106 @05667f4); 허브 `/v1/nodes`·console(#45/#598)에서 조회 |

## 2. 호스트 건강

| 감시하던 것 | panewire 이벤트 | 배포 판 | 근거 |
|---|---|---|---|
| 노드 다운·heartbeat stale | 허브 alert | **있음 — 경로는 Telegram**(director 레인 아님) | hub_alert.go @e401923: heartbeat 관측→alert 상태기계→`notifier.Send`(hub_tg.go). watched node-down 재알림 `cf58951` 두 판 모두 |
| 커스텀 호스트 체크 결과 | `--checks-config` 체크 → heartbeat.checks → 허브 alert | **기능 있음 · desktop 미설정** | checks.go `LoadHubChecksConfig`·`runHubChecks`(두 판); 실행 중 desktop 데몬 argv 에 `--checks-config` 없음(실측) |
| syspolicyd 부재·크래시 .ips·exec 정지 등 mac 호스트 내부 신호 | — | **없음**(범위 3 — 노드 헬스 신호: 노드가 주기 측정하고 전이 시 1회 알림) | 해당 신호의 이벤트는 아직 존재하지 않음 — 별도 태스크·노드 배포 필요 |
| 노드 자동업데이트(trial·overdue) | update 이벤트 | **미배포** | `b08ab5d`(#76) origin/main 만 — #574 카나리 대기와 같은 배포 단위 |

## 3. CI·PR 대기

| 감시하던 것 | panewire 이벤트 | 배포 판 | 근거 |
|---|---|---|---|
| CI 결과·PR 상태 변화 | — | **없음** | panewire 소스에 GitHub/CI 통합 없음 — GitHub 참조는 release asset 다운로드(노드 self-update, hub_r19_node.go)뿐 |

## 4. 기타

| 감시하던 것 | panewire 이벤트 | 배포 판 | 근거 |
|---|---|---|---|
| 프롬프트 착지 증명 | `panewire prompt --uptake` 관측(confirmed/unproven/composer_residue) | **있음** | prompt·wait 경로 두 판; 제출 증명은 claude·codex 만, 그 외 하네스는 unproven(relay-handoff §3-2) |
| 스폰 요청·결과 | `spawn.requested`·`spawn.result` 허브 broadcast | **있음 — 허브 내부/UI · 노드 수신은 기능 있음/desktop 미설정** | hub_spawn.go 두 판. 노드 측 `/v1/spawn` 수신(handleHubSpawn, hub_spawn_node.go)은 #48(56cdf3e)부터 배포 판에 있음 — desktop 에서 꺼져 있는 이유는 판이 아니라 `~/.config/panewire/spawn.json` 부재다(실측: 파일 없음 → "spawn disabled") |
| 레인 라우트 변경 | `lanes.changed` 허브 broadcast | **있음 — 허브 내부/UI** | lanes_write.go @e401923 |
| 릴레이 진단 | `relay.unrouted`·`rejected`·`truncated`·`unconfirmed` 등 | **있음 — 허브 내부/UI** | relay.go·relay_ack.go @e401923 |
| 버스트·failover | burst request/hold·Wake-on-LAN·전원 | **있음** | burst*.go·failover(#17·#19·#20) 두 판 |
| 잡·세션 인벤토리 조회 | `panewire jobs`·`lanes`·`outbox` 등 풀 CLI | **부분** | `jobs`·`lanes`·`emit`·`wait`·`place` 배포판에 있음(cli.go @05667f4); `fleet-census`(#73)·`session-reap`(#78)·`lanes-audit`(#71)·`sessions`(#69)·`panewire job *`(#74·#75) 미배포 |
| devin 제출 증명 분류 | relay 분류 개선 | **미배포** | `458377b`(#62) origin/main 만 |

## 5. CI·PR 대기 결론 (범위 4)

**결론: 지금처럼 감시가 필요한 쪽(director·해당 builder)이 짧게 기다린다 — 허브가
`gh` 를 폴링하는 방식은 채택하지 않는다.** 이유 세 가지. (1) 비용: CI 대기는
실측 ~7건/96h로 전체 감시의 3% 미만이라, 허브에 gh 인증·폴링 루프·rate limit 관리를
새로 얹는 비용이 절감분을 초과한다. (2) 신뢰성: 허브 폴링은 GitHub 자격증명과 rate
limit를 허브 수명에 묶어 허브 자체가 단일 장애점이 되고, 지금 방식은 `gh` 인증이
이미 있는 세션에서 돌아 추가 자격 관리가 없다. (3) 재부팅 내성: 이 태스크의 문제는
"감시가 세션과 함께 죽는다"인데, CI 대기는 유실돼도 손실이 작다 — 재부팅 후
`gh pr checks` 1회로 상태를 재구성할 수 있어, 유실이 곧 잡 소실로 이어지는 잡 감시와
다르다. "짧게 기다린다"의 수단은 **timeout 을 건 블로킹 명령 1개**다(예:
`timeout 20m gh pr checks <n> --watch` 또는 `gh pr checks` 단발 확인) — 폴링
루프를 만들지 않는다는 점에서 director 스킬 §감시 정책의 임시 대기 규칙과 같은
계열이다. 대기 빈도가 커져 허브 이전을 재논의할 때의 올바른 방향은 허브 폴링이
아니라 PR webhook·poller → `lane.event` 발행이고, 그것은 새 이벤트 추가이므로
범위 2·3 계열 태스크로 보낸다.

## 보증 범위와 한계

- "있음"의 보증은 **이벤트 생성 → 허브 라우팅**까지고, 그것도 전제가 있다:
  owner lane 이 허브 route 에 등록돼 있어야 하고(relay.go @e401923 — 실패 시
  `relay.unrouted`), `lane.event` 계열은 handoffkeep 영속이 성공해야 주입된다.
  `wrk spawn` 에 `--owner`/`--lane` 이 빠지면 `default` 로 들어가 push 는 오지
  않는다. director pane 주입의 마지막 구간은 수신 측 노드(mac, 미측정)에 달렸다
  — pane 주입 자체는 `panewire prompt` 경로로 매일 관측되는 구간이다. mac 노드
  판은 operator 자격이 있는 쪽에서 허브 `GET /v1/nodes` 로 측정할 수 있다
  (desktop 에는 operator 토큰이 없어 미측정으로 둔다).
- push 알림이 와도 **소비는 director 세션 생존에 달렸다**. 재부팅 내성이 있는 것은
  측정·전달이지 판정이 아니다.
- 위 "미배포" 행들은 origin/main 에 존재하나 배포 판에 없다. 이 표를 근거로 해당
  감시(예: pane 소실 수동 감시)를 걷어내면 **사고를 영원히 모르게 된다** — 그
  공백 동안의 임시 수단은 director 스킬 §감시 정책의 "공백 신호" 절을 따른다.
- 커버되지 않는 신호가 필요하면 폴링 루프로 대체하지 말고 이벤트 추가 태스크로
  큐에 넣는다(director 스킬 §감시 정책).
