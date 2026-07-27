#!/bin/bash
# scripts/domain-init.sh
# 앱별 DOMAIN.md 스켈레톤과 루트 DOMAIN.md 인덱스를 생성한다.
#
# 이전 버전은 모델 클래스명을 grep으로 긁어 계층 트리와 필드 표를 만들었다.
# 그 내용은 전부 코드에서 재도출 가능한 "구조"라, 문서에 박제하는 순간 낡기 시작했다.
# (plab 실측: web/match/models.py 866커밋 대비 DOMAIN.md 19커밋 = 2.2%만 추종)
#
# 이제 구조는 codegraph가 실시간으로 답하고, 이 스크립트는 codegraph가 **못 보는 것**만
# 스켈레톤화한다. 실측으로 확인된 사각지대 세 가지:
#   - Choices/Enum 값 (codegraph 심볼 아님)
#   - Meta.db_table 매핑  (codegraph FTS 미검색)
#   - 시그널 부수효과      (codegraph 호출 그래프에 엣지 없음)
#
# 값은 AST로 정확히 뽑고, "그게 무슨 뜻인가"만 TODO로 남긴다.
#
# 사용법: bash scripts/domain-init.sh [target_dir]

set -e

TARGET_DIR="${1:-$PWD}"
TARGET_DIR="${TARGET_DIR%/}"
TODAY=$(date +%Y-%m-%d)
PROJECT_NAME=$(basename "$TARGET_DIR")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT="$SCRIPT_DIR/domain-extract.py"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[domain-init]${NC} $1"; }
success() { echo -e "${GREEN}[domain-init]${NC} ✓ $1"; }
warn()    { echo -e "${YELLOW}[domain-init]${NC} ⚠ $1"; }

if ! command -v python3 &>/dev/null; then
  warn "python3 없음 — DOMAIN.md 생성을 건너뜁니다"
  exit 0
fi
if [ ! -f "$EXTRACT" ]; then
  warn "domain-extract.py 없음 ($EXTRACT) — 건너뜁니다"
  exit 0
fi

# ── 의미 지식이 있는 디렉토리 탐색 ─────────────────────
# 추출기가 실제로 무언가(모델·choices·시그널)를 찾은 디렉토리만 대상으로 삼는다.
# models.py 존재 여부로 판단하던 방식보다 정확하고, 비 Django 프로젝트도 커버한다.
info "도메인 지식 보유 디렉토리 탐색 중... ($TARGET_DIR)"

