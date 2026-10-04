# 첫 Application — podinfo, 커밋만으로 앱이 생기는 것을 본다

`gitops/apps/podinfo.yaml`과 `gitops/manifests/podinfo/{deployment,service,ingress}.yaml`을
손으로 작성해(Helm·Kustomize 미사용) root Application(`argocd-bootstrap.md`)이
읽게 했다. 이 노트는 Application CRD의 네 부분, `OutOfSync`와 `Missing`의 차이,
그리고 `git push`부터 `curl` 200까지 실제로 관측한 상태 전이를 적는다.

## Application CRD의 네 부분

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: podinfo, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/Melting-Face/argocd-study.git
    targetRevision: main
    path: gitops/manifests/podinfo
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    syncOptions: [CreateNamespace=true]
```

- **`source`** — 무엇을 배포할지. repo·브랜치(`targetRevision`)·경로 세 개가
  모이면 "Git의 이 상태"가 하나로 정해진다. `targetRevision: main`이 아닌
  다른 브랜치에 커밋해도 ArgoCD는 조용히 무시한다(`argocd-bootstrap.md`의
  Review Focus (2)에서 이미 재현했다).
- **`destination`** — 어디에 배포할지. `server`는 대상 클러스터(여기선 자기
  자신, in-cluster), `namespace`는 리소스가 들어갈 네임스페이스다.
- **`project`** — `default`. ArgoCD의 `AppProject`로 소스 repo·대상 네임스페이스
  범위를 제한할 수 있지만, 이 저장소는 단일 사용자·단일 repo라 기본값을 그대로
  썼다.
- **`syncPolicy`** — 무엇을, 언제 반영할지. `automated`를 넣지 않았다 — 수동
  `sync`를 눌러 무엇이 언제 일어나는지 먼저 보기 위해서다(Task 8의 드리프트
  실험이 "수동 sync로 시작"을 전제한다). `syncOptions: [CreateNamespace=true]`만
  켰다 — 아래 참고.

## `CreateNamespace=true`를 쓴 이유 — §3-1 소유권 경계

설계 스펙 §3-1은 "한 리소스는 한 주인만"을 원칙으로 못박는다:

| 주인 | 소유 대상 |
| --- | --- |
| `terraform/platform` | `argocd` 네임스페이스, ingress-nginx, ArgoCD, root Application 1개 |
| ArgoCD | `gitops/apps/**`의 모든 선언 |

`podinfo` 네임스페이스는 Terraform이 만들지 않는다 — Terraform은 "클러스터
안"의 어떤 것도 소유하지 않기 때문이다. 만약 Terraform이 `podinfo` 네임스페이스를
미리 만들어 둔다면, 그 네임스페이스는 Terraform state와 ArgoCD 둘 다가
"내 것"이라 주장하는 자리가 된다 — 이것이 Terraform이 되돌리고 ArgoCD가 다시
맞추는 무한 sync 루프의 시작점이다. `syncOptions: CreateNamespace=true`는 그
네임스페이스를 ArgoCD가 Application의 일부로 직접 만들게 해 소유권을 한
곳으로 좁힌다. 실제로 `argocd app sync` 로그에도 `namespace/podinfo created`가
찍혔다(아래 Step 4 로그) — Terraform이 아니라 ArgoCD가 만들었다는 증거다.

## `OutOfSync`와 `Missing`의 차이

ArgoCD는 **Sync Status**와 **Health Status**를 따로 보고한다 — 이 둘은
서로 다른 질문에 답한다.

- **Sync Status**(`Synced`/`OutOfSync`)는 "Git의 선언과 클러스터의 실제
  상태가 같은가"를 비교한 결과다. `OutOfSync`는 둘이 다르다는 뜻이지,
  리소스가 없다는 뜻이 아니다 — 예를 들어 리소스는 떠 있지만 replica 수나
  이미지 태그가 Git과 다르면 그것도 `OutOfSync`다(Task 8의 드리프트 실험이
  바로 이 경우다).
- **Health Status**(`Healthy`/`Progressing`/`Missing`/`Degraded` 등)는 "그
  리소스가 실제로 동작 중인가"를 본다. `Missing`은 Health Status 쪽 값이고,
  "Git에는 선언이 있는데 클러스터에 그 리소스 자체가 아예 없다"는 뜻이다.

즉 `Sync Status: OutOfSync` + `Health Status: Missing`은 "Git에 선언은 있지만
아직 한 번도 클러스터에 만들어진 적이 없다"는 상태다 — 아래 Step 3에서 실제로
이 조합을 봤다. 리소스가 일단 만들어진 뒤에 드리프트가 나면 보통
`OutOfSync` + `Healthy`(또는 `Progressing`) 조합으로 바뀐다 — "다르지만 떠 있긴
하다"는 뜻이다.

## `repoURL` 평문 중복 — 이유와 대가(D4), 그리고 CI로 줄인 방법

ArgoCD에는 "repoURL 전역 변수"가 없다. root Application의 `repoURL`은
Terraform이 `var.repo_url`로 주입하지만, `gitops/apps/podinfo.yaml`은 Git에
커밋되는 정적 YAML이라 같은 값을 다시 적어야 한다. Kustomize component나
app-of-apps Helm 차트로 묶으면 중복을 없앨 수 있지만, **Step 1에 새 추상화가
끼어들어 Application CRD 학습 자체가 흐려진다**는 판단으로 평문 중복을
택했다(설계 스펙 D4).

대가는 분명하다 — repo를 옮기거나(fork) 이름을 바꾸면 `gitops/apps/*.yaml`
파일 수만큼 값을 일일이 고쳐야 하고, 하나라도 빠뜨리면 그 Application만
조용히 옛 repo를 보게 된다. 이 대가를 **없애지 않고 줄이는** 방향으로
`.github/workflows/ci.yml`에 `repoURL 일관성 검사` 스텝을 추가했다 —
`gitops/**`의 모든 `repoURL:` 값을 grep으로 모아 `sort -u`했을 때 1개보다
많으면 CI가 빨간불을 낸다. 인프라 명령(`kubectl`·`helm`·`terraform`)은
전혀 쓰지 않는 파일 검사다. 의도적으로 두 번째 Application 파일에 다른
`repoURL`을 넣어 로컬에서 재현해 보니, 검사가 실제로 불일치를 잡고
`exit 1`로 떨어지는 것을 확인했다(정리 후 되돌렸다 — 커밋하지 않았다).
전환 비용 자체는 `sed` 일괄 치환 1회로 여전히 남아 있다 — **이 불편을 먼저
겪어야 후속 프로젝트의 ApplicationSet이 왜 필요한지 체감된다**는 것이 D4의
결론이다.

## 실제로 본 상태 전이

### Step 3 — 커밋·푸시만으로 앱이 생기는가

```bash
$ git push
To https://github.com/Melting-Face/argocd-study.git
   86b06b6..a35c276  main -> main

$ argocd app list
NAME            ... STATUS     HEALTH   SYNCPOLICY  REPO                                              PATH                      TARGET
argocd/podinfo  ... OutOfSync  Missing  Manual      https://github.com/Melting-Face/argocd-study.git  gitops/manifests/podinfo  main
argocd/root     ... Synced     Healthy  Auto-Prune  https://github.com/Melting-Face/argocd-study.git  gitops/apps               main

$ argocd app get podinfo
Sync Policy:        Manual
Sync Status:        OutOfSync from main (a35c276)
Health Status:      Missing

GROUP              KIND        NAMESPACE  NAME     STATUS     HEALTH   HOOK  MESSAGE
                   Service     podinfo    podinfo  OutOfSync  Missing
apps               Deployment  podinfo    podinfo  OutOfSync  Missing
networking.k8s.io  Ingress     podinfo    podinfo  OutOfSync  Missing
```

`kubectl`을 한 번도 쓰지 않았는데 `podinfo` Application 자체가 생겼다 — root가
`automated: {prune: true}`로 `gitops/apps/`를 지켜보다 새 커밋을 집어가
`podinfo` Application 리소스를 만든 것이다. 그런데 `podinfo` Application은
`syncPolicy`에 `automated`가 없어 **자기 하위 리소스(Service·Deployment·
Ingress)는 만들지 않고 멈췄다** — `OutOfSync` + `Missing` 조합을 그대로 봤다.

### Step 4 — 수동 sync

```bash
$ argocd app sync podinfo
...
2026-10-05T05:19:25+09:00          Namespace                           podinfo   Running   Synced   namespace/podinfo created
2026-10-05T05:19:27+09:00  networking.k8s.io     Ingress     podinfo   podinfo  OutOfSync  Missing  ingress.networking.k8s.io/podinfo created
2026-10-05T05:19:27+09:00                        Service     podinfo   podinfo  OutOfSync  Missing  service/podinfo created
2026-10-05T05:19:27+09:00   apps              Deployment     podinfo   podinfo  OutOfSync  Missing  deployment.apps/podinfo created
...
Sync Status:        Synced to main (a35c276)
Health Status:      Progressing
```

`namespace/podinfo created` — Terraform이 아니라 ArgoCD가 이 sync 동작
안에서 네임스페이스를 만들었다는 증거다(`CreateNamespace=true`).

### 중간에 실제로 걸린 문제 — `CreateContainerConfigError`

sync는 성공했지만 파드가 바로 `Healthy`가 되지 않았다:

```bash
$ kubectl --kubeconfig ~/.kube/argocd-study.config --context kind-argocd-study \
    -n podinfo get pods
NAME                           READY   STATUS                       RESTARTS   AGE
pod/podinfo-6bf88f5b44-s29gc   0/1     CreateContainerConfigError   0          2m18s

$ kubectl ... describe pod -n podinfo -l app.kubernetes.io/name=podinfo
Warning  Failed  kubelet  Error: container has runAsNonRoot and image has
         non-numeric user (app), cannot verify user is non-root
```

업스트림 이미지는 Dockerfile에서 `USER app`(숫자가 아닌 이름)으로 빌드돼,
`securityContext.runAsNonRoot: true`만 두면 kubelet이 "진짜 non-root인지"를
스스로 확인하지 못해 컨테이너 생성 자체를 거부한다. `podman run --rm
--entrypoint id ghcr.io/stefanprodan/podinfo:6.15.0` → `uid=100(app)
gid=101(app)`로 실제 UID/GID를 확인해 `runAsUser: 100`·`runAsGroup: 101`을
명시하는 커밋을 하나 더 올려 해결했다. `syncPolicy`가 수동이라 이 두 번째
커밋도 `argocd app sync podinfo`를 다시 눌러야 반영됐다 — 수동 sync를
택한 대가(자동 반영 없음)를 여기서도 체감했다.

### 최종 확인

```bash
$ argocd app get podinfo
Sync Status:        Synced to main (34bf54c)
Health Status:      Healthy

$ kubectl ... get ns podinfo
NAME      STATUS   AGE
podinfo   Active   11m

$ kubectl ... -n podinfo get pods
NAME                     READY   STATUS    RESTARTS   AGE
podinfo-d6bf84d7-f5j6l   1/1     Running   0          62s

$ curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081
200
```

## 이미지 태그 선택 — `6.15.0`

GitHub Releases API(`api.github.com/repos/stefanprodan/podinfo/releases/latest`)
실측으로 `tag_name: "6.15.0"`(2026-08-31 공개)을 확인하고 그대로 고정했다 —
`latest` 태그는 이 저장소 컨벤션(`docs/conventions/k8s.md` §4)이 금지한다.
이 이미지는 멀티아키(amd64/arm64)로 배포돼 kind-on-podman의 arm64 노드에서도
그대로 동작한다.
