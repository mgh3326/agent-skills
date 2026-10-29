# spawn-hosts — 원격 호스트·배치·wake (`runtug`)

키·기본값·exit code 의 정본은 runtug `docs/config.md` 와 README 다. 이 파일은 운영 요지만 둔다.
설정은 runtug 가 `~/.config/wrk/hosts.toml` 을 그대로 읽는다(`WRK_HOSTS_CONFIG` 로 대체). 실제
호스트명·경로·자격 파일 경로는 공개 repo 에 적지 않는다. `runtug hosts` 가 해석된 상태를 보인다.

## 배치 — `--host auto`

- runtug 의 로컬 배치 정책이 고른다: 잡의 `--tags`(`unity`·`xcode`·`gpu`·`linux`)가 호스트
  `tags` 의 부분집합이어야 후보다(태그 없는 잡은 어디든). 필요한 쿼타 계정의 fresh presence 가
  있는 호스트가 먼저고(degraded 는 unknown 으로 센다), 깨어 있는 후보는 load5/ncpu 순이며
  `[placement] load_threshold` 이상인 호스트는 다른 후보가 없을 때만 쓴다.
- 선택된 호스트의 spawn-time quota gate 가 최종 승인이다 — 거절되면 다음 후보로 간다. 모든 결정은
  잡의 `job.placement` 이벤트에 남고 `--dry-run` 이 그 기록을 보인다.
- `--host local|<이름>` 은 강제 override 다 — `--override-reason` 필수, 장애 대응·진단에만 쓴다.
  강제 원격은 실패해도 로컬로 폴백하지 않는다.
- `[local] spawn = false` 는 이 호스트의 로컬 스폰을 닫는다(명시 `--host local` 포함 rc 80) — 켜고
  끄는 것은 operator 의 운영 단계다. 안전 boolean 은 bare TOML boolean 만 받는다: 따옴표 값·중복
  키·root 키·BOM 은 rc 70 설정 거부다.

## 원격 호스트 (SSH)

- 대상에 runtug 가 이미 설치돼 있어야 한다. 시작 호스트가 구조화 요청과 원문 브리프를 stdin 으로
  넘기고 실행 호스트가 자기 brief-policy 로 preamble 을 합성한다 — 호스트 간 policy 판을 맞추고,
  켜기 전에 원격 `--dry-run` 출력을 비교한다.
- 원격 cwd 기본값은 대상의 `$HOME/work/<repo>`(없으면 clone)다. `cwd_map` 은 예외일 때만 둔다.
- 스폰 전 `ssh -o BatchMode=yes <host> true` 로 도달을 확인한다.
- 확인·조작은 로컬 사이드바의 herdr-mirror 미러 워크스페이스에서 한다. 🔴 미러 pane 은 원격의
  진짜 pane 이다 — 타이핑하면 원격 세션에 들어가고, 제출 검증(`relay.md` §3)은 동일하게 적용된다.
- 🔴 같은 machine_id 의 panewire 노드를 두 번 띄우면 hub 가 거부하고 "hub unavailable" 로만
  보인다 — 노드 상태는 hub `/v1/nodes` 또는 hub `/ui` 가 정본이다.

## wake — 꺼진 호스트

`wake = "panewire"` 호스트는 정해진 경우에만 깨운다: 깨어 있는 호스트에 없는 capability, 깨어
있는 후보 전부가 `[placement] wake_after_s` 넘게 threshold 초과, 필요한 계정이 그 호스트에만
측정됨, 또는 운영자 요청. 깨운 뒤 노드 접속을 기다려 배치하고, 실패는 rc 81 이다. 명시
`--host <wake 호스트>` 는 unreachable 이면 한 번 깨운다.

## 레인 등록

- worker 는 `-l` 라벨을 레인으로, `--owner` 를 parent 로 등록한다. `--role builder` 는 `--lane` 을
  레인으로, `--parent` 를 parent 로 등록하고 OK 줄 끝에 `lane=<lane>@<machine>` 또는
  `lane=UNREGISTERED` 를 단다(`WRK_LANE_STRICT=1` 이면 rc 82 — pane 은 그대로 유효). worker 는
  등록됐을 때만 `lane=` 을 단다.
- 자격 체인: worker 레인 `lanes_token_env` → `hub_token_env`, builder 레인 `lanes_token_env` →
  `operator_token_env` → `hub_token_env`. runtug 는 자격 값을 출력하지 않는다.
- `runtug lanes-missing` 이 레인이나 parent 가 허브에 없는 열린 잡을 읽기 전용으로 나열한다.

## runtug 에 없는 것

- `via = "hub"` 원격 스폰 — hub 가 runtug 를 부를 수 있을 때까지 거부된다. SSH 호스트만 쓴다.
