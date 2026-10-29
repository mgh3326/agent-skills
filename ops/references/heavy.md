# heavy — 무거운 로컬 실행 (`runtug heavy`)

"무거운 실행" = **1분 넘게 도는 어떤 테스트·빌드**(앱 full pytest, `go test -race`·vitest,
panewire `go test ./...` 등). 반드시 `runtug heavy -- <cmd>` 로 감싼다:

- 호스트당 슬롯 `heavy_max`개 — 커널 flock 이라 죽은 홀더의 슬롯은 커널이 회수한다.
- **같은 head 에서 세션당 최대 1회.**
- 대기 상한 20분(`WRK_HEAVY_WAIT_CAP`, 기본 1200초) — 초과하면 rc 75 로 실패하고 보고서에 "heavy
  대기 초과" 를 적는다. 락 없이 임의로 돌리지 않는다.
- `nice -n 10`, 슬롯을 잡은 뒤 load5/ncpu < 1.0 까지 대기 — 그 머신의 `[local] heavy_load_wait =
  false` 면 **이 load 대기만** 생략된다(슬롯·락·nice·cap 은 그대로).
- 보유자·유효 상한·load_wait 상태는 `runtug heavy status` 로 본다(status 는 슬롯 파일을 만들지 않는다).

호스트별 상한은 **그 머신 자신의** hosts.toml `[local] heavy_max` 가 정한다(없으면 1, `0` 이면 rc 78
전면 거부). 호스트별 확정값의 정본은 각 머신의 hosts.toml 이다(hk task 772·#1241). `heavy_max = 0`
인 호스트에서는 1–3개 targeted test 파일을 직접 돌리는 것만 허용되고, 그 이상은 heavy 가 허용된
호스트로 보낸다. 획득·거부·대기 초과는 `~/.local/state/wrk/heavy.log`(JSONL, `WRK_HEAVY_LOG`)에
남는다. runtug 는 기존 호스트 락 namespace 를 그대로 쓰므로 옛 launcher 의 실행과도 서로 배제한다.

**runtug 에 없는 것**: 우선순위 class·CI 양보·FIFO/requeue 티켓. `WRK_HEAVY_CLASS`(`ci`|`lane`)와
`--queue-key` 는 감사 라벨일 뿐이다 — CI 를 먼저 보내야 하면 운영자에게 올린다.

macOS 에는 `flock` 명령이 없으므로 **브리프에 셸 `flock` 문구를 직접 쓰지 않는다** — `runtug heavy --`
호출로 쓴다. 슬롯 fd 는 명령에 상속되므로(중첩 `runtug heavy` 는 그 fd 로 자기 트리 안임을 증명한다)
슬롯은 래퍼가 아니라 **그 fd 를 상속한 자손이 하나라도 살아 있는 동안** 잡혀 있다. 남은 자식
프로세스를 정리해야 다음 실행이 대기·시간초과하지 않는다.
