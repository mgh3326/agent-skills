# heavy — 무거운 로컬 실행

### 4.x-3 무거운 로컬 실행 (호스트당 `heavy_max`개 — `wrk heavy`)

"무거운 실행" = **1분 넘게 도는 어떤 테스트·빌드**(auto_trader·scopefuel full pytest, hk
`go test -race`·vitest, panewire `go test ./...`, agent-skills `test-wrk.sh` — scopefuel 도
포함이다). 반드시 `wrk heavy -- <cmd>` 로 감싼다 — 호스트당 슬롯 `heavy_max`개
(`fcntl.flock` 카운팅 세마포, mac·Linux 동일; 죽은 홀더의 슬롯은 커널이 회수한다),
**같은 head 에서 세션(역할)당 최대 1회**(워커의 실행과 tester 의 독립 재실행은
별개다), 대기 상한 20분(초과 시 rc=75 로 실패하고 보고서에 "heavy 대기
초과" 기록, 락 없이 임의로 돌리지 않는다), `nice -n 10`, 시작 전 load5/ncpu ≥ 1.0 이면 대기
— 단 그 머신의 `[local] heavy_load_wait = false`(#1241)면 **이 load 대기만** 생략된다
(슬롯·락·nice·cap은 그대로; 슬롯 대기가 cap을 쓰면 rc 75).
보유자·대기열·유효 상한·load_wait 상태는 `wrk heavy status` 로 본다.

호스트별 상한은 **그 머신 자신의** hosts.toml `[local] heavy_max` 가 정한다(없으면 1).
`0`이면 그 호스트에서 heavy 를 전면 거부(rc 78, 호스트명을 적고 desktop 으로 안내한다).
모든 획득·거부·대기초과는 `~/.local/state/wrk/heavy.log`(JSONL, `WRK_HEAVY_LOG`로 경로
변경)에 `host`/`job`/`task`/`cmd`/`wait_s`/`hold_s` 등을 남겨 director 가 기계별 대기
시간을 집계할 수 있다.

**우선순위 class (hk 1533).** `WRK_HEAVY_CLASS=ci` 는 CI 작업 표시다(미설정·빈 값·`lane` 은
기본 lane class이고, 그 밖의 값은 rc 78 로 거부된다). 호스트 락에 살아 있는 ci 대기자가 있는
동안 lane 대기자는 그 ci 대기자가 가져갈 수 있는 슬롯(그 ci 대기자가 대기할 때의 자기
limit 미만 인덱스)을 잡지 않는다 — 슬롯이 비면 먼저 폴링한 쪽이 아니라 ci 대기자가 가져간다.
**선점은 없다**: 실행 중인 보유자는 신호를 받지도, 쫓겨나지도, 단축되지도 않으며, ci 대기자
자신은 양보하지 않는다. ci 대기자의 limit 보다 위 슬롯(데스크톱 러너처럼 ci 가
`WRK_HEAVY_MAX=1` 이면 slot 1)은 lane 에게 열려 있어 놀지 않는다. pid 가 사라진 ci 대기자
파일(stale)은 아무것도 막지 않는다. 기아 방지: 살아 있는 ci 대기자에게 양보한 시간이 누적
`WRK_HEAVY_CI_DEFER_MAX` 초(기본 1800, 0 = 양보 안 함)에 이른 lane 대기자는 그 대기가 끝날
때까지 더는 양보하지 않는다. 시계는 살아 있는 ci 대기자가 있는 동안만 가고 없으면 멈추므로,
늦게 온 ci 대기자 앞에서 가드가 이미 소진돼 있는 일은 없다. 총 대기 cap(기본 1200 s)은 그대로라서
기본 cap 에서는 `WRK_HEAVY_WAIT_CAP` 을 키운 호출에서만 이 가드가 의미를 가진다.
`wrk heavy status` 는 보유자·대기자 줄마다 `class=ci|lane` 과 대기 당시 `limit=` 을 보여 주고,
heavy.log 의 모든 행에는 `class` 필드가 붙는다(`kind` 무관 — run·wait_cap·defer·nested·refused
전부, `log_event` 가 행마다 넣는다). 양보한 lane 대기자는 양보가 끝날 때 `kind=defer` 행을
1개(`class` 포함, `wait_s`, `defer_s` = 실제 양보한 시간, `reason`) 남긴다.

이 순서는 잠금이 아니라 대기자 디렉터리를 읽는 대기열 순서이고, 약속하는 범위는 정확히
이만큼이다: ci 대기자는 기록이 그 디렉터리에 **보이는 순간부터** 대기 중이다(기록은 점 이름으로
쓴 뒤 첫 슬롯 시도 전에 rename 하므로 원자적이다 — lane 의 한 pass 는 온전한 기록 아니면 아무
것도 읽지 않는다). 그 rename 이후에 시작하는 lane pass 는 모두 그 ci 대기자가 가져갈 슬롯을
건너뛰고, 다음에 비는 슬롯은 ci 대기자가 가져간다. **약속하지 않는 것**: wrk 와 python 반쪽이
기동하는 동안(기록이 생기기 전)은 ci 대기자가 대기 중이 아니며, 기록을 이미 읽은 시점에
rename 이 일어난 lane pass(한 pass, 슬롯 시도 전 재확인 없음)는 그 pass 안에서 빈 슬롯을 잡을 수
있다. 둘 다 그 뒤에 선점되지는 않는다. 옛 wrk 의 대기자는 class 를 아예 모르고 예전처럼 경쟁한다.

09-27 운영자 확정값(정본은 hk task 772, **적용은 merge 후 director-1 이 라이브 설정에
한다**): 이 맥(mac-personal) `heavy_max = 0` — syspolicyd SIGSEGV 방지, desktop
`heavy_max = 1`, m1b `heavy_max = 2`. 이 맥에서는 1-3개 targeted test 파일을
`wrk heavy` 없이 직접 돌리는 것만 허용된다.

10-02 운영자 지시(#1241, 적용은 merge 후 desk): m1b·mac-personal은 기존 `[local]` 아래에
`heavy_load_wait = false` 한 줄을 추가하고, M1(mac-work)은 아직 hosts.toml 자체가 없으니
`[local]` + `heavy_load_wait = false` 두 줄짜리 파일을 새로 만든다 — M1은 load5/ncpu ≈ 3으로
load gate가 사실상 열리지 않아 heavy 실행이 20분 cap까지 큐잉됐다. 어느 파일이든 값은 bare
boolean만 허용되고 잘못 쓰면 rc 70으로 거부된다.

macOS 에는 `flock` 명령이 없으므로 **브리프에 셸 `flock` 문구를 직접 쓰지 않는다.** 09-24
수동 규약(`flock /tmp/desktop-heavy-test.lock`)은 `wrk heavy` 로 대체됐다 — 그 파일을 직접
잡는 브리프 문구는 `wrk heavy --` 호출로 읽는다(호환 메모: 파일 경로만 달라지고 직렬화
의미는 같다. 단 전환기에는 옛 파일을 직접 잡는 진행 중 잡과 `wrk heavy` 가 서로를 배제하지
못한다 — 새 브리프부터 갈음한다). 그 규약은 브리프 15건에서 누락됐고 `-o` 누락으로 락이
1시간 새는 사고(v637)가 났다. `wrk heavy` 는 슬롯 fd 를 `pass_fds` 로 명령에 넘긴다(중첩 `wrk heavy`
가 자기 소유 트리 안임을 증명하는 용도) — 그래서 슬롯은 래퍼가 아니라 **그 fd 를 상속한 자손이 하나라도
살아 있는 동안** 잡혀 있다. 남은 자식 프로세스를 정리해야 다음 실행이 대기·시간초과하지 않는다.

