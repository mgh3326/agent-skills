---
name: captain
description: Own one pull-request delivery loop by briefing, spawning, independently verifying, fixing, and joining workers; use only for captain-level coordination.
---

# captain — PR 루프 소유자

캡틴은 PR 한 건의 실행 루프를 소유한다. 캡틴 프로필은 `captain-opus`(Opus, effort high) 또는
`captain-sol`(codex-sol)만 쓴다. `codex-terra`와 `codex-luna`는 워커 전용이다.

## 시작과 브리프

1. `spawn-worker`를 먼저 읽고, 그 스킬의 규모 분류·worktree·브리프·착지·회수 규칙을 그대로
   따른다. 브리프 형식도 재사용한다: 작업/AC, worktree·branch, 불변 제약, 완료 증거, 금지사항,
   파일 인박스 보고 경로, 그리고 모든 지시와 AC의 1:1 대응을 명시한다.
2. `wrk spawn --role captain --lane <captain-lane> --parent <parent-lane>`으로 캡틴 job을
   등록한다. captain role은 `captain-opus` 또는 `captain-sol`만 허용되며 parent 레인은 필수다.
   arbiter의 `job.claim` envelope payload에는 `owner_lane`, `role: "captain"`, `parent_lane`이
   남는다.
3. 워커와 검증자는 캡틴이 스폰한다. 검증자의 급은 반드시 워커 이상이며, 독립 세션으로 AC 반증,
   변경 범위, 실패 경로를 확인한다. `spawn-worker`의 뮤턴트, 실모양 fixture, `gh pr checks`를
   직접 확인하는 규칙을 생략하지 않는다. `gh pr checks`가 조회 불가하거나 녹색을 직접 확인할 수
   없으면 성공으로 추정하지 않는다.
4. BLOCKER만 fix 라운드를 연다. 3라운드를 넘기지 않는다.

## 큐와 상위 레인 보고

다음 작업 선택과 상태 전이는 우선 다음 인터페이스를 사용한다.

```bash
handoffkeep tasks next
handoffkeep tasks transition <job> <state>
```

현재 이 인터페이스가 없으면, `~/work/herdr-inbox/jobs/<job>/`의 파일 인박스를 상태 정본으로
쓴다. 인터페이스가 없는 것을 근거로 상태를 추측하거나 새 큐를 만들지 않는다.

panewire R19a 계약은 두 종류의 이벤트를 같이 소비한다.

- arbiter 산출물은 envelope이다: `job_id`, `seq`, `kind`, `payload`, `created_at`. 캡틴 claim의
  `payload.parent_lane`이 상위 목적지다.
- `wrk done`, `wrk escalate`, `wrk joined` 산출물은 events 디렉터리의 평면 레코드다.
  캡틴의 `job.escalate`와 `job.joined`는 `owner_lane`에 반드시 **캡틴 자신의 레인**을 기록하고,
  정보용 `parent_lane`도 함께 기록한다. `parent_lane`은 라우팅 근거가 아니다. R19a는
  panewire의 `lanes.json`으로 owner 레인의 parent를 해석해 상위 pane으로 주입한다.

`tests/fixtures/panewire-r19a/`의 claim fixture는 실제 `arbiter claim` artifact와 같은 envelope
shape다. 소비자는 flat completion event를 arbiter envelope이라고 가정하면 안 된다.

## 종료와 에스컬레이션

다음 다섯 경우에는 상위 레인으로 올린다.

1. 정책 선택이 필요할 때
2. 레인 계약이 충돌할 때
3. BLOCKER fix가 3라운드를 초과할 때
4. 시크릿·배포·브로커 접촉이 필요한 때
5. JOIN 판정이 불확실할 때
6. 뮤턴트 RED는 assertion 실패일 때만 인정한다. 예외 또는 `IndexError`로 끝난 실행은 유효한
   뮤턴트 검증이 아니다.
7. 캡틴은 머지하지 않는다. 머지는 parent의 권한이며 캡틴은 `wrk joined`로 JOIN 후보와 증거만
   기록한다.
8. **N 라운드 후 검증 범위 고정.** 캡틴은 브리프에 검증 라운드 수 N을 적는다(기본 1). N 라운드가
   끝나면 검증 범위는 그 시점의 수용조건과 이미 제기된 지적으로 고정된다. 이후 라운드에서 **새로
   발견된 카테고리**는 BLOCKER로 올리지 않고 보고서의 **RISKS**에 적는다. 재작업 라운드는 이미
   제기된 BLOCKER를 닫기 위해서만 연다. 이 고정이 3항의 하드 캡 앞단에서 수렴을 만든다 — 심각도
   하한과 라운드 캡이 없으면 적대검증자는 항상 무언가를 더 찾아내고 수렴이 무한히 늦어진다
   (07-31 실측: 4과제 16라운드).

막힘은 `wrk escalate <job> --question "<text>"`으로 기록한 뒤 **대기**한다. 상위 결정을
추측해 계속 진행하지 않는다.

PR, head SHA, 보고서가 확정되고 JOIN 판정이 명확할 때만 다음으로 완료를 기록한다.

```bash
wrk joined <job> --pr <url> --head <sha> --report <path>
```

이는 `job.joined` 평면 이벤트를 parent 레인으로 보낸다. `wrk done`은 워커 완료 관측용이며,
캡틴 루프의 완료 선언은 `wrk joined`다.
