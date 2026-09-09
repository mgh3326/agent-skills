---
name: linear-archive
description: ROB Linear 이슈를 handoffkeep 문서로 보존하고 native archive로 쿼타 슬롯을 확보하는 archive-only 절차. 쿼타(~250) 근접 시 또는 닫힌 이슈가 쌓였을 때 사용. 트리거 - "linear 아카이브", "이슈 정리해", "쿼타 찼어", "닫힌 이슈 치워", rob-lookup --count 가 220 초과.
---

# linear-archive — ROB Linear 보존·아카이브 표준 절차

> ROB-NNN 은 비공개 이슈 트래커 참조이며, 각 규칙 옆 본문이 근거를 자립 설명한다.

🔴 도메인 오버레이: $AGENT_SKILLS_DOMAIN/linear-archive.md 가 존재하면 이 스킬을 적용하기
전에 반드시 먼저 읽어라. 없으면 아래 추상 규칙만 적용한다.

**원칙 1: handoffkeep 보존 후 native archive만 허용.** 개별 이슈는
`linear/ROB-NNNN`(kind `note`)에 보존하고, 승인된 ID와 manifest를 포함한 배치 기록은
`report/linear/archive/YYYY-MM-DD/<batch>`(kind `report`)에 보존한다.
**원칙 2: archive는 항상 운영자 승인 게이트.** 보존·선별은 무승인(Linear 부작용 0),
archive만 승인 필요다. Obsidian은 운영자 개인 노트 전용이며 이 절차의 1차 저장소나 실행
전제 조건이 아니다.

## 0. 용어 (운영자 정본)

- **native archive(`issueArchive`)** = 🔴 **기본 수단(2026-08-03 운영자 결정).** 쿼타 미터에서
  빠지고(실측: issueCount 250→249), 내용은 Linear 에 그대로 남으며(제목·본문·상태 identifier
  직접 조회 가능 실측), `issueUnarchive` 로 **같은 번호로 복원**된다. purge 없음(단, 장기
  retention 은 미관측 — 아래 보험 참조).
- **handoffkeep 보존** = durable 정본. 개별 이슈 문서와 배치 보고서의 SHA를 대조한 뒤
  archive한다. Obsidian 사본은 운영자 개인 노트일 뿐 정본이 아니다.
- **삭제(`issueDelete`)** = 🔴 **은퇴(retired) 경로. 신규 사용 금지.** 과거에는 노이즈 전용
  최후수단이었으나 soft-delete 후 30일 purge와 비가역성 때문에 archive-only로 봉인됐다.
- ~~⚠️ native archive 로 바꾸라고 권하지 말 것~~ — **2026-08-03 폐기.** 과거 운영자가 단순성을
  위해 delete 를 택했으나, 같은 운영자가 실측(archive 가 쿼타를 비우면서 내용·번호·복원성을
  보존) 후 archive-first 로 전환을 결정했다. delete 의 유일한 장점이었던 "단순성"은 되돌릴 수
  없다는 비용과 교환할 값이 아니었다.

## 1. 언제 하나 — reactive-at-cap (주기 실행 아님)

```bash
rob-lookup --count          # 쿼타 미터 = active(non-archived) 카운트
```
- 문서상 계단식 임계값(180/200/220/240)은 **사실상 죽었다.** 실제 운영은 **250 근처에서
  승인배치 1회로 ~216~227 복귀 후 재충전 반복**.
- **cron 이나 주기 폴링을 걸지 말 것.** 매 배치의 선별 기준이 달라 판단이 필요하다
  (배치 이름이 매번 다른 이유: `closed-leaf-frontier`·`recency-hold`·`aggressive-cleanup`).
- 파이프라인이 이슈를 양산하면 하루 +26 까지 증가한 기록이 있다. 한도 근접이 곧 재발한다.
- **icebox(2026-08-03 신설)**: 닫힌 이슈만이 아니라 **미착수 Backlog** 도 대상이다.
  "일이 유효한가"와 "Linear 에 있어야 하는가"는 별개다 — 수주 내 착수 예정이 아니면
  archive 로 내리고, 착수 시 `issueUnarchive` 로 같은 번호로 되살린다.
  ⚠️ 단, **브리프·계약·메모리가 번호로 참조하는 앵커 이슈**(레인 정책·봉인 계약류)는 제외.

## 2. 무엇을 고르나 — 트랙별 조건

### Track A — `issueArchive` (기본)

내용이 Linear 에 남고 가역이므로 조건이 가볍다. **전부 통과해야 후보**:

1. **닫힌 이슈** (Done/Canceled/Duplicate) 이고 종료 후 **5~7일 경과**(보드 가시성 hold —
   구 2주에서 단축, 2026-08-03), **또는** 미착수 Backlog 로 **수주 내 착수 예정 없음**(icebox).
