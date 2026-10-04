# argocd-study

ArgoCD·Terraform·Helm·Helmfile 네 도구를 **한 저장소에서 같이** 다루는 학습·포트폴리오
프로젝트다. 네 도구는 같은 질문 — **"선언을 어디에 두고, 누가 적용하며, 누가 소유하는가"**
— 에 대한 서로 다른 답이라, 따로 공부하지 않고 나란히 놓고 비교한다. 정본은
[설계 문서](docs/superpowers/specs/2026-10-04-argocd-study-design.md)다.

- 컴퓨트: **kind on Podman(rootful)**
- 오케스트레이션 대상 워크로드: **Airflow**
- 과정 기록: [GitHub 위키](https://github.com/Melting-Face/argocd-study/wiki)
  (`wiki/`에서 `main` push 시 자동 미러)

## 소유권 경계

| 주인 | 소유 대상 | 소유하지 않는 것 |
| --- | --- | --- |
| `terraform/cluster/kind/` | kind 클러스터, 노드 이미지·레이블, 포트 매핑, kubeconfig | 클러스터 **안의** 어떤 것도 |
| `terraform/platform/` | `argocd` 네임스페이스, ingress-nginx, ArgoCD, **root Application 1개** | `gitops/` 아래 어떤 앱도 |
| ArgoCD | `gitops/apps/**` 아래 모든 선언 | ArgoCD 자기 자신 |

상세 근거는 설계 문서 §3.

## 사전 준비물

| 항목 | 필요 이유 |
| --- | --- |
| **Podman**, `podman-machine-default`가 **rootful**로 실행 중 | kind의 Podman provider는 experimental이고 rootful 머신을 요구한다 |
| `kind`·`kubectl`·`helm`·`kustomize`·`gh`·`git` | 클러스터 구성·조회 |
| **`argocd` CLI** (Homebrew: `brew install argocd`) | Step 1부터 `argocd app get`/`list`로 Sync/Health를 확인한다 — 이 저장소의 사전 실측 시점(2026-10-04)엔 미설치였다 |
| **`helmfile`** (Homebrew: `brew install helmfile`) | Step 5(소유권 이전 실습)에 필요하다 — 같은 시점에 미설치였다 |
| `terraform` (>= 1.5) | 스택 2개를 적용한다 |
| 호스트 포트 **8081**(HTTP)·**8444**(HTTPS) 여유 | kind의 `extraPortMappings`가 이 포트를 점유한다. 다른 kind 클러스터(예: 포트 8080/8443을 쓰는 클러스터)가 있으면 충돌하지 않는지 먼저 확인한다 |

## 시작하기 — `terraform apply` 2회

스택은 `terraform/cluster/kind`(substrate)와 `terraform/platform`(ingress-nginx·ArgoCD)
둘로 나뉜다. 순서가 있다 — platform은 cluster가 내보내는 kubeconfig 경로에 의존한다.

```bash
# 1) substrate — kind 클러스터
terraform -chdir=terraform/cluster/kind init
terraform -chdir=terraform/cluster/kind apply

# 2) platform — ingress-nginx + ArgoCD (+ root Application)
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform apply

# 3) 확인 — port-forward 없이 바로 접근된다
kubectl --context kind-argocd-study get pods -n argocd
curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.localtest.me:8081
```

초기 admin 비밀번호는 `argocd-initial-admin-secret`에서 읽는다. 이후 `gitops/apps/**`의
변경은 **Git 커밋만으로** 반영된다 — `kubectl apply`도 `argocd app create`도 필요 없다.

전체 해체·복원(설계의 최종 수렴점):

```bash
terraform -chdir=terraform/cluster/kind destroy
terraform -chdir=terraform/cluster/kind apply
terraform -chdir=terraform/platform  apply
# Git 이 정본이므로 gitops/apps/** 의 애플리케이션은 전부 자동 복원되어야 한다
```

`terraform/`·`gitops/`·`helmfile.yaml`은 설계가 확정된 뒤 이어지는 Task에서 생성된다 —
지금 이 저장소에는 두 스택의 **설계**(디렉터리 레이아웃·소유권 경계·부트스트랩 순서)만
있고 `.tf`·Application YAML 본체는 없다. 명령은 완성된 뒤의 절차를 미리 적어 둔 것이다.

## 문서 지도

| 문서 | 내용 |
| --- | --- |
| [설계 문서](docs/superpowers/specs/2026-10-04-argocd-study-design.md) | 아키텍처·설계 결정(D1~D8)·리스크·테스트 전략 — **정본** |
| [구현 계획](docs/superpowers/plans/2026-10-04-argocd-study-phase1.md) | Phase 1(Step 0~2) 구현 계획 |
| [`docs/conventions/`](docs/conventions/README.md) | 코딩·운영 규칙 5종(terraform·git·k8s·general·publishing) |
| [`CLAUDE.md`](CLAUDE.md) | 핵심 컨벤션 요약 |
| [`AGENTS.md`](AGENTS.md) | 서브에이전트 구성·권한·강제 수단과 그 한계 |
| [위키](https://github.com/Melting-Face/argocd-study/wiki) | 실습 과정에서 관측한 것(Step별 노트) |

## AI 에이전트 작업 방식

`.claude/agents/`에 서브에이전트 4종(`devops-engineer`·`devops-verifier`·`tech-writer`·
`researcher`)이 있다. 각자의 역할·경계는 [`AGENTS.md`](AGENTS.md)를 본다.
`terraform apply`/`destroy`·`helm install`/`upgrade`·`helmfile apply`/`sync`·
`kubectl apply`/`delete`·`git commit`/`push` 등 비가역 작업은
[`.claude/settings.json`](.claude/settings.json)의 `permissions.ask`에 걸려 **실행 전
사용자 승인**을 거친다.
