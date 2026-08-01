---
name: linear-archive
description: ROB Linear 이슈를 Obsidian으로 아카이브하고 Linear에서 삭제해 쿼타 슬롯을 확보하는 절차. 쿼타(~250) 근접 시 또는 닫힌 이슈가 쌓였을 때 사용. 트리거 - "linear 아카이브", "이슈 정리해", "쿼타 찼어", "닫힌 이슈 치워", rob-lookup --count 가 220 초과.
---

# linear-archive — ROB Linear 아카이브·삭제 표준 절차

**원칙 1: export 없이 삭제 금지.** 삭제분은 30일 후 Linear 에서 실제 purge 된다(ROB-383 실측:
07-04 조회 가능 → 07-29 소멸). **Obsidian export 가 유일한 영구 소스**다.
**원칙 2: 삭제는 항상 운영자 승인 게이트.** export·선별은 무승인(부작용 0), 삭제만 승인 필요.

## 0. 용어 (운영자 정본)

- **아카이브** = Obsidian 으로 옮기기(durable 기록)
- **삭제(`issueDelete`)** = Linear 에서 빼기. hard-destroy 가 아니라 soft-archive(`archivedAt` 세팅)
  이지만 **30일 후 purge** 되고 내용검색은 즉시 불가.
- ⚠️ **native archive 로 바꾸라고 권하지 말 것** — 운영자가 단순성을 위해 delete 를 택했고,
  recall 은 Obsidian grep 이 담당한다.

## 1. 언제 하나 — reactive-at-cap (주기 실행 아님)

```bash
rob-lookup --count          # 쿼타 미터 = active(non-archived) 카운트
```
- 문서상 계단식 임계값(180/200/220/240)은 **사실상 죽었다.** 실제 운영은 **250 근처에서
  승인배치 1회로 ~216~227 복귀 후 재충전 반복**.
- **cron 이나 주기 폴링을 걸지 말 것.** 매 배치의 선별 기준이 달라 판단이 필요하다
  (배치 이름이 매번 다른 이유: `closed-leaf-frontier`·`recency-hold`·`aggressive-cleanup`).
- 파이프라인이 이슈를 양산하면 하루 +26 까지 증가한 기록이 있다. 한도 근접이 곧 재발한다.

## 2. 무엇을 고르나 — 6개 조건 전부 통과해야 삭제 후보

1. **닫힌 상태만** (Done / Canceled / Duplicate). ⚠️ `linear-delete.sh` 는 Duplicate 를 closed 로
   안 쳐서 SKIP 한다 → `save_issue` 로 Canceled 로 바꾼 뒤 삭제.
2. **leaf** — active 자식 0
3. **active parent 없음**
4. **Obsidian 에 이미 preserved** (export 선행)
5. **safety/broker 민감 키워드 미해당** — denylist: `order·broker·KIS·Alpaca·paper·execution·
   ledger·journal·approval·preflight·reconciliation·watch·TradingAgents·Decision Session·mock·
   canary·audit·Prefect`
6. **recency frontier 미만** — 최근 완료분은 보드에 잠깐 유지

**제외 대상**: 모든 open 상태(Backlog·Todo·In Progress·In Review), 자식 가진 parent/epic/
roadmap/sprint anchor, active PR 참조 중인 것.

⚠️ **Backlog 는 아카이브 대상이 아니다** — 닫힌 게 아니라 손 안 댄 것이다. 줄이려면 먼저 닫아야
한다(별개 작업).

**순서**: child → parent. 부모는 자식 삭제 후 다음 pass 에서 leaf 가 된다(2-pass 필요할 수 있음).

## 3. 실행 순서 (항상 이 순서)

```
① 쿼타 스냅샷        rob-lookup --count
② 후보 선별          §2 의 6조건. 5-check preflight 를 삭제 시점에 재확인
③ Obsidian export    배치 md(full context) + manifest json
④ 🔴 운영자 승인      exact ID 목록 제시 → 명시적 승인 대기
⑤ 승인된 ID 만 삭제   ~/bin/linear-delete.sh --confirm (또는 --canary 로 1건 선행)
⑥ 사후 검증          trashed=true + active count 재확인
```

- **③까지는 무승인 진행 가능**(부작용 0). ④ 없이 ⑤로 넘어가지 말 것.
- **canary 권장**: 첫 1건을 `--canary` 로 삭제하고 soft-archive 동작을 확인한 뒤 나머지.

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

- **export 없이 삭제** — 30일 후 영구 소실
- **승인 없이 삭제** — ④는 생략 불가
- **Backlog·open 이슈 삭제** — 대상이 아니다
- **주기 실행 자동화** — reactive-at-cap 이 정책이다
- **vault 데이터를 이 repo 로 옮기기** — agent-skills 는 public repo 다. 이슈 본문에 무엇이
  있을지 모른다. 경로만 참조할 것.

## 실사례 근거

- **2026-07-04**: 53건 선별 → 52건 삭제, active 181→134. dry-run 이 일부 `parentId` 를 null 로
  놓쳐 오분류 → 스크립트의 live children 재확인이 커버(2-pass 필요했음).
- **2026-07-12**: 하드캡 275 도달 → 90건 export+delete, 275→186.
- **2026-07-16**: `list_issues` limit 250 상한에 걸려 카운트가 250으로 보이는 함정 →
  **GraphQL `{teams{nodes{key issueCount}}}` 가 정본**.
- **2026-07-17**: 43/43 삭제, 240→197 정확 일치. canary=ROB-800.
- **2026-07-29**: ROB-383(06-16 삭제분)이 Linear 에서 **purge 확인** → "delete 도 복구 가능"은
  30일 한정. Obsidian export 가 유일 영구 소스임이 확정됨.
