#!/bin/bash

# harness-init: 프로젝트에 Harness Engineering 환경 셋업
# 사용법: bash init.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
TARGET_DIR="${PWD}"

# ── 색상 출력 ──────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[harness]${NC} $1"; }
success() { echo -e "${GREEN}[harness]${NC} ✓ $1"; }
warn()    { echo -e "${YELLOW}[harness]${NC} $1"; }

# ── 환경 선택 ──────────────────────────────────────────
if [ -z "$ENV_TYPE" ]; then
  if [ -t 0 ]; then
    echo ""
    echo -e "${BLUE}  어떤 환경으로 구축 예정이신가요?${NC}"
    echo "  1) Python  (Django / FastAPI / Flask)"
    echo "  2) JS / TS (Next.js / NestJS / Express)"
    echo "  3) 모름    (자동 감지)"
    echo ""
    printf "  선택 [1-3]: "
    read -r ENV_CHOICE || ENV_CHOICE="3"

    case "$ENV_CHOICE" in
      1) ENV_TYPE="python" ;;
      2) ENV_TYPE="js"     ;;
      *) ENV_TYPE="auto"   ;;
    esac
    echo ""
  else
    ENV_TYPE="auto"
  fi
fi

# ── 스택 감지 ──────────────────────────────────────────
STACK=$(bash "$SCRIPT_DIR/scripts/migration.sh" --detect "$TARGET_DIR")
info "감지된 스택: $STACK"

# ── CLAUDE.md 생성/업데이트 ────────────────────────────
bash "$SCRIPT_DIR/scripts/merge-claude-md.sh" "$TARGET_DIR" "$TEMPLATE_DIR"

# ── .claude 디렉토리 구조 생성 ─────────────────────────
info ".claude 디렉토리 구성 중..."

mkdir -p "$TARGET_DIR/.claude/tasks"
mkdir -p "$TARGET_DIR/.claude/decisions"
mkdir -p "$TARGET_DIR/.claude/skills"
mkdir -p "$TARGET_DIR/.claude/agents"
mkdir -p "$TARGET_DIR/.claude/commands"

# skills 복사 (서브디렉토리 포함: orchestrator/)
cp -rn "$TEMPLATE_DIR/django/.claude/skills/"* "$TARGET_DIR/.claude/skills/" 2>/dev/null || true
success "skills 설치 완료"

# ADR 템플릿 복사
cp -n "$TEMPLATE_DIR/django/.claude/decisions/adr-template.md" "$TARGET_DIR/.claude/decisions/" 2>/dev/null || true

# agents 복사
cp -rn "$TEMPLATE_DIR/django/.claude/agents/"* "$TARGET_DIR/.claude/agents/" 2>/dev/null || true
success "agents 설치 완료"

# commands 복사
cp -rn "$TEMPLATE_DIR/django/.claude/commands/"* "$TARGET_DIR/.claude/commands/" 2>/dev/null || true
success "commands 설치 완료"

# hooks 복사
if [ -d "$TEMPLATE_DIR/django/.claude/hooks" ]; then
  mkdir -p "$TARGET_DIR/.claude/hooks"
  cp -rn "$TEMPLATE_DIR/django/.claude/hooks/"* "$TARGET_DIR/.claude/hooks/" 2>/dev/null || true
  chmod +x "$TARGET_DIR/.claude/hooks/"*.sh 2>/dev/null || true
  success "hooks 설치 완료"
fi

# rules 복사 (CLAUDE.md @imports 참조 대상)
if [ -d "$TEMPLATE_DIR/django/.claude/rules" ]; then
  mkdir -p "$TARGET_DIR/.claude/rules"
  cp -rn "$TEMPLATE_DIR/django/.claude/rules/"* "$TARGET_DIR/.claude/rules/" 2>/dev/null || true
  success "rules 설치 완료"
fi

