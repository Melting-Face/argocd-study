# Phase 3 설계 — ApplicationSet 과 GitHub 기반 이미지 CD

- 작성일: 2026-10-07
- 상태: **승인 완료** (2026-10-07 — spec 승인, grilling 2라운드 반영) · 구현 계획: [`2026-10-07-applicationset-image-cd.md`](../plans/2026-10-07-applicationset-image-cd.md)
- 상위 설계: [`2026-10-04-argocd-study-design.md`](2026-10-04-argocd-study-design.md) — 이 문서는 그 §3-1·§4·
  D4·D5·D7 과 Phase 2 계획 T4~T7 을 **부분 대체**한다(§9 에 대체 범위를 적는다)
- 결정 로그 원본: `.superpowers/sdd/2026-10-05-argocd-study-phase2/progress.md` 의
  "Phase 3 브레인스토밍"(2026-10-06)·"브레인스토밍 재개"(2026-10-07) 절

> **판정 기록 규율**(상위 설계 §6)이 이 문서에도 적용된다. 관측 전 결과를 지어내지 않는다.
> 🔴 표시는 **1차 출처로 아직 확인하지 못한 주장**이고, 구현 계획이 그 확인을 선행 태스크로 갖는다.

---

## 1. 개요

### 1-1. 요구 (사용자 원문, 2026-10-07)

1. Terraform 을 통한 ArgoCD 배포
2. chart 와 container image 는 GitHub 를 통해 관리
3. ArgoCD 가 ApplicationSet 을 통해 정해진 앱들을 자동으로 배포·관리
4. ArgoCD 는 GitHub 에서 pulling 을 통해 CD

사용자가 제시한 흐름(승인): ① Terraform 이 ArgoCD 를 실행 → ② ArgoCD 가 준비되면 Terraform 이
앱 목록(ApplicationSet)을 배포 → ③ 이후 GitHub 의 chart·이미지 변경은 ArgoCD 가 pull 로 CD.

### 1-2. 중심 질문의 Phase 3 판본

상위 설계의 질문 *"선언을 어디에 두고, 누가 적용하며, 누가 소유하는가"* 를 **"무엇을 배포할지"**
와 **"무엇으로 배포할지"** 로 쪼갠다.

| 질문 | 주인 | 적용 방식 |
| --- | --- | --- |
| 어떤 앱이 존재하는가 (앱 목록) | **Terraform** | `terraform apply` (push, 드물다) |
| 그 앱이 어떤 chart·values·이미지 태그인가 | **Git** | ArgoCD 폴링 (pull, 잦다) |
| 이미지 태그를 Git 에 누가 적는가 | **GitHub Actions** | 이미지 빌드 직후 커밋 |

### 1-3. 성공 기준

1. `terraform apply` 로 ArgoCD 와 ApplicationSet 이 서고, **ApplicationSet 이 Application 2개
   (`podinfo`·`airflow`)를 생성**한다. `gitops/apps/` 와 root Application 은 존재하지 않는다.
2. 기존 `podinfo` 워크로드가 root → ApplicationSet 주인 교체 중에 **재생성되지 않는다**(Deployment UID 불변).
3. Airflow 가 **우리 저장소의 umbrella chart** 와 **GHCR 의 커스텀 이미지**로 배포되고, 이미지에 구운
   DAG 1개가 UI 에서 success 까지 간다.
4. git tag push 1회로 **사람의 추가 개입 없이** 이미지 빌드 → GHCR 푸시 → 태그 커밋 → ArgoCD 재배포가
   일어나고, 실행 중 파드의 이미지 태그가 바뀐 것을 관측한다.
5. 연속된 두 커밋에 걸쳐 Airflow 의 fernet·jwt Secret 이 **바뀌지 않는다**(렌더 결정성).
6. 클러스터 안에 **Git 쓰기 자격증명이 0개**다.

---

## 2. 범위

### 2-1. 범위 안

- `terraform/platform`: `root_app` → `appset` 교체, 앱 목록 변수
- `gitops/charts/airflow/`: 공식 chart 를 감싼 umbrella chart (Phase 2 T4 흡수)
- `images/airflow/`: 커스텀 이미지(공식 base + 우리 DAG)
- `.github/workflows/image.yml`: 빌드·푸시·태그 커밋
- Airflow Secret 3종 수동 생성 절차 (`docs/airflow-secret.md` 확장)

### 2-2. 범위 밖 — 정한 것

