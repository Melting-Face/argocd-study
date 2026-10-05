# ArgoCD 스터디 환경 — Phase 2 (Step 3~5) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 같은 앱을 plain manifest → 자체 Helm chart로 재작성해 ArgoCD 소스 타입 전환을 관측하고, Airflow를 공식 chart로 배포한 뒤, 플랫폼 릴리스의 소유권을 Terraform에서 Helmfile로 **실제로 이전**한다.

**Architecture:** Phase 1이 세운 2스택(`cluster/kind` + `platform`)과 root Application 위에서 진행한다. Terraform·ArgoCD의 소유권 경계(§3-1)는 그대로 두고, **Step 5에서만** 플랫폼 릴리스의 주인을 Terraform → Helmfile로 옮긴다. 새 인프라 계층을 만들지 않는다.

**Tech Stack:** Helm(자체 chart + `apache-airflow/airflow` 1.22.0), Helmfile, ArgoCD v3.5.3, Terraform(`state rm`)

**Spec:** [`docs/superpowers/specs/2026-10-04-argocd-study-design.md`](../specs/2026-10-04-argocd-study-design.md) §6 Step 3~5

---

## Global Constraints

Phase 1의 제약을 **전부 승계**한다. 추가·갱신분만 적는다.

- 커밋 Conventional Commits, 설명 **한국어**, 제목 **72자 이내**, 본문 **80자 이내 줄바꿈**(gitlint가 실제로 거부한다)
- 주석·문서 한국어, 리소스·변수명 영어
- 🔴 차트·이미지 **정확한 버전 고정**(`~>`·`latest` 금지). `docs/conventions/terraform.md` §2
- 🔴 `kubectl`·`argocd`·`helm` 은 **반드시**:
  ```bash
  export KUBECONFIG=~/.kube/argocd-study.config   # 기본 current-context 는 kind-lakehouse(다른 프로젝트)
  # 그 뒤 모든 명령에 --context kind-argocd-study
  ```
- `argocd login argocd.localtest.me:8081 --username admin --plaintext` (Phase 1 실측: `--insecure` 아님)
- 호스트명은 `*.localtest.me`, 호스트 포트 **8081**
- 🔴 **승인 게이트는 사실상 없다**(R13). `terraform destroy`·`kind delete cluster`·`helm uninstall`은 **막아줄 것이 없다**
- 🔴 기존 `lakehouse` 클러스터를 **절대** 건드리지 않는다
- `wiki/<slug>.md` 평평·프론트매터 금지·링크에 `.md` 붙임·H1 한국어. `_Sidebar.md` 갱신
- 🔴 **관측하지 않은 출력을 적지 않는다.** 관측이 없으면 명령까지만 쓰고 기대 출력을 비운다

### Phase 1이 남긴 상태 (이 계획의 출발점)
```
app podinfo  Synced/Healthy  (source: directory, gitops/manifests/podinfo)
             syncPolicy: {automated:{prune:true,selfHeal:true}, syncOptions:[CreateNamespace=true]}
app root     Synced/Healthy  (gitops/apps, directory.recurse)
helm 릴리스: ingress-nginx(4.15.1) · argo-cd(10.9.6) · root-app(로컬 chart) — 전부 Terraform 소유
```

---

## Review Focus

- **Airflow 3에서 values 키 경로가 바뀌었다** — 차트 1.22.0은 appVersion **3.2.2**다. UI를 서빙하는 것은 `webserver`가 아니라 **`apiServer`**이고, ingress 블록도 **`ingress.apiServer`**다(`ingress.web`은 레거시). 🔴 **Helm은 모르는 키를 조용히 버리므로**, 옛 경로로 쓰면 `apply`는 성공하고 **UI만 안 열린다**. (Task 3)
- **기본 executor가 `CeleryExecutor`다** — spec은 LocalExecutor를 요구한다. 안 바꾸면 `redis`(기본 `enabled: true`)·worker가 뜨고 **26GB를 `lakehouse`와 공유하는 환경에서 자원이 샌다**. (Task 3)
- **`terraform state rm`은 백업 없이는 되돌릴 수 없다** — 이 계획에서 유일하게 복구 불가능한 조작이다. (Task 6)
- **소스 타입 전환이 파드를 재생성할 수 있다** — 결과 매니페스트가 미묘하게 달라지면 재생성되고, 운영이라면 다운타임이다. 이게 Step 3의 핵심 질문이다. (Task 2)
- **자원 경합** — Airflow(LocalExecutor로도 scheduler·apiServer·dagProcessor·triggerer·postgres ≈5파드 + PVC) + ArgoCD 7파드 + ingress-nginx. (Task 4)

