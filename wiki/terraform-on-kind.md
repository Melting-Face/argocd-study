# kind 위의 Terraform — `tehcyx/kind`와 런타임 자동탐지 함정

`terraform/cluster/kind/`가 세우는 스택 A를 만들며 관측한 것을 적는다. 핵심은
하나다 — **"podman을 쓴다"를 Terraform 변수로 고정할 방법이 없다.** 이 노트는 왜
안 되는지, 그 대신 무엇을 했는지, 그리고 그 방어가 어디까지 막고 어디서부터
못 막는지를 실측 기준으로 적는다.

## `tehcyx/kind` 프로바이더 스키마

`kind_cluster` 리소스(실측: `terraform providers schema -json`, 버전 0.11.0):

- 인자: `name`(필수), `node_image`, `wait_for_ready`, `kind_config`(블록),
  `kubeconfig_path`. `node_image`·`kubeconfig_path`는 `optional+computed`라
  직접 값을 넣어도 되고, 비워두면 프로바이더가 채운다.
- 내보내는 값: `kubeconfig`, `client_certificate`, `client_key`,
  `cluster_ca_certificate`, `endpoint`, `completed`.
- `kind_config` 블록은 `kind`·`api_version`(둘 다 필수)과 `node` 블록 리스트를 받는다.
- `kind_config.node` 블록이 지원하는 것: `role`, `image`, `extra_mounts`,
  `extra_port_mappings`, `labels`, `kubeadm_config_patches`.
- `extra_port_mappings` 필드: `container_port`, `host_port`, `listen_address`,
  `protocol`.

(출처: `tehcyx/kind` 0.11.0의 `kind/schema_kind_config.go`를 GitHub API로 직접 읽어
확인 — 2026-10-04.)

## R1 — podman 선택에 `KIND_EXPERIMENTAL_PROVIDER`가 안 먹는다

`tehcyx/terraform-provider-kind`의 `kind/resource_cluster.go`(L137, 149, 196)는
런타임 옵션 없이 `cluster.NewProvider(cluster.ProviderWithLogger(...))`를 호출한다.

`kubernetes-sigs/kind`의 `pkg/cluster/provider.go`에서 `NewProvider`는 옵션이
없으면 `DetectNodeProvider()`로 떨어지고, 그 함수는 **docker → nerdctl → podman
순으로 `IsAvailable()`**을 본다. 소스 주석이 명시한다:

> "kind **cli** 는 `KIND_EXPERIMENTAL_PROVIDER`를 보지만" — **라이브러리 자동탐지는
> 보지 않는다.**

아무것도 못 찾으면 `ProviderWithDocker()`로 폴백한다.

지금 이 머신은 docker·nerdctl이 없어 podman이 선택된다(`command -v docker` /
`nerdctl` 둘 다 실패, `podman`만 성공). **그러나 이것은 설정이 아니라 우연이다.**
Docker Desktop을 설치하면 조용히 docker로 넘어가고, 환경변수로 되돌릴 수단이
없다.

## 방어 — `precondition`으로 전제를 선언한다

"고정"은 못 하므로, `var.expected_runtime` + `data "external" "runtime"` +
`lifecycle.precondition`으로 **"지금 탐지된 런타임이 우리가 알던 값과 같은가"만**
plan 단계에서 확인한다.

```hcl
data "external" "runtime" {
  program = [abspath("${path.module}/scripts/detect-runtime.sh")]
}

resource "kind_cluster" "this" {
  # ...
  lifecycle {
    precondition {
      condition     = data.external.runtime.result.detected == var.expected_runtime
      error_message = "탐지된 런타임이 expected_runtime과 다르다 ..."
    }
  }
}
```

`scripts/detect-runtime.sh`는 kind 라이브러리와 **같은 순서**(docker → nerdctl →
podman)로 `command -v`를 본다 — 순서가 다르면 이 방어 자체가 거짓 안전감을 준다.

```json
{"detected":"podman"}
```

## 한계 — 이것은 "고정"이 아니라 "조용한 변경 차단"이다

이 precondition이 막는 것과 못 막는 것은 다르다:

| 상황 | precondition 결과 |
| --- | --- |
| Docker Desktop을 설치해 docker가 PATH에 새로 잡힘 | **막는다** — 탐지 결과가 `docker`로 바뀌어 `expected_runtime=podman`과 불일치 → plan 실패 |
| podman 바이너리는 그대로인데 podman machine(VM)이 꺼짐 | **못 막는다** — `command -v podman`은 여전히 성공한다 |

precondition은 **바이너리가 PATH에 있는가**만 본다. 런타임이 **실제로 동작하는가**는
다른 질문이고, 이 방어는 그 질문에 답하지 않는다. "고정"이라고 부르면 틀린
안전감을 준다 — 정확히는 "환경이 조용히 바뀌는 것"만 잡아내는 조기경보다.

## 실측 — Step 9: podman machine을 세워둔 채 재현

```bash
podman machine stop
terraform plan
```

관측한 에러 원문:

```
Error: failed to list nodes: command "podman ps -a --filter label=io.x-k8s.kind.cluster=argocd-study --format '{{.Names}}'" failed with error: exit status 125
```

precondition은 통과했다(podman 바이너리는 여전히 PATH에 있으므로) — 그리고
`kind_cluster.this`의 상태 조회가 그 뒤에서 뒤늦게, 훨씬 불친절한 메시지로 죽었다.
표의 예측과 정확히 일치한다.

### 복구 — 예상보다 한 단계 더 필요했다

`podman machine start`만으로는 부족했다. 머신(VM)을 중지했다 올리면 그 안에서 돌던
kind 노드 **컨테이너 자체**가 `Exited (137)` 상태로 남는다 — VM 재기동이 컨테이너를
자동으로 다시 띄워주지 않는다. 실제로 필요했던 절차:

```bash
podman machine start
# 이 시점에 terraform plan 을 돌리면 다른 에러가 난다:
#   Error: failed to get cluster internal kubeconfig: command
#   "podman exec --privileged argocd-study-control-plane cat /etc/kubernetes/admin.conf"
#   failed with error: exit status 125
podman start argocd-study-control-plane   # 노드 컨테이너를 직접 재기동
terraform plan                             # No changes. 복구 확인
```

**지어내지 않았다** — 두 에러 메시지와 복구 2단계 모두 이 세션에서 실제로 관측한
그대로다.

## 덤 — "대상 0개라 Skipped"를 통과로 읽으면 안 된다

이 스택이 추가되기 전(Task 1~3), `.pre-commit-config.yaml`의 `terraform_tflint` 훅은
`.tf` 파일이 저장소에 0개라 **대상이 없어 매번 Skipped**였다. 그런데 그 훅은 사실
tflint 바이너리가 PATH에 있어야만 도는데, **어느 머신에도 tflint가 설치돼 있지
않았다.** "Skipped"가 초록불처럼 보여 이 구멍이 전혀 드러나지 않았다.

이 디렉터리의 `.tf` 파일이 처음 생기면서 그 구멍이 로컬과 CI 양쪽에서 동시에
터졌다(`ERROR: 'tflint' is required ... but it is not discoverable in the system's
PATH`). 교훈: **"대상 0개라 Skipped"는 "그 검사가 통과했다"가 아니라 "그 검사를
아직 아무도 돌려보지 않았다"는 뜻이다.** 새 파일 종류를 추가할 때는 그 종류를
대상으로 하는 훅이 실제로 도구를 찾아 실행되는지 한 번은 직접 확인해야 한다.

고친 방법: `.pre-commit-config.yaml`의 `terraform_tflint` 훅에
`--hook-config=--tool-version=0.64.0`을 추가해, pre-commit이 시스템 설치에
기대지 않고 **직접 그 버전을 내려받아 캐시**하게 했다 — 클론 직후 상태에서도
작동해야 한다는 기준으로 골랐다(`ci.yml`에 설치 스텝을 추가하는 대안은 CI만
고치고 로컬 클론은 여전히 깨진 채로 둔다).

## 참고

- `tehcyx/terraform-provider-kind`: `github.com/tehcyx/terraform-provider-kind`
- `kubernetes-sigs/kind`: `github.com/kubernetes-sigs/kind`
- 설계 문서 §8 R1 상세: [docs/superpowers/specs/2026-10-04-argocd-study-design.md](https://github.com/Melting-Face/argocd-study/blob/main/docs/superpowers/specs/2026-10-04-argocd-study-design.md)

---

⚠️ 자동 미러됨 — 웹 편집 금지
