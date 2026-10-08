# ApplicationSet List generator — root Application 에서 주인 교체하기

Phase 3 Task 6의 기록이다. Phase 1~2에서 `podinfo` Application은 Terraform이 깐 **root
Application**(`gitops/apps/` 를 recurse로 읽는 앱)이 만들었다. 이것을 Terraform이 깐
**ApplicationSet `apps`**(List generator)가 만들도록 바꾸면서, 돌고 있는 `podinfo`
워크로드가 **재생성되지 않는지**를 두 번의 `apply`로 쪼개 관측했다.

질문은 둘이다.

1. 앱 목록의 주인을 Terraform에 두고, 앱의 내용(chart·values·이미지 태그)은 Git에서 끌어오는
   분업이 왜 맞는가.
2. 같은 이름의 Application이 이미 있을 때 ApplicationSet은 충돌하는가, 인수하는가.

## 왜 앱 목록은 Terraform이 쥐는가

설계 문서
([Phase 3 설계](https://github.com/Melting-Face/argocd-study/blob/main/docs/superpowers/specs/2026-10-07-applicationset-image-cd-design.md)
§1-2)는 중심 질문을 둘로 쪼갠다.

| 질문 | 주인 | 적용 방식 |
| --- | --- | --- |
| 어떤 앱이 존재하는가 (앱 목록) | Terraform | `terraform apply` (push, 드물다) |
| 그 앱이 어떤 chart·values·이미지 태그인가 | Git | ArgoCD 폴링 (pull, 잦다) |

앱 목록은 `terraform/platform/variables.tf` 의 `var.apps` 다. 원소는 `name`·`path`·
`namespace` 셋뿐이고 **이미지 태그는 넣지 않는다.** 태그가 Terraform에 있으면 이미지가
바뀔 때마다 `apply`가 필요해져 "Git에서 pull로 CD"가 깨진다. 그래서 `apply`는 **앱을
추가하거나 뺄 때만** 일어난다. 목록 검증은 변수에 붙어 있다 — `name` 중복 금지, `path` 는
`gitops/charts/` 로 시작, `name` 은 DNS-1123 label.

Terraform 쪽 선언은 `terraform/platform/argocd.tf` 의 `helm_release.appset` 이다.

```hcl
resource "helm_release" "appset" {
  name       = "appset"
  chart      = "${path.module}/charts/appset"
  namespace  = "argocd"
  depends_on = [helm_release.argo_cd]
  wait       = true

  values = [yamlencode({
    repoUrl = var.repo_url
    apps    = var.apps
  })]
}
```

`depends_on = [helm_release.argo_cd]` + `wait = true` 가 "ArgoCD가 준비된 뒤에 목록을
올린다"는 순서 보장이다. ApplicationSet을 `kubernetes_manifest` 가 아니라 **로컬 chart +
`helm_release`** 로 까는 이유는 root Application 때와 같다 — CRD가 plan 시점에 클러스터에
없어 스키마 조회가 안 된다(설계 D5).

## 두 겹의 템플릿

`terraform/platform/charts/appset/templates/applicationset.yaml` 에는 템플릿 엔진이
**둘** 있고, 각자 채우는 자리가 다르다.

| 자리 | 채우는 쪽 | 표기 |
| --- | --- | --- |
| `generators[0].list.elements` | Helm (`.Values.apps`) | `toYaml .Values.apps \| nindent 10` — 이스케이프 불필요 |
| `template.*` 의 `name`·`path`·`namespace` | ApplicationSet 컨트롤러 (각 element) | Helm 백틱 이스케이프로 감싼다 |

컨트롤러가 채울 자리를 Helm이 먼저 해석하면 `.name` 이 없어 렌더가 깨지거나 빈 값이 된다.
그래서 Helm 문자열 리터럴로 감싸 **그대로 통과**시킨다. 저장소의 실제 선언이다.

```yaml
  template:
    metadata:
      name: '{{`{{ .name }}`}}'
    spec:
      source:
        path: '{{`{{ .path }}`}}'
      destination:
        namespace: '{{`{{ .namespace }}`}}'
```

이 형태는 ArgoCD 공식 문서 *"Template"* (operator-manual/applicationset)이 Helm으로
ApplicationSet을 배포할 때 권하는 이스케이프다. 나머지 세부는 이렇다.

- `goTemplate: true` + `goTemplateOptions: [missingkey=error]` — element에 키가 빠지면 빈
  값으로 조용히 넘어가지 않고 오류로 드러낸다.
- 문자열 값은 홑따옴표로 감싼다. 이스케이프 필드는 안쪽에 백틱을 쓰고, `required` 메시지는
  큰따옴표를 쓰기 때문이다.
- `repoUrl` 은 `required` 로 막는다. 기본값이 빈 문자열이면 `helm lint` 는 WARN만 내고
  통과하지만 `helm template` 은 실패한다.
- `syncPolicy` 는 block-style로 쓴다 — 빈 맵·flow-style 맵은 ArgoCD가 정규화해 영구
  드리프트를 만든다([소스 타입 전환](argocd-source-types.md)).
- `automated`·`selfHeal`·`prune` 세 스위치를 모두 켠다. 독립된 스위치이므로 하나로 뭉뚱그려
  설명하지 않는다([드리프트와 self-heal](drift-and-selfheal.md)).

### 주석 함정 — 주석 안의 이중 중괄호도 Helm이 해석한다

템플릿 파일 맨 위 설명 주석에 컨트롤러 표현식을 예시로 적었더니, 렌더 결과에서 그 표현식이
**빈 문자열로 사라졌다**(Task 4 보고, 실측). YAML 주석(`#`)은 YAML 파서에게만 주석이고
Helm 템플릿 엔진은 텍스트 전체를 해석한다. 그래서 이 파일의 주석은 이중 중괄호를 쓰지 않고
"이중 중괄호 표현식"이라고 말로 풀어 쓴다.

이스케이프를 빠뜨려도 `helm template` 은 **에러 없이** 빈 값으로 통과한다. 그래서 chart에
`tests/render.test.sh` 를 두고, 이스케이프를 일부러 제거(`'{{ .path }}'`)해 본 결과
`FAIL: (a) 리터럴 {{ .path }} 가 렌더 결과에 없다 - Helm 이스케이프 누락` 으로 잡히는 것을
확인했다(Task 4 보고). 이 테스트는 pre-commit·CI에는 아직 연결하지 않았다.

## 이행 절차 — 두 번의 apply

root 가 `prune: true` 로 `podinfo` 를 소유하던 상태에서 순서를 틀리면 워크로드가 지워진다.
설계 §5-5의 순서이고, 관측 지점을 나누려고 `apply` 를 둘로 쪼갰다.

1. 사전 기록 (Deployment UID, Application의 `finalizers`·`ownerReferences`)
2. `helm_release.root_app` 제거 → **apply #1** (`Plan: 0 to add, 0 to change, 1 to destroy.`,
   대상은 `helm_release.root_app` 하나)
