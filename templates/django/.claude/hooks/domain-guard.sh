#!/bin/bash
# PostToolUse(Edit|Write|MultiEdit) 훅 — 도메인 의미 변화 게이트
#
# 이전 버전(domain-update-reminder.sh)은 워킹트리 전체를 보고 echo만 했다.
# models.py를 한 번 건드리면 이후 모든 편집마다 같은 배너가 떠서 무시당했고,
# 강제력이 없어 실제 갱신으로 이어지지 않았다.
# (plab 실측: models.py 866커밋 대비 DOMAIN.md 19커밋 — 2.2%)
#
# 이 버전은 두 가지가 다르다:
#   1. 방금 편집한 파일 하나만 판정한다 (반복 발화 없음)
#   2. AST 지문 비교로 의미가 실제 바뀐 경우에만 발화한다 (오탐 없음)
#   3. exit 2 로 에이전트에게 차단성 피드백을 준다 (echo가 아니라 지시)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
GATE="$PROJECT_DIR/.claude/scripts/domain-gate.py"

[ -f "$GATE" ] || exit 0
command -v python3 &>/dev/null || exit 0

# stdin 으로 들어오는 훅 페이로드에서 편집 대상 경로를 꺼낸다.
PAYLOAD=$(cat)
FILE_PATH=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
ti = data.get("tool_input") or {}
print(ti.get("file_path") or ti.get("path") or "")
' 2>/dev/null)

[ -n "$FILE_PATH" ] || exit 0

OUTPUT=$(python3 "$GATE" --repo "$PROJECT_DIR" --file "$FILE_PATH" 2>&1)
STATUS=$?

# 2 = 내부 오류(git 없음 등). 게이트 고장이 작업을 막아서는 안 된다.
if [ "$STATUS" -eq 1 ]; then
  echo "$OUTPUT" >&2
  exit 2
fi

exit 0
