# tflint 설정.
# Task 1 시점엔 저장소에 .tf 파일이 0개다 — 지금 당장 적용 대상은 없고,
# Task 4 에서 terraform 스택이 생기면 이 설정이 적용된다.
# `terraform` 플러그인(tflint 번들 내장)의 기본(recommended) 규칙셋만 켠다(brief 지정 — 커스텀 룰 추가는 범위 밖).
plugin "terraform" {
    enabled = true
    preset  = "recommended"
}
