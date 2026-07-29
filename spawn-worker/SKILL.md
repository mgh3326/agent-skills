---
name: spawn-worker
description: herdr로 워커/검증자 세션을 스폰(생성·기동·브리프 주입)할 때 반드시 사용. worktree 준비, 모델×effort 티어맵, 브리프 형식, 적대검증 루프, 완료 보고 검증(ls-remote)까지 스폰 전 과정의 표준. 트리거 - "워커 띄워/스폰해", "검증자 붙여", "작업 시켜", herdr-spawn·herdr agent start 사용 전.
---

# spawn-worker — 워커 스폰 표준 절차

**원칙: 워커의 자기보고는 증거가 아니다.** 스폰의 완성은 기동이 아니라 "독립 검증 + 물증
대조(ls-remote)까지의 루프"다.

## 1. 작업장 준비 (스폰 전)

- **worktree**: 항상 최신 `origin/main` 기준. `wt switch --create <이름>` 우선(.env 자동
  연결) — raw `git worktree add`는 **.env 미복사**라 DB/API 작업이 헛돈다(부득이하면
  .env→.env.dev 심링크, prod 조회는 `ENV_FILE=.env.prod` 명시). canonical repo에서 직접
  작업 금지(main 고정).
- **컨텍스트 버전 확인**: 스폰 전 `head AGENTS.md`로 신판("얇은 포인터")인지 확인 — 구
  브랜치 worktree는 stale 규칙이 로드된다. operator 레인 작업이면 cwd=해당 레인 디렉토리
  (`live/`·`mock/` — 레인 AGENTS.md가 최소 안전선).
- **스폰 이름**: 이슈별 유일 이름(예: rob1234-fix). 범용명은 `agent_name_taken`으로 재사용 불가.

## 2. 모델×effort 티어맵

**불변식: 워커 티어 < 검증 티어. 같은 세션 자체검증은 무효(자기 확인).**

| 역할 | 기본 | 대안/에스컬레이션 |
|---|---|---|
| 다단계 구현 워커 | sonnet / codex-med | kiro-sonnet(별도 크레딧 풀) · 강워커=codex-max |
| 단일턴/기계적 작업 | terra · agy-flash | terra는 조기정지 미제 — **체크포인트 계약 필수**(단계 커밋+재개 지점 보고) |
| 적대검증 | codex(sol high) / opus | P0급·안전장치=codex-max(xhigh)·kiro-opus |
| 규명·안전장치 수정·공간열거·재수정 | **무조건 high 상향** | |

**스폰 전 쿼타 확인 → 계열 라우팅** (티어를 정한 다음, 그 티어를 어느 계열에서 뽑을지):

- 스폰 전 `scopefuel` 1회 실행(폴백 `~/bin/ai-quota`) — claude/codex/agy(그룹별)/kiro 4개 풀의
  잔량·pace·reset을 본다.
- **claude weekly는 use-it-or-lose-it** — 사용률 ≤85%면 claude 우선, 초과·WARN이면 **같은
  티어의 codex 계열로 전환** (워커: sonnet↔codex-med · 검증: opus↔sol-high · 강모델:
  codex-max). `herdr-spawn -m auto-worker|auto-verify`가 이 라우팅을 자동화한다.
- **kiro(월 크레딧)·agy는 독립 풀** — claude·codex 압박 시 우회 레인. agy는 그룹 확인 필수
  (3p 소진이어도 gemini 그룹은 별개).
- **동티어 후보가 여러 풀에 있으면 scopefuel 여유율(pace 감안)이 가장 큰 풀 우선.**
  같은 급 모델은 계열 간 호환이다: 강모델 codex-max↔kiro-opus / 검증 opus↔sol-high↔kiro-opus /
  다단계 워커 sonnet↔codex-med↔kiro-sonnet / 경워커 agy-flash(gemini 그룹)↔terra.
  (예: claude weekly WARN + kiro 월크레딧 여유 상황이면 워커·검증 모두 kiro 레인이 1순위가 된다.)
- **계열은 바꿔도 티어는 유지** — 쿼타를 이유로 검증 high→medium 하향 금지. 해당 티어를
  전 계열에서 못 뽑으면 스폰하지 말고 정지·보고.
