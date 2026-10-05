# 드리프트와 self-heal — automated·selfHeal·prune는 독립된 3개 스위치다

`gitops/apps/podinfo.yaml`의 `syncPolicy`를 다섯 번 바꿔가며 클러스터에
수동 드리프트를 직접 만들고, ArgoCD가 그걸 어떻게(또는 안) 되돌리는지
관측했다. 이 노트의 결론은 하나다 — **`automated`는 "Git을 반영한다"는
스위치이지 "클러스터를 고친다"는 스위치가 아니다.** `selfHeal`이 그 일을
하고, `prune`은 또 다른 축(삭제된 매니페스트를 지울지)이다. 셋은 서로
독립이고, 하나를 켜면 나머지도 같이 켜진다고 생각하면 실험 2에서
틀린다.

> ⚠️ 이 노트의 `kubectl`/`argocd` 명령은 전부 `export KUBECONFIG=~/.kube/argocd-study.config`
> 를 먼저 설정한 뒤 실행한 것이다 — 이 머신의 기본 kubeconfig current-context 는
> 다른 프로젝트의 `kind-lakehouse`라, 명시하지 않으면 그 클러스터를 조회한다.

## 실험 요약

| # | 선행 상태 | 조작 | 관측 |
| --- | --- | --- | --- |
| 1 | 수동 sync (`automated` 없음) | `kubectl scale --replicas=5` | `OutOfSync` 전이, `diff`에 replicas 5↔1 |
| 2 | `automated: {}` (selfHeal 없음) | 드리프트를 그대로 둠 | **되돌아가지 않음** — 8분 가까이 관측 |
| 3 | `automated.selfHeal: true` | 드리프트를 다시 만듦 | 6초 만에 복구(이벤트 타임스탬프 기준) |
| 4 | `prune: false` → `prune: true` | `ingress.yaml` 삭제 | 고아로 남았다가, `prune: true`로 바꾸자 지워짐 |
| 5 | `prune: true`, selfHeal on | `gitops/apps/podinfo.yaml` 삭제 | **예상과 다른 결과** — podinfo는 안 지워지고 root가 깨짐(아래) |

아래는 각 실험의 실제 명령과 출력이다.

## 실험 1 — 수동 sync 상태에서 드리프트

사전 상태: `syncPolicy`에 `automated` 없음, `Synced/Healthy`, `replicas=1`.

```
$ kubectl scale deploy podinfo -n podinfo --replicas=5
deployment.apps/podinfo scaled
```

`argocd app get`을 폴링한 결과:

- +15초: `Sync Status: Synced to main (a74d5b1)` — 아직 전이 전
- +92초: `Sync Status: OutOfSync from main (a74d5b1)` — 전이됨

전이 시점은 이 15~92초 구간 어딘가다. 폴링 간격이 성긴 탓에 더 정밀하게
특정할 수 없다 — **폴링 간격보다 정밀한 숫자를 주장하지 않는다.**

```
$ argocd app diff podinfo
===== apps/Deployment podinfo/podinfo ======
169c169
<   replicas: 5
---
>   replicas: 1
```

`<`가 Git(원하는 상태), `>`가 라이브 클러스터다 — 클러스터가 5, Git이
1이라고 말하는 중이다(diff 포맷상 좌우가 그렇게 찍힌다).

## 실험 2 — `automated: {}`만 켠다(selfHeal 없음)

`syncPolicy.automated: {}`를 커밋·푸시했다(`75fbf4b`). 그러자 **예상 밖의
일이 먼저 일어났다** — `automated`를 막 켜는 순간 ArgoCD는 "지금 Git
상태"를 한 번 즉시 적용한다. 이게 실험 1에서 만든 드리프트(replicas=5)를
덮어써 1로 되돌렸다:

```
$ kubectl get events -n podinfo --sort-by=.lastTimestamp | tail -3
...  ScalingReplicaSet   deployment/podinfo   Scaled down replica set podinfo-d6bf84d7 from 5 to 1
```

