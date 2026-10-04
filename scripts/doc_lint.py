#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""마크다운 문서의 **링크 존재**와 **시제 어휘**를 기계로 검사한다.

사용법:
    python3 scripts/doc_lint.py            # 시제 어휘(기본 검사 — 잔여 0 등급만)
    python3 scripts/doc_lint.py --links    # 링크·앵커 + 위키 인덱스
    python3 scripts/doc_lint.py --wide     # 시제 어휘 + 진단 패턴(게이트 아님)
    python3 scripts/doc_lint.py --summary  # 파일별 위반 수만(진척 측정용)

이 스크립트는 dagster-study `scripts/doc_lint.py` 를 이식한 변형판이다.
원본에서 **링크 존재 검사(`--links`)와 시제 검사(기본 검사)만** 남기고, 이
저장소에 적용 대상이 없는 축(관측 일자, 외부 볼트 참조, 줄 길이·표 셀·강조·
문서 길이 같은 가독성 4축)은 걷어냈다(YAGNI) — 이 저장소의 문서는 아직
그 축이 문제가 된 적이 없고, 쓰이지 않을 규칙을 미리 넣지 않는다.

검사에서 빼는 것(빠뜨린 것과 구분하기 위해 명시한다):
    - 펜스 코드 블록(``` … ```) 안 — 명령·설정 원문은 줄여 쓸 수 없다.
    - URL만 있는 줄.

이 스크립트가 다루지 않는 것:
    - 관측·결정 일자 표기, 외부 볼트 참조, 줄 길이·표 셀·강조·문서 길이
      (이식 원본에는 있었으나 이 저장소에는 대상이 없어 제거했다).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# 시제 어휘 — 진행 상태를 말하는 낱말은 문서에 두지 않는다. 날짜 없이도
# 저절로 낡는 "아직 ~없다" 류를 잡는다(날짜 축과는 다른 함정).
#   🔴 **한글 어휘에는 경계(`\b`)를 두르지 마라 — 두르면 조사·어미에서 샌다.**
#      파이썬 `\b`는 유니코드 워드 문자 기준이라 한글 조사 앞에서 서지 않는다.
#      `\b아직까지\b`는 "아직까지 안 했다"는 잡지만 "아직까지는"·"아직까지의"를
#      놓친다 — 그래서 여기 `\b`가 없는 것은 빠뜨린 것이 아니라 결정이다.
#   🔴 영문(TODO/TBD/FIXME)은 **ASCII 문자로만** 경계를 세운다 — `_`도 경계가
#      아니다(`TODO_LIST` 같은 식별자가 잡혀야 한다). 숫자는 경계에서 빼지
#      않는다(`TODO2`는 TODO의 변형이다).
# 잔여 0건 등급 — 기본 검사(유입 게이트)로 쓴다.
TENSE_STRICT_RES = (
    re.compile(r"(?<![A-Za-z])(TODO|TBD|FIXME)(?![A-Za-z])"),
    re.compile(r"아직까지|지금까지"),
    re.compile(r"예정이다|할 예정|될 예정"),
)

# 잔여가 있을 수 있는 넓은 패턴 — `--tense --wide` 로만 돈다(진단 모드,
# 커밋 게이트가 아니다). 규칙 문서가 위반 예시를 인용하는 자리와 부딪히므로
# 그때는 아래 TENSE_OPT_OUT 마커로 그 줄만 면제한다.
TENSE_DIAGNOSTIC_RES = (
    re.compile(r"아직[^.。\n]{0,20}?(없다|없고|없으|않다|않고|않으|못한다|못했|안 )"),
    re.compile(r"미해소"),
    re.compile(r"이번에"),
)

# 이 마커는 **면제이지 검증이 아니다** — 붙이면 그 줄은 아무도 안 본다.
# 진짜 상태 서술에 붙이면 조용히 통과하므로, 인용·예시에만 쓴다.
TENSE_OPT_OUT = "<!-- tense-ok -->"

# 기본 검사(시제) 대상 — 사람과 AI가 함께 읽는 문서만.
#   🔴 `wiki/`는 **저장소 밖으로 나가는 원본**이라 반드시 포함한다. 미러는
#      단방향이라 낡은 문장이 나가면 저장소 쪽에서 더 막을 곳이 없다.
DEFAULT_TARGETS = ("AGENTS.md", "CLAUDE.md", "README.md", "docs", "wiki")

# 링크 검사는 저장소 전역 1회로 돈다 — 모집단을 분업하면 경계에 사각이 생긴다.
LINK_SCAN_DIRS = ("docs", "wiki")
LINK_SCAN_FILES = ("README.md", "AGENTS.md", "CLAUDE.md")

