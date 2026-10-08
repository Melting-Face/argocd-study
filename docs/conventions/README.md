# 코딩·운영 컨벤션 (conventions)

이 저장소의 **규칙 정본**이 모여 있는 디렉터리다. 문서 6개 중 5개는
`../dagster-study`에서 **필요한 절만 선별 이식**했고, `agents.md`는 2026-10-08 신설이다 — 무엇을 덜어내고 무엇을 남겼는지는
각 문서 머리말에 적혀 있다. 배경은
[설계 문서](../superpowers/specs/2026-10-04-argocd-study-design.md) §7(이식 목록).

[`AGENTS.md`](../../AGENTS.md)·[`CLAUDE.md`](../../CLAUDE.md)는 이 디렉터리를 가리키는
요약/인덱스이고, 규칙의 **정본은 여기**다.

## 목차

| 문서 | 다루는 것 | 대표 규칙 |
| --- | --- | --- |
| [`general.md`](general.md) | 언어·들여쓰기·파일 명명·비밀정보 | 주석 한국어·식별자 영어 · `.tf`는 2칸 예외 · 영문 kebab-case |
| [`git.md`](git.md) | git 워크플로 | `main` 단일 브랜치 · Conventional Commits · **커밋이 곧 공개**(R9) |
| [`terraform.md`](terraform.md) | Terraform (2스택) | `cluster/kind`·`platform` 분리 · 버전 고정 · **`config_context` 고정** |
| [`k8s.md`](k8s.md) | Kubernetes | requests/limits·probe 필수 · RBAC 최소권한 · kind 포트는 생성 시점에만 |
| [`publishing.md`](publishing.md) | 위키(`wiki/`) 발행 | 평평 구조·프론트매터 금지 · 관측 안 된 출력을 예시로 안 만든다 |
| [`agents.md`](agents.md) | 서브에이전트·SDD 운용 | 태스크 `main`/`sdd` 분류 · fix round 2회 · 구현자 브리프에 읽을 파일 목록 |

## 읽는 순서

1. 처음이면 [`general.md`](general.md) → 작업할 영역 문서 1개.
2. 위키에 쓴다면 [`publishing.md`](publishing.md)를 먼저 읽는다 — 평평 구조·링크 표기는
   `doc-lint`가 기계로 검사한다.
3. Terraform·K8s 작업은 둘 다 읽는다 — 이 저장소는 두 층의 경계가 설계의 핵심이다
   (설계 문서 §3 "한 리소스는 한 주인만").

## 원칙

- **정본은 한 곳.** 다른 문서는 요약하고 이 디렉터리를 링크한다.
- **도구로 강제 가능한 규칙의 정본은 도구 설정 파일**이다(`.gitlint`·`.tflint.hcl`·
  `.pre-commit-config.yaml` 등). 문서는 그 설정의 **의도**를 설명할 뿐 값을 중복 정의하지
  않는다.
- **코드·설정과 문서가 어긋나면 코드/설정이 사실**이다. 문서를 코드에 맞춘다(반대 아님).
- 이식한 교훈은 **출처를 밝힌다** — `../dagster-study`의 실측을 이 저장소가 관측한 사실처럼
  적지 않는다. 각 문서 끝 "참고" 절이 그 출처다.
