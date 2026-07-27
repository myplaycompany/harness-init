#!/usr/bin/env python3
"""도메인 의미 지식 추출기.

codegraph가 인덱싱하지 못하는 것만 뽑는다. 실측(plab pf-server-django, 2026-07-27)에서
codegraph는 아래를 전부 놓쳤다:

  - Django 모델 필드 선언(ForeignKey/OneToOne/CharField) → 심볼로 취급 안 함 (0건)
  - db_table 문자열 리터럴 → FTS 검색 불가 (0건)
  - @receiver(post_save, sender=X) 시그널 배선 → 호출 그래프에 엣지 없음 (0건)

이 셋이 곧 "사람이 문서로 남겨야 하는 것"의 경계다. 값 목록은 여기서 기계 추출하고,
그 값이 무슨 뜻인지(의미)만 사람/에이전트가 채운다.

추출은 LLM 추론이 아니라 stdlib `ast` 파싱이다. 환각이 없고 비용이 0이다.

사용법:
    python3 domain-extract.py <target_dir> [--app <app_dir>] [--format json|md]
"""

import argparse
import ast
import json
import os
import sys

SKIP_DIRS = {
    ".git",
    ".venv",
    "venv",
    "env",
    "__pycache__",
    "node_modules",
    "migrations",
    ".worktrees",
    ".claude",
    ".codegraph",
    "site-packages",
    "build",
    "dist",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
}

CHOICE_BASES = {"TextChoices", "IntegerChoices", "Choices"}
ENUM_BASES = {"Enum", "IntEnum", "StrEnum", "IntFlag", "Flag"}
SIGNAL_NAMES = {
    "post_save",
    "pre_save",
    "post_delete",
    "pre_delete",
    "m2m_changed",
    "post_init",
    "pre_init",
    "post_migrate",
    "pre_migrate",
}


def _base_names(node):
    """클래스 base 이름을 짧은 이름 집합으로 반환 (models.TextChoices → TextChoices)."""
    names = set()
    for b in node.bases:
        if isinstance(b, ast.Name):
            names.add(b.id)
        elif isinstance(b, ast.Attribute):
            names.add(b.attr)
    return names


def _const(node):
    """상수 노드에서 파이썬 값을 꺼낸다. 상수가 아니면 None."""
    if isinstance(node, ast.Constant):
        return node.value
    return None


