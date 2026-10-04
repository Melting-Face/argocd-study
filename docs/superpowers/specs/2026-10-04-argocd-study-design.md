# ArgoCD 스터디 환경 설계

- 작성일: 2026-10-04
- 상태: 설계 승인 완료 (구현 계획 미작성)
- 대상 저장소: [`Melting-Face/argocd-study`](https://github.com/Melting-Face/argocd-study) (**public**)
- `var.repo_url` = `https://github.com/Melting-Face/argocd-study.git` — D4·D5의 입력값

---

## 1. 개요

### 1-1. 목적

ArgoCD를 **문서만 읽어본 수준**에서 출발해, 단계별 실습으로 GitOps를 체득하고
그 과정을 **GitHub 위키에 기록**한다. 실습 대상 워크로드는 **Airflow**다.

최종 목표는 사용자의 표현을 그대로 옮기면 **"ArgoCD부터 모든 코드를 IaC로 관리하는 것"** 이다.

### 1-2. 이 프로젝트의 중심 질문

> **선언을 어디에 두고, 누가 적용하며, 누가 소유하는가?**

| 도구 | 선언 위치 | 적용 주체 | 상태 추적 |
| --- | --- | --- | --- |
| Terraform | `.tf` | 사람이 `apply` (push) | state 파일 |
| Helm | chart + values | 사람이 `install` (push) | 릴리스 시크릿 |
| Helmfile | `helmfile.yaml` | 사람이 `apply` (push) | Helm 릴리스에 위임 |
| **ArgoCD** | **Git** | **컨트롤러가 지속 조정 (pull)** | **Git = 정본** |

네 도구는 같은 문제의 네 가지 답이다. **따로 공부하면 "쓰는 법"만 남고, 같이 놓으면 "언제 무엇을"이 보인다.**
그래서 4축을 한 저장소에서 다루며, 분해하지 않는다.

### 1-3. 성공 기준

1. `terraform apply` 2회로 **접근 가능한 ArgoCD 환경**이 선다 (port-forward 불필요).
2. Git 커밋만으로 애플리케이션이 배포된다.
3. 수동 드리프트를 ArgoCD가 self-heal로 복구하는 것을 **관측**한다.
4. Airflow가 GitOps로 배포되고 UI에서 DAG 1개가 성공한다.
5. **클러스터를 통째로 파괴하고 `apply` 2회로 전부 복원된다.** ← 최종 수렴점
6. 위키 10장이 발행된다.

### 1-4. 사전 실측 (2026-10-04, macOS Darwin 25.6.0 / Apple Silicon)

| 도구 | 상태 |
| --- | --- |
| `podman` | 설치됨. `podman-machine-default` **rootful=true, running**, 8 CPU / 26.08GiB / 93GiB |
| `kind` `kubectl` `helm`(v4.2.0) `kustomize` `k3d` `gh` `git` | 설치됨 |
| `docker` `nerdctl` `minikube` `argocd` `helmfile` | **없음** |
| 기존 kind 클러스터 | `lakehouse` (dagster-study 소유, 중지 상태). 호스트 포트 **8080/8443 점유** |
| `argo/argo-cd` 차트 | **10.9.6** (ArgoCD **v3.5.3**), `extraObjects` 지원 확인 |
| `ghcr.io/stefanprodan/podinfo` | **linux/amd64 + linux/arm64** 멀티아키 확인 |
| `*.localtest.me` | `127.0.0.1` 해석 확인 (`argocd.`/`airflow.`) |

추가 설치 필요: `argocd` CLI, `helmfile` (둘 다 Homebrew).

---

## 2. 범위

### 2-1. 학습 축 4개

| 축 | 내용 |
| --- | --- |
| ① ArgoCD | Application, sync/health, 드리프트·self-heal·prune, 소스 타입 |
| ② Terraform | 스택 경계·폭발반경, provider chaining, `precondition`, `depends_on`, `state rm`/`import` |
| ③ Helm | chart 작성, values, 공식 차트 운영 |
| ④ Helmfile | 여러 릴리스 선언, **소유권 이전 실험** |

② 는 ①의 구조재로 **이미 설계에 들어 있으므로 추가 비용이 거의 0**이다.
새 실습을 만드는 것이 아니라 **이미 내리는 판단을 위키에 적는 것**이다.

### 2-2. 범위 밖 — 빠뜨린 것이 아니라 정한 것

| 제외 | 이유 |
| --- | --- |
| **ArgoCD self-management** (ArgoCD가 ArgoCD를 Application으로 관리) | Terraform과 ArgoCD가 ArgoCD를 공동 소유 → §3-1 원칙 위반. 축 ①(Terraform으로 설치·관리)만으로 "IaC 관리"는 충족된다 |
| **Secret 관리 자동화** (SOPS / Sealed Secrets / External Secrets) | 그 자체로 축 하나. Step 4는 수동 `kubectl create secret` + Application은 참조만 |
| **ApplicationSet / 멀티클러스터 / SSO / 알림** | 이 spec 범위 밖. D4의 불편을 먼저 겪은 뒤 후속 프로젝트로 |
| **Helmfile을 ArgoCD CMP로** (`helmfile template`을 매니페스트 생성기로) | 플러그인 설정이 ArgoCD 내부 구조 학습을 요구 |
| **Terraform module 화** | 2스택 평면 구조에 반복이 없다. 억지 추상화 연습이 된다 |
| **remote backend / workspace / Terragrunt** | 로컬 1인 환경. state 잠금이 필요 없다. "왜 안 쓰는가"를 적는 것으로 대체 |
| **e2e 자동화** (CI에서 클러스터를 띄워 Step 0~5 재현) | 유지비가 산출을 넘는다. 관측은 사람이 하고 위키가 증거가 된다 |

---

## 3. 아키텍처

### 3-1. 핵심 원칙 — 한 리소스는 한 주인만

Terraform과 ArgoCD가 같은 리소스를 동시에 소유하면,
Terraform이 되돌리고 ArgoCD가 다시 맞추는 **무한 sync 루프**가 생긴다.
경계를 선언으로 못 박는다.

| 주인 | 소유 대상 | 소유하지 않는 것 |
| --- | --- | --- |
| 스택 A `terraform/cluster/kind` | kind 클러스터, 노드 이미지·레이블, 포트 매핑, kubeconfig | 클러스터 **안의** 어떤 것도 |
| 스택 B `terraform/platform` | `argocd` 네임스페이스, ingress-nginx, ArgoCD, **root Application 1개** | `gitops/` 아래 어떤 앱도 |
| ArgoCD | `gitops/apps/**` 의 모든 선언 | ArgoCD 자기 자신 |

### 3-2. substrate 계약 — 바닥이 플랫폼에 보장할 것 3가지

```
+-- substrate (교체 가능) ----------------------------+
|  kind-on-podman | kind-on-docker | k3d | 원격 k3s   |
+----------------------+------------------------------+
                       | 계약 3개만 넘긴다
                       v
   (1) kubeconfig 경로 + context 이름
   (2) 호스트에서 닿는 HTTP 진입점  (hostPort | NodePort | LoadBalancer)
   (3) 기본 StorageClass            (Step 4 Airflow 가 PVC 를 쓴다)
                       |
+----------------------v------------------------------+
|  platform -- ingress-nginx + ArgoCD  (substrate 무관) |
+-----------------------------------------------------+
```

**바닥을 kind-on-podman으로 못박지 않는다.** docker일 수도, k3s일 수도 있다.
이 계약이 이 프로젝트에서 가장 값진 산출물이며, 위키 노트 한 장을 따로 받는다.

substrate 의존이 남는 컴포넌트는 **ingress-nginx 하나뿐**이고,
`var.ingress_profile` (`kind` | `loadbalancer`)로 values 파일을 고르는 방식으로 격리한다.

### 3-3. 부트스트랩 / 해체 순서

```
   apply |                                                  ^ destroy (역순)
+----------------------------------------------------------+
| 1. terraform -chdir=terraform/cluster/kind apply          |
|      kind_cluster "argocd-study"                          |
|      -> ~/.kube/argocd-study.config  (정적 경로)           |
+----------------------------------------------------------+
| 2. terraform -chdir=terraform/platform apply              |
|      helm_release "ingress-nginx"                         |
|      helm_release "argo-cd"  (+ extraObjects: root App)   |
+----------------------------------------------------------+
| 3. (사람 개입 없음) ArgoCD 가 gitops/apps/ 를 읽어 전개     |
+----------------------------------------------------------+
```

**스택 간 결합은 kubeconfig 경로 문자열 하나뿐이다.**
`terraform_remote_state`를 쓰지 않는다 — 쓰는 순간 스택 B의 plan이 스택 A의 state에 묶여
분리의 실익이 사라지고, substrate 교체 가능성도 깨진다.
대가는 경로를 양쪽에 중복 선언하는 것이고, 변수 기본값으로 받는다.

---

## 4. 디렉터리 레이아웃

```
argocd-study/
+-- terraform/
|   +-- cluster/
|   |   +-- kind/                     # 구현 (1) -- 교체 가능
|   |   |   +-- versions.tf           #   tehcyx/kind 버전 고정 (latest 금지)
|   |   |   +-- main.tf               #   kind_cluster + extraPortMappings + 노드 labels
|   |   |   |                         #   + precondition: docker/nerdctl 부재 확인
|   |   |   +-- variables.tf
|   |   |   +-- outputs.tf            #   substrate 계약 (1)(2)(3) 을 내보낸다
|   |   +-- README.md                 # "다른 substrate 는 형제 디렉터리로. outputs 계약만 맞추면 platform 은 안 바뀐다"
|   +-- platform/
|       +-- versions.tf               #   hashicorp/helm ~> 3.0
|       +-- provider.tf               #   config_context 고정 (필수)
|       +-- ingress.tf                #   helm_release "ingress-nginx"
|       +-- argocd.tf                 #   helm_release "argo-cd" (extraObjects 에 root App)
|       +-- variables.tf              #   kubeconfig_path, kube_context, ingress_profile, repo_url
|       +-- values/
|           +-- ingress-nginx.kind.yaml          # hostPort + ingress-ready nodeSelector + toleration
|           +-- ingress-nginx.loadbalancer.yaml  # docker-desktop / k3d / 클라우드
|           +-- argocd.yaml.tftpl                # substrate 무관. repo_url 주입
|
+-- gitops/                           # ArgoCD 소유 -- Git 호스팅 중립
|   +-- apps/                         #   root 가 recurse 로 읽는 디렉터리
|   |   +-- podinfo.yaml              #     Step 1 -> Step 3 에서 소스 타입 전환
|   |   +-- airflow.yaml              #     Step 4
|   +-- manifests/podinfo/            #   Step 1: plain manifest (손으로 작성)
|   +-- charts/podinfo/               #   Step 3: 자체 Helm chart
|   +-- values/airflow.yaml           #   Step 4: 공식 차트 values
|
+-- helmfile.yaml                     # Step 5: ingress-nginx + argo-cd 재선언
|
+-- wiki/                             # 위키 원본 (평평, 영문 kebab-case, 프론트매터 없음)
|   +-- Home.md  _Sidebar.md          #   고정 2개. wiki/README.md 는 두지 않는다
|   +-- (노트 10장 -- 9절 참조)
|
+-- .github/workflows/                # GitHub 종속은 여기에만 격리
|   +-- ci.yml                        #   정적 검사만 (인프라 미접속)
|   +-- wiki.yml                      #   위키 단방향 미러
+-- scripts/
|   +-- wiki_linkify.py               #   .md 접미어 제거
|   +-- doc_lint.py                   #   링크/시제 검사
+-- docs/
|   +-- conventions/                  #   terraform.md, git.md, k8s.md(절삭), publishing.md(4-1만), general.md
|   +-- superpowers/specs/            #   이 문서
+-- .claude/
|   +-- agents/                       #   4종
|   +-- skills/                       #   5종
|   +-- settings.json                 #   permissions ~20, hooks 0
+-- .pre-commit-config.yaml           # 훅 ~17
+-- CLAUDE.md  AGENTS.md  README.md
```

**호스팅 종속이 `.github/` 한 곳에 갇혀 있다.** `wiki/*.md`, `gitops/`, `terraform/` 은 전부 중립이다.

---

## 5. 주요 설계 결정

### D1. Terraform 2스택 분리 (1스택 아님)

`kind_cluster`와 `helm_release`를 한 스택에 두면, helm 프로바이더 설정이
`kind_cluster.this.kubeconfig`(apply 시점에야 알려지는 값)를 참조해 plan에서 막힌다.
`kubeconfig_path`를 정적 리터럴로 고정하고 `depends_on`을 걸면 우회되지만 destroy 순서에서 다시 깨진다.

→ **cluster / platform 2스택.** dagster-study가 폭발반경 기준으로 이미 같은 결론에 도달했다
(`docs/architectures/terraform.md`: A=cluster, B=data, C=platform).

### D2. UI 접근은 Ingress (port-forward · NodePort 탈락)

| 방식 | 영구성 | 확장성 | 판정 |
| --- | --- | --- | --- |
| `kubectl port-forward` | 세션마다 재실행 | 앱당 1개 | 탈락 |
| NodePort + extraPortMappings 직결 | O | **치명적 결함** | 탈락 |
| **Ingress + extraPortMappings 80/443** | O | 무제한 | **채택** |

**NodePort 탈락 사유**: `extraPortMappings`는 **클러스터 생성 시점에만 지정 가능**하다
(kind 노드는 컨테이너라 공개 포트를 사후에 추가할 수 없다).
NodePort 직결이면 앱을 추가할 때마다 **클러스터를 재생성**해야 하고, Step 4 Airflow에서 바로 터진다.

Ingress는 80/443 둘만 열면 호스트명으로 무한 확장된다. 생성시점 고정 제약을 한 번만 치른다.

**주소**: `*.localtest.me` 가 공개 DNS에서 127.0.0.1로 해석되므로 `/etc/hosts`를 건드리지 않는다.
- `http://argocd.localtest.me:8081`
- `http://podinfo.localtest.me:8081`
- `http://airflow.localtest.me:8081`

**포트**: `80 -> 8081`, `443 -> 8444`.
기존 `lakehouse` 클러스터가 8080/8443을 쓰므로 비켜 잡는다.

### D3. ingress-nginx는 ArgoCD가 아니라 Terraform이 설치한다

ArgoCD가 설치하는 안(Step 1의 첫 Application으로)을 먼저 검토했으나 **self-locking** 결함으로 기각했다.

```
ingress-nginx Application 이 깨짐
  -> ArgoCD UI 접근 불가 (ingress 가 죽었으니)
  -> 고치려면 UI 가 필요한데 들어갈 수 없다
  -> 결국 port-forward 로 복구 -- 없애려던 마찰이 가장 나쁜 타이밍에 돌아온다
```

**운영 도구가 자기 접근 경로를 자기가 배포하면 안 된다.**
학습 환경이라 치명적이진 않으나, **잘못된 패턴을 몸에 익히게 되는 것**이 더 나쁘다.

그 외 근거: ingress-nginx는 애플리케이션이 아니라 **클러스터 진입 설비**(계층이 다르다) /
`terraform apply` 2회로 **완전히 접근 가능한 환경**이 서는 결정성 / dagster-study도 같은 계층에 뒀다.

### D4. `repoURL`은 평문 중복 + CI 일관성 검사

ArgoCD에는 "repoURL 전역 변수"가 없다. root는 Terraform이 `var.repo_url`로 주입하지만,
`gitops/apps/*.yaml`의 하위 Application들은 Git에 커밋되는 정적 YAML이라 각자 들고 있어야 한다.

Kustomize component나 app-of-apps Helm 차트로 묶는 방법이 정석이지만,
**Step 1에 새 추상화가 끼어들어 Application CRD 학습이 흐려진다.**

→ 평문 중복 + `ci.yml`이 불일치를 잡는다. 전환 비용은 `sed` 일괄 치환 1회.
**이 불편을 먼저 겪어야 ApplicationSet(후속 프로젝트)이 왜 필요한지 체감된다.**

### D5. root Application은 `kubernetes_manifest`가 아니라 `extraObjects`로

`hashicorp/kubernetes`의 `kubernetes_manifest`는 **plan 시점에 API 서버에 접속해 리소스 스키마를 조회**한다.
ArgoCD Application CRD는 같은 apply 안의 `helm_release`가 설치하므로, 최초 plan 시점에 CRD가 없어 **plan이 실패**한다.
plan은 apply 이전이므로 `depends_on`으로도 풀리지 않는다.

→ **`argo/argo-cd` 차트의 `extraObjects`에 root Application을 넣는다** (차트 10.9.6에서 지원 확인).

부수 효과가 전부 좋다:
1. CRD 순서 문제 소멸 (같은 릴리스가 CRD와 함께 적용)
2. `var.repo_url`이 진짜로 한 곳에만 남는다
3. Terraform 리소스가 2개로 줄어 플랫폼 스택이 더 얇아진다

### D6. substrate 중립화

바닥을 kind-on-podman으로 못박지 않는다 (§3-2).
이 결정으로 **podman 자동탐지 문제(R1)가 `terraform/cluster/kind/` 안에만 사는 국지적 문제로 격하**된다.

`k3d/`, `existing/` 구현은 **지금 만들지 않는다**(YAGNI).
필요해질 때 형제 디렉터리로 추가하면 되고, 그게 가능하다는 것이 계약의 증명이다.

### D7. Helmfile의 역할은 "또 하나의 배포 도구"가 아니라 **소유권 이전 실험**

```
Step 0  terraform/platform  -> helm_release "ingress-nginx" / "argo-cd"   [Terraform 소유]
Step 5  helmfile.yaml 로 같은 두 릴리스를 선언
          -> terraform state rm    (Terraform 이 놓아준다. 리소스는 안 지운다)
          -> helmfile apply        (Helmfile 이 인수)
          -> 재생성 없이 넘어갔는가?  <- 실측
```

②Terraform 축의 `state rm`/`import` 주제와 완전히 겹치므로 **④를 추가하는 한계비용이 거의 0**이다.
그리고 §3-1 "한 리소스는 한 주인만" 원칙을 **실제로 손으로 옮겨보는 유일한 실습**이라,
프로젝트 중심 질문의 결론부가 된다.

### D8. Step 1 교재는 podinfo

멀티아키(arm64 확인) 이미지를 쓰는 순수 k8s 리소스라 **어느 substrate에서든 동일하게 동작**한다.
plain manifest / Helm chart / Kustomize base를 공식으로 전부 제공해
**같은 앱을 세 가지 소스 타입으로 배포해 비교**할 수 있다.
이미지 태그·replica 변경이 Step 2 드리프트 실험에 이상적이고, UI가 있어 Ingress로 눈에 보인다.

---

## 6. Step별 계획과 완료 판정

> **판정 기록 규율**: 아래는 **명령과 통과 조건**만 적는다. **기대 출력 예시는 비워 둔다.**
> 관측하기 전에 출력을 지어내 위키에 박아두면, 되돌릴 수 없는 매체에 거짓이 남는다.
> (dagster-study `docs/conventions/publishing.md` §4-1 계승)

### Step 0 — Terraform으로 바닥 세우기 `(1)(2)`

| 스택 | 만드는 것 |
| --- | --- |
| `cluster/kind` | `kind_cluster` — extraPortMappings `80->8081`/`443->8444`, 노드 label `ingress-ready=true`, control-plane taint 유지, `precondition`(docker·nerdctl 부재). outputs = substrate 계약 3개 |
| `platform` | `helm_release "ingress-nginx"` (profile=kind) / `helm_release "argo-cd"` (`server.insecure=true`, ingress `argocd.localtest.me`, `extraObjects`에 root App), `depends_on` + `wait = true` |

완료 판정:
```
terraform -chdir=terraform/cluster/kind plan    # 통과: No changes
terraform -chdir=terraform/platform  plan       # 통과: No changes
kubectl --context kind-argocd-study get pods -n argocd           # 전부 Running
kubectl --context kind-argocd-study get ingress -A               # argocd-server Ingress 에 ADDRESS 할당
curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.localtest.me:8081   # 200
```
초기 비밀번호는 `argocd-initial-admin-secret`에서 읽는다.
**port-forward 없이 Step 0에서 바로 UI에 접근된다.**

위키: `argocd-bootstrap.md`, `terraform-on-kind.md`, `terraform-stack-boundaries.md`

### Step 1 — 첫 Application `(1)`

`gitops/apps/podinfo.yaml` (Application, source=directory) +
`gitops/manifests/podinfo/{deployment,service,ingress}.yaml` 을 손으로 작성한다.

Application의 `destination.namespace`는 `podinfo`, `syncOptions: CreateNamespace=true` 로 둔다
(네임스페이스를 Terraform이 만들지 않는다 — §3-1).

`syncPolicy.automated` **없이 시작**한다 — 수동 sync를 눌러 무엇이 언제 일어나는지 눈으로 본다.

완료 판정:
```
git push                      # 커밋만으로 앱이 생겨야 한다
argocd app list               # podinfo 등장
argocd app get podinfo        # OutOfSync -> (수동 sync) -> Synced/Healthy
curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081   # 200
```

위키: `first-application.md`

### Step 2 — 드리프트와 self-heal `(1)`  ★ GitOps의 핵심

| 실험 | 선행 상태 | 조작 | 관측 대상 |
| --- | --- | --- | --- |
| 1 | 수동 sync (Step 1 그대로) | `kubectl scale deploy podinfo --replicas=5` | `OutOfSync` 전이, diff 화면 |
| 2 | `automated: {}` 만 켠다 (selfHeal **없음**) | 드리프트를 그대로 둔다 | **되돌아가지 않는다** — 새 커밋은 자동 반영되지만 **수동 드리프트는 복구되지 않는다** |
| 3 | `automated.selfHeal: true` 커밋 | 드리프트를 다시 만든다 | 자동 복구 시점·지연 |
| 4 | `prune: false` | 매니페스트 1개 삭제 커밋 | **고아 리소스가 남는다**. 이후 `prune: true` 로 바꿔 재관측 |
| 5 | `prune: true`, selfHeal on | `gitops/apps/podinfo.yaml` 삭제 | 앱이 사라지는가, 하위 리소스는? (cascade) |

**실험 2가 이 Step의 핵심 교훈이다.** `automated`·`selfHeal`·`prune`은 **독립된 3개 스위치**이고,
많은 사람이 하나로 착각한다.

완료 판정: 5개 실험의 상태 전이를 **각각 관측하고 명령·출력을 위키에 기록**한다.

위키: `drift-and-selfheal.md`

### Step 3 — 자체 Helm chart 작성 `(1)(3)`

`gitops/charts/podinfo/` 에 `Chart.yaml`, `values.yaml`,
`templates/{deployment,service,ingress}.yaml`, `templates/_helpers.tpl` 을 작성한다.
Step 1의 plain manifest를 **같은 결과가 나오는 chart로 재작성**하고
Application의 `source`를 `directory` -> `helm`으로 바꾼다.

완료 판정:
```
helm lint gitops/charts/podinfo
helm template podinfo gitops/charts/podinfo > /tmp/from-helm.yaml
diff <(kustomize cfg cat gitops/manifests/podinfo) /tmp/from-helm.yaml   # 의미 있는 차이만 남는가
argocd app get podinfo    # 소스 타입 전환 후에도 Synced/Healthy
kubectl get pod -n podinfo -o jsonpath='{.items[*].metadata.uid}'   # 전환 전후 UID 비교
```

**소스 타입을 바꾸면 파드가 재생성되는가?** 가 이 Step의 핵심 질문이다.
ArgoCD는 생성 수단이 아니라 **결과 매니페스트**를 보므로, 결과가 같으면 재생성되지 않아야 한다. 실측한다.

위키: `writing-a-helm-chart.md`, `argocd-source-types.md`

### Step 4 — Airflow 공식 chart `(1)(3)`

| 항목 | 결정 |
| --- | --- |
| chart | `apache-airflow/airflow` (공식) |
| executor | **LocalExecutor** — 기존 `lakehouse`와 같은 podman machine(26GB)을 공유하므로 최소 구성 |
| values | `gitops/values/airflow.yaml` |
| Secret | **Git에 넣지 않는다.** `kubectl create secret` 으로 수동 생성, Application은 참조만 |
| namespace | `syncOptions: CreateNamespace=true` (Terraform이 만들지 않는다 — §3-1) |
| PVC | substrate 계약 (3) 기본 StorageClass 사용 |

완료 판정:
```
argocd app get airflow                   # Synced/Healthy
kubectl get pvc -n airflow               # Bound
curl -sS -o /dev/null -w '%{http_code}\n' http://airflow.localtest.me:8081   # 200
# example DAG 1개를 수동 트리거해 success 까지 확인
```

**Step 4 실습 시 `lakehouse` 클러스터 중지를 전제로 한다** (R7).

위키: `airflow-on-argocd.md`

### Step 5 — Helmfile로 소유권 이전 `(2)(4)`  ★ 결론부

```
1) helmfile template / diff   -> terraform 이 깐 릴리스와 같은 결과인가?
2) terraform state rm         -> Terraform 이 소유권을 놓는다 (리소스는 안 지운다)
3) helmfile apply             -> Helmfile 이 인수
4) 재생성 없이 넘어갔는가?
```

완료 판정:
```
kubectl get pods -n argocd -o jsonpath='{.items[*].metadata.uid}'   # 2) 전후 UID 불변
helm history argo-cd -n argocd                                      # revision 증가 양상
terraform -chdir=terraform/platform plan                            # 놓아준 리소스가 plan 에 없어야 한다
```

**`terraform state rm` 실행 전 `terraform/platform/terraform.tfstate` 백업을 필수 절차로 둔다** (R8).

위키: `helmfile-vs-terraform.md`, `who-owns-what.md`

### 최종 검증 — 전체 파괴와 복원

```
terraform -chdir=terraform/cluster/kind destroy
terraform -chdir=terraform/cluster/kind apply
terraform -chdir=terraform/platform  apply
# -> Git 이 정본이므로 앱은 전부 자동 복원되어야 한다
```

**이것이 "모든 코드를 IaC로"의 실체이고, 이 프로젝트의 수렴점이다.** 실행하고 위키에 기록한다.

---

## 7. `../dagster-study` 자산 이식 목록

**원칙: 체계가 따라와야 작동하는 것은 가져오지 않는다.**
훅·가드·거버넌스가 그 경우이고, 도구 지식(스킬)·규약(컨벤션)·배달 파이프라인(위키 CI)은 가져온다.

### 7-1. 에이전트 — 12종 중 4종

| 에이전트 | 판정 | 변형 내용 |
| --- | --- | --- |
| `devops-engineer` | 이식 | compose·Dagster 절 삭제, Helm/Helmfile/ArgoCD 절 추가 |
| `devops-verifier` | 이식 | "선언 vs 실제 런타임 대조"가 ArgoCD sync/health 검증과 같은 일 |
| `tech-writer` | 이식 | `docs/**` + `wiki/**` 소유자 |
| `researcher` | 이식(축소) | 외부 1차 출처 수집. DUA 질의유출 통제 절 삭제 |

제외: `devops-qa`, `security`(gitleaks·detect-private-key 훅과 범위 중복),
`archivist`(저널 체계 전체가 따라와야 함), 데이터 축 5종.

### 7-2. 스킬 — 20종 중 5종

| 스킬 | 판정 |
| --- | --- |
| `kubernetes-specialist` (148KB) | 이식 — 4축 전부의 바닥 |
| `terraform-style-guide` (16KB) | 이식 |
| `terraform-test` (32KB) | 이식 — `.tftest.hcl` |
| `git-commit` (4KB) | 이식 — Conventional Commits |
| `documentation` (4KB) | 이식 — 위키 10장 |
| `brainstorming` (96KB) | 이미 있음 |

제외: **`terraform-stacks`(124KB) — HashiCorp Terraform Stacks(HCP 제품, `.tfstack.hcl`) 전용 가이드이고,
우리의 "2스택"은 root module 2개를 디렉터리로 나눈 것이라 다른 개념이다.**
`archify`(8.6MB), dbt·spark·sql·dagster 계열 9종도 제외.

**없는 것**: ArgoCD·Helm·Helmfile 스킬은 dagster-study에 없다. 필요하면 외부 탐색 또는 신규 작성이며, **이식이 아니라 신규 작업**이다.

### 7-3. `.claude/settings.json`

| 항목 | 판정 |
| --- | --- |
| `permissions.ask` 128개 | 제외 -> **신규 ~15개** |
| `permissions.deny` 22개 | 발신 동사 몇 개만 차용 |
| `hooks` 16개 / 가드 스크립트 8종 | **제외 — 0개로 시작** |

**훅을 가져오지 않는 이유**: 16개 훅은 전부 저널·워커 경계·연구 게이트·plan 미러라는
**뒤에 있는 거버넌스 체계**를 전제한다. 체계 없이 스크립트만 옮기면
**오동작하거나 조용히 무력화**된다. 필요해지면 그때 하나씩 세운다.

신규 `ask` 핵심: `git commit`/`git push`, `gh` 쓰기,
**`terraform apply`/`destroy`**, **`helm install/upgrade/uninstall`**,
**`helmfile apply/sync/destroy`**, `kubectl delete`/`apply`, `kind delete cluster`.

### 7-4. pre-commit — 28개 중 ~17개

- **이식**: `check-added-large-files` `check-json` `check-merge-conflict` `check-toml` `check-yaml`
  `detect-private-key` `end-of-file-fixer` `trailing-whitespace` `gitleaks` `gitlint` `yamllint`
  `shellcheck` `terraform_fmt` `ruff-check` `ruff-format`
- **이식(변형)**: `doc-lint` `doc-links` — 위키 `.md` 링크 규약 강제
- **신규**: `tflint`, `helm lint`, `helmfile lint`
- **제외**: `sqlfluff-*` `nbstripout` `hadolint` `guard-tests` `hook-files` `permission-glob`
  `skill-wiring` `worker-wiring` `no-health-data-files` `no-research-state-files`

### 7-5. 문서

| 문서 | 판정 |
| --- | --- |
| `docs/conventions/terraform.md` (5.9KB) | 거의 그대로 |
| `docs/conventions/publishing.md` **§4-1만** (17.8KB -> ~3KB) | 위키 산출물 규약. DUA·소규모셀 전부 삭제 |
| `docs/conventions/git.md` (16KB) | 변형 |
| `docs/conventions/k8s.md` (42KB -> ~8KB) | **대폭 절삭** — §9 Spark, §9-2 Flink, §11 Iceberg, §12 CNPG 제거. §1~8, §10만 |
| `docs/conventions/general.md` (22KB) | 선별 |
| `docs/architectures/terraform.md` | 참조 — 폭발반경 분할 근거 (D1의 선례) |

제외: dagster·dbt·analysis·data-quality·python·codex·monitoring·issue·docker·timezone.

`CLAUDE.md`(45KB) / `AGENTS.md`(12KB)는 **골격만 차용하고 내용은 재작성**한다.
가져올 구조: 문서화 원칙 / 커밋 컨벤션 / 코딩 철학 / 프로젝트 구조 컨벤션 / 테스트 컨벤션 / 타임존 정책.

### 7-6. 스크립트 · CI

| 자산 | 판정 |
| --- | --- |
| `scripts/wiki_linkify.py` | **그대로** |
| `scripts/doc_lint.py` | 변형 (데이터 규칙 제거) |
| `.github/workflows/wiki.yml` | 거의 그대로 (리포명 교체) |
| `.github/workflows/ci.yml` | **구조만** — 설계원칙 4개는 계승, 스텝은 전면 재작성 |

**`wiki.yml` 선행조건 2개를 계승한다** (사람이 1회):
1. 웹 UI에서 위키 첫 페이지를 만들어야 `.wiki.git`이 생성된다 (빈 위키는 `Repository not found`).
2. Settings -> Wikis -> **Restrict editing to collaborators only** 를 켠다.
   저장소가 공개면 아무나 위키를 고칠 수 있고, 그 편집은 다음 미러가 덮어써 **조용히 사라진다**.
   이 설정은 **REST API로 조회할 수 없다** (`has_wiki` 필드뿐) — 자동 관측 경로가 없다.

**`ci.yml` 설계원칙 4개 (계승)**:
1. **인프라에 붙는 명령을 넣지 않는다.** 게이트가 클러스터 가용성에 묶이면 커밋이 막힌다. 스텝은 파일만 읽는다.
2. 크리덴셜은 명백히 가짜만 쓴다.
3. 규칙의 단일 출처는 저장소 설정 파일이다. 워크플로는 '무엇을 언제 실행할지'만 정한다.
4. 외부 도구는 액션이 아니라 러너에 직접 깐다.

### 7-7. 이식 규모 요약

| | dagster-study | argocd-study |
| --- | --- | --- |
| 에이전트 | 12 | **4** |
| 스킬 | 20 | **5** |
| 훅 | 16 | **0** |
| permissions | 155 | **~20 (신규)** |
| pre-commit | 28 | **~17** |
| conventions 문서 | 17 | **5** |

---

## 8. 리스크 등록부

| # | 리스크 | 확률 | 영향 | 대응 | 잔여 |
| --- | --- | --- | --- | --- | --- |
| R1 | **podman 자동탐지가 docker로 뒤집힘** | 중 | 중 | `precondition`으로 전제 선언 -> apply 실패로 조용한 변경 차단 | "고정"은 불가. D6 덕에 영향이 국지적 |
| R2 | provider chaining | — | — | D1 2스택 분리로 해소 | 없음 |
| R3 | `lakehouse`와 호스트 포트 충돌 | 고 | 저 | 8081/8444로 비켜 잡음 | 없음 |
| R4 | ingress-nginx admission webhook 경합 | 중 | 중 | `depends_on` + `wait = true` | 첫 apply가 검증 |
| R5 | kind용 ingress 전용 설정 | 고 | 중 | `kind_config.node`의 `labels`·`kubeadm_config_patches` (스키마 확인됨) | 없음 |
| R6 | `kubernetes_manifest` CRD/plan 제약 | 고 | 고 | D5 `extraObjects` 전환 | 없음 |
| R7 | **자원 경합** — podman machine 26GB를 `lakehouse`와 공유 | 고 | 중 | Airflow LocalExecutor 최소 구성. Step 4 실습 시 `lakehouse` 중지 전제를 위키에 명시 | 남음 |
| R8 | `terraform state rm` 비가역 (Step 5) | 중 | 고 | 실행 전 tfstate 백업을 필수 절차로 | 남음 |
| R9 | **공개 저장소 = 발행** (push가 곧 공개) | 고 | 고 | `gitleaks` + `detect-private-key` + CI. Secret은 Git에 넣지 않는다 | **패턴 방어는 봉쇄가 아니다** |
| R10 | 위키 미러 선행조건 미충족 | 중 | 저 | §7-6 선행조건 2개 (사람이 1회) | 자동 관측 경로 없음 |
| R11 | `tehcyx/kind`는 커뮤니티 프로바이더 | 저 | 중 | 버전 고정. 끊기면 substrate 계약 덕에 `k3d`/`existing`으로 교체 | 구조로 흡수 |
| R12 | `*.localtest.me` 외부 DNS 의존 | 저 | 저 | 폴백: `/etc/hosts` 또는 `nip.io` (둘 다 실측 확인) | 없음 |

### R1 상세 — podman 선택에 `KIND_EXPERIMENTAL_PROVIDER`가 안 먹는다

`tehcyx/terraform-provider-kind`의 `kind/resource_cluster.go` (L137, 149, 196)는
런타임 옵션 없이 `cluster.NewProvider(cluster.ProviderWithLogger(...))`를 호출한다.

`kubernetes-sigs/kind`의 `pkg/cluster/provider.go`에서 `NewProvider`는 옵션이 없으면
`DetectNodeProvider()`로 떨어지고, 그 함수는 **docker -> nerdctl -> podman 순으로 `IsAvailable()`** 을 본다.
소스 주석이 명시한다: *"kind **cli** 는 `KIND_EXPERIMENTAL_PROVIDER`를 보지만"* — **라이브러리 자동탐지는 보지 않는다.**
아무것도 못 찾으면 `ProviderWithDocker()`로 폴백한다.

현재 머신에서는 docker·nerdctl이 없어 podman이 선택된다(§1-4). **그러나 이것은 설정이 아니라 우연이다.**
Docker Desktop을 설치하면 조용히 docker로 넘어가고, 환경변수로 되돌릴 수단이 없다.

---

## 9. 테스트 전략

| 층 | 수단 | 대상 | 실효 |
| --- | --- | --- | --- |
| 1. 로컬 정적 | pre-commit ~17훅 | `terraform fmt`, `tflint`, `yamllint`, `helm lint`, `helmfile lint`, `gitleaks`, `doc-lint` | **실수 방지** — `--no-verify`로 우회 가능 |
| 2. 서버 정적 | `.github/workflows/ci.yml` | 위 + `terraform validate` | **봉쇄** — 우회 불가 |
| 3. 단위 | `.tftest.hcl` | 변수 검증, `precondition` 로직, plan 수준 | 클러스터 불필요 |
| 4. 수동 관문 | Step별 완료 판정 (§6) | `plan` 0-diff, 파드 Running, HTTP 200, 상태 전이 관측 | **사람** |

**CI에는 인프라에 붙는 명령을 넣지 않는다** (§7-6 원칙 1).
`terraform apply`·`kubectl`·`helm install`은 전부 층 4에 남긴다.

---

## 10. 실패 모드와 복구 경로

| 깨진 것 | UI 접근 | 복구 |
| --- | --- | --- |
| podinfo / Airflow Application | 살아 있음 | ArgoCD UI에서 바로 |
| root Application | 살아 있음 | `terraform apply` 재실행 (root는 Terraform 소유) |
| **ingress-nginx** | 끊김 | `kubectl port-forward` 1회 -> 수정 -> 복구. **D3에서 Terraform 소유로 둔 이유** |
| ArgoCD 자체 | 끊김 | `terraform -chdir=terraform/platform apply` |
| 클러스터 | 끊김 | `destroy && apply` x2 — **Git이 정본이므로 앱은 전부 자동 복원** |

---

## 11. 위키 구성

```
wiki/
+-- Home.md
+-- _Sidebar.md
|
|  -- ArgoCD 축 --
+-- argocd-bootstrap.md            Step 0
+-- first-application.md           Step 1
+-- drift-and-selfheal.md          Step 2
+-- argocd-source-types.md         Step 3
+-- airflow-on-argocd.md           Step 4
|
|  -- Terraform / Helm / Helmfile 축 --
+-- terraform-on-kind.md           tehcyx/kind, podman 자동탐지 함정, 전제 방어
+-- terraform-stack-boundaries.md  2스택 분리, 폭발반경, provider chaining
+-- writing-a-helm-chart.md        Step 3
+-- helmfile-vs-terraform.md       Step 5
|
|  -- 교차 축 (중심 질문의 결론) --
+-- who-owns-what.md               Terraform vs Helm vs Helmfile vs ArgoCD 소유권 경계
```

### 위키 규약 (dagster-study `publishing.md` §4-1 계승)

- 경로 `wiki/<slug>.md` — **평평하게** 둔다 (위키에 계층 사이드바가 없다).
- 파일명은 영문 kebab-case(URL에 노출), 제목(H1)은 한국어.
- 고정 이름 둘: `Home.md`, `_Sidebar.md`. **`wiki/README.md`를 두지 않는다**(엉뚱한 페이지가 생긴다).
- **프론트매터를 쓰지 않는다** — 위키가 YAML을 렌더링하지 못하고 본문에 그대로 노출한다.
- 링크는 저장소 원본에 `.md`를 **붙여** 쓰고, 미러 단계에서 `wiki_linkify.py`가 접미어를 뗀다.
  원본에서 생략하면 링크 검사기가 대상을 못 찾아 **검사가 통째로 죽는다**.
  참조형 링크(`[x]: url`)와 HTML `<a href>`는 쓰지 않는다 (변환 대상 밖).
- **예시와 함께 정리한다.** 주장·함정·교훈을 서술로만 두지 않고, 그것을 드러내는
  명령·설정·에러 원문을 그 자리에 함께 둔다.
  단 **관측되지 않은 실행 출력을 예시로 만들지 않는다.**
  관측이 없으면 명령까지만 쓰고 기대 출력을 비운다.

---

## 12. 구현 분할

범위가 Step 6개로 커졌으므로 한 번에 구현하지 않는다.

- **이 spec**: Step 0~5 전체를 담는다 — 전체 그림이 있어야 Step 0의 경계 결정이 옳은지 판단된다.
- **구현 계획**: `writing-plans` 단계에서 **Phase 1 = Step 0~2** 만 상세화한다.
  Phase 2(Step 3~5)는 Phase 1 완료 후 작성한다.

---

## 13. 참고 문헌

| 제목 | 출처 | 확인한 것 |
| --- | --- | --- |
| Argo CD — Git Webhook Configuration | `argo-cd.readthedocs.io/en/stable/operator-manual/webhook/` | 지원 프로바이더 6종(GitHub·GitLab·Bitbucket·Bitbucket Server·Azure DevOps·Gogs), `/api/webhook` 엔드포인트, `webhook.bitbucket.uuid` / `webhook.bitbucketserver.secret` 키 이름 |
| tehcyx/terraform-provider-kind | `github.com/tehcyx/terraform-provider-kind` | `kind/resource_cluster.go` 런타임 옵션 미지정, `kind/schema_kind_config.go` 의 `labels`·`kubeadm_config_patches`·`extra_port_mappings` 지원 |
| kubernetes-sigs/kind | `github.com/kubernetes-sigs/kind` | `pkg/cluster/provider.go` 의 `NewProvider` / `DetectNodeProvider` 자동탐지 순서와 docker 폴백 |
| Terraform Registry — tehcyx/kind `kind_cluster` | `registry.terraform.io/providers/tehcyx/kind/latest/docs/resources/cluster` | 리소스 스키마 및 내보내는 속성 |
| Terraform For Local Environments (podman+kind) | `blog.woohoosvcs.com/2024/10/terraform-for-local-environments-podmankind/` | 동일 조합 사용 사례 (단 podman 선택 방법은 미기재) |
| argo/argo-cd Helm chart | `helm show values argo/argo-cd` (10.9.6 / ArgoCD v3.5.3) | `extraObjects` 지원 |
| `../dagster-study` | 로컬 저장소 | 폭발반경 기반 스택 분할, `provider.tf` `config_context` 고정 교훈, 위키 미러 파이프라인과 선행조건, CI 설계원칙 |

---

## 14. Bitbucket 이식성 (장래 전환)

| 층 | 전환 비용 | 비고 |
| --- | --- | --- |
| Application `spec.source.repoURL` | 1줄 (D4에 따라 `sed` 일괄) | ArgoCD는 Git 프로바이더 중립 |
| 매니페스트 (Helm/Kustomize) | 없음 | Git 호스팅 무관 |
| Terraform / Helmfile | 없음 | 호스팅 무관 |
| 웹훅 | 키 이름만 교체 | `/api/webhook` 공용. `webhook.github.secret` -> `webhook.bitbucket.uuid` (Cloud) / `webhook.bitbucketserver.secret` (Server) |
| 리포 인증 Secret | 구조 동일, 발급처만 다름 | GitHub PAT/deploy key <-> Bitbucket App password/Access token |
| `.github/workflows/ci.yml` | **재작성** | Bitbucket Pipelines |
| `.github/workflows/wiki.yml` | **재설계** | `<repo>.wiki.git`은 GitHub 고유 구조 |

**설계상 호스팅 종속은 `.github/` 한 곳과 `repoURL` 문자열에만 있다.**
