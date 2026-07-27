#!/bin/bash
# SessionStart 훅 — 지식 계층 준비 및 상태 주입
#
# 세션이 시작될 때 두 가지를 한다:
#   1. codegraph 인덱스를 증분 동기화한다 (구조 지식을 최신으로)
#   2. DOMAIN.md 신선도를 컨텍스트로 주입한다 (의미 지식이 낡았음을 알림)
#
# 2번이 중요하다. 낡은 문서를 낡은 줄 모르고 근거 삼는 게 가장 위험하다.
# plab 실측에서 web/order/DOMAIN.md는 소스보다 160일 뒤처져 있었고,
# 그 사실을 아무도(에이전트 포함) 몰랐다.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRIPTS="$PROJECT_DIR/.claude/scripts"

export PATH="$HOME/.local/bin:$PATH"

# 두 작업은 서로 의존하지 않는다. 직렬로 두면 최악의 경우 타임아웃이 합산되어
# 세션 시작이 40초까지 늘어난다. 병렬로 돌려 천장을 절반으로 낮춘다.
TMPDIR_HOOK=$(mktemp -d 2>/dev/null) || TMPDIR_HOOK=""
CG_OUT="${TMPDIR_HOOK:-/tmp}/cg.$$"
FRESH_OUT="${TMPDIR_HOOK:-/tmp}/fresh.$$"
cleanup() { [ -n "$TMPDIR_HOOK" ] && rm -rf "$TMPDIR_HOOK"; }
trap cleanup EXIT

# ── 1. 구조 지식 동기화 ────────────────────────────────
(
  if command -v codegraph &>/dev/null && [ -d "$PROJECT_DIR/.codegraph" ]; then
    if (cd "$PROJECT_DIR" && timeout 20 codegraph sync . >/dev/null 2>&1); then
      echo "구조 지식(codegraph) 인덱스 동기화됨. 코드 구조·호출 경로·영향 범위는 파일을 훑지 말고 codegraph로 조회하세요."
    else
      echo "구조 지식(codegraph) 동기화 실패 — 인덱스가 낡았을 수 있습니다. 'codegraph index .' 로 재빌드하세요."
    fi
  elif command -v codegraph &>/dev/null; then
    echo "codegraph 설치됨, 이 프로젝트는 미초기화 — 'codegraph init .' 실행 시 구조 조회를 쓸 수 있습니다."
  fi
) > "$CG_OUT" 2>/dev/null &
CG_PID=$!

# ── 2. 의미 지식 신선도 ────────────────────────────────
(
  if [ -f "$SCRIPTS/domain-freshness.py" ] && command -v python3 &>/dev/null; then
    timeout 20 python3 "$SCRIPTS/domain-freshness.py" "$PROJECT_DIR" --stale-days 30
  fi
) > "$FRESH_OUT" 2>/dev/null &
FRESH_PID=$!

wait "$CG_PID" "$FRESH_PID" 2>/dev/null
CG_LINE=$(cat "$CG_OUT" 2>/dev/null)
FRESH=$(cat "$FRESH_OUT" 2>/dev/null)

# ── 출력 ───────────────────────────────────────────────
if [ -z "$CG_LINE" ] && [ -z "$FRESH" ]; then
  exit 0
fi

echo "## 지식 계층 상태"
echo ""
[ -n "$CG_LINE" ] && { echo "$CG_LINE"; echo ""; }
[ -n "$FRESH" ] && { echo "$FRESH"; echo ""; }
echo "구조(어디에 무엇이 있나)는 codegraph, 의미(그게 무슨 뜻인가)는 DOMAIN.md가 담당합니다."
echo "자세한 역할 분담은 .claude/rules/knowledge.md 를 참조하세요."

exit 0