# 위키 인덱스 — `check_links`의 반대 방향("노트를 추가하고 인덱스에 안 적는
# 것")을 본다. 둘 다 본다: `Home.md`는 진입 페이지, `_Sidebar.md`는 상시
# 내비게이션이라 도달 경로가 서로 다르다.
WIKI_INDEX_FILES = ("Home.md", "_Sidebar.md")

# 인덱스에서 등재된 노트 이름을 뽑는 패턴 — `wiki_linkify.py`가 변환하는
# 대상과 같은 형태다(원본은 `.md`를 붙여 쓰고, 미러 단계에서 접미어만 뗀다).
WIKI_LINK_RE = re.compile(r"\]\((?!https?://|mailto:|#)([^)\s#]+\.md)(?:#[^)\s]*)?\)")

EXCLUDE_PARTS = (".venv", "node_modules")

FENCE_RE = re.compile(r"^\s*(```|~~~)")

# 링크는 표시 텍스트만 남기고 접는다 — URL 안의 `TODO` 같은 경로는 문장이
# 아니고, 긴 주소가 섞인 줄을 잘못 읽지 않기 위함이다.
LINK_TEXT_RE = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")


def heading_slug(text: str) -> str:
    """제목을 GitHub 앵커 슬러그로 바꾼다.

    구두점이 제거되면 그 자리의 공백은 합쳐지지 않고 각각 하이픈이 된다.
    이 규칙을 틀리면 정상 링크를 위반으로 잡아 "고치다가" 실제로 깨뜨린다.
    """
    text = re.sub(r"[`*\[\]()]", "", text).strip().lower()
    text = "".join(c for c in text if c.isalnum() or c.isspace() or c in "-_")
    return re.sub(r"\s", "-", text)


def collect(targets: list[str], repo_root: Path) -> list[Path]:
    """대상 열거를 파일 목록으로 편다 — 디렉터리는 재귀, 제외 경로는 걸러낸다."""
    files: list[Path] = []
    for target in targets:
        path = repo_root / target
        if path.is_dir():
            files.extend(sorted(path.rglob("*.md")))
        elif path.is_file():
            files.append(path)
    return [f for f in files if not any(part in f.parts for part in EXCLUDE_PARTS)]


def check_links(repo_root: Path) -> list[str]:
    """저장소 전역의 상대 링크와 앵커가 실재하는지 본다.

    ⚠️ **다루지 않는 것** — 인라인 마크다운 링크(`[텍스트](경로)`)만 본다.
    참조형 링크(`[x]: url`)와 HTML `<a href>`는 인식하지 못한다. 위키 원본
    규약이 애초에 이 두 형태를 쓰지 않기로 했으므로(`scripts/wiki_linkify.py`
    머리 주석과 같은 전제) 비대칭 구멍은 아니지만, **그 규약 자체를 어겨도
    이 검사는 못 잡는다** — 빠뜨린 것이 아니라 관측 범위 밖임을 명시해 둔다.
    """
    targets: list[Path] = [repo_root / f for f in LINK_SCAN_FILES]
    for d in LINK_SCAN_DIRS:
        targets.extend(sorted((repo_root / d).rglob("*.md")))
    docs = [
        f
        for f in targets
        if f.is_file() and not any(p in f.parts for p in EXCLUDE_PARTS)
    ]

    slugs: dict[Path, set[str]] = {}
    for f in docs:
        body = f.read_text(encoding="utf-8")
        slugs[f] = {
            heading_slug(m.group(2))
            for m in re.finditer(r"^(#{1,6})\s+(.*)$", body, re.MULTILINE)
        }

    findings: list[str] = []
    for f in docs:
        rel = f.relative_to(repo_root)
        # 펜스 코드 블록은 제외한다 — 코드의 제네릭·슬라이스가 링크로 오인된다.
        prose_lines, in_fence = [], False
        for line in f.read_text(encoding="utf-8").splitlines():
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if not in_fence:
                prose_lines.append(line)
        prose = "\n".join(prose_lines)
        link_re = r"\]\((?!https?:|mailto:)([^)#]*)(?:#([^)]+))?\)"
        for m in re.finditer(link_re, prose):
            path_part, anchor = m.group(1), m.group(2)
            target = (f.parent / path_part).resolve() if path_part else f.resolve()
            if path_part and not target.exists():
                findings.append(f"{rel}: dead-link {path_part} — 대상 파일이 없다")
                continue
            if anchor and target in slugs and anchor not in slugs[target]:
                findings.append(
                    f"{rel}: dead-anchor {path_part}#{anchor} — 그런 절이 없다"
                )
    return findings


