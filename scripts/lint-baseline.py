#!/usr/bin/env python3
"""기존 레포에 ruff를 처음 켤 때 쓰는 baseline 생성기.

harness-init 은 이미 개발이 진행된 남의 레포에 주입된다. 그런 레포에 ruff를 처음
켜면 레거시 위반이 쏟아지고, pre-commit 이 **모든 커밋을 막는다**. 그러면 DOMAIN.md를
갱신하려는 커밋조차 통과하지 못해 지식 루프 자체가 멈춘다.

실측(plab pf-server-django, 2026-07-27): 8,221건 / 1,418파일 / 21개 규칙 코드.

per-file-ignores 로 파일 단위 유예를 주면 (파일,규칙) 쌍이 2,338개라 pyproject.toml이
읽을 수 없게 된다. 그래서 **규칙 코드 단위**로 유예한다. 21줄이면 한눈에 보이고,
한 줄 지우면 그 규칙이 즉시 다시 켜진다 (래칫).

트레이드오프는 명시해 둔다: 유예된 코드는 신규 코드에서도 잡히지 않는다. 대신
유예 목록이 pyproject.toml 한곳에 모여 있어 무엇을 포기했는지 항상 보인다.
게이트를 조용히 낮추지 않는 것이 목적이다.

사용법: python3 lint-baseline.py <target_dir> [--apply]
        --apply 없이 실행하면 무엇이 유예될지 출력만 한다.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

MARKER = "# harness-init:lint-baseline"


def find_ruff():
    """PATH → pre-commit 캐시 순으로 ruff 실행 파일을 찾는다."""
    found = shutil.which("ruff")
    if found:
        return found
    patterns = [
        os.path.expanduser("~/.cache/pre-commit/repo*/py_env*/bin/ruff"),
        os.path.expanduser("~/.cache/pre-commit/repo*/*/bin/ruff"),
    ]
    for pattern in patterns:
        matches = sorted(glob.glob(pattern))
        if matches:
            return matches[-1]
    return None


def scan(ruff, target):
    """프로젝트 설정(pyproject.toml)을 그대로 써서 위반을 수집한다.

    --isolated 를 쓰지 않는 이유: pre-commit 이 실제로 적용할 설정과 baseline이
    달라지면 유예 목록이 틀어진다.
    """
    try:
        proc = subprocess.run(
            [ruff, "check", ".", "--output-format=json", "--no-cache", "--quiet"],
            cwd=target,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return None, f"ruff 실행 실패: {exc}"

    if not proc.stdout.strip():
        # 위반이 0건이어도 ruff는 빈 배열을 낸다. 출력이 아예 없으면 설정 오류다.
        return None, (proc.stderr.strip() or "ruff가 출력을 내지 않았습니다")

    try:
        violations = json.loads(proc.stdout)
    except (json.JSONDecodeError, ValueError):
        return None, (proc.stderr.strip() or "ruff 출력을 파싱하지 못했습니다")

    counts = {}
    for v in violations:
        code = v.get("code")
        if code:
            counts[code] = counts.get(code, 0) + 1
    return counts, None


def already_applied(pyproject_path):
    try:
        with open(pyproject_path, encoding="utf-8") as f:
            return MARKER in f.read()
    except OSError:
        return False


def render_block(counts):
    """[tool.ruff.lint] 아래에 넣을 ignore 블록."""
    total = sum(counts.values())
    lines = [
        MARKER,
        f"# 하네스 도입 시점에 이미 존재하던 위반 {total:,}건을 규칙 단위로 유예했다.",
        "# 신규 코드에도 적용되지 않으니, 한 줄씩 지워가며 되살리는 것이 목표다.",
        "#   확인:  ruff check . --select <코드>",
        "#   수정:  ruff check . --select <코드> --fix",
        "ignore = [",
    ]
    for code in sorted(counts):
        lines.append(f'    "{code}",  # {counts[code]:,}건')
    lines.append("]")
    return "\n".join(lines)


def apply_block(pyproject_path, counts):
    """[tool.ruff.lint] 섹션 안에 ignore 블록을 삽입한다."""
    with open(pyproject_path, encoding="utf-8") as f:
        text = f.read()

    block = render_block(counts)
    section = re.search(r"^\[tool\.ruff\.lint\]\s*$", text, re.M)
    if not section:
        # 섹션이 없으면 파일 끝에 새로 만든다.
        text = text.rstrip("\n") + "\n\n[tool.ruff.lint]\n" + block + "\n"
    else:
        insert_at = section.end()
        text = text[:insert_at] + "\n" + block + text[insert_at:]

    with open(pyproject_path, "w", encoding="utf-8") as f:
        f.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("target", nargs="?", default=".")
    parser.add_argument(
        "--apply", action="store_true", help="pyproject.toml 에 실제로 기록"
    )
    args = parser.parse_args()

    target = os.path.abspath(args.target)
    pyproject = os.path.join(target, "pyproject.toml")

    if not os.path.isfile(pyproject):
        print("[lint-baseline] pyproject.toml 없음 — 건너뜁니다")
        return 0

    if already_applied(pyproject):
        print("[lint-baseline] baseline 이미 적용됨, 건너뜁니다")
        return 0

    ruff = find_ruff()
    if not ruff:
        print("[lint-baseline] ruff를 찾지 못해 baseline을 건너뜁니다.")
        print("  기존 레포라면 첫 커밋에서 레거시 위반으로 막힐 수 있습니다.")
        print("  그때 실행: python3 ~/harness-init/scripts/lint-baseline.py . --apply")
        return 0

    counts, err = scan(ruff, target)
    if err:
        print(f"[lint-baseline] 검사 실패 — 건너뜁니다 ({err})")
        return 0

    if not counts:
        print("[lint-baseline] 기존 위반 0건 — 유예 없이 엄격 모드로 시작합니다")
        return 0

    total = sum(counts.values())
    top = sorted(counts.items(), key=lambda kv: -kv[1])[:5]

    print("")
    print("  ─────────────────────────────────────────────────────")
    print(f"  ruff 기존 위반 {total:,}건 (규칙 {len(counts)}종) 발견")
    print("  ─────────────────────────────────────────────────────")
    for code, n in top:
        print(f"    {code:<8} {n:>6,}건")
    if len(counts) > len(top):
        print(f"    ... 외 {len(counts) - len(top)}종")
    print("")

    if not args.apply:
        print("  유예 없이 두면 이 파일들을 건드리는 모든 커밋이 막힙니다.")
        print("  적용하려면: python3 scripts/lint-baseline.py . --apply")
        print("")
        print(render_block(counts))
        return 0

    apply_block(pyproject, counts)
    print(f"  → pyproject.toml 에 규칙 단위 유예를 기록했습니다 ({len(counts)}종).")
    print("    신규 코드도 유예 대상 규칙은 검사되지 않습니다. 래칫으로 줄여가세요:")
    print(f"      ruff check . --select {top[0][0]} --fix")
    print("    고친 뒤 pyproject.toml 의 해당 줄을 지우면 그 규칙이 다시 켜집니다.")
    print("")
    return 0


if __name__ == "__main__":
    sys.exit(main())
