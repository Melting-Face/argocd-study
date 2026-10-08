#!/usr/bin/env bash
# gitops/charts/airflow/tests/render.test.sh
#
# Airflow umbrella chart(공식 chart 를 dependency 로 감싼 chart)를 `helm template` 으로
# 렌더해 정적 계약을 검증한다. 클러스터를 건드리지 않는다(렌더링만 한다). 의존 chart 는
# `helm dependency build` 로 받는다 — 네트워크(https://airflow.apache.org)가 필요하다.
#
# 단언:
#   1. 렌더 결정성 — 같은 입력으로 두 번 렌더한 결과가 바이트 동일하다.
#      (공식 chart 는 Secret 을 자동 생성할 때 randAlphaNum 을 쓰므로, 이름을 지정한
#       정적 Secret 참조로 바꾸지 않으면 렌더마다 값이 달라져 ArgoCD 가 영원히 OutOfSync 다.)
#   2. fernet-key·jwt-secret·api-secret-key Secret 을 chart 가 만들지 않는다.
#   3. 해당 환경변수가 정해진 (Secret 이름, 데이터 키)를 secretKeyRef 로 가리킨다.
#   4. airflow 컨테이너 이미지가 모두 ghcr.io/melting-face/airflow-dags:v0.1.0 이다.
#   5. scripts/bump-image-tag.sh 의 마커 줄이 airflow.images.airflow.tag 와 이어져 있다
#      (진짜 values 의 복사본에만 쓴다 — 실제 파일은 건드리지 않는다).
#
# 의존 도구: helm, ruby(YAML→JSON), jq. yq 는 쓰지 않는다(이 환경에 없다).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CHART_DIR}/../../.." && pwd)"
BUMP_SCRIPT="${REPO_ROOT}/scripts/bump-image-tag.sh"
RELEASE_NAME="airflow"
NAMESPACE="airflow"
EXPECTED_IMAGE="ghcr.io/melting-face/airflow-dags"
EXPECTED_TAG="v0.1.0"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

overall_rc=0
pass() { echo "PASS $1"; }
fail() {
    echo "FAIL $1"
    overall_rc=1
}

# stdin 의 각 줄을 4칸 들여써 출력한다(실패 상세용)
indent() {
    while IFS= read -r line; do
        echo "    ${line}"
    done
}

# YAML(stdin) -> JSON Lines(문서 하나당 한 줄)
yaml_to_json_lines() {
    ruby -ryaml -rjson -e 'YAML.load_stream(STDIN.read).compact.each { |doc| puts doc.to_json }'
}

# $1: 출력 파일  나머지: helm template 에 덧붙일 인자
render() {
    local out="$1"
    shift
    helm template "${RELEASE_NAME}" "${CHART_DIR}" -n "${NAMESPACE}" "$@" >"${out}"
}

