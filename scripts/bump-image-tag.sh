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
#   3  마커 줄이 정확히 1개가 아니거나(0개·2개 이상) 모양이 `tag: "vX.Y.Z"` 가 아님
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

# 마커 줄의 모양 검사 — `tag:` 키 + 정확히 vX.Y.Z 인 값(큰따옴표는 선택)만 허용한다.
# 모양이 다르면 sed 가 조용히 아무것도 안 바꾸고 `unchanged` 로 오인되므로 exit 3 으로 막는다.
line="$(grep -- "${marker}[[:space:]]*\$" "$file")"
re_quoted='^[[:space:]]*tag:[[:space:]]*"(v[0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*# bump-image-tag[[:space:]]*$'
re_plain='^[[:space:]]*tag:[[:space:]]*(v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*# bump-image-tag[[:space:]]*$'
if [[ "$line" =~ $re_quoted ]] || [[ "$line" =~ $re_plain ]]; then
    current="${BASH_REMATCH[1]}"
else
    echo "마커 줄 모양 위반(기대: tag: \"vX.Y.Z\"  $marker): $line" >&2
    exit 3
fi

# `unchanged` 는 마커 줄의 값이 이미 <tag> 와 같을 때만 의미한다
if [ "$current" = "$tag" ]; then
    echo "unchanged"
    exit 0
fi

# 임시 파일에 치환해 쓴 뒤 교체한다 (BSD/GNU sed 의 `-i` 차이를 피한다)
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "/${marker}[[:space:]]*\$/s/\\(tag:[[:space:]]*\"\\{0,1\\}\\)v[0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*/\\1${tag}/" \
    "$file" >"$tmp"

# 치환 결과 검증 — 마커 줄의 값이 정확히 <tag> 가 아니면 파일을 건드리지 않고 실패한다
newline="$(grep -- "${marker}[[:space:]]*\$" "$tmp")"
if [[ "$newline" =~ $re_quoted ]] || [[ "$newline" =~ $re_plain ]]; then
    if [ "${BASH_REMATCH[1]}" != "$tag" ]; then
        echo "치환 검증 실패: $newline" >&2
        exit 3
    fi
else
    echo "치환 검증 실패: $newline" >&2
    exit 3
fi

# cat 으로 덮어써 원본 파일의 권한·inode 를 유지한다
cat "$tmp" >"$file"
echo "changed"
