# spawn-hosts-wrk — 원격 호스트·spill-over·hub placement (`wrk` 전용)

> frozen — `wrk` 와 함께 삭제한다(runtug 컷오버 후 Phase C). 새 규칙을 여기에 더하지 않는다.

### 4.x 원격 호스트 워커 (NCP·RPi·데스크탑·M1) — herdr-mirror 채택(2026-09-02)

- **스폰**은 원격 herdr 서버에서 현지 `wrk` 로 한다(패턴 고정):
  ```bash
  ssh <host> 'export PATH=$HOME/.local/bin:$PATH HERDR_SESSION=worker; wrk spawn -c <path> -m <프로필> -p <프롬프트파일> -w w1 -l <라벨> --t <T> --owner <내 세션> --job <id>'
  ```
  호스트별 세션명: ncp=`operator`, rpi/desktop/m1=`worker`. 프롬프트 파일은 먼저 `scp` 로 올린다.
- **확인·조작**은 로컬 사이드바의 미러 워크스페이스(`ncp: sessions`, `rpi: ~`, `m1: ~` …)에서
  한다 — herdr-mirror(nikok6) 가 원격 pane 을 라이브 스트림하고 agent 상태를 실제값으로
  보고한다. `herdr-mirror status` 로 데몬/호스트 상태 확인, 설정 정본
  `~/.config/herdr-mirror/hosts.toml`. M1 은 사람이 쓰는 기기라 `always_control=false`(읽기 전용).
- 🔴 미러 pane 은 **원격의 진짜 pane** 이다 — 거기에 타이핑하면 원격 세션에 들어간다. 제출
  검증(`relay.md` §3)은 동일하게 적용된다.
- 🔴 같은 machine_id 의 panewire 노드를 두 번 띄우면 hub 가 거부하고 "hub unavailable" 로만
  보인다 — 노드 상태는 hub `/v1/nodes`(NCP operator 토큰) 또는 hub `/ui` 가 정본이다.
- 호스트 다운(뚜껑 닫힘·WoL 실패)은 미러 데몬이 재시도 루프로 표시할 뿐이다 — 스폰 전
  `ssh -o BatchMode=yes <host> true` 로 도달 확인.

### 4.x-1 `wrk` spill-over — hub placement 우선, 로컬 압력은 폴백

`wrk spawn`의 기본 `--host auto`는 **정책을 자체 결정하지 않는다.** 먼저
`panewire place --class worker --cwd <key> --hub-url wss://… --hub-token-env <file>
[--hub-cf-env <file>]`를 호출해 JSON의 `decision`·`candidates`·`reason`을 받고, 그 선택을
실행한다. hub가 명시적으로 `local`을 주면 로컬이 과부하여도 그대로 따른다.
hub 호출 자체가 실패했을 때만 아래의 로컬 폴백 측정(load5/ncpu·`working` agent 수·macOS
`CPU_Speed_Limit`)으로 후보를 고른다. 잘못된 hub JSON은 로컬 폴백하지 않고 fail-closed다.

호스트별 경로·세션·workspace는 공개 코드가 아니라 로컬 설정
`~/.config/wrk/hosts.toml`에 둔다(테스트/이식용 경로는 `WRK_HOSTS_CONFIG`). 값은 반드시 각
환경에 맞춘 자리표시자를 바꿔 넣는다.

```toml
[local]
max_load_ratio = 0.5       # hub unavailable 때만 사용
max_active = 4             # hub unavailable 때만 사용
heavy_max = 1              # 이 머신의 wrk heavy 동시 홀더 수: 0=금지, N=슬롯 N개 (기본 1)
heavy_load_wait = true     # wrk heavy의 슬롯 획득 후 load5/ncpu<1.0 대기 — false면 그 대기만 생략 (기본 true)
spawn = false              # 이 호스트의 로컬 spawn 자체를 닫는다 — bare TOML boolean만 허용, 기본 true

[hub]
hub_url = "wss://<hub-host>"
hub_token_env = "<path-to-token-env-file>"
operator_token_env = "<path-to-operator-token-file>"  # 선택 사항 — builder lanes 자격증명 체인의 둘째, worker는 안 읽음 (#1397)
hub_cf_env = "<path-to-cf-env-file>"   # 선택 사항
lanes_token_env = "<path-to-node-token-file>"  # 선택 사항 — lanes 전용 노드 토큰
machine_id = "<hub-machine-id>"        # 선택 사항 — 이 호스트 자신의 허브 머신 id, 빌더 폴백 (#1397)
session_machine_ids = {"<non-fleet-session>" = "<hub-machine-id>"}  # 선택 사항 — 레인 자동 등록
# quota_gate = "local"     # 선택 사항 — hub quota gate 의 명시적 opt-out (lanes-only 호스트용)

[hosts.<remote-name>]
ssh = "<ssh-alias>"
herdr_session = "worker"
workspace = "<remote-workspace>"
cwd_map = {"<local-worktree>"="<remote-worktree>"}
capacity = 3               # hub unavailable 때의 후보 실측 한도
# 선택적 wake-on-demand (#1239): 기본 off 호스트만 둔다. 아래 세 키가 세트다.
wake = "panewire"
wake_hold = 10             # burst hold(분), 기본 10
wake_wait = 300            # 노드 접속 대기 상한(초), 기본 300
```

