#!/usr/bin/env bash
# helm-dep-build.sh 테스트 — CI 러너처럼 helm repo 가 하나도 없는 격리 환경을 재현한다.
# 실행: bash scripts/tests/helm-dep-build.test.sh (airflow.apache.org 네트워크 필요)
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/scripts/helm-dep-build.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 빈 helm 환경 — 로컬 `helm repo add` 이력이 결과를 가리지 못하게 한다
export HELM_REPOSITORY_CONFIG="$work/helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$work/helm/repo-cache"
export HELM_CACHE_HOME="$work/helm/cache"
export HELM_CONFIG_HOME="$work/helm/config"
export HELM_DATA_HOME="$work/helm/data"
mkdir -p "$work/helm"

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

# 저장소 트리를 건드리지 않도록 chart 를 복사해서 쓴다
cp -R "$root/gitops/charts/airflow" "$work/airflow-plain"
cp -R "$root/gitops/charts/airflow" "$work/airflow-script"
cp -R "$root/gitops/charts/podinfo" "$work/podinfo"
rm -rf "$work/airflow-plain/charts" "$work/airflow-script/charts"

# 1) 재현: 빈 환경에서 맨 helm dependency build 는 실패해야 한다
if helm dependency build "$work/airflow-plain" >"$work/plain.log" 2>&1; then
    check "1 빈 환경에서 맨 helm dependency build 는 실패한다(재현)" no
else
    check "1 빈 환경에서 맨 helm dependency build 는 실패한다(재현)" yes
fi

# 2) 스크립트는 같은 환경에서 성공하고 tgz 를 만든다
if [ -x "$script" ] && "$script" "$work/airflow-script" >"$work/script.log" 2>&1 \
    && [ -f "$work/airflow-script/charts/airflow-1.22.0.tgz" ]; then
    check "2 helm-dep-build.sh 가 성공하고 charts/airflow-1.22.0.tgz 를 만든다" yes
else
    check "2 helm-dep-build.sh 가 성공하고 charts/airflow-1.22.0.tgz 를 만든다" no
    sed 's/^/    /' "$work/script.log" 2>/dev/null
fi

# 3) dependencies 없는 chart 는 no-op 성공
if [ -x "$script" ] && "$script" "$work/podinfo" >/dev/null 2>&1 && [ ! -d "$work/podinfo/charts" ]; then
    check "3 의존성 없는 chart 는 no-op 성공" yes
else
    check "3 의존성 없는 chart 는 no-op 성공" no
fi

echo "합계: PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
