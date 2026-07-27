#!/bin/bash
# codegraph-setup.sh — 구조 지식 계층(codegraph) 배선
#
# codegraph는 **선택 의존성**이다. harness-init은 남의 레포에 주입되는 도구라
# 팀원 전원에게 바이너리 설치를 강요하지 않는다. 없으면 안내만 하고 건너뛰며,
# 에이전트 rules는 codegraph 없이도 Grep/Read 폴백으로 동작한다.
#
# 사용법: bash scripts/codegraph-setup.sh <target_dir>

TARGET_DIR="${1:-$PWD}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[codegraph]${NC} $1"; }
success() { echo -e "${GREEN}[codegraph]${NC} ✓ $1"; }
warn()    { echo -e "${YELLOW}[codegraph]${NC} $1"; }

# 설치 스크립트가 ~/.local/bin 에 심볼릭 링크를 걸지만 로그인 셸 PATH에 없을 수 있다.
export PATH="$HOME/.local/bin:$PATH"

# ── 설치 여부 확인 ─────────────────────────────────────
if ! command -v codegraph &>/dev/null; then
  warn "codegraph 미설치 — 구조 지식 계층을 건너뜁니다."
  warn ""
  warn "  codegraph는 코드 구조(호출 경로·영향 범위·심볼 위치)를 사전 인덱싱해"
  warn "  에이전트가 파일을 훑지 않고 한 번에 조회하게 해주는 선택 도구입니다."
  warn ""
  warn "  설치:  curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh"
  warn "  이후:  bash scripts/codegraph-setup.sh $TARGET_DIR"
  warn ""
  warn "  설치하지 않아도 하네스는 정상 동작합니다 (에이전트가 Grep/Read로 폴백)."
  exit 0
fi

CG_VERSION=$(codegraph --version 2>/dev/null || echo "unknown")
info "codegraph $CG_VERSION 감지"

# ── .gitignore 먼저 처리 ───────────────────────────────
# 인덱스는 100MB 단위로 커진다(plab 실측 103MB). 인덱싱 전에 무시 설정을 해서
# 실수로 스테이징되는 창을 아예 만들지 않는다.
GITIGNORE="$TARGET_DIR/.gitignore"
if ! grep -qs '^\.codegraph/' "$GITIGNORE" 2>/dev/null; then
  {
    echo ""
    echo "# codegraph 인덱스 (로컬 산출물 — 100MB+, 커밋 금지)"
    echo ".codegraph/"
  } >> "$GITIGNORE"
  success ".gitignore에 .codegraph/ 추가"
fi

# ── 인덱스 생성 또는 갱신 ──────────────────────────────
if [ -d "$TARGET_DIR/.codegraph" ]; then
  info "기존 인덱스 감지 — 증분 동기화"
  if (cd "$TARGET_DIR" && codegraph sync . >/dev/null 2>&1); then
    success "인덱스 동기화 완료"
  else
    warn "동기화 실패 — 'codegraph index .' 로 전체 재빌드를 시도하세요"
  fi
else
  info "인덱스 생성 중... (대형 레포는 수십 초 소요)"
  if (cd "$TARGET_DIR" && codegraph init . 2>&1 | tail -3); then
    success "인덱스 생성 완료"
  else
    warn "인덱싱 실패 — 수동 실행: cd $TARGET_DIR && codegraph init ."
    exit 0
  fi
fi

# ── MCP 서버를 프로젝트 스코프로 등록 ──────────────────
# --location local 은 프로젝트의 .mcp.json 에 쓴다. 팀원이 레포를 받으면
# 별도 설정 없이 같은 도구를 쓰게 되므로 전역(global)보다 이쪽이 맞다.
if [ -f "$TARGET_DIR/.mcp.json" ] && grep -q "codegraph" "$TARGET_DIR/.mcp.json" 2>/dev/null; then
  info "MCP 서버 이미 등록됨, 건너뜀"
else
  if (cd "$TARGET_DIR" && codegraph install --yes --target claude --location local >/dev/null 2>&1); then
    success "MCP 서버 등록 완료 (.mcp.json — 팀 공유)"
  else
    warn "MCP 자동 등록 실패 — 수동 실행: cd $TARGET_DIR && codegraph install"
  fi
fi

# ── 텔레메트리 안내 ────────────────────────────────────
info "익명 사용 통계가 기본 활성입니다. 끄려면: codegraph telemetry off"

echo ""
success "구조 지식 계층 준비 완료"
echo "    조회:  codegraph explore \"<질문>\"  ·  codegraph impact <심볼>  ·  codegraph callers <심볼>"
echo "    한계:  Django 모델 필드·db_table·시그널 배선은 인덱싱되지 않습니다 (DOMAIN.md 담당)"