def check_wiki_flat(wiki_dir: Path) -> list[str]:
    """`wiki/` 하위에 **디렉터리로 묻힌** `.md` 파일이 있는지 본다.

    위키 규약은 평평 구조를 요구한다(위키에 계층 사이드바가 없다). 그런데
    그 규약은 지금까지 문서에만 적혀 있었고 기계가 재지 않았다 — 그래서
    누군가 `wiki/sub/note.md`를 만들어도 **아무것도 못 잡는다**:
    `check_wiki_index`의 `glob("*.md")`는 평면 글롭이라 애초에 그 파일을
    모집단에 넣지 않고(= "unindexed"조차 못 뜬다), `.github/workflows/wiki.yml`의
    `cp wiki/*.md`도 비재귀라 조용히 복사하지 않는다. pre-commit·CI·미러
    워크플로가 **전부 초록불**인 채로 그 노트는 영원히 위키에 배달되지
    않는다 — 증상이 없는 침묵 실패다.

    이 검사가 그 사각을 메운다. `wiki_dir.rglob("*.md")`로 **재귀**해
    `wiki_dir` 바로 아래가 아닌 파일을 모두 위반으로 잡는다 — `check_wiki_index`
    가 평면 글롭을 쓰는 것과 **의도적으로 반대**다(한쪽은 "평평함을 전제하고
    그 전제 안에서 본다", 이쪽은 "그 전제 자체가 깨졌는지를 본다").
    """
    if not wiki_dir.is_dir():
        return []
    return [
        f"wiki/{f.relative_to(wiki_dir)}: nested-file — wiki/ 는 평평해야 한다"
        " (위키에 계층 사이드바가 없고, 미러의 cp wiki/*.md 는 비재귀라"
        " 하위 디렉터리 파일은 배달되지 않는다)"
        for f in sorted(wiki_dir.rglob("*.md"))
        if f.parent != wiki_dir
    ]


def check_wiki_index(wiki_dir: Path) -> tuple[list[str], int] | None:
    """위키 노트가 인덱스 두 곳(`Home.md`·`_Sidebar.md`)에 모두 등재됐는지 본다.

    `check_links`의 역방향이다 — 링크가 아예 없으면 깨질 링크도 없어서
    "노트를 추가하고 인덱스에 안 적는 것"은 `check_links`가 못 본다.

    반환은 `(위반 목록, 모집단 크기)`다. `wiki/`가 없으면 `None`을 돌려
    건너뛴다 — 호출부는 이 `None`을 `0건`이 아니라 "검사 안 함"으로
    출력해야 한다(안 본 것과 통과한 것은 다른 상태다).

    ⚠️ 글롭은 평면이다(`rglob`이 아니다) — 위키 규약이 `wiki/` 하위
    디렉터리를 금지한다(위키에 계층 사이드바가 없다).
    """
    if not wiki_dir.is_dir():
        return None

    notes = [f for f in sorted(wiki_dir.glob("*.md")) if f.name not in WIKI_INDEX_FILES]

    findings: list[str] = []
    linked: dict[str, set[str]] = {}
    for index_name in WIKI_INDEX_FILES:
        index_path = wiki_dir / index_name
        if not index_path.is_file():
            findings.append(f"wiki/{index_name}: missing-index — 인덱스 파일이 없다")
            continue
        # 펜스 안은 링크로 세지 않는다 — check_links 와 같은 규율이다.
        prose, in_fence = [], False
        for line in index_path.read_text(encoding="utf-8").splitlines():
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if not in_fence:
                prose.append(line)
        # 경로가 붙어 있어도(`./x.md`) 파일명으로 정규화해 비교한다.
        linked[index_name] = {
            Path(m.group(1)).name for m in WIKI_LINK_RE.finditer("\n".join(prose))
        }

    # 인덱스 자체가 없으면 그것이 유일한 실행 가능한 결함이다.
    #   노트별 미등재를 함께 쏟으면 진짜 할 일이 N건 밑에 묻힌다.
    if findings:
        return findings, len(notes)

    for note in notes:
        missing = [name for name in WIKI_INDEX_FILES if note.name not in linked[name]]
        if missing:
            findings.append(
                f"wiki/{note.name}: unindexed — {' · '.join(missing)}에 링크가 없다"
            )
    return findings, len(notes)