---

## File Structure

| 파일 | 책임 |
| --- | --- |
| `gitops/charts/podinfo/**` | Step 1 plain manifest와 **같은 결과**를 내는 자체 chart |
| `gitops/apps/podinfo.yaml` | `source`를 `directory` → `helm`으로 전환 |
| `gitops/values/airflow.yaml` | Airflow 공식 chart values (Airflow 3 키 경로) |
| `gitops/apps/airflow.yaml` | Airflow Application |
| `helmfile.yaml` | 플랫폼 릴리스 2개(ingress-nginx·argo-cd) 재선언 |
| `wiki/{writing-a-helm-chart,argocd-source-types,airflow-on-argocd,helmfile-vs-terraform,who-owns-what}.md` | 관측 기록 |
| `docs/conventions/k8s.md` | Helm chart 작성 규약 보강(Task 1) |

---

## Task 1: podinfo 자체 Helm chart

**Files:**
- Create: `gitops/charts/podinfo/{Chart.yaml,values.yaml,.helmignore}`, `gitops/charts/podinfo/templates/{deployment,service,ingress,_helpers.tpl}.yaml`
- Modify: `.pre-commit-config.yaml`(`helm lint` 훅 추가), `docs/conventions/k8s.md`
- Create: `wiki/writing-a-helm-chart.md` / Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: `gitops/manifests/podinfo/{deployment,service,ingress}.yaml` (Phase 1 산출물 — **정답지**다)
- Produces: `gitops/charts/podinfo/` — Task 2가 Application의 `source.helm`으로 가리킨다. values 키: `image.tag`·`replicaCount`·`ingress.host`·`resources`

- [ ] **Step 1: 동등성 테스트를 먼저 만든다**