| 항목 | 왜 뺐나 |
| --- | --- |
| Argo CD Image Updater | 클러스터에 Git 쓰기 자격증명이 필요하다 — **보안상 GitHub Actions 커밋을 택했다**(2026-10-07) |
| Git generator / Matrix generator | 앱 목록 주인을 Terraform 으로 정했다 — List 가 그 결정의 직접 표현이다 |
| podinfo 커스텀 이미지 | upstream 이미지(`ghcr.io/stefanprodan/podinfo`)로 충분하다. 커스텀 이미지는 Airflow 하나 |
| 멀티 아키텍처 이미지 | 실행 환경이 Apple Silicon kind 하나다(arm64 only, YAGNI). 원격 x86 클러스터가 생기면 추가 |
| chart 를 GHCR(OCI)로 발행 | 요구 ②의 "GitHub 로 관리"를 **Git 경로 chart** 로 충족한다. OCI 발행은 버전 관리 층을 하나 더 만든다 |
| `charts/*.tgz` 커밋(vendoring) | ArgoCD 가 렌더 시 의존성을 받는다(§4-2). `Chart.lock` 의 digest 로 재현성을 고정한다 |
| 태그 접두사(`airflow/v0.1.0`) | 커스텀 이미지가 하나다. **두 번째 이미지가 생기면 재검토**한다(grilling Q3, 철학 5) |
| ArgoCD webhook (push 알림) | 로컬 kind 는 GitHub 에서 도달할 수 없다. 폴링으로 충분하다 |

---

## 3. 아키텍처 (섹션 1 — 2026-10-07 승인)

```
 ┌──────────────── GitHub ────────────────────────────────────────┐
 │ main 브랜치                          GHCR (public)              │
 │  gitops/charts/podinfo/  (chart)      ghcr.io/melting-face/     │
 │  gitops/charts/airflow/  (umbrella)     airflow-dags:vX.Y.Z     │
 │    └ values.yaml  airflow.images.airflow.tag ◄─┐       ▲        │
 │  images/airflow/ (Dockerfile + dags/)          │       │ push   │
 │        │ git tag vX.Y.Z push                 커밋     │        │
 │        └──► GitHub Actions: 빌드(arm64) ───────┴───────┘        │
 └─────────────────────▲──────────────────────────────────────────┘
                       │ pull (폴링)
 ┌──── kind 클러스터 ───┴──────────────────────────────────────────┐
 │ [Terraform platform]  ArgoCD ──► ApplicationSet "apps" (List)   │
 │                                    ├─► Application podinfo      │
 │                                    └─► Application airflow ──► 이미지 pull (GHCR)
 │ [Helmfile, Phase 2 T6 이후]  ingress-nginx                       │
 │ [사람, 수동]  Secret 3종 (airflow 네임스페이스)                    │
 └─────────────────────────────────────────────────────────────────┘
```

### 3-1. 소유권 표 (상위 설계 §3-1 갱신)

| 주인 | 소유 대상 | 바뀌는 계기 |
| --- | --- | --- |
| `terraform/cluster/kind` | (변경 없음) | — |
| `terraform/platform` | `argocd` 네임스페이스, ArgoCD, **ApplicationSet `apps` 와 그 앱 목록** | 앱 추가·제거 시 `apply` |
| Helmfile (Phase 2 T6 이후) | ingress-nginx **만** | `helmfile apply` |
| ArgoCD (ApplicationSet 경유) | Application `podinfo`·`airflow` 와 그 하위 리소스, `podinfo` 네임스페이스 | Git 커밋 → 폴링 |
| GitHub Actions | GHCR 이미지, `gitops/charts/airflow/values.yaml` 의 **태그 한 줄** | git tag push |
| 사람 | `airflow` 네임스페이스, Airflow Secret 3종 (값은 Git 밖) | 클러스터 생성 시 1회 |

### 3-2. 불변 규칙

1. **이미지 태그는 Terraform 에 넣지 않는다.** List element 는 `name`·`path`·`namespace` 만 갖는다.
   태그가 Terraform 에 있으면 이미지 변경마다 `apply` 가 필요해져 요구 ④(pull)가 깨진다.
2. **클러스터 안 Git 쓰기 자격증명 0개.** GHCR 패키지는 public 이라 pull 자격증명도 0개다.
3. **Terraform 이 ArgoCD 를 소유하는 것을 유지한다**(사용자 제약, 2026-10-07). 상위 설계 D7 의 소유권
   이전 실험은 ingress-nginx 로 축소한다(§9).
4. **Git 에 자동으로 쓰는 주체는 GitHub Actions 하나**이고, 그것이 고치는 곳은 values 파일의 태그 한 줄뿐이다.

---

## 4. 구성요소