2. **앵커 아님** — 브리프·계약·메모리가 번호로 상시 참조하는 이슈가 아님.
3. **active PR 이 참조 중 아님.**
4. **active parent 가 있으면 §2-1 역참조 코멘트 선행**(UI 에서 archived 자식이 숨을 수 있음).
5. 🔴 **운영자 승인** — exact ID 목록. 특히 icebox 는 "안 할 일" 판정이 아니라
   "지금 안 볼 일" 판정이지만, 그래도 목록 승인은 생략 불가.

denylist 는 **Track A 에 적용하지 않는다** — 금지의 근거가 "증거 소실"이었는데 archive 는
아무것도 소실하지 않는다. 대신 handoffkeep 개별 이슈 문서와 배치 보고서를 먼저 기록하고
SHA를 대조한다.

### Track B — `issueDelete` — 은퇴(retired), 신규 사용 금지

아래 조건과 사례는 과거 삭제 판단의 근거를 보존하기 위한 **이력**이다. 신규 후보 선별이나
실행 절차로 사용하지 말고, 어떤 조건을 충족해도 `issueDelete`를 호출하지 않는다.
과거 Track B 자료를 재기록할 때도 개별 이슈는 `linear/ROB-NNNN`(kind `note`), 배치와
manifest는 `report/linear/archive/YYYY-MM-DD/<batch>`(kind `report`)를 사용한다.

1. **과거 조건: 닫힌 상태만** (Done / Canceled / Duplicate). ⚠️ `linear-delete.sh` 는 Duplicate 를 closed 로
   안 쳐서 SKIP 한다 → `save_issue` 로 Canceled 로 바꾼 뒤 삭제.
2. **leaf** — active 자식 0
3. **active parent 없음** — 단, **역참조 코멘트를 남기면 예외로 통과**한다(아래 §2-1).
4. **과거 조건: 보존본 선행** (당시에는 Obsidian export를 사용)
5. **안전 민감 키워드 미해당** — denylist는 `$AGENT_SKILLS_DOMAIN/linear-archive-denylist.txt`
   에서 읽는다(형식은 `linear-archive/denylist.txt.example` 참조 — 한 줄에 한 항목, `#` 주석
   허용). 🔴 **파일이 없으면 Track B(delete) 전체를 차단한다** — denylist 부재를
   "제한 없음"으로 해석하지 않는다(안전 기본값 = no-delete).
6. **recency frontier 미만** — 최근 완료분은 보드에 잠깐 유지
   🔴 **stale backlog 를 Canceled 로 닫은 건은 예외다.** 닫는 순간 `updatedAt` 이 지금으로
   갱신돼 60일 방치분도 "최근 것"으로 잡힌다(2026-08-01 실측). 이 경우 **닫기 전의 방치
   기간**으로 판정하라 — 선별을 닫기 **전에** 끝내고 ID 목록을 고정한 뒤 닫는 것이 안전하다.

**제외 대상**: 모든 open 상태(Backlog·Todo·In Progress·In Review), 자식 가진 parent/epic/
roadmap/sprint anchor, active PR 참조 중인 것.

⚠️ **Backlog 는 아카이브 대상이 아니다** — 닫힌 게 아니라 손 안 댄 것이다. 줄이려면 먼저 닫아야
한다(별개 작업).

**과거 순서**: child → parent. 부모는 자식 삭제 후 다음 pass 에서 leaf 가 됐다(2-pass가 필요할 수 있었음).

### 2-1. 과거 active parent 예외 — 삭제 이력 보존용

이 절은 retired Track B가 사용되던 당시의 역참조 근거다. 신규 삭제 허가로 해석하지 않는다.

조건 3 이 "부모가 살아 있으면 자식도 못 지운다"로 읽히지만, **그건 Linear 안에서만 볼 때다.**
아카이브 배치 파일은 **본문 전문 + 부모/자식 관계 + 원본 URL** 을 보존한다(2026-08-01 배치
실측: 19건 1,205줄, 각 항목에 `- 자식: ROB-xxx` 와 `### 본문` 전문). 그러므로 자식을 지워도
내용은 읽을 수 있다.

**빠진 것은 방향 하나뿐이다** — 아카이브→원본(URL)은 있는데 **부모→아카이브 역참조가 없다.**
부모를 열었을 때 자식이 어디로 갔는지 Linear 안에서 알 길이 없다.

🔴 **과거에는 active parent를 가진 자식을 지울 때 삭제 전에 부모에 코멘트를 남겼다:**
```
ROB-525·526·527·528 은 2026-08-03 에 Canceled 후 아카이브됨(사유: <한 줄>).
전문: <vault>/auto_trader/linear-archive/2026-08-03-<batch>.md
```
- 코멘트는 **삭제 전에** 남겼다. 삭제 후에는 어떤 ID였는지 재구성이 어려웠기 때문이다.
- 이 코멘트가 없으면 과거 조건 3을 통과하지 못했다. 없는 채로 지우면 부모가 **추적 불가능한
  고아 계획**을 갖게 됐기 때문이다.
- 부모가 여러 자식을 잃으면 **한 코멘트에 모아서** 남겼다(코멘트 폭주 방지).

## 3. 실행 순서 (항상 이 순서)

