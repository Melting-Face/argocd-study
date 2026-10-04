# 변수 검증 단위 테스트 — 전부 plan 모드라 실제 클러스터를 만들지 않는다.
# TDD 순서: 이 파일이 먼저 존재하고(red), variables.tf/main.tf 가 생기면 통과한다(green).
# spec Global Constraints: 호스트 포트 8080/8443 은 기존 lakehouse 클러스터가 점유하므로 금지.

run "reject_lakehouse_ports" {
  command = plan

  variables {
    http_host_port = 8080 # 기존 lakehouse 클러스터가 점유
  }

  expect_failures = [var.http_host_port]
}

run "reject_unknown_runtime" {
  command = plan

  variables {
    expected_runtime = "containerd"
  }

  expect_failures = [var.expected_runtime]
}

run "defaults_are_the_spec_values" {
  command = plan

  assert {
    condition     = var.cluster_name == "argocd-study" && var.http_host_port == 8081 && var.https_host_port == 8444
    error_message = "기본값이 spec Global Constraints 와 다르다"
  }
}
