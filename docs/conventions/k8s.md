# Kubernetes 규칙

> 이 문서는 `../dagster-study` `docs/conventions/k8s.md`(42KB)를 **대폭 절삭 이식**한 것이다.
> 원본 §1~7은 [docker.md]에 있던 원칙(이미지 고정·자원 한도·비밀 참조·non-root)을 K8s 리소스로
> 옮긴 **범용 규칙**이라 그대로 유효하다. 원본 §8(Dagster in-cluster 배치)과 §9~9-4(Spark
> Operator·Flink Operator·컴퓨트 동시 기동)·§11(Iceberg 카탈로그 정합)·§12(CNPG)는 **이
> 저장소에 없는 데이터 레이크하우스 전용 체계**라 전부 들어냈다. §10(클러스터 노출·연결)은
> kind-on-podman·ingress-nginx 관련 부분만 남기고 Spark/Flink/SeaweedFS 세부(로컬 레지스트리,
> 러너 이미지, gRPC TLS)는 들어냈다 — 이 저장소는 그런 컴퓨트 워크로드가 없다.
> **설계상 정본은 [설계 문서](../superpowers/specs/2026-10-04-argocd-study-design.md)** 다.
> 아래는 "어느 substrate에서도 유효한 일반 원칙"만 적고, 이 프로젝트 고유의 포트·호스트명
> 결정(D2·D3·D6)은 중복 서술하지 않는다.

## 1. 워크로드 유형

- **컨트롤러**(ArgoCD·ingress-nginx): `Deployment`.
- **GitOps 대상 워크로드**(podinfo·Airflow): ArgoCD Application이 생성·관리.
- **상태 저장**이 필요한 워크로드는 `StatefulSet` + `PersistentVolumeClaim`(PVC)로 데이터 유실을
  막는다. **`emptyDir`를 상태 저장에 쓰지 않는다** — 파드 재기동만으로 데이터가 전부 소멸한다.
- 노출은 `Service`(기본 ClusterIP), 외부 진입은 `Ingress`(§6).

## 2. 리소스 requests/limits 필수

모든 컨테이너에 `requests`(예약)·`limits`(상한)를 명시한다.

```yaml
resources:
  requests: { cpu: "500m", memory: "1Gi" }
  limits:   { cpu: "1",    memory: "2Gi" }
```

- `limits.memory` 합이 노드 할당가능 메모리를 넘지 않게 한다. kind 노드는 podman machine의
  자원(§6)을 나눠 쓰므로 여유를 좁게 잡는다.
- **예외는 외부(업스트림) 매니페스트를 그대로 적용하는 경우뿐**이고, 그때는 예외임을 기록한다
  — `../dagster-study`의 실측: ingress-nginx(kind provider `deploy.yaml`)는 `requests`만 있고
  `limits`가 없다. 이 저장소도 같은 업스트림 매니페스트를 쓰므로 같은 예외가 적용된다.

## 3. 헬스체크는 probe로

- `readinessProbe`(트래픽 수용 준비) · `livenessProbe`(교착 시 재시작) · 느린 기동은
  `startupProbe`로 보완한다.
- ArgoCD Application의 `Healthy` 판정은 이 probe들의 결과에 의존한다 — probe가 없으면
  ArgoCD가 "떠 있다"로만 보고 "준비됐다"를 구분하지 못한다.

## 4. 설정·비밀정보는 ConfigMap·Secret 참조 (하드코딩 금지)

- 비밀값은 `Secret`, 일반 설정은 `ConfigMap` → `envFrom`/`valueFrom`으로 주입한다.
- **Airflow 연결·크리덴셜은 Git에 넣지 않는다** — `kubectl create secret`으로 수동 생성하고
  Application은 참조만 한다(설계 문서 Step 4). Secret CR 자체를 평문 YAML로 커밋하지 않는다.
- 이미지 태그는 고정한다(`latest` 금지) + `imagePullPolicy` 명시.

## 5. RBAC 최소권한

- 워크로드별 `ServiceAccount`를 분리하고, 필요한 `Role`/`RoleBinding`만 부여한다.
  클러스터 전역 권한(`ClusterRole`) 남발을 피한다 — ArgoCD 자체는 다중 네임스페이스를
  관리하므로 `ClusterRole`이 필요하지만, **ArgoCD가 배포하는 애플리케이션**(podinfo·Airflow)의
  ServiceAccount까지 같은 권한을 받을 이유는 없다.
- `NetworkPolicy`로 파드 간 통신을 최소화한다(기본 deny + 허용 리스트). 이 저장소는 학습
  환경이라 Step 0~5에서 강제하지 않지만, 넣는다면 ingress-nginx → 대상 서비스 트래픽부터
  허용 목록에 올린다.

## 6. 보안 컨텍스트

- `securityContext`: `runAsNonRoot: true`·`readOnlyRootFilesystem`(이미지가 허용하는 범위에서)·
  `allowPrivilegeEscalation: false`·불필요 capability drop.

## 7. 패키징은 Helm

- 환경별 차이는 `values-<profile>.yaml`로 분리한다(예: `ingress-nginx.kind.yaml` vs
  `ingress-nginx.loadbalancer.yaml` — substrate에 따라 고르는 값만 다르고 템플릿은 공통).
- 이 저장소는 Helm 외에 **Helmfile**로 같은 릴리스를 재선언하는 실습이 있다(설계 D7) —
  두 도구가 같은 릴리스를 동시에 소유하면 안 되므로, 소유권 전환 시점(`terraform state rm`)을
  명확히 하고 그 전후로 한쪽만 `helm upgrade`/`helmfile apply`를 호출한다.
