---
name: orchestrator
description: "django 백엔드 전용 에이전트 팀을 조율하여 기능 개발/유지보수 작업을 수행한다. 티켓({TICKET-ID}) 또는 요구사항을 입력받아 analyst → architect → coder ↔ tester → reviewer 파이프라인을 실행한다. 트리거: '백엔드 팀 실행', 'django 백엔드 구현', '{TICKET-ID} 팀으로 처리', '하네스 팀 실행', '기능 개발', '유지보수 작업'. 후속: 결과 수정, 부분 재실행, 리뷰 재시도, 설계 수정 요청 시에도 이 스킬 사용."
---

# Django Backend Team Orchestrator

django 백엔드의 **기능 개발/유지보수 작업을 전담하는 5인 전문 팀**을 조율하는 오케스트레이터 스킬.

## 실행 모드: 에이전트 팀

5명 이상의 에이전트 협업이며 파이프라인 중간에 생성-검증 루프가 있어 `TeamCreate` + `SendMessage` + `TaskCreate` 방식이 필수.

## 에이전트 구성

| 팀원 | 에이전트 타입 | 역할 | 출력 |
|------|-------------|------|------|
| analyst | 커스텀 (Explore 기반) | 티켓 분석, 영향 범위 식별, 모델 선행 분석 | `_workspace/01_ticket_analysis.md` |
| architect | 커스텀 (Plan 기반) | Views/Services/Repositories 설계, 테스트 전략 | `_workspace/02_architecture.md` |
| coder | 커스텀 (general-purpose) | 실제 코드 작성 | 소스 파일 + `_workspace/03_implementation_notes.md` |
| tester | 커스텀 (general-purpose) | pytest 테스트 작성 (Factory + PropertyMock) | 테스트 파일 + `_workspace/04_test_notes.md` |
| reviewer | 커스텀 (Explore 기반) | CLAUDE.md 규칙/레이어 경계 검증 | `_workspace/05_review_report.md` |

## 워크플로우

### Phase 0: 컨텍스트 확인

1. `_workspace/` 디렉토리 존재 여부 확인
2. 실행 모드 결정:
   - **미존재** → 초기 실행. Phase 1로 진행
   - **존재 + 부분 수정 요청** ("테스트 다시 써", "리뷰 재실행" 등) → 해당 에이전트만 재호출, 다른 산출물은 보존
   - **존재 + 새 티켓** → 기존 `_workspace/`를 `_workspace_{YYYYMMDD_HHMMSS}/`로 이동 후 Phase 1
3. 부분 재실행 시 이전 산출물 경로를 에이전트 프롬프트에 포함

### Phase 1: 준비

1. 사용자 입력 분석 — 티켓 번호 추출 또는 자연어 요구사항 정리
2. **티켓 자동 조회** (티켓 번호 입력 시):
   - `which jira` 로 jira CLI 설치 여부 확인
   - CLI 존재 시 `jira issue view {TICKET-ID}` 로 조회
   - CLI 미존재 시 사용자에게 티켓 내용 직접 입력 요청
3. `_workspace/` 생성 + `_workspace/00_input.md`에 입력 원문 저장

### Phase 2: 팀 구성