# 도메인 지식 도구 복사 (.claude/scripts/)
# 다른 템플릿과 달리 -n 이 아니라 덮어쓴다. 이 셋은 사용자가 편집하는 설정이 아니라
# 훅·pre-commit·에이전트가 함께 호출하는 하네스 소유 코드라, 버전이 어긋나면
# 게이트가 조용히 오작동한다. 재실행 시 항상 최신으로 맞춘다.
mkdir -p "$TARGET_DIR/.claude/scripts"
cp "$SCRIPT_DIR/scripts/domain-extract.py" \
   "$SCRIPT_DIR/scripts/domain-gate.py" \
   "$SCRIPT_DIR/scripts/domain-freshness.py" \
   "$TARGET_DIR/.claude/scripts/" 2>/dev/null || true
chmod +x "$TARGET_DIR/.claude/scripts/"*.py 2>/dev/null || true
success "도메인 지식 도구 설치 완료 (.claude/scripts/ — extract/gate/freshness)"

# settings.json (없을 때만 생성)
if [ ! -f "$TARGET_DIR/.claude/settings.json" ]; then
  cp "$TEMPLATE_DIR/django/.claude/settings.json" "$TARGET_DIR/.claude/settings.json"
  success "settings.json 생성 완료"
else
  warn ".claude/settings.json 이미 존재, 건너뜀"
fi

# ── LSP 설정 주입 ────────────────────────────────────────
# 언어에 따라 settings.json에 LSP 서버 설정 추가 (이미 lsp 키가 있으면 건너뜀)
SETTINGS_FILE="$TARGET_DIR/.claude/settings.json"
_inject_lsp_python() {
  python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        s = json.load(f)
    if not isinstance(s, dict):
        s = {}
except Exception:
    s = {}
if "python" not in s.setdefault("lsp", {}):
    s["lsp"]["python"] = {"command": "pylsp"}
    with open(path, "w") as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
        f.write("\n")
PYEOF
}
_inject_lsp_js() {
  python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        s = json.load(f)
    if not isinstance(s, dict):
        s = {}
except Exception:
    s = {}
lsp = s.setdefault("lsp", {})
if not isinstance(lsp, dict):
    lsp = s["lsp"] = {}
if "typescript" not in lsp or "javascript" not in lsp:
    lsp.update({
        "typescript": {"command": "typescript-language-server", "args": ["--stdio"]},
        "javascript": {"command": "typescript-language-server", "args": ["--stdio"]}
    })
    with open(path, "w") as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
        f.write("\n")
PYEOF
}

case "$ENV_TYPE" in
  python)
    _inject_lsp_python && success "LSP 설정 완료 (Python: pylsp)"
    ;;
  js)
    _inject_lsp_js && success "LSP 설정 완료 (JS/TS: typescript-language-server)"
    ;;
  auto)
    case "$STACK" in
      django|fastapi|flask)
        _inject_lsp_python && success "LSP 설정 완료 (Python: pylsp)"
        ;;
      nextjs|nestjs|express|node)
        _inject_lsp_js && success "LSP 설정 완료 (JS/TS: typescript-language-server)"
        ;;
      *)
        warn "LSP: 스택을 인식하지 못해 LSP 설정을 건너뜁니다 (수동으로 settings.json에 추가하세요)"
        ;;
    esac
    ;;
esac

# project debrief-guardrails 생성 (없을 때만, 스택 무관)
PROJECT_NAME=$(basename "$TARGET_DIR")
if [ ! -f "$TARGET_DIR/.claude/debrief-guardrails.md" ]; then
  sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/" \
    "$TEMPLATE_DIR/base/project-debrief-guardrails.md" \
    > "$TARGET_DIR/.claude/debrief-guardrails.md"
  success "debrief-guardrails.md 생성 완료 (.claude/)"
fi

# .gemini 복사
if [ -d "$TEMPLATE_DIR/django/.gemini" ]; then
  mkdir -p "$TARGET_DIR/.gemini"
  cp -rn "$TEMPLATE_DIR/django/.gemini/"* "$TARGET_DIR/.gemini/" 2>/dev/null || true
  success ".gemini 설치 완료"
fi

# .github 복사
if [ -d "$TEMPLATE_DIR/django/.github" ]; then
  mkdir -p "$TARGET_DIR/.github"
  cp -rn "$TEMPLATE_DIR/django/.github/"* "$TARGET_DIR/.github/" 2>/dev/null || true
  success ".github 설치 완료"
fi

