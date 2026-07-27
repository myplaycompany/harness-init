#!/usr/bin/env python3
"""의미 변화 감지 게이트.

DOMAIN.md가 낡는 이유는 갱신 알림이 너무 자주 떠서다. plab 실측(2026-07-27):
`web/match/models.py`는 866커밋, `web/match/DOMAIN.md`는 19커밋. 2.2%만 따라갔다.
models.py 변경 전체를 트리거로 삼으면 대부분이 오탐이라 무시당한다.

그래서 여기서는 **의미가 실제로 바뀐 변경만** 잡는다. 정규식이 아니라
domain-extract의 AST 추출 결과를 변경 전/후로 비교해서 판정하므로 오탐이 없다.

감지 대상 (전부 codegraph 사각지대 — 실측 확인):
  - Choices/Enum 멤버의 추가·삭제·값 변경
  - @receiver / signal.connect 배선 변경
  - Meta.db_table 변경

모드:
  --file <path>    편집 직후 판정. HEAD와 워킹트리를 비교. (PostToolUse 훅용)
  --staged         커밋 직전 판정. HEAD와 스테이지를 비교. (pre-commit 게이트용)

종료 코드:
  0  의미 변화 없음, 또는 있지만 DOMAIN.md도 함께 갱신됨
  1  의미 변화가 있는데 DOMAIN.md가 갱신되지 않음
  2  내부 오류 (git 없음 등) — 호출부에서 통과 처리할 것
"""

import argparse
import os
import re
import subprocess
import sys

# domain-extract 를 모듈로 불러오면 .claude/scripts/__pycache__/ 가 생긴다.
# 게이트는 pre-commit 안에서도 돌기 때문에 그 쓰레기가 스테이징 후보로 올라온다.
# 애초에 만들지 않는다.
sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from domain_extract import parse_file  # noqa: F401  (파일명이 하이픈이면 아래 폴백)
except ImportError:
    import importlib.util

    _spec = importlib.util.spec_from_file_location(
        "domain_extract",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "domain-extract.py"),
    )
    if _spec is None or _spec.loader is None:
        print("domain-gate: domain-extract.py를 찾을 수 없습니다", file=sys.stderr)
        sys.exit(2)
    domain_extract = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(domain_extract)

# JS/TS/Prisma는 stdlib 파서가 없어 선언 블록을 중괄호 매칭으로 잘라 판정한다.
# (_js_fingerprint 참조 — Python의 ast 경로와 같은 "전/후 지문 비교" 구조)
JS_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".prisma")


def git(args, cwd, allow_fail=False):
    """git 명령을 실행하고 stdout을 반환. 실패 시 None (allow_fail=True일 때)."""
    try:
        out = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=not allow_fail,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout


def _fingerprint(source, path):
    """소스 문자열에서 의미 지문(semantic fingerprint) 집합을 만든다.

    파싱 불가(구문 오류 등)면 None을 반환해 호출부가 판정을 보류하게 한다.
    """
    import ast
    import tempfile

    try:
        ast.parse(source)
    except (SyntaxError, ValueError):
        return None

    with tempfile.NamedTemporaryFile(
        "w", suffix=".py", delete=False, encoding="utf-8"
    ) as tmp:
        tmp.write(source)
        tmp_path = tmp.name
    try:
        result, err = domain_extract.parse_file(tmp_path, path)
    finally:
        os.unlink(tmp_path)

    if err or result is None:
        return None

    marks = set()
    for m in result["models"]:
        marks.add(("table", m["name"], m["db_table"]))
    for c in result["choices"]:
        for mem in c["members"]:
            marks.add(
                ("choice", c.get("owner"), c["name"], mem["name"], repr(mem["value"]))
            )
    for s in result["signals"]:
        marks.add(("signal", s.get("sender"), s["signal"], s["handler"]))
    return marks


