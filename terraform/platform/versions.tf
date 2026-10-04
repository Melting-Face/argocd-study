# 스택 B (platform) — ingress-nginx. Task 6 에서 ArgoCD 가 추가된다.
# required_version·프로바이더 버전은 전부 정확히 고정한다 (latest·범위 금지, Global Constraints).
#
# 버전은 registry.terraform.io 에서 실측해 정확히 고정했다(2026-10-04, Global Constraints —
# ~> 범위 표기 금지).
# - hashicorp/helm 3.0.2: 3.x 최신은 3.3.0 이지만, docs/conventions/terraform.md 가 명시한
#   "argo-cd 차트 10.9.6 / ArgoCD v3.5.3 기준 확인"이 3.0 라인을 전제로 한 검증이라
#   3.0.x 중 최신 패치(3.0.2)로 고정한다. 이 파일은 Task 6(ArgoCD)도 그대로 쓴다.
# - hashicorp/kubernetes 2.38.0: brief 가 명시한 ~> 2.38 라인의 최신판. 3.x 로 건너뛰면
#   리소스 스키마 변경 영향 범위를 이 태스크에서 검증할 수 없어 보수적으로 2.38.0 을 쓴다.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "3.0.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.38.0"
    }
  }
}