**Track A (`issueArchive`, 기본)**
```
① 쿼타 스냅샷        rob-lookup --count
② 후보 선별          §2 Track A 조건
③ 역참조 코멘트      active parent 가 있는 자식만 (§2-1)
④ handoffkeep 보존   개별 note + 후보 manifest 배치 report 기록, 소스 SHA 대조
⑤ 🔴 운영자 승인      exact ID 목록 제시 → 명시적 승인 대기
⑥ 승인된 ID 만       GraphQL issueArchive (1건 canary → 나머지)
⑦ 사후 검증          issueCount 감소 + 표본 1건 identifier 재조회(내용 보존 확인)
⑧ 배치 기록 확정     handoffkeep report에 승인 ID·결과·사유·일자·SHA 기록
```
- ④까지 Linear mutation 없이 진행 가능. ⑤ 없이 ⑥ 금지.
- 복원 = `issueUnarchive(id)` — 같은 번호로 돌아온다. 착수 결정이 나면 즉시.

**Track B (`issueDelete`) — retired 이력, 신규 실행 금지:**
```
# 과거 절차 기록일 뿐 실행 명령이 아니다.
① 스냅샷 → ② 6조건 선별 → ③ 보존본 생성 → ④ 운영자 승인
→ ⑤ 삭제 canary/배치 → ⑥ trashed=true + count 재확인
```

## 4. 경로·도구

```
handoffkeep 개별 이슈  linear/ROB-NNNN                              kind note
handoffkeep 배치 기록  report/linear/archive/YYYY-MM-DD/<batch>      kind report
  본문                  승인 ID·사유·일자·개별 문서 SHA·manifest
조회 도구               rob-lookup ROB-NNN | --search <키워드> | --count
운영자 개인 노트        $ROB_VAULT 아래 선택적 사본(1차 저장소 아님)
```

과거 `linear-delete.sh`의 closed+leaf 안전가드와 credential 비노출 방식은 아래 실사례의
해석 근거로만 보존한다. 스크립트와 `issueDelete`는 신규 실행하지 않는다.

## 5. 하지 말 것

- **승인 없이 archive** — exact ID 목록 승인 게이트는 생략 불가
- **`issueDelete`, delete mutation, 삭제 스크립트 신규 실행** — Track B는 retired이며 이 절차는 archive-only다
- **handoffkeep 보존·SHA 대조 없이 archive** — 개별 note와 배치 report가 먼저다
- **In Progress·In Review·앵커 이슈 archive** — 활성 작업은 대상이 아니다.
  Backlog 는 **icebox 조건 충족 + 승인 시에만** Track A 대상(delete 는 여전히 금지)
- **주기 실행 자동화** — reactive-at-cap 이 정책이다
- **unarchive 남발** — 되살리면 쿼타를 다시 먹는다. 착수 확정 시에만
- **vault 데이터를 이 repo 로 옮기기** — agent-skills 는 public repo 다. 이슈 본문에 무엇이
  있을지 모른다. 경로만 참조할 것.

## 실사례 근거

- **2026-08-03 (archive-first 전환 실측)**: `issueArchive(ROB-1152)` → issueCount 250→249,
  기본 issues 쿼리에서 제외, **identifier 직접 조회로 제목·본문 1,488자·상태 전부 보존 확인.**
  같은 날 방치 Backlog 13건 전수 조사(rob1208)에서 CANCEL 1·KEEP 7·NEEDS_OPERATOR 5 —
  "방치 = 무효"가 아니라 "유효하지만 미착수"가 대부분임이 확인돼 icebox(가역 archive)가
  cancel/delete 보다 정확한 수단으로 판정됨.

- **2026-07-04**: 53건 선별 → 52건 삭제, active 181→134. dry-run 이 일부 `parentId` 를 null 로
  놓쳐 오분류 → 스크립트의 live children 재확인이 커버(2-pass 필요했음).
- **2026-07-12**: 하드캡 275 도달 → 90건 export+delete, 275→186.
- **2026-07-16**: `list_issues` limit 250 상한에 걸려 카운트가 250으로 보이는 함정 →
  **GraphQL `{teams{nodes{key issueCount}}}` 가 정본**.
- **2026-07-17**: 43/43 삭제, 240→197 정확 일치. canary=ROB-800.
- **2026-07-29**: ROB-383(06-16 삭제분)이 Linear 에서 **purge 확인** → "delete 도 복구 가능"은
  30일 한정. Obsidian export 가 유일 영구 소스임이 확정됨.
- **2026-08-01 (이 스킬 첫 실전)**: 257(한도 초과) → 닫힌 이슈가 30건뿐이고 그중 18건이 당일
  작업분이라 후보 3건에 그침 → **압박 원인이 닫힌 이슈가 아니라 30일+ 방치 Backlog 26건**임을
  확인. 15건을 Canceled 로 닫고 기존 4건과 함께 19건 export → canary(ROB-331) → 삭제.
  **257 → 238.** 이때 §2-6 의 `updatedAt` 함정이 드러났다(닫자마자 전부 recency 에 걸림).
