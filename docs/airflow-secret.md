# Airflow Secret 수동 생성 절차

이 문서는 Airflow가 쓰는 Secret 3종(fernet 키, JWT 서명 키, API 서버 세션 키)을
**Git에 넣지 않고** 클러스터에 수동으로 만드는 절차다. `gitops/charts/airflow/values.yaml`은
이 Secret들의 **이름만** 참조하고, 값은 참조하지 않는다.

- 대상 클러스터: `kind-argocd-study` (🔴 `KUBECONFIG=~/.kube/argocd-study.config` +
  `--context kind-argocd-study`를 반드시 쓴다 — 기본 `current-context`는 다른
  프로젝트의 클러스터를 가리킨다)
- 네임스페이스: `airflow` (소유자는 **사람**이다 — Application이 아니라 이 절차가 만든다)
- 클러스터당 **한 번** 수행한다.

| Secret 이름 | 데이터 키 | values 키 | 값 형식 |
| --- | --- | --- | --- |
| `airflow-fernet-key` | `fernet-key` | `fernetKeySecretName` | Fernet 키(32바이트 url-safe base64) |
| `airflow-jwt-secret` | `jwt-secret` | `jwtSecretName` | 임의 문자열 |
| `airflow-webserver-secret` | `api-secret-key` | `apiSecretKeySecretName` | 임의 문자열 |

## 1. 왜 chart가 스스로 만들게 두면 안 되는가

값을 비워 두면 chart가 fernet·JWT·API 키를 `randAlphaNum`으로 **렌더할 때마다** 새로
만든다. ArgoCD는 Git 변경이나 hard refresh 때마다 chart를 다시 렌더하므로 키가
그때마다 바뀌고, 그 결과 (a) fernet 키로 암호화해 DB에 저장한 Connection·Variable을 더
이상 복호화하지 못하고 (b) 이미 발급된 JWT와 세션이 무효가 되며 (c) 렌더마다 매니페스트가
달라져 영구적인 OutOfSync 노이즈가 생긴다(설계 문서 F1). 그래서 Secret을 **미리, 한 번**
만들고 values는 이름만 가리키게 한다.

`airflow-webserver-secret`에는 `api-secret-key` **하나만** 넣는다. Airflow 3 / chart
1.22.0은 이 Secret에서 `api-secret-key`만 읽고(`AIRFLOW__API__SECRET_KEY`), Airflow 2 전용인
`webserver-secret-key`는 읽지 않으며 `webserverSecretKeySecretName`도 values에서 삭제했기
때문이다.

## 2. 절차

값은 `$(...)` 치환으로만 넘긴다 — 셸 히스토리·문서·보고서에 값이 남지 않는다.

Fernet 키는 32바이트 url-safe base64여야 한다(`token_hex`는 형식이 달라 쓰지 않는다).
정식 생성기는 `Fernet.generate_key()`지만 `cryptography` 패키지가 없는 호스트가 있어
(이 저장소 작업 호스트의 `python3`에는 없었다) 표준 라이브러리만 쓰는 아래 명령을 쓴다.
Fernet 키가 정확히 "랜덤 32바이트의 url-safe base64"이므로 출력 형식이 같다.

```bash
export KUBECONFIG=~/.kube/argocd-study.config

# 1) 네임스페이스 — 멱등. 몇 번 실행해도 안전하다.
kubectl --context kind-argocd-study create namespace airflow \
  --dry-run=client -o yaml | kubectl --context kind-argocd-study apply -f -

# 2) Secret 3종 — "없을 때만 만든다". 아래 경고 참고.
kubectl --context kind-argocd-study -n airflow get secret airflow-fernet-key >/dev/null 2>&1 \
  || kubectl --context kind-argocd-study -n airflow create secret generic airflow-fernet-key \
    --from-literal=fernet-key="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"

kubectl --context kind-argocd-study -n airflow get secret airflow-jwt-secret >/dev/null 2>&1 \
  || kubectl --context kind-argocd-study -n airflow create secret generic airflow-jwt-secret \
    --from-literal=jwt-secret="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"

kubectl --context kind-argocd-study -n airflow get secret airflow-webserver-secret >/dev/null 2>&1 \
  || kubectl --context kind-argocd-study -n airflow create secret generic airflow-webserver-secret \
    --from-literal=api-secret-key="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
```

🔴 네임스페이스와 달리 Secret은 `create --dry-run | apply`로 멱등화하지 **않는다.** 그
방식은 재실행할 때마다 값을 **새로 생성해 덮어쓰고**, fernet 키가 바뀌면 이미 암호화되어
저장된 데이터를 복호화할 수 없게 된다. 그래서 `get secret ... || create ...`로 "없을 때만"
만든다. 의도적으로 키를 교체(rotate)하려면 Secret을 직접 지우고 다시 만들되, fernet은 기존
Connection·Variable을 다시 입력해야 한다는 점을 감수한다.

