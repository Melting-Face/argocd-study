# Airflow Secret 수동 생성 절차

이 문서는 Airflow가 쓰는 Flask 세션 암호화 키(이하 "webserver secret key")를
**Git에 넣지 않고** 클러스터에 수동으로 만드는 절차다. `gitops/values/airflow.yaml`은
이 Secret의 **이름만** 참조하고, 값은 참조하지 않는다.

- 대상 클러스터: `kind-argocd-study` (🔴 `KUBECONFIG=~/.kube/argocd-study.config` +
  `--context kind-argocd-study`를 반드시 쓴다 — 기본 `current-context`는 다른
  프로젝트의 클러스터를 가리킨다)
- Secret 이름: `airflow-webserver-secret`
- 네임스페이스: `airflow`
- 실행 주체: **Task 4** (이 Task는 절차만 적고 실행하지 않는다)

## 1. 왜 두 개의 데이터 키가 필요한가

Airflow 공식 chart(`apache-airflow/airflow` 1.22.0, appVersion 3.2.2)에는 같은 목적의
값 키가 두 개 있다.

| values 키 | 주입되는 환경변수 | Secret 데이터 키 | airflowVersion 게이트 |
| --- | --- | --- | --- |
| `webserverSecretKeySecretName` | `AIRFLOW__WEBSERVER__SECRET_KEY` | `webserver-secret-key` | `semverCompare "<3.0.0"` — **3.2.2에서는 꺼짐** |
| `apiSecretKeySecretName` | `AIRFLOW__API__SECRET_KEY` | `api-secret-key` | `semverCompare ">=3.0.0"` — **3.2.2에서 켜짐** |

(`templates/_helpers.yaml`의 `standard_airflow_environment`, `templates/secrets/webserver-secret-key-secret.yaml`,
`templates/secrets/api-secret-key-secret.yaml` 실측 — Task 3 `helm template` 렌더에서
`AIRFLOW__WEBSERVER__SECRET_KEY`는 0건, `AIRFLOW__API__SECRET_KEY`가 apiServer·scheduler·
dagProcessor·triggerer 10곳에서 `airflow-webserver-secret` / `api-secret-key`를 참조하는
것으로 확인했다.)

🔴 **Task 3·4 브리프가 전제한 "키는 `webserver-secret-key` 하나"는 Airflow 3.2.2 기준으로
틀렸다.** `gitops/values/airflow.yaml`은 두 values 키를 모두 같은 Secret 이름에 걸어
두었으므로, 이 Secret에는 **두 데이터 키를 모두** 채운다 — `api-secret-key`가 실제로
읽히는 쪽이고, `webserver-secret-key`는 지금은 아무도 읽지 않지만 향후 chart가
바뀌거나 누군가 `airflowVersion`을 내릴 때를 대비해 같이 채워 둔다(비용은 랜덤 문자열
하나 더 생성하는 것뿐이다).

## 2. 절차

```bash
export KUBECONFIG=~/.kube/argocd-study.config

# 1) 네임스페이스 — ArgoCD Application의 CreateNamespace=true가 보통 만들어 주지만,
#    Secret을 Application보다 먼저 넣으려면 네임스페이스가 먼저 있어야 한다.
kubectl --context kind-argocd-study create namespace airflow \
  --dry-run=client -o yaml | kubectl --context kind-argocd-study apply -f -

# 2) Secret 생성 — 두 데이터 키를 모두 채운다. 값은 각각 독립적으로 생성한다
#    (같은 문자열을 재사용해도 안전성에 문제는 없지만, 굳이 공유할 이유도 없다).
kubectl --context kind-argocd-study -n airflow create secret generic airflow-webserver-secret \
  --from-literal=api-secret-key="$(python3 -c 'import secrets;print(secrets.token_hex(16))')" \
  --from-literal=webserver-secret-key="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"

# 3) 존재 확인 — 이름만 확인한다. 값은 보고서·위키에 적지 않는다.
kubectl --context kind-argocd-study -n airflow get secret airflow-webserver-secret \
  -o jsonpath='{.metadata.name}{"\n"}'
kubectl --context kind-argocd-study -n airflow get secret airflow-webserver-secret \
  -o jsonpath='{.data}' | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin).keys()))'
# 기대 출력: ['api-secret-key', 'webserver-secret-key']
```