# docs 복사
if [ -d "$TEMPLATE_DIR/django/docs" ]; then
  mkdir -p "$TARGET_DIR/docs"
  cp -rn "$TEMPLATE_DIR/django/docs/"* "$TARGET_DIR/docs/" 2>/dev/null || true
  success "docs 설치 완료"
fi

# DOMAIN.md 복사 (JS: 정적 템플릿 / Python: domain-init.sh가 동적 생성)
IS_JS_ENV() { [ "$ENV_TYPE" = "js" ] || { [ "$ENV_TYPE" = "auto" ] && [[ "$STACK" =~ ^(nextjs|nestjs|express|node)$ ]]; }; }
IS_PYTHON_ENV() { [ "$ENV_TYPE" = "python" ] || { [ "$ENV_TYPE" = "auto" ] && [[ "$STACK" =~ ^(django|fastapi|flask)$ ]]; }; }
if IS_JS_ENV; then
  if [ ! -f "$TARGET_DIR/DOMAIN.md" ]; then
    cp "$TEMPLATE_DIR/js/DOMAIN.md" "$TARGET_DIR/DOMAIN.md"
    success "DOMAIN.md 템플릿 생성 완료 (JS용 — TODO 항목 채우기 필요)"
  else
    warn "DOMAIN.md 이미 존재, 건너뜀"
  fi
fi

# ── .gitignore 업데이트 ────────────────────────────────
GITIGNORE="$TARGET_DIR/.gitignore"
APPEND_FILE="$TEMPLATE_DIR/django/.gitignore.append"

if [ -f "$GITIGNORE" ]; then
  if ! grep -q ".claude/local/" "$GITIGNORE"; then
    echo "" >> "$GITIGNORE"
    cat "$APPEND_FILE" >> "$GITIGNORE"
    success ".gitignore 업데이트 완료"
  else
    warn ".gitignore 이미 설정됨, 건너뜀"
  fi
else
  cp "$APPEND_FILE" "$GITIGNORE"
  success ".gitignore 생성 완료"
fi

# ── pre-commit 설정 ────────────────────────────────────
# ENV_TYPE 우선, 그 외에는 스택 자동 감지 (java/spring 계열은 생략)
case "$ENV_TYPE" in
  python)
    PRECOMMIT_YAML="$TEMPLATE_DIR/django/.pre-commit-config.yaml"
    ;;
  js)
    PRECOMMIT_YAML="$TEMPLATE_DIR/js/.pre-commit-config.yaml"
    ;;
  *)
    case "$STACK" in
      nextjs|nestjs|express|node)
        PRECOMMIT_YAML="$TEMPLATE_DIR/js/.pre-commit-config.yaml"
        ;;
      django|fastapi|flask)
        PRECOMMIT_YAML="$TEMPLATE_DIR/django/.pre-commit-config.yaml"
        ;;
      *)
        PRECOMMIT_YAML=""
        ;;
    esac
    ;;
esac

