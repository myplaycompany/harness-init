# CLAUDE.md — harness-init

harness-init 자체 개발 가이드. `init.sh` 수정, 템플릿 추가, 훅 작성 시 참조한다.

---

## 프로젝트 목적

AI 에이전트(Claude Code)가 신뢰할 수 있는 결과물을 생산하도록, **에이전트 팀·규칙·도메인 지식·자기강화 루프**를 프로젝트에 주입하는 셋업 도구.

---

## 디렉토리 구조

```
harness-init/
├── init.sh                 ← 메인 실행 진입점. 스택 감지 → 분기 → 설치 순서
├── templates/
│   ├── base/               ← 스택 무관 전역 공통 파일 (모든 프로젝트에 적용)
│   ├── django/             ← Django/Python 전용 하네스
│   └── js/                 ← JS/TS 전용 하네스 (django/ 위에 오버라이드)
└── scripts/
    ├── domain-extract.py   ← AST로 Choices·시그널·db_table 추출 (의미 지식 원천)
    ├── domain-gate.py      ← 의미 변화 판정. 훅·pre-commit·CI가 공유하는 단일 판정기
    ├── domain-freshness.py ← DOMAIN.md 신선도 측정
    ├── domain-init.sh      ← DOMAIN.md 의미 스켈레톤 생성 (extract 위임)
    ├── domain-fill.sh      ← 시그널 부수효과만 LLM으로 요약
    ├── codegraph-setup.sh  ← 구조 지식 계층 배선 (선택 의존성)
    ├── lint-baseline.py    ← 기존 레포 레거시 ruff 위반을 규칙 단위 유예 (루프 차단 방지)
    ├── migration.sh        ← 비 Django 스택 마이그레이션
    └── merge-claude-md.sh  ← CLAUDE.md 주입 헬퍼
```

---

## init.sh 구조 (단계 순서)

1. **환경 선택** — Python / JS·TS / 자동 감지
2. **스택 감지** — `manage.py`, `package.json` 등으로 기술 스택 판별
3. **하네스 설치** — `templates/django/` 또는 `templates/js/` 복사 + `.claude/scripts/` 도구 배치
4. **pre-commit 설치** — Python: ruff, JS·TS: prettier + eslint, 공통: domain-gate
   → 이어서 `lint-baseline.py` 로 기존 레포의 레거시 위반 유예 (아래 참조)
5. **스택 마이그레이션** — `migration.sh`로 비 Django 스택 적응
6. **구조 지식 계층** — `codegraph-setup.sh` (인덱싱 + MCP 등록, 선택 의존성)
7. **의미 지식 계층** — `domain-init.sh` + `domain-fill.sh`
8. **전역 자기강화 루프 설치** — `templates/base/` 파일을 `~/.claude/`에 복사 + `settings.json` 병합

> 단계를 추가할 때는 반드시 기존 단계 번호 순서를 유지하고, 완료 메시지를 출력하라.

---

## 템플릿 계층

| 계층 | 경로 | 적용 방식 |
|------|------|----------|
| 전역 공통 | `templates/base/` | `~/.claude/`에 복사 (프로젝트 디렉토리 아님) |
| Python 공통 | `templates/django/` | 프로젝트 루트에 복사 |
| JS 오버라이드 | `templates/js/` | `templates/django/` 위에 덮어쓰기 |

새 스택을 추가할 때는 `templates/{stack}/`을 만들고 `migration.sh`의 `configure_stack()` 함수에 분기를 추가한다.

---

## 전역 자기강화 루프

`init.sh` 마지막 단계에서 설치된다. **절대 건너뛰지 말 것** — 이 루프가 Claude의 세션 간 학습을 가능하게 한다.

### 설치 대상 파일

| 소스 (templates/base/) | 목적지 | 덮어쓰기 |
|----------------------|--------|---------|
| `hooks/session-stop.sh` | `~/.claude/hooks/session-stop.sh` | No (기존 보존) |
| `hooks/session-start-context.sh` | `~/.claude/hooks/session-start-context.sh` | No (기존 보존) |
| `debrief-guardrails.md` | `~/.claude/debrief-guardrails.md` | No (기존 보존) |
| `project-debrief-guardrails.md` | `.claude/debrief-guardrails.md` | No (기존 보존) |

### settings.json 병합 규칙

`~/.claude/settings.json`에 Stop/SessionStart 훅을 추가할 때 `python3`으로 JSON 병합:
- 기존 hooks 배열이 있으면 append (중복 체크 필수)
- 파일이 없으면 최소 구조로 신규 생성
- `jq` 의존성 금지 — `python3`만 사용

