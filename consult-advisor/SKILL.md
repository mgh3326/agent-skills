---
name: consult-advisor
description: 판단이 어려운 문제(설계 분기, 검증 판정 불일치, 위험한 결정)를 강모델 자문으로 푸는 절차. 자문처는 세션 이름 또는 티어(판단급)로 지정 — 상존 세션이 없으면 headless 1회성 자문을 실행. 트리거 - "자문 받아줘", "강모델에 물어봐", "fable/opus/sol에 확인해줘", 판단 막힘·검증자 간 판정 불일치.
---

# consult-advisor — 강모델 자문 왕복

**원칙 1: 자문자는 이 대화의 컨텍스트가 없다** — 질문 패킷은 자족적이어야 한다.
**원칙 2: 자문은 참고 의견이다** — 승인이 아니다. "자문이 하라고 했다"는 mutation·머지·
배포의 실행 근거가 될 수 없다. 채택 여부는 질의 세션의 계약과 운영자 승인 범위를 따른다.

## 1. 자문처 결정

- **세션 이름 지정 시**: `herdr agent list`로 상존 확인 → 있으면 **ask-session 스킬 절차**로
  질의(답변 파일 계약 포함). 없으면 아래 티어 경로로 폴백(임의 재스폰 금지).
- **티어 지정(기본)**: 판단급 동급표에서 scopefuel 여유율로 계열 선택(spawn-worker §2 규칙):
  `opus(high~max effort) ↔ codex sol(xhigh/max) ↔ kiro-opus`
- **fable 예외**: fable은 신규 스폰 금지(운영자 전용 풀·orch 규약). **상존 fable 세션이 있을
  때만** ask-session으로 질의. 없으면 위 동급표로.

## 2. 질문 패킷 (자족성 체크리스트)

①배경 2~5줄(자문자가 모르는 전제) ②구체 질문(판정 형식 지정: 선택지/근거/확신도)
③근거 자료 — 파일 **경로**가 아니라 필요 발췌를 패킷에 포함(headless 자문자는 파일 접근이
안 되거나 다른 cwd일 수 있음; 접근 가능하면 경로+발췌 병기) ④"모르면 '모름'과 근거 — 추측
금지" ⑤시크릿·credential 값 제외.

## 3. 실행 — headless 1회성 우선 (pane 스폰 불요)

```bash
P=~/work/herdr-inbox/consult-<주제>-<HHMM>.md   # 패킷을 파일로 먼저
claude -p --model opus "$(cat $P)"                              # claude 계열
codex exec --skip-git-repo-check -c model_reasoning_effort=xhigh "$(cat $P)"   # codex 계열
kiro-cli chat --no-interactive --trust-tools= "$(cat $P)"       # kiro 계열 (Linear write 주의 → trust-tools=)
agy --model gemini-3.1-pro-high --add-dir <repo> -p "$(cat $P)" # agy (--add-dir 필수, 없으면 규칙/파일 미로드)
```

- 자문 난도가 높으면 **2계열 교차 자문**(예: opus + sol)으로 판정 일치 여부까지 확인 —
  불일치면 그 자체가 "운영자 표면화" 신호다.
- 상존 세션 질의(ask-session 경로)는 그 세션의 컨텍스트가 자산일 때만 선택(예: orch의 전황,
  캡틴의 레인 맥락). 순수 판단 문제는 headless가 낫다(컨텍스트 오염·대기열 없음).

## 4. 회수·기록·채택

- 자문 답변은 `~/work/herdr-inbox/consult-<주제>-answer-<HHMM>.md`로 보존(질의 패킷과 쌍).
- 보고: 질문 요지 / 자문처(모델·계열) / 핵심 답변 / 교차 자문 시 일치 여부 / **채택·기각과
  그 이유는 질의 세션이 별도로 판단해 기록**.
- 자문 결과로 승인 범위 밖 행동이 필요해지면 → 실행하지 말고 운영자에게 결정 요청.

## 설계 배경

- 기존 "Fable 자문 프로토콜"(세션→orch inbox→Fable 답변)의 일반화 — 자문처를 이름이 아닌
  **능력(티어)**으로 지정해 세션 생멸과 무관하게 동작한다.
- headless 우선인 이유: pane 스폰은 주입·감시·정리 비용과 함정(제출 검증, status 플랩)이
  붙는다. 1회성 질문-답변은 print 모드가 구조적으로 안전하다.
