# 입력 변수 — 되돌리기 어렵거나 환경과 충돌하는 값은 validation 블록으로 plan 단계에서 막는다
# (docs/conventions/terraform.md §5).
#
# kubeconfig_path·kube_context·ingress_profile·storage_class 4개는 terraform/cluster/kind 의
# output 과 "이름·타입"이 같다 — substrate 계약(spec §3-2)이다. terraform_remote_state 를
# 쓰지 않기로 했으므로(spec D1) 이 네 값은 양쪽에 중복 선언된다. 한쪽을 고치고 다른 쪽을
# 안 고치면 조용히 어긋난다 — 기계가 안 잡아주는 몇 안 되는 수동 책임 중 하나다
# (wiki/terraform-stack-boundaries.md).

variable "kubeconfig_path" {
  description = <<-EOT
    kind 가 쓴 kubeconfig 파일의 절대 경로. terraform/cluster/kind 의 output
    "kubeconfig_path" 와 같은 이름·같은 값이어야 한다(substrate 계약, terraform_remote_state
    를 쓰지 않는 대가로 양쪽에 중복 선언한다). pathexpand()로 ~ 를 홈 디렉터리로 확장한다
    (provider.tf).
  EOT
  type        = string
  default     = "~/.kube/argocd-study.config"
}

variable "kube_context" {
  description = <<-EOT
    kubeconfig 안에서 쓸 context 이름. terraform/cluster/kind 의 output "kube_context" 와
    같은 이름·같은 값이어야 한다(substrate 계약, terraform_remote_state 를 쓰지 않는 대가로
    양쪽에 중복 선언한다). 🔴 비우면 helm/kubernetes 프로바이더가 kubeconfig 의 현재
    컨텍스트를 따라간다 — 이 podman machine 에 공존하는 다른 kind 클러스터(lakehouse)에
    조용히 apply 하는 사고로 이어질 수 있다(docs/conventions/terraform.md §2-1).
  EOT
  type        = string
  default     = "kind-argocd-study"
}

variable "ingress_profile" {
  description = <<-EOT
    ingress-nginx values 파일을 고르는 키. terraform/cluster/kind 의 output
    "ingress_profile" 과 같은 이름·같은 값이어야 한다(substrate 계약, terraform_remote_state
    를 쓰지 않는 대가로 양쪽에 중복 선언한다). "kind" | "loadbalancer" 중 하나가 아니면
    존재하지 않는 values/ingress-nginx.<profile>.yaml 을 참조해 apply 가 실패한다 —
    오선택을 plan 단계에서 막는다.
  EOT
  type        = string
  default     = "kind"

  validation {
    condition     = contains(["kind", "loadbalancer"], var.ingress_profile)
    error_message = "ingress_profile 은 \"kind\" 또는 \"loadbalancer\" 중 하나여야 한다 — 그 밖의 값은 values/ingress-nginx.<profile>.yaml 파일이 존재하지 않아 apply 가 실패한다."
  }
}

# substrate 계약 4개 중 하나라 Task 5 는 아직 참조하지 않지만, "계약을 온전히 받는다"는
# 것 자체가 이 스택의 역할이라 미사용이어도 선언해 둔다(Task 6 이전에 PVC 를 쓰는 리소스가
# 없다). Task 6 이 참조를 추가하면 이 ignore 주석은 지운다.
# tflint-ignore: terraform_unused_declarations
variable "storage_class" {
  description = <<-EOT
    이 substrate 가 기본 제공하는 StorageClass 이름. terraform/cluster/kind 의 output
    "storage_class" 와 같은 이름·같은 값이어야 한다(substrate 계약, terraform_remote_state
    를 쓰지 않는 대가로 양쪽에 중복 선언한다). 이 스택(Task 5)은 아직 쓰지 않지만, Task 6 이
    Airflow 등 PVC 가 필요한 워크로드를 다루기 전에 선언을 먼저 맞춰 둔다.
  EOT
  type        = string
  default     = "standard"
}

# brief 요구사항 — Task 6(argocd.tf)이 쓸 repo_url 을 "선언이 사용보다 앞선다" 원칙에 따라
# 여기서 먼저 선언하고 validation 을 테스트로 고정한다. Task 6 이 참조를 추가하면 이 ignore
# 주석은 지운다.
# tflint-ignore: terraform_unused_declarations
variable "repo_url" {
  description = <<-EOT
    ArgoCD root Application 이 추적할 Git 저장소 URL. 이 스택(Task 5)은 쓰지 않지만
    Task 6(argocd.tf)이 쓰므로 선언을 여기서 먼저 고정한다(선언이 사용보다 앞선다).
    HTTPS 여야 한다 — ArgoCD 가 무인증 public fetch 를 하려면 SSH(git@...) 키 자격증명
    없이 접근 가능해야 하기 때문이다.
  EOT
  type        = string
  default     = "https://github.com/Melting-Face/argocd-study.git"

  validation {
    condition     = startswith(var.repo_url, "https://")
    error_message = "repo_url 은 https:// 로 시작해야 한다 — ArgoCD 가 무인증 public fetch 를 하므로 git@ 형태의 SSH URL 은 쓸 수 없다."
  }
}

# cluster 스택과 값이 일치해야 하는 중복 변수. 이 스택의 리소스는 이 포트로 직접 트래픽을
# 보내지 않고(포트 매핑은 cluster 스택 소관), Task 6 의 argocd_url output 이 참조한다.
# Task 6 이 참조를 추가하면 이 ignore 주석은 지운다.
# tflint-ignore: terraform_unused_declarations
variable "http_host_port" {
  description = <<-EOT
    컨트롤 판정(terraform plan/apply 완료 후 curl)에 쓰는, 호스트에서 ingress-nginx 로
    들어가는 HTTP 포트. terraform/cluster/kind 의 같은 이름 변수(extra_port_mappings 의
    실제 호스트 포트)와 값이 일치해야 한다 — 이 스택은 그 포트로 트래픽을 보내지 않지만
    (포트 매핑 자체는 cluster 스택 소관), Task 6 의 argocd_url output 이 이 값으로 URL 을
    조립한다. terraform_remote_state 를 쓰지 않는 대가로 양쪽에 중복 선언한다.

    🔴 어긋나면 무슨 일이 나는가: cluster 스택이 실제로 연 호스트 포트(예: 8081)와
    이 값(예: 기본값을 바꾸지 않아 생긴 8082 같은 불일치)이 다르면, Task 6 의
    argocd_url output 은 "조용히 틀린 포트"로 URL 을 조립한다. 사용자는
    `connection refused`만 보고, 원인이 "두 스택의 변수 불일치"라는 걸 URL 문자열만
    봐서는 알 수 없다. 게다가 kind 의 extra_port_mappings 는 클러스터 **생성 시점**에만
    정할 수 있어, cluster 쪽 값을 바로잡으려면 이 변수만 고치는 게 아니라
    **클러스터 재생성**이 필요하다(docs/conventions/k8s.md §8). 이 변수를 바꿀 때는
    반드시 terraform/cluster/kind/variables.tf 의 http_host_port 와 같은 값인지
    먼저 확인한다.
  EOT
  type        = number
  default     = 8081
}
