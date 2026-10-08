#!/usr/bin/env bash
# terraform/platform/charts/appset/tests/render.test.sh
#
# appset chart 의 렌더 결과를 검증한다. 클러스터를 건드리지 않는다(helm template 은
# 로컬 렌더링만 한다). 의존 도구: helm, ruby(표준 라이브러리 YAML/JSON).
#
# 검사 항목:
#   (a) 앱 2개 렌더 — ApplicationSet 1개(이름 apps), elements 2개, 그리고 ApplicationSet
#       컨트롤러가 채울 리터럴 {{ .name }}·{{ .path }}·{{ .namespace }} 가 렌더 결과에
#       그대로 남아 있다(Helm 이 먼저 먹어버리면 빈 문자열이 되어 앱이 전부 같은 이름이 된다)
#   (b) apps=[] 도 렌더되고 elements: [] 로 유효한 YAML 이다
#   (c) repoUrl 을 비우면 helm template 이 실패한다(helm lint 는 이를 못 잡는다)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_URL="https://github.com/Melting-Face/argocd-study.git"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

FAILED=0
fail() {
    echo "FAIL: $*" >&2
    FAILED=1
}
pass() {
    echo "PASS: $*"
}

cat > "${WORKDIR}/two-apps.yaml" <<'VALUES'
apps:
  - name: podinfo
    path: gitops/charts/podinfo
    namespace: podinfo
  - name: airflow
    path: gitops/charts/airflow
    namespace: airflow
VALUES

# 렌더 결과(stdin)를 YAML 로 파싱해 ApplicationSet 개수·이름·elements 개수를 "개수 이름 개수" 로 출력
summarize() {
    ruby -ryaml -e '
        docs = YAML.load_stream(STDIN.read).compact
        sets = docs.select { |d| d["kind"] == "ApplicationSet" }
        name = sets.empty? ? "-" : sets[0]["metadata"]["name"]
        els = sets.empty? ? -1 : sets[0]["spec"]["generators"][0]["list"]["elements"].length
        puts "#{sets.length} #{name} #{els}"
    '
}

# (a) 앱 2개
if out_a="$(helm template appset "${CHART_DIR}" --set "repoUrl=${REPO_URL}" -f "${WORKDIR}/two-apps.yaml" 2>&1)"; then
    if [[ "$(echo "${out_a}" | summarize)" == "1 apps 2" ]]; then
        pass "(a) ApplicationSet 1개, 이름 apps, elements 2개"
    else
        fail "(a) 요약 불일치: $(echo "${out_a}" | summarize)"
    fi
    for key in name path namespace; do
        if grep -qF "{{ .${key} }}" <<< "${out_a}"; then
            pass "(a) 리터럴 {{ .${key} }} 보존"
        else
            fail "(a) 리터럴 {{ .${key} }} 가 렌더 결과에 없다 - Helm 이스케이프 누락"
        fi
    done
else
    fail "(a) helm template 실패: ${out_a}"
fi

# (b) apps=[]
if out_b="$(helm template appset "${CHART_DIR}" --set "repoUrl=${REPO_URL}" --set-json 'apps=[]' 2>&1)"; then
    if [[ "$(echo "${out_b}" | summarize)" == "1 apps 0" ]]; then
        pass "(b) apps=[] 렌더, elements 0개로 유효한 YAML"
    else
        fail "(b) 요약 불일치: $(echo "${out_b}" | summarize)"
    fi
    # toYaml | nindent 는 빈 목록을 "elements:" 다음 줄의 [] 로 쓴다 - 파싱한 길이가 0 이면 충분하다.
    if grep -qE '^ +\[\]$' <<< "${out_b}"; then
        pass "(b) 빈 목록 [] 출력"
    else
        fail "(b) 빈 목록 [] 가 없다"
    fi
else
    fail "(b) helm template 실패: ${out_b}"
fi

# (c) repoUrl 비움
if helm template appset "${CHART_DIR}" --set "repoUrl=" > /dev/null 2>&1; then
    fail "(c) repoUrl 이 비었는데 helm template 이 성공했다"
else
    pass "(c) repoUrl 비움 - helm template 실패"
fi

exit "${FAILED}"
