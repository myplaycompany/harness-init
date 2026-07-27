#!/bin/bash
# CLAUDE.md를 프로젝트에 주입
# - 기존 파일 있으면 harness 섹션 추가
# - 없으면 새로 생성

TARGET_DIR="$1"
TEMPLATE_DIR="$2"

TEMPLATE_FILE="$TEMPLATE_DIR/django/CLAUDE.md"
TARGET_FILE="$TARGET_DIR/CLAUDE.md"
MARKER="<!-- harness-init: DO NOT REMOVE -->"

if [ -f "$TARGET_FILE" ]; then
  if grep -q "$MARKER" "$TARGET_FILE"; then
    echo -e "\033[1;33m[harness]\033[0m CLAUDE.md 이미 harness 설정 포함, 건너뜀"
    exit 0
  fi
  {
    echo ""
    echo "$MARKER"
    echo ""
    cat "$TEMPLATE_FILE"
  } >> "$TARGET_FILE"
  echo -e "\033[0;32m[harness]\033[0m ✓ CLAUDE.md 업데이트 완료"
else
  # 신규 생성 시에도 마커를 넣는다. 없으면 재실행 시 "harness 설정 없음"으로
  # 판정해 템플릿 전체를 한 번 더 덧붙인다 (재실행마다 CLAUDE.md가 배로 늘어남).
  {
    echo "$MARKER"
    echo ""
    cat "$TEMPLATE_FILE"
  } > "$TARGET_FILE"
  echo -e "\033[0;32m[harness]\033[0m ✓ CLAUDE.md 생성 완료"
fi