`helm template` 결과와 plain manifest가 **의미상 같은지** 비교하는 스크립트를 `gitops/charts/podinfo/tests/equivalence.sh` 로 쓴다. 두 쪽을 정규화(`yq` 또는 `kubectl --dry-run=client -o yaml`)해 diff 한다.
🔴 **무엇을 "의미 있는 차이"로 볼지 스크립트에 명시하라** — Helm이 붙이는 `app.kubernetes.io/managed-by: Helm`·`helm.sh/chart` 레이블은 **정당한 차이**다. 그 외의 차이는 실패로 본다.

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
bash gitops/charts/podinfo/tests/equivalence.sh
```
Expected: FAIL — chart가 아직 없다. 출력을 보고서에 남긴다.

- [ ] **Step 3: chart 구현**

`Chart.yaml`(`apiVersion: v2`, `type: application`, `version`·`appVersion` 고정), `values.yaml`, 템플릿 4개.
🔴 **Phase 1이 매니페스트에 박은 값을 그대로 가져와라** — 이미지 태그 `6.15.0`, `runAsUser: 100`/`runAsGroup: 101`(비숫자 USER 때문에 `runAsNonRoot`가 검증 못 하던 문제의 해결책), requests/limits 4값, `ingressClassName: nginx`, host `podinfo.localtest.me`, containerPort 9898.
🔴 **`_helpers.tpl`의 레이블은 Phase 1 매니페스트의 레이블과 일치시켜라** — 어긋나면 셀렉터가 깨져 Task 2에서 파드가 재생성된다(그러면 Step 3의 핵심 질문에 답할 수 없다).

- [ ] **Step 4: 테스트 통과 확인**

```bash
bash gitops/charts/podinfo/tests/equivalence.sh      # 의미 있는 차이 0건
helm lint gitops/charts/podinfo --strict
helm template podinfo gitops/charts/podinfo | head -40
```

- [ ] **Step 5: `helm lint` 를 pre-commit 게이트로 추가**

spec §7-4가 계획했으나 Phase 1에서 **도입되지 않았고**, 최종 리뷰가 `AGENTS.md`에 「Helm chart 린트 게이트 — 없음」으로 기록했다. 이제 chart가 둘(`charts/root-app`, `gitops/charts/podinfo`)이니 도입한다.
🔴 **일부러 깨뜨려 잡히는지 확인하라** — `Chart.yaml`의 필수 필드를 지워 `helm lint`가 FAIL 하는 것을 관측하고 되돌려라.
⚠️ Phase 1 실측: **`helm lint --strict`는 `required` 미충족을 WARN으로만 낸다**(`helm template`이라야 실패). 이 한계를 훅 주석에 적고, `AGENTS.md`의 "없음" 행을 **실제 도입 내용 + 이 한계**로 갱신하라.

- [ ] **Step 6: `docs/conventions/k8s.md` 에 Helm chart 규약 추가**

이 저장소의 chart가 지킬 것: 버전 고정, `required`로 필수값 강제(초록불 함정 방지), 레이블 규약, `.helmignore`.

- [ ] **Step 7: 위키 `writing-a-helm-chart.md` 작성 + 커밋**

plain manifest → chart 재작성에서 **실제로 걸린 것**을 적어라. 동등성 스크립트가 무엇을 정당한 차이로 보는지, `helm lint`의 한계도.
🔴 **클러스터를 건드리지 않는다** — 이 Task는 파일 작업뿐이다. `argocd app` 상태가 변하면 안 된다.

---

## Task 2: 소스 타입 전환과 재생성 관측 ★ Step 3의 핵심 질문

**Files:**
- Modify: `gitops/apps/podinfo.yaml` (`source.path` → `source.helm`)
- Create: `wiki/argocd-source-types.md` / Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: Task 1의 `gitops/charts/podinfo/`
- Produces: `source.helm`을 쓰는 podinfo Application — Phase 2 이후의 기준 상태

- [ ] **Step 1: 전환 **전** 상태를 기록한다**

```bash
kubectl --context kind-argocd-study get pod -n podinfo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.metadata.creationTimestamp}{"\n"}{end}'
kubectl --context kind-argocd-study get rs -n podinfo -o name
argocd app get podinfo
```
🔴 **이 출력이 비교 기준이다.** 보고서에 raw 그대로 남겨라.

- [ ] **Step 2: Application 의 source 를 전환하고 커밋·푸시**

`path: gitops/manifests/podinfo` → `path: gitops/charts/podinfo` + `helm:` 블록(values 오버라이드가 필요하면 최소한으로).
⚠️ `automated: {prune:true, selfHeal:true}` 가 켜져 있으므로 **푸시하면 자동으로 적용된다.** 적용 과정을 지켜봐라.

- [ ] **Step 3: 🔑 파드가 재생성됐는가 — 관측**

```bash
argocd app get podinfo            # Synced/Healthy 로 수렴하는가
kubectl --context kind-argocd-study get pod -n podinfo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}'   # Step 1 과 비교
kubectl --context kind-argocd-study get rs -n podinfo    # ReplicaSet 이 새로 생겼는가
kubectl --context kind-argocd-study get events -n podinfo --sort-by=.lastTimestamp | tail -10
```
- **UID 가 같다** → 재생성 없음. ArgoCD가 결과 매니페스트만 본다는 증거
- **UID 가 바뀌었다** → 재생성됨. 🔴 **무엇이 달랐는지 찾아라** — `argocd app diff` 와 Task 1의 동등성 스크립트를 다시 돌려 **어느 필드가 원인인지** 특정하라. "재생성됐다"로 끝내지 말 것
- 🔴 **어느 쪽이든 그게 답이다.** 기대한 쪽으로 쓰지 말고 관측한 쪽을 적어라

- [ ] **Step 4: 접속 확인**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081   # 200
```

