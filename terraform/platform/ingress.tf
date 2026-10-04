# ingress-nginx — 클러스터 진입 설비. ArgoCD(Task 6)가 아니라 이 스택(Terraform)이 설치한다
# (spec D3 — 운영 도구가 자기 접근 경로를 자기가 배포하면 self-locking 결함이 생긴다).
#
# 차트 버전 4.15.1(appVersion 1.15.1)은 2026-10-04 ingress-nginx 공식 헬름 레포지토리
# (https://kubernetes.github.io/ingress-nginx)에서 `helm search repo --versions` 로 실측한
# 최신 안정판이다. Chart.yaml 의 kubeVersion 제약은 ">=1.21.0-0" 이고, 이 클러스터 노드는
# v1.35.0(terraform/cluster/kind 의 node_image 실측치)이라 호환된다.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.15.1"
  namespace        = "ingress-nginx"
  create_namespace = true

  # 🔴 wait = true — Task 6(ArgoCD)의 admission webhook 경합(spec R4) 대비. ingress-nginx
  # 가 ValidatingWebhookConfiguration 을 설치하는데, 이 릴리스가 "준비됨"을 보고하기 전에
  # ArgoCD 쪽 Ingress 가 먼저 만들어지면
  # `failed calling webhook "validate.nginx.ingress.kubernetes.io"` 로 실패한다. wait = true 는
  # 컨트롤러 파드가 Ready 가 될 때까지 이 리소스의 apply 를 막아, Task 6 이 depends_on 으로
  # 이 리소스를 참조하면 그 경합이 구조적으로 사라지게 한다.
  wait = true

  values = [file("${path.module}/values/ingress-nginx.${var.ingress_profile}.yaml")]
}
