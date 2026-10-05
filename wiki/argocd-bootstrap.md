# ArgoCD 부트스트랩 — 스택 B, root Application, extraObjects 가 실제로 깨진 자리

`terraform/platform/argocd.tf`가 ArgoCD(argo-cd 차트 10.9.6 = ArgoCD v3.5.3)와
root Application 1개를 세우며 관측한 것을 적는다. 핵심은 하나다 — **설계
스펙(D5)이 "root Application 을 argo-cd 차트의 extraObjects 에 넣으면 CRD 순서
문제가 사라진다"고 적었는데, 실제로 그렇게 구현해 `helm install`을 돌리면
100% 재현되는 다른 실패가 난다.** 이 노트는 그 실패를 실측으로 보여주고,
무엇으로 바꿨는지, 왜 그 대안이 D5 의 원칙(`kubernetes_manifest` 미사용)을
여전히 지키는지를 적는다.

> ⚠️ 이 노트의 `kubectl`/`argocd` 명령은 전부 `export KUBECONFIG=~/.kube/argocd-study.config`
> 를 먼저 설정한 뒤 실행한 것이다 — 이 머신의 기본 kubeconfig current-context 는
> 다른 프로젝트의 `kind-lakehouse`라, 명시하지 않으면 그 클러스터를 조회해 조용히
> 틀린 결과(또는 "No resources found")를 돌려준다. 일부 명령은 그 위에 `--kubeconfig`·
> `--context`를 다시 명시해 적었다.

## Terraform 2스택 apply 절차

```bash
terraform -chdir=terraform/cluster/kind apply    # 1회차 — kind 클러스터, kubeconfig
terraform -chdir=terraform/platform apply        # 2회차 — ingress-nginx + ArgoCD + root
```

`terraform/platform`은 `cp local.auto.tfvars.example local.auto.tfvars` 로 변수
파일을 먼저 만들어야 한다(`*.tfvars`는 `.gitignore` 대상). 두 스택이 공유하는
계약 4개(`kubeconfig_path`·`kube_context`·`ingress_profile`·`storage_class`)는
[terraform-stack-boundaries](terraform-stack-boundaries.md) 참고.

## 🔴 D5 원안이 깨진 자리 — CRD 와 그 CRD 를 쓰는 CR 을 같은 `helm install` 로 만들 수 없다

설계 문서 D5 와 brief 의 원안은 이랬다:

```yaml
# values/argocd.yaml.tftpl (원안)
extraObjects:
  - apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata: { name: root, namespace: argocd }
    spec: { ... }
```

근거는 "`kubernetes_manifest`는 Terraform **plan** 시점에 API 서버에서 CRD
스키마를 조회하는데, 그 CRD 는 같은 apply 의 `helm_release`가 설치하므로 최초
plan 에서 CRD 가 없어 plan 이 죽는다(spec D5/R6) → extraObjects 는 같은
릴리스 산출물이라 CRD 와 함께 적용되어 이 순서 문제가 사라진다"였다.

**이 환경에서 그대로 구현해 실행한 결과:**

```bash
$ helm install argo-cd argo/argo-cd --version 10.9.6 -n argocd --create-namespace \
    -f <extraObjects 에 root Application 을 담은 values>
Error: unable to build kubernetes objects from release manifest: resource mapping
not found for name: "root" namespace: "argocd" from "": no matches for kind
"Application" in version "argoproj.io/v1alpha1"
ensure CRDs are installed first
```

같은 명령을 그대로 재실행해도 **똑같은 에러가 똑같이 난다** — 네임스페이스조차
생성되지 않는다(`kubectl get ns argocd` → `NotFound`, `helm history` → `release:
not found`). 부분 생성이나 운 좋은 재시도 성공 같은 건 없었다.