- [ ] **Step 5: 위키 `argocd-source-types.md` 작성 + 커밋**

`directory`·`helm`·`kustomize` 소스 타입의 차이, **전환 시 무슨 일이 일어나는가**(Step 3 관측), ArgoCD가 "생성 수단"이 아니라 "결과 매니페스트"를 본다는 것의 의미와 **그 한계**(결과가 1비트라도 다르면 재생성된다).

---

## Task 3: Airflow values 준비 — **배포하지 않는다**

**Files:**
- Create: `gitops/values/airflow.yaml`
- Create: `docs/airflow-secret.md` (Secret 수동 생성 절차)

**Interfaces:**
- Produces: `gitops/values/airflow.yaml` — Task 4의 Application이 `helm.valueFiles`로 가리킨다. Secret 이름: `airflow-webserver-secret`(키 `webserver-secret-key`)

- [ ] **Step 1: 차트 사실을 먼저 실측한다**

```bash
helm show values apache-airflow/airflow --version 1.22.0 > /tmp/af-values.yaml
grep -nE '^(executor|airflowVersion|defaultAirflowTag):' /tmp/af-values.yaml
grep -n -A3 '^ingress:' /tmp/af-values.yaml
```
🔴 **컨트롤러가 확인한 사실**(이걸 기준으로 쓰되 **당신도 재확인하라**):
- 차트 **1.22.0** / appVersion **3.2.2** — **Airflow 3**이다
- 기본 `executor: "CeleryExecutor"` → **`LocalExecutor`로 바꿔야 한다**
- UI를 서빙하는 것은 **`apiServer`**(`webserver`는 레거시 블록). ingress도 **`ingress.apiServer`**
- 기본 `enabled`: `redis=true` · `statsd=true` · `triggerer=true` · `postgresql=true` · `flower=false` · `pgbouncer=false`

- [ ] **Step 2: `gitops/values/airflow.yaml` 작성**

- `executor: LocalExecutor`
- 🔴 **LocalExecutor에서 불필요한 것을 끈다**: `redis.enabled: false`(기본 true — **안 끄면 쓸모없는 파드가 뜬다**), `statsd.enabled: false`. `triggerer`는 Airflow 3에서 deferrable 태스크에 쓰이므로 **끌지 말지 판단하고 이유를 적어라**
- `postgresql.enabled: true` 유지(차트 내장 — 학습 환경에 적절). PVC는 substrate 계약 ③의 `standard` StorageClass
- `ingress.apiServer`: `enabled: true`, `host: airflow.localtest.me`, `ingressClassName: nginx`
- `webserverSecretKeySecretName: airflow-webserver-secret` — 🔴 **값을 Git에 넣지 않는다**
- requests/limits 명시(`docs/conventions/k8s.md` §2)

- [ ] **Step 3: 🔴 키가 실제로 먹는지 `helm template`으로 증명한다**

**이게 이 Task의 핵심 게이트다.** Helm은 모르는 키를 조용히 버린다.
```bash
helm template airflow apache-airflow/airflow --version 1.22.0 \
  -f gitops/values/airflow.yaml > /tmp/af-rendered.yaml
grep -c 'kind: Deployment\|kind: StatefulSet' /tmp/af-rendered.yaml
grep -n 'AIRFLOW__CORE__EXECUTOR' /tmp/af-rendered.yaml | head -3    # LocalExecutor 인가
grep -c 'redis' /tmp/af-rendered.yaml                                 # 0 이어야 한다
grep -n -A5 'kind: Ingress' /tmp/af-rendered.yaml                     # host·ingressClassName
grep -n 'airflow-webserver-secret' /tmp/af-rendered.yaml              # Secret 참조
```
🔴 **각 명령의 실제 출력을 보고서에 남겨라.** 하나라도 기대와 다르면 키 경로가 틀린 것이다 — 고치고 다시 렌더하라.

- [ ] **Step 4: 렌더된 파드 수와 자원 요구를 계산한다**