3. `gitops/apps/` 삭제 (root가 이미 없어 prune이 일어나지 않는다)
4. `helm_release.appset` 추가 → **apply #2** (`Plan: 1 to add, 0 to change, 0 to destroy.`)
5. 관측 후 `terraform plan` 0-diff 확인

apply #2의 plan이 렌더한 `values` 는 다음과 같았다(스택 `terraform/platform`, plan 요약 파일
기록).

```text
values = [
  <<-EOT
      "apps":
      - "name": "podinfo"
        "namespace": "podinfo"
        "path": "gitops/charts/podinfo"
      "repoUrl": "https://github.com/Melting-Face/argocd-study.git"
  EOT,
]
```

이 시점의 `var.apps` 기본값에는 `podinfo` 하나뿐이다. `airflow` 는 이미지가 GHCR에 생긴 뒤
목록에 추가한다(`variables.tf` 의 설명 주석).

## 관측 기록

모든 시각은 UTC다. 아래 값은 `task-6-preflight.md` 에 적힌 그대로이며, **기록에 없는 출력은
적지 않는다.** 사전 기록 외 단계에서 정확히 어떤 명령으로 뽑았는지는 기록에 남아 있지 않다 —
판정 명령은 설계 §7의 G1·G2 표와 Task 6 계획의 것이다.

### 사전 기록 (2026-10-08T10:38:40Z)

