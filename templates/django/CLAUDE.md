# CLAUDE.md

{project_name} — Django {version} / {deployment_info}

## 코딩 원칙

### 1. 코딩 전에 생각하라
- 가정을 명시적으로 밝히고, 불확실하면 질문하라.
- 여러 해석이 가능하면 조용히 하나를 고르지 말고 선택지를 제시하라.
- 더 단순한 방법이 있으면 말하라. 필요하면 반론하라.
- 혼란스러우면 멈추고, 무엇이 불명확한지 짚어라.

### 2. 단순함 우선
- 요청받은 것만 구현. 추측성 기능, 불필요한 추상화, 불가능한 시나리오의 에러 처리 금지.
- 200줄로 쓴 코드가 50줄로 가능하면 다시 써라.
- "시니어 엔지니어가 과하다고 할까?" — 그렇다면 단순화하라.

### 3. 외과적 변경
- 요청과 직접 관련된 코드만 수정. 인접 코드 "개선", 포맷팅, 리팩토링 금지.
- 기존 스타일에 맞춰라. 본인 스타일이 달라도.
- 내 변경으로 생긴 미사용 import/변수/함수만 제거. 기존 데드코드는 언급만 하고 삭제하지 마라.

### 4. 목표 기반 실행
- 작업을 검증 가능한 목표로 변환:
  - "검증 추가" → "잘못된 입력 테스트 작성 후 통과시키기"
  - "버그 수정" → "재현 테스트 작성 후 통과시키기"
  - "리팩토링" → "전후 테스트 통과 확인"

## 절대 금지 사항

| 규칙 | 이유 |
|------|------|
| `git push --force`, `git reset --hard` 금지 | 이력 손실 위험 |

## 환경 설정

| 환경 | 모듈 | 비고 |
|------|------|------|
| local | `{project}.settings.local` | |
| dev | `{project}.settings.dev` | |
| prod | `{project}.settings.prod` | |
| test | `{project}.settings.test` | SQLite 메모리 DB |

## 상세 규칙

@.claude/rules/knowledge.md
@.claude/rules/architecture.md
@.claude/rules/testing.md
@.claude/rules/domain.md
@.claude/rules/agents.md
@.claude/rules/hooks.md

## 하네스 변경 이력

| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