# 이미지 목록(중복 제거): postgresql subchart 는 airflow 이미지가 아니므로 뺀다.
list_airflow_images() {
    yaml_to_json_lines <"$1" | jq -r '
      select((.metadata.name // "") | test("-postgresql") | not)
      | [.. | objects | select(has("image")) | .image] | .[]' | sort -u
}

# --- 준비: dependency 받기 ---
if ! helm dependency build "${CHART_DIR}" >"${WORKDIR}/dep.log" 2>&1; then
    echo "FAIL [준비] helm dependency build 실패 — chart 가 없거나 깨졌다:"
    sed 's/^/    /' "${WORKDIR}/dep.log"
    exit 1
fi

render "${WORKDIR}/render1.yaml" 2>"${WORKDIR}/render1.err" || {
    echo "FAIL [준비] helm template 렌더링 실패:"
    sed 's/^/    /' "${WORKDIR}/render1.err"
    exit 1
}
render "${WORKDIR}/render2.yaml"

# --- 단언 1: 렌더 결정성 ---
if cmp -s "${WORKDIR}/render1.yaml" "${WORKDIR}/render2.yaml"; then
    pass "[1 렌더 결정성] 두 렌더가 바이트 동일"
else
    fail "[1 렌더 결정성] 두 렌더가 다르다:"
    { diff "${WORKDIR}/render1.yaml" "${WORKDIR}/render2.yaml" || true; } | head -20 | sed "s/^/    /"
fi

# --- 단언 2: 자동 생성 Secret 0개 ---
generated="$(yaml_to_json_lines <"${WORKDIR}/render1.yaml" |
    jq -r 'select(.kind == "Secret") | .metadata.name
           | select(test("-(fernet-key|jwt-secret|api-secret-key)$"))')"
if [ -z "${generated}" ]; then
    pass "[2 Secret 자동 생성 없음] fernet-key·jwt-secret·api-secret-key 0개"
else
    fail "[2 Secret 자동 생성 없음] chart 가 Secret 을 만든다:"
    indent <<<"${generated}"
fi

# --- 단언 3: secretKeyRef ---
check_secret_ref() {
    local env_name="$1" expected="$2" actual
    actual="$(yaml_to_json_lines <"${WORKDIR}/render1.yaml" | jq -s -r --arg n "${env_name}" '
      [.. | objects | select(.name? == $n)
       | (.valueFrom.secretKeyRef // {name: "(secretKeyRef 아님)", key: "-"})
       | "\(.name)/\(.key)"] | unique | join(",")')"
    if [ "${actual}" = "${expected}" ]; then
        pass "[3 secretKeyRef] ${env_name} -> ${expected}"
    else
        fail "[3 secretKeyRef] ${env_name}: 기대 '${expected}', 실제 '${actual}'"
    fi
}
check_secret_ref AIRFLOW__CORE__FERNET_KEY airflow-fernet-key/fernet-key
check_secret_ref AIRFLOW__API_AUTH__JWT_SECRET airflow-jwt-secret/jwt-secret
check_secret_ref AIRFLOW__API__SECRET_KEY airflow-webserver-secret/api-secret-key

# --- 단언 4: 이미지 ---
check_images() {
    local label="$1" file="$2" tag="$3" images bad
    images="$(list_airflow_images "${file}")"
    bad="$(echo "${images}" | grep -v -x "${EXPECTED_IMAGE}:${tag}" || true)"
    if [ -n "${images}" ] && [ -z "${bad}" ]; then
        pass "[${label}] airflow 컨테이너 이미지가 모두 ${EXPECTED_IMAGE}:${tag}"
    else
        fail "[${label}] 기대와 다른 이미지가 있다(또는 이미지가 0개):"
        indent <<<"${images}"
    fi
}
check_images "4 이미지" "${WORKDIR}/render1.yaml" "${EXPECTED_TAG}"

# --- 단언 5: bump-image-tag.sh 와 values.yaml 의 연결 (복사본에서만) ---
copy="${WORKDIR}/values.copy.yaml"
cp "${CHART_DIR}/values.yaml" "${copy}"

if out="$("${BUMP_SCRIPT}" "${EXPECTED_TAG}" "${copy}")" && [ "${out}" = "unchanged" ]; then
    pass "[5a bump] ${EXPECTED_TAG} 를 다시 쓰면 unchanged"
else
    fail "[5a bump] ${EXPECTED_TAG} 에 대해 'unchanged' 를 기대했다(실제: '${out:-}')"
fi

if out="$("${BUMP_SCRIPT}" v0.1.1 "${copy}")" && [ "${out}" = "changed" ]; then
    pass "[5b bump] v0.1.1 로 올리면 changed"
else
    fail "[5b bump] v0.1.1 에 대해 'changed' 를 기대했다(실제: '${out:-}')"
fi

# 복사본을 -f 로 덮어 렌더하면 이미지가 :v0.1.1 이어야 한다 — 마커 줄이 정말
# airflow.images.airflow.tag 인지(다른 키를 고치고 있지 않은지) 증명한다.
if render "${WORKDIR}/render-bumped.yaml" -f "${copy}"; then
    check_images "5c bump 렌더" "${WORKDIR}/render-bumped.yaml" v0.1.1
else
    fail "[5c bump 렌더] 복사본으로 helm template 실패"
fi

exit "${overall_rc}"