```bash
grep -c 'kind: Deployment\|kind: StatefulSet\|kind: Job' /tmp/af-rendered.yaml
```
그리고 렌더 결과에서 `resources.requests` 의 cpu·memory 를 **합산**하라(방법은 당신 판단 —
`yq` 든 python 이든). 합계 두 숫자와 **어떻게 셌는지**를 보고서에 적어라.
🔴 **ArgoCD 7파드 + ingress-nginx 1 + podinfo 1 위에 얹힌다.** 합계를 보고서에 적고, R7(자원 경합) 판단 근거로 삼아라. `lakehouse` 중지가 필요하면 Task 4에서 전제로 명시하라.

- [ ] **Step 5: `docs/airflow-secret.md` 작성 — Secret 수동 생성 절차**

```bash
kubectl --context kind-argocd-study create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
kubectl --context kind-argocd-study -n airflow create secret generic airflow-webserver-secret \
  --from-literal=webserver-secret-key="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
```
🔴 **왜 Git에 안 넣는지**(§2-2 범위 밖 결정: SOPS/Sealed/External Secrets는 축 하나)와 **그 대가**(수동 단계라 "전체 파괴 후 복원"이 완전 자동이 아니게 된다)를 함께 적어라. 이건 Phase 1의 "수동 개입 0회" 성과에 **구멍을 내는 것**이고, 정직하게 기록해야 한다.

- [ ] **Step 6: 커밋**

🔴 클러스터를 건드리지 않는다. 이 Task는 파일 + `helm template` 뿐이다.

---

## Task 4: Airflow 배포

**Files:**
- Create: `gitops/apps/airflow.yaml`
- Create: `wiki/airflow-on-argocd.md` / Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: `gitops/values/airflow.yaml`(Task 3), Secret `airflow-webserver-secret`
- Produces: `airflow` Application — Synced/Healthy

- [ ] **Step 1: 전제 확인 — 자원**

```bash
KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters        # lakehouse 상태
podman machine inspect podman-machine-default --format '{{.Memory}} {{.CPUs}}'
kubectl --context kind-argocd-study top node 2>/dev/null || echo "metrics 없음 — 가용"
```
🔴 Task 3 Step 4의 합계와 대조하라. `lakehouse`가 **실행 중이면 중지**하고(그 클러스터 자체는 **삭제하지 않는다**), 그 사실을 보고서에 적어라.

- [ ] **Step 2: Secret 을 수동 생성한다**

`docs/airflow-secret.md` 절차를 그대로 실행하고 **출력을 남겨라**.
```bash
kubectl --context kind-argocd-study -n airflow get secret airflow-webserver-secret -o jsonpath='{.metadata.name}{"\n"}'
```
🔴 **값을 보고서·위키에 적지 마라.** 이름과 존재만 확인한다.

- [ ] **Step 3: `gitops/apps/airflow.yaml` 작성·커밋·푸시**

`source`: repoURL(다른 Application과 **동일 문자열** — CI 검사가 본다), `chart: airflow`, `repoURL: https://airflow.apache.org`(차트 저장소), `targetRevision: 1.22.0`, `helm.valueFiles: [$values/gitops/values/airflow.yaml]` 또는 multi-source.
⚠️ **차트가 외부 저장소에 있으므로 Application의 source 구조가 podinfo와 다르다.** multi-source(`sources:`)가 필요할 수 있다 — 실제로 어떤 형태가 되는지 확인하고 **그 차이를 위키에 적어라**.
`destination.namespace: airflow`, `syncOptions: [CreateNamespace=true]`.

- [ ] **Step 4: 동기화와 완료 판정**

```bash
argocd app get airflow                                   # Synced/Healthy
kubectl --context kind-argocd-study get pods -n airflow
kubectl --context kind-argocd-study get pvc -n airflow   # Bound
curl -sS -o /dev/null -w '%{http_code}\n' http://airflow.localtest.me:8081   # 200
```
🔴 **CRD·훅 순서 문제가 날 수 있다**(차트가 migration Job을 쓴다). 실패하면 **에러 원문을 그대로** 기록하고 원인을 찾아라.