def _dotted(node):
    """Name/Attribute를 점 표기 문자열로. 그 외에는 None."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        prefix = _dotted(node.value)
        return f"{prefix}.{node.attr}" if prefix else node.attr
    return None


def _extract_choice_members(cls):
    """Choices/Enum 클래스 본문에서 (멤버명, 값, 라벨) 목록을 뽑는다.

    Django TextChoices는 `OPEN = "open", "모집중"` 형태로 값과 라벨을 튜플로 쓴다.
    순수 Enum은 `OPEN = "open"` 만 있다.
    """
    members = []
    for stmt in cls.body:
        if not isinstance(stmt, ast.Assign) or len(stmt.targets) != 1:
            continue
        target = stmt.targets[0]
        if not isinstance(target, ast.Name) or target.id.startswith("_"):
            continue
        value, label = None, None
        if isinstance(stmt.value, ast.Tuple) and stmt.value.elts:
            value = _const(stmt.value.elts[0])
            if len(stmt.value.elts) > 1:
                label = _const(stmt.value.elts[1])
        else:
            value = _const(stmt.value)
        if value is None and label is None:
            continue
        members.append({"name": target.id, "value": value, "label": label})
    return members


def _extract_inline_choices(node):
    """`STATUS_CHOICES = (("a", "A"), ...)` 형태의 모듈/클래스 레벨 튜플 상수."""
    if not isinstance(node, ast.Assign) or len(node.targets) != 1:
        return None
    target = node.targets[0]
    if not isinstance(target, ast.Name) or "CHOICE" not in target.id.upper():
        return None
    if not isinstance(node.value, (ast.Tuple, ast.List)):
        return None
    members = []
    for elt in node.value.elts:
        if isinstance(elt, (ast.Tuple, ast.List)) and len(elt.elts) >= 2:
            value, label = _const(elt.elts[0]), _const(elt.elts[1])
            if value is not None:
                members.append({"name": None, "value": value, "label": label})
    if not members:
        return None
    return {"name": target.id, "kind": "tuple", "line": node.lineno, "members": members}


def _extract_db_table(cls):
    """모델 클래스의 Meta.db_table 값. 없으면 None."""
    for stmt in cls.body:
        if isinstance(stmt, ast.ClassDef) and stmt.name == "Meta":
            for meta_stmt in stmt.body:
                if isinstance(meta_stmt, ast.Assign) and len(meta_stmt.targets) == 1:
                    t = meta_stmt.targets[0]
                    if isinstance(t, ast.Name) and t.id == "db_table":
                        return _const(meta_stmt.value)
    return None


def _is_model(cls):
    """Django 모델로 볼 수 있는 클래스인지."""
    return bool(_base_names(cls) & {"Model", "AbstractUser", "AbstractBaseUser"})


def _extract_receiver(node):
    """@receiver(post_save, sender=X) 데코레이터가 붙은 함수 정보."""
    for deco in node.decorator_list:
        if not isinstance(deco, ast.Call):
            continue
        if _dotted(deco.func) not in ("receiver", "django.dispatch.receiver"):
            continue
        signal = _dotted(deco.args[0]) if deco.args else None
        sender = None
        for kw in deco.keywords:
            if kw.arg == "sender":
                sender = _dotted(kw.value) or _const(kw.value)
        return {
            "handler": node.name,
            "signal": signal,
            "sender": sender,
            "line": node.lineno,
            "style": "decorator",
        }
    return None


def _extract_connect(node):
    """post_save.connect(handler, sender=X) 형태의 명시적 배선."""
    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
        return None
    if node.func.attr != "connect":
        return None
    signal_path = _dotted(node.func.value)
    if not signal_path or signal_path.split(".")[-1] not in SIGNAL_NAMES:
        return None
    handler = _dotted(node.args[0]) if node.args else None
    sender = None
    for kw in node.keywords:
        if kw.arg == "sender":
            sender = _dotted(kw.value) or _const(kw.value)
    return {
        "handler": handler,
        "signal": signal_path.split(".")[-1],
        "sender": sender,
        "line": node.lineno,
        "style": "connect",
    }


def parse_file(path, rel_path):
    """한 파일에서 models / choices / signals 를 추출한다."""
    try:
        with open(path, encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=path)
    except (SyntaxError, UnicodeDecodeError, OSError) as exc:
        return None, f"{rel_path}: {type(exc).__name__}"

    models, choices, signals = [], [], []

    def visit_class(cls, owner=None):
        bases = _base_names(cls)
        if bases & CHOICE_BASES or bases & ENUM_BASES:
            members = _extract_choice_members(cls)
            if members:
                choices.append(
                    {
                        "owner": owner,
                        "name": cls.name,
                        "kind": next(iter(bases & (CHOICE_BASES | ENUM_BASES))),
                        "file": rel_path,
                        "line": cls.lineno,
                        "members": members,
                    }
                )
            return
        if _is_model(cls):
            models.append(
                {
                    "name": cls.name,
                    "db_table": _extract_db_table(cls),
                    "file": rel_path,
                    "line": cls.lineno,
                }
            )
        for stmt in cls.body:
            if isinstance(stmt, ast.ClassDef):
                visit_class(stmt, owner=cls.name)
            else:
                inline = _extract_inline_choices(stmt)
                if inline:
                    inline.update({"owner": cls.name, "file": rel_path})
                    choices.append(inline)

    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            visit_class(node)
        else:
            inline = _extract_inline_choices(node)
            if inline:
                inline.update({"owner": None, "file": rel_path})
                choices.append(inline)

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            rec = _extract_receiver(node)
            if rec:
                rec["file"] = rel_path
                signals.append(rec)
        elif isinstance(node, ast.Call):
            conn = _extract_connect(node)
            if conn and conn["handler"]:
                conn["file"] = rel_path
                signals.append(conn)

    return {"models": models, "choices": choices, "signals": signals}, None


def iter_python_files(root):
    """스킵 대상 디렉토리와 테스트 파일을 제외한 .py 경로를 순회한다."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")
        ]
        for name in filenames:
            if not name.endswith(".py"):
                continue
            if (
                name.startswith("test_")
                or name.endswith("_test.py")
                or name == "conftest.py"
            ):
                continue
            full = os.path.join(dirpath, name)
            yield full, os.path.relpath(full, root)


