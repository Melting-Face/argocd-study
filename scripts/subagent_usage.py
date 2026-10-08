#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Claude Code 세션 기록에서 메인 세션·서브에이전트의 턴과 토큰을 집계한다.

사용법:
    python3 scripts/subagent_usage.py [--since T] [--until T] [--session ID ...]
                                      [--tools] [--json] [--project-dir DIR]

규칙 정본은 docs/conventions/agents.md §4 이다. 요지:
    - 판정은 **메인 세션 + 서브에이전트 총량**으로 한다 — `main` 태스크를 메인으로
      옮기면 서브에이전트만 줄어 보이는 착시가 생기기 때문이다.
    - ctx = input + cache_read + cache_creation. 캐시 읽기를 포함하므로 청구액
      비율과 다르다(달러 환산은 단가표 하드코딩이 필요해 하지 않는다).
    - 같은 message.id 가 스트리밍으로 여러 행에 기록되므로 id 로 중복 제거한다
      (마지막 행의 usage 를 쓴다).

입력 형식은 Claude Code 내부 형식이라 버전이 바뀌면 깨질 수 있다. 그래서
건너뛴 행 수와 관측된 version 을 항상 보고하고, 파일은 있는데 집계된
메시지가 0건이면 exit 2 로 끝낸다(조용한 0 은 "비용이 0으로 줄었다"는 착시다).
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

WARNING = (
    "⚠️ ctx 는 캐시 읽기를 포함한 입력량이라 청구액 비율과 다르다 "
    "(판정은 메인+서브에이전트 총량)"
)
TOKEN_KEYS = ("input", "cache_read", "cache_creation", "output")
USAGE_FIELDS = {
    "input": "input_tokens",
    "cache_read": "cache_read_input_tokens",
    "cache_creation": "cache_creation_input_tokens",
    "output": "output_tokens",
}
WAIT_RE = re.compile(r"\bsleep\b|--watch\b|\bwait\b|\buntil\b")
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
COMMAND_NAME_RE = re.compile(r"^[A-Za-z0-9_.+-]+$")


def default_project_dir() -> Path:
    """현재 저장소 경로를 Claude Code 프로젝트 디렉터리 이름 규칙으로 바꾼다."""
    repo = Path(__file__).resolve().parent.parent
    return (
        Path.home() / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(repo))
    )