```text
podinfo Deployment UID: 153eae59-8ed1-456d-9185-600615718710
Application podinfo finalizers= ownerReferences= labels=
Application root finalizers= ownerReferences= labels={"app.kubernetes.io/managed-by":"Helm"}
```

`podinfo` Application에는 finalizer도 ownerReference도 **없다.** root에도 finalizer가 없다.

### apply #1 직후 (2026-10-08T11:29:20Z)

```text
NAME      SYNC STATUS   HEALTH STATUS
podinfo   Synced        Healthy
podinfo Deployment UID: 153eae59-8ed1-456d-9185-600615718710
podinfo-d6bf84d7-v9tzl   1/1   Running   1 (59m ago)   3d8h
```

root가 사라진 뒤 Application 목록에는 `podinfo` 행만 남았고, Deployment UID는 같다.

### apply #2 직후, G1·G2 (2026-10-08T11:31:40Z)

```text
NAME   AGE
apps   26s
NAME      SYNC STATUS   HEALTH STATUS
podinfo   Synced        Healthy
podinfo ownerReferences: [{"apiVersion":"argoproj.io/v1alpha1","blockOwnerDeletion":true,"controller":true,"kind":"ApplicationSet","name":"apps","uid":"ed1b081a-38c1-417e-b6a2-9c5977ee63f2"}]
podinfo finalizers: ["resources-finalizer.argocd.argoproj.io"]
podinfo Deployment UID: 153eae59-8ed1-456d-9185-600615718710
appset conditions: ErrorOccurred=False(ApplicationSetUpToDate) ParametersGenerated=True(ParametersGenerated) ResourcesUpToDate=True(ApplicationSetUpToDate)
```

### apply #2 이후 `terraform plan`

`terraform plan -detailed-exitcode` 의 종료 코드는 **0**(변경 없음)이었다.

### 전후 비교

