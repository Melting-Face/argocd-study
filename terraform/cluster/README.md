# terraform/cluster — substrate 스택

이 디렉터리는 **substrate**(클러스터가 올라가는 바닥)를 소유한다. 지금은
`kind/` 하나뿐이지만, **다른 substrate 는 형제 디렉터리로 추가한다** —
`terraform/cluster/k3d/`, `terraform/cluster/existing/` 등. `terraform/cluster/kind/`를
고쳐서 다른 바닥을 흉내 내지 않는다.

## 계약

`terraform/platform`은 이 디렉터리의 **outputs 4개**만 variable 기본값으로 받는다
(`terraform_remote_state`를 쓰지 않는다 — 이유는
[`wiki/terraform-stack-boundaries.md`](../../wiki/terraform-stack-boundaries.md) 참고):

| output | 타입 | 의미 |
| --- | --- | --- |
| `kubeconfig_path` | string | kubeconfig 파일의 절대 경로 |
| `kube_context` | string | kubeconfig 안의 context 이름 |
| `ingress_profile` | string | ingress-nginx values 파일을 고르는 키 (`"kind"` \| `"loadbalancer"`) |
| `storage_class` | string | 이 substrate 가 기본 제공하는 StorageClass 이름 |

**outputs 계약만 맞추면 `platform`은 안 바뀐다.** 새 substrate 구현을 추가할 때
`kind/`의 `versions.tf`·`variables.tf`·`main.tf`·`outputs.tf` 구조를 그대로 본떠
같은 이름·같은 타입의 output 4개만 내보내면 된다.

## 이 구현(`kind/`)이 아는 것

- kind 클러스터, 노드 이미지·레이블, 호스트 포트 매핑, kubeconfig 까지만 소유한다.
  클러스터 **안의** 어떤 것도 소유하지 않는다(설계 §3-1).
- `tehcyx/kind` 프로바이더는 런타임(docker/nerdctl/podman)을 선택하지 않는다 —
  선택은 `kind` 라이브러리의 자동탐지가 한다. `var.expected_runtime` +
  `lifecycle.precondition`으로 그 전제를 "고정"이 아니라 "조용한 변경 차단"으로만
  방어한다. 상세: [`wiki/terraform-on-kind.md`](../../wiki/terraform-on-kind.md).
- 테스트: `tests/validation.tftest.hcl`이 변수 검증(`validation` 블록)을 plan 모드로
  확인한다. 클러스터 생성 없이 `terraform test`로 돈다.

## 사용

```bash
cd terraform/cluster/kind
terraform init
terraform test     # 변수 검증 단위 테스트
terraform apply
kubectl --kubeconfig ~/.kube/argocd-study.config get nodes
```