def collect(root, app=None):
    """루트(또는 특정 앱) 아래를 훑어 앱 단위로 묶은 추출 결과를 만든다."""
    scan_root = os.path.join(root, app) if app else root
    apps, errors = {}, []

    for full, _ in iter_python_files(scan_root):
        rel_to_root = os.path.relpath(full, root)
        result, err = parse_file(full, rel_to_root)
        if err:
            errors.append(err)
            continue
        if not (result["models"] or result["choices"] or result["signals"]):
            continue
        app_key = os.path.dirname(rel_to_root) or "."
        bucket = apps.setdefault(app_key, {"models": [], "choices": [], "signals": []})
        for key in ("models", "choices", "signals"):
            bucket[key].extend(result[key])

    return {"root": os.path.abspath(root), "apps": apps, "errors": errors}


def _fmt_value(v):
    return "—" if v is None else f"`{v}`"


def render_markdown(data, app_key=None):
    """DOMAIN.md 의 '기계 추출' 블록으로 쓸 마크다운을 만든다.

    값과 위치는 기계가 채우고, '의미' 열은 TODO로 남긴다. 그 열이 사람이 채워야 할
    유일한 부분이고, codegraph가 절대 답할 수 없는 부분이다.
    """
    keys = [app_key] if app_key else sorted(data["apps"])
    out = []

    for key in keys:
        payload = data["apps"].get(key)
        if not payload:
            continue
        if not app_key:
            out.append(f"### {key}\n")

        if payload["models"]:
            out.append("#### 모델 → 테이블 매핑\n")
            out.append("> `Meta.db_table`로 Django 기본 명명을 덮어쓴 경우가 있다.")
            out.append("> Raw SQL 작성 시 이 표의 실제 테이블명을 쓴다.\n")
            out.append("| 모델 | 실제 테이블 | 위치 |")
            out.append("|------|------------|------|")
            for m in sorted(payload["models"], key=lambda x: x["name"]):
                table = m["db_table"] or "(Django 기본값)"
                out.append(f"| `{m['name']}` | `{table}` | `{m['file']}:{m['line']}` |")
            out.append("")

        if payload["choices"]:
            out.append("#### 상태값 / Choices\n")
            out.append("> 값은 코드에서 추출했다.")
            out.append("> **의미** 열은 코드로 알 수 없으니 직접 채운다.\n")
            for c in payload["choices"]:
                owner = f"{c['owner']}." if c.get("owner") else ""
                where = f"{c['file']}:{c['line']}"
                out.append(f"##### `{owner}{c['name']}` ({c['kind']}) — `{where}`\n")
                out.append("| 멤버 | 값 | 라벨 | 의미 / 전이 조건 |")
                out.append("|------|-----|------|-----------------|")
                for m in c["members"]:
                    # 튜플형 choices 는 멤버 이름이 없다. 값 자체가 식별자 역할을 한다.
                    name = f"`{m['name']}`" if m["name"] else "—"
                    label = m["label"] if m["label"] else "—"
                    out.append(
                        f"| {name} | {_fmt_value(m['value'])} | {label} | TODO |"
                    )
                out.append("")

        if payload["signals"]:
            out.append("#### 시그널 부수효과\n")
            out.append("> **codegraph가 추적하지 못하는 영역이다.**")
            out.append("> (실측 확인: 호출 그래프에 엣지 없음)")
            out.append("> 모델을 save() 하면 여기 적힌 핸들러가 함께 실행된다.")
            out.append("> 무엇을 바꾸는지 직접 적는다.\n")
            out.append("| 발신 모델 | 시그널 | 핸들러 | 위치 | 무슨 부수효과를 내나 |")
            out.append("|----------|--------|--------|------|--------------------|")
            for s in sorted(
                payload["signals"], key=lambda x: (x.get("sender") or "", x["line"])
            ):
                sender = f"`{s['sender']}`" if s["sender"] else "(전체)"
                handler = f"`{s['handler']}`" if s["handler"] else "—"
                where = f"{s['file']}:{s['line']}"
                out.append(
                    f"| {sender} | `{s['signal']}` | {handler} | `{where}` | TODO |"
                )
            out.append("")

    return "\n".join(out)