- [ ] **Step 5: example DAG 1개를 실행해 success 까지 확인**

UI 또는 `airflow` CLI(파드 exec)로 트리거한다. **어느 DAG을, 어떻게 트리거했고, 얼마나 걸렸는지** 적어라.

- [ ] **Step 6: 위키 `airflow-on-argocd.md` 작성 + 커밋**

Airflow 3의 키 경로 변경(`webserver`→`apiServer`), LocalExecutor로 끈 것들과 이유, **Secret을 수동으로 둔 대가**, multi-source 구조, 자원 합계, 겪은 실패와 해결. 🔴 관측한 것만.

---

## Task 5: Helmfile 선언과 diff — **소유권은 안 건드린다**

**Files:**
- Create: `helmfile.yaml`, `helmfile.d/values/`(필요하면)
- Modify: `.pre-commit-config.yaml`(`helmfile lint` 훅)
- Create: `wiki/helmfile-vs-terraform.md`(전반부) / Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: `terraform/platform/values/ingress-nginx.kind.yaml`, `terraform/platform/values/argocd.yaml.tftpl`(렌더 결과)
- Produces: `helmfile.yaml` — Task 6이 `helmfile apply`로 인수한다

- [ ] **Step 1: `helmfile` 설치 확인**

```bash
command -v helmfile || brew install helmfile
helmfile --version
```
🔴 **버전을 고정 기록하라**(이 저장소 규약). 설치했으면 `README.md` 전제조건에 반영.

- [ ] **Step 2: Terraform이 실제로 적용한 values 를 추출한다**

```bash
helm get values ingress-nginx -n ingress-nginx -o yaml > /tmp/live-ingress.yaml
helm get values argo-cd -n argocd -o yaml > /tmp/live-argocd.yaml
```
🔴 **`.tftpl`을 읽어 추측하지 말고 살아 있는 릴리스에서 뽑아라.** `templatefile`이 주입한 `repo_url`이 들어 있다.

- [ ] **Step 3: `helmfile.yaml` 작성**

릴리스 2개(`ingress-nginx` 4.15.1, `argo-cd` 10.9.6)를 선언한다. 네임스페이스·차트 저장소·버전을 **Terraform과 정확히 동일하게**. values는 Step 2에서 뽑은 것을 기준으로 한다.
⚠️ `root-app`(로컬 chart)은 **이번 범위에서 제외**한다 — Terraform이 계속 소유한다. 그 이유를 주석에 적어라.

- [ ] **Step 4: 🔑 `helmfile diff` 로 동등성을 증명한다**

```bash
helmfile diff
```
🔴 **차이가 0이어야 한다.** 차이가 있으면 **Task 6을 시작하면 안 된다** — `helmfile apply`가 릴리스를 바꿔버린다. 차이가 나오면 그 내용을 기록하고 `helmfile.yaml`을 맞춰라.
🔴 **출력을 raw 그대로 보고서에 남겨라.** 이게 Task 6의 안전 근거다.

- [ ] **Step 5: `helmfile lint` 를 pre-commit 에 추가하고 깨뜨려 확인**

- [ ] **Step 6: 위키 `helmfile-vs-terraform.md` 전반부 작성 + 커밋**

Terraform `helm_release` vs Helmfile `release` 의 선언 방식 비교, 상태를 어디에 두는가(state 파일 vs Helm 릴리스 시크릿), `helmfile diff`가 무엇을 보장하는가.
🔴 **아직 소유권을 옮기지 않았다**는 것을 명시하라. 후반부는 Task 6이 쓴다.

---

## Task 6: 소유권 이전 ★ 이 프로젝트의 결론부

**Files:**
- Modify: `terraform/platform/{ingress,argocd}.tf`(이전된 리소스 제거), `terraform/platform/README.md`
- Modify: `wiki/helmfile-vs-terraform.md`(후반부), `wiki/argocd-bootstrap.md`(부트스트랩 절차 변경 반영)
- Create: `wiki/who-owns-what.md` / Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: Task 5의 `helmfile.yaml`과 `helmfile diff` 0 증거
- Produces: Terraform state에서 빠지고 Helmfile이 소유하는 `ingress-nginx`·`argo-cd` 릴리스

