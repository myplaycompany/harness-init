#!/bin/bash
# domain-fill.sh — DOMAIN.md 스켈레톤의 TODO 중 "코드에서 사실로 확인 가능한" 부분만 채운다.
#
# 이전 버전은 앱마다 claude -p 를 호출해 필드 표·계층 트리·관계를 재도출했다.
# 그건 (1) codegraph가 실시간으로 더 정확히 답하는 구조 정보였고, (2) models.py 한 파일만
# 읽고 추론해 앱 간 관계를 hearsay로 합성했으며, (3) 앱 수만큼 LLM 호출이 들었다.
#
# 이제 값·위치는 AST(domain-extract.py)가 정확히 채워 넣는다. 여기서 LLM이 하는 일은
# 딱 하나, **핸들러 본문을 읽고 무슨 부수효과를 내는지 사실을 요약**하는 것이다.
# 이건 추론이 아니라 추출이라 환각 여지가 적고, codegraph가 못 보는 유일한 영역이다.
#
# 의도적으로 채우지 않는 것: 비즈니스 규칙, 내부 슬랭, 변경 시 주의사항.
# 코드에 없는 지식이라 LLM이 쓰면 그럴듯한 창작이 된다. 사람이 채워야 한다.
#
# 사용법: bash domain-fill.sh <TARGET_DIR>

TARGET_DIR="${1:-$PWD}"
TARGET_DIR="${TARGET_DIR%/}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[domain-fill]${NC} $1"; }
success() { echo -e "${GREEN}[domain-fill]${NC} ✓ $1"; }
warn()    { echo -e "${YELLOW}[domain-fill]${NC} $1"; }

if ! command -v claude &>/dev/null; then
  warn "Claude Code 미설치 — 자동 채우기를 건너뜁니다."
  warn "  스켈레톤은 이미 생성되어 있습니다. TODO를 직접 채우거나, 설치 후 재실행하세요:"
  warn "  bash ~/harness-init/scripts/domain-fill.sh $TARGET_DIR"
  exit 0
fi

# ── TODO가 남은 DOMAIN.md 탐색 ─────────────────────────
DOMAIN_FILES=$(find "$TARGET_DIR" -name "DOMAIN.md" \
  ! -path "*/.venv/*" ! -path "*/venv/*" ! -path "*/env/*" \
  ! -path "*/node_modules/*" ! -path "*/.git/*" ! -path "*/__pycache__/*" \
  ! -path "*/.worktrees/*" ! -path "*/worktrees/*" \
  2>/dev/null | sort)

if [ -z "$DOMAIN_FILES" ]; then
  warn "DOMAIN.md가 없습니다 — domain-init.sh 를 먼저 실행하세요"
  exit 0
fi

# 시그널 표가 있고 TODO가 남은 문서만 대상으로 삼는다.
TARGETS=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -q "시그널 부수효과" "$f" 2>/dev/null && grep -q "TODO" "$f" 2>/dev/null; then
    TARGETS="${TARGETS}${f}
"
  fi
done <<< "$DOMAIN_FILES"

if [ -z "$TARGETS" ]; then
  info "채울 시그널 부수효과 TODO가 없습니다. 건너뜁니다."
  exit 0
fi

COUNT=$(echo "$TARGETS" | grep -c . )
info "시그널 부수효과 채우기 시작 (${COUNT}개 문서)"
info "값·위치는 이미 AST로 채워져 있고, 핸들러가 무엇을 바꾸는지만 요약합니다."
echo ""

FAILED=""

while IFS= read -r domain_file; do
  [ -n "$domain_file" ] || continue
  rel_domain="${domain_file#$TARGET_DIR/}"
  app_name=$(basename "$(dirname "$domain_file")")

  info "  → $app_name 분석 중..."

  PROMPT="'${rel_domain}' 의 '시그널 부수효과' 표에서 '무슨 부수효과를 내나' 열이 TODO인 행만 채운다.

절차:
1. '${rel_domain}' 를 읽어 시그널 표의 각 행에 적힌 핸들러 이름과 파일:라인 위치를 확인한다.
2. 각 핸들러 함수의 **본문을 실제로 읽는다** (표에 적힌 위치로 이동). 핸들러가 다른 함수를
   호출하면 그 함수까지 따라 읽는다.
3. 그 핸들러가 실제로 **무엇을 변경하는지**만 한 문장으로 적는다. 다음을 우선한다:
   - 어떤 모델/테이블의 어떤 필드를 쓰는가 (예: 'Match.soldout_at 갱신')
   - 어떤 외부 효과를 내는가 (예: '알림톡 발송', '캐시 무효화', '결제 취소 호출')
   - 어떤 다른 서비스를 호출하는가 (예: 'PromotionService.open() 조건부 호출')

엄격한 규칙:
- 코드에서 확인한 사실만 쓴다. 추측·일반론 금지. 확인 못 했으면 'TODO' 그대로 둔다.
- 한 행당 한 문장, 80자 이내. 세미콜론으로 최대 3개까지 나열 가능.
- '시그널 부수효과' 표의 마지막 열 외에는 **아무것도 수정하지 않는다**.
- '비즈니스 규칙', '변경 시 주의사항', '한 줄 요약', 슬랭·용어 섹션은 코드로 알 수 없는
  지식이므로 TODO를 그대로 남긴다. 절대 창작하지 않는다.
- 상태값 표의 '의미' 열은 라벨만 보고 유추하지 말고 TODO로 둔다. 단, 코드에서 그 값이
  어떤 분기를 타는지 명확히 확인한 경우에만 채운다.

수정한 내용을 '${rel_domain}' 에 직접 쓴다."

  if (cd "$TARGET_DIR" && claude --dangerously-skip-permissions -p "$PROMPT" </dev/null >/dev/null 2>&1); then
    success "  $app_name 완료"
  else
    warn "  $app_name 실패 — 수동으로 채우거나 재실행하세요"
    FAILED="$FAILED $app_name"
  fi
done <<< "$TARGETS"

echo ""
if [ -z "$FAILED" ]; then
  success "시그널 부수효과 채우기 완료"
else
  warn "일부 실패:$FAILED"
  warn "재실행: bash ~/harness-init/scripts/domain-fill.sh $TARGET_DIR"
fi

echo ""
warn "남은 TODO는 의도적으로 비워둔 것입니다 (코드로 알 수 없는 지식):"
echo "    · 비즈니스 규칙 · 내부 슬랭 · 용어 사전 · 변경 시 주의사항"
echo "  팀이 채워야 하는 부분이고, 이후 pre-commit 게이트가 최신 유지를 강제합니다."