| 항목 | 이행 전 (10:38:40Z) | 이행 후 (11:31:40Z) |
| --- | --- | --- |
| `podinfo` Application `ownerReferences` | 없음 | ApplicationSet `apps`, `controller: true`, `blockOwnerDeletion: true` |
| `podinfo` Application `finalizers` | 없음 | `resources-finalizer.argocd.argoproj.io` |
| `podinfo` Deployment UID | `153eae59-8ed1-456d-9185-600615718710` | `153eae59-8ed1-456d-9185-600615718710` (apply #1 직후에도 동일) |
| 상태 | — | `Synced` / `Healthy` |

## 교훈

### (a) finalizer 없는 root를 지워도 자식은 남는다

설계는 이를 **추론**으로만 갖고 있었다. ArgoCD *"Cluster Bootstrapping"* 문서는 자식 앱까지
지우려면 finalizer를 붙이라고 하는데, "붙이지 않으면 남는다"는 문장은 직접 없다(대우 추론).
사전 기록에서 root에 finalizer가 없음을 확인했고, apply #1 직후 `podinfo` 가 `Synced` /
`Healthy` 로 남고 Deployment UID가 같은 것으로 **추론이 관측으로 확인**됐다. 이 한 번의 관측이
증명하는 것은 "이 root(finalizer 없음)에 한해서"다.

### (b) ApplicationSet은 같은 이름의 Application과 충돌하지 않고 인수했다

ArgoCD v3.5.3 소스 `applicationset/utils/createOrUpdate.go` 의 `CreateOrUpdate` 는 같은
이름의 Application이 있으면 spec·labels·annotations·finalizers를 생성값으로 patch한 뒤
`SetControllerReference` 로 소유 참조를 건다. **소유자를 사전 검사하지 않는다.** 설계는 여기서
"인수가 예상 동작"이라고 소스로 읽었고(발췌 기반), 관측이 같았다. 전후 표의
`ownerReferences` 가 그 증거다. 오류가 났다면 `podinfo` Application을 non-cascade로 지우고
재생성시키는 대체 경로를 준비했지만 쓰지 않았다.

### (c) 인수는 finalizer를 **더한다** — 목록에서 빼면 워크로드가 사라진다

전후 표에서 눈여겨볼 곳은 finalizers 행이다. ArgoCD *"Application Deletion"* 문서에 따르면
ApplicationSet이 만든 Application에는 `resources-finalizer.argocd.argoproj.io` 가 기본으로
붙고, 그 Application이 지워지면 하위 리소스까지 cascade 삭제된다. 인수된 `podinfo` 도 이제
같다. 따라서 **앞으로 `var.apps` 에서 앱을 빼고 `apply` 하면 그 앱의 워크로드가 삭제된다**
(설계 F8). 이행 전에는 root 의 `prune` 이 Git 쪽 삭제에만 반응했는데, 이제는 Terraform
목록 변경이 곧 삭제 명령이다.

지우지 않고 빼려면 ApplicationSet의 `syncPolicy.preserveResourcesOnDeletion: true` 가
문서가 말하는 방법이다. 이 chart에는 아직 적용하지 않았다. `applicationsSync: create-only`
계열의 삭제 보호는 문서와 소스 서술이 상충한다고 설계가 판정해 쓰지 않는다.

### (d) 목록은 push, 내용은 pull

`apply`가 필요한 일은 앱의 추가·제거뿐이다. chart·values·이미지 태그는 Git에 커밋하면 ArgoCD가
폴링으로 가져간다. (c)의 삭제 위험도 이 분업 안에 있다 — 앱의 존재는 드물고 신중해야 하는
변경이라 `apply`라는 무거운 문 뒤에 둔 것이다.

### (e) 두 겹 템플릿과 주석 함정

위 두 절이 요지다. 이스케이프를 빠뜨리면 `helm template` 이 **조용히** 통과하므로 렌더 결과를
단언하는 테스트가 있어야 하고, 설명 주석에도 이중 중괄호를 쓰지 않는다.

### (f) 부수적으로 만난 것

- **tflint 미사용 변수**: apply #1에서 `root_app` 을 지우자 `var.repo_url` 의 소비자가
  사라져 `terraform_unused_declarations` 가 걸렸다. 두 번의 apply 사이에서만 참조가 없으므로
  `var.repo_url`·`var.apps` 에 `# tflint-ignore: terraform_unused_declarations` 를
  **임시로** 달았고, apply #2 커밋에서 `helm_release.appset` 이 소비하면서 지웠다. 두 apply를
  쪼갠 대가가 중간 상태의 린트 예외였다.
- **D4 CI 검사 삭제**: 상위 설계 D4는 `gitops/**` 의 `repoURL` 평문 중복을 CI가 일관성
  검사로 막는 구조였다. `gitops/apps/` 가 사라지니 `gitops/**` 에 `repoURL` 이 0개가 되고,
  값은 Terraform `var.repo_url` 한 곳에만 남는다. 중복이 구조적으로 소멸했으므로 `ci.yml` 의
  해당 스텝을 삭제했다. 검사를 고친 것이 아니라 **검사 대상이 없어진 것**이다.

## 아직 관측하지 않은 것

- 폴링 주기 안에서의 Git 변경 반영(이미지 태그 변경 CD)은 이 노트의 범위 밖이다.
- `preserveResourcesOnDeletion` 동작, 앱 제거 시의 실제 cascade 삭제는 **관측하지 않았다.**
  (c)의 서술은 공식 문서와 설계 F8에 근거한 것이다.
- 설계가 "root 가 만든 자식에는 controller ownerReference 가 없어 `AlreadyOwnedError` 경로를
  타지 않을 것"이라 본 점은 사전 기록(`ownerReferences=` 비어 있음)으로 부합한다. 소스의
  해당 분기를 따로 실행해 본 것은 아니다.

## 출처

- Argo CD v3.5.3 소스 `applicationset/utils/createOrUpdate.go` (`CreateOrUpdate`,
  `SetControllerReference`) — 설계 문서 §11 V3-c, 발췌 기반
- Argo CD 문서 *"Template"* (operator-manual/applicationset) — Helm 이스케이프
- Argo CD 문서 *"Application Deletion"* — resources-finalizer 기본 부착,
  `preserveResourcesOnDeletion`
- Argo CD 문서 *"Cluster Bootstrapping"* — 자식 앱은 finalizer가 있을 때만 cascade 삭제
- 저장소: `terraform/platform/argocd.tf`, `terraform/platform/variables.tf`,
  `terraform/platform/charts/appset/templates/applicationset.yaml`