- Helm 차트를 직접 작성할 때는(Step 3 `gitops/charts/podinfo/`) `helm lint`로 검증하고,
  `helm template`로 렌더링한 결과를 plain manifest와 비교해 **의미 있는 차이만** 남는지 본다.

### 7-1. 이 저장소에서 작성하는 Helm chart가 지킬 것

이 저장소가 직접 작성한 chart(`terraform/platform/charts/root-app`,
`gitops/charts/podinfo`)는 아래를 지킨다 — 업스트림(outside) chart를 그대로 쓰는
경우(예: ingress-nginx)는 대상이 아니다.

- **버전을 정확히 고정한다** — `Chart.yaml`의 `version`·`appVersion`에 범위 연산자
  (`~>` 등)나 `latest`를 쓰지 않는다(전역 CLAUDE.md·§4와 같은 원칙).
- **`required`로 필수값을 강제한다** — `values.yaml` 기본값이 비어도 되는 필드는
  없다고 보고, 비었을 때 깨져야 하는 값(이미지 태그, ingress host, resources
  4값 등)은 템플릿에서 `required "에러 메시지" .Values.xxx`로 감싼다.
  🔴 **초록불 함정** — `helm lint --strict`는 `required` 미충족을 ERROR가 아니라
  WARN으로만 내고 exit 0으로 통과한다(실측, `.pre-commit-config.yaml`의
  `helm-lint` 훅 주석). **`helm template`(렌더 실행)만 실제로 실패시킨다** —
  값 수준 검증은 `helm lint`가 아니라 `helm template`/equivalence 테스트로 한다.
- **레이블 규약** — 정답지(plain manifest)가 이미 떠 있는 리소스를 chart로
  재작성할 때는 `selector.matchLabels`·pod 템플릿 레이블·`Service.spec.selector`를
  기존 레이블과 **글자 그대로** 맞춘다. `Deployment.spec.selector`는 생성 후
  불변 필드라, 여기서 어긋나면 Deployment가 교체되며 파드가 재생성된다. Helm이
  관용적으로 붙이는 `app.kubernetes.io/managed-by`·`helm.sh/chart` 레이블은
  리소스 자신의 `metadata.labels`에만 넣고 selector/pod 템플릿에는 넣지 않는다.
- **`.helmignore`를 둔다** — 패키징 대상이 아닌 파일(테스트 스크립트 등)을
  chart 아카이브에서 뺀다.

## 8. 클러스터 노출·연결 규칙 (kind-on-podman)

> 이 절은 `../dagster-study` §10의 kind/ingress 관련 교훈만 남긴 것이다. 이 프로젝트의
> 실제 포트·호스트명 결정은 설계 문서 D2·D3·R1·R12가 정본이고, 여기서는 **반복해 틀리기 쉬운
> 일반 함정**만 적는다.

- **kind는 공개 포트를 클러스터 생성 시점에만 정할 수 있다.** 노드가 컨테이너라 사후에 포트를
  추가할 수 없다 — `extraPortMappings`가 없으면 Ingress·NodePort 둘 다 호스트에서 닿지 않고,
  빠뜨렸다면 **클러스터 재생성**이 유일한 방법이다(`kind delete cluster` 후 재생성 — 레지스트리
  등 부가 자원까지 지우는 전용 다운 스크립트와 혼동하지 않는다).
- **macOS + Podman은 VM 안에서 동작한다** — kind는 그 VM(podman machine) 안 컨테이너로 노드를
  만든다. kind의 Podman provider는 experimental이라 **rootful 머신이 필수**다.
  `KIND_EXPERIMENTAL_PROVIDER`는 **kind CLI만 본다** — Terraform 프로바이더(`tehcyx/kind`)처럼
  `kind` 라이브러리를 직접 호출하는 경로는 이 환경변수를 보지 않고 docker→nerdctl→podman
  순서로 자동탐지한다(설계 문서 §8 상세, R1).
- **노출 범위는 포트가 아니라 그 포트가 제공하는 API가 정한다.** UI 하나만 열었다고 생각한
  포트가 실은 REST API도 함께 연다면(예: 같은 포트에 UI와 제어 API가 같이 얹힌 도구), 인증 없는
  제어 경로가 함께 열린다 — Ingress로 내보내기 전에 그 포트가 **무엇을 함께 노출하는지**
  확인한다.
- **Ingress 컨트롤러는 ingress-nginx**(kind provider 매니페스트)를 쓴다. 호스트명은
  `<service>.localtest.me`로 통일한다 — 공개 DNS가 127.0.0.1로 응답해 `/etc/hosts` 수정이
  필요 없다(DNS 장애 시 폴백은 `/etc/hosts` 또는 `nip.io`).
- **HTTP 계열(웹 UI)은 Ingress**로, 그 밖의 데이터 접속은 필요할 때 `port-forward`를 쓴다.
  이 저장소는 **운영 도구(ArgoCD)가 자기 접근 경로(ingress-nginx)를 스스로 배포하면 안 된다**는
  원칙을 따른다(설계 D3) — ingress-nginx는 Terraform이, 그 위의 애플리케이션 Ingress는
  ArgoCD가 관리한다.

## 참고

- Kubernetes 공식 문서: https://kubernetes.io/docs/home/
- Helm 문서: https://helm.sh/docs/
- Helmfile: https://github.com/helmfile/helmfile
- kind: https://kind.sigs.k8s.io/
- ingress-nginx: https://kubernetes.github.io/ingress-nginx/
- `../dagster-study` `docs/conventions/k8s.md` — §1~7·§10 kind/ingress 부분의 원출처
  (로컬 저장소, 실측 기반). §8(Dagster)·§9~9-4(Spark/Flink)·§11(Iceberg)·§12(CNPG)는
  이식하지 않았다.
