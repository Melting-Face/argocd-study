# ArgoCD 소스 타입 전환 — plain manifest에서 Helm chart로

Phase 2 Task 2의 기록이다. podinfo Application의 `source.path`를
`gitops/manifests/podinfo`(plain manifest, directory 타입)에서
`gitops/charts/podinfo`(Task 1이 쓴 Helm chart) + `source.helm: {}`로 바꾸고,
**그 전환이 돌고 있는 파드를 재생성하는지** 실측했다. 질문은 하나였다 — ArgoCD는
"생성 수단"이 아니라 "결과 매니페스트"를 본다는데, 그 말이 실제로 그런가.

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
