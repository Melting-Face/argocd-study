#!/usr/bin/env bash
# 이미지 태그 갱신 스크립트 — values 파일의 태그 한 줄을 <tag> 로 바꾼다.
#
# 사용법: scripts/bump-image-tag.sh <tag> <values-file>
#
# 대상 줄: 줄 끝이 마커 주석 `# bump-image-tag` 인 단 한 줄. 이 줄은
#   `airflow.images.airflow.tag` (gitops/charts/airflow/values.yaml) 의 값이어야 하며,
#   그 관계는 Task 3 의 렌더 테스트가 보증한다. 기대 형태(들여쓰기는 달라도 된다):
#       tag: "v0.1.0"  # bump-image-tag
#   들여쓰기·따옴표·마커 주석은 그대로 보존하고 버전 토큰만 바꾼다.
#
# 🔴 yq 대신 sed 한 줄 치환을 쓰는 이유: yq 는 로컬에 없고, 쓰더라도 들여쓰기·따옴표를
#    재서식화해 여러 줄 diff 를 만들 위험이 있다. sed 는 대상 줄 하나만 건드린다.
#
# 종료 코드:
#   0  성공 — stdout 에 `changed` 또는 `unchanged`
#   1  사용법 오류·파일 없음
#   2  태그 형식 위반 (^v[0-9]+\.[0-9]+\.[0-9]+$) — 파일을 열기 전에 검사한다
#   3  마커 줄이 정확히 1개가 아님 (0개 또는 2개 이상)
set -u

marker='# bump-image-tag'

if [ "$#" -ne 2 ]; then
    echo "사용법: $0 <tag> <values-file>" >&2
    exit 1
fi

tag="$1"
file="$2"

# 형식 검사는 파일을 건드리기 전에 한다
if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "태그 형식 위반: '$tag' (기대: vX.Y.Z)" >&2
    exit 2
fi

if [ ! -f "$file" ]; then
    echo "파일 없음: $file" >&2
    exit 1
fi

# 마커 줄 수 검사 — 정확히 1개여야 한다
count="$(grep -c -- "${marker}[[:space:]]*\$" "$file")"
if [ "$count" -ne 1 ]; then
    echo "마커 '$marker' 줄이 ${count}개다 (정확히 1개여야 한다): $file" >&2
    exit 3
fi

# 임시 파일에 치환해 쓴 뒤 비교·교체한다 (BSD/GNU sed 의 `-i` 차이를 피한다)
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "/${marker}[[:space:]]*\$/s/\\(tag:[[:space:]]*\"\\{0,1\\}\\)v[0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*/\\1${tag}/" \
    "$file" >"$tmp"

if cmp -s "$file" "$tmp"; then
    echo "unchanged"
else
    # cat 으로 덮어써 원본 파일의 권한·inode 를 유지한다
    cat "$tmp" >"$file"
    echo "changed"
fi