mac-personal의 실제 desktop 항목(기본 off, 필요할 때만 깨우는 대상)은 이렇게 생겼다:
```toml
[hosts.desktop]
ssh = "desktop"
herdr_session = "worker"
workspace = "w1"
cwd_map = {"<local-worktree>"="<remote-worktree>"}
capacity = 4
wake = "panewire"
wake_hold = 10
wake_wait = 300
```

- 원격 선택 시 브리프를 권한 `0600` 임시 파일로 `scp`하고,
  `ssh <alias> 'HERDR_SESSION=<session> wrk spawn ... --host local'`로 현지 `wrk`에 위임한다.
  그러므로 원격에서도 quota gate·pane 착지 검증이 동일하게 수행된다. 원격 `-w`는 설정의
  `workspace`가 기본값이며 호출자가 명시하면 그 값을 유지한다.
- `cwd_map`은 접두 매핑이다: cwd가 키와 같거나 `<키>.<suffix>`(형제 worktree, suffix는
  `[A-Za-z0-9._-]+`)이면 `<값>`·`<값>.<suffix>`로, `<키>/<하위경로>`이면 `<값>/<하위경로>`로
  매핑한다. 가장 긴 키가 이기고 `<키>foo`처럼 경계가 아닌 접두는 매칭하지 않는다.
- 유도된 경로(suffix·subpath 매핑)는 원격에서 확인한다: 형제 worktree(suffix)가 없으면
  원격 레포 루트에서 `git fetch` + `git worktree add`로 만들고, 없는 subpath는 만들지
  않고 fail-closed다(원격 레포를 먼저 동기화). 이미 있으면 branch·HEAD가 로컬과 같은지
  확인한다. 로컬 브랜치가 origin에 push되지 않았거나 원격이 다른 커밋이면 덮어쓰지 않고
  fail-closed다 — push·정렬·수동 생성 중 무엇을 하면 되는지 메시지가 나온다. 정확히
  일치하는 리포 루트 매핑은 기존처럼 통과한다.
- 선택한 호스트에 cwd 매핑이 없으면 **fail-closed**다. `--host auto`의
  hosts.toml 순서 라운드(hub 응답이 없어 local-fallback으로 돌아간 경우)만
  그런 후보를 probe 전에 건너뛰고(성공 라운드에는 조용히, 전멸 라운드에는
  보류된 진단 한 줄) 라운드를 멈추지도 wake 판정에도 세지 않는다. hub가
  답한 placement 라운드에는 skip이 없다 — placement 결정이 권위이므로 그
  라운드의 cwd-map 미스는 여전히 rc 2로 fail-closed다. 명시적
  `--host NAME`도 cwd-map rc 2를 그대로 유지한다.