**원인(실측 — `helm pull argo/argo-cd --version 10.9.6 --untar` 후 직접 확인):**
이 chart 는 CRD 를 Helm 의 특수 `crds/` 디렉터리(별도 선-적용 경로)가 아니라
평범한 `templates/crds/*.yaml` 로 담고 있고(`.Values.crds.install` 로 토글), Helm
hook 애노테이션도 없다. 그래서 CRD 와 `extraObjects`의 Application 둘 다 **같은
매니페스트 문자열**로 렌더링되어 **한 번에** Kubernetes 클라이언트로 넘어간다.
Helm 클라이언트는 이 전체 매니페스트를 리소스 목록으로 "빌드"하는 단계에서
RESTMapper 로 각 오브젝트의 GVK 를 해석하는데, **이 빌드 단계는 적용(생성) 전에
끝나야 한다** — 즉 CRD 가 매니페스트 순서상 Application 보다 먼저 적용될
예정이어도, "순서대로 적용"이 시작되기도 전에 "전체를 미리 해석"하는 단계에서
아직 클러스터에 없는 CRD 때문에 막힌다.

**"같은 릴리스면 CRD 와 함께 적용되어 순서 문제가 사라진다"는 D5 의 근거는
Terraform **plan** 시점 문제(`kubernetes_manifest`)에는 맞지만, Helm **apply**
시점의 "CRD 와 그 CRD 를 쓰는 CR 을 한 install 로 함께 설치"라는, 완전히 다른
레이어의 제약에는 적용되지 않는다.** 둘 다 "CRD 타이밍 문제"라는 같은 이름으로
불렀지만 실제로는 서로 다른 문제였다.

### 해법 — `helm_release` 2개 + `depends_on`

root Application 을 `argo_cd` 릴리스와 분리해, 이 저장소가 직접 소유하는 최소
chart(`terraform/platform/charts/root-app/`, 템플릿 1개)로 **두 번째**
`helm_release`를 만든다.

```hcl
resource "helm_release" "argo_cd" {
  name   = "argo-cd"
  chart  = "argo-cd"
  # ... (extraObjects 없음)
}

resource "helm_release" "root_app" {
  name       = "root-app"
  chart      = "${path.module}/charts/root-app"
  namespace  = "argocd"
  depends_on = [helm_release.argo_cd]   # 🔑 argo_cd 가 "완전히 끝난 뒤"에만 적용
  wait       = true

  set = [{ name = "repoUrl", value = var.repo_url }]
}
```

`depends_on` 은 `argo_cd` 릴리스의 **apply 가 끝난 뒤**(CRD 가 이미 클러스터에
존재하는 시점)에야 `root_app` 릴리스를 적용한다 — 두 릴리스가 별개의 Helm
install 호출이라, `root_app` 쪽 Helm 클라이언트가 매니페스트를 빌드하는 시점엔
`Application` CRD 가 이미 API 서버 discovery 에 등록돼 있다.

**`kubernetes_manifest`는 여전히 쓰지 않는다** — D5 의 핵심(Terraform plan 이
API 서버 스키마를 조회하지 않게 한다)은 그대로 유지된다. `helm_release`는
Terraform 입장에서 `values`/`set`이 불투명한 문자열 blob이라, plan 단계에서
그 내용의 리소스 타입을 검증하지 않는다. 바뀐 것은 "Application 을 어디
안에" 넣느냐(단일 extraObjects → 두 번째 전용 릴리스)일 뿐, "무엇으로"
만드느냐(Helm, kubernetes_manifest 아님)는 그대로다.

**실제 apply 결과(2026-10-04):**

```bash
$ terraform apply -var-file=local.auto.tfvars -auto-approve
helm_release.argo_cd: Creating...
helm_release.argo_cd: Creation complete after 55s [id=argo-cd]
helm_release.root_app: Creating...
helm_release.root_app: Creation complete after 0s [id=root-app]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

한 번의 `terraform apply`로 끝났다 — 사람이 끼어들지 않았다.

## values 키 경로 — 실측

```bash
$ helm show values argo/argo-cd --version 10.9.6 | grep -n "hostname:\|extraObjects"
```

🔴 `server.ingress.hostname` 은 **단수 문자열**이다(`hosts: [...]` 배열이 아니다 —
구버전 예제를 그대로 베끼면 Helm 이 그 키를 조용히 버리고 Ingress 가
`global.domain` 기본값(`argocd.example.com`)으로 엉뚱하게 뜬다). 비우면 같은
기본값으로 폴백한다. 이번 values 는 명시했다:

```bash
$ helm get values argo-cd -n argocd
USER-SUPPLIED VALUES:
configs:
  params:
    server.insecure: true