### 가드레일 파일 수정 원칙

- `templates/base/debrief-guardrails.md` — 보편적 교훈만. 특정 프로젝트 내용 금지
- `templates/base/project-debrief-guardrails.md` — 섹션 구조 유지. `{{PROJECT_NAME}}` placeholder는 `sed`로 치환

---

## 코딩 원칙

### 외과적 변경
- `init.sh` 수정 시 해당 단계만 수정. 다른 단계 포맷·변수명 정리 금지.
- 기존 변수명과 함수명 스타일을 따른다.

### 멱등성 (Idempotency)
- 모든 파일 복사는 `-n` (no-overwrite) 플래그 사용. 재실행 시 기존 설정 파괴 금지.
- 디렉토리 생성은 `mkdir -p` 사용.
- **예외 — `.claude/scripts/*.py`는 덮어쓴다.** 사용자가 편집하는 설정이 아니라 훅·pre-commit·CI가
  함께 호출하는 하네스 소유 코드다. 버전이 어긋나면 게이트가 조용히 오작동한다.
- **append는 반드시 존재 검사와 짝을 이룬다.** 파일 끝에 섹션을 덧붙이는 코드는 재실행 시
  같은 섹션을 쌓는다. 실제로 `merge-claude-md.sh`(신규 생성 시 마커 누락)와
  `domain-init.sh`(루트 인덱스)에서 이 버그가 났다. 신규 생성 경로에도 마커를 넣을 것.
- 검증: 빈 레포에 `init.sh`를 3회 돌린 뒤 헤더·마커·인덱스 섹션이 각각 1개인지 확인.

### 에러 처리
- 필수 도구(git, python3) 없으면 명확한 메시지 출력 후 종료.
- Claude Code CLI 없어도 domain-fill.sh 건너뛰고 계속 진행 (선택 기능).

### 의존성
- `bash`, `git`, `python3` — 필수
- `pre-commit`, `claude` CLI, `codegraph` — 선택 (없으면 해당 단계 skip)
- `jq` — 금지 (python3으로 대체)
- 파이썬 도구는 **stdlib만** 사용한다. 대상 프로젝트의 가상환경에 의존하면 훅이 깨진다.

### 하네스는 자신의 게이트를 통과해야 한다
`.claude/scripts/*.py`는 하네스가 프로젝트에 심는 ruff 설정(E/F/I, line-length 88)을
그대로 적용받는다. 심어놓은 린트에 자기 코드가 걸리면 사용자가 첫 커밋부터 막힌다.
**ruff는 한글을 전각(width 2)으로 계산**하므로 파이썬 `len()`으로 센 길이와 다르다.
수정 후 반드시 실제 ruff로 확인할 것:

```bash
ruff format scripts/*.py && ruff check scripts/*.py --select E,F,I
```

---

## 지식 계층 설계 원칙

이 하네스의 핵심 판단은 **무엇을 문서화하고 무엇을 하지 않는가**다.

| 계층 | 담당 | 이유 |
|------|------|------|
| 구조 | codegraph (실시간 인덱스) | 코드에서 재도출 가능 → 문서에 박제하면 낡는다 |
| 의미 | DOMAIN.md (사람이 작성) | 코드에 존재하지 않음 → 문서가 유일한 보존처 |

경계는 추측이 아니라 실측으로 정했다 (2026-07-27, Django 2,741파일 레포):
codegraph는 모델 필드 선언·`Meta.db_table`·`@receiver` 배선을 **각각 0건** 반환했다.
그 셋이 DOMAIN.md의 영역이고, `domain-extract.py`가 추출하는 대상과 정확히 일치한다.

새 항목을 DOMAIN.md 템플릿에 추가하려 할 때는 먼저 물어라:
**"codegraph explore로 답할 수 있는가?"** 답할 수 있으면 넣지 않는다.

### 기존 레포 도입 원칙 — 게이트가 루프를 죽이면 안 된다

harness-init 은 **이미 개발이 진행된 남의 레포**에 들어간다. 신규 게이트를 추가할 때는
"이 게이트가 도입 첫날 모든 커밋을 막는가"를 반드시 확인한다.

ruff가 그랬다. 기존 레포에 처음 켜면 레거시 위반이 쏟아져 커밋이 전부 막히고,
그러면 DOMAIN.md 갱신 커밋도 못 하게 되어 지식 루프 자체가 정지한다.
(실측: plab 8,221건 / 1,418파일)

해법은 **유예하되 숨기지 않기**다. `lint-baseline.py` 가 기존 위반을 규칙 코드 단위로
`ignore` 에 모아 한곳에서 보이게 한다. 파일 단위 유예는 항목이 2,338개가 되어 실패한다.