### 4-1. `terraform/platform/charts/appset/` (기존 `charts/root-app/` 대체)

root Application 을 쓰던 이유(D5 정정 — CRD 가 plan 시점에 없어 `kubernetes_manifest` 불가)가
ApplicationSet 에도 똑같이 적용되므로 **로컬 chart + `helm_release`** 패턴을 그대로 쓴다.

```
charts/appset/
  Chart.yaml
  values.yaml                     # namespace, repoUrl(required), targetRevision, apps: []
  templates/applicationset.yaml
```

템플릿의 핵심 형태:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: apps
  namespace: "{{ .Values.namespace }}"
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          {{- toYaml .Values.apps | nindent 10 }}     # Helm 이 렌더 — 이스케이프 불필요
  template:
    metadata:
      name: '{{`{{ .name }}`}}'                       # ApplicationSet 이 렌더 — Helm 이스케이프
    spec:
      project: default
      source:
        repoURL: '{{ required "..." .Values.repoUrl }}'
        targetRevision: "{{ .Values.targetRevision }}"
        path: '{{`{{ .path }}`}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{`{{ .namespace }}`}}'
      syncPolicy:
        automated: { selfHeal: true, prune: true }
        syncOptions: [CreateNamespace=true]
```

- **두 겹의 템플릿을 구분한다**: `generators.list.elements` 는 **Helm 이** Terraform 값으로 채우고,
  `template.*` 의 `{{ .name }}` 등은 **ApplicationSet 컨트롤러가** 채운다. 후자만 Helm 문자열 리터럴로 감싼다.
  ✅ 이스케이프 형태 `'{{`{{ .x }}`}}'` 는 ArgoCD *"Template"* 문서가 "Helm 으로 ApplicationSet 을 배포할 때"에
  한정해 권고하는 방식이다(§11 V3-b).
- 🔴 예시 코드의 flow-style(`automated: { ... }`)은 설명용이다. 실제 파일은 block-style 로 쓴다
  — 빈 맵 영구 드리프트(`wiki/argocd-source-types.md`) 교훈.
- `automated`·`selfHeal`·`prune` 은 **세 스위치 모두 켠다**(Step 2 실험의 최종 결론 계승). 셋을 따로 설명한다.

### 4-2. Terraform 변수와 `helm_release.appset`

```hcl
variable "apps" {
  description = "ApplicationSet 이 생성할 앱 목록 — 이미지 태그는 넣지 않는다(spec 3-2 규칙 1)"
  type = list(object({
    name      = string
    path      = string
    namespace = string
  }))
  default = [
    { name = "podinfo", path = "gitops/charts/podinfo", namespace = "podinfo" },
    { name = "airflow", path = "gitops/charts/airflow", namespace = "airflow" },
  ]
  # validation: name 중복 금지, path 는 "gitops/charts/" 로 시작, name 은 DNS-1123
}
```

- `helm_release.appset` 은 `depends_on = [helm_release.argo_cd]` + `wait = true` — 기존 `root_app` 의
  실측된 순서 보장(`argocd.tf:59-64`)을 그대로 계승한다. 이것이 사용자 흐름 ②의 "ArgoCD 가 준비되면"이다.
- 값 전달은 `values = [yamlencode({ repoUrl = var.repo_url, apps = var.apps })]` 한 덩어리로 한다.

### 4-3. `gitops/charts/airflow/` umbrella chart (Phase 2 T4 흡수)

```
gitops/charts/airflow/
  Chart.yaml        # dependencies: airflow 1.22.0 @ https://airflow.apache.org
  Chart.lock        # 커밋한다 (digest 고정)
  values.yaml       # 기존 gitops/values/airflow.yaml 을 `airflow:` 키 아래로 한 단계 내린 것
  .helmignore
