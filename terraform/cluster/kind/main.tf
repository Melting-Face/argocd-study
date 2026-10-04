# 스택 A — kind 클러스터(substrate). 클러스터 "안"의 어떤 것도 소유하지 않는다
# (소유권 경계는 spec §3-1 표 참고 — 노드·레이블·포트매핑·kubeconfig 까지만 이 스택 소관).

# kind 가 실제로 어떤 런타임을 선택할지 "탐지"한다. var.expected_runtime 과 대조하기 위한
# 입력일 뿐, 이 데이터 소스 자체가 런타임을 고르지는 않는다(그건 kind 라이브러리 내부 로직이다).
data "external" "runtime" {
  program = [abspath("${path.module}/scripts/detect-runtime.sh")]
}

resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = var.node_image
  wait_for_ready  = true
  kubeconfig_path = pathexpand(var.kubeconfig_path)

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # ingress-nginx(kind provider 매니페스트)가 이 레이블로 자신을 어느 노드에
      # 스케줄할지 정한다(nodeSelector) — platform 스택이 참조하므로 여기서 박아둔다.
      labels = {
        "ingress-ready" = "true"
      }

      # 🔴 extra_port_mappings 는 클러스터 "생성 시점"에만 지정할 수 있다 — kind 노드가
      #   컨테이너라 사후에 공개 포트를 추가할 방법이 없다(spec D2). 포트를 바꾸려면
      #   클러스터를 재생성해야 한다.
      extra_port_mappings {
        container_port = 80
        host_port      = var.http_host_port
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = var.https_host_port
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
    }
  }

  lifecycle {
    precondition {
      # 🔴 이것은 "고정"이 아니라 "조용한 변경 차단"이다. tehcyx/kind 는 런타임 옵션을
      # kind 라이브러리에 넘기지 않으므로(kind/resource_cluster.go), 실제 선택은
      # DetectNodeProvider()의 docker -> nerdctl -> podman 자동탐지가 결정한다.
      # KIND_EXPERIMENTAL_PROVIDER 환경변수는 kind **CLI** 만 보고 이 라이브러리 경로는
      # 보지 않는다 — 즉 이 변수로 "원하는 런타임을 강제"할 수단이 없다.
      # 이 precondition 은 "지금 PATH 에서 탐지되는 런타임이 우리가 알던 값과 같은가"만
      # plan 단계에서 확인해, Docker Desktop 설치 등으로 자동탐지 결과가 조용히 바뀌는
      # 것을 막는다. 바이너리 존재만 보므로 "런타임이 실제로 동작하는가"는 검증하지
      # 못한다(podman machine 이 중지돼 있어도 이 precondition 은 통과한다 — Step 9 관측).
      condition     = data.external.runtime.result.detected == var.expected_runtime
      error_message = "탐지된 런타임(${data.external.runtime.result.detected})이 expected_runtime(${var.expected_runtime})과 다르다. kind 라이브러리의 자동탐지 순서(docker > nerdctl > podman)가 조용히 바뀌었을 수 있다 — KIND_EXPERIMENTAL_PROVIDER 로는 되돌릴 수 없다(R1). var.expected_runtime 을 의도적으로 바꾸는 것이 아니라면 PATH 에서 어떤 런타임이 새로 잡혔는지 확인한다."
    }
  }
}
