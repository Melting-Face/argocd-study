# argocd-study 학습 노트

ArgoCD·Terraform·Helm·Helmfile 네 도구를 한 저장소에서 다루는
**학습·포트폴리오 프로젝트**다. 네 도구는 같은 질문
(**선언을 어디에 두고, 누가 적용하며, 누가 소유하는가**)에 대한
서로 다른 답이라, 따로 공부하지 않고 같이 놓고 비교한다.

이 위키는 그 과정에서 **관측한 것**을 정리하는 곳이다. 설계가 맞았다는
확인보다, **게이트를 통과한 것과 실제로 작동한다는 증거를 혼동한 자리**,
그리고 그것을 어떻게 알아챘는지를 주로 적는다.

> ⚠️ **이 위키는 저장소에서 자동 생성된다.**
> 원본은 [`wiki/`](https://github.com/Melting-Face/argocd-study/tree/main/wiki)에 있고,
> `main`에 push되면 GitHub Actions가 이 위키로 단방향 미러한다.
> **웹에서 편집하면 다음 미러가 덮어쓴다** — 고칠 것이 있으면 저장소에 PR을 보내라.

## 지금 상태

스택 A(kind 클러스터)와 스택 B(ingress-nginx·ArgoCD)를 세우고, 첫 Application
(podinfo)을 커밋만으로 띄워보며 노트 4장이 생겼다. 나머지 구간은 이후 과제가
진행되며 채워진다.

- **ArgoCD 축** — [부트스트랩](argocd-bootstrap.md) →
  [첫 애플리케이션](first-application.md) → 드리프트와 self-heal →
  소스 타입(Helm/Helmfile/plain manifest) → Airflow 배포
- **Terraform·Helm·Helmfile 축** — [kind 위의 Terraform](terraform-on-kind.md),
  [스택 경계와 폭발반경](terraform-stack-boundaries.md), Helm 차트 작성,
  Helmfile과 Terraform의 비교
- **교차 축** — 네 도구의 소유권 경계가 어디서 겹치고 갈리는지

노트가 생기면 이 페이지와 [`_Sidebar`](_Sidebar.md)가 함께 갱신된다 —
`doc-links` 훅이 등재되지 않은 노트를 통과시키지 않는다.

## 이 프로젝트가 궁금하다면

문서의 정본은 **저장소**에 있다. 위키는 그것을 요약하지 않고 별개의 글을 둔다.

| | |
| --- | --- |
| 프로젝트 소개 | [README](https://github.com/Melting-Face/argocd-study#readme) |
| 설계 스펙 | [docs/superpowers/specs/2026-10-04-argocd-study-design.md](https://github.com/Melting-Face/argocd-study/blob/main/docs/superpowers/specs/2026-10-04-argocd-study-design.md) |
| 구현 계획 | [docs/superpowers/plans/2026-10-04-argocd-study-phase1.md](https://github.com/Melting-Face/argocd-study/blob/main/docs/superpowers/plans/2026-10-04-argocd-study-phase1.md) |

## 축

```text
Terraform → kind 클러스터 → ArgoCD(Helm) → ArgoCD Application(Git) → Airflow
                                         ↳ Helmfile 로 같은 대상을 다시 선언 (비교)
```

컴퓨트는 **kind(Podman 위)**, 오케스트레이션 대상 워크로드는 **Airflow**다.
적용 주체가 사람인 도구(Terraform·Helm·Helmfile)와 컨트롤러인 도구(ArgoCD)를
나란히 두고 "언제 무엇을 쓰는가"를 노트로 쌓는다.