def check_tense(files: list[Path], repo_root: Path, wide: bool = False) -> list[str]:
    """문서 본문에 진행 상태를 말하는 시제 어휘가 남아 있는지 본다.

    `wide`가 거짓이면 잔여 0인 패턴만(기본 검사·유입 게이트),
    참이면 진단 패턴까지 함께 본다(`--tense --wide`).

    펜스 코드 블록·프론트매터 안은 제외한다. 링크는 표시 텍스트만 본다.
    🔴 이 검사가 0건이어도 "낡는 문장이 없다"는 뜻이 아니다 — 어휘를 쓰지
    않고 쓴 상태 서술은 관측 범위 밖이다.
    """
    patterns = TENSE_STRICT_RES if not wide else TENSE_STRICT_RES + TENSE_DIAGNOSTIC_RES
    findings: list[str] = []
    for path in files:
        rel = path.relative_to(repo_root) if path.is_relative_to(repo_root) else path

        in_fence = False
        in_frontmatter = False
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if lineno == 1 and line.strip() == "---":
                in_frontmatter = True
                continue
            if in_frontmatter:
                if line.strip() == "---":
                    in_frontmatter = False
                continue
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence or TENSE_OPT_OUT in line:
                continue
            # 링크는 표시 텍스트만 본다 — URL 안의 TODO 같은 경로는 문장이 아니다.
            prose = LINK_TEXT_RE.sub(r"\1", line)
            findings.extend(
                f"{rel}:{lineno}: tense-word {m.group(0)} — 상태는 Issue로"
                for pattern in patterns
                for m in pattern.finditer(prose)
            )
    return findings


def main() -> int:
    """대상 문서를 훑어 링크·시제 위반을 출력하고, 위반이 있으면 종료코드 1을 낸다.

    🔴 **기본 검사(플래그 없음)는 시제 어휘다.** 이 변형판에는 가독성 4축이
    없어 "기본 검사"가 비어 있을 자리가 없다 — `doc-lint` 훅은 이 기본
    경로를 그대로 쓴다(`entry: python3 scripts/doc_lint.py`).
    """
    parser = argparse.ArgumentParser(description="마크다운 링크·시제 검사")
    parser.add_argument(
        "paths", nargs="*", help="검사할 파일/디렉터리 (기본: 저장소 문서 전체)"
    )
    parser.add_argument(
        "--links",
        action="store_true",
        help="저장소 전역 링크·앵커 + 위키 인덱스만 검사",
    )
    parser.add_argument(
        "--wide",
        action="store_true",
        help="시제 어휘에 진단 패턴까지 포함(게이트 아님)",
    )
    parser.add_argument("--summary", action="store_true", help="파일별 위반 수만 출력")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent

    if args.links:
        link_findings = check_links(repo_root)
        for finding in link_findings:
            print(finding)
        print(f"\n링크 위반 {len(link_findings)}건", file=sys.stderr)

        index_result = check_wiki_index(repo_root / "wiki")
        if index_result is None:
            # 🔴 여기도 "0건"이 아니다 — 안 본 것과 통과한 것은 다른 상태다.
            print("위키 인덱스: 검사 안 함 (wiki/ 없음)", file=sys.stderr)
            index_findings: list[str] = []
        else:
            index_findings, note_count = index_result
            for finding in index_findings:
                print(finding)
            print(
                f"위키 인덱스 미등재 {len(index_findings)}건 / 노트 {note_count}개",
                file=sys.stderr,
            )

        # 위키 평평 구조 강제 — check_wiki_flat 머리 주석 참고. check_wiki_index
        # 와 같은 자리(--links)에서 돈다 — 둘 다 "wiki/ 구조가 규약과 맞는가"
        # 축이고, 모집단이 항상 wiki/ 전체여야 하는 것도 같다(always_run 훅).
        flat_findings = check_wiki_flat(repo_root / "wiki")
        for finding in flat_findings:
            print(finding)
        print(f"위키 평평 구조 위반 {len(flat_findings)}건", file=sys.stderr)

        return 1 if link_findings or index_findings or flat_findings else 0

    # 기본 검사(플래그 없음) — 시제 어휘. 경로 생략 시 DEFAULT_TARGETS 전체를 본다.
    files = collect(list(args.paths) or list(DEFAULT_TARGETS), repo_root)
    if not files:
        print("검사 대상 없음", file=sys.stderr)
        return 2
    tense_findings = check_tense(files, repo_root, wide=args.wide)
    if not args.summary:
        for finding in tense_findings:
            print(finding)
    else:
        counts: dict[str, int] = {}
        for finding in tense_findings:
            key = finding.split(":")[0]
            counts[key] = counts.get(key, 0) + 1
        for rel, count in sorted(counts.items(), key=lambda item: -item[1]):
            print(f"{count:5d}  {rel}")
    print(f"\n시제 어휘 {len(tense_findings)}건 / 문서 {len(files)}개", file=sys.stderr)
    return 1 if tense_findings else 0


if __name__ == "__main__":
    sys.exit(main())
