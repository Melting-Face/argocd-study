# ArgoCD 소스 타입 전환 — plain manifest에서 Helm chart로

Phase 2 Task 2의 기록이다. podinfo Application의 `source.path`를
`gitops/manifests/podinfo`(plain manifest, directory 타입)에서
`gitops/charts/podinfo`(Task 1이 쓴 Helm chart)로 바꾸고, **그 전환이 돌고 있는
파드를 재생성하는지** 실측했다. 질문은 하나였다 — ArgoCD는 "생성 수단"이 아니라
"결과 매니페스트"를 본다는데, 그 말이 실제로 그런가.

(최초 커밋에는 `source.helm: {}`도 같이 넣었다가, 그게 영구 `OutOfSync` 드리프트를
만드는 것을 fix round 1에서 발견해 제거했다 — 아래 "빈 맵/빈 블록이 만드는 영구
드리프트" 절.)

## 세 소스 타입이 매니페스트를 만드는 방법

ArgoCD repo-server는 경로 안의 파일로 타입을 자동 판별한다(명시적으로
`source.helm`·`source.kustomize`·`source.directory`를 주지 않은 경우):

> "Helm if there's a file matching `Chart.yaml`. Kustomize if there's a
> `kustomization.yaml`" ... "Otherwise it is assumed to be a plain **directory**
> application."
> — [ArgoCD 공식 문서, Tool Detection](https://argo-cd.readthedocs.io/en/stable/user-guide/tool_detection/)

| 타입 | 판별 파일 | 렌더링 방법 | 이 저장소에서 |
|---|---|---|---|
| `directory` | (기본값, 없으면 이걸로 떨어짐) | 디렉토리의 YAML/JSON/Jsonnet 파일을 그대로 읽는다 — 템플릿 엔진이 없다 | Phase 1, `gitops/manifests/podinfo/*.yaml` |
| `helm` | `Chart.yaml` | `helm template <release> <chart> [-f values.yaml] [--set ...]`로 렌더링 | Phase 2 이후, `gitops/charts/podinfo/` |
| `kustomize` | `kustomization.yaml` | `kustomize build`로 오버레이를 합성 | 이 저장소는 안 씀(`terraform/platform/charts/root-app`은 Helm) |

세 타입 모두 **repo-server 안에서** 렌더링이 끝난다 — API 서버에 아무것도
적용되지 않은 순수 텍스트(매니페스트 YAML 묶음)가 나온다. 그 다음부터
application controller가 하는 일은 타입과 무관하게 동일하다: 그 텍스트를
클러스터의 live 상태와 **필드 단위로 diff**하고, 다르면 `kubectl apply`에
해당하는 작업을 한다. 소스 타입은 "그 텍스트를 어떻게 만들었는가"의 차이일 뿐,
controller의 diff·apply 로직에는 들어가지 않는다 — 이것이 "ArgoCD는 생성 수단이
아니라 결과 매니페스트를 본다"의 정확한 의미다.

## 전환 전 — 실측 기준값 (2026-10-05, Step 1)

```
$ kubectl --context kind-argocd-study get pod -n podinfo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.metadata.creationTimestamp}{"\n"}{end}'
podinfo-d6bf84d7-v9tzl f3b25e72-0503-4bba-ad4c-335368d7bfb3 2026-10-05T03:18:52Z

$ kubectl --context kind-argocd-study get rs -n podinfo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.metadata.creationTimestamp}{"\n"}{end}'
podinfo-d6bf84d7 c4980386-2263-46f3-9caa-7a1b9f279156 2026-10-05T03:18:52Z

$ argocd app get podinfo
Sync Status:        Synced to main (ba24f9d)
Health Status:      Healthy
Sync Policy:        Automated (Prune), selfHeal: true
```

전환 직전 `gitops/charts/podinfo/tests/equivalence.sh`를 다시 돌려 chart가
여전히 plain manifest와 동등함을 재확인했다 — 세 리소스(deployment/service/
ingress) 모두 `PASS`.

## 전환 과정에서 실제로 일어난 일 (Step 2~3 관측)

`gitops/apps/podinfo.yaml`의 `source.path`를 `gitops/charts/podinfo`로 바꾸고
`source.helm: {}`를 추가해 커밋(`dc2bfa8`)·푸시했다. `automated.selfHeal: true`가
켜져 있어 수동 sync 없이 아래 순서로 자동 반영됐다(직접 관측):

1. **root Application이 먼저 OutOfSync로 바뀐다** — `gitops/apps/`를
   `directory.recurse`로 보는 root는 podinfo Application CR 자체를 자기
   매니페스트로 관리한다. podinfo.yaml 커밋 직후 `argocd app get root`가
   `Sync Status: OutOfSync from main (dc2bfa8)`을 보고했다. **podinfo
   Application의 `spec.source`가 바뀌려면 root가 먼저 자기 sync를 끝내야 한다**
   — 이건 이 저장소의 2계층(root→leaf) 구조 때문이고, 소스 타입 전환 자체와는
   무관한 중간 단계다.
2. root의 automated sync가 podinfo Application CR의 `spec.source.path`를
   `gitops/charts/podinfo`로 갱신한다.
3. podinfo Application controller가 새 spec으로 즉시 재평가한다. 3초 간격으로
   40회(약 2분) 폴링했지만 **`Sync Status`가 `OutOfSync`로 떨어지는 순간을 한
   번도 포착하지 못했다** — diff 계산이 폴링 간격(3초)보다 빨랐거나, 애초에
   diff가 없어 "재계산 즉시 Synced"로 끝난 것으로 보인다(관측 한계로 남긴다).
4. `argocd app get podinfo`의 리소스별 MESSAGE가 `created`에서 `configured`로
   바뀌었다 — Namespace/Service/Deployment/Ingress가 **새로 만들어진 게 아니라
   기존 리소스에 대해 apply(patch)만 일어났다**는 1차 증거.

```
전환 후 argocd app get podinfo:
Source: Path: gitops/charts/podinfo
Sync Status:  Synced to main (dc2bfa8)
Health Status: Healthy
GROUP               KIND        NAME     STATUS  HEALTH   MESSAGE
                    Service     podinfo  Synced  Healthy  service/podinfo configured
apps                Deployment  podinfo  Synced  Healthy  deployment.apps/podinfo configured
networking.k8s.io   Ingress     podinfo  Synced  Healthy  ingress.networking.k8s.io/podinfo configured
```

## 전환 후 — 재생성 여부 (Step 3 핵심)

```
$ kubectl --context kind-argocd-study get pod -n podinfo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.metadata.creationTimestamp}{"\n"}{end}'
podinfo-d6bf84d7-v9tzl f3b25e72-0503-4bba-ad4c-335368d7bfb3 2026-10-05T03:18:52Z

$ kubectl --context kind-argocd-study get rs -n podinfo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{" "}{.metadata.creationTimestamp}{"\n"}{end}'
podinfo-d6bf84d7 c4980386-2263-46f3-9caa-7a1b9f279156 2026-10-05T03:18:52Z
```

**Pod UID·ReplicaSet UID·creationTimestamp가 전환 전과 한 글자도 다르지 않다.**
`kubectl get events -n podinfo`에도 Deployment/ReplicaSet/Pod에 대한 이벤트는
없었다(`ingress Scheduled for sync` 한 줄뿐 — Ingress controller의 외부 리소스
갱신 이벤트로, 파드 생애주기와 무관). `argocd app diff podinfo`도 빈 출력·exit
0 — live 상태와 Git(Helm 렌더 결과) 사이에 차이가 없다는 뜻이다.

**결론: 재생성되지 않았다.** plain manifest와 Helm chart가 만들어 낸 매니페스트가
바이트 단위까지는 아니어도 Kubernetes API 서버가 보는 의미 단위에서 완전히
같았기 때문이다 — ArgoCD는 "이 리소스를 Helm이 만들었나 손으로 썼나"를 구분하는
필드를 아예 갖고 있지 않다. 리소스 하나하나를 live 상태와 비교해 **다른 필드가
없으면 아무 것도 하지 않는다.**

### 재생성이 "안 됐다"를 뒷받침하는 근거 (교차 확인)

- `Deployment.spec.selector.matchLabels`: 전환 후 `{app.kubernetes.io/name:
  podinfo}` 그대로. Task 1이 `_helpers.tpl`을 `podinfo.selectorLabels`(selector
  전용, `app.kubernetes.io/name`만)와 `podinfo.labels`(top-level
  `metadata.labels`용, `managed-by`·`helm.sh/chart` 포함)로 쪼개둔 덕이다.
- ReplicaSet 이름의 해시(`d6bf84d7`, pod-template-hash)가 그대로다 — 이 해시는
  pod 템플릿 spec 전체의 해시라, 컨테이너 이미지·env·리소스 limit·레이블 중
  하나라도 바뀌면 값이 바뀐다. 안 바뀌었다는 건 pod 템플릿이 필드 단위로
  동일했다는 뜻.
- `gitops/charts/podinfo/tests/equivalence.sh`를 전환 후에도 다시 돌려
  3개 리소스 모두 재확인: `PASS`.

## 접속 확인 (Step 4)

```
$ curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081
200
```

## "결과 매니페스트를 본다"의 한계 — 1비트만 달라도 재생성된다

이 실험이 "재생성 없음"으로 끝난 건 Helm chart가 plain manifest와 **의미상
완전히 같은 결과**를 내도록 Task 1이 미리 맞춰놨기 때문이지, ArgoCD가 소스
타입 전환에 원래 관대해서가 아니다. 경계는 명확하다:

- `selector.matchLabels`는 Deployment의 **생성 후 불변 필드**다. Helm chart가
  관용적으로 붙이는 `app.kubernetes.io/instance`·`app.kubernetes.io/managed-by`
  같은 레이블이 selector에 단 하나라도 섞여 들어가면(`helm create`가 만드는
  기본 `_helpers.tpl`이 바로 이렇게 한다), Kubernetes는 Deployment를
  **교체**(delete+create)할 수밖에 없다 — API 서버가 그 필드의 수정을 아예
  거부하기 때문이다. ArgoCD는 이걸 알고 특별 대우를 해주지 않는다. 그냥
  `kubectl apply`가 실패 → ArgoCD가 `replace`(또는 delete 후 재생성)로
  대응하고, 그 결과로 새 ReplicaSet·새 Pod가 뜬다.
- 이게 바로 Task 1이 `_helpers.tpl`을 `podinfo.selectorLabels`와
  `podinfo.labels`로 쪼갠 이유다(`wiki/writing-a-helm-chart.md`) — **이 분리가
  없었다면 이 Task 2 실험은 처음부터 "소스 타입 전환 = 재생성"으로 끝났을
  것이고, 그게 소스 타입 전환 자체의 속성인지 chart 작성 실수인지 구분할 수
  없었을 것이다.** 이번 실측에서 재생성이 안 된 것은 "ArgoCD가 Helm 전환에
  관대하다"는 뜻이 아니라, **selector를 포함해 결과 매니페스트가 정말로
  한 비트도 다르지 않았다**는 뜻으로 읽어야 한다.
- 더 일반화하면: `metadata.labels`·`annotations`처럼 가변 필드는 값이
  달라져도 ArgoCD가 조용히 patch로 수렴시킨다. 반면 `selector`처럼
  **불변 필드**에 차이가 생기면 Kubernetes 레벨에서 교체가 강제된다. "소스
  타입을 바꿔도 안전하다"는 결론은 이 불변 필드 축을 건드리지 않는 한에서만
  성립하고, 그 보장은 ArgoCD가 아니라 **chart를 쓰는 사람의 책임**이다.

## 빈 맵/빈 블록이 만드는 영구 드리프트 (fix round 1)

Task 2가 처음 커밋한 `gitops/apps/podinfo.yaml`은 이렇게 썼다:

```yaml
    path: gitops/charts/podinfo
    helm: {}
```

ArgoCD는 `Chart.yaml`만으로 Helm 소스를 자동 판별하니 `helm:` 블록은 애초에
불필요했다 — 그런데 "불필요하다"가 "무해하다"는 아니었다.

### 증상 — sync는 매번 성공하는데 상태는 계속 OutOfSync

```
$ argocd app get root
Sync Status:        OutOfSync from main (2c634a2)
GROUP        KIND         NAME     STATUS     HEALTH
argoproj.io  Application  argocd   podinfo    OutOfSync
```

```
$ kubectl get events -n argocd --field-selector involvedObject.name=root --sort-by=.lastTimestamp
13m   Normal   ResourceUpdated      application/root   Updated sync status: Synced -> OutOfSync
10m   Normal   OperationStarted     application/root   Initiated automated sync to '2c634a2...'
10m   Normal   OperationCompleted   application/root   Partial sync operation to 2c634a2... succeeded
10m   Normal   ResourceUpdated      application/root   Updated sync status: OutOfSync -> Synced
10m   Normal   ResourceUpdated      application/root   Updated sync status: Synced -> OutOfSync
5m30s Normal   OperationStarted     application/root   Initiated automated sync to '2c634a2...'
5m30s Normal   OperationCompleted   application/root   Partial sync operation to 2c634a2... succeeded
5m30s Normal   ResourceUpdated      application/root   Updated sync status: OutOfSync -> Synced
5m30s Normal   ResourceUpdated      application/root   Updated sync status: Synced -> OutOfSync
30s   Normal   OperationStarted     application/root   Initiated automated sync to '2c634a2...'
30s   Normal   OperationCompleted   application/root   Partial sync operation to 2c634a2... succeeded
29s   Normal   ResourceUpdated      application/root   Updated sync status: OutOfSync -> Synced
29s   Normal   ResourceUpdated      application/root   Updated sync status: Synced -> OutOfSync
```

**`OperationCompleted ... succeeded`가 찍히고 바로 다음 줄에서 `Synced ->
OutOfSync`로 되돌아가는 패턴이 ArgoCD의 기본 재조정 주기(약 3분)마다 무한
반복됐다.** `selfHeal: true`가 켜져 있어 매번 "무의미한 sync"를 자동으로
재시도한다 — CPU를 태우고 이벤트 로그를 계속 채우지만 실제로는 아무 것도
바뀌지 않는다.

### 판정 — 어느 필드인지 특정

```
$ argocd app diff root
===== argoproj.io/Application argocd/podinfo ======
130a131
>     helm: {}
```

`argocd app diff`가 즉시 범인을 지목했다: **live(클러스터)에는 `spec.source.helm`
필드 자체가 없는데, Git에는 `helm: {}`가 있다.**

### 원인 — 빈 맵은 Kubernetes API 서버가 저장하지 않는다

`source.helm`의 타입은 구조체 포인터(optional object)다. 빈 객체 `{}`를
`kubectl apply`(ArgoCD 내부적으로도 동일한 경로)로 보내면, API 서버는 그 필드에
의미 있는 내용이 없다고 보고 **저장하지 않는다** — `omitempty` 계열 처리로
사라진다. 그래서:

- **Git(desired)** = `helm: {}` 있음
- **Live(실제 etcd에 저장된 값)** = `helm` 필드 없음
- 매 reconcile마다 ArgoCD가 "Git에 있는데 live에 없다"로 diff를 보고 →
  sync를 건다 → `kubectl apply`가 다시 빈 맵을 보내고 → API 서버가 다시
  저장을 거부 → **처음부터 반복.**

sync operation 자체는 매번 "성공"으로 끝난다(apply 호출은 에러 없이 끝나니까)
— 그런데 그 apply가 **아무 것도 바꾸지 못했기** 때문에 다음 비교 때 똑같은
diff가 또 나온다. "sync Succeeded"와 "실제로 수렴했다"가 다른 말이라는
뜻이다.

### 해결

`helm: {}` 자체를 지웠다(`f37112b`). ArgoCD가 `Chart.yaml` 존재로 Helm 소스를
자동 판별하므로 빈 블록을 둘 이유가 없었다.

```
# 수정 후
$ argocd app diff root
(빈 출력, exit=0)

$ kubectl get events -n argocd --field-selector involvedObject.name=root --sort-by=.lastTimestamp | tail -3
Normal   ResourceUpdated   application/root   Updated sync status: OutOfSync -> Synced
(이후 재이탈 없음 — 4분 이상 Synced 유지 확인)
```

### 일반화 — 언제 또 이 일이 난다

Git에 **값이 있는데 API 서버가 저장하지 않는 필드**를 적으면 항상 이 패턴이
난다. 후보:

- **빈 맵/빈 리스트** (`helm: {}`, `annotations: {}`, `tags: []`) — 이번 사례.
  `omitempty`가 있는 optional 구조체 필드는 내용이 없으면 저장 자체가 안 된다.
- **서버가 기본값으로 채우는(defaulting) 필드를 명시적으로 적되, 그 값이
  "비어있음과 동치"로 취급되는 경우** — 예를 들어 어떤 admission
  webhook/CRD는 빈 문자열·0·false를 "미설정"과 같은 것으로 보고 저장하지
  않을 수 있다(이 저장소에서 직접 재현하지는 않았다 — 일반화로만 적는다).
- **진단 신호**: `argocd app diff`에서 **매번 같은 한 줄만** 차이로 뜨고,
  `argocd app get`의 `Sync Status`가 `Synced`로 떨어졌다가 곧바로
  `OutOfSync`로 되돌아가길 반복하며, sync operation 기록은 계속
  `Succeeded`다. "초록불(Succeeded)인데 안심할 수 없다"는 점에서 이 저장소의
  다른 노트들이 적어 온 **침묵 실패(조용히 적용 안 됨)와 정반대 방향** — 이건
  **시끄럽게 영원히 안 끝나는** 실패다.
- **예방**: ArgoCD가 자동 판별 가능한 필드(Helm/Kustomize 여부 등)는 명시적
  빈 블록을 아예 쓰지 않는다. 오버라이드가 필요할 때만, 실제 값이 있을 때만
  그 블록을 쓴다.

## 남은 우려

- Step 3의 폴링(3초 간격)이 `OutOfSync` 중간 상태를 한 번도 못 잡았다 — 전환이
  net-net 무해했다는 결론에는 영향 없지만, "controller가 재계산하는 동안
  Sync Status가 실제로 어떻게 전이하는가"는 이 관측만으로는 더 세밀하게 말할
  수 없다(미확인).
- `argocd.argoproj.io/tracking-id` 같은 ArgoCD 자체 추적 annotation이
  `source.path`가 바뀌어도 값이 그대로인지는 이번에 별도로 확인하지 않았다
  (미확인) — 값이 Application 이름 기반이라 바뀌지 않을 것으로 보이지만
  실측하지 않았다.
- CI(`ci` 워크플로)가 이번 푸시(`dc2bfa8`)에서 1차로 실패했다 —
  `terraform_tflint` 훅이 `tflint` 0.64.0 릴리스 자산을 못 찾아서였다. 같은
  커밋을 `gh run rerun`으로 재실행하니 바로 성공했다(28초) — 코드 변경 없이
  재실행만으로 통과했으므로 GitHub 쪽 릴리스 자산 다운로드의 일시적 플레이키로
  판단한다. 이 Task의 변경(`gitops/apps/podinfo.yaml`)과는 무관하고,
  `.pre-commit-config.yaml`의 tflint 버전 고정은 이 Task 소관이 아니라 손대지
  않았다.

## 참고

- [ArgoCD 공식 문서 — Tool Detection](https://argo-cd.readthedocs.io/en/stable/user-guide/tool_detection/)
- [ArgoCD 공식 문서 — Application Sources 개요](https://argo-cd.readthedocs.io/en/stable/user-guide/application-sources/)
- `wiki/writing-a-helm-chart.md` — 이 chart가 plain manifest와 왜/어떻게
  동등한지(selector/label 분리의 근거)
- `gitops/charts/podinfo/tests/equivalence.sh` — 동등성 재검증에 쓴 스크립트
- `gitops/apps/podinfo.yaml` — 전환된 Application 선언
- `.superpowers/sdd/2026-10-05-argocd-study-phase2/task-2-report.md` — 이 Task의
  전체 raw 관측 로그