server:
  ingress:
    enabled: true
    hostname: argocd.localtest.me
    ingressClassName: nginx
    path: /
    pathType: Prefix
    tls: false
```

## 기본 설치 컴포넌트 7개와 자원 사용량 (실측 2026-10-04)

`kubectl get pods -n argocd`:

```
argo-cd-argocd-application-controller-0                    1/1   Running
argo-cd-argocd-applicationset-controller-...                1/1   Running
argo-cd-argocd-dex-server-...                                1/1   Running
argo-cd-argocd-notifications-controller-...                  1/1   Running
argo-cd-argocd-redis-...                                     1/1   Running
argo-cd-argocd-repo-server-...                               1/1   Running
argo-cd-argocd-server-...                                    1/1   Running
```

이 클러스터(kind-on-podman)엔 `metrics-server`가 없어 `kubectl top`이 안 통한다
(`error: Metrics API not available`). 대신 kind 노드 컨테이너 안에서 containerd
의 `crictl stats`로 컨테이너별 실측치를 받았다(`podman exec
argocd-study-control-plane crictl stats --output table`):

| 컴포넌트 | CPU % | 메모리 |
| --- | --- | --- |
| `server` | ~0.02–0.04 | ~27 MB |
| `repo-server` | ~0.00–0.03 | ~29 MB |
| `application-controller` | ~0.15–0.19 | ~73–107 MB |
| `redis` | ~0.24–0.32 | ~6 MB |
| `dex-server` | ~0.00 | ~19 MB |
| `notifications-controller` | ~0.00 | ~18 MB |
| `applicationset-controller` | ~0.02–0.03 | ~21 MB |

합계 약 **190~200 MB**, CPU 는 유휴 상태 기준 1코어의 1% 미만 합산 — 이
podman machine(8 CPU / 26 GB, `lakehouse`와 공유)에서 정상 운영 범위다. 차트
기본값은 `resources.requests/limits`를 지정하지 않는다(BestOffort QoS) — Phase 1
은 학습 환경이라 그대로 뒀다.

## `repo-server` 반복 재시작 — 증상, 판정, 원인, 해결 (Fix round 1)

**증상**: `repo-server`만 재시작 횟수가 계속 늘어난다(최초 관측 103분 동안
12회, 5시간여 뒤 38회 — 한 번의 일시적 현상이 아니라 지속되는 패턴). 나머지
6개 컴포넌트는 재시작 0회로 그대로였다.

**🔑 판정 — 크래시가 아니라 kubelet 이 죽인 것이다.**

```bash
$ kubectl describe pod -n argocd <repo-server pod>
Warning  Unhealthy  Liveness probe failed: Get "http://.../healthz?full=true":
                     context deadline exceeded (Client.Timeout exceeded while awaiting headers)
Normal   Killing    Container repo-server failed liveness probe, will be restarted

