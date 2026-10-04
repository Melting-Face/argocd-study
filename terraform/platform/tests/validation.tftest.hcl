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