이건 **self-heal이 아니다** — `automated`를 켜는 시점의 일회성 초기
동기화다. 실험 2가 실제로 묻는 질문("정책이 켜진 *이후* 생긴 드리프트는
어떻게 되는가")을 테스트하려면 드리프트를 다시 만들어야 했다:

```
$ kubectl scale deploy podinfo -n podinfo --replicas=5     # 05:56:11 KST
```

그 뒤 `argocd app get`을 간격을 두고 확인했다:

| 경과 | 시각(KST) | Sync Status | replicas |
| --- | --- | --- | --- |
| +3m08s | 05:59:19 | OutOfSync from main (75fbf4b) | 5/5 |
| +5m08s | 06:01:19 | OutOfSync from main (75fbf4b) | 5/5 |
| +7m54s | 06:04:05 | OutOfSync from main (75fbf4b) | 5/5 |

ArgoCD 기본 조정 주기(약 3분)를 넘겨 거의 8분을 관측했지만 **되돌아가지
않았다.** `Sync Policy: Automated`인데도 드리프트가 그대로 남은 것 —
이게 이 노트의 핵심 교훈이다. `automated`는 Git이 바뀌면 반영하지만,
클러스터가 Git과 달라졌다고 해서 먼저 나서서 고치지 않는다.

## 실험 3 — `selfHeal: true` 추가, 복구 지연 측정

`syncPolicy.automated.selfHeal: true`를 커밋·푸시했다(`192a0ab`). 이것도
켜지는 순간 즉시 동기화가 한 번 돌아 실험 2의 드리프트(replicas=5)를
1로 되돌렸다 — 베이스라인을 `Synced/Healthy, replicas=1`로 확인한 뒤
새 드리프트를 만들었다:

```
$ date                                                      # 09:20:52 KST
$ kubectl scale deploy podinfo -n podinfo --replicas=5
deployment.apps/podinfo scaled
```

### 측정 방법

두 가지로 쟀다.

1. **`kubectl get events --sort-by=.lastTimestamp`** — 초 단위 타임스탬프.
   ```
   2026-10-05T00:20:53Z  SuccessfulCreate  Created pod: podinfo-d6bf84d7-...   (5개로 스케일업, Deployment 컨트롤러 반응)
   2026-10-05T00:20:58Z  ScalingReplicaSet  Scaled down replica set podinfo-d6bf84d7 from 5 to 1   (self-heal 교정)
   ```
   드리프트 명령(00:20:52Z)부터 교정 이벤트(00:20:58Z)까지 **6초**.

2. **10초 간격 폴링**(교차 검증) — `kubectl get deploy -o jsonpath='{.spec.replicas}'`:
   - +5초(09:20:57): `5`
   - +16초(09:21:08): `1`

   6초라는 이벤트 기반 값이 이 (5초, 16초) 구간 안에 들어오므로 서로
   모순되지 않는다.

### 정밀도 한계

`kubectl get events`의 `lastTimestamp`는 **초 단위**로 잘린다 — "6.2초"
같은 소수점 자리 숫자는 쓸 수 없다. **복구 지연은 6초(초 단위 정밀도)로
적는다.**

### 오염 가능성 점검

이 저장소의 repo-server는 liveness probe 타임아웃으로 반복 재시작하는
고질적인 문제가 있다(아래 "참고 — 이번 관측 중 발견한 인프라 불안정성"
참고). 그 재시작이 이 측정 구간에 끼었다면 지연 숫자가 재시작 때문인지
조정 주기 때문인지 구분할 수 없다. 측정 직후 재시작 카운트를 확인했다:

```
$ kubectl get pod -n argocd argo-cd-argocd-repo-server-... \
    -o jsonpath='{.status.containerStatuses[0].restartCount}'
34
```

측정 전후로 재시작 카운트가 그대로 34였고, 그 직전 재시작은 약 20분
전(00:00:21Z)이었다 — **이 6초 측정 구간에는 재시작이 끼지 않았다.**
깨끗한 측정이다.

Task 7에서는 `argocd app get`/`app sync`가 2분 타임아웃을 낸 적이
있다고 보고됐다(원인 미규명). 이 실험의 "6초" 측정은 `argocd` CLI를
전혀 쓰지 않고 `kubectl get events`/`kubectl get deploy -o jsonpath`만
썼으므로 **그 경로로는 오염되지 않는다** — 다만 이것이 다른 경로의
오염 가능성까지 배제한다는 뜻은 아니다.

## 실험 4 — `prune`: 고아 리소스와 그 해소

### `prune: false`에서 매니페스트 삭제

`syncPolicy.automated.prune: false`를 명시하고 `ingress.yaml`을 삭제해
커밋·푸시했다(`2fa9363`).

```
$ argocd app get podinfo
...
GROUP               KIND        NAMESPACE  NAME     STATUS     HEALTH
apps                Deployment  podinfo    podinfo  Synced     Healthy
                    Service     podinfo    podinfo  Synced     Healthy
networking.k8s.io   Ingress     podinfo    podinfo  OutOfSync  Healthy

$ kubectl get ingress -n podinfo
NAME      CLASS   HOSTS                  ADDRESS        PORTS   AGE
podinfo   nginx   podinfo.localtest.me   10.96.35.206   80      4h13m
```

`argocd app diff`는 Ingress 전체가 "라이브에만 있고 Git에는 없음"으로
나온다(모든 줄이 `<`쪽):

```
$ argocd app diff podinfo
===== networking.k8s.io/Ingress podinfo/podinfo ======
1,55d0
< apiVersion: networking.k8s.io/v1
< kind: Ingress
...
```

`curl podinfo.localtest.me:8081`은 여전히 `200`이다 — **고아가 된
뒤에도 그 리소스는 계속 서비스한다.** `prune: false`인 한 앱은 영원히
`OutOfSync`로 남는다(Deployment·Service는 Synced인데 Ingress 하나가
extra라서 전체 Sync Status가 OutOfSync로 고정된다).

### `prune: true`로 전환

`syncPolicy.automated.prune: true`로 바꿔 커밋·푸시했다(`834288c`).
application-controller 로그에서 교정 과정을 그대로 볼 수 있었다:

```
# prune:false였을 때 반복됐던 로그
"Skipping auto-sync: need to prune extra resources only but automated prune is disabled"

# prune:true 반영 직후
"Adding resource result, status: 'Pruned', phase: 'Succeeded', message: 'pruned'"
```

```
$ kubectl get ingress -n podinfo
No resources found in podinfo namespace.

$ argocd app get podinfo
Sync Status:   Synced to main (834288c)
Health Status: Healthy

$ curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081
404
```

Ingress가 지워졌고(라우트가 없으니 `404`), 앱 전체는 다시
`Synced/Healthy`가 됐다. 뒤처리로 `ingress.yaml`을 원래 내용대로
복구해 커밋·푸시했고(`675fd57`), 재동기화 후 `curl`이 다시 `200`으로
돌아온 것을 확인했다.

## 실험 5 — root에서 Application 자체를 지운다

`gitops/apps/podinfo.yaml`을 삭제·커밋·푸시했다(`2cdb6cb`). 기대한 그림은
"root가 podinfo Application을 prune하고, 그 뒤 cascade 여부를 본다"였다.
실제로 일어난 일은 **그 전 단계에서 막혔다.**

### 왜 막혔는가 — Git은 빈 디렉터리를 추적하지 않는다

`gitops/apps/`에 들어 있던 파일은 `podinfo.yaml` 하나뿐이었다(Task 7에서
자리표시자였던 `.gitkeep`을 이미 지운 상태였다). 그 유일한 파일을 지우니
**디렉터리 자체가 Git 트리에서 사라졌다** — `git ls-tree -r HEAD --name-only`
에 `gitops/apps`가 전혀 나오지 않는다. root Application의 `source.path`는
`gitops/apps`인데, 그 경로가 이제 Git에 없다.

```
$ argocd app get root
Sync Status:        Unknown
Health Status:      Healthy

CONDITION        MESSAGE
ComparisonError  Failed to load target state: failed to generate manifest
                 for source 1 of 1: rpc error: code = Unknown desc =
                 gitops/apps: app path does not exist
```

```
$ argocd app list
NAME            STATUS   HEALTH   CONDITIONS       PATH
argocd/podinfo  Synced   Healthy  <none>           gitops/manifests/podinfo
argocd/root     Unknown  Healthy  ComparisonError  gitops/apps
```

```
$ kubectl get application -n argocd
NAME      SYNC STATUS   HEALTH STATUS
podinfo   Synced        Healthy
root      Unknown       Healthy
```

### 실제 관측 — podinfo는 지워지지 않았다

root가 desired state 계산 자체에 실패했으므로(`ComparisonError`), **prune
연산을 시도조차 하지 못했다.** 그 결과:

- `podinfo` Application CR은 그대로 `Synced/Healthy`로 남아 있었다.
- 하위 리소스(`kubectl get all -n podinfo`)도 Deployment·Service·
  ReplicaSet·Pod 전부 그대로였다.
- 네임스페이스(`kubectl get ns podinfo`)도 `Active`로 남아 있었다.

즉 **"앱이 사라지는가"에 대한 답은 "아니다"다** — 다만 brief가 그린
"prune이 지워서 안 사라진다"가 아니라 **"root 자신이 desired state를
계산 못 해 아무 것도 건드리지 못해서 안 사라진다"**는, 더 앞 단계에서
막힌 결과다. 이건 **의도치 않게 안전한 실패 모드**로 읽을 수 있다 — 소스
해석이 깨지면 ArgoCD는 "아무 매니페스트도 없으니 전부 지워야겠다"로
해석하지 않고, 그냥 비교를 포기하고 아무 것도 하지 않는다.

### 뒤처리

`gitops/apps/podinfo.yaml`을 원래 내용대로 복구하면서, 이 기회에
`syncPolicy`를 이 Task의 최종 목표 상태(`automated: {selfHeal: true,
prune: true}`)로 함께 확정해 커밋·푸시했다. 경로가 다시 생기자 root는
바로 `ComparisonError`에서 회복됐다(복구 확인은 아래 "뒤처리 확인"
참고).

### 미확인으로 남기는 것

이번 실험에서는 "Application에 `resources-finalizer.argocd.argoproj.io`
annotation이 있을 때 cascade 삭제가 실제로 일어나는가"를 확인하지
못했다 — 이 repo의 `podinfo.yaml`에는 그 annotation이 없었고, 애초에
root가 멈춰서 삭제 자체가 시도되지 않았다. **미확인.** 다음에 이걸
보려면 빈 디렉터리 문제를 피해야 한다(예: `gitops/apps/`에 다른 앱을
하나 더 두거나 `.gitkeep`을 되살려 경로를 유지한 채로 `podinfo.yaml`만
지운다).

## 참고 — 이번 관측 중 발견한 인프라 불안정성

측정과 직접 관련은 없지만, 관측 도중 두 가지를 발견했다.

1. **`repo-server`가 여전히 반복 재시작한다.** `terraform/platform`의
   Fix round 1이 liveness/readiness probe `timeoutSeconds`를 1초에서
   5초로 올려 "재시작이 멈추는지 관측으로 검증했다"고 적었지만(
   [`argocd-bootstrap.md`](argocd-bootstrap.md)), 이번 세션에서는
   4시간40분 동안 34회, 이후 6시간여 동안 40회까지 재시작 카운트가
   늘었다. **장시간 기준으로는 완전히 해소되지 않았다** — 짧은
   검증 구간에서 "멈췄다"로 본 것은 우연이었을 가능성이 있다. 원인은
   여전히 같다(`healthz?full=true` probe가 이 podman VM의 간헐적
   스케줄링 지연을 못 견딤).
2. **`ingress-nginx-controller`도 같은 계열 문제를 보인다.** readiness/
   liveness probe `timeoutSeconds: 1`(차트 기본값, 손대지 않음)이
   이 환경에서 간헐적으로 초과돼 재시작한다. 이 창에 `argocd` CLI나
   `curl` 호출이 걸리면 `EOF`/connection reset으로 실패했다 — 재시도
   하면 15~20초 안에 해소됐다. Task 7에서 관측된 "`argocd app get/sync`
   2분 타임아웃 1회"와 같은 계열의 증상일 가능성이 높다(argocd CLI는
   Ingress를 거쳐서만 argocd-server에 닿으므로) — 다만 이번 세션에서는
   2분 타임아웃 자체는 재현되지 않았다. **미확인**으로 남긴다.