- "스스로 검증하라"는 지시 금지 → **시도 목록 열거 + 하한 명시**(예: "테스트 X·Y 실행,
  전수 grep 후에만 부재 단정").

## 3. 브리프 작성 (자족적일 것)

포함: ①작업 정의+AC ②worktree 경로·브랜치 ③제약(하드 인바리언트 불변, 게이트 완화 금지,
직접 머지 금지 — **정지점=PR까지**) ④완료 기준+보고 형식(실행한 테스트 원문, push SHA)
⑤금지사항 ⑥보고 채널=**파일 인박스 `~/work/herdr-inbox/`**(orch에 send 금지 — 타이핑 충돌).

**주문·mutation을 유발할 수 있는 브리프 3규칙 (ROB-1150 실사고 기반)**:
- **계약·레인 대조 = 브리프 1단계 게이트**: 대상 계좌를 `mock/CLAUDE.md §1 계좌맵`·
  `operator_contract.yaml`·레인 정책 이슈와 대조하는 판정을 브리프 첫 단계로 명시
  ("충돌이면 실행 말고 회신"). **운영자 승인 릴레이도 그대로 옮기지 말 것** — 승인이
  계좌맵을 읽고 나온 게 아닐 수 있으므로 orch가 먼저 대조한 뒤 브리프화한다.
- **검증 지시는 방법까지 지정**: "동작하는지 확인하라"는 워커가 mutation으로 실증하게
  만든다(1왕복 승인이 2왕복 체결로). read-only 확인 방법을 지정하거나, mutation이
  필요하면 범위를 수치로 못 박는다.
- **강도 보정(운영자 07-29)**: 이 게이트의 목적은 관료화가 아니라 "예약·봉인·read_only로
  **지정된** 계좌를 브리프가 뚫지 않는 것"이다. 봉인 캠페인·live·전용 예약 계좌 =
  fail-closed 엄격 / 자유 mock 재량 범위 = 경량 확인(계좌맵 1분 대조+충돌 시 보고)이면
  족하다. 실수는 막지 못한 것을 보정하며 개선한다 — 절차를 무한히 두껍게 만들지 않는다.
- kiro 워커: "Linear는 읽기만, 이슈·코멘트 변경 금지" 필수(kiro Linear MCP는 write 가능).
- 무인 워커는 승인 우회 플래그 필요(codex `--yolo`, agy `--dangerously-skip-permissions`) —
  `~/bin/herdr-spawn` 매핑에 내장. mock 레인은 `-L mock` + `MOCK_MCP_PROFILE` 필수.
- **스폰 = Linear 기록 의무**: 착수 시 이슈 등록/코멘트(이슈번호 명시). 태스크 상태는 세션
  기억이 아니라 Linear가 정본 — 놓침 방지의 근간.

## 4. 기동·주입·감시

- 기동은 `~/bin/herdr-spawn` 우선(worktree+탭+기동+주입 원샷). 수동이면 `herdr agent start
  <유일이름> --workspace <ws> --cwd <worktree> --no-focus -- <argv>`.
- 브리프 주입과 제출 검증은 **relay-handoff 스킬 절차**를 따른다(제출 검증 생략 금지,
  접수 확인 도구 1회 지시 포함).
- 감시는 `agent_status` **전이 기반**(working→비working 2분 지속 시 확인). kiro/agy는 status
  플랩(작업 중 idle/done 오표시) — 완료 판정은 상태가 아니라 **산출물/화면 마커**(PR URL·
  최종보고·inbox 파일)로. 스폰 후 5분 내 실 툴호출 없으면 stuck 판정→재스폰.

## 5. 검증 루프 (스폰의 후반전)

1. 워커 "완료" 보고 → **`git ls-remote`로 push SHA 실재 대조**(머지·배포·후속 스폰 전 필수).
2. **적대검증자 스폰**: 새 세션(같은 worktree 가능·수정/커밋 금지), 입력=이슈 AC+PR+경로만.
   "틀렸다고 가정하고 반증": 독립 테스트 재실행, false-green 탐지(assert 뒤집기), AC 대조,
   merge-base 기준 스코프 확인. 템플릿=`~/work/herdr-templates/VERIFY-TEMPLATE.txt`.
3. findings는 작업자에게 회송(컨텍스트 보유자가 수정)→재검증 루프. 검증 PASS+CI green까지가
   "완료"다.
4. 부재/미완 단정("테스트 없음"·"미배선")은 전수 탐색 후에만 보고에 인용.

## 실사례 근거 (2026-07)

- 워커 push 자기보고 허위 → ls-remote 대조 규약(#1640). 적대검증이 false-green 2건 적발(ROB-727).
- raw worktree add로 .env 누락 → DB 규명 워커 공회전 직전 적발(07-29).
- terra 조기정지 3회 → 체크포인트 계약으로 손실 0 격리. sonnet "green" 오보고 2회 →
  전체 스위트 랜덤 순서로 적발.