## 3. 왜 Git에 넣지 않는가

설계 문서(§2-2, 범위 밖 결정)가 **Secret 관리 자동화(SOPS / Sealed Secrets / External
Secrets)를 이 프로젝트의 학습 축에서 뺐다** — "그 자체로 축 하나"이기 때문이다. 이
저장소는 public이고(`git.md` §5, R9), 평문 Secret을 커밋하는 순간 그 값은 인터넷에
공개된다. 네 가지 자동화 축 중 하나를 더 추가하지 않기로 한 대가로, Airflow 연결·
크리덴셜·이 세션 키는 **수동 `kubectl create secret`**으로 둔다(`k8s.md` §4,
설계 문서 Step 4).

## 4. 대가 — "수동 개입 0회"가 깨지는 지점

Phase 1은 "클러스터 전체 파괴 후 `apply` 2회로 4분 40초, 수동 개입 **0회**"를
실증했다(설계 문서, Phase 1 최종 검증). 이 Secret 절차는 그 0회를 지킬 수 없게 한다.

- **복원 절차가 `apply` 2회만으로 끝나지 않는다.** `terraform apply`(cluster) →
  `terraform apply`(platform) 사이 또는 이후에, **사람이** 이 문서의 2절 명령을
  실행해야 한다. 자동화된 단계가 아니라 사람이 끼어드는 단계다.
- **잊으면 조용히 실패한다.** Secret이 없으면 apiServer·scheduler·dagProcessor·
  triggerer 파드가 `CreateContainerConfigError`로 멈춘다(Secret의 `secretKeyRef`를
  찾지 못해서) — ArgoCD는 이걸 `Degraded`로 보여주지만, "Secret을 깜빡했다"는
  원인까지 알려주지는 않는다. 디버깅 시간이 추가로 든다.
  🔴 Task 4가 **배포 시점에** 이 Secret을 실제로 만든다(이 문서의 절차를 따라).
- **측정 대상은 Task 7이다.** 이 문서는 "그 지점이 어디인지"만 못 박는다 — 실제
  소요 시간·반복 시 재현성은 Task 7이 전체 파괴·복원 재검증에서 잰다. 여기서
  미리 숫자를 추정해 적지 않는다(관측하지 않은 수치를 적지 않는다).
- **이것은 "보안을 위해 치른 작은 비용"으로 뭉개지 않는다.** 정확히는: 자동 복원
  경로에 **사람이 수행해야 하는 단일 실패 지점(SPOF)이 하나 생긴다.** 그 사람이
  이 문서를 보지 못하거나 순서를 놓치면 복원이 멈춘다. SOPS/Sealed Secrets/
  External Secrets 중 하나를 썼다면 이 단계도 Git 커밋(암호화된 값)으로
  자동화됐을 것이다 — 그 축을 쓰지 않기로 한 것이 범위 설계(§2-2)이고, 이 문서는
  그 결정이 복원 자동화에 실제로 입히는 손상을 숨기지 않고 적는 것이다.

## 5. 참고

- `gitops/values/airflow.yaml` — 이 Secret 이름을 참조하는 값 파일(Task 3).
- `docs/conventions/k8s.md` §4 — "Airflow 연결·크리덴셜은 Git에 넣지 않는다" 규칙의 정본.
- `docs/superpowers/specs/2026-10-04-argocd-study-design.md` §2-2 — Secret 관리
  자동화를 범위 밖으로 정한 결정과 이유.