3. **root의 Git 커밋 반영이 예상보다 크게 늦은 구간이 있었다**
   (한 번은 약 55~60분). repo-server의 `git fetch` 로그를 보면 간격이
   기본 3분이 아니라 18분까지 벌어진 사례가 있었다. 이 구간에 세션
   쪽의 긴 유휴 구간(호스트 절전 추정)이 겹쳐 있어, 지연이 repo-server
   재시작 때문인지 호스트 유휴 때문인지 **단일 원인으로 확정하지
   못했다** — 둘 다 후보로 남긴다.

4. **호스트 와이파이 단절이 클러스터 내부 DNS까지 전파됐다.** Task 8
   착수 전, 호스트 네트워크가 끊긴 동안 root Application이
   `Unknown/ComparisonError`에 빠졌다. `argocd app get root`의 에러
   메시지:

   ```
   ComparisonError: Failed to load target state: failed to generate manifest for
     source 1 of 1: rpc error: code = Unknown desc = failed to list refs:
     Get "https://github.com/Melting-Face/argocd-study.git/info/refs?service=git-upload-pack":
     dial tcp: lookup github.com on 10.96.0.10:53: no such host
   ```

   `10.96.0.10`은 클러스터 내부 CoreDNS의 ClusterIP다. 호스트가
   인터넷(따라서 DNS 상위 전달)을 잃으면, kind 노드의 컨테이너 런타임도
   같은 호스트 네트워크 경로를 타기 때문에 CoreDNS의 upstream forward가
   실패하고, 그 실패가 `github.com` 조회 실패로 `repo-server`까지
   전파된다. 이 메시지는 **이전 구현자가 중단 당시 실제로 받은 에러를
   그대로 인용한 것**이고, 이번 Task 8 담당자가 재현한 것은 아니다 —
   네트워크는 Task 8 착수 전에 이미 복구돼 있었다.

   같은 창에서 `repo-server`가 재시작 루프(관측된 restart count r=42)에
   다시 들어갔다. 이는 위 1번 항목(`healthz?full=true` probe 타임아웃)과
   같은 증상이지만 **원인은 다르게 추정된다** — `/healthz?full=true`가
   repo 연결 상태까지 확인하기 때문에 DNS 실패가 probe 실패로 이어졌을
   것으로 보인다. **이것은 추정이며 로그로 직접 확인하지 못했다. 미확인
   으로 남긴다.**

   복구 절차: 호스트 네트워크 회복 후(클러스터 내부에서
   `nslookup github.com`이 다시 성공하는 것으로 확인) root Application에
   `argocd.argoproj.io/refresh: hard` annotation을 패치하자 즉시
   `Synced/Healthy`로 돌아왔다. 자동 폴링(기본 3분 주기)을 기다리지
   않고 hard refresh로 강제한 것이라, 이 복구 자체는 **수동 개입**이다.

   🔑 이 사고는 실험 5의 "안전한 실패 모드" 발견을 실제 장애로 뒷받침
   한다 — Git에 닿지 못하는 몇 시간 동안 ArgoCD는 **아무것도 지우지
   않았다.** `podinfo` Application과 그 하위 리소스는 root가
   `ComparisonError`에 갇혀 있던 내내 `Synced/Healthy`로 유지됐다(이
   관측 역시 이전 구현자의 것이며, 이번 담당자는 네트워크 복구 이후의
   상태만 직접 확인했다). 소스를 못 읽으면 "비교를 포기하고 멈춘다"는
   동작이, 사람이 설계한 실험(실험 5)에서만 성립하는 게 아니라 실제
   우발적 장애에서도 동일하게 성립함을 보여준다.

이 넷 모두 Phase 2 과제(또는 별도 인프라 안정화 작업)로 넘긴다 — 이
Task의 범위는 관측이지 수리가 아니다.