- [ ] **Step 1: 🔴 state 백업 — 생략 불가**

```bash
cp terraform/platform/terraform.tfstate \
   .tfstate-backups/platform.tfstate.$(date +%Y%m%d-%H%M%S)
```
🔴 **이 계획에서 유일하게 복구 불가능한 조작이 다음 스텝이다.** 백업 경로를 보고서에 적어라.
그리고 `helmfile diff`를 **다시 한 번** 돌려 0인지 확인하라(Task 5 이후 상태가 바뀌었을 수 있다).

- [ ] **Step 2: 이전 **전** UID 기록**

```bash
kubectl --context kind-argocd-study get pods -n argocd -n ingress-nginx \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}'
helm history argo-cd -n argocd
helm history ingress-nginx -n ingress-nginx
```

- [ ] **Step 3: `terraform state rm` — Terraform 이 소유권을 놓는다**

```bash
terraform -chdir=terraform/platform state rm helm_release.ingress_nginx
terraform -chdir=terraform/platform state rm helm_release.argo_cd
```
🔴 **리소스는 지워지지 않는다. state 에서만 빠진다.** 실행 후 즉시:
```bash
kubectl --context kind-argocd-study get pods -n argocd    # 전부 그대로 Running 이어야 한다
```

- [ ] **Step 4: `helmfile apply` — Helmfile 이 인수**

```bash
helmfile apply
```

- [ ] **Step 5: 🔑 재생성 없이 넘어갔는가 — 관측**

```bash
kubectl ... -o jsonpath='...uid...'      # Step 2 와 비교 — 🔴 UID 불변이어야 한다
helm history argo-cd -n argocd           # revision 이 늘었는가, 어떻게
argocd app get podinfo                   # ArgoCD 자신이 멀쩡한가
curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.localtest.me:8081
```
🔴 **UID 가 바뀌었다면 "인수"가 아니라 "재설치"다.** 그 사실을 그대로 적어라.

- [ ] **Step 6: `.tf` 에서 이전된 리소스를 제거하고 `plan` 확인**

```bash
terraform -chdir=terraform/platform plan   # 🔴 놓아준 리소스가 plan 에 없어야 한다
```
🔴 **`.tf` 에 리소스 블록이 남아 있으면 plan 이 "새로 만들겠다"고 한다.** 제거하라. 다만 `root_app`은 남는다.

- [ ] **Step 7: 부트스트랩 절차가 바뀌었다 — 문서 갱신**

이제 환경을 세우려면 `terraform apply` 2회가 아니라 **`terraform apply`(cluster) → `helmfile apply` → `terraform apply`(platform, root-app만)** 이 된다(순서는 실제로 확인하라).
🔴 `README.md`·`terraform/platform/README.md`·`wiki/argocd-bootstrap.md`·**spec §3-3**이 전부 "2회"를 말한다. **전부 갱신하거나, spec 쪽은 컨트롤러에게 보고하라**(`docs/superpowers/**`는 건드리지 말 것).

- [ ] **Step 8: 위키 `who-owns-what.md` 작성 — 프로젝트의 결론부**

**이게 Phase 1+2 전체의 답이다.** 네 도구(Terraform·Helm·Helmfile·ArgoCD)가 **무엇을 어떻게 소유하는가**를 한 장에 정리하라:
- 선언 위치 / 적용 주체(push vs pull) / 상태를 어디에 두는가 / 무엇이 drift 를 되돌리는가
- §3-1 "한 리소스는 한 주인만"이 **실제로 어떻게 지켜졌는지**, 그리고 Step 5에서 주인을 **옮길 때 무엇이 필요했는지**
- 🔴 **이번에 관측한 것만.** 일반론을 쓰지 마라

- [ ] **Step 9: 커밋**

---

## Task 7: 변경된 부트스트랩으로 전체 파괴·복원 재검증

