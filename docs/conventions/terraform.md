# Terraform 규칙

> 이 문서는 `../dagster-study` `docs/conventions/terraform.md`를 이식한 것이다. 원본의 버전 고정·
> `templatefile` 함정·변수 검증 교훈은 **도구 지식이라 그대로 유효**하다. OCI·k3s 등
> 원본 특유의 클라우드 스택 서술은 이 저장소에 해당 스택이 없어 들어내고, 이 저장소의
> **2스택 구조**(`terraform/cluster/kind`·`terraform/platform`)에 맞춰 §1·§4를 다시 썼다.
> 설계 배경은 [설계 문서](../superpowers/specs/2026-10-04-argocd-study-design.md) §3·D1·D5·D6.

## 1. 디렉터리 구조 — 스택 2개, 역할별 표준 파일명

이 저장소는 **`terraform/cluster/kind/`**(substrate — kind 클러스터)와 **`terraform/platform/`**
(ingress-nginx·ArgoCD)로 나뉜다. 한 스택에 합치지 않는 이유는 D1(helm 프로바이더가
`kind_cluster.this.kubeconfig`처럼 apply 시점에야 정해지는 값을 참조하면 plan이 막힌다)이다.

파일은 **역할별 표준 이름**으로 나눈다(추적성 — grep·점프 용이):

- `versions.tf` — `required_version`·`required_providers`(버전 고정)
- `provider.tf` — 프로바이더 설정. **`config_context`를 변수로 고정**한다(아래 §2-1)
- `variables.tf` — 입력 변수(모두 `description`·`type`)
- `outputs.tf` — 출력. `cluster/kind`의 outputs는 **substrate 계약 3개**
  (kubeconfig 경로+context, 호스트 진입점, 기본 StorageClass)를 내보낸다
- 리소스는 관심사별 파일(`ingress.tf`·`argocd.tf` 등)로 분리
- 템플릿은 `<name>.tftpl`로 두고 `templatefile()`로 렌더링한다

스택 간 결합은 **`kubeconfig_path` 문자열 하나뿐**이다. `terraform_remote_state`는 쓰지
않는다 — 쓰는 순간 스택 B의 plan이 스택 A의 state에 묶이고 substrate 교체 가능성이 깨진다
(대가는 경로를 양쪽에 변수 기본값으로 중복 선언하는 것).

## 2. 버전 고정 (latest 금지)

- **프로바이더 버전은 `~>` 범위가 아니라 정확한 버전으로 핀한다**(Global Constraints).
  같은 커밋을 체크아웃하면 같은 프로바이더 버전이 받아져야 재현성이 성립하는데, `~>`는
  패치(또는 마이너) 범위를 열어 둬 "언제 `terraform init`을 실행했는가"에 따라 다른
  버전이 설치될 수 있다. 실제 코드(`terraform/platform/versions.tf`)는 `helm = "3.0.2"`·
  `kubernetes = "2.38.0"`, `terraform/cluster/kind/versions.tf`는 `kind = "0.11.0"`·
  `external = "2.4.2"`로 전부 정확히 고정돼 있다.
  - 🔑 **예외는 `required_version`뿐이다**: `required_version = ">= 1.5.0"`처럼 하한만
    둔다. 이건 Terraform CLI 자체의 버전이라 "이 설정을 처리할 수 있는 최소 기능
    집합"만 보장하면 되고, 실행 환경(로컬 CLI·CI 러너)마다 실제 설치된 버전이 다른
    것을 전제하기 때문이다 — 프로바이더처럼 "정확히 그 버전의 바이너리를 내려받아
    고정"하는 대상이 아니다.
- **`.terraform.lock.hcl`은 커밋 대상**이다(프로바이더 해시 고정 → 재현성). state·tfvars와
  달리 추적 대상이다.
- **`tehcyx/kind`는 커뮤니티 프로바이더**다(R11) — 버전을 더 좁게 핀하고, 끊기면 substrate
  계약 덕에 `k3d`/`existing` 구현으로 교체한다(설계 D6).
- `hashicorp/helm`은 `3.0.2`로 핀한다(argo-cd 차트 10.9.6 / ArgoCD v3.5.3 기준 확인이
  3.0 라인을 전제로 했으므로, 3.x 최신(3.3.0대)이 아니라 3.0 라인의 최신 패치를 쓴다).

### 2-1. `config_context`는 반드시 고정한다

Helm·Kubernetes 프로바이더가 kubeconfig의 **현재 컨텍스트**에 암묵 의존하면, 로컬에 클러스터가
여럿일 때(`lakehouse`·`argocd-study` 등) **다른 클러스터에 apply하는 사고**가 조용히 날 수 있다.