APP_LIST=$(python3 "$EXTRACT" "$TARGET_DIR" --format json --quiet 2>/dev/null \
  | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
for app, payload in sorted(data.get("apps", {}).items()):
    # choices 나 signals 가 있어야 문서로 남길 의미가 있다.
    # 모델만 있는 디렉토리는 db_table 매핑만 필요하므로 함께 포함한다.
    if payload["choices"] or payload["signals"] or payload["models"]:
        print(app)
')

if [ -z "$APP_LIST" ]; then
  warn "도메인 지식을 찾지 못했습니다 (모델·Choices·시그널 없음). 건너뜁니다"
  exit 0
fi

APP_COUNT=$(echo "$APP_LIST" | wc -l | tr -d ' ')
info "${APP_COUNT}개 디렉토리 발견"

# ── 앱별 DOMAIN.md 스켈레톤 ────────────────────────────
CREATED=0
while IFS= read -r app; do
  [ -n "$app" ] || continue
  if [ "$app" = "." ]; then
    continue  # 루트는 아래에서 따로 처리
  fi

  domain_file="$TARGET_DIR/$app/DOMAIN.md"
  if [ -f "$domain_file" ]; then
    warn "$app/DOMAIN.md 이미 존재, 건너뜀"
    continue
  fi

  if python3 "$EXTRACT" "$TARGET_DIR" --app "$app" --format skeleton --today "$TODAY" --quiet \
      > "$domain_file" 2>/dev/null; then
    success "$app/DOMAIN.md 생성"
    CREATED=$((CREATED + 1))
  else
    rm -f "$domain_file"
    warn "$app/DOMAIN.md 생성 실패"
  fi
done <<< "$APP_LIST"

# ── 루트 DOMAIN.md ─────────────────────────────────────
ROOT_FILE="$TARGET_DIR/DOMAIN.md"

INDEX_ROWS=""
while IFS= read -r app; do
  [ -n "$app" ] && [ "$app" != "." ] || continue
  [ -f "$TARGET_DIR/$app/DOMAIN.md" ] || continue
  name=$(basename "$app")
  INDEX_ROWS="${INDEX_ROWS}| ${name} | [\`${app}/DOMAIN.md\`](${app}/DOMAIN.md) | TODO: 한 줄 설명 |
"
done <<< "$APP_LIST"

if [ -f "$ROOT_FILE" ]; then
  # 인덱스 섹션이 이미 있으면 다시 붙이지 않는다. 무조건 append 하면 재실행할
  # 때마다 같은 표가 쌓인다.
  if grep -q "도메인 문서 인덱스" "$ROOT_FILE"; then
    warn "루트 DOMAIN.md에 인덱스 섹션 이미 존재, 건너뜀"
  else
    warn "루트 DOMAIN.md 이미 존재 — 인덱스 섹션만 추가합니다"
    {
      echo ""
      echo "---"
      echo ""
      echo "## 도메인 문서 인덱스 (domain-init.sh 생성)"
      echo ""
      echo "| 도메인 | 문서 | 설명 |"
      echo "|-------|------|------|"
      printf "%s" "$INDEX_ROWS"
    } >> "$ROOT_FILE"
    success "루트 DOMAIN.md 인덱스 추가"
  fi
else
  cat > "$ROOT_FILE" <<EOF
# ${PROJECT_NAME} — 도메인 지식

> **이 문서는 의미(semantics) 전용이다.**
>
> 코드 구조 — 심볼이 어디 있는지, 무엇이 무엇을 호출하는지, 무엇을 바꾸면 어디가
> 깨지는지 — 는 여기 적지 않는다. 문서에 박제하면 그 순간부터 낡는다.
> 구조는 codegraph에 물어본다:
>
> \`\`\`
> codegraph explore "<질문>"     # 관련 심볼 + 소스 + 호출 경로
> codegraph impact <심볼>        # 이걸 바꾸면 어디가 영향받나
> codegraph callers <심볼>       # 누가 호출하나
> \`\`\`
>
> 여기에는 **코드를 아무리 읽어도 알 수 없는 것**만 적는다.

## 프로젝트 개요

| 항목 | 내용 |
|------|------|
| 목적 | TODO: 이 시스템이 해결하는 문제 |
| 주요 사용자 | TODO |
| 핵심 도메인 | TODO |

## 용어 사전

> 한국어 도메인 용어 ↔ 코드 식별자 대응. 에이전트가 "정산"이라는 말을 듣고
> \`settlements\`를 찾아갈 수 있게 하는 표다.

| 용어 | 코드 식별자 | 도메인 | 의미 |
|-----|------------|-------|------|
| TODO | \`\` | | |

## 슬랭 / 내부 용어

> 팀 안에서만 통하는 줄임말, 별칭, 관용 표현. 신규 입사자와 에이전트가 가장 많이
> 막히는 지점이고, 코드 어디에도 정의가 없는 유일한 지식이다.

| 슬랭 | 정식 명칭 | 의미 | 관련 코드 |
|-----|----------|------|----------|
| TODO | | | \`\` |

## 도메인 간 비즈니스 규칙

> 여러 앱에 걸쳐 있어 한 파일만 봐서는 안 보이는 규칙.

- TODO

## 외부 연동 시스템

| 시스템 | 용도 | 실패 시 영향 | 비고 |
|--------|------|-------------|------|
| TODO | | | |

---

## 도메인 문서 인덱스

| 도메인 | 문서 | 설명 |
|-------|------|------|
$(printf "%s" "$INDEX_ROWS")

---

## 변경 이력

| 날짜 | 변경 내용 |
|-----|----------|
| ${TODAY} | DOMAIN.md 초기 생성 (domain-init.sh) |
EOF
  success "루트 DOMAIN.md 생성"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} DOMAIN.md 스켈레톤 생성 완료 (신규 ${CREATED}건)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  값·위치는 AST로 채워져 있습니다. 남은 TODO는 '의미'입니다:"
echo "  ├── 상태값이 각각 무슨 뜻이고 언제 전이하는가"
echo "  ├── 시그널 핸들러가 무슨 부수효과를 내는가  ← codegraph 사각지대"
echo "  ├── 용어 사전 · 내부 슬랭"
echo "  └── 변경 시 주의사항 (과거 사고 지점)"
echo ""
echo "  이후 코드에서 값이 바뀌면 pre-commit 게이트가 갱신을 강제합니다."