```

- `charts/` 디렉터리(.tgz)는 `.gitignore` 한다 — ArgoCD repo-server 가 렌더 시 받는다.
  ✅ 근거(§11 V4): v3.5.3 소스 `reposerver/repository/repository.go` — `helm template` 이 *"found in Chart.yaml,
  but missing in charts/ directory"* 로 실패할 때만 `runHelmBuild` 가 `helm dependency build` 를 실행하고
  (`.argocd-helm-dep-up` 마커로 1회), Chart.yaml 의 https 의존성 저장소는 ArgoCD 에 미등록이어도 `RepoAdd` 대상이
  된다. ⇒ `charts/` 를 커밋하지 않는 것이 **자동 빌드의 전제조건**이다(커밋하면 빌드를 건너뛴다).
  🔴 ArgoCD Helm 사용자 가이드에는 이 동작 서술이 **없다** — 근거는 소스뿐이다. 실동작은 G3 에서 관측한다.
- **실측(2026-10-07, helm v4.2.0, scratchpad)**: `helm dependency build` 성공(tgz 291,304 B), umbrella
  렌더와 공식 chart 직접 렌더의 diff 16줄이 **전부 랜덤 생성 secret 값**(`jwt-secret`·`fernet-key`·
  `checksum/jwt-secret`) — 구조 동등.
- values 추가분:

| 키 | 값 | 이유 |
| --- | --- | --- |
| `airflow.images.airflow.repository` | `ghcr.io/melting-face/airflow-dags` | 커스텀 이미지 |
| `airflow.images.airflow.tag` | `v0.1.0` | **CI 가 고치는 유일한 줄** |
| `airflow.fernetKeySecretName` | `airflow-fernet-key` | 렌더 결정성(§6 F1) |
| `airflow.jwtSecretName` | `airflow-jwt-secret` | 렌더 결정성 |
| `airflow.apiSecretKeySecretName` | `airflow-webserver-secret` | 기존 유지 (`webserverSecretKeySecretName` 은 Airflow 2 전용이라 효과 없음 — 기존 values 주석과 일치) |

  ✅ 데이터 키 이름(§11 V5, chart 1.22.0 `templates/secrets/*` 와 `_helpers.yaml` 원문): `fernet-key`
  (→ `AIRFLOW__CORE__FERNET_KEY`), `jwt-secret`(→ `AIRFLOW__API_AUTH__JWT_SECRET`), `api-secret-key`
  (→ `AIRFLOW__API__SECRET_KEY`). 각 `*SecretName` 이 비어 있을 때만 chart 가 Secret 을 스스로 만든다.
  Production Guide 1.22.0 도 *"You should set a static API secret key ..."*, *"... static JWT Secret key ..."* 를 권고한다.
- 기존 `gitops/values/airflow.yaml` 은 **옮기고 지운다**(같은 내용의 두 정본을 두지 않는다).

### 4-4. `images/airflow/`

```
images/airflow/
  Dockerfile        # FROM apache/airflow:3.2.2 ; COPY dags/ /opt/airflow/dags/
  dags/hello.py     # 단일 태스크 DAG
```

- DAG 기본 경로 `/opt/airflow/dags` 는 렌더된 `airflow.cfg` 의 `dags_folder` 로 실측했다(2026-10-06).
- DAG 는 **`timezone="Asia/Seoul"`**(pendulum) 을 명시한다 — CLAUDE.md 타임존 정책의 첫 적용례.
- `apache/airflow:3.2.2` 는 linux/arm64 를 공식 제공한다(2026-10-06 `podman manifest inspect` 실측).

### 4-5. `.github/workflows/image.yml`

| 항목 | 값 |
| --- | --- |
| 트리거 | `push: tags: ['v*.*.*']` — **사람이 semver 태그를 push 할 때만** |
| 러너 | `ubuntu-24.04-arm` (네이티브 arm64, QEMU 없음) — public 저장소 전용·무료 GA(2025-08-07, §11 V2) |
| 권한 | `permissions: { contents: write, packages: write }` — 기본 `GITHUB_TOKEN` 만, 추가 PAT·Secret 없음 |
| 단계 | ① checkout → ② GHCR 로그인(`GITHUB_TOKEN`) → ③ build·push `airflow-dags:${tag}` (linux/arm64) → ④ `main` checkout → ⑤ `yq` 로 `airflow.images.airflow.tag` 갱신 → ⑥ 커밋 `chore(airflow): 이미지 태그를 ${tag} 로 갱신` → ⑦ push (실패 시 `pull --rebase` 후 1회 재시도) |

- **루프가 구조적으로 없다**: 트리거가 tag push 이고 봇 커밋은 branch push 다. 이중으로, GitHub Docs 가
  *"if a workflow run pushes code using the repository's `GITHUB_TOKEN`, a new workflow will not run"* 라고
  명시한다(§11 V1, 예외는 `workflow_dispatch`·`repository_dispatch`).
  🔴 `contents: write` 로 `main` push 가 되는지의 정의 문서는 아직 못 읽었다(V1-c) — 첫 실행이 판정한다. `ci.yml` 이 봇 커밋에 안 도는
  것도 같은 이유라 **봇 커밋은 서버 정적 검사를 받지 않는다** — 고치는 범위가 태그 한 줄이라 수용한다.
- 봇 커밋 제목은 Conventional Commits 를 따른다(`.gitlint` 와 같은 형식). 로컬 훅은 돌지 않는다.
- **빌드가 실패하면 태그 커밋도 없다** — `bump` job 이 `needs: build` 라 "이미지가 GHCR 에 있다"가 커밋의 전제조건이다.
- **추가 규칙(grilling 2026-10-07)**: ① 태그 커밋이 `origin/main` 의 조상이 아니면 실패(Q1) ② GHCR 에 같은 태그가
  이미 있으면 실패 — 태그 불변(Q2) ③ job 을 `build`·`bump` 로 나눠 `bump` 실패 시 "Re-run failed jobs" 로만 복구(Q7)
  ④ **태그는 빌드 이벤트, 배포 상태는 `main` 의 values 한 줄** — 롤백은 봇 커밋 `git revert`, 재전진은 그 revert 의
  revert(Q4·Q8)

---

## 5. 데이터 흐름

### 5-1. 부트스트랩 (Phase 3 완료 시점, Phase 2 T6 이전)

```
terraform -chdir=terraform/cluster/kind apply
(사람) Airflow Secret 3종 생성 — docs/airflow-secret.md       ← airflow 네임스페이스 선생성 포함
terraform -chdir=terraform/platform apply
  ingress_nginx (wait) → argo_cd (wait) → appset (wait)
ArgoCD: ApplicationSet → Application 2개 → 각자 sync
```

**네임스페이스 주인**: Secret 은 Application 보다 먼저 있어야 하므로 **사람이 `airflow` 네임스페이스를 먼저
만든다** — 기존 절차(`docs/airflow-secret.md` 1단계, `create --dry-run | apply` 멱등)를 그대로 따른다.
`CreateNamespace=true` 는 이미 있는 네임스페이스를 그대로 쓸 뿐이라(`managedNamespaceMetadata` 를 쓰지 않으므로)
ArgoCD 가 그 네임스페이스를 소유하지 않는다. 따라서 §3-1 표에서 `airflow` 네임스페이스의 주인은 **사람**이다
(`podinfo` 네임스페이스는 ArgoCD). 이 비대칭을 위키에 적는다.

Phase 2 T6 이후의 부트스트랩은 **kind TF → `helmfile apply`(ingress-nginx) → platform TF** 로 도구를
넘나든다 — `argo_cd.depends_on = [ingress_nginx]`(`argocd.tf:23`, R4 webhook 경합)를 Terraform 안에서
표현할 수 없게 되기 때문이다. 이 변경은 Phase 2 T6 가 다룬다.

### 5-2. 이미지 변경 (정상 경로)

```
사람: images/airflow/dags/ 수정 → main 커밋·push   (이 시점엔 아무것도 배포되지 않는다)
사람: git tag v0.1.1 && git push origin v0.1.1
Actions: build → push ghcr.io/melting-face/airflow-dags:v0.1.1 → values.yaml 태그 커밋 → push main
ArgoCD: 폴링 주기 안에 새 커밋 감지 → airflow 재렌더 → OutOfSync → 자동 sync → 파드 롤링
```

폴링 주기는 `timeout.reconciliation` 기본 **120s** + `timeout.reconciliation.jitter` 기본 **최대 60s**
(§11 V6) — 커밋 감지까지 **최대 약 3분**이 예상 범위다. 성공 기준 4 의 관측에서 "태그 push → 파드 교체"
경과 시간을 실제로 기록한다(빌드 시간 포함).

### 5-3. chart·values 변경

사람이 `gitops/charts/**` 를 커밋하면 5-2 의 ArgoCD 단계만 일어난다(이미 Phase 1·2 에서 검증된 경로).

### 5-4. 앱 추가·제거

`var.apps` 수정 → `terraform apply` → ApplicationSet 이 Application 을 생성·삭제. **이 경로만 push 다** —
의도된 비대칭이다(§1-2).

### 5-5. root → ApplicationSet 이행 (1회성)

현재 `podinfo` Application 의 주인은 root 다(root 는 `prune: true`). 순서를 틀리면 워크로드가 지워진다.

1. 사전 기록: `podinfo` Deployment UID, `podinfo` Application 의 `finalizers`·`ownerReferences`
2. `helm_release.root_app` 제거 → root Application 삭제. 문서는 *"자식 앱까지 지우려면 finalizer 를 붙여라"*
   라고 한다(§11 V3-d). root 템플릿에 `resources-finalizer.argocd.argoproj.io` 가 **없으므로** 자식은 남는다고
   **추론**한다 — 직접 문장은 없다. 1 의 사전 기록과 대조해 관측한다
3. `gitops/apps/` 디렉터리 삭제 커밋 (root 가 이미 없어 prune 이 일어나지 않는다)
4. `helm_release.appset` 적용
5. ApplicationSet 이 기존 `podinfo` Application 을 **인수하는지 관측**(§11 V3-c). v3.5.3 소스상
   `CreateOrUpdate` 는 소유자를 사전 검사하지 않고 같은 이름이면 spec·labels·annotations·**finalizers** 를
   생성값으로 patch 한 뒤 `SetControllerReference` 로 소유 참조를 건다 ⇒ **인수가 예상 동작**이다.
   root 가 sync 로 만든 자식에는 controller ownerReference 가 없어 `AlreadyOwnedError` 경로는 타지 않을 것으로
   본다(🔴 추론). 인수 시 기본 finalizer 가 새로 붙어, 이후 앱 목록에서 빼면 워크로드까지 지워진다(F8).
   - 오류가 나면: `podinfo` Application 을 **non-cascade 삭제** 후 ApplicationSet 이 재생성하게 한다
6. 사후 확인: Deployment UID 불변(성공 기준 2)

2 와 4 는 같은 `apply` 한 번에 일어나도 된다(Terraform 이 삭제·생성 순서를 정한다). 하지만 **관측 지점을
나누기 위해 두 번의 apply 로 쪼갠다** — 학습 저장소의 이점이다.

---

## 6. 실패 모드

| # | 증상 | 원인 | 복구 / 예방 |
| --- | --- | --- | --- |
| F1 | 커밋마다 Airflow 파드 재시작, Connection 복호화 실패 | chart 가 fernet·jwt 를 렌더마다 랜덤 생성 | **예방**: Secret 3종을 수동 생성하고 이름만 참조(§4-3). 성공 기준 5 가 회귀 검사 |
| F2 | `helm template` 이 ApplicationSet 템플릿에서 실패하거나 `{{ .name }}` 이 빈 값 | Helm·ApplicationSet `{{ }}` 이스케이프 누락 | pre-commit `helm template` 렌더 후 `{{ .name }}` 문자열 잔존을 grep 으로 단언 |
| F3 | `airflow` Application `ComparisonError` (dependency) | repo-server 가 `airflow.apache.org` 에 도달 못 함 | Application 상태 메시지 확인. 반복되면 `charts/*.tgz` vendoring 으로 전환(§2-2 재검토) |
| F4 | `ImagePullBackOff` | GHCR 패키지가 **private 기본값**으로 생성됨, 또는 태그·아키텍처 불일치 | 첫 푸시 후 패키지 가시성을 public 으로 **1회 수동 전환**. 🔴 기본 가시성 규칙은 계획 단계에서 확인 |
| F5 | 태그 push 했는데 values 가 안 바뀜 | 빌드 실패(커밋 단계 미도달) 또는 `main` push 경합 | Actions 로그. 이미지가 없으면 커밋도 없다(안전 방향 실패). 경합은 rebase 재시도 1회 후 실패로 끝낸다 |
| F6 | ApplicationSet 적용 후 `podinfo` 가 두 주인 사이에서 충돌 | §5-5 의 이행 순서 위반 | §5-5 의 절차와 사전 기록 |
| F7 | Airflow `CreateContainerConfigError` | Secret 3종 중 누락 또는 데이터 키 이름 불일치 | `kubectl describe pod` 의 이벤트. 키 이름은 V5 로 사전 확정 |
| F8 | 앱을 목록에서 뺐더니 워크로드가 사라짐 | **의도된 동작** — ApplicationSet 이 생성한 Application 에는 `resources-finalizer` 가 기본으로 붙어 cascade 삭제된다(V3-e) | 문서화. 지우지 않고 빼려면 ApplicationSet `syncPolicy.preserveResourcesOnDeletion: true`. `applicationsSync: create-only` 계열의 삭제 보호는 문서와 소스 서술이 **상충**해 쓰지 않는다 |
| F9 | 이미지는 GHCR 에 있는데 values 가 안 바뀜, 태그 재push 도 거부됨 | `bump` job 실패 + 태그 불변 | Actions "Re-run failed jobs" 로 `bump` 만 재실행 |
| F10 | 같은 태그로 레지스트리 이미지가 바뀌었는데 파드는 옛 이미지 | 태그 덮어쓰기 + `IfNotPresent` | **예방**: 불변 검사(태그 존재 시 빌드 실패) |

---

## 7. 테스트와 완료 판정

상위 설계의 4계층을 따른다. **인프라에 붙는 검사는 CI 에 넣지 않는다.**

| 계층 | 추가되는 검사 |
| --- | --- |
| 1. 로컬 정적 | `helm lint`·`helm template` (`charts/appset` — 이스케이프 잔존 단언 포함, `gitops/charts/airflow` — `helm dependency build` 선행), `yamllint`, `actionlint`(신규 워크플로) |
| 2. 서버 정적 | `ci.yml` 의 같은 검사. 🔑 **D4 repoURL 일관성 검사 스텝은 삭제한다** — `gitops/apps/` 가 사라지면 `gitops/**` 에 repoURL 이 0개가 되고, repoURL 은 Terraform `var.repo_url` 한 곳에만 남아 **평문 중복 자체가 구조적으로 소멸**한다 |
| 3. 단위 | `tests/validation.tftest.hcl` 에 `var.apps` 검증 추가 — 이름 중복, `gitops/charts/` 접두사, DNS-1123. 각 검증은 **깨뜨려 실패하는 것을 확인**한다 |
| 4. 수동 관문 | 아래 표 |

| 관문 | 판정 명령 (기대 결과는 관측 후 기록) |
| --- | --- |
| G1 ApplicationSet 생성 | `kubectl -n argocd get applicationset apps`, `argocd app list` |
| G2 이행 무중단 | `kubectl -n podinfo get deploy podinfo -o jsonpath='{.metadata.uid}'` 이행 전·후 비교 |
| G3 Airflow 배포 | `argocd app get airflow`, 파드 이미지 확인, UI 에서 `hello` DAG 수동 트리거 |
| G4 이미지 CD | `git push origin v0.1.1` → `gh run watch` → `git log -1 origin/main` → 파드 이미지 태그 |
| G5 렌더 결정성 | 커밋 2회 전·후 `kubectl -n airflow get secret airflow-fernet-key airflow-jwt-secret -o jsonpath='{..resourceVersion}'` |
| G6 자격증명 0 | `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository` 등으로 쓰기 자격증명 부재 확인 |

---

## 8. 위키

| 노트 | 내용 |
| --- | --- |
| `applicationset-list-generator.md` (신규) | 두 겹 템플릿, Terraform 이 목록을 쥐는 이유, root 이행 관측(G2) |
| `image-cd-with-actions.md` (신규) | tag → 빌드 → 커밋 → 폴링, Image Updater 를 안 쓴 이유(보안), 경과 시간 관측(G4) |
| `airflow-on-argocd.md` (Phase 2 계획에 있던 것) | umbrella chart, 랜덤 secret 문제와 결정성(G5), KST DAG |

---

## 9. 상위 설계·Phase 2 계획에 미치는 영향

| 대상 | 변경 |
| --- | --- |
| 상위 §3-1 소유권 표 | §3-1 로 대체 (root Application → ApplicationSet, ingress-nginx 만 Helmfile) |
| 상위 D4 (repoURL 평문 중복 + CI 검사) | **소멸** — 중복 자체가 사라진다(§7). D4 에 정정 표기 |
| 상위 D5 (root 전용 로컬 chart) | 패턴 계승, 대상만 ApplicationSet 으로 |
| 상위 D7 (소유권 이전) | **ingress-nginx 로 축소** — ArgoCD 는 Terraform 유지(사용자 제약) |
| Phase 2 T4 (Airflow multi-source) | **이 spec 이 대체**. `P2-T4-R1`(repoURL 허용 목록)도 소멸 |
| Phase 2 T5 (Helmfile 선언) | ingress-nginx 만 선언 |
| Phase 2 T6 (state rm) | `helm_release.ingress_nginx` 만. `argo_cd.depends_on` 제거와 도구 횡단 부트스트랩 문서화 |
| Phase 2 T7 (파괴·복원) | **맨 마지막**에 실행해 Phase 3 결과 전체(ApplicationSet·Secret 3종·도구 횡단 순서)를 검증 |

**실행 순서**: Phase 3(이 spec) → Phase 2 T5 → T6 → T7. 상위 설계 문서와 Phase 2 계획 문서의 본문 수정은
Phase 3 구현 계획의 문서 태스크로 수행한다.

---

## 10. 리스크

| ID | 리스크 | 영향 | 대응 |
| --- | --- | --- | --- |
| P3-R1 | ApplicationSet 이 기존 `podinfo` Application 인수 중 오류(소유 참조 충돌) | 이행 절차 변경 | 소스상 인수가 예상 동작(V3-c). 오류 시 §5-5 대체 경로 |
| P3-R2 | repo-server 가 `airflow.apache.org` 에 도달 못 함 | Airflow 렌더 실패 | 소스상 자동 빌드는 확인(V4). 네트워크 실패 시 `charts/*.tgz` vendoring 으로 전환 |
| P3-R3 | 저장소를 private 으로 바꾸면 arm64 러너가 사라짐 | 빌드 불가 | arm64 러너는 public 전용(V2). 전환 시 `ubuntu-24.04` + QEMU(buildx) |
| P3-R4 | 봇 커밋이 서버 정적 검사를 우회 | 잘못된 values 가 바로 배포 | 고치는 범위를 태그 한 줄로 제한, `yq` 후 `helm template` 단계를 워크플로 안에 둔다 |
| P3-R5 | 공개 저장소에서 tag push 권한 = 배포 권한 | 의도치 않은 배포 | 저장소 쓰기 권한자 = 본인 1명. 학습 범위에서 수용 |

---

## 11. 검증 항목 — 1차 출처 확인 결과 (2026-10-07, researcher)

WebFetch 발췌 기반이라 코드 인용은 바이트 대조 원문이 아니다. 🔴 는 남은 미확인이고, **관측(G1~G6)이 최종 판정**이다.

| ID | 주장 | 판정 | 출처 (등급) |
| --- | --- | --- | --- |
| V1-a,b | `GITHUB_TOKEN` push 는 새 워크플로를 만들지 않는다. 예외 `workflow_dispatch`·`repository_dispatch` | ✅ | GitHub Docs *"Triggering a workflow"* (A) |
| V1-c | `permissions: contents: write` 로 `main` push 가능 | 🔴 미확인 | *"Permissions for the GITHUB_TOKEN"* 미열람 — 첫 실행이 판정 |
| V2 | `ubuntu-24.04-arm` public 저장소 전용·무료 GA | ✅ | GitHub Changelog 2025-08-07 *"arm64 hosted runners for public repositories are now generally available"* (B) |
| V3-a | List generator + `goTemplate: true` + `missingkey=error` | ✅ | ArgoCD *"Go Template"* (A) |
| V3-b | Helm 안 ApplicationSet 이스케이프 `'{{`{{ .x }}`}}'` | ✅ | ArgoCD *"Template"* (A) |
| V3-c | 같은 이름 기존 Application 은 인수(patch + 소유 참조) | ✅ 소스 / 🔴 실측 | `applicationset/utils/createOrUpdate.go`, `applicationset_controller.go` @ v3.5.3 (A, 발췌) |
| V3-d | finalizer 없는 root 삭제 시 자식 잔존 | 🔴 대우 추론 | ArgoCD *"Cluster Bootstrapping"*, *"App Deletion"* (A) |
| V3-e | 생성 Application 에 finalizer 기본 부착, `preserveResourcesOnDeletion` | ✅ | ArgoCD *"Application Deletion"*, *"Controlling Resource Modification"* (A) |
| V4 | v3.5.3 repo-server 자동 `helm dependency build`, 미등록 https repo 허용 | ✅ 소스 / 🔴 실측 | `reposerver/repository/repository.go`, `util/helm/helm.go` @ v3.5.3 (A) |
| V5 | Secret 데이터 키 `fernet-key`·`jwt-secret`·`api-secret-key` | ✅ | `apache/airflow` @ `helm-chart/1.22.0` `chart/templates/secrets/*` (A), *"Production Guide"* 1.22.0 (A) |
| V6 | `timeout.reconciliation` 120s + jitter 60s | ✅ | ArgoCD *"argocd-cm.yaml"* (A) |

## 12. 참고 문헌

- Argo CD — *"Generators"*, *"List Generator"*, *"Template"*, *"Controlling Resource Modification"* (argo-cd.readthedocs.io, operator-manual/applicationset)
- Argo CD — `reposerver/repository/repository.go` @ v3.1.0 (`runHelmBuild`, `getHelmRepos`) — 2026-10-07 열람
- Argo CD — *"Helm"* user guide — 2026-10-07 열람, 의존성 처리 서술 **없음**
- Apache Airflow Helm Chart 1.22.0 — *"Production Guide"*, *"Parameters reference"*
- Helm — *"Charts: Chart Dependencies"* (helm.sh/docs/topics/charts)
- GitHub Docs — *"Automatic token authentication"*, *"Supported runners and hardware resources"*
- GitHub Changelog — *"arm64 hosted runners for public repositories are now generally available"* (2025-08-07)
- Argo CD — `reposerver/repository/repository.go`, `applicationset/utils/createOrUpdate.go` @ v3.5.3
- Apache Airflow — `chart/templates/secrets/*` @ `helm-chart/1.22.0`
- Argo CD — *"argocd-cm.yaml"*, *"Application Deletion"*, *"Cluster Bootstrapping"*, *"Go Template"*