```
TeamCreate(
  team_name: "django-backend-team",
  members: [
    { name: "analyst", agent_type: "analyst", model: "opus",
      prompt: "_workspace/00_input.md를 읽고 영향 범위·모델 선행 분석을 _workspace/01_ticket_analysis.md에 작성. 영향 범위는 codegraph로 조회한다(explore/impact/affected). 모델을 건드리는 작업이면 해당 앱 DOMAIN.md의 '시그널 부수효과' 표를 반드시 확인해 분석에 포함 — 시그널 배선은 codegraph 호출 그래프에 나타나지 않는다. 완료 시 architect에게 SendMessage." },
    { name: "architect", agent_type: "architect", model: "opus",
      prompt: "_workspace/01_ticket_analysis.md를 기반으로 Views/Services/Repositories 설계·테스트 전략을 _workspace/02_architecture.md에 작성. 완료 시 coder에게 SendMessage." },
    { name: "coder", agent_type: "coder", model: "opus",
      prompt: "_workspace/02_architecture.md를 따라 코드 작성. 모델 변경 필요 시 즉시 중단 후 리더에게 보고. Choices 값·시그널 배선·db_table 을 바꿨으면 해당 앱 DOMAIN.md에 그 '의미'(뜻·전이조건·부수효과)를 적고 변경 이력 갱신 — 값 목록이나 구조는 적지 않는다. 결과를 _workspace/03_implementation_notes.md에 작성. 완료 시 tester에게 SendMessage." },
    { name: "tester", agent_type: "tester", model: "opus",
      prompt: "_workspace/02_architecture.md 테스트 전략과 _workspace/03_implementation_notes.md 변경 파일 목록을 기반으로 pytest 작성(Factory + PropertyMock). 결과를 _workspace/04_test_notes.md에 작성. 완료 시 reviewer에게 SendMessage." },
    { name: "reviewer", agent_type: "reviewer", model: "opus",
      prompt: "구현+테스트 완료 변경을 CLAUDE.md 규칙·레이어 경계 기준으로 리뷰. 체크리스트 E는 'python3 .claude/scripts/domain-gate.py --staged' 를 실제로 실행해 판정하고, 종료 코드 1이면 BLOCKER로 FAIL 처리한다(눈으로 훑어 판단 금지). _workspace/05_review_report.md 작성. FAIL 시 담당 에이전트에게 SendMessage로 재작업 요청." }
  ]
)
```

### Phase 3: 작업 등록

```
TaskCreate(tasks: [
  { title: "티켓 분석 및 영향 범위 식별", assignee: "analyst" },
  { title: "레이어드 설계 문서 작성", assignee: "architect" },
  { title: "Views/Services/Repositories 구현 + 의미 변화 시 DOMAIN.md 갱신", assignee: "coder" },
  { title: "pytest 테스트 작성 및 실행", assignee: "tester" },
  { title: "레이어 규칙 및 CLAUDE.md 준수 리뷰", assignee: "reviewer" }
])
```

### Phase 4: 파이프라인 실행 + 생성-검증 루프

**파이프라인 (순차)**:
1. analyst → SendMessage(to: architect)
2. architect → SendMessage(to: coder)
3. coder ↔ tester (양방향 생성-검증 루프, 최대 3회)
   - **루프 완료 직후**: coder가 `python3 .claude/scripts/domain-gate.py --staged` 를 돌려 종료 코드 0 확인
4. reviewer → 체크리스트 E를 게이트 실행으로 검증 → PASS 시 리더에게 "PR 제출 가능" 보고

**리뷰 게이트**:
- FAIL 시: 담당 에이전트에게 SendMessage로 재작업 요청. 최대 2회 루프
- 위반 10건 이상: architect로 설계 재검토 에스컬레이션

**모델 변경 에스컬레이션**:
- coder가 마이그레이션 필요 감지 → 즉시 작업 중단, 리더에게 SendMessage
- 대안(annotated field, cached_property, QuerySet 활용) 검토 → 대안 불가 시 경고 명시하고 계속

**팀원 간 통신 규칙**:
- analyst → architect: 영향 범위 및 기존 패턴
- architect → coder: 설계 모호 부분 질의응답
- coder ↔ tester: 구현/테스트 양방향
- 모든 에이전트 → reviewer: 완료 알림
- reviewer → 담당자: FAIL 시 재작업 요청

### Phase 5: 통합 보고

1. 모든 작업 완료 확인 (TaskGet)
2. `_workspace/` 내 5개 산출물 Read
3. 리더가 사용자 보고서 작성
4. TeamDelete

