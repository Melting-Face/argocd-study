#!/usr/bin/env bash
# gitops/charts/podinfo/tests/equivalence.sh
#
# "helm template로 렌더링한 결과"와 "gitops/manifests/podinfo/*.yaml(Phase 1이 손으로
# 쓴 정답지, 지금 클러스터에서 돌고 있다)"가 의미상 같은지 본다. 클러스터를 전혀
# 건드리지 않는다 — helm template은 로컬 렌더링만 하고(--validate를 주지 않았다),
# API 서버에 접속하지 않는다.
#
# 🔴 무엇을 "정당한 차이"로 보는가 — 그 외 모든 차이는 실패다:
#   - metadata.labels["app.kubernetes.io/managed-by"]
#   - metadata.labels["helm.sh/chart"]
#   이 둘은 Helm 차트가 관용적으로 자기 리소스에 붙이는 레이블이다(_helpers.tpl의
#   podinfo.labels). plain manifest에는 애초에 없었고, Helm "엔진"이 자동으로
#   주입하는 것도 아니다 — 우리 차트의 _helpers.tpl이 공통 레이블 블록에 넣기로
#   선택한 것뿐이다. 중요한 건 이 둘이 **selector/matchLabels/pod 템플릿 레이블에는
#   들어가지 않는다는 것** — 그쪽 레이블은 아래서 전혀 지우지 않고 그대로 비교한다.
#   Deployment.spec.selector.matchLabels는 생성 후 불변 필드라, 거기 한 글자라도
#   다르면 Task 2에서 Deployment가 교체되며 파드가 재생성된다(이 Task의 핵심 리스크).
#
# 의존 도구: helm(로컬 렌더링), ruby(YAML→JSON, macOS 기본 탑재 Psych/JSON 표준
# 라이브러리만 쓴다 — 별도 설치 불필요), jq(JSON 정규화·diff용 키 정렬).
# yq는 쓰지 않는다(이 환경에 없다 — 실측).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${CHART_DIR}/../../.." && pwd)"
MANIFEST_DIR="${REPO_ROOT}/gitops/manifests/podinfo"
RELEASE_NAME="podinfo"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# YAML(stdin) -> JSON Lines(문서 하나당 한 줄). YAML.load_stream이 빈 문서(문서
# 구분자 `---`만 있고 내용이 없는 경우)를 nil로 돌려주므로 compact로 걸러낸다.
yaml_to_json_lines() {
    ruby -ryaml -rjson -e 'YAML.load_stream(STDIN.read).compact.each { |doc| puts doc.to_json }'
}

# JSON 한 줄 -> 정규화된 JSON. "정당한 차이" 필드를 지우고 키를 정렬한다.
normalize_json() {
    jq -S '
      if .metadata.labels then
        .metadata.labels |= del(."app.kubernetes.io/managed-by", ."helm.sh/chart")
      else
        .
      end
    '
}

overall_rc=0

# $1: 리소스 이름(로그용)  $2: plain manifest 파일  $3: 차트 템플릿 경로(templates/ 기준)
compare_resource() {
    local label="$1" manifest_file="$2" template_path="$3"
    local plain_json="${WORKDIR}/${label}.plain.json"
    local chart_json="${WORKDIR}/${label}.chart.json"

    if ! yaml_to_json_lines <"${manifest_file}" | normalize_json >"${plain_json}"; then
        echo "FAIL [${label}] plain manifest(${manifest_file}) 파싱 실패"
        overall_rc=1
        return
    fi

    local render_err="${WORKDIR}/${label}.helm.stderr"
    if ! helm template "${RELEASE_NAME}" "${CHART_DIR}" --show-only "${template_path}" \
        >"${WORKDIR}/${label}.raw.yaml" 2>"${render_err}"; then
        echo "FAIL [${label}] helm template 렌더링 실패 — chart가 없거나 깨졌다:"
        sed 's/^/    /' "${render_err}"
        overall_rc=1
        return
    fi

    if ! yaml_to_json_lines <"${WORKDIR}/${label}.raw.yaml" | normalize_json >"${chart_json}"; then
        echo "FAIL [${label}] helm template 출력 파싱 실패"
        overall_rc=1
        return
    fi

    if diff -u "${plain_json}" "${chart_json}" >"${WORKDIR}/${label}.diff"; then
        echo "PASS [${label}] 의미 있는 차이 없음"
    else
        echo "FAIL [${label}] 정규화 후에도 차이가 남는다 (좌: plain manifest, 우: helm template):"
        sed 's/^/    /' "${WORKDIR}/${label}.diff"
        overall_rc=1
    fi
}

compare_resource deployment "${MANIFEST_DIR}/deployment.yaml" templates/deployment.yaml
compare_resource service "${MANIFEST_DIR}/service.yaml" templates/service.yaml
compare_resource ingress "${MANIFEST_DIR}/ingress.yaml" templates/ingress.yaml

exit "${overall_rc}"