if [ -n "$PRECOMMIT_YAML" ] && [ -f "$PRECOMMIT_YAML" ]; then
  if [ ! -f "$TARGET_DIR/.pre-commit-config.yaml" ]; then
    cp "$PRECOMMIT_YAML" "$TARGET_DIR/.pre-commit-config.yaml"
    success ".pre-commit-config.yaml 생성 완료"
  else
    warn ".pre-commit-config.yaml 이미 존재, 건너뜀"
  fi

  # pyproject.toml — ruff 설정 (Python 스택만, 없을 때만)
  HARNESS_OWNS_PYPROJECT=false
  if [ "$PRECOMMIT_YAML" = "$TEMPLATE_DIR/django/.pre-commit-config.yaml" ]; then
    if [ ! -f "$TARGET_DIR/pyproject.toml" ]; then
      sed "s|{project_name}|${PROJECT_NAME//&/\\&}|g" \
        "$TEMPLATE_DIR/django/pyproject.toml" > "$TARGET_DIR/pyproject.toml"
      HARNESS_OWNS_PYPROJECT=true
      success "pyproject.toml 생성 완료 (ruff: E/F/I 규칙, black-compatible)"
    else
      warn "pyproject.toml 이미 존재, 건너뜀"
    fi
  fi

  # pre-commit 설치 확인 및 자동 설치 (brew → pipx → pip 순으로 시도)
  if ! command -v pre-commit &>/dev/null; then
    info "pre-commit 미설치 — 설치 시도 중..."
    if command -v brew &>/dev/null; then
      brew install pre-commit -q && success "pre-commit 설치 완료 (brew)"
    elif command -v pipx &>/dev/null; then
      pipx install pre-commit && success "pre-commit 설치 완료 (pipx)"
    elif command -v pip &>/dev/null; then
      pip install pre-commit -q && success "pre-commit 설치 완료 (pip)"
    elif command -v pip3 &>/dev/null; then
      pip3 install pre-commit -q && success "pre-commit 설치 완료 (pip3)"
    else
      warn "pre-commit 자동 설치 실패. 수동으로 설치 후 'pre-commit install' 실행하세요:"
      warn "  brew install pre-commit  또는  pipx install pre-commit"
    fi
  fi

  # git 저장소이면 훅 등록 (pre-commit 설치 확인 후 실행)
  if git -C "$TARGET_DIR" rev-parse --git-dir &>/dev/null; then
    if command -v pre-commit &>/dev/null; then
      (cd "$TARGET_DIR" && pre-commit install) && success "pre-commit 훅 등록 완료"
    fi
  else
    warn "git 저장소가 아닙니다. 'git init' 후 'pre-commit install' 수동 실행 필요"
  fi

  # ── lint baseline ──────────────────────────────────
  # 이미 개발이 진행된 레포에 ruff를 처음 켜면 레거시 위반이 쏟아져 모든 커밋이 막힌다.
  # 그러면 DOMAIN.md 갱신 커밋도 통과하지 못해 지식 루프 자체가 멈춘다.
  # 기존 위반을 규칙 단위로 유예해 루프를 살리고, 무엇을 유예했는지는 항상 노출한다.
  if [ "$HARNESS_OWNS_PYPROJECT" = true ]; then
    # 하네스가 만든 pyproject.toml 이므로 직접 기록한다.
    python3 "$SCRIPT_DIR/scripts/lint-baseline.py" "$TARGET_DIR" --apply
  elif [ -f "$TARGET_DIR/pyproject.toml" ]; then
    # 기존 pyproject.toml 은 남의 설정이다. 건드리지 않고 보고만 한다.
    python3 "$SCRIPT_DIR/scripts/lint-baseline.py" "$TARGET_DIR"
  fi
fi

# ── 비 Django 스택이면 harness 마이그레이션 ───────────
if [ "$STACK" != "django" ]; then
  info "비 Django 스택 감지 — harness 마이그레이션 실행..."
  bash "$SCRIPT_DIR/scripts/migration.sh" "$TARGET_DIR"
fi

# ── 구조 지식 계층 (codegraph) ─────────────────────────
# 선택 의존성. 없으면 안내만 하고 넘어간다 — 하네스는 codegraph 없이도 동작하고,
# 에이전트 rules에 Grep/Read 폴백 경로가 명시되어 있다.
bash "$SCRIPT_DIR/scripts/codegraph-setup.sh" "$TARGET_DIR"

# ── 의미 지식 계층 (DOMAIN.md) ─────────────────────────
# 구조(모델 목록·필드·관계·호출 경로)는 codegraph가 실시간으로 답하므로 문서화하지 않는다.
# 여기서는 codegraph가 못 보는 것 — Choices 값, db_table 매핑, 시그널 부수효과 — 만
# AST로 추출해 스켈레톤을 만든다.
EXISTING_MODELS=$(find "$TARGET_DIR" -name "models.py" \
  ! -path "*/migrations/*" \
  ! -path "*/.venv/*" \
  ! -path "*/venv/*" \
  ! -path "*/env/*" \
  ! -path "*/__pycache__/*" \
  ! -path "*/.git/*" \
  2>/dev/null | head -1)