```hcl
provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path   # 정적 경로. kind_cluster 의 output 을 참조하지 않는다
    config_context = var.kube_context      # "kind-argocd-study" 처럼 고정 — 현재 컨텍스트에 기대지 않는다
  }
}
```

`kubeconfig_path`·`kube_context`는 `cluster/kind`의 output이지만, **스택 B의 변수 기본값으로
다시 선언**한다(§1의 "경로 중복"이 이 자리다) — `terraform_remote_state`를 피한 대가다.

## 3. 포매터·검증 고정

- **`.tf` 포매터는 `terraform fmt`(2-space)로 고정**한다. `.tf`는 전역 4칸 규칙의 **예외**다.
- 커밋 전 게이트(pre-commit): `terraform fmt -check -recursive` + `tflint`
  (규칙은 [`.tflint.hcl`](../../.tflint.hcl)). `terraform validate`는 **CI 잡**에서
  `-backend=false init` 뒤에 돈다 — 로컬 훅에 넣으면 `.terraform/`(`.gitignore` 대상) 부재로
  커밋이 프로바이더 레지스트리 가용성에 묶인다([`.pre-commit-config.yaml`](../../.pre-commit-config.yaml)
  terraform_tflint 훅 주석 참고).
- **`templatefile` 주의**: `.tftpl`에서 `$${...}`가 아닌 `${expr}`는 모두 보간식으로 평가된다.
  주석·문서 문자열에도 `${...}` 리터럴을 쓰지 않는다(파싱 실패). 쉘 변수는 브레이스 없는
  `$VAR`로 쓴다(`argocd.yaml.tftpl`이 대상이다).

## 4. 비밀·상태는 커밋 금지 (참조 주입)

- **커밋 금지**: `*.tfstate`·`*.tfstate.backup`·`terraform.tfvars`·회수 kubeconfig
  (`~/.kube/argocd-study.config`는 홈 디렉터리 경로라 애초에 저장소 밖이지만, `.gitignore`로
  재확인한다).
- `var.repo_url`처럼 민감하지 않은 입력도 **변수로 선언**한다(하드코딩 금지) — 평문 중복이
  불가피한 곳(`gitops/apps/*.yaml`)의 불일치는 CI가 잡는다(설계 D4).
- 이 저장소는 **클라우드 자격증명이 없다**(로컬 kind) — 원격 backend·state 암호화는 검토
  대상에서 제외한다(설계 §2-2 "remote backend/workspace/Terragrunt" 제외 사유와 같다).

## 5. 변수·기본값

- 모든 입력은 `variable`로 선언하고 `description`·`type`을 명시한다.
- **되돌리기 어려운 입력은 `validation` 블록으로 막는다** — 예: `var.ingress_profile`이
  `kind`/`loadbalancer` 밖의 값이면 plan 단계에서 실패해야, 오타가 조용히 잘못된 values
  파일을 고르지 않는다. 주석이 아니라 **실행 시점 검증**이어야 하는 이유는 원본과 같다
  (원본은 클라우드 과금 상한이 근거였고, 이 저장소는 **substrate 오선택**이 근거다).

## 6. 프로비저닝은 선언적으로

- kind 노드 구성(labels·kubeadm_config_patches·extraPortMappings)은 **선언형 스키마**로
  표현한다(`tehcyx/kind`가 지원). `provisioner "remote-exec"`는 쓰지 않는다 — 이 저장소에는
  대상이 없지만, 쓰게 되면 재현성이 provisioner 실행 순서에 묶인다.

## 7. 네트워크·노출 최소화

- Ingress는 필요한 호스트·포트만 연다. 상세 규칙은 [`k8s.md`](k8s.md) §6·§7과 정합한다.
- `server.insecure=true`(ArgoCD) 같은 완화 설정은 **로컬 학습 환경이라는 전제**를 코드 옆
  주석으로 남긴다 — 운영 환경 템플릿으로 복사되지 않도록.

## 참고

- Terraform 문서: https://developer.hashicorp.com/terraform/docs
- 스타일 가이드: https://developer.hashicorp.com/terraform/language/style
- `terraform fmt`: https://developer.hashicorp.com/terraform/cli/commands/fmt
- state 민감정보: https://developer.hashicorp.com/terraform/language/state/sensitive-data
- `tehcyx/kind` 프로바이더: https://registry.terraform.io/providers/tehcyx/kind/latest/docs
- `hashicorp/helm` 프로바이더: https://registry.terraform.io/providers/hashicorp/helm/latest/docs
- `../dagster-study` `docs/conventions/terraform.md` — 버전 고정·`templatefile` 함정·
  변수 검증 교훈의 원출처(로컬 저장소, 실측 기반)
