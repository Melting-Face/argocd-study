#!/usr/bin/env bash
# bump-image-tag.sh 테스트 — 임시 디렉터리의 픽스처 values 로 종료 코드·stdout·파일 변경을 단언한다.
# 실행: bash scripts/tests/bump-image-tag.test.sh
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/scripts/bump-image-tag.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

# 단언 헬퍼 — 실패해도 계속 진행해 전체 결과를 본다
check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        echo "PASS: $name"
    else
        fail=$((fail + 1))
        echo "FAIL: $name (기대 '$expected', 실제 '$actual')"
    fi
}

# 마커가 정확히 1줄인 기본 픽스처
make_fixture() {
    cat >"$1" <<'YAML'
# 픽스처 values
airflow:
  images:
    airflow:
      repository: ghcr.io/melting-face/airflow-dags
      tag: "v0.1.0"  # bump-image-tag
      pullPolicy: IfNotPresent
  executor: LocalExecutor  # 다른 주석
YAML
}

# 스크립트 실행: stdout 은 out, 종료 코드는 rc 에 담는다
run() {
    out="$(bash "$script" "$@" 2>/dev/null)"
    rc=$?
}

# 케이스 1: 새 태그 -> changed, 변경 1줄, 주석·따옴표·들여쓰기 보존
f="$work/case1.yaml"
make_fixture "$f"
cp "$f" "$work/case1.orig"
run v0.1.1 "$f"
check "새 태그: stdout" "changed" "$out"
check "새 태그: exit" "0" "$rc"
numstat="$(git diff --no-index --numstat "$work/case1.orig" "$f" | awk '{print $1 "/" $2}')"
check "새 태그: 변경 1줄(추가/삭제)" "1/1" "$numstat"
check "새 태그: 마커 줄 보존" '      tag: "v0.1.1"  # bump-image-tag' "$(grep 'bump-image-tag' "$f")"
check "새 태그: 다른 주석 보존" "1" "$(grep -c '# 다른 주석' "$f")"

# 케이스 2: 같은 값 -> unchanged, 바이트 동일
f="$work/case2.yaml"
make_fixture "$f"
cp "$f" "$work/case2.orig"
run v0.1.0 "$f"
check "같은 태그: stdout" "unchanged" "$out"
check "같은 태그: exit" "0" "$rc"
cmp -s "$work/case2.orig" "$f" && same=same || same=differ
check "같은 태그: 파일 바이트 동일" "same" "$same"

# 케이스 3: 형식 위반 -> exit 2, 파일 불변
for bad in 0.1.1 v0.1 latest; do
    f="$work/case3.yaml"
    make_fixture "$f"
    cp "$f" "$work/case3.orig"
    run "$bad" "$f"
    check "형식 위반 '$bad': exit" "2" "$rc"
    cmp -s "$work/case3.orig" "$f" && same=same || same=differ
    check "형식 위반 '$bad': 파일 불변" "same" "$same"
done

# 케이스 4: 마커 줄 없음 -> exit 3, 파일 불변
f="$work/case4.yaml"
printf 'airflow:\n  images:\n    airflow:\n      tag: "v0.1.0"\n' >"$f"
cp "$f" "$work/case4.orig"
run v0.1.1 "$f"
check "마커 없음: exit" "3" "$rc"
cmp -s "$work/case4.orig" "$f" && same=same || same=differ
check "마커 없음: 파일 불변" "same" "$same"

# 케이스 5: 마커 줄 2개 -> exit 3, 파일 불변
f="$work/case5.yaml"
make_fixture "$f"
printf '  other:\n    tag: "v0.0.1"  # bump-image-tag\n' >>"$f"
cp "$f" "$work/case5.orig"
run v0.1.1 "$f"
check "마커 2개: exit" "3" "$rc"
cmp -s "$work/case5.orig" "$f" && same=same || same=differ
check "마커 2개: 파일 불변" "same" "$same"

# 케이스 6: 마커 줄 모양 위반 -> exit 3, 파일 불변
n=0
while IFS= read -r bad_line; do
    n=$((n + 1))
    f="$work/case6.yaml"
    printf 'airflow:\n  images:\n    airflow:\n%s\n' "$bad_line" >"$f"
    cp "$f" "$work/case6.orig"
    run v0.2.0 "$f"
    check "모양 위반 #$n: exit" "3" "$rc"
    cmp -s "$work/case6.orig" "$f" && same=same || same=differ
    check "모양 위반 #$n: 파일 불변" "same" "$same"
done <<'LINES'
      tag: 'v0.1.0'  # bump-image-tag
      image: ghcr.io/x:v0.1.0  # bump-image-tag
      tag: "v0.1.0-rc1"  # bump-image-tag
LINES

# 케이스 7: 따옴표 없는 값도 지원한다
f="$work/case7.yaml"
printf '      tag: v0.1.0  # bump-image-tag\n' >"$f"
run v0.2.0 "$f"
check "따옴표 없음: stdout" "changed" "$out"
check "따옴표 없음: 결과" '      tag: v0.2.0  # bump-image-tag' "$(cat "$f")"

echo "---"
echo "통과 $pass / 실패 $fail"
[ "$fail" -eq 0 ]