- `wake = "panewire"`(#1239)는 기본 off 원격 호스트를 필요할 때만 깨운다. 후보가 probe에서
  ssh-unreachable이었다는 것만으로는 깨우지 않고 라운드를 끝까지 돌린다: **로컬이 job을
  받을 수 없고**(압력 초과이거나 `spawn = false`) **아무 후보도 job을 받지 못했으며**
  **라운드가 stop-set 응답(도달한 원격 wrk의 rc 2·70·74·75)으로 끝나지 않았고**
  **최소 하나의 후보가 remote-full을 응답했을 때**(정량적 용량 증거) 첫 wake 후보에
  `panewire burst request --target <name>
  --hold <wake_hold>m --timeout <min(wake_wait,600)>s --reason … --hub-url …
  --hub-token-env <credential>`를 보낸다(`hub_url`은 다른 hub 경로와 같은
  `wss://`→`https://` 변환을 거친다). 자격 증명은 `[hub] operator_token_env`가 우선이고
  없을 때만 `hub_token_env`로 폴백한다 — `hub_token_env`는 hub quota gate(#1138)의
  opt-in이기도 하므로 `quota_gate = "local"` 호스트는 그 키를 비워 둔 채 이 경로를 쓴다.
  `hub_cf_env`는 선택 사항이다. hold 승인(rc 0)이나 `cooldown_active`(동시에 돌린 다른
  wrk의 wake가 이미 진행 중이라는 뜻 — 두 번째 요청을 쌓지 않고 그 wake를 기다리는 게
  동시성 규약)이면 최대 `wake_wait`초 동안 ssh probe를 반복해 노드 접속을 확인한 뒤
  spawn을 올린다. 거부(target_unavailable·wake_via_unavailable·invalid_request)·CLI
  실패·타임아웃·대기 후에도 unreachable이면 후보별 진단을 출력하고
  `wrk: <host> wake <사유>; not falling back to local` 한 줄로 rc 81
  (`WRK_EXIT_WAKE_FAILED`)이다 — wake를 시도한 뒤에는 `[local] spawn`과 무관하게
  로컬로 폴백하지 않는다. wake 후 배치가 실패하면 그 rc가 그대로 전파된다.
  명시적 `--host <wake host>`는 unreachable이어도 같은 wake+대기+배치를 하고
  실패도 같은 형태다 — hosts.toml의 `wake` 키 자체가 opt-in이다.
- `--host auto` 순회에서 위임된 원격 wrk가 설정 오류로 거부(rc 70 — 예: 원격의 잘못된
  [hub] quota_gate)하면 라운드는 즉시 멈추고 rc 70 fail-closed다(#1154). 다음 후보나
  로컬 폴백으로 넘어가지 않는다 — 스폰이 닫힌 호스트에 job을 두지 않기 위해서다.
  probe·prepare·scp 같은 전송 leg의 실패 rc는 70이 될 수 없게 1로 정규화되므로
  라우터가 보는 70은 항상 원격 wrk 자신의 응답이다. 그 외 원격 실패(전송 오류, 원격
  quota 거부 rc 4 등)는 기존처럼 다음 후보를 시도하고, 모두 실패하면 로컬 폴백한다.
- `spawn = false`(#1155)는 이 호스트의 로컬 spawn 자체를 닫는 운영 스위치다 — 켜고 끄는
  것은 operator의 운영 단계다(wrk는 읽기만 한다). 닫힌 호스트에서 `--host auto`는 로컬
  압력이 낮아도 로컬을 후보로 쓰지 않고, 모든 원격이 실패하면 로컬 폴백 없이 후보별
  진단 뒤 `wrk: local spawns are disabled ...`와 함께 rc 80
  (`WRK_EXIT_LOCAL_SPAWN_DISABLED`)으로 거부한다. `--host local`은 pane·arbiter·hk 클레임
  같은 모든 부수효과 전에 같은 rc 80으로 거부된다. **ssh 위임**은 실행 호스트에서
  `wrk spawn --host local`로 도착하므로, 원격 호스트가 `spawn = false`이면 위임도 같은
  rc 80으로 거절한다 — 스폰 호스트의 auto 순회는 이 응답을 stop set에 넣지 않고 다음
  후보로 넘어간다(70과 달리 라운드를 멈추지 않는다). **`via = "hub"` 위임은 다르다** —
  hub(wrkgate)는 대상에서 `--host` 없이 `wrk spawn`을 실행하므로 닫힌 via=hub 대상은
  auto 라운드를 돈다: 로컬 pane은 절대 생기지 않지만, 그 대상 자신의 원격 후보로는
  job이 갈 수 있다. 값은 bare TOML boolean만 허용한다 — `"false"`처럼 따옴표 붙인
  문자열은 타입 오류로 rc 70 설정 거부다. 키가 없거나 `true`이면 main과 바이트 동일한
  기존 동작이다.
- 이 스위치는 fail-closed다(#1163) — 오타로 "허용"으로 읽히는 안전 스위치는 없는 것보다
  나쁘다. 허용 형태는 정확히 하나다: `[local]` 단독 줄 + `spawn = false`(또는 `true`)
  한 번. 그 외 local 테이블이나 spawn 키를 가리키는 모든 형태 — `[local] # comment`,
  `[ local ]`, `["local"]` 같은 헤더, 두 번째 `[local]` 테이블, 두 번째 spawn 키,
  `spawn`/`spawn: false`/`spawn == false`/`"spawn" = false`처럼 `spawn = value`가 아닌
  줄, bare true/false가 아닌 값 — 은 파일 줄 번호와 사유를 담은 rc 70 설정 오류로
  모든 spawn 배치를 거부한다. 첫 테이블 헤더 이전의 모든 내용도 거부다 — root
  테이블은 비어 있어야 해서 `local.spawn = false`, `"local".spawn = false`,
  `local = { spawn = false }`는 플래그가 아니라 root 키다([hosts.x] 아래의
  `local.spawn`은 hosts.x.local.spawn이라 무시된다). 줄 시작의 UTF-8 BOM도
  거부다. hosts.toml이 존재하는데 일반 파일로 읽을 수 없거나, 상위 디렉터리의
  search bit이 없어 존재 여부를 확인할 수 없을 때도 같다 — 진짜로 없는 파일만
  허용이다. `[local]`이 없거나 spawn 키가 없거나 정확한 한 줄이면 기존과 동일하다.
  `wrk hosts`는 해석된 상태를 `local spawn=allowed|disabled|error (<사유>)`로
  출력한다 (보고 명령이라 오류 상태에서도 rc 0).
- `heavy_load_wait`(#1241)은 같은 strict 스캐너가 읽는 두 번째 [local] boolean이다 —
  같은 규칙이다: `[local]` 단독 줄 아래 `heavy_load_wait = true|false` 한 번만 허용되고,
  따옴표 값·다른 철자·중복·변형된 키 줄은 모두 줄 번호를 단 rc 70 거부다(이 거부는
  surface 전체에 걸려서 heavy 뿐 아니라 spawn 배치도 막는다). 없거나 `true`이면 기존과
  동일(슬롯을 잡은 뒤 load5/ncpu<1.0이 될 때까지 기다린다). `false`이면 **그 load 대기만**
  생략한다 — heavy_max 슬롯 획득·슬롯 락·`nice -n 10`·20분 cap(슬롯 대기에도 적용, 초과 시
  rc 75)은 그대로다. 잘못된 [local]은 슬롯을 잡기 전에 rc 70으로 거부한다.
  `wrk hosts`는 `local heavy_load_wait=true|false|error (<사유>)`를, `wrk heavy status`는
  `load_wait true|false|error (<사유>)`를 출력한다(둘 다 보고 명령이라 오류에서도 rc 0).
  hosts.toml 자체가 없으면(디렉터리도 없으면) 대기 on·heavy_max 1로 기존과 동일하고,
  `[local]`에 이 키만 있는 파일은 생성 전과 비교해 이 스위치 외 라우팅·기본값·rc는
  바꾸지 않는다 — 단 #58부터 있던 선행 차이 하나: 읽을 수 있는 hosts 파일이
  생기면 --host auto 의 로컬 착지 OK 줄에 host=local 주석이 붙는다(파일이 없을 때의
  fast path는 bare 줄을 출력한다). 이 diff가 아니라 어떤 hosts 파일이든 생기면
  나타나는 기존 동작이다.
- `wrk hosts`는 현재 로컬 폴백 압력과 후보의 도달/활성 상태를 표로 보인다. 모든 라우팅은
  `~/.local/state/wrk/spillover.log`에 `source=hub|local-fallback`과 사유를 남긴다.
- `lanes_token_env`(#1037)는 이 호스트 자신의 hub 머신 ID에 묶인 노드 토큰 파일(mode 0600
  `HUB_MACHINE_ID`/`HUB_TOKEN`)이다. 설정하면 `panewire lanes add/ls/rm`만 이 경로를
  `--hub-token-env`로 쓴다 — 이 파일은 operator route에 닿지 않는다. quota gate·placement는
  계속 `hub_token_env`만 읽고, wake(#1239)는 `operator_token_env`를 먼저 보고 없을 때만
  `hub_token_env`로 폴백하며, hub spawn은 `operator_token_env`를 쓴다. wrk는 파일을 스캔해
  `HUB_MACHINE_ID` 키의 값만 추출한다. 그 값이 `^[A-Za-z0-9._-]{1,64}$` 모양의 머신 id가
  아니면(예: 같은 줄에 `HUB_TOKEN`이 붙은 한 줄 파일) 값 없이 한 번 경고하고 건너뛰고,
  유효한데 `session_machine_ids`의 머신과 다르면 역시 한 번 경고하고 건너뛴다(허브가 403 할
  요청); `HUB_TOKEN`은 절대 읽거나 출력하지 않는다. `hub_token_env`
  없이 `hub_url`+`lanes_token_env`만 둔 lanes-only `[hub]`는 quota gate를 켜지 않는다 —
  게이트의 opt-in은 오직 `hub_token_env`다.
- 레인 자격증명 체인(#1397): lanes route(`lanes add/ls/rm`)가 쓰는 credential은
  레인의 role로 갈린다 — **worker 레인은 #965 때와 같은 `lanes_token_env` →
  `hub_token_env` 체인을 그대로 유지**하며 `operator_token_env`를 절대 읽지 않는다
  (operator_token_env만 설정된 호스트의 매핑 worker는 #965 때처럼 등록 없이 한 번
  경고하고 끝난다); **builder 레인만** `lanes_token_env` → `operator_token_env` →
  `hub_token_env` 순을 쓴다. PUT /v1/lanes 는 operator 토큰만 받으므로
  operator_token_env가 builder lanes를 authorizing할 수 있다. `reap --apply`의
  `lanes rm`도 job의 claim role로 같은 구분을 따라간다(대칭). `wrk lanes-missing`은
  모든 role의 레인을 감사하므로 builder 체인(셋 다)으로 한 번 `lanes ls`를 친다.
  예외 — 원격 `--host` builder 등록은 다른 머신의 레인을 쓰므로 `operator_token_env`를 먼저
  쓰고, 없을 때만 공유 체인으로 폴백한다(노드 스코프 lanes 토큰은 자기 호스트의 레인만
  authorizing한다고 가정).
- **빌더 레인 등록(#1397)**: `--role builder` 스폰도 허브 레인을 등록한다 — `--lane`이
  레인명, `--parent`가 부모(`job.joined`/`job.escalate`가 owner 레인의 parent로 라우팅되므로
  빌더 레인이 없으면 이 이벤트가 유실된다). 머신은 `session_machine_ids`에 매핑된 세션이면
  그 값, 아니면 `[hub] machine_id`(이 호스트 자신의 허브 머신 id — 원격 스폰어가
  hosts.toml 키로 부르는 그 id)를 쓴다. `machine_id` 폴백은 빌더 전용이다 — fleet 세션에
  매핑되지 않은 워커는 여전히 경고 한 번 후 미등록 착지다(fleet worker가 global lane이
  되면 안 되므로). 빌더의 OK 줄은 항상 `lane=<lane>@<machine>` 또는 `lane=UNREGISTERED`를
  단다; 기본은 warn-only이고 `WRK_LANE_STRICT=1`이면 pane 기동·OK 출력 후 rc 82로
  답한다(pane은 그대로 유효). `owner_lane`이 기록된 열린 job(worker 포함) 중 그 레인 또는
  parent가 `panewire lanes ls`에 없는 것은 `wrk lanes-missing`이 읽기 전용으로 나열한다.
- **원격 `--host NAME` builder 스폰의 레인(#1397)**: 실행 호스트는 operator credential이
  없으므로 `lanes add`를 스폰을 시킨 호스트가 한다 — 위임된 wrk는 `--lane-defer <host key>`를
  받아 panewire 호출 없이 `hub_lane`/`hub_lane_machine`만 자기 `job.spawned` receipt에 기록하고,
  시작 호스트는 원격이 `OK pane=` 줄을 찍고 pane이 살아 있는 rc(0, 또는 landing 미확인 76)
  로 답할 때 `lanes add`를 직접 친다(machine = 그 호스트의
  hosts.toml 키 — 그 키가 곧 허브 머신 id다). add가 건너뛰어지거나 실패하면 그 줄의
  `lane=`은 `UNREGISTERED`로 다시 쓰인다 — 시작 호스트가 확인하지 않은 `lane=L@M`은
  절대 그대로 통과하지 않는다. 이 경로는 빌더 전용이다 — 원격 worker에게는
  `--lane-defer`도 시작 호스트의 `lanes add`도 없고, 실행 호스트가 자신의
  `session_machine_ids`로 보통의 worker 조회를 한다. receipt는 job과 함께 실행 호스트에
  있으므로 `wrk reap`은 그곳에서 pane 검증을 거쳐 같은 machine+pane 가드로 `lanes rm`을
  치는데, **`lanes rm`은 허브 호출이므로 실행 호스트 자신이 lanes credential을 들고
  있을 때만 지워진다** — credential이 없는 실행 호스트의 reap은 경고를 남기고 허브 행은
  남긴다(step-4 머신 스코프 토큰이 오기 전까지의 알려진 공백; `lanes rm`은 어느
  operator-credentialed 호스트에서든 칠 수 있다).
  알려진 순서 공백 — `--lane-defer` 스폰의 hk task claim+link는 deferred receipt 기록
  **이전**에 일어난다. receipt 쓰기가 실패하면 pane은 닫히지만 task는 실제로 돌지 않은
  job에 묶인 채 남고, 재시도는 hk의 already-bound 거절에 걸릴 수 있다.
- `quota_gate = "local"`(#1138)은 그 local-only 상태의 명시적 opt-out이다 — M1 같은
  lanes-only 호스트가 쓴다. `hub_url`이 있고 `hub_token_env`가 없는 `[hub]`는 매 spawn마다
  게이트가 건너뛰어지고 local scopefuel gate만 적용된다는 경고를 stderr에 정확히 한 번
  출력하는데, `quota_gate = "local"`을 두면 그 경고 없이 같은 경로를 탄다. 다른 값은
  모두 설정 오류로 rc 70 fail-closed이고, `hub_token_env`와 함께 두는 것도 모순된
  설정으로 같은 70이다.
- `--host local`은 운영자 강제 로컬, `--host <remote-name>`은 강제 원격이다. 둘 다 hub 판정을
  우회하므로 장애 대응·진단에만 쓴다. 강제 원격은 실패해도 로컬로 폴백하지 않고 원격의
  exit code를 그대로 전파한다 — 로컬 폴백은 `--host auto`에서만 일어난다.

### 4.x-2 `via = "hub"` — hub가 직접 원격 spawn을 실행할 때

노드가 hub의 `/v1/spawn` 계약을 제공하면, 대상 호스트에 `via = "hub"`를 설정하고
`wrk spawn ... --host machine-a`로 호출한다. 이 경로는 operator Bearer 토큰과 CF 서비스
토큰을 hub에만 보내므로 tailnet·SSH·scp가 필요 없다. SSH 기반 원격 spawn은 `via`가 없거나
`via = "ssh"`일 때의 기존 경로다.

```toml
[hub]
hub_url = "wss://<hub-host>"
hub_token_env = "<node-token-env>"
hub_cf_env = "<cf-access-env>"
operator_token_env = "<operator-env>"

[hosts.machine-a]
via = "hub"
cwd_keys = {"<local-worktree>"="repo-a"}
```

- `hub_url`은 `wss://`/`ws://`에서 HTTPS/HTTP base URL로 변환된다. `operator_token_env`와
  `hub_cf_env`의 파일은 source하지 않고 필요한 키만 읽으며, 값은 출력이나 spill-over 로그에
  남기지 않는다.
- hub 요청에는 `cwd_keys`의 현재 cwd 키와 UTF-8 brief inline, 허용된 spawn 인자만 들어간다.
  응답이 pending이면 최대 1시간 동안 조회하고, 완료 결과의 pane·job으로 기존 원격 spawn과
  같은 `OK pane=... host=machine-a ... job=...` 행을 출력한다.
- `cwd_keys`도 `cwd_map`과 같은 접두 규칙으로 매핑한다 — 형제 worktree cwd는 `<키>.<suffix>`
  키로 유도된다. hub가 유도된 키를 모르면 기존과 같이 fail-closed다.
- `cwd_keys`에 현재 cwd가 없거나 `operator_token_env`가 없으면 **fail-closed**다. 로컬 또는
  SSH로 조용히 되돌리지 않으며, `--host local` 또는 hosts.toml 보완을 안내한다. lost·인증
  실패·hub 오류도 같은 원칙으로 종료한다.