def parse_time(value: str) -> datetime:
    """ISO 날짜 또는 날짜시간을 받는다. 타임존이 없으면 UTC 로 해석한다."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def bash_head(command: str) -> str:
    """명령의 첫 단어만 돌려준다 — 인자(경로·값)는 출력하지 않는다.

    변수 대입(`F=...`)과 `cd <dir>` 뒤의 연결 연산자(`&&`·`;`·`|`)를 건너뛰어
    실제 명령을 본다. 명령 이름 형태가 아니면(경로 등) `(기타)`로 가린다.
    """
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        tokens = command.split()
    skipping_cd = False
    for token in tokens:
        if set(token) <= set("&;|()"):
            skipping_cd = False
            continue
        if skipping_cd or ENV_ASSIGN_RE.match(token):
            continue
        if token == "cd" and any(set(t) <= set("&;|") for t in tokens):
            skipping_cd = True
            continue
        return token if COMMAND_NAME_RE.match(token) else "(기타)"
    return "(기타)"


def empty_totals() -> dict:
    return {"turns": 0, **dict.fromkeys(TOKEN_KEYS, 0), "ctx": 0, "peak_ctx": 0}


def add_totals(target: dict, source: dict) -> None:
    for key in ("turns", *TOKEN_KEYS, "ctx"):
        target[key] += source[key]
    target["peak_ctx"] = max(target["peak_ctx"], source["peak_ctx"])


def scan_file(path: Path, since, until, stats: dict) -> tuple[dict, dict]:
    """jsonl 한 파일을 집계한다. (합계, 도구 분포)를 돌려준다."""
    messages: dict[str, dict] = {}
    tool_uses: dict[str, dict] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            stats["skipped_lines"] += 1
            continue
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        usage, msg_id = message.get("usage"), message.get("id")
        if not isinstance(usage, dict) or not msg_id:
            stats["skipped_lines"] += 1
            continue
        stamp = record.get("timestamp")
        if since or until:
            if not stamp:
                stats["skipped_lines"] += 1
                continue
            when = parse_time(stamp)
            if (since and when < since) or (until and when > until):
                continue
        if record.get("version"):
            stats["versions"].add(record["version"])
        messages[msg_id] = usage
        for block in message.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_uses[block.get("id") or f"{msg_id}:{len(tool_uses)}"] = block

    totals = empty_totals()
    for usage in messages.values():
        values = {
            key: int(usage.get(field) or 0) for key, field in USAGE_FIELDS.items()
        }
        ctx = values["input"] + values["cache_read"] + values["cache_creation"]
        totals["turns"] += 1
        for key in TOKEN_KEYS:
            totals[key] += values[key]
        totals["ctx"] += ctx
        totals["peak_ctx"] = max(totals["peak_ctx"], ctx)

    tools: Counter = Counter()
    heads: Counter = Counter()
    wait = 0
    for block in tool_uses.values():
        name = block.get("name", "?")
        tools[name] += 1
        if name == "Bash":
            command = (block.get("input") or {}).get("command", "")
            heads[bash_head(command)] += 1
            wait += bool(WAIT_RE.search(command))
    tool_info = {"tools": dict(tools), "bash_heads": dict(heads), "wait": wait}
    return totals, tool_info


def collect(project_dir: Path, sessions, since, until, with_tools: bool) -> dict:
    stats = {"skipped_lines": 0, "versions": set(), "files": 0}
    result = {"main_sessions": [], "subagents": []}
    totals = {"main": empty_totals(), "subagents": empty_totals()}

    for main_file in sorted(project_dir.glob("*.jsonl")):
        session = main_file.stem
        if sessions and session not in sessions:
            continue
        stats["files"] += 1
        main_totals, main_tools = scan_file(main_file, since, until, stats)
        row = {"session": session, **main_totals}
        if with_tools:
            row["tools"] = main_tools
        result["main_sessions"].append(row)
        add_totals(totals["main"], main_totals)

        for agent_file in sorted((project_dir / session / "subagents").glob("*.jsonl")):
            stats["files"] += 1
            meta_file = agent_file.with_suffix(".meta.json")
            meta = {}
            if meta_file.exists():
                try:
                    meta = json.loads(meta_file.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    stats["skipped_lines"] += 1
            agent_totals, agent_tools = scan_file(agent_file, since, until, stats)
            if agent_totals["turns"] == 0:
                continue
            row = {
                "session": session,
                "agent_id": agent_file.stem.removeprefix("agent-"),
                "agent_type": meta.get("agentType") or "unknown",
                "model": meta.get("model") or "unknown",
                "description": meta.get("description") or "",
                **agent_totals,
            }
            if with_tools:
                row["tools"] = agent_tools
            result["subagents"].append(row)
            add_totals(totals["subagents"], agent_totals)

    totals["all"] = empty_totals()
    add_totals(totals["all"], totals["main"])
    add_totals(totals["all"], totals["subagents"])
    result["subagents"].sort(key=lambda row: row["ctx"], reverse=True)
    result["totals"] = totals
    result["skipped_lines"] = stats["skipped_lines"]
    result["versions"] = sorted(stats["versions"])
    result["files"] = stats["files"]
    return result


def fmt_m(value: int) -> str:
    return f"{value / 1e6:.1f}M"


def print_text(result: dict, with_tools: bool) -> None:
    print(WARNING)
    print(
        f"{'구분':<44} {'turns':>6} {'ctx':>8} {'cache_rd':>9} "
        f"{'output':>8} {'peak':>7}"
    )
    rows = [("메인 " + m["session"][:8], m) for m in result["main_sessions"]]
    for agent in result["subagents"]:
        kind = f"{agent['agent_type'][:15]}/{agent['model'][:6]}"
        label = f"{kind} {agent['description'][:20]}"
        rows.append((label, agent))
    for label, row in rows:
        print(
            f"{label:<44} {row['turns']:>6} {fmt_m(row['ctx']):>8} "
            f"{fmt_m(row['cache_read']):>9} {row['output'] / 1e3:>7.0f}k "
            f"{row['peak_ctx'] / 1e3:>6.0f}k"
        )
        if with_tools and "tools" in row:
            tools = row["tools"]
            print(
                f"    tools={tools['tools']} bash={tools['bash_heads']} "
                f"wait={tools['wait']}"
            )
    for name in ("main", "subagents", "all"):
        total = result["totals"][name]
        print(f"합계 {name:<39} {total['turns']:>6} {fmt_m(total['ctx']):>8}")
    print(
        f"파일 {result['files']}개 · 건너뛴 행 {result['skipped_lines']} · "
        f"version {', '.join(result['versions']) or '미관측'}"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project-dir", type=Path, default=default_project_dir())
    parser.add_argument("--since", type=parse_time, help="메시지 timestamp 하한(UTC)")
    parser.add_argument("--until", type=parse_time, help="메시지 timestamp 상한(UTC)")
    parser.add_argument(
        "--session", action="append", default=[], help="세션 ID(반복 가능)"
    )
    parser.add_argument("--tools", action="store_true", help="도구·Bash 첫 단어 분포")
    parser.add_argument("--json", action="store_true", help="JSON 으로 출력")
    args = parser.parse_args(argv)

    if not args.project_dir.is_dir():
        print(f"프로젝트 디렉터리가 없다: {args.project_dir}", file=sys.stderr)
        return 1
    result = collect(
        args.project_dir, set(args.session), args.since, args.until, args.tools
    )
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print_text(result, args.tools)
    if result["files"] and result["totals"]["all"]["turns"] == 0:
        print("집계된 메시지가 0건이다 — 기록 형식 변화를 의심한다", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
