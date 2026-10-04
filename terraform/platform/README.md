# terraform/platform — 플랫폼 스택 (ingress-nginx · Task 6 의 ArgoCD)

이 디렉터리는 **플랫폼**(클러스터 위에서 돌아가는 공통 인프라)을 소유한다. 지금은
ingress-nginx 하나지만(Task 5), Task 6 이 `argocd.tf`와 `values/argocd.yaml.tftpl`을
같은 스택에 더한다. `gitops/` 아래 애플리케이션은 이 스택이 아니라 ArgoCD 가 소유한다
(spec §3-1).

## 계약 — substrate 로부터 variable 로 받는 값

`terraform/cluster/kind`가 내보내는 substrate 계약 4개를 **variable 기본값으로 다시
선언**해서 받는다(`terraform_remote_state`를 쓰지 않는다 — 이유는
[`wiki/terraform-stack-boundaries.md`](../../wiki/terraform-stack-boundaries.md) 참고):

| variable | cluster 스택의 output | 값 (kind substrate) |
| --- | --- | --- |
| `kubeconfig_path` | `kubeconfig_path` | `~/.kube/argocd-study.config` |
| `kube_context` | `kube_context` | `kind-argocd-study` |
| `ingress_profile` | `ingress_profile` | `kind` |
| `storage_class` | `storage_class` | `standard` |

이 네 값은 **중복 선언**이다 — 분리의 대가다. 한쪽(cluster output)을 고치면
`local.auto.tfvars`(와 `.example`)도 같이 고쳐야 한다. 이 불일치는 기계가 잡아주지
않는다.

그 외 이 스택이 직접 선언하는 변수:

- `repo_url` — Task 6 의 ArgoCD root Application 이 쓴다. HTTPS 고정(validation).
  선언이 사용보다 앞선다(Task 5 에서 먼저 선언, Task 6 에서 참조).
- `http_host_port` — cluster 스택의 같은 이름 변수(`extra_port_mappings`의 실제 호스트
  포트)와 **값이 일치해야 한다**. 기본 `8081`. Task 6 의 `argocd_url` output 이 쓴다.

## 사용

```bash
cd terraform/platform
cp local.auto.tfvars.example local.auto.tfvars   # *.tfvars 는 .gitignore 대상
terraform init
terraform test                                   # 변수 검증 단위 테스트 (2 run)
terraform apply -var-file=local.auto.tfvars
```

## 완료 판정

```bash
kubectl get pods -n ingress-nginx                                 # controller Running
kubectl get validatingwebhookconfiguration | grep ingress-nginx   # webhook 등록됨
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8081   # 404 (컨트롤러는 살아있고 라우트가 없다)
terraform plan -var-file=local.auto.tfvars                        # No changes
```

🔑 **404 가 성공이다.** ingress-nginx 컨트롤러가 요청을 받았지만 아직 그 호스트명으로
라우팅할 Ingress 가 없다는 뜻이다. `connection refused`가 나오면 포트 매핑
(cluster 스택의 `extra_port_mappings`) 또는 `controller.hostPort.enabled`가 잘못된
것이다.

## DNS 판정 — `*.localtest.me`

이 저장소는 호스트명을 `<service>.localtest.me`로 통일한다(spec D2). 공개 DNS가
`127.0.0.1`로 응답하므로 평소에는 `/etc/hosts`를 건드릴 필요가 없다.

### 판정 명령

```bash
dig +short argocd.localtest.me     # 기대: 127.0.0.1
dig +short podinfo.localtest.me    # 기대: 127.0.0.1
```

`127.0.0.1` 한 줄만 나오면 정상이다. 아무것도 안 나오거나(NXDOMAIN) 다른 IP가
나오면 아래 폴백 절차로 간다.

### 폴백 절차 (해석 안 되는 망일 때)

1. 원인이 로컬 DNS(사내망·VPN·방화벽의 외부 DNS 차단)인지 먼저 확인한다.

   ```bash
   dig +short @8.8.8.8 argocd.localtest.me   # 공개 리졸버로 직접 질의 — 이게 되면 로컬 DNS 설정 문제
   ```

2. 그래도 안 되면 `/etc/hosts`에 정적 매핑을 추가한다(이 프로젝트가 쓰는 모든
   호스트명을 한 줄에 둔다).

   ```bash
   echo "127.0.0.1 argocd.localtest.me podinfo.localtest.me" | sudo tee -a /etc/hosts
   ```

   되돌릴 때는 같은 줄을 `/etc/hosts`에서 지운다.

3. `/etc/hosts` 편집 권한이 없는 환경(관리형 기기 등)이라면 `nip.io`로 호스트명
   자체를 바꾼다 — IP를 호스트명에 인코딩해 DNS 질의 없이 항상 해석된다.

   ```
   http://argocd.127.0.0.1.nip.io:8081
   ```

   이 경우 `values/ingress-nginx.*.yaml`을 바꾸는 게 아니라, Task 6 의 ArgoCD
   Ingress `host` 필드(또는 해당 애플리케이션의 Ingress `host`)를 `nip.io` 형태로
   바꿔야 한다 — Ingress 쪽 호스트명 매칭 규칙이기 때문이다.

### 이 환경의 실측

```
$ dig +short argocd.localtest.me
127.0.0.1
$ dig +short podinfo.localtest.me
127.0.0.1
```

정상 — 폴백이 필요하지 않았다.

## ingress-nginx values 프로파일

- `values/ingress-nginx.kind.yaml` — 지금 쓰는 프로파일. `hostPort` + `NodePort` +
  `nodeSelector(ingress-ready=true)` + control-plane taint `tolerations`로, kind 노드가
  컨테이너라 LoadBalancer 를 받을 수 없는 제약을 우회한다.
- `values/ingress-nginx.loadbalancer.yaml` — **지금 쓰이지 않는다.** substrate 중립화
  (spec D6)가 코드로 가능하다는 증명으로 둔다. `controller.service.type: LoadBalancer`
  만 바꾸면 되는 substrate(클라우드 LB·docker 위의 kind 등)로 교체할 때 이 파일을
  고른다.

## 알려진 제약

- `terraform destroy`는 이 README 작성 시점 기준 실행하지 않았다 — 이 클러스터가
  Task 6~8 의 전제라 비가역 명령을 피했다(Task 5 brief 의 승인 게이트 경고 참고).
