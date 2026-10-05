# plain manifest를 Helm chart로 재작성하기 — podinfo

Phase 1이 손으로 쓴 `gitops/manifests/podinfo/{deployment,service,ingress}.yaml`을
`gitops/charts/podinfo/` Helm chart로 재작성하며 실제로 걸린 것을 적는다. 이
chart는 Phase 2 Task 2가 Application의 `source.directory`를 `source.helm`으로
바꿀 때 쓴다 — 바뀔 때 파드가 재생성되는지 관측하는 것이 그 Task의 핵심이고,
**그 관측이 chart 작성 실수가 아니라 소스 타입 전환 자체 때문이라고 말하려면
이 chart가 plain manifest와 의미상 같은 결과를 내야 한다.**

## 핵심 위험 — 레이블이 selector를 바꾸면 파드가 재생성된다

`helm create`가 만드는 기본 `_helpers.tpl`은 `app.kubernetes.io/name`·
`app.kubernetes.io/instance`·`app.kubernetes.io/version`·`app.kubernetes.io/managed-by`
를 묶어 selector에까지 넣는다. 이 저장소는 그 관용 패턴을 쓰지 않았다 — Phase 1
매니페스트의 selector/pod 템플릿/Service selector가 전부 `app.kubernetes.io/name:
podinfo` 하나뿐이기 때문이다.

`Deployment.spec.selector`는 생성 후 **불변 필드**다. 여기서 한 글자라도
달라지면 Kubernetes가 Deployment를 교체(delete+create)하고, 새 ReplicaSet·새
Pod가 뜬다 — Task 2가 관측하려는 "소스 타입 전환이 재생성을 일으키는가"라는
질문에 "chart가 selector를 바꿨기 때문"이라는 잡음이 섞여 버린다.

그래서 `templates/_helpers.tpl`을 두 블록으로 쪼갰다:

- `podinfo.selectorLabels` — `app.kubernetes.io/name: podinfo` 하나만. Deployment의
  `selector.matchLabels`·pod 템플릿 레이블·Service의 `selector`에 전부 이것만 쓴다.
- `podinfo.labels` — 위 selectorLabels + `app.kubernetes.io/managed-by`·
  `helm.sh/chart`. Deployment/Service/Ingress **자기 자신의** `metadata.labels`에만
  쓴다. 이 두 레이블은 top-level 리소스 레이블일 뿐 selector에 들어가지 않으므로
  Deployment 교체를 유발하지 않는다.

## 동등성 테스트 — 무엇을 "정당한 차이"로 보는가

`gitops/charts/podinfo/tests/equivalence.sh`가 `helm template`로 렌더링한 결과와
`gitops/manifests/podinfo/*.yaml`을 리소스별로 비교한다. 두 쪽을 YAML → JSON(Ruby
표준 라이브러리 `YAML`/`JSON`, 별도 설치 없이 macOS 기본 Ruby로 충분했다 — `yq`는
이 환경에 없었다) → `jq -S`(키 정렬)로 정규화한 뒤 `diff`한다.

**정당한 차이로 보고 비교 전에 지우는 것은 딱 둘이다**:

- `metadata.labels["app.kubernetes.io/managed-by"]`
- `metadata.labels["helm.sh/chart"]`

이 둘은 Helm "엔진"이 자동으로 주입하는 게 아니라 이 chart의 `_helpers.tpl`이
공통 레이블 블록(`podinfo.labels`)에 넣기로 **선택한 것**이다. 지우는 범위도
딱 `metadata.labels`로 한정했다 — `selector.matchLabels`·pod 템플릿 레이블은 전혀
건드리지 않는다. 그 외 모든 차이(필드 추가·삭제·값 불일치)는 실패로 본다.

### red → green

chart가 아직 없는 상태(Step 1 직후)에서 돌리면:

```
FAIL [deployment] helm template 렌더링 실패 — chart가 없거나 깨졌다:
    Error: unable to detect chart at .../gitops/charts/podinfo/Chart.yaml: open ... no such file or directory
FAIL [service] helm template 렌더링 실패 — chart가 없거나 깨졌다: (동일)
FAIL [ingress] helm template 렌더링 실패 — chart가 없거나 깨졌다: (동일)
```

`Chart.yaml`·`values.yaml`·templates 4개를 다 쓴 뒤 다시 돌리면:

```
PASS [deployment] 의미 있는 차이 없음
PASS [service] 의미 있는 차이 없음
PASS [ingress] 의미 있는 차이 없음
```

## `helm lint --strict`의 한계 — WARN과 ERROR는 다르다