### Phase 6: 하네스 자기 점검 (자동)

| 점검 항목 | 자동 진화 트리거 기준 |
|----------|---------------------|
| 어떤 에이전트가 가장 많이 재작업했나? | 재작업 2회 이상 → Phase 7에서 해당 에이전트 지시 보완 |
| 생성-검증 루프가 3회를 넘었나? | 초과 시 → architect 설계 단계 강화 지시 추가 |
| 동일한 규칙 위반이 2회 이상 반복됐나? | 반복 시 → 해당 규칙을 에이전트 원칙에 명시 |
| 사용자가 직접 개입한 지점이 있나? | 개입 발생 시 → 해당 단계 자동화/명시화 |
| Phase 8 문서화에서 발견한 패턴이 CLAUDE.md에 반영됐나? | 미반영 시 → Phase 7에서 즉시 반영 |

**트리거 기준에 해당하는 항목이 있으면** → Phase 7로 자동 진행
**모든 항목이 기준 미달 (완벽한 실행)** → Phase 8로 바로 진행

### Phase 7: 하네스 자동 진화

Phase 6 자기 점검에서 트리거 기준에 해당하는 항목을 발견하면, 사용자 확인 없이 리더가 직접 하네스 파일을 수정한다.

> **핵심 원칙**: 하네스는 고정물이 아니라 진화하는 시스템이다. 매 실행 후 점검 결과를 자동으로 반영하고 지속 갱신한다.

#### 7-1. 피드백→수정대상 매핑

| 피드백 유형 | 수정 대상 | 예시 |
|------------|----------|------|
| 결과 품질 문제 | 에이전트 스킬/원칙 | "분석이 얕다" → analyst에 깊이 기준 추가 |
| 에이전트 역할 부재 | 에이전트 정의 추가 | "보안 리뷰 필요" → security-reviewer 에이전트 신설 |
| 워크플로우 순서 문제 | 오케스트레이터 스킬 | "검증이 먼저여야" → Phase 순서 재배치 |
| 팀 구성 문제 | 오케스트레이터 + 에이전트 | "이 둘은 합쳐도 됨" → 에이전트 통합 |
| 트리거 키워드 누락 | 스킬 description | "이 표현이 안 먹힌다" → description 확장 |
| 테스트 커버리지 부족 | tester 원칙 | "엣지 케이스 누락" → 테스트 전략 보강 |
| 리뷰가 너무 엄격/느슨 | reviewer 체크리스트 | 체크리스트 항목 추가/제거 |

#### 7-2. 수정 절차

1. 피드백을 일반화 — 특정 사례만 고치지 말고 패턴으로 반영 (과적합 방지)
2. `.claude/agents/*.md` 또는 `.claude/skills/orchestrator/SKILL.md` 수정
3. CLAUDE.md `### 하네스 변경 이력`에 날짜·변경 내용·대상·사유를 기록
4. 수정 전후 비교 가능하도록 기존 구조는 보존하면서 증분 수정

#### 7-3. 자동 진화 트리거

| 신호 | 자동 수행 |
|------|---------|
| 동일 실패 패턴이 2회 이상 반복 | 해당 에이전트 `.md`에 실패 방지 규칙 즉시 추가 |
| 에이전트가 동일 실패 패턴 반복 | 에이전트 정의에 해당 실패 방지 규칙 추가 |
| 사용자가 오케스트레이터를 우회하고 직접 작업 | 트리거 조건 확장 또는 팀 구성 간소화 — 자동 적용 |
| 매 실행마다 동일한 수동 설정 반복 | 해당 설정을 오케스트레이터 Phase 1에 자동화 |

#### 7-4. 운영/유지보수 워크플로우

"하네스 점검", "하네스 감사", "에이전트/스킬 동기화" 요청 시:

1. **현황 감사**: `.claude/agents/`와 오케스트레이터 설정을 대조하여 불일치(drift) 감지
2. **증분 수정**: 에이전트/스킬을 한 번에 하나씩 추가·수정·삭제
3. **CLAUDE.md 동기화**: 변경 이력 업데이트
4. **변경 검증**: 구조 무결성, 트리거 누락, 실행 테스트

### Phase 8: 변경사항 문서화 (Compounding)

`reviews/YYYY-MM-DD-{TICKET-ID}.md` 파일 생성:

```markdown
# {TICKET-ID}: [작업 제목]
- **Date**: YYYY-MM-DD
- **Branch**: feature/{TICKET-ID}

## 해결한 문제
## 적용한 패턴
## 가장 어려웠던 결정
## 발견한 예외/주의사항
## 변경 파일
## 하네스 변경
```

패턴 발견 시 CLAUDE.md 즉시 반영:
- 새로운 아키텍처 예외
- 반복되는 버그 패턴 (2회 이상)
- 기존 규칙의 모호함

### Phase 9: 자동 커밋 및 PR 생성

1. 피처 브랜치 생성: `feature/{TICKET-ID}`
2. 커밋 대상: 구현 코드 + 하네스 파일 (Phase 7 수정 시) + `reviews/` 문서
3. 커밋 메시지: `[{TICKET-ID}] type: 설명`
4. PR 생성: `gh pr create --base dev`

## 사용자 보고서 형식

```markdown
# 실행 결과: {TICKET-ID}

## 요약
- **분석**: (analyst 요점)
- **설계**: (핵심 레이어 구조)
- **구현**: (변경 파일 N개)
- **테스트**: (추가 테스트 M건, 실행 결과)
- **리뷰**: PASS / FAIL (위반 N건)

## 변경 파일 목록
## DOMAIN.md 업데이트
- (변경된 앱 + 업데이트 내용, 없으면 "없음")
## PR
- **브랜치**: feature/{TICKET-ID} → dev
- **PR URL**: (자동 생성된 PR 링크)
- **하네스 변경**: (Phase 7 수정 파일 목록, 없으면 "없음")
```

## 에러 핸들링

- **팀원 응답 없음**: 리더가 상태 확인 후 재개 또는 재시작
- **리뷰 FAIL 루프 3회 초과**: 작업 중단, 사용자에게 직접 보고
- **모델 변경 필요**: 즉시 중단 후 "마이그레이션 필요" 경고 명시
- **새 패키지 필요**: requirements 파일 편집 후 "pip-compile 필요" 명시. 작업 계속
- **컨텍스트 부족**: analyst가 "정보 부족" 플래그 → 리더가 코드 탐색으로 자체 보완. 보완 불가 시에만 사용자에게 최소 1회 질문

## 데이터 흐름

```
[사용자 입력]
    ↓
[리더: orchestrator]
    ├→ TeamCreate + TaskCreate
    ├→ analyst ──→ _workspace/01_ticket_analysis.md
    ├→ architect ──→ _workspace/02_architecture.md
    ├→ coder ←→ tester (생성-검증 루프)
    ├→ reviewer ──→ _workspace/05_review_report.md
    ├→ [Phase 6: 자기 점검]
    ├→ [Phase 7: 하네스 진화]
    ├→ [Phase 8: 문서화 → reviews/]
    └→ [Phase 9: 커밋 + PR → dev]
```

## 트리거 조건

**이 스킬을 사용해야 하는 경우**:
1. 티켓 번호와 함께 "구현해줘", "처리해줘", "작업해줘" 요청
2. Django 앱에 기능을 추가하거나 수정하는 작업
3. 레이어드 아키텍처 준수가 중요한 유지보수 작업
4. 이전 실행 결과를 수정/재실행/보완하는 요청

**이 스킬을 사용하지 않아야 하는 경우**:
- 단순한 typo 수정, 주석 추가 등 1~2줄 변경
- PR 리뷰만 필요한 경우 (`/review` 사용)
