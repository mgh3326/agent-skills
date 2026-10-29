# watching — 폴링 없이 기다리기

## 감시 정책 — 폴링 루프 금지, 이벤트 구독

잡·워커·호스트 상태를 **세션에 붙은 폴링 루프**(주기적으로 잡 디렉터리·report
파일·pane 상태·리소스를 확인하며 도는 백그라운드/Monitor 프로세스)로 감시하지
않는다. 감시가 레인 세션에 붙어 있으면 세션과 함께 죽는다 — 09-24 재부팅 때
34개가 한꺼번에 소멸했고, 그 전 96시간 동안 256건이 적층됐다(hk:doc
`task/2026-09-24/director-monitors-to-panewire` 실측).

- **잡별 폴링 감시 상한은 0이다.** 잡마다 새 폴링 루프를 만들지 않는다. 완료·
  에스컬레이션·JOIN·레인 통지는 자기 레인으로 push 되는 `job.*`·`lane.event`·
  `idle-wake` 알림을 소비한다 — 어떤 신호가 배포 판에서 실제로 오는지는
  `panewire-events.md` 표가 정본이다(소스에만 있는 이벤트는 "미배포").
- **부족한 이벤트는 폴링으로 대체하지 말고 태스크로 낸다.** 표에서
  "없음/미배포"인 신호가 필요하면 그것은 panewire 에 이벤트를 추가하는 일이다.
  폴링으로 돌이키는 순간 상한 0의 의미가 사라진다.
- **공백 신호는 걷어내지 않는다 — 잡별 루프 대신 단발 확인으로 커버한다.** 표의
  "미배포" 행 중 유실을 되돌릴 수 없는 신호(현재: pane 소실 = `job.lost` 미배포,
  working 중 정체 = stall 미배포)는 감시를 걷어내면 사고를 영원히 모른다. 그
  공백 동안의 수단은 **이벤트 수신 시·턴 시작 시의 단발 조회 1회**다 — 반복하면
  루프다.
  - **수단은 호스트 범위를 맞춰 고른다.** 같은 호스트의 워커는 `herdr agent
    list`(로컬 herdr 소켓 1대분 — 다른 호스트의 워커는 보이지 않는다), 다른
    호스트는 `ssh <host> herdr agent list`. operator 자격이 있는 호스트라면
    `panewire jobs jobs|orphaned --hub-url <허브> --hub-token-env <operator
    env>`·허브 `GET /v1/jobs/orphaned`로 fleet 조회가 된다(둘 다 operator
    인증 필요 — 허브 앞단의 Cloudflare Access 자격도 별도로 필요하다,
    `--hub-cf-env`). ssh 도 operator 자격도 안 되는 호스트의 소실은 감시
    공백으로 남겨 두고 보고한다 — 폴링으로 메우지 않는다.
  - **판정 기준:** 소실 = 내가 띄운 잡의 pane/agent 가 목록에 없고 완료
    이벤트도 없음(목록은 살아 있는 것만 보이므로, 내 잡 목록과의 대조가
    필요하다). 정체 = `working`인데 `herdr pane read` 화면 tail 이 직전
    조회 이후 수 분째 그대로 — `revision`·last event 는 일하는 동안에도 안
    변하므로 비교 대상이 아니다(#66 stall detector 도 pane read 기반). 단발
    1회로는 판별이 안 되므로 직전 조회 결과를 남겨 다음 단발 조회가
    비교한다. 정체로 판정해도 통지만 하고 reap·재스폰은 하지 않는다.
  - 잡별 루프가 아니므로 상한 0을 깨지 않고, 위 동시 상한 안에 센다.
    #80·#66 배포로 push 가 생기면 이 임시 수단은 걷어낸다.
- **임시 대기·관측은 동시 3개 이하.** 근거: 세션-붙은 감시는 수가 잡 수에 비례해
  자라며(실측 96h에 256건), 상한이 잡 수 비례이면 재부팅 시 전량 소멸 사고가
  재현된다. 3개는 한 턴에 전부 나열해 정당화할 수 있는 수다 — 3개를 넘는 대기가
  필요해 보이면 그것은 대기가 아니라 빠진 이벤트다. 단발 조회(지금 상태 1회
  확인)와 bounded timeout 있는 블로킹 대기(`panewire wait` 등) 1개는 이 상한의
  대상이지만 폴링 루프가 아니다 — 반복 호출로 루프를 만들면 위반이다.
- 예외는 없다 — 위 공백 신호 규칙도 잡별 폴링을 허용하지 않는다. CI·PR 대기도
  폴링 루프를 만들지 않는다 — 방침은 `panewire-events.md` §5 결론을
  따른다.

## 스폰 후 대기 — 유휴와 이벤트 기상

워커를 스폰하고 착지를 확인한 뒤 스폰한 세션은 **유휴로 대기하고, 완료
알림으로 깨어난다**. 완료·에스컬레이션·settled idle 전이는 panewire 가
`job.*`·`lane.event`·`idle-wake` 로 owner 레인에 push 한다 — 턴마다 pane·잡
디렉터리·report 파일을 확인하는 폴링 반복은 금지다(#636: 감시 루프는 세션과
함께 죽고, 턴 비용은 확인할 때마다 든다).

- 허용되는 유일한 능동 대기는 **bounded timeout 있는 블로킹 명령 1개**
  (`panewire wait --agent <이름> --status idle --settle 60s --timeout <한계>`
  등 — `--timeout` 은 필수 인자다)다. `runtug spawn … --wait --wait-timeout <한계>` 도
  같은 1개로 센다(rc 0 완료·READY, 83 ESC, 84 lost·revoked, 85 timeout). 그 종료는 완료
  증거가 아니라 깨어남 신호다 — wait 종료 후의 판정은 언제나 산출물이다. `panewire wait --agent`는
  로컬 herdr 소켓만 본다 — 원격 배치 워커에는 쓸 수 없다.
- 기다리는 동안 턴을 소비하지 않는다. 확인이 필요하면 블로킹 명령으로 묶거나,
  이벤트가 올 때까지 둔다.
- 배포 판에서 push 되지 않는 신호(예: job.lost·revoked·정체)가 필요하면 그
  공백을 브리프·보고서에 명시하고, 임시 수단은 위 §감시 정책의
  "공백 신호" 규칙(단발 조회, 잡별 루프 금지)을 따른다. 커버 범위는
  `panewire-events.md` 표가 정본이다.

## 이벤트 모양 (panewire R19a)

panewire R19a 계약은 두 종류의 이벤트를 같이 소비한다.

- arbiter 산출물은 envelope이다: `job_id`, `seq`, `kind`, `payload`, `created_at`. 위임 좌석 claim의
  `payload.parent_lane`이 상위 목적지다.
- `runtug done`·`runtug escalate`는 `arbiter event`로 기록하므로 같은 envelope이다(runtug에는
  `joined`가 없다). 평면 레코드는 옛 launcher 잡의 events 디렉터리에만 있다.
  위임 좌석의 `job.escalate`는 `owner_lane`에 **좌석 자신의 레인**을 기록하고,
  정보용 `parent_lane`도 함께 기록한다. `parent_lane`은 라우팅 근거가 아니다. R19a는
  panewire의 `lanes.json`으로 owner 레인의 parent를 해석해 상위 pane으로 주입한다.

`tests/fixtures/panewire-r19a/`의 claim fixture는 실제 `arbiter claim` artifact와 같은 envelope
shape다. 소비자는 flat completion event를 arbiter envelope이라고 가정하면 안 된다.