`values.yaml`의 `ingress.host`를 빈 문자열로 바꾸고 실측했다:

```
$ helm lint gitops/charts/podinfo --strict
level=WARN msg="missing required values" message="values.yaml의 ingress.host 는 필수값이다"
==> Linting gitops/charts/podinfo
1 chart(s) linted, 0 chart(s) failed   # exit 0 — 통과

$ helm template podinfo gitops/charts/podinfo
Error: execution error at (podinfo/templates/ingress.yaml:15:15): values.yaml의 ingress.host 는 필수값이다
# exit 1 — 여기서만 실제로 실패한다
```

`required` 템플릿 함수로 막은 값은 **lint가 아니라 template(렌더 실행) 단계에서만**
터진다. `helm lint --strict`는 그 상황을 WARN으로만 보고하고 초록불을 낸다 —
"lint를 통과했다"를 "chart가 올바르다"로 읽으면 안 되는 이유다.

반대로 `Chart.yaml`의 `version:` 필드를 지우고 실측하면 lint 자체가 ERROR로
떨어진다(`[ERROR] Chart.yaml: version is required`, exit 1) — **Chart.yaml 구조
오류는 lint가 잡고, 값 수준 `required` 위반은 template이 잡는다.** 이 저장소의
`helm-lint` pre-commit 훅(`.pre-commit-config.yaml`)은 전자만 커버한다. 후자는
`tests/equivalence.sh`(내부에서 `helm template`을 호출한다)와 Task 2의 실제 배포
관측이 메운다.

### 깨뜨려서 훅이 실제로 잡는지 확인

`gitops/charts/podinfo/Chart.yaml`에서 `version:` 줄을 지우고
`pre-commit run helm-lint --all-files`를 돌리면:

```
Helm chart 린트 (helm lint --strict).....................................Failed
- hook id: helm-lint
- exit code: 1
...
--- helm lint --strict gitops/charts/podinfo ---
==> Linting gitops/charts/podinfo
[ERROR] Chart.yaml: version is required
...
Error: 1 chart(s) linted, 1 chart(s) failed
```

같은 실행에서 `terraform/platform/charts/root-app`도 같이 린트되는 것을 확인했다
(훅이 두 chart를 순회한다) — 그쪽은 구조 오류가 없어 WARN(앞서 언급한 같은
`required` 한계)만 내고 자기 차례는 통과했다. `version:`을 되돌리면 다시
`Passed`로 돌아온다.

## 왜 `kubectl --dry-run=client`로 정규화하지 않았는가

brief는 정규화 수단으로 `yq` 또는 `kubectl --dry-run=client -o yaml`을 제안했다.
`kubectl create -f <manifest> --dry-run=client -o yaml`을 먼저 시도했는데, 이
환경에서는 discovery 정보를 얻으려 API 서버에 접속을 시도하다 클러스터가
닿지 않으면(`connect: connection refused`) 실패했다 — 떠 있을 때도 "접속을
시도한다"는 사실 자체가 이 Task의 "클러스터를 건드리지 않는다" 제약과 어긋난다.
Phase 1 매니페스트가 `protocol: TCP`·`imagePullPolicy` 같은 필드를 이미 전부
명시해 둔 덕에 API 서버 쪽 기본값 보정(defaulting)이 애초에 필요 없었다 — 그래서
완전히 로컬인 Ruby(YAML)+jq 조합으로 바꿨다.

## 남은 우려

- `helm-lint` pre-commit 훅은 시스템에 설치된 `helm` 바이너리를 그대로 호출한다
  (`terraform_tflint`처럼 pre-commit이 버전을 받아 캐시하지 않는다) — 로컬과 CI의
  helm 버전이 다르면 린트 결과가 달라질 수 있다(관측하지 않음, 구조상 가능성만
  적는다).
- 이 chart는 `values.yaml`에 기본값을 채워 뒀고 `required`는 "비었을 때"만
  막는다 — 기본값 자체가 Phase 1 실측과 다른 값으로 조용히 바뀌는 것은
  `tests/equivalence.sh`가 매 실행마다 잡아 준다.

## 참고

- `gitops/charts/podinfo/` — chart 본체
- `gitops/charts/podinfo/tests/equivalence.sh` — 동등성 테스트
- `gitops/manifests/podinfo/` — 정답지(plain manifest, Phase 1)
- `docs/conventions/k8s.md` §7-1 — 이 저장소의 Helm chart 규약
- `.pre-commit-config.yaml`의 `helm-lint` 훅 주석 — 도입 배경과 한계
- Helm `required` 함수: https://helm.sh/docs/chart_template_guide/function_list/#required