$ kubectl get pod ... -o jsonpath='{.status.containerStatuses[0].lastState}'
{"terminated":{"reason":"Completed","exitCode":0, ...}}
```

`exitCode: 0`·`reason: Completed`가 핵심 증거다 — 애플리케이션이 죽은 것이면
0이 아닌 exit code 나 `Error`/`OOMKilled` 같은 reason 이 남는다. **0 과
`Completed`는 kubelet 이 liveness probe 실패를 이유로 정상 종료 신호를 보내
"죽인" 것**이지, repo-server 프로세스 자체가 크래시한 게 아니다. 이 구분이
진단의 핵심이다.

**원인**: 차트 기본값(`helm show values argo/argo-cd --version 10.9.6` 의
`repoServer.livenessProbe`/`repoServer.readinessProbe`)이
`timeoutSeconds: 1`로 매우 빡빡하고, liveness 쪽은
`httpPath: /healthz?full=true`(가벼운 핑이 아니라 전체 점검)라 더 걸리기
쉽다. 이 podman VM 은 8 CPU/26 GB 를 `lakehouse` 클러스터와 공유하므로,
일시적 스케줄링 지연이 1초를 넘기면 3회 연속 실패(기본
`failureThreshold`) 후 kubelet 이 컨테이너를 재시작한다. `crictl stats`로
본 실제 CPU 사용량 자체는 낮아(§ 위 표) 지속적인 자원 고갈로는 보이지
않는다 — "단일 노드 kind + 공유 VM + 1초 타임아웃"의 조합이 원인이라는
설명이 가장 들어맞는다.

**🔴 "Synced/Healthy 라 기능 영향 없다"로 넘기면 안 되는 이유** — 이 저장소의
후속 단계가 정확히 이 재시작 주기에 부딪힌다:
- Step 1(Task 7)의 `argocd app sync`는 repo-server 가 매니페스트를
  fetch·render 해야 끝난다. 동기화 도중 재시작하면 원인을 알 수 없는 sync
  실패로 보일 수 있다 — 초보 학습 환경에서 가장 혼란스러운 실패 양상이다.
- Step 2(Task 8)의 드리프트 실습은 "자동 복구 시점·지연을 실제로 재어
  적는다"를 요구한다. repo-server 가 몇 분마다 재시작하면 측정한 지연이
  self-heal 조정 주기인지 repo-server 재시작 대기인지 구분할 수 없어
  **측정값 자체가 오염된다.**

**해결** — `values/argocd.yaml.tftpl`에 `repoServer.livenessProbe.timeoutSeconds`·
`repoServer.readinessProbe.timeoutSeconds`를 `5`로 올렸다(기본 `1`). 5라는
값 자체가 이론적으로 최적이라는 근거는 없다 — "기본값보다 넉넉한 여유를
준다"는 판단이고, 재시작이 실제로 멈추는지를 관측으로 검증했다.
`readinessProbe`도 같은 기본값(`timeoutSeconds: 1`)이라 같은 문제를 가질 수
있어 함께 올렸다(readiness 실패는 컨테이너를 죽이지는 않지만 Service
엔드포인트에서 빠져 sync 요청이 일시적으로 실패할 수 있다 — 근본 원인이
같다면 함께 고치는 것이 맞다고 판단했다).

```bash
$ kubectl get deploy argo-cd-argocd-repo-server -n argocd \
    -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}{"\n"}{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
{"failureThreshold":3,"httpGet":{"path":"/healthz?full=true","port":"metrics","scheme":"HTTP"},"initialDelaySeconds":10,"periodSeconds":10,"successThreshold":1,"timeoutSeconds":5}
{"failureThreshold":3,"httpGet":{"path":"/healthz","port":"metrics","scheme":"HTTP"},"initialDelaySeconds":10,"periodSeconds":10,"successThreshold":1,"timeoutSeconds":5}
```

**검증 — "적용됐다"가 아니라 "재시작이 멈췄다"가 판정 기준이다.** 재시작
주기(관측상 약 8분)보다 긴 **16분** 동안 같은 파드를 1분 간격으로 관측했다:

```
04:39:57  argo-cd-argocd-repo-server-7bf47955cf-m5b2s   1/1   Running   0   31s
04:40:58  ...                                             1/1   Running   0   92s
04:41:58  ...                                             1/1   Running   0   2m32s
...
04:54:59  ...                                             1/1   Running   0   15m
=== FINAL (16분 경과) ===
          ...                                             1/1   Running   0   16m
```

**같은 파드가 16분 내내 재시작 0회를 유지했다** — 파드 이름이 바뀌지
않았다는 것(`-7bf47955cf-m5b2s`)과 AGE 가 끊김 없이 계속 증가했다는 것이
"새 파드라 0부터 시작"이 아니라 "실제로 멈췄다"는 증거다. `argocd app list`도
적용 전후 모두 `Synced/Healthy`로 변화가 없었다 — 수정이 회귀를 만들지
않았다.

### 🔴 정정 — "해결"로 닫지 않는다

이 절만 읽으면 probe 수정으로 repo-server 재시작이 끝난 것처럼 보이지만,
[`drift-and-selfheal.md`](drift-and-selfheal.md) "참고" 절은 **같은 수정이 적용된
채로** 4시간40분 동안 34회, 이후 6시간여 동안 40회까지 재시작이 늘었다고
기록한다 — "16분 0회"는 짧은 검증 구간의 우연이었을 수 있다는 뜻이다.

최종 리뷰 시점(2026-10-05, 클러스터를 Task 8 Step 7 에서 재구축한 뒤)에 다시
확인한 값은 또 다르다: `kubectl --kubeconfig ~/.kube/argocd-study.config
--context kind-argocd-study get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server`
가 **5시간40분 동안 재시작 0회**를 보였다.

세 관측을 나란히 두면:

| 관측 시점 | 관측 구간 | 재시작 |
| --- | --- | --- |
| probe 수정 직후 (이 절) | 16분 | 0회 |
| Task 8 드리프트 실험 중 | 4시간40분 → 6시간여 | 34회 → 40회 |
| 최종 리뷰 시점(재구축된 클러스터) | 5시간40분 | 0회 |

**어느 쪽이 지금의 "정상"을 대표하는지 미확인이다.** 클러스터 인스턴스(Task 8
Step 7 의 전체 파괴·재생성)와 그 사이 설정이 둘 다 바뀌었어서, "고쳐졌다"와
"이번엔 운이 좋았다"를 가를 근거가 없다. 결론을 내리지 않고 세 값을 그대로
남긴다.

## 초기 admin 비밀번호

🔴 **`argocd-initial-admin-secret`은 Helm 템플릿에 없다**(실측:
`helm template argo-cd argo/argo-cd --version 10.9.6 | grep initial-admin` → 0건).
**ArgoCD 서버가 최초 기동 시 런타임에 직접 만든다** — 서버 로그에
`"Initialized admin password"`가 찍힌다. 즉 `apply` 직후 파드가 아직 `Ready`
되기 전이면 이 Secret 이 잠깐 없을 수 있다. 설정이 틀린 게 아니라 타이밍이다.

```bash
kubectl --kubeconfig ~/.kube/argocd-study.config --context kind-argocd-study \
  -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

`outputs.tf`는 이 **명령 문자열**만 내보낸다(`argocd_initial_admin_password_command`).
🔴 비밀번호 **값**은 output 에 담지 않는다 — Terraform state 는 평문 파일이라,
값을 담는 순간 state 에 비밀이 영구히 남는다.

## `argocd login` — `--plaintext` 가 통했다, `--insecure` 는 안 통했다

`server.insecure: true` + Ingress `tls: false` 조합은 **HTTP 전용**이다. 실측:

```bash
$ argocd login argocd.localtest.me:8081 --username admin --password "$PW" --plaintext
'admin:login' logged in successfully

$ argocd login argocd.localtest.me:8081 --username admin --password "$PW" --insecure
WARNING: server is not configured with TLS. Proceed (y/n)? {"level":"fatal","msg":"EOF","time":"..."}
```

`--insecure`는 "TLS 인증서 검증을 생략한다"는 뜻이라 **여전히 TLS 핸드셰이크를
시도**하고, 평문 HTTP 서버를 만나면 비대화형 세션에서 `y/n` 프롬프트를 못
받아 `EOF`로 죽는다. `--plaintext`는 "TLS 자체를 쓰지 않는다"는 뜻이라 이
조합(서버가 진짜 HTTP)에 맞는 쪽은 `--plaintext`다.

## Review Focus (1) — 빈 `gitops/apps/`에서 root 의 상태, 두 가지를 관측했다

**(a) 경로가 아예 없을 때** (이 태스크 시작 시점 — git 이 빈 디렉터리를
추적하지 않아 `gitops/`가 저장소에 존재하지 않았다):

```
$ argocd app get root
Sync Status:        Unknown
Health Status:      Healthy

CONDITION        MESSAGE
ComparisonError  Failed to load target state: failed to generate manifest for
                 source 1 of 1: rpc error: code = Unknown desc = gitops/apps:
                 app path does not exist
```

**(b) `gitops/apps/.gitkeep`만 있는 빈 디렉터리로 바뀐 뒤** (`.gitkeep`을 commit
`67b6a1f`로 push 하고 `argocd app get root --hard-refresh`):

```
Sync Status:        Synced to main (67b6a1f)
Health Status:      Healthy
```

(CONDITION 없음.)

**두 상태는 다르다.** (a)는 `Unknown` + `ComparisonError`("경로가 없다"는
메시지)이고, (b)는 조건 없이 `Synced`다 — ArgoCD 는 "디렉터리가 없다"와
"디렉터리는 있는데 비어 있다"를 구분해서 보고한다. `directory.recurse: true`가
빈 디렉터리 자체는 유효한 소스로 받아들인다(매니페스트 0개 = 정상 Sync).

## Review Focus (2) — `targetRevision: main`과 브랜치 불일치, 침묵을 재현했다

```bash
git switch -c throwaway-probe
printf '# throwaway probe\n' > gitops/apps/probe-placeholder.yaml
git add gitops/apps/probe-placeholder.yaml
git commit -m "test: 브랜치 커밋으로 targetRevision 불일치 시 침묵 확인"
git push -u origin throwaway-probe
argocd app get root --hard-refresh    # 관측 대상
```

**관측 결과:**

```
Sync Status:        Synced to main (67b6a1f)
```

`throwaway-probe`에 새 커밋을 push 했는데도 `Sync Status`는 push 전과 **완전히
같은 커밋 해시**(`67b6a1f`, main 의 HEAD)를 그대로 가리켰다 — 아무 변화가
없었다. `--hard-refresh`로 강제로 Git 을 다시 읽게 했는데도 그렇다.
`targetRevision: main`이라 ArgoCD 는 애초에 `throwaway-probe` 브랜치를 보지
않는다 — root 가 `main`을 보는 한, 다른 브랜치에 아무리 커밋해도 **조용히
무시된다.** "커밋했는데 ArgoCD 가 반응이 없다"는 것이 초보가 가장 자주 빠지는
함정이라는 brief 의 경고가 실측으로 확인됐다.

정리:

```bash
git switch main
git push origin --delete throwaway-probe
git branch -D throwaway-probe
```

## Review Focus (3) — private 전환 시 거동 (🔴 미확인)

이 저장소는 public 이라 `argocd app` 정의에 repo 자격증명을 넣지 않았다(root
Application 의 `source.repoURL`이 익명 HTTPS fetch 로 통한다). **만약** 이
저장소를 private 로 바꾸면 ArgoCD 의 무인증 fetch 가 실패하고, `argocd repo
add https://github.com/... --username ... --password ...` 같은 방식으로 자격증명을
먼저 등록해야 할 것으로 예상된다 — 등록 전까지는 Sync 가 "조용히" 실패할
것으로 예상된다(아마 `ComparisonError`로, Review Focus (1)(a)와 비슷한 모양일
것이다).

🔴 **이 문단은 추측이다. 실제로 저장소를 private 로 전환해 재현하지 않았다**
(되돌리기 번거롭고 GitHub Actions·위키 미러 동작에 영향을 줄 수 있어서, brief
지시대로 전환 자체를 보류했다). 확인하지 않은 것을 확인했다고 적지 않는다.

## 설계 스펙 §10 — 실패 모드와 복구 경로 (🔴 Phase 1 에서 테스트하지 않음, 미검증)

| 깨진 것 | UI 접근 | 복구 |
| --- | --- | --- |
| podinfo / Airflow Application | 살아 있음 | ArgoCD UI 에서 바로 |
| root Application | 살아 있음 | `terraform apply` 재실행(root 는 Terraform 소유) |
| **ingress-nginx** | 끊김 | `kubectl port-forward` 1회 → 수정 → 복구 |
| ArgoCD 자체 | 끊김 | `terraform -chdir=terraform/platform apply` |
| 클러스터 | 끊김 | `destroy && apply` ×2 — Git 이 정본이므로 앱은 자동 복원 |

**이 표의 다섯 행 중 어느 것도 이 태스크에서 실제로 깨뜨려 보지 않았다 —
전부 설계 스펙에서 그대로 옮긴 것이고, 전부 미검증이다.**

**ingress-nginx 가 죽었을 때만 `kubectl port-forward`가 필요한 이유**(spec D3):
ArgoCD UI 는 Ingress(ingress-nginx)를 거쳐 들어간다. ingress-nginx 자체가
죽으면 그 진입로가 사라지므로 `port-forward`로 우회해야 한다. 하지만
**ingress-nginx 는 Terraform(이 스택)이 설치하지, ArgoCD 가 설치하지 않는다**
(D3 — "운영 도구가 자기 접근 경로를 자기가 배포하면 안 된다"). 만약
ingress-nginx 를 ArgoCD Application 으로 관리했다면: ingress-nginx Application
이 깨짐 → ArgoCD UI 접근 불가(ingress 가 죽었으므로) → 고치려면 UI 가 필요한데
들어갈 수 없음 → 결국 port-forward 로 복구 → "없애려던 마찰이 가장 나쁜
타이밍에 돌아온다"는 self-locking 이 생긴다. ingress-nginx 가 Terraform 소유라서
"ArgoCD 가 죽어도 ingress-nginx 는 멀쩡"하고, "ingress-nginx 가 죽었을 때만"
`port-forward`가 필요한 드문 경우로 좁혀진다.

## 완료 판정 — 실제 출력 (2026-10-04)

```bash
$ terraform -chdir=terraform/platform apply -var-file=local.auto.tfvars -auto-approve
helm_release.argo_cd: Creation complete after 55s [id=argo-cd]
helm_release.root_app: Creation complete after 0s [id=root-app]
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

$ kubectl get pods -n argocd            # 전부 Running (7/7)
$ kubectl get ingress -n argocd
NAME                    CLASS   HOSTS                 ADDRESS        PORTS   AGE
argo-cd-argocd-server   nginx   argocd.localtest.me   10.96.35.206   80      ...

$ curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.localtest.me:8081
200

$ argocd app list
NAME         ... STATUS  HEALTH   SYNCPOLICY  REPO                                              PATH         TARGET
argocd/root  ... Synced  Healthy  Auto-Prune  https://github.com/Melting-Face/argocd-study.git  gitops/apps  main

$ terraform -chdir=terraform/platform plan -var-file=local.auto.tfvars
No changes. Your infrastructure matches the configuration.
```

**port-forward 없이 UI 가 뜨는 것**(`curl` 200)이 spec 성공 기준 1번이고,
실측으로 충족했다.

## Task 8 Step 7 — 전체 파괴와 복원 (2026-10-05, spec 성공 기준 5번)

🔴 **1회 수행 — 반복 재현은 미검증이다.** 아래는 이번 한 번의 실행에서 나온 실제
출력이고, 매번 같은 시간·같은 순서로 끝난다는 보장은 아니다.

Task 8 착수 전, 호스트 와이파이 단절로 root Application 이
`Unknown/ComparisonError` 에 갇혔던 사고가 있었다(자세한 경위와 에러
메시지는 [`drift-and-selfheal.md`](drift-and-selfheal.md) "참고" 절
4번 항목). 네트워크가 복구된 뒤, 이 사고와 별개로 spec 성공 기준 5번
(전체 파괴 → `apply` 2회로 복원)을 검증했다.

사전 점검(호스트 ping/DNS, `git status`/`git log origin/main..HEAD`
모두 깨끗, 클러스터 내부 `nslookup github.com` 성공)을 모두 통과한
뒤 진행했다. `terraform/cluster/kind plan -destroy` 로 파괴 대상이
`kind_cluster.this`(`argocd-study`) 하나뿐임을 먼저 확인했다 —
기존 `lakehouse` 클러스터는 대상에 없었다. state 파일은
`terraform/cluster/kind/terraform.tfstate`, `terraform/platform/terraform.tfstate`
를 타임스탬프를 붙여 `.tfstate-backups/`(`.gitignore` 대상, 로컬
보관)에 복사해 두었다.

```bash
$ terraform -chdir=terraform/platform destroy -auto-approve
Destroy complete! Resources: 3 destroyed.          # 15:49:47 → 15:49:50 (약 3초)

$ terraform -chdir=terraform/cluster/kind destroy -auto-approve
kind_cluster.this: Destruction complete after 11s   # 15:50:17 → 15:50:29 (약 12초)

$ terraform -chdir=terraform/cluster/kind apply -auto-approve
kind_cluster.this: Creation complete after 26s      # 15:50:52 → 15:51:19 (약 27초)

$ terraform -chdir=terraform/platform apply -auto-approve
helm_release.ingress_nginx: Creation complete after 1m8s
helm_release.argo_cd: Creation complete after 1m34s
helm_release.root_app: Creation complete after 0s
Apply complete! Resources: 3 added, 0 changed, 0 destroyed.  # 15:51:41 → 15:54:26 (약 2분45초)
```

`platform apply` 완료 직후 `podinfo` Application 은 `Synced/Progressing`
이었고, **11초 뒤** `Synced/Healthy` 로 전환됐다(10초 간격 폴링으로 확인,
상한 10분 — 실제로는 1회 폴링 만에 도달). `root` 는 apply 완료 시점에
이미 `Synced/Healthy` 였다.

**수동 개입: 없었다.** 네 명령(`destroy` 2회, `apply` 2회) 이후 `argocd
app list`·`curl` 확인까지 아무 것도 손으로 고치지 않았다. 네트워크 사고
당시의 `hard refresh` 패치는 **이 Step 7 복원과는 별개 사건**이고(위
참고), 이번 destroy→apply 사이클에는 그런 개입이 없었다.

```bash
$ argocd login argocd.localtest.me:8081 --username admin --plaintext
'admin:login' logged in successfully

$ argocd app list
NAME            STATUS  HEALTH   SYNCPOLICY  REPO                                              PATH
argocd/podinfo  Synced  Healthy  Auto-Prune  https://github.com/Melting-Face/argocd-study.git  gitops/manifests/podinfo
argocd/root     Synced  Healthy  Auto-Prune  https://github.com/Melting-Face/argocd-study.git  gitops/apps

$ curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.localtest.me:8081
200
$ curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081
200
```

**암호**: `argocd-initial-admin-secret` 이 새 클러스터에서 다시
런타임 생성됐다(Task 6 에서 예견한 대로) — 새 비밀번호(16자)로만
로그인됐고 이전 비밀번호는 쓰지 않았다(별도로 재확인하지 않음).

**kubeconfig 인증서**: 새 클러스터는 인증서가 바뀌지만, `kind` Terraform
provider 가 `kubeconfig_path`(`~/.kube/argocd-study.config`) 를 apply
때마다 덮어쓰기 때문에 `kubectl`/`argocd` 모두 캐시 문제 없이 즉시
연결됐다 — "옛 캐시로 실패" 현상은 **관측되지 않았다**.

**승인 프롬프트**: `.claude/settings.json` 의 `ask` 패턴에
`Bash(terraform * destroy*)` 가 있지만, 이번 두 번의
`terraform destroy -auto-approve` 실행 모두 **승인 프롬프트가 뜨지
않았다.** 세션이 설정을 핫리로드하지 않는 것인지 패턴이 여전히 안
맞는 것인지는 이번 관측만으로는 가를 수 없다 — **미확인**으로
남긴다(이전 구현자가 겪은 것과 같은 음성 결과의 재현).

**총 소요**: `platform destroy` 시작부터 `podinfo` 가 `Healthy` 가
되기까지 약 4분 50초(destroy 2회 ≈ 15초 + apply 2회 ≈ 3분12초 +
podinfo 전개 11초, 각 단계 사이 명령 전환 시간 포함).
