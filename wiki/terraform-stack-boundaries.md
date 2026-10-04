# Terraform 스택 경계 — 왜 2개로 나눴는가

`terraform/cluster/kind`와 `terraform/platform`을 한 스택으로 합치지 않은 이유,
그 대가로 치른 것, 그리고 "그럼 `terraform_remote_state`로 이으면 되지 않나"를
안 쓴 이유를 적는다.

## 1스택이면 생기는 문제 — provider chaining이 plan을 죽인다

`kind_cluster`와 `helm_release`를 한 스택에 두면 이렇게 된다:

```hcl
# 한 스택에 다 넣었다고 가정
resource "kind_cluster" "this" { ... }

provider "helm" {
  kubernetes {
    config_path = kind_cluster.this.kubeconfig_path   # apply 시점에야 정해지는 값
  }
}

resource "helm_release" "ingress_nginx" { ... }
```

`kind_cluster.this.kubeconfig_path`는 **apply가 끝나야 값이 생기는 출력**이다.
그런데 `provider` 블록은 **plan 단계에서 평가**된다 — Terraform이 리소스 그래프를
그리기도 전에 프로바이더를 구성해야 하기 때문이다. 그 결과 `terraform plan`
자체가 "클러스터가 아직 없는데 거기 붙을 helm 프로바이더를 어떻게 구성하냐"는
순환으로 막힌다.

리터럴 경로(`kubeconfig_path = "~/.kube/argocd-study.config"`)로 고정하고
`depends_on`을 걸면 plan은 우회되지만, 이번엔 **destroy 순서**에서 다시 깨진다 —
같은 state 안에 있는 리소스라 Terraform이 삭제 순서를 그래프로 풀려 하고,
클러스터가 사라지면 그 안의 helm 릴리스를 "읽을" 방법이 없어진다.

## 2스택 분리로 해소

→ **`cluster`(substrate) / `platform`(ingress-nginx·ArgoCD) 2스택.**
`cluster`가 먼저 `apply`되어 kubeconfig 파일이 디스크에 실제로 존재한 뒤에야
`platform`이 그 "정적 경로 문자열"을 변수로 받아 `apply`된다. 두 스택은 서로
다른 state를 갖고, provider 평가 시점에 서로의 그래프를 참조하지 않는다 —
그래서 순환이 원천적으로 생기지 않는다.

## 폭발반경

```
cluster 스택 state 손상       -> 클러스터만 영향, platform state 는 무사
platform 스택 state 손상      -> ingress-nginx/ArgoCD 만 영향, 클러스터는 무사
```

한 state 파일이 깨지면(수동 편집 실수, lock 충돌, provider 버그) 그 피해가
스택 경계를 넘지 않는다. 1스택이었다면 state 하나가 전부를 들고 있어, 작은
실수(예: `terraform state rm` 대상 오타)가 클러스터까지 끌고 내려갈 수 있다.

## `terraform_remote_state`를 안 쓴 이유와 그 대가

`terraform_remote_state`로 `cluster`의 outputs를 `platform`이 직접 읽는 방법도
있었다. 쓰지 않은 이유:

- `terraform_remote_state`를 쓰는 순간 `platform`의 `plan`이 `cluster`의 **state
  파일**에 묶인다 — state 파일 형식·백엔드 설정·접근 권한까지 결합이 번진다.
- substrate를 교체할 가능성(D6 — kind 대신 k3d나 원격 k3s)을 깨뜨린다.
  `remote_state`는 "그 state를 만든 모듈이 무엇인지"까지 암묵적으로 안다.
  substrate 구현을 형제 디렉터리로 바꿔치기해도 `platform`이 안 바뀌려면,
  `platform`은 애초에 "값 4개"만 알아야지 "그 값을 누가 어떤 state로 냈는지"를
  알면 안 된다.

**대가**: `kubeconfig_path`·`kube_context` 같은 값을 `cluster`의 output과
`platform`의 variable 기본값, **양쪽에 중복 선언**해야 한다. 한쪽을 고치고
다른 쪽을 안 고치면 조용히 어긋난다 — 이 불일치는 기계가 안 잡아준다(이
저장소에서 사람이 지는 몇 안 되는 수동 책임 중 하나다).

## substrate 계약 4개 (이 분리가 지키려는 것)

`terraform/cluster/kind`가 내보내고 `terraform/platform`이 variable로 받는
값은 이 4개뿐이다(상세: [terraform-on-kind](terraform-on-kind.md),
[`terraform/cluster/README.md`](https://github.com/Melting-Face/argocd-study/blob/main/terraform/cluster/README.md)):

| output | 타입 | 의미 |
| --- | --- | --- |
| `kubeconfig_path` | string | kubeconfig 파일의 절대 경로 |
| `kube_context` | string | kubeconfig 안의 context 이름 |
| `ingress_profile` | string | ingress-nginx values 파일을 고르는 키 |
| `storage_class` | string | 기본 StorageClass 이름 |

결합면이 이 4개 문자열/값으로 좁혀져 있다는 것 자체가 "2스택으로 나눴다"는
선언보다 더 강한 증거다 — `platform`의 `variables.tf`를 열어보면 그 결합이
정확히 몇 줄인지 바로 보인다.

---

⚠️ 자동 미러됨 — 웹 편집 금지