APP_SKELETON_HEADER = """# {title} 도메인

> **이 문서는 의미(semantics) 전용이다.** 코드에서 읽어낼 수 있는 것 — 심볼 위치,
> 호출 경로, 영향 범위, 어떤 함수가 무엇을 부르는지 — 은 여기 적지 않는다.
> 그건 codegraph가 항상 최신으로 답한다: `codegraph explore "<질문>"`
>
> 여기에는 **코드를 읽어도 알 수 없는 것**만 적는다. 상태값이 무슨 뜻인지,
> 어떤 조건에서 전이하는지, 시그널이 무슨 부수효과를 내는지, 왜 이렇게 되어 있는지.

## 한 줄 요약

TODO: 이 도메인이 무엇을 책임지는가

## 비즈니스 규칙

> 코드에 흩어져 있어 한눈에 안 보이는 규칙, 예외, 정책을 적는다.

- TODO

## 변경 시 주의사항

> 이 도메인을 건드릴 때 밟기 쉬운 지뢰. 과거에 사고가 났던 지점을 남긴다.

- TODO

"""

APP_SKELETON_FOOTER = """
## 변경 이력

| 날짜 | 변경 내용 |
|-----|----------|
| {today} | DOMAIN.md 초기 생성 |
"""


def render_skeleton(data, app_key, title=None, today="TODO"):
    """앱 단위 DOMAIN.md 전체 문서를 만든다 (의미 템플릿 + 기계 추출 표)."""
    header = APP_SKELETON_HEADER.format(
        title=title or os.path.basename(app_key.rstrip("/"))
    )
    body = render_markdown(data, app_key)
    footer = APP_SKELETON_FOOTER.format(today=today)
    return header + body + footer


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("target", nargs="?", default=".", help="프로젝트 루트")
    parser.add_argument("--app", help="특정 앱 디렉토리만 (루트 기준 상대경로)")
    parser.add_argument(
        "--format",
        choices=["json", "md", "skeleton"],
        default="json",
        help="json=원자료, md=추출 표만, skeleton=앱 DOMAIN.md 전체 문서",
    )
    parser.add_argument("--today", default="", help="skeleton 변경이력에 넣을 날짜")
    parser.add_argument(
        "--quiet", action="store_true", help="파싱 실패를 stderr에 알리지 않음"
    )
    args = parser.parse_args()

    if not os.path.isdir(args.target):
        print(f"domain-extract: 디렉토리가 아닙니다: {args.target}", file=sys.stderr)
        return 1

    data = collect(args.target, args.app)

    if data["errors"] and not args.quiet:
        print(
            f"domain-extract: {len(data['errors'])}개 파일 파싱 실패", file=sys.stderr
        )
        for e in data["errors"][:5]:
            print(f"  - {e}", file=sys.stderr)

    if args.format == "json":
        json.dump(data, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    elif args.format == "skeleton":
        if not args.app:
            print(
                "domain-extract: --format skeleton 은 --app 이 필요합니다",
                file=sys.stderr,
            )
            return 1
        sys.stdout.write(render_skeleton(data, args.app, today=args.today or "TODO"))
    else:
        sys.stdout.write(render_markdown(data, args.app))

    return 0


if __name__ == "__main__":
    sys.exit(main())
