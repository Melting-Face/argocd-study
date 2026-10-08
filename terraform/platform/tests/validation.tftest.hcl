# 변수 검증 단위 테스트 — 전부 plan 모드라 실제 헬름 릴리스를 만들지 않는다.
# TDD 순서: 이 파일이 먼저 존재하고(red), variables.tf 가 생기면 통과한다(green).
# spec §5 — 되돌리기 어려운 입력(ingress_profile 오선택·repo_url 프로토콜 오선택)은
# validation 블록으로 plan 단계에서 막는다.

run "reject_unknown_ingress_profile" {
  command = plan

  variables {
    ingress_profile = "traefik"
  }

  expect_failures = [var.ingress_profile]
}

run "repo_url_must_be_https_git" {
  command = plan

  variables {
    repo_url = "git@github.com:Melting-Face/argocd-study.git"
  }

  expect_failures = [var.repo_url]
}

# var.apps — ApplicationSet 이 만들 앱 목록의 입력 검증(spec §4-2). 이름이 곧 Application 이름이자
# 중복 시 조용히 덮어쓰이는 키라 plan 단계에서 막는다.
run "apps_reject_duplicate_names" {
  command = plan

  variables {
    apps = [
      { name = "podinfo", path = "gitops/charts/podinfo", namespace = "podinfo" },
      { name = "podinfo", path = "gitops/charts/airflow", namespace = "airflow" },
    ]
  }

  expect_failures = [var.apps]
}

run "apps_reject_path_outside_gitops_charts" {
  command = plan

  variables {
    apps = [
      { name = "podinfo", path = "gitops/manifests/podinfo", namespace = "podinfo" },
    ]
  }

  expect_failures = [var.apps]
}

run "apps_reject_invalid_name" {
  command = plan

  variables {
    apps = [
      { name = "Pod_Info", path = "gitops/charts/podinfo", namespace = "podinfo" },
    ]
  }

  expect_failures = [var.apps]
}