## 3. 확인

값은 가리고 Secret 이름과 데이터 키만 출력한다.

```bash
kubectl --context kind-argocd-study -n airflow get secret airflow-fernet-key airflow-jwt-secret airflow-webserver-secret \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.data}{"\n"}{end}' | sed -E 's/:"[^"]+"/:<redacted>/g'
```

관측 결과(2026-10-08 UTC, `kind-argocd-study`). 값은 명령의 `sed`가 `<redacted>`로 가린 것이다.
2절 블록 실행은 아래 3개 Secret과 네임스페이스를 새로 만들었다(종료 코드 0).

```text
namespace/airflow created
secret/airflow-fernet-key created
secret/airflow-jwt-secret created
secret/airflow-webserver-secret created
```

3절 확인 명령의 출력은 다음과 같다.

```text
airflow-fernet-key {"fernet-key":<redacted>}
airflow-jwt-secret {"jwt-secret":<redacted>}
airflow-webserver-secret {"api-secret-key":<redacted>}
```

판정: 세 Secret이 각각 위 표의 데이터 키 **하나씩만** 갖는다.

## 4. 왜 Git에 넣지 않는가

설계 문서(§2-2, 범위 밖 결정)가 **Secret 관리 자동화(SOPS / Sealed Secrets / External
Secrets)를 이 프로젝트의 학습 축에서 뺐다** — "그 자체로 축 하나"이기 때문이다. 이
저장소는 public이고(`git.md` §5, R9), 평문 Secret을 커밋하는 순간 그 값은 인터넷에
공개된다. 네 가지 자동화 축 중 하나를 더 추가하지 않기로 한 대가로, Airflow 연결·
크리덴셜·이 세션 키·fernet 키·JWT 키는 **수동 `kubectl create secret`**으로 둔다(`k8s.md` §4,
설계 문서 Step 4).

## 5. 대가 — "수동 개입 0회"가 깨지는 지점

Phase 1은 "클러스터 전체 파괴 후 `apply` 2회로 4분 40초, 수동 개입 **0회**"를
실증했다(설계 문서, Phase 1 최종 검증). 이 Secret 절차는 그 0회를 지킬 수 없게 한다.

- **복원 절차가 `apply` 2회만으로 끝나지 않는다.** `terraform apply`(cluster) →
  `terraform apply`(platform) 사이 또는 이후에, **사람이** 이 문서의 2절 명령을
  실행해야 한다. 자동화된 단계가 아니라 사람이 끼어드는 단계다.
- **잊으면 조용히 실패한다.** Secret이 하나라도 없으면 apiServer·scheduler·dagProcessor·
  triggerer 파드가 `CreateContainerConfigError`로 멈춘다(Secret의 `secretKeyRef`를
  찾지 못해서) — ArgoCD는 이걸 `Degraded`로 보여주지만, "Secret을 깜빡했다"는
  원인까지 알려주지는 않는다. 디버깅 시간이 추가로 든다.
  🔴 배포 전에 이 문서의 절차로 Secret 3종을 먼저 만든다.
- **측정 대상은 Task 7이다.** 이 문서는 "그 지점이 어디인지"만 못 박는다 — 실제
  소요 시간·반복 시 재현성은 Task 7이 전체 파괴·복원 재검증에서 잰다. 여기서
  미리 숫자를 추정해 적지 않는다(관측하지 않은 수치를 적지 않는다).
- **이것은 "보안을 위해 치른 작은 비용"으로 뭉개지 않는다.** 정확히는: 자동 복원
  경로에 **사람이 수행해야 하는 단일 실패 지점(SPOF)이 하나 생긴다.** 그 사람이
  이 문서를 보지 못하거나 순서를 놓치면 복원이 멈춘다. SOPS/Sealed Secrets/
  External Secrets 중 하나를 썼다면 이 단계도 Git 커밋(암호화된 값)으로
  자동화됐을 것이다 — 그 축을 쓰지 않기로 한 것이 범위 설계(§2-2)이고, 이 문서는
  그 결정이 복원 자동화에 실제로 입히는 손상을 숨기지 않고 적는 것이다.

## 6. 참고

- `gitops/charts/airflow/values.yaml` — 이 Secret 3종의 이름을 참조하는 값 파일.
- `docs/conventions/k8s.md` §4 — "Airflow 연결·크리덴셜은 Git에 넣지 않는다" 규칙의 정본.
- `docs/superpowers/specs/2026-10-04-argocd-study-design.md` §2-2 — Secret 관리
  자동화를 범위 밖으로 정한 결정과 이유.
