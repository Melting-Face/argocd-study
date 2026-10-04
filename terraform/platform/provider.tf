# 프로바이더 설정. config_context 를 반드시 고정한다(docs/conventions/terraform.md §2-1).
#
# 🔴 config_context 를 비우면 kubeconfig 의 "현재 컨텍스트"를 따라간다. 이 podman machine 에는
# 별도 kind 클러스터 lakehouse 가 공존하고(실측: kubectl config get-contexts 의 CURRENT 가
# kind-lakehouse 였다), 다른 세션이 current-context 를 바꿔두면 이 스택이 조용히 엉뚱한
# 클러스터에 apply 할 수 있다 — dagster-study 가 실측으로 남긴 교훈이다.
provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kube_context
  }
}

# hashicorp/kubernetes 는 이 스택에서 아직 리소스로 쓰지 않는다(D5 — kubernetes_manifest 대신
# Helm extraObjects 를 쓰기로 했다). versions.tf 에 선언만 해 Task 6 이 이 provider 를 쓸 때
# 버전 고정을 다시 결정하지 않도록 한다. 실제 provider "kubernetes" 설정 블록은 Task 6 이
# 필요해지는 시점에 추가한다(선언이 사용보다 앞선다는 원칙은 지키되, 쓰지 않는 provider 설정
# 블록을 미리 만들어 검증되지 않은 기본값을 심어두지 않는다).