if ! IS_JS_ENV && IS_PYTHON_ENV; then
  info "의미 지식 스켈레톤 생성 중..."
  bash "$SCRIPT_DIR/scripts/domain-init.sh" "$TARGET_DIR"

  # 앱을 찾지 못했으면(신규 프로젝트 등) 루트에 기본 템플릿만 둔다.
  if [ ! -f "$TARGET_DIR/DOMAIN.md" ]; then
    sed "s|{project_name}|${PROJECT_NAME//&/\\&}|g" \
      "$TEMPLATE_DIR/django/DOMAIN.md" > "$TARGET_DIR/DOMAIN.md"
    success "DOMAIN.md 기본 템플릿 생성 완료"
  fi

  # 시그널 핸들러 본문을 읽어 '무슨 부수효과를 내나' 열만 채운다 (Claude Code 필요).
  if [ -n "$EXISTING_MODELS" ]; then
    bash "$SCRIPT_DIR/scripts/domain-fill.sh" "$TARGET_DIR"
  fi
fi

# ── 전역 자기강화 루프 설정 (~/.claude) ────────────────
info "전역 자기강화 루프 설정 중..."

GLOBAL_CLAUDE="$HOME/.claude"
GLOBAL_HOOKS="$GLOBAL_CLAUDE/hooks"
GLOBAL_DEBRIEFS="$GLOBAL_CLAUDE/debriefs"

mkdir -p "$GLOBAL_HOOKS" "$GLOBAL_DEBRIEFS"

# 훅 스크립트 복사 (기존 파일 덮어쓰지 않음)
cp -n "$TEMPLATE_DIR/base/hooks/session-stop.sh" \
  "$GLOBAL_HOOKS/session-stop.sh" 2>/dev/null || true
cp -n "$TEMPLATE_DIR/base/hooks/session-start-context.sh" \
  "$GLOBAL_HOOKS/session-start-context.sh" 2>/dev/null || true
chmod +x "$GLOBAL_HOOKS/session-stop.sh" \
         "$GLOBAL_HOOKS/session-start-context.sh" 2>/dev/null || true

# 전역 debrief-guardrails 생성 (없을 때만)
if [ ! -f "$GLOBAL_CLAUDE/debrief-guardrails.md" ]; then
  cp "$TEMPLATE_DIR/base/debrief-guardrails.md" \
    "$GLOBAL_CLAUDE/debrief-guardrails.md"
  success "debrief-guardrails.md 생성 완료 (~/.claude/)"
fi

# ~/.claude/settings.json에 훅 등록 (python3 사용, 기존 항목 중복 방지)
GLOBAL_SETTINGS="$GLOBAL_CLAUDE/settings.json"
if [ -f "$GLOBAL_SETTINGS" ]; then
  python3 - "$GLOBAL_SETTINGS" << 'PYEOF'
import json, sys, os

path = sys.argv[1]
try:
    with open(path) as f:
        s = json.load(f)
    if not isinstance(s, dict):
        s = {}
except (json.JSONDecodeError, ValueError):
    s = {}

hooks = s.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = {}
    s["hooks"] = hooks

def ensure_hook(key, cmd, timeout):
    entries = hooks.get(key)
    if not isinstance(entries, list):
        entries = [{"hooks": []}]
        hooks[key] = entries
    existing = [h.get("command") for e in entries if isinstance(e, dict) for h in e.get("hooks", []) if isinstance(h, dict)]
    if cmd not in existing:
        if not entries or not isinstance(entries[0], dict):
            entries.insert(0, {"hooks": []})
        entries[0].setdefault("hooks", []).append({"type": "command", "command": cmd, "timeout": timeout})

home = os.path.expanduser("~")
ensure_hook("Stop",         f"{home}/.claude/hooks/session-stop.sh",          10)
ensure_hook("SessionStart", f"{home}/.claude/hooks/session-start-context.sh",  5)