def _describe(mark):
    kind = mark[0]
    if kind == "table":
        return f"모델 {mark[1]} → 테이블 {mark[2]}"
    if kind == "choice":
        owner = f"{mark[1]}." if mark[1] else ""
        # 튜플형 choices(`STATUS_CHOICES = (("a", "A"), ...)`)는 멤버 이름이 없다.
        # 그 경우 `.None` 이 붙어 읽는 사람을 헷갈리게 하므로 값만 보여준다.
        member = f".{mark[3]}" if mark[3] else ""
        return f"상태값 {owner}{mark[2]}{member} = {mark[4]}"
    if kind == "signal":
        return f"시그널 {mark[1]} {mark[2]} → {mark[3]}()"
    return str(mark)


def detect_python(repo, path, old_source, new_source):
    """파이썬 파일의 의미 변화를 전/후 지문 차집합으로 판정한다."""
    old_marks = _fingerprint(old_source, path) if old_source is not None else set()
    new_marks = _fingerprint(new_source, path)

    # 새 버전이 파싱 불가면 아직 편집 중이다. 판정을 보류한다.
    if new_marks is None:
        return []
    if old_marks is None:
        old_marks = set()

    changes = []
    for mark in sorted(new_marks - old_marks, key=str):
        changes.append(("추가", _describe(mark)))
    for mark in sorted(old_marks - new_marks, key=str):
        changes.append(("삭제", _describe(mark)))
    return changes


def _match_block(source, open_index):
    """여는 중괄호 위치에서 짝이 맞는 닫는 중괄호까지의 본문을 돌려준다.

    따옴표 안의 중괄호는 세지 않는다. enum·상수 객체 블록을 잘라내는 용도라
    템플릿 리터럴 중첩 같은 극단적 경우까지는 다루지 않는다.
    """
    depth = 0
    quote = None
    for i in range(open_index, len(source)):
        ch = source[i]
        if quote:
            if ch == "\\":
                continue
            if ch == quote:
                quote = None
            continue
        if ch in "\"'`":
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[open_index + 1 : i], i
    return None, len(source)


