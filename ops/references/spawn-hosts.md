# spawn-hosts — 원격 호스트·배치·wake (`panewire`)

키·기본값·exit code 의 정본은 panewire `docs/config.md` 와 README 다. 이 파일은 운영 요지만 둔다.
설정은 panewire 가 `~/.config/fleet/hosts.toml` 을 그대로 읽는다(`FLEET_HOSTS_CONFIG` 로 대체). 실제
호스트명·경로·자격 파일 경로는 공개 repo 에 적지 않는다. `panewire hosts` 가 해석된 상태를 보인다.

## 배치 — `--host auto`

- panewire 의 로컬 배치 정책이 고른다: 잡의 `--tags`(`unity`·`xcode`·`gpu`·`linux`)가 호스트
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

## 원격 실행 — hub와 node

- CLI는 hub에 요청을 접수한다. hub가 배치·쿼타 승인을 수행하고, 선택된 node가 checkout·launch·brief 착지를 검증한다. launcher subprocess나 SSH launcher 폴백은 없다.
- `ACCEPTED job=… request=…`는 durable hub 예약이다. `SPAWNED` 이벤트와 착지 확인 전에는 pane 생성이나 brief 전달을 주장하지 않는다.
- 응답 유실 시 같은 명령을 다시 실행해 저장된 submission key를 재사용한다. timeout·단절은 `reconciling`/`deadline_exceeded`일 수 있으며, 새 job id로 재스폰하지 않는다. 실행 소유권을 확인하기 전에는 다른 node로 옮기거나 pane을 닫지 않는다.
- workspace를 생략하면 실행 host의 설정을 쓴다. label을 주면 실행 host에서 id로 해석한다. `m1`, `m1b`, `mbp`, `desktop`, `pi`는 hosts 설정의 alias이며 CLI가 해석된 machine id를 출력한다. 실제 host 값은 공개 문서에 쓰지 않는다.
- node 상태는 hub `/v1/nodes` 또는 `/ui`가 정본이다. 같은 machine id의 node를 중복 실행하지 않는다.
- herdr mirror pane은 원격의 실제 pane이다. 제출 확인은 `relay.md` §3과 동일하게 적용한다.

## wake — 꺼진 호스트

`wake = "panewire"` 호스트는 정해진 경우에만 깨운다: 깨어 있는 호스트에 없는 capability, 깨어
있는 후보 전부가 `[placement] wake_after_s` 넘게 threshold 초과, 필요한 계정이 그 호스트에만
측정됨, 또는 운영자 요청. 깨운 뒤 노드 접속을 기다려 배치하고, 실패는 rc 81 이다. 명시
`--host <wake 호스트>` 는 unreachable 이면 한 번 깨운다.

## 레인 등록

- worker 는 `-l` 라벨을 레인으로, `--owner` 를 parent 로 등록한다. `--role builder` 는 `--lane` 을
  레인으로, `--parent` 를 parent 로 등록하고 OK 줄 끝에 `lane=<lane>@<machine>` 또는
  `lane=UNREGISTERED` 를 단다(`PANEWIRE_LANE_STRICT=1` 이면 rc 82 — pane 은 그대로 유효). worker 는
  등록됐을 때만 `lane=` 을 단다.
- 자격 체인: worker 레인 `lanes_token_env` → `hub_token_env`, builder 레인 `lanes_token_env` →
  `operator_token_env` → `hub_token_env`. panewire 는 자격 값을 출력하지 않는다.
- `panewire lanes-missing` 이 레인이나 parent 가 허브에 없는 열린 잡을 읽기 전용으로 나열한다.

## 제거된 명령

`panewire heavy`는 호스트 lock을 되살리지 않는다. 부하 기반 배치 조회에는 `panewire place`를 쓴다.