**Files:**
- Modify: `wiki/argocd-bootstrap.md`(복원 결과 갱신), `wiki/who-owns-what.md`(결론 보강)

**Interfaces:**
- Consumes: Task 6이 바꾼 부트스트랩 절차, Task 3의 수동 Secret 절차

🔑 **Phase 1은 "파괴 후 `apply` 2회로 4분 40초·수동 개입 0회"를 실증했다.** Phase 2가 그 전제를
두 군데에서 깼다 — ① 소유권 이전으로 **절차가 바뀌었고** ② Airflow Secret이 **수동 단계**다.
이 Task는 **그래서 지금은 어떻게 되는가**를 측정한다. 🔴 **"여전히 된다"를 증명하는 게 아니라
무엇이 달라졌는지 재는 것이다.**

- [ ] **Step 1: 사전 점검 — Phase 1 Step 7과 동일**

호스트 인터넷·DNS, 클러스터 내부 DNS, `git status` 비어 있음, `git log origin/main..HEAD` 비어 있음,
state 백업(타임스탬프), `terraform plan -destroy` 로 **범위에 `lakehouse` 가 없음** 확인.
🔴 하나라도 실패하면 **시작하지 말고 보고**하라. 복원 근거는 Git 뿐이다.

- [ ] **Step 2: 파괴**

```bash
terraform -chdir=terraform/platform  destroy      # 이제 root-app 만 남아 있다
helmfile destroy                                   # Helmfile 이 소유한 릴리스 2개
terraform -chdir=terraform/cluster/kind destroy
```
🔴 **순서를 실제 의존관계에 맞게 정하고 그 이유를 적어라.** Phase 1과 다르다.

- [ ] **Step 3: 복원 — 구간별 시간을 재라**

Task 6 Step 7에서 문서화한 절차를 **그대로** 따라간다. 각 명령의 소요 시간을 기록하라.
🔴 **Airflow Secret 수동 생성이 어느 지점에 끼는지** 명확히 하라 — 그게 "수동 개입 0회"가 깨지는 자리다.

- [ ] **Step 4: 복원 판정**

```bash
argocd app list                                   # root·podinfo·airflow
curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.localtest.me:8081
curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081
curl -sS -o /dev/null -w '%{http_code}\n' http://airflow.localtest.me:8081
```

- [ ] **Step 5: Phase 1과 나란히 비교해 기록**

| | Phase 1 | Phase 2 |
| --- | --- | --- |
| 명령 수 | `apply` 2회 | (측정) |
| 총 소요 | 4분 40초 | (측정) |
| 수동 개입 | **0회** | (측정 — Secret 최소 1회) |

🔴 **악화됐으면 악화됐다고 적어라.** 그게 "Secret을 Git에 안 넣는다"는 결정의 **실제 대가**이고,
spec §2-2가 그 결정을 "정한 것"이라 적은 자리의 **값을 매기는 일**이다.
복원이 **실패하면** 즉흥 수리 말고 `BLOCKED` 로 보고하라.

- [ ] **Step 6: 위키 갱신 + 커밋**

---

## Phase 2 완료 기준

| spec 성공 기준 | 검증 위치 |
| --- | --- |
| 4. Airflow 가 GitOps 로 배포되고 DAG 1개 성공 | Task 4 Step 4~5 |
| 6. 위키 10장 | Task 1·2·4·5·6 이 5장 추가 (Phase 1 의 5장 + 5 = 10) |

추가로 Phase 2 가 답하는 것:
- **소스 타입을 바꾸면 파드가 재생성되는가** (Task 2)
- **소유권을 옮길 때 리소스가 재생성되는가** (Task 6)

🔴 **Phase 1 의 "전체 파괴 후 복원 4분 40초·수동 개입 0회"는 Phase 2 가 두 군데에서 깬다** —
소유권 이전으로 절차가 바뀌었고, Airflow Secret 이 수동 단계다.
**Task 7 이 그것을 측정한다.** 악화됐으면 악화됐다고 적는 것이 이 Task 의 산출물이다.