with open(path, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
PYEOF
  success "~/.claude/settings.json 훅 등록 완료"
else
  warn "~/.claude/settings.json 없음 — 훅을 수동으로 등록하세요"
  warn "  Stop:         ~/.claude/hooks/session-stop.sh"
  warn "  SessionStart: ~/.claude/hooks/session-start-context.sh"
fi

# ── 완료 메시지 ────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Harness Engineering 환경 셋업 완료! [$STACK]${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  생성된 파일:"
echo "  ├── CLAUDE.md"
echo "  ├── .gitignore"
echo "  ├── .pre-commit-config.yaml   (python: ruff / js: prettier+eslint)"
echo "  ├── pyproject.toml            (python only: ruff E/F/I + black-compatible format)"
echo "  ├── .claude/tasks/"
echo "  ├── .claude/decisions/"
echo "  ├── .claude/skills/          (explore/implement/debug/review/autopilot + orchestrator)"
echo "  ├── .claude/agents/          (analyst/architect/coder/tester/reviewer)"
echo "  ├── .claude/commands/        (/review, /workflows:gemini-review 슬래시 커맨드)"
echo "  ├── .claude/hooks/           (session-knowledge — SessionStart / pre-bash-guard — PreToolUse / domain-guard, insight-collector, notification)"
echo "  ├── .claude/scripts/         (domain-extract / domain-gate / domain-freshness — 의미 지식 도구)"
echo "  ├── .claude/rules/           (knowledge / architecture / testing / domain / agents / hooks — CLAUDE.md @imports)"
echo "  ├── .claude/settings.json"
echo "  ├── .gemini/                 (Gemini Code Assist 설정)"
echo "  ├── .github/                 (이슈 템플릿, PR 템플릿, 워크플로우)"
echo "  ├── docs/DOC-SYNC-POLICY.md  (문서 동기화 정책)"
  if IS_JS_ENV; then
    echo "  └── DOMAIN.md  (JS 템플릿 — 의미 TODO 채우기 필요)"
  elif [ -n "$EXISTING_MODELS" ]; then
    echo "  └── DOMAIN.md + 앱별 DOMAIN.md  (값·위치는 AST로 채워짐 / '의미' TODO는 사람 몫)"
  elif IS_PYTHON_ENV; then
    echo "  └── DOMAIN.md  (Python 기본 템플릿 — 의미 TODO 채우기 필요)"
  else
    echo "  └── (DOMAIN.md: 신규 프로젝트 — 코드 작성 후 domain-init.sh 실행)"
  fi
echo ""
echo -e "${BLUE}  지식 계층${NC}"
echo "  ├── 구조 (어디에 뭐가 있나·뭐가 뭘 부르나)  → codegraph, 실시간 인덱스"
echo "  └── 의미 (무슨 뜻인가·왜 이런가)            → DOMAIN.md, 게이트가 최신 강제"
echo ""
echo -e "${BLUE}  자동 가드레일 3단${NC}"
echo "  ├── 세션 시작   session-knowledge.sh  인덱스 동기화 + 낡은 문서 경고"
echo "  ├── 편집 직후   domain-guard.sh       의미 변화 감지 → 갱신 지시 (exit 2)"
echo "  └── 커밋 직전   domain-gate           문서 미갱신이면 커밋 차단"
echo ""
echo "  에이전트 팀 (orchestrator 스킬):"
echo "  analyst → architect → coder ⇄ tester → reviewer"
echo ""
echo "  슬래시 커맨드:"
echo "  /orchestrator   /review   /explore   /implement   /debug   /autopilot"
echo ""
echo "  GitHub Actions:"
echo "  claude-code-review · claude · pr-auto-fill · pr-test · post-merge-docs · domain-drift"
echo ""

if IS_JS_ENV; then
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}  📝 DOMAIN.md 작성 가이드 (JS/TS 환경)${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  DOMAIN.md 에 사용 중인 ORM/스키마 라이브러리의 도메인 지식을 채워두세요."
  echo "  AI 에이전트가 코드 작성 전 이 문서를 참조합니다."
  echo ""
  echo "  라이브러리별 스키마 위치 힌트:"
  echo "  · Prisma    → prisma/schema.prisma"
  echo "  · TypeORM   → src/**/*.entity.ts"
  echo "  · Mongoose  → src/**/*.schema.ts"
  echo "  · Drizzle   → src/db/schema.ts"
  echo ""
  echo "  자동화 힌트 (스크립트로 스켈레톤 생성하고 싶다면):"
  echo "  Django용 자동 생성 스크립트를 참고해 ORM에 맞게 응용하세요:"
  echo "  → $(dirname "$0")/scripts/domain-init.sh"
  echo ""
fi
