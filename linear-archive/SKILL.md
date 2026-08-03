---
name: linear-archive
description: ROB Linear 이슈를 Obsidian으로 아카이브하고 Linear에서 삭제해 쿼타 슬롯을 확보하는 절차. 쿼타(~250) 근접 시 또는 닫힌 이슈가 쌓였을 때 사용. 트리거 - "linear 아카이브", "이슈 정리해", "쿼타 찼어", "닫힌 이슈 치워", rob-lookup --count 가 220 초과.
---

# linear-archive — ROB Linear 아카이브·삭제 표준 절차

**원칙 1: export 없이 삭제 금지.** 삭제분은 30일 후 Linear 에서 실제 purge 된다(ROB-383 실측:
07-04 조회 가능 → 07-29 소멸). **Obsidian export 가 유일한 영구 소스**다.
**원칙 2: 삭제는 항상 운영자 승인 게이트.** export·선별은 무승인(부작용 0), 삭제만 승인 필요.

## 0. 용어 (운영자 정본)

- **native archive(`issueArchive`)** = 🔴 **기본 수단(2026-08-03 운영자 결정).** 쿼타 미터에서
  빠지고(실측: issueCount 250→249), 내용은 Linear 에 그대로 남으며(제목·본문·상태 identifier
  직접 조회 가능 실측), `issueUnarchive` 로 **같은 번호로 복원**된다. purge 없음(단, 장기
  retention 은 미관측 — 아래 보험 참조).
- **Obsidian export** = durable 이중화. archive 경로에서는 **보험(권장)**, delete 경로에서는
  **필수**다.
- **삭제(`issueDelete`)** = **노이즈 전용 최후수단.** soft-archive 후 **30일 purge**, 내용검색
  즉시 불가. 진짜 무가치한 것(스팸·중복 생성 실수)에만.
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

denylist(order·broker·mock…)는 **Track A 에 적용하지 않는다** — 금지의 근거가 "증거 소실"
이었는데 archive 는 아무것도 소실하지 않는다. Obsidian export 는 보험으로 권장(특히
retention 장기 관측 전까지 trading-evidence 류).

### Track B — `issueDelete` (노이즈 전용) — 6개 조건 전부 통과해야

1. **닫힌 상태만** (Done / Canceled / Duplicate). ⚠️ `linear-delete.sh` 는 Duplicate 를 closed 로
   안 쳐서 SKIP 한다 → `save_issue` 로 Canceled 로 바꾼 뒤 삭제.
2. **leaf** — active 자식 0
3. **active parent 없음** — 단, **역참조 코멘트를 남기면 예외로 통과**한다(아래 §2-1).
4. **Obsidian 에 이미 preserved** (export 선행)
5. **safety/broker 민감 키워드 미해당** — denylist: `order·broker·KIS·Alpaca·paper·execution·
   ledger·journal·approval·preflight·reconciliation·watch·TradingAgents·Decision Session·mock·
   canary·audit·Prefect`
6. **recency frontier 미만** — 최근 완료분은 보드에 잠깐 유지
   🔴 **stale backlog 를 Canceled 로 닫은 건은 예외다.** 닫는 순간 `updatedAt` 이 지금으로
   갱신돼 60일 방치분도 "최근 것"으로 잡힌다(2026-08-01 실측). 이 경우 **닫기 전의 방치
   기간**으로 판정하라 — 선별을 닫기 **전에** 끝내고 ID 목록을 고정한 뒤 닫는 것이 안전하다.

**제외 대상**: 모든 open 상태(Backlog·Todo·In Progress·In Review), 자식 가진 parent/epic/
roadmap/sprint anchor, active PR 참조 중인 것.

⚠️ **Backlog 는 아카이브 대상이 아니다** — 닫힌 게 아니라 손 안 댄 것이다. 줄이려면 먼저 닫아야
한다(별개 작업).

**순서**: child → parent. 부모는 자식 삭제 후 다음 pass 에서 leaf 가 된다(2-pass 필요할 수 있음).

### 2-1. active parent 예외 — 부모에 역참조를 남기면 자식을 지울 수 있다