_JS_ENUM_DECL = re.compile(r"\benum\s+([A-Za-z_$][\w$]*)\s*\{")
_JS_CONST_DECL = re.compile(
    r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*\{"
)
_JS_TYPE_UNION = re.compile(
    r"\btype\s+([A-Za-z_$][\w$]*)\s*=\s*((?:\s*\|?\s*['\"][^'\"]*['\"])+)\s*;", re.S
)
_JS_MEMBER = re.compile(r"^\s*([A-Za-z_$][\w$]*)\s*(?:[:=]\s*(.+?))?\s*,?\s*$")
_PRISMA_MODEL = re.compile(r"\bmodel\s+([A-Za-z_$][\w$]*)\s*\{")
_PRISMA_MAP = re.compile(r"@@map\(\s*['\"]([^'\"]+)['\"]\s*\)")


def _split_members(body):
    """블록 본문을 멤버 단위로 쪼갠다.

    줄바꿈만으로 나누면 `{ FREE: "free", PRO: "pro" }` 처럼 한 줄에 몰아쓴 객체가
    멤버 하나로 잡혀 감지 메시지가 엉뚱해진다. 중첩 괄호와 따옴표 밖의 쉼표에서도
    끊는다.
    """
    parts, buf, depth, quote = [], [], 0, None
    for ch in body:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "\"'`":
            quote = ch
        elif ch in "{[(":
            depth += 1
        elif ch in "}])":
            depth -= 1
        elif (ch == "," or ch == "\n") and depth == 0:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    parts.append("".join(buf))
    return [p.split("//")[0].strip() for p in parts if p.split("//")[0].strip()]


def _js_fingerprint(source):
    """JS/TS/Prisma 소스에서 의미 지문을 만든다.

    Python은 stdlib ast로 정밀 판정하지만 JS 계열은 파서가 없다. 그래서 선언 블록을
    중괄호 매칭으로 잘라 멤버 이름·값을 뽑는 방식을 쓴다. diff 라인만 보던 방식은
    `enum { ... }` 블록 **안에** 멤버를 한 줄 추가하는 가장 흔한 변경을 통째로
    놓쳤다(검증 CASE 10에서 실패 확인). 블록 단위로 보면 그 케이스가 잡힌다.
    """
    marks = set()

    for m in _JS_ENUM_DECL.finditer(source):
        body, _ = _match_block(source, m.end() - 1)
        if body is None:
            continue
        for line in _split_members(body):
            member = _JS_MEMBER.match(line)
            if member:
                marks.add(("enum", m.group(1), member.group(1), member.group(2) or ""))

    for m in _JS_CONST_DECL.finditer(source):
        body, close = _match_block(source, m.end() - 1)
        if body is None:
            continue
        # `} as const` 로 닫히는 상수 객체만 도메인 지식으로 본다.
        if not re.match(r"\s*as\s+const\b", source[close + 1 : close + 24]):
            continue
        for line in _split_members(body):
            member = _JS_MEMBER.match(line)
            if member:
                marks.add(("const", m.group(1), member.group(1), member.group(2) or ""))

    for m in _JS_TYPE_UNION.finditer(source):
        for literal in re.findall(r"['\"]([^'\"]*)['\"]", m.group(2)):
            marks.add(("union", m.group(1), literal, ""))

    for m in _PRISMA_MODEL.finditer(source):
        body, _ = _match_block(source, m.end() - 1)
        if body is None:
            continue
        mapped = _PRISMA_MAP.search(body)
        marks.add(("table", m.group(1), mapped.group(1) if mapped else None))

    return marks


def _describe_js(mark):
    kind = mark[0]
    if kind == "enum":
        return f"enum {mark[1]}.{mark[2]}" + (f" = {mark[3]}" if mark[3] else "")
    if kind == "const":
        return f"상수 {mark[1]}.{mark[2]}" + (f" = {mark[3]}" if mark[3] else "")
    if kind == "union":
        return f"union 타입 {mark[1]} 의 '{mark[2]}'"
    if kind == "table":
        return f"모델 {mark[1]} → 테이블 {mark[2]}"
    return str(mark)


def detect_js(repo, path, old_source, new_source):
    """JS/TS/Prisma 의미 변화를 전/후 지문 차집합으로 판정한다."""
    if new_source is None:
        return []
    new_marks = _js_fingerprint(new_source)
    old_marks = _js_fingerprint(old_source) if old_source is not None else set()

    changes = []
    for mark in sorted(new_marks - old_marks, key=str):
        changes.append(("추가", _describe_js(mark)))
    for mark in sorted(old_marks - new_marks, key=str):
        changes.append(("삭제", _describe_js(mark)))
    return changes


def changed_files(repo, staged, base=None):
    """판정 대상 파일 목록.

    base 가 주어지면 <base>...HEAD (머지 베이스 기준) 변경분을 본다. CI에서
    PR 전체를 한 번에 판정할 때 쓴다.
    """
    if base:
        args = ["diff", "--name-only", f"{base}...HEAD"]
    else:
        args = ["diff", "--name-only"]
        if staged:
            args.append("--cached")
    out = git(args, repo, allow_fail=True)
    if out is None:
        return []
    return [p for p in out.splitlines() if p.strip()]


def read_version(repo, path, ref):
    """특정 ref의 파일 내용. 없으면 None (신규 파일)."""
    out = git(["show", f"{ref}:{path}"], repo, allow_fail=True)
    return out


def read_staged(repo, path):
    out = git(["show", f":{path}"], repo, allow_fail=True)
    return out


def read_worktree(repo, path):
    full = os.path.join(repo, path)
    if not os.path.isfile(full):
        return None
    try:
        with open(full, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def domain_files_for(repo, path):
    """이 소스 파일의 변경을 반영해야 할 DOMAIN.md 후보 (가까운 것부터)."""
    candidates = []
    d = os.path.dirname(path)
    while True:
        cand = os.path.join(d, "DOMAIN.md") if d else "DOMAIN.md"
        if os.path.isfile(os.path.join(repo, cand)):
            candidates.append(cand)
        if not d:
            break
        d = os.path.dirname(d)
    return candidates


def _read_pair(repo, path, staged, base):
    """판정에 쓸 (변경 전, 변경 후) 소스 쌍.

    base 모드에서는 워킹트리가 아니라 HEAD 커밋 내용을 '변경 후'로 본다.
    CI는 체크아웃된 커밋을 판정하는 것이지 로컬 편집 상태를 보는 게 아니다.
    """
    if base:
        return read_version(repo, path, base), read_version(repo, path, "HEAD")
    old = read_version(repo, path, "HEAD")
    new = read_staged(repo, path) if staged else read_worktree(repo, path)
    return old, new


def analyze(repo, staged, only_file=None, base=None):
    """의미 변화가 있는 파일과 그 내용을 모은다."""
    if only_file:
        targets = [only_file]
    else:
        targets = changed_files(repo, staged, base)

    findings = {}
    for path in targets:
        if path.endswith(".py"):
            if "/migrations/" in path or path.startswith("migrations/"):
                continue
            name = os.path.basename(path)
            if (
                name.startswith("test_")
                or name.endswith("_test.py")
                or name == "conftest.py"
            ):
                continue
            old, new = _read_pair(repo, path, staged, base)
            if new is None:
                continue
            changes = detect_python(repo, path, old, new)
        elif path.endswith(JS_EXTENSIONS):
            if "__tests__" in path or ".test." in path or ".spec." in path:
                continue
            old, new = _read_pair(repo, path, staged, base)
            if new is None:
                continue
            changes = detect_js(repo, path, old, new)
        else:
            continue

        if changes:
            findings[path] = changes
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--file", help="이 파일 하나만 판정 (레포 루트 기준 상대경로)")
    parser.add_argument("--staged", action="store_true", help="스테이지된 변경을 판정")
    parser.add_argument("--base", help="이 ref 와 HEAD 를 비교 (CI에서 PR 전체 판정)")
    parser.add_argument("--repo", default=".", help="레포 루트")
    args = parser.parse_args()

    repo = git(["rev-parse", "--show-toplevel"], args.repo, allow_fail=True)
    if not repo:
        return 2
    repo = repo.strip()

    only = args.file
    if only and os.path.isabs(only):
        try:
            only = os.path.relpath(only, repo)
        except ValueError:
            return 2
    if only and (only.startswith("..") or not os.path.exists(os.path.join(repo, only))):
        return 0

    findings = analyze(repo, args.staged, only, args.base)
    if not findings:
        return 0

    # 대응 DOMAIN.md가 이미 함께 변경됐으면 통과시킨다.
    touched = set(changed_files(repo, args.staged, args.base))
    if not args.staged and not args.base:
        touched |= set(changed_files(repo, False))
    unresolved = {}
    for path, changes in findings.items():
        candidates = domain_files_for(repo, path)
        if any(c in touched for c in candidates):
            continue
        unresolved[path] = (changes, candidates)

    if not unresolved:
        return 0

    if args.base:
        label = "PR 병합 전 갱신 필요"
    elif args.staged:
        label = "커밋 차단"
    else:
        label = "DOMAIN.md 갱신 필요"
    lines = [
        "",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        f"  🚧 도메인 의미 변화 감지 — {label}",
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "",
        "코드에서 뽑을 수 없는 지식이 바뀌었습니다. codegraph는 이 영역을",
        "인덱싱하지 못하므로 DOMAIN.md에 남기지 않으면 그대로 유실됩니다.",
        "",
    ]
    for path, (changes, candidates) in sorted(unresolved.items()):
        lines.append(f"  {path}")
        for verb, desc in changes[:8]:
            lines.append(f"    [{verb}] {desc}")
        if len(changes) > 8:
            lines.append(f"    ... 외 {len(changes) - 8}건")
        target = candidates[0] if candidates else "DOMAIN.md (없음 — 생성 필요)"
        lines.append(f"    → 갱신 대상: {target}")
        lines.append("")

    lines += [
        "해야 할 일:",
        "  1. 위 항목의 **의미**를 DOMAIN.md에 적는다",
        "     (값 목록이 아니라 뜻·전이조건·부수효과)",
        "  2. 시그널이면 '무슨 부수효과를 내나' 열을 반드시 채운다",
        "  3. 변경 이력 표에 한 줄 추가",
        "",
        "스켈레톤 재생성:",
        "  python3 .claude/scripts/domain-extract.py . --app <앱경로> --format md",
        "",
    ]
    if args.staged:
        lines += [
            "이번만 넘기려면:  git commit --no-verify",
            "  (게이트 우회는 표면화 대상입니다. PR 설명에 사유를 남기세요.)",
            "",
        ]

    print("\n".join(lines), file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)
