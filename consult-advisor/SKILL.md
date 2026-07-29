---
name: consult-advisor
description: 판단이 어려운 문제(설계 분기, 검증 판정 불일치, 위험한 결정)를 강모델 자문으로 푸는 절차. 자문처는 세션 이름 또는 티어(판단급)로 지정 — 상존 세션이 없으면 자문 전용 pane 세션을 스폰. 트리거 - "자문 받아줘", "강모델에 물어봐", "fable/opus/sol에 확인해줘", 판단 막힘·검증자 간 판정 불일치.
---

# consult-advisor — 강모델 자문 왕복

**원칙 1: 자문자는 이 대화의 컨텍스트가 없다** — 질문 패킷은 자족적이어야 한다.
**원칙 2: 자문은 참고 의견이다** — 승인이 아니다. "자문이 하라고 했다"는 mutation·머지·
배포의 실행 근거가 될 수 없다. 채택 여부는 질의 세션의 계약과 운영자 승인 범위를 따른다.
**원칙 3: 자문 맥락은 추적 가능해야 한다** — pane 세션 스폰이 기본(운영자가 사후에 어떤
질문·답이 오갔는지 herdr에서 확인 가능 + 같은 세션에 후속 재질의 가능). headless 1회성은
간단한 단답 확인용 예외.

## 1. 자문처 결정

- **세션 이름 지정 시**: `herdr agent list`로 상존 확인 → 있으면 **ask-session 스킬 절차**로
  질의. 없으면 아래 티어 경로로.
- **티어 지정(기본)**: 판단급 동급표에서 scopefuel 여유율로 계열 선택(spawn-worker §2 규칙):
  `fable ↔ opus(high~max effort) ↔ codex sol(xhigh~ultra) ↔ kiro-opus`
- **fable 스폰 허용(자문 한정, 07-29 운영자 결정)**: 자문 목적의 fable pane 스폰은 가능하다.
  단 스폰 전 scopefuel로 fable 잔량 확인은 동일 적용 — 티어 유지 불변식과 별개로, fable
  풀이 WARN이면 동급표의 다른 계열(opus-max/sol-ultra/kiro-opus)로.

## 2. 질문 패킷 (자족성 체크리스트)

①배경 2~5줄(자문자가 모르는 전제) ②구체 질문(판정 형식 지정: 선택지/근거/확신도)
③근거 자료 — 파일 경로 + 핵심 발췌 병기(자문 세션 cwd에서 접근 가능한지 확인)
④"모르면 '모름'과 근거 — 추측 금지" ⑤시크릿·credential 값 제외.

## 3. 실행 — 자문 pane 스폰 (기본)

```bash
# 이름: consult-<주제> (전역 유일). cwd = 질의 대상 자료가 있는 repo/디렉토리
herdr agent start consult-<주제> --workspace <ws> --cwd <dir> --no-focus -- claude --model opus
# 또는 herdr-spawn 매핑 사용 (codex-max/ultra·kiro-opus·fable)
```

- 주입·제출검증 = **relay-handoff §3**, 답변 회수 = **ask-session §3**(답변 파일 계약+폴링).
- 자문 세션은 답변 후 **바로 정리하지 않는다** — 운영자 맥락 검토·후속 재질의용으로 유지,
  정리는 운영자/정기 청소(zj-clean) 몫.
- 자문 난도가 높으면 **2계열 교차 자문**(예: opus + sol)으로 판정 일치 여부까지 확인 —
  불일치면 그 자체가 "운영자 표면화" 신호다.
- **상존 세션 질의가 나은 경우**: 그 세션의 컨텍스트가 자산일 때(예: orch의 전황, 분석을
  직접 쓴 세션). 이때는 스폰 없이 ask-session으로.
- (예외) 단답 확인·형식 검증처럼 맥락 보존 가치가 없는 질문만 headless 1회성 허용:
  `claude -p --model opus` / `codex exec -c model_reasoning_effort=xhigh` /
  `kiro-cli chat --no-interactive --trust-tools=` / `agy -p --add-dir <repo>`.

## 4. 회수·기록·채택

- 자문 답변은 `~/work/herdr-inbox/consult-<주제>-answer-<HHMM>.md`로 보존(질의 패킷과 쌍).
- 보고: 질문 요지 / 자문처(모델·계열·pane) / 핵심 답변 / 교차 자문 시 일치 여부 / **채택·
  기각과 그 이유는 질의 세션이 별도로 판단해 기록**.
- 자문 결과로 승인 범위 밖 행동이 필요해지면 → 실행하지 말고 운영자에게 결정 요청.

## 설계 배경

- 기존 "Fable 자문 프로토콜"(세션→orch inbox→Fable 답변)의 일반화 — 자문처를 이름이 아닌
  **능력(티어)**으로 지정해 세션 생멸과 무관하게 동작한다.
- pane 스폰이 기본인 이유(07-29 운영자 결정): headless는 싸지만 자문 맥락이 어디에도 안
  남는다 — 운영자가 "무슨 근거로 그 판단이 나왔나"를 사후 추적하려면 pane 세션이 필요하고,
  같은 자문자에게 이어서 물을 수도 있다.
