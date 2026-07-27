#!/bin/bash
# PostToolUse(Edit|Write|MultiEdit) 훅 — 도메인 의미 변화 게이트
#
# 이전 버전(domain-update-reminder.sh)은 워킹트리 전체를 보고 echo만 했다.
# models.py를 한 번 건드리면 이후 모든 편집마다 같은 배너가 떠서 무시당했고,
# 강제력이 없어 실제 갱신으로 이어지지 않았다.
# (plab 실측: models.py 866커밋 대비 DOMAIN.md 19커밋 — 2.2%)
#
# 이 버전은 세 가지가 다르다:
#   1. 방금 편집한 파일 하나만 판정한다 (반복 발화 없음)
#   2. AST 지문 비교로 의미가 실제 바뀐 경우에만 발화한다 (오탐 없음)
#   3. exit 2 로 에이전트에게 차단성 피드백을 준다 (echo가 아니라 지시)
#
# 훅 페이로드 파싱도 게이트에 맡긴다. 여기서 python3 로 JSON을 먼저 까면
# 편집 한 번에 인터프리터가 두 번 뜬다. Edit/Write 직후마다 도는 경로다.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
GATE="$PROJECT_DIR/.claude/scripts/domain-gate.py"

[ -f "$GATE" ] || exit 0
command -v python3 &>/dev/null || exit 0

OUTPUT=$(python3 "$GATE" --repo "$PROJECT_DIR" --hook-payload 2>&1)
STATUS=$?

# 2 = 내부 오류(git 없음, 판정기 로딩 실패 등). 게이트 고장이 작업을 막아서는 안 된다.
# 커밋 시점에는 pre-commit 이 같은 오류로 차단하므로 고장 자체는 드러난다.
if [ "$STATUS" -eq 1 ]; then
  echo "$OUTPUT" >&2
  exit 2
fi

exit 0