조건 3 이 "부모가 살아 있으면 자식도 못 지운다"로 읽히지만, **그건 Linear 안에서만 볼 때다.**
아카이브 배치 파일은 **본문 전문 + 부모/자식 관계 + 원본 URL** 을 보존한다(2026-08-01 배치
실측: 19건 1,205줄, 각 항목에 `- 자식: ROB-xxx` 와 `### 본문` 전문). 그러므로 자식을 지워도
내용은 읽을 수 있다.

**빠진 것은 방향 하나뿐이다** — 아카이브→원본(URL)은 있는데 **부모→아카이브 역참조가 없다.**
부모를 열었을 때 자식이 어디로 갔는지 Linear 안에서 알 길이 없다.

🔴 **그래서 active parent 를 가진 자식을 지울 때는, 삭제 전에 부모에 코멘트를 남긴다:**
```
ROB-525·526·527·528 은 2026-08-03 에 Canceled 후 아카이브됨(사유: <한 줄>).
전문: <vault>/auto_trader/linear-archive/2026-08-03-<batch>.md
```
- 코멘트는 **삭제 전에** 남긴다. 삭제 후에는 어떤 ID 였는지 재구성이 어렵다.
- 이 코멘트가 없으면 조건 3 은 통과하지 못한다 — 없는 채로 지우면 부모가 **추적 불가능한
  고아 계획**을 갖게 된다.
- 부모가 여러 자식을 잃으면 **한 코멘트에 모아서** 남긴다(코멘트 폭주 방지).

## 3. 실행 순서 (항상 이 순서)

**Track A (`issueArchive`, 기본)**
```
① 쿼타 스냅샷        rob-lookup --count
② 후보 선별          §2 Track A 조건
③ 역참조 코멘트      active parent 가 있는 자식만 (§2-1)
④ 🔴 운영자 승인      exact ID 목록 제시 → 명시적 승인 대기
⑤ 승인된 ID 만       GraphQL issueArchive (1건 canary → 나머지)
⑥ 사후 검증          issueCount 감소 + 표본 1건 identifier 재조회(내용 보존 확인)
⑦ 배치 기록          아카이브 배치 md 에 ID·사유·일자 기록 (Obsidian export 는 보험 — 권장)
```
- ②까지 무승인 진행 가능. ④ 없이 ⑤ 금지.
- 복원 = `issueUnarchive(id)` — 같은 번호로 돌아온다. 착수 결정이 나면 즉시.

**Track B (`issueDelete`, 노이즈 전용)** — 구 절차 유지:
```
① 스냅샷 → ② 6조건 선별 → ③ 🔴 Obsidian export(필수) → ④ 🔴 운영자 승인
→ ⑤ linear-delete.sh --confirm (--canary 선행) → ⑥ trashed=true + count 재확인
```

## 4. 경로·도구

```
Obsidian vault  /Users/mgh3326/shared/obsidian/robin-vault/auto_trader/linear-archive/
  배치 파일       YYYY-MM-DD-rob-linear-<kind>-batch-N.md   (사람용 full context)
  manifest        같은 이름의 .manifest.json / .ids.json     (기계 판독용)
  개별 이슈       issues/ROB-NNN-*.md                        (YAML frontmatter)
정책 문서        …/auto_trader/linear-cleanup-policy.md      (canonical v2, 2026-07-04)
삭제 스크립트    ~/bin/linear-delete.sh ROB-a ROB-b …
                 dry-run 기본 · --confirm 실삭제 · --canary 1건 · --file
조회 도구        rob-lookup ROB-NNN | --search <키워드> | --count
```

`linear-delete.sh` 안전가드: closed+leaf 만 삭제하고, 레이트리밋 등 비-JSON 응답은 그 건만
ERROR 처리 후 계속한다. 키는 스크립트가 `~/.config/linear/api-key`(chmod 600)에서 직접 읽으므로
**명령줄에 credential 이 노출되지 않는다**.

## 5. 하지 말 것

- **승인 없이 archive/delete** — ④는 두 트랙 모두 생략 불가
- **export 없이 delete** — 30일 후 영구 소실 (Track B 한정. Track A 는 보험 권장)
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
