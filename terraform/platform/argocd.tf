# ArgoCD — argo-cd 차트 10.9.6(ArgoCD v3.5.3)을 argocd 네임스페이스에 설치한다(spec §3-1 —
# 스택 B 가 소유하는 것은 "argocd 네임스페이스 · ArgoCD 자체 · root Application 1개"뿐이고,
# gitops/apps/ 아래 실제 앱은 ArgoCD 가 소유한다). root Application 은 아래 두 번째
# helm_release(root_app)로 분리했다 — 이유는 그 리소스의 주석 참고.
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
  # 접근 가능"을 검증하려면 이 대기가 필요하다. 아래 root_app 이 이 wait 에 기대 CRD 존재를
  # 전제한다.
  wait = true

  values = [templatefile("${path.module}/values/argocd.yaml.tftpl", {})]
}

# root Application 전용 두 번째 릴리스 — charts/root-app/ (로컬 chart, 이 저장소 소유).
#
# 🔴 brief·spec D5 원안은 이 Application 을 argo_cd 릴리스의 extraObjects 에 넣는 것이었다.
# 2026-10-04 이 환경에서 실측한 결과, 그 원안은 **apply 시점에 100% 재현되는 실패**를 낸다:
# argo-cd 차트는 Application CRD 를 Helm 의 특수 crds/ 디렉터리가 아니라 평범한 템플릿으로
# 담고 있어(.Values.crds.install 토글), 같은 helm install 안에서 "CRD" 와 "그 CRD 를 쓰는
# CR(extraObjects 의 Application)"을 함께 만들려 하면 Helm 클라이언트가 매니페스트 전체를
# 리소스 목록으로 빌드하는 단계(RESTMapper 로 GVK 해석)에서 막힌다 — 이 시점엔 아직 CRD 가
# 클러스터에 없다. 에러(helm install 직접 재현, 2회 연속 동일):
#
#   Error: unable to build kubernetes objects from release manifest: resource mapping
#   not found for name: "root" namespace: "argocd" from "": no matches for kind
#   "Application" in version "argoproj.io/v1alpha1"
#   ensure CRDs are installed first
#
# 재시도해도 네임스페이스조차 생성되지 않고 같은 에러로 즉시 실패한다(부분 생성 없음,
# 멱등하게 재현됨) — "같은 릴리스면 CRD 와 함께 적용되어 순서 문제가 사라진다"는 근거는
# Terraform plan 시점 문제(kubernetes_manifest)에는 맞지만 Helm apply 시점의 CRD/CR 동시
# 설치 문제에는 적용되지 않는다. 상세 근거는 values/argocd.yaml.tftpl 의 주석과
# wiki/argocd-bootstrap.md 에도 남겼다.
#
# ⇒ 별도 helm_release 로 쪼개고 depends_on + wait = true 로 "argo_cd 릴리스가 완전히 끝난
# 뒤"에만 이 릴리스가 적용되게 한다 — 그 시점엔 Application CRD 가 이미 클러스터에 있다.
# kubernetes_manifest 는 여전히 쓰지 않는다(D5 의 핵심 — plan 시점 스키마 조회 문제는
# 그대로 피한다). 이 조합("Helm 릴리스 2개 + depends_on")이 이 환경에서 실제로 동작을
# 확인한 방식이다.
resource "helm_release" "root_app" {
  name       = "root-app"
  chart      = "${path.module}/charts/root-app"
  namespace  = "argocd"
  depends_on = [helm_release.argo_cd]
  wait       = true

  set = [
    {
      name  = "repoUrl"
      value = var.repo_url
    }
  ]
}