새 게이트를 추가할 때 체크:
- 레거시 코드가 있는 레포에서 도입 첫 커밋이 통과하는가
- 통과 못 하면 유예 경로가 있는가, 그 유예가 **한곳에 모여 보이는가**
- 유예를 되돌리는 방법(래칫)이 한 줄 삭제로 되는가

### 게이트 설계 원칙
- **오탐은 게이트를 죽인다.** 이전 훅은 `models.py` 변경 전체에 발화해서 무시당했다
  (실측: 소스 866커밋 대비 문서 19커밋). 판정은 AST 지문 비교로 하고, 정규식으로 파일
  종류를 보는 방식으로 되돌아가지 말 것.
- **판정기는 하나다.** PostToolUse 훅, pre-commit, CI가 모두 `domain-gate.py`를 호출한다.
  판정 로직을 복제하면 세 곳이 서로 다른 답을 낸다.
- **종료 코드 규약**: 0=통과, 1=위반, 2=내부 오류(판정 자체를 못 함).
  호출부마다 2를 다르게 다루는데, 이건 의도된 것이다.

  | 호출부 | exit 2 처리 | 이유 |
  |--------|------------|------|
  | `domain-guard.sh` (PostToolUse) | 통과 | 도구 문제로 작업 중인 에이전트를 세우지 않는다 |
  | pre-commit `domain-gate` | 차단 | 커밋 경계에서 판정기가 죽어 있으면 드리프트가 조용히 통과한다 |

  뒤쪽이 중요하다. "검사가 0건을 반환하면 안전 신호가 아니라 스캐너가 깨졌다는
  신호일 수 있다." 커밋을 막되 **메시지가 도메인 위반과 구분되게** 한다
  (`domain-gate: <경로> 로딩 실패`). traceback으로 죽으면 종료 코드가 1이 되어
  pre-commit이 위반으로 오해하므로, 모듈 로딩 실패는 반드시 잡아서 2로 내보낸다.

---

## 새 기능 추가 체크리스트

- [ ] `init.sh`에 단계 추가 (번호 순서 유지)
- [ ] 해당 템플릿 파일을 `templates/` 적절한 계층에 배치
- [ ] README.md의 "설치 결과" 트리와 "템플릿 구조" 섹션 업데이트
- [ ] README.md에 기능 설명 섹션 추가
- [ ] 멱등성 확인 (재실행해도 안전한지)

---

## 하네스 변경 이력

| 날짜 | 변경 | 사유 |
|------|------|------|
| 2026-05-14 | `templates/base/` 계층 신설. 전역 자기강화 루프 (Stop/SessionStart 훅 + 가드레일) 추가 | Claude의 세션 간 교훈 누적 및 자동 컨텍스트 주입 |
| 2026-07-27 | 지식 2계층 분리. 구조는 codegraph, DOMAIN.md는 의미 전용으로 축소 | DOMAIN.md에 구조를 박제해 낡음. plab 실측 추종률 2.2% (소스 866커밋 / 문서 19커밋) |
| 2026-07-27 | `domain-extract.py` 신설 — AST로 Choices·시그널·db_table 추출 | LLM 추론 대신 파싱. 환각 제거, 앱당 claude 호출 1회→0회 |
| 2026-07-27 | `domain-update-reminder.sh` → `domain-guard.sh` 교체 | 구버전은 워킹트리 전체를 보고 echo만 해서 반복 발화·무시당함. 파일 단위 AST 지문 비교 + exit 2 |
| 2026-07-27 | pre-commit `domain-gate` 추가, reviewer 체크리스트 E를 WARNING→BLOCKER 승격 | 경고는 강제력이 없었음. 커밋 차단으로 전환 |
| 2026-07-27 | `domain-sync.yml`(머지 후 LLM 재생성) → `domain-drift.yml`(PR 전 무비용 검출) | 머지 후에는 리뷰 기회가 없고, 매번 LLM이 다시 써서 드리프트 유발 |
| 2026-07-27 | `lint-baseline.py` 신설 | 기존 레포에 ruff를 처음 켜면 레거시 위반(plab 8,221건)이 모든 커밋을 막아 지식 루프가 정지 |
| 2026-07-27 | `pyproject.toml` ruff 설정을 `[tool.ruff.lint]` 스키마로 이관 | 최상위 `select` 는 deprecated — 커밋마다 경고 출력 |
| 2026-07-27 | `pyproject.toml` 복사를 `cp` → `sed` 로 변경 | `{project_name}` placeholder가 치환되지 않아 isort `known-first-party` 가 리터럴로 박혀 있었음 |
