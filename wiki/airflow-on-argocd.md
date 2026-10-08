# ArgoCD 위의 Airflow 배포 — "Synced"인데 아무것도 돌지 않던 교착

Phase 3 Task 8의 기록이다. 공식 Apache Airflow chart를 우리 저장소의 umbrella chart로 감싸
`ApplicationSet`이 만든 Application으로 배포했다. 첫 sync에서 ArgoCD는 `Synced`를 보여줬지만
파드는 10분 넘게 뜨지 못했다. 원인은 chart의 **Helm 훅과 ArgoCD 훅 매핑의 충돌**이었고,
고친 뒤에도 **멈춘 sync operation** 이라는 두 번째 함정이 있었다.

질문은 셋이다.

1. 공식 chart를 왜 저장소 안의 umbrella chart로 감싸고, 의존성은 누가 받는가.
2. 렌더마다 바뀌는 랜덤 Secret과 사람이 소유하는 네임스페이스는 어떻게 다루는가.
3. 컨트롤러가 `Synced`라고 했을 때 무엇을 더 확인해야 하는가.

## 왜 umbrella chart인가

설계 문서
([Phase 3 설계](https://github.com/Melting-Face/argocd-study/blob/main/docs/superpowers/specs/2026-10-07-applicationset-image-cd-design.md)
§1-1)의 요구 2번은 "chart 와 container image 는 GitHub 를 통해 관리"다. 공식 chart를
`apache-airflow` 저장소에서 직접 가리키면 chart 소스가 GitHub 밖에 있고, ApplicationSet
템플릿도 앱마다 소스 형태가 갈라진다. 그래서 `gitops/charts/airflow/` 에 의존성만 선언한
얇은 chart를 두고, 모든 앱이 `path: gitops/charts/<앱>` 이라는 **한 가지 템플릿 모양**을
따르게 했다([ApplicationSet 노트](applicationset-list-generator.md)).

`gitops/charts/airflow/Chart.yaml` 의 의존성 선언이다.

```yaml
dependencies:
  - name: airflow
    version: 1.22.0
    repository: https://airflow.apache.org
```

`values.yaml` 은 공식 chart의 키를 최상위 `airflow:` 아래로 한 단계 내려 쓴다. 이미지 태그
한 줄(`# bump-image-tag` 마커)이 배포 상태의 단일 출처다.

### 의존성은 누가 받는가 — 두 환경의 결과가 갈렸다

설계 §4-3은 `charts/`(.tgz)를 `.gitignore` 하고 ArgoCD repo-server가 렌더 때 받게 했다.
근거는 Argo CD v3.5.3 소스(`reposerver/repository/repository.go`)뿐이었고, 사용자 가이드에는
이 동작 서술이 없어 설계가 "실동작은 G3에서 관측한다"고 남겨 두었다.

- **ArgoCD 쪽 (관측)**: 2026-10-08T12:13:22Z 의 `apply` 후 `airflow` Application이
  **첫 sync에서 `Synced`** 였다. repo-server가 ArgoCD에 등록하지 않은
  `https://airflow.apache.org` 의존성을 스스로 빌드했다는 뜻이다. 소스 읽기가 관측으로
  확인된 셈이다.
- **CI 러너 쪽 (관측)**: 같은 `helm dependency build gitops/charts/airflow` 가 CI(커밋
  `dfec04c`)에서 아래 오류로 실패했다.

  ```text
  no repository definition for https://airflow.apache.org
  ```

  개발 머신은 과거 `helm repo add` 이력이 있어 통과했다 — **로컬이 결함을 가렸다.**
  깨끗한 러너에는 repo 정의가 없다. 고침은 `scripts/helm-dep-build.sh <chart>` 다.
  `Chart.yaml` 의 `https://` 의존성 저장소를 `helm repo add` 한 뒤 `dependency build` 를
  실행하며, pre-commit 훅·`tests/render.test.sh`·`image.yml` 세 곳이 같은 스크립트를 쓴다.
  재현과 검증은 `HELM_*` 환경변수를 비어 있는 임시 경로로 돌려서 했다(CI-R1 보고:
  스크립트 부재 시 테스트 `PASS 1 / FAIL 2`, 추가 후 `PASS 3 / FAIL 0`, 격리 환경에서
  `pre-commit run --all-files` 전 훅 통과).

교훈: 「ArgoCD가 알아서 받는다」와 「내 CI가 알아서 받는다」는 **서로 다른 보장**이다. 한쪽의
성공이 다른 쪽을 증명하지 않는다.

## 랜덤 Secret 문제와 세 개의 수동 Secret

공식 chart는 fernet 키·JWT 시크릿 이름을 지정하지 않으면 **렌더할 때마다** `randAlphaNum` 으로
새로 만든다. ArgoCD는 커밋·refresh마다 다시 렌더하므로 커밋마다 키가 회전하고(암호화된
Connection을 복호화하지 못하고, 렌더가 비결정적이라 `OutOfSync` 소음이 생긴다 — 설계 F1)
이를 막으려고 Secret을 미리 만들고 `values.yaml` 은 **이름만** 참조한다.

| Secret 이름 | 데이터 키 | values 키 |
| --- | --- | --- |
| `airflow-fernet-key` | `fernet-key` | `fernetKeySecretName` |
| `airflow-jwt-secret` | `jwt-secret` | `jwtSecretName` |
| `airflow-webserver-secret` | `api-secret-key` | `apiSecretKeySecretName` |

생성 절차는 저장소의 [`docs/airflow-secret.md`](https://github.com/Melting-Face/argocd-study/blob/main/docs/airflow-secret.md)
가 정본이다(값은 `$(...)` 치환으로만 넘기고, `get secret || create` 로 "없을 때만" 만든다).
`tests/render.test.sh` 의 단언 1~3이 회귀를 막는다 — 두 번 렌더한 결과가 바이트 동일한지,
chart가 이 세 Secret을 만들지 않는지, 환경변수가 위 표의 (이름, 키)를 `secretKeyRef` 로
가리키는지.

### 네임스페이스의 주인은 사람이다

Secret은 Application보다 먼저 있어야 하므로 **사람이 `airflow` 네임스페이스를 먼저
만든다.** Application의 `CreateNamespace=true` 는 이미 있는 네임스페이스를 쓸 뿐
`managedNamespaceMetadata` 를 쓰지 않으므로 ArgoCD가 소유하지 않는다(설계 §5-1). 따라서
`airflow` 네임스페이스의 주인은 사람이고 `podinfo` 네임스페이스의 주인은 ArgoCD다 — 의도된
비대칭이다. 대가도 있다. 클러스터를 새로 만들면 `apply` 두 번만으로 끝나지 않고 **사람이
끼는 단계가 하나 생긴다.** Secret을 빠뜨리면 파드가 `CreateContainerConfigError` 로 멈춘다
(설계 F7).

## ★ 훅 교착 — 이 노트의 핵심

### 증상 (2026-10-08, `apply` 12:13:22Z 이후)

`airflow` Application은 `Synced` 였는데 `Progressing` 이 10분 넘게 이어졌다.
`api-server`·`dag-processor`·`scheduler`·`triggerer` 파드는 `Init:Error` 를 반복했고,
네임스페이스에 **Job이 0개**였다. init 컨테이너 `wait-for-airflow-migrations` 의 로그에는
이 줄이 있었다(`values.yaml` §8 주석에 기록된 원문 — 중간은 생략 표기).

```text
TimeoutError: There are still unapplied migrations ... MigrationHead(s) in DB: set()
```

DB에 마이그레이션 헤드가 하나도 없다 — 마이그레이션이 한 번도 돌지 않았다.

### 원인

1. 공식 chart의 DB 마이그레이션 Job과 초기 사용자 Job은 기본으로
   `helm.sh/hook: post-install,post-upgrade` 를 단다.
2. ArgoCD는 Helm 훅을 자기 훅으로 옮긴다. Argo CD 문서 *"Helm Hooks"* 의 매핑표에 따르면
   `post-install`·`post-upgrade` 는 **PostSync** 가 된다.
3. PostSync는 sync에 속한 리소스가 **Healthy가 된 뒤에** 실행된다.
4. 그런데 파드는 마이그레이션이 끝나야 Healthy가 된다. 마이그레이션 Job은 파드가 Healthy가
   되어야 뜬다. **서로를 기다리는 교착이다.**

Helm CLI 설치와의 차이는 이 저장소에서 관측하지 않았다 — 위 매핑이 교착의 원인이라는 판정은
ArgoCD 위에서의 관측과 공식 문서 두 가지에 근거한다.

### 수정

Airflow Helm chart 1.22.0 문서 *"Installing the Helm Chart with Argo CD, Flux, Rancher or
Terraform"* 의 권고대로 `values.yaml` 을 고쳤다(커밋 `974fcfe`).

```yaml
  migrateDatabaseJob:
    useHelmHooks: false
    jobAnnotations:
      "argocd.argoproj.io/hook": Sync
  createUserJob:
    useHelmHooks: false
```

- `useHelmHooks: false` 가 둘 — chart가 Job에 `helm.sh/hook` 을 달지 않게 한다.
- 마이그레이션 Job에는 ArgoCD의 `Sync` 훅을 직접 단다. `Sync` 훅은 PostSync와 달리
  sync 본 단계에서 실행되어 다른 리소스의 Healthy를 선행 조건으로 두지 않는다(수정 후
  12:36에 마이그레이션이 실제로 시작된 것이 관측 근거다).
- **트레이드오프(문서가 인정)**: `Sync` 훅은 **sync마다** 다시 돈다. 마이그레이션이 매번
  재실행된다. 이상적이지 않지만 자동이다.

`tests/render.test.sh` 에 두 단언을 더했다.

- 단언 6: `helm.sh/hook` 어노테이션이 붙은 **Job** 이 0개다.
- 단언 7: `*run-airflow-migrations` Job이 일반 리소스로 렌더되고
  `argocd.argoproj.io/hook: Sync` 를 가진다.

수정 전 렌더에서 두 단언이 실제로 FAIL 하는 것을 먼저 보았다(RED): 단언 6은
`Job/airflow-create-user`·`Job/airflow-run-airflow-migrations` 와
`Secret/airflow-broker-url` 을 잡았고, 단언 7은 Job 이름이 `run-airflow-migrations` 라
정규식을 고쳐야 했다. 수정 뒤 단언 1~7이 모두 PASS 였다.

한 가지 남은 것: `Secret/airflow-broker-url` 의 `helm.sh/hook: pre-install` 은 chart가
redis를 꺼도 렌더되고 끌 값이 없다. `pre-install` 은 PreSync로 매핑되어 이 교착과 무관하므로
단언 6을 Job으로 한정했다.

### 두 번째 함정 — 고친 커밋이 적용되지 않았다

수정 커밋을 push(12:27:18Z)했는데도 파드는 그대로였다. 앱은 `OutOfSync` / `Degraded`,
sync operation은 `Running` 이었고 이 상태가 12:27~12:29Z에 관측됐다. 이유는 이렇다. 처음의
sync operation이 **리소스가 Healthy가 되기를 기다리며 끝나지 않았다.** operation이
진행 중이면 자동 sync는 새 커밋을 적용하지 못한다. 교착을 만든 operation이 교착을 푸는
커밋의 적용을 막은 것이다.

해결은 그 operation을 끝내는 것이었다. 사용자 승인(12:35:30Z) 아래 `argocd app terminate-op`
을 `--core` 로 시도했으나 `configmap "argocd-cm" not found` 로 실패했고, 컨트롤러가
`status.operationState.phase` 를 `Terminating` 으로 직접 패치했다. (이 두 사실은 컨트롤러
세션의 보고에서 옮긴 것이다. 원장의 한 줄 기록은 "멈춘 op Terminating 패치" 까지다.)

### 이후 타임라인 (UTC, 원장 기록)

| 시각 | 사건 |
| --- | --- |
| 12:36 | 새 operation(`974fcfe`)이 시작되어 migrations 훅이 돈다 |
| 12:40:46 | `one or more synchronization tasks completed unsuccessfully. Retrying attempt #1` |
| 12:41:26 | `Succeeded`, `Synced` / `Healthy` |

중간의 한 번의 실패는 **자동 재시도**(attempt #1)가 흡수했다. 재시도 원인 — 어느 태스크가
왜 실패했는지 — 은 기록하지 않았다(**미관측**).

### 교훈 (CLAUDE.md 원칙 7)

첫 sync에서 ArgoCD는 `Synced` 를 보여줬다. 그러나 `Synced` 는 **Git의 매니페스트가
클러스터에 적용되었다**는 뜻이지 **의도한 것이 돌고 있다**는 뜻이 아니다. 이 사건에서
`Synced` 와 `Healthy` 는 서로 다른 축이었고(`Synced` / `Progressing`), 그 아래에서
파드는 한 번도 준비되지 못했다. 성공 신호는 컨트롤러가 그렇게 판단했다는 것뿐이다.

더해서 두 가지.

- 이 결함은 **계획(Task 3)과 설계에 없었다.** 설계 §6의 실패 모드 표에 이 교착이 빠져
  있었고, 관측으로 드러나서야 추가되었다(원장 판정 HOOK-R1 — 설계 F11로 기록하기로 했다).
- "멈춘 operation"은 수정이 **자동으로 도착하지 않는** 상태를 만든다. 고쳤는데 안 바뀐다면
  앱 상태 옆의 operation 단계(`Running` 인지)를 먼저 본다.

## 자원 관문 (Task 8 Step 0, 2026-10-08)

배포 전에 클러스터가 감당하는지 `helm template` 렌더에서 requests를 합산해 확인했다.

| 항목 | 값 |
| --- | --- |
| 노드 Allocatable | cpu 8 / mem 26679960Ki (≈26055Mi) |
| 배포 전 requests | cpu 1150m (14%) / mem 444Mi (1%) |
| airflow chart requests (Deployment·StatefulSet 컨테이너, Job 제외) | cpu 1.25 / mem 2240Mi |
| airflow chart limits | cpu 2.55 / mem 4480Mi |
| 합계 requests | cpu 2.40 (30%) / mem 2684Mi (≈10%) |

requests가 설정되지 않은 컨테이너는 0개였다. 기준은 80% 미만이었고 통과했다.

## 완료 관측 (G3, 2026-10-08)

모두 컨텍스트 `kind-argocd-study` 에서 관측했다(`task-8-observations.md`, 12:44:08Z 기록).

- 이미지: `ghcr.io/melting-face/airflow-dags:v0.1.0` 8개, `docker.io/bitnamilegacy/postgresql:16.1.0-debian-11-r15` 1개.
- DAG 임포트 오류: `dags list-import-errors` → `No data found`.
- `hello` DAG 실행 `manual__2026-10-08T12:41:52` → `success` (12:42:01Z 확인).
- 태스크 로그(DAG는 `images/airflow/dags/hello.py`, 스케줄·표시는 KST 정책):

  ```text
  hello from Airflow, now (KST) = 2026-10-08T21:41:55.496540+09:00
  ```

  UTC 12:41:55 가 `+09:00` 의 21:41:55 와 일치한다.
- 최종 상태: `Synced` / `Healthy`.

## G5 기준점 — 이미지 CD 비교용

이 값들은 **지금 아무 변화도 없었다는 기준선**이다. 이미지 태그를 올린 뒤 같은 값을 다시
읽어 Secret은 회전하지 않았고(`resourceVersion` 동일) 워크로드는 한 번만 롤링되었는지
(`generation` 증가) 비교한다. 비교는 이미지 CD 노트에서 한다 — 여기서는 기준만 기록한다.

```text
airflow-fernet-key rv=137576
airflow-jwt-secret rv=137577
airflow-webserver-secret rv=137578
Deployment/airflow-api-server gen=1
Deployment/airflow-dag-processor gen=1
StatefulSet/airflow-postgresql gen=1
StatefulSet/airflow-scheduler gen=1
StatefulSet/airflow-triggerer gen=1
```

## 아직 관측하지 않은 것

- 재시도(attempt #1)를 일으킨 태스크와 실패 원인.
- 마이그레이션 `Sync` 훅이 **이후 sync마다** 실제로 재실행되는지(문서가 말하는 트레이드오프
  — 재실행을 따로 관측하지 않았다).
- G5 비교 결과(이미지 태그 변경 이후의 `resourceVersion`·`generation`).
- `Secret/airflow-broker-url` 의 `pre-install` 훅이 PreSync로 매핑되어 무해하다는 서술은
  매핑표에 근거한 추론이다.

## 출처

- Argo CD 문서 *"Helm Hooks"* (user-guide/helm) — `post-install`·`post-upgrade` → PostSync 매핑
- Apache Airflow Helm chart 1.22.0 문서 *"Installing the Helm Chart with Argo CD, Flux, Rancher
  or Terraform"* — `useHelmHooks: false`, `Sync` 훅 권고
- Argo CD v3.5.3 소스 `reposerver/repository/repository.go` — 의존성 자동 빌드(설계 §4-3, §11 V4)
- 저장소: `gitops/charts/airflow/Chart.yaml`, `values.yaml`, `tests/render.test.sh`,
  `scripts/helm-dep-build.sh`, `docs/airflow-secret.md`, `images/airflow/dags/hello.py`
