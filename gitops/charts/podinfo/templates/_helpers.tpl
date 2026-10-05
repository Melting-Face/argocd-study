{{/*
🔴 가장 중요한 파일 — 여기 레이블이 Phase 1 plain manifest
(gitops/manifests/podinfo/*.yaml)의 레이블과 어긋나면 Task 2에서 Deployment
selector/matchLabels가 바뀌어 파드가 재생성된다. Deployment.spec.selector는
생성 후 불변 필드라 한 글자 차이도 교체(delete+create)를 강제한다 — 그러면
"source.directory → source.helm 전환이 재생성을 일으키는가"라는 Task 2의 핵심
관측이 "chart 작성 실수 때문인지 소스 타입 전환 때문인지" 구분되지 않는다.

⇒ 그래서 이 chart는 Helm 관용 공통 레이블 세트(name/instance/version 전부를
   selector에 넣는 `helm create` 기본 패턴)를 쓰지 않는다. selector/pod 템플릿/
   Service selector에는 Phase 1과 완전히 같은 최소 레이블
   (`app.kubernetes.io/name: podinfo`) 하나만 쓴다.
*/}}
{{- define "podinfo.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
{{- end }}

{{/*
리소스 자신에게 붙는 레이블 — 선택자 레이블 + Helm이 관용적으로 붙이는
`app.kubernetes.io/managed-by`·`helm.sh/chart`. Deployment/Service/Ingress의
metadata.labels(자기 자신)에만 쓰고, selector/matchLabels/pod 템플릿 레이블에는
쓰지 않는다 — 그쪽은 위 podinfo.selectorLabels만 쓴다.

gitops/charts/podinfo/tests/equivalence.sh가 이 두 레이블(managed-by·helm.sh/chart)
을 "정당한 차이"로 보고 비교 전에 지운다 — plain manifest엔 당연히 없던 레이블이고,
Helm 엔진이 자동 주입하는 것도 아니라 이 _helpers.tpl이 공통 레이블 블록에 넣기로
선택한 것뿐이기 때문이다.
*/}}
{{- define "podinfo.labels" -}}
{{ include "podinfo.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
