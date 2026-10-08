#!/usr/bin/env bash
# subagent_usage.py 테스트 — 가짜 세션 기록(fixture)만 쓰고 ~/.claude 는 읽지 않는다.
# 실행: bash scripts/tests/subagent-usage.test.sh (pre-commit 로컬 훅 `subagent-usage-test`)
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/scripts/subagent_usage.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
check() {
    local name="$1" ok="$2"
    if [ "$ok" = "yes" ]; then
        pass=$((pass + 1))
        echo "PASS: $name"
    else
        fail=$((fail + 1))
        echo "FAIL: $name"
    fi
}

# JSON 출력에서 값 하나를 꺼낸다 — 인자: JSON 파일, 파이썬 식(d 가 파싱 결과)
jq_py() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# --- fixture: 세션 S1(메인 + 서브에이전트 2개), 세션 S2(메인만) -----------------
proj="$work/proj"
mkdir -p "$proj/S1/subagents"

# 메인 S1: m1 이 스트리밍으로 3행에 걸쳐 기록된다(같은 message.id) → 1턴이어야 한다
u1='"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":7}'
u2='"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}'
cat >"$proj/S1.jsonl" <<EOF
{"type":"user","timestamp":"2026-10-01T00:00:00Z","message":{"role":"user","content":"hi"}}
{"type":"assistant","version":"9.9.9","timestamp":"2026-10-01T00:00:01Z","message":{"id":"m1","role":"assistant","content":[],$u1}}
{"type":"assistant","version":"9.9.9","timestamp":"2026-10-01T00:00:01Z","message":{"id":"m1","role":"assistant","content":[],$u1}}
{"type":"assistant","version":"9.9.9","timestamp":"2026-10-01T00:00:01Z","message":{"id":"m1","role":"assistant","content":[],$u1}}
{not json
{"type":"assistant","version":"9.9.9","timestamp":"2026-10-02T00:00:00Z","message":{"id":"m2","role":"assistant","content":[],$u2}}
EOF

# 서브에이전트 a1(meta 있음): Bash 2회 — sleep(대기), kubectl(인자에 경로가 있다)
cat >"$proj/S1/subagents/agent-a1.jsonl" <<'EOF'
{"type":"assistant","version":"9.9.9","timestamp":"2026-10-01T01:00:00Z","message":{"id":"s1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 5"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"KUBECONFIG=/secret/path kubectl --kubeconfig /secret/path get pods"}}],"usage":{"input_tokens":2,"cache_read_input_tokens":50,"cache_creation_input_tokens":0,"output_tokens":3}}}
{"type":"assistant","version":"9.9.9","timestamp":"2026-10-01T01:00:00Z","message":{"id":"s1","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"KUBECONFIG=/secret/path kubectl --kubeconfig /secret/path get pods"}}],"usage":{"input_tokens":2,"cache_read_input_tokens":50,"cache_creation_input_tokens":0,"output_tokens":3}}}
EOF
cat >"$proj/S1/subagents/agent-a1.meta.json" <<'EOF'
{"agentType":"general-purpose","description":"Task 1 fixture","model":"sonnet"}
EOF

# 서브에이전트 a2(meta 없음) → unknown 으로 표시돼야 한다
cat >"$proj/S1/subagents/agent-a2.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-10-01T02:00:00Z","message":{"id":"x1","role":"assistant","content":[],"usage":{"input_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}
EOF

# 메인 S2: --session 필터로 빠져야 한다
cat >"$proj/S2.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-10-01T00:00:00Z","message":{"id":"z1","role":"assistant","content":[],"usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}
EOF

run_json() { python3 "$script" --project-dir "$proj" --json "$@" >"$work/out.json" 2>"$work/err.txt"; }

# 1) 같은 message.id 는 1턴 · 토큰 합 · meta 없음은 unknown · 깨진 행은 건너뛴다
run_json --session S1
[ "$(jq_py "$work/out.json" 'd["totals"]["main"]["turns"]')" = "2" ] && ok=yes || ok=no
check "1 메인 턴은 message.id 중복 제거 후 2" "$ok"
[ "$(jq_py "$work/out.json" 'd["totals"]["main"]["ctx"]')" = "116" ] && ok=yes || ok=no
check "2 메인 ctx 합계 = (10+100+5) + 1 = 116" "$ok"
[ "$(jq_py "$work/out.json" 'd["totals"]["main"]["output"]')" = "8" ] && ok=yes || ok=no
check "3 메인 output 은 따로 센다(7+1)" "$ok"
[ "$(jq_py "$work/out.json" '[a["agent_type"] for a in d["subagents"] if a["agent_id"]=="a2"][0]')" = "unknown" ] && ok=yes || ok=no
check "4 meta 없는 서브에이전트는 unknown" "$ok"
[ "$(jq_py "$work/out.json" 'd["skipped_lines"] >= 1')" = "True" ] && ok=yes || ok=no
check "5 깨진 행은 건너뛰고 개수를 보고한다" "$ok"
[ "$(jq_py "$work/out.json" 'd["totals"]["all"]["ctx"]')" = "$((116 + 52 + 4))" ] && ok=yes || ok=no
check "6 판정 총량 all = 메인 + 서브에이전트" "$ok"
[ "$(jq_py "$work/out.json" '"9.9.9" in d["versions"]')" = "True" ] && ok=yes || ok=no
check "7 관측된 Claude Code version 을 보고한다" "$ok"

# 2) --session 필터 · 메시지 시각 범위 필터(UTC)
[ "$(jq_py "$work/out.json" 'all(m["session"]=="S1" for m in d["main_sessions"])')" = "True" ] && ok=yes || ok=no
check "8 --session S1 은 S2 를 뺀다" "$ok"
run_json --session S1 --since 2026-10-02
[ "$(jq_py "$work/out.json" 'd["totals"]["main"]["turns"]')" = "1" ] && ok=yes || ok=no
check "9 --since 는 메시지 timestamp 로 거른다" "$ok"
run_json --session S1 --until 2026-10-01T00:30:00Z
[ "$(jq_py "$work/out.json" 'd["totals"]["subagents"]["turns"]')" = "0" ] && ok=yes || ok=no
check "10 --until 은 이후 메시지를 뺀다" "$ok"

# 3) --tools: 첫 단어만, 대기 횟수, 인자 비노출
python3 "$script" --project-dir "$proj" --session S1 --tools --json >"$work/tools.json" 2>/dev/null
[ "$(jq_py "$work/tools.json" '[a for a in d["subagents"] if a["agent_id"]=="a1"][0]["tools"]["bash_heads"]=={"sleep":1,"kubectl":1}')" = "True" ] && ok=yes || ok=no
check "11 Bash 첫 단어 분포(환경변수 대입은 건너뜀, tool_use id 중복 제거)" "$ok"
[ "$(jq_py "$work/tools.json" '[a for a in d["subagents"] if a["agent_id"]=="a1"][0]["tools"]["wait"]')" = "1" ] && ok=yes || ok=no
check "12 대기·폴링 횟수" "$ok"
python3 "$script" --project-dir "$proj" --session S1 --tools >"$work/tools.txt" 2>&1
! grep -q "secret" "$work/tools.json" "$work/tools.txt" && ok=yes || ok=no
check "13 명령 인자(경로)는 출력하지 않는다" "$ok"

# 4) 텍스트 출력 첫 줄 경고 · 0건이면 exit 2
python3 "$script" --project-dir "$proj" --session S1 >"$work/out.txt" 2>&1
head -1 "$work/out.txt" | grep -q "청구액" && ok=yes || ok=no
check "14 텍스트 출력 첫 줄에 청구액 경고" "$ok"
mkdir -p "$work/empty"
echo '{"type":"user","message":{"role":"user","content":"x"}}' >"$work/empty/E.jsonl"
python3 "$script" --project-dir "$work/empty" >/dev/null 2>&1
[ "$?" = "2" ] && ok=yes || ok=no
check "15 파일은 있는데 집계 0건이면 exit 2(형식 변화 신호)" "$ok"

# 5) `&&` 없는 단독 cd 명령에서도 죽지 않는다(첫 단어 cd)
mkdir -p "$work/cdonly"
cat >"$work/cdonly/C.jsonl" <<'EOF2'
{"type":"assistant","timestamp":"2026-10-01T00:00:00Z","message":{"id":"c1","role":"assistant","content":[{"type":"tool_use","id":"k1","name":"Bash","input":{"command":"cd /tmp"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}
EOF2
python3 "$script" --project-dir "$work/cdonly" --tools --json >"$work/cd.json" 2>"$work/cd.err"
[ "$(jq_py "$work/cd.json" 'd["main_sessions"][0]["tools"]["bash_heads"]=={"cd":1}' 2>/dev/null)" = "True" ] && ok=yes || ok=no
check "16 && 없는 단독 cd 는 첫 단어 cd 로 센다" "$ok"

# 6) 따옴표 안 공백이 있는 변수 대입·`;` 로 이은 cd 에서도 인자가 새지 않는다
mkdir -p "$work/quoted"
cat >"$work/quoted/Q.jsonl" <<'EOF2'
{"type":"assistant","timestamp":"2026-10-01T00:00:00Z","message":{"id":"q1","role":"assistant","content":[{"type":"tool_use","id":"j1","name":"Bash","input":{"command":"F=\"a.md docs/secret-path.md\"; pre-commit run --files $F"}},{"type":"tool_use","id":"j2","name":"Bash","input":{"command":"cd /secret-dir; git status"}},{"type":"tool_use","id":"j3","name":"Bash","input":{"command":"./docs/secret-run.sh"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}
EOF2
python3 "$script" --project-dir "$work/quoted" --tools --json >"$work/q.json" 2>&1
[ "$(jq_py "$work/q.json" 'd["main_sessions"][0]["tools"]["bash_heads"]=={"pre-commit":1,"git":1,"(기타)":1}' 2>/dev/null)" = "True" ] && ok=yes || ok=no
check "17 따옴표 대입·; 로 이은 cd 를 해석하고 경로형 첫 단어는 (기타)" "$ok"
! grep -q "secret" "$work/q.json" && ok=yes || ok=no
check "18 경로가 출력에 새지 않는다" "$ok"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
