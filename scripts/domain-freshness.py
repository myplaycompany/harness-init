#!/usr/bin/env python3
"""DOMAIN.md 신선도 리포트.

문서가 낡는 건 조용히 일어난다. plab 실측(2026-07-27):

    web/order/DOMAIN.md     2026-02-02   ← 5개월 정지
    web/order/models.py     2026-07-03
    web/accounts/DOMAIN.md  2026-02-02
    web/match/DOMAIN.md     19 커밋  vs  web/match/models.py 866 커밋

에이전트는 문서가 낡았다는 걸 모른 채 그 내용을 근거로 코드를 짠다. 그래서
세션 시작 시점에 "이 앱 문서는 소스보다 N일 뒤처졌다"를 컨텍스트로 밀어넣는다.
낡았다는 사실 자체가 가드레일이다.

사용법: python3 domain-freshness.py [repo] [--stale-days N] [--format text|json]
"""

import argparse
import json
import os
import subprocess
import sys

SKIP_PARTS = {
    ".git",
    ".venv",
    "venv",
    "env",
    "node_modules",
    "__pycache__",
    ".worktrees",
    "worktrees",
    ".codegraph",
    "site-packages",
}
SOURCE_EXTENSIONS = (".py", ".ts", ".tsx", ".js", ".jsx")


def git(args, cwd):
    try:
        out = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def last_commit_ts(repo, paths):
    """주어진 경로들을 건드린 마지막 커밋의 unix timestamp.

    경로를 한꺼번에 pathspec으로 넘겨 git 호출을 1회로 묶는다. 파일마다 호출하면
    앱 하나에 수십 회가 되어 SessionStart 훅 예산(수 초)을 넘긴다.
    """
    if isinstance(paths, str):
        paths = [paths]
    if not paths:
        return None
    out = git(["log", "-1", "--format=%ct", "--"] + list(paths), repo)
    if not out:
        return None
    try:
        return int(out.splitlines()[0])
    except (ValueError, IndexError):
        return None


def commit_count(repo, paths):
    """주어진 경로 중 하나라도 건드린 커밋 수 (합계가 아니라 합집합)."""
    if isinstance(paths, str):
        paths = [paths]
    if not paths:
        return 0
    out = git(["rev-list", "--count", "HEAD", "--"] + list(paths), repo)
    try:
        return int(out) if out else 0
    except ValueError:
        return 0


def find_domain_files(repo):
    found = []
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [
            d for d in dirnames if d not in SKIP_PARTS and not d.startswith(".")
        ]
        if "DOMAIN.md" in filenames:
            found.append(os.path.relpath(os.path.join(dirpath, "DOMAIN.md"), repo))
    return sorted(found)


def source_files_in(repo, directory):
    """DOMAIN.md와 같은 디렉토리의 소스 파일 (하위 디렉토리 제외, 테스트 제외)."""
    full = os.path.join(repo, directory) if directory else repo
    out = []
    try:
        entries = os.listdir(full)
    except OSError:
        return out
    for name in entries:
        if not name.endswith(SOURCE_EXTENSIONS):
            continue
        if (
            name.startswith("test_")
            or name.endswith("_test.py")
            or name == "conftest.py"
        ):
            continue
        out.append(os.path.join(directory, name) if directory else name)
    return out


def analyze(repo, stale_days):
    report = []
    for domain_path in find_domain_files(repo):
        directory = os.path.dirname(domain_path)
        sources = source_files_in(repo, directory)
        if not sources:
            continue

        doc_ts = last_commit_ts(repo, domain_path)
        src_ts = last_commit_ts(repo, sources)
        if not doc_ts or not src_ts:
            continue

        lag_days = max(0, (src_ts - doc_ts) // 86400)
        doc_commits = commit_count(repo, domain_path)
        src_commits = commit_count(repo, sources)

        report.append(
            {
                "domain": domain_path,
                "lag_days": lag_days,
                "doc_commits": doc_commits,
                "src_commits": src_commits,
                "stale": lag_days >= stale_days,
            }
        )

    report.sort(key=lambda r: -r["lag_days"])
    return report


def render_text(report, stale_days, limit):
    stale = [r for r in report if r["stale"]]
    if not stale:
        if not report:
            return ""
        return f"도메인 문서 {len(report)}건 모두 최신 ({stale_days}일 이내)."

    lines = [
        f"⚠ DOMAIN.md {len(stale)}건이 소스보다 뒤처져 있습니다 (기준 {stale_days}일).",
        "  아래 문서는 현재 코드와 다를 수 있습니다.",
        "  근거로 삼기 전에 코드로 교차 확인하세요.",
        "",
    ]
    for r in stale[:limit]:
        ratio = ""
        if r["src_commits"]:
            pct = 100.0 * r["doc_commits"] / r["src_commits"]
            ratio = f", 갱신율 {r['doc_commits']}/{r['src_commits']}커밋 ({pct:.0f}%)"
        lines.append(f"  · {r['domain']} — {r['lag_days']}일 뒤처짐{ratio}")
    if len(stale) > limit:
        lines.append(f"  · ... 외 {len(stale) - limit}건")
    lines.append("")
    lines.append(
        "  작업 대상 앱의 문서가 위 목록에 있으면, 그 앱을 건드릴 때 함께 갱신하세요."
    )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("repo", nargs="?", default=".")
    parser.add_argument("--stale-days", type=int, default=30)
    parser.add_argument("--limit", type=int, default=8, help="텍스트 출력 시 나열 개수")
    parser.add_argument("--format", choices=["text", "json"], default="text")
    args = parser.parse_args()

    repo = git(["rev-parse", "--show-toplevel"], args.repo)
    if not repo:
        return 0
    repo = repo.strip()

    report = analyze(repo, args.stale_days)

    if args.format == "json":
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    else:
        text = render_text(report, args.stale_days, args.limit)
        if text:
            print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
