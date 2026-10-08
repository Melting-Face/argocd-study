# ArgoCD — argo-cd 차트 10.9.6(ArgoCD v3.5.3)을 argocd 네임스페이스에 설치한다(spec §3-1 —
# 스택 B 가 소유하는 것은 "argocd 네임스페이스 · ArgoCD 자체 · 앱 등록 진입점 1개"뿐이고,
# 실제 앱은 ArgoCD 가 소유한다). 진입점 릴리스는 이 릴리스와 분리한다 — Application CRD 가
# 이 릴리스에 들어 있어 같은 helm install 로 CR 을 함께 만들 수 없기 때문이다
# (values/argocd.yaml.tftpl 의 주석 참고).
#
# 🔴 D5 — kubernetes_manifest 를 쓰지 않는다. hashicorp/kubernetes 의 kubernetes_manifest 는
# plan 시점에 API 서버에 붙어 리소스 스키마를 조회하는데, Application CRD 는 helm_release 가
# 설치하므로 최초 plan 에서는 CRD 가 아직 없어 plan 자체가 죽는다. plan 은 apply 이전이라
# depends_on 으로도 풀리지 않는다(spec D5/R6). helm_release 는 plan 시점에 API 서버 스키마를
# 조회하지 않으므로(values 는 Terraform 입장에서 불투명한 문자열 blob) 이 문제가 없다.
resource "helm_release" "argo_cd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.6" # ArgoCD v3.5.3 — docs/conventions/terraform.md 가 못박은 검증 버전
  namespace        = "argocd"
  create_namespace = true

  # 🔴 R4 — ingress-nginx admission webhook 경합 대비. ingress-nginx 가 설치하는
  # ValidatingWebhookConfiguration 이 준비되기 전에 ArgoCD 의 Ingress 가 먼저 만들어지면
  # `failed calling webhook "validate.nginx.ingress.kubernetes.io"` 로 apply 가 실패한다.
  # depends_on 으로 순서를, wait = true(ingress.tf)로 "준비됨"을 둘 다 강제한다.
  depends_on = [helm_release.ingress_nginx]

  # 컨트롤러 파드 등이 Ready 가 될 때까지 apply 를 막는다 — 완료 판정이 "apply 직후 바로
  # 접근 가능"을 검증하려면 이 대기가 필요하다. 이 릴리스 뒤에 붙는 별도 릴리스(appset)가 이 wait 에
  # 기대 Application CRD 존재를 전제한다.
  wait = true

  values = [templatefile("${path.module}/values/argocd.yaml.tftpl", {})]
}
