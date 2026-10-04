# 프로젝트 CLAUDE.md (argocd-study)

> 이 저장소는 ArgoCD·Terraform·Helm·Helmfile 네 도구를 **한 저장소에서 같이** 다루는
> 학습 프로젝트다. 중심 질문은 **"선언을 어디에 두고, 누가 적용하며, 누가 소유하는가"**이고,
> 그 답은 [설계 문서](docs/superpowers/specs/2026-10-04-argocd-study-design.md)가 정본이다.
> 이 문서는 요약/인덱스이고, 상세 규칙은 [`docs/conventions/`](docs/conventions/README.md)에
> 있다. 골격은 `../dagster-study`의 `CLAUDE.md`를 빌리고 내용은 이 저장소 기준으로 새로 썼다.

## 문서화 원칙

- **규칙 정본은 [`docs/conventions/`](docs/conventions/README.md)** 다. 이 문서·`AGENTS.md`는
  요약/인덱스이고, 규칙을 바꾸면 **정본과 함께 갱신**한다(단일 출처 유지).
- 문서는 한국어로 작성하고, 코드 식별자·명령어·경로는 원문 그대로 표기한다.
- **`README.md`·`docs/**`의 독자는 "클론해 따라 하려는 사람"이다.** 관측 전 명령의 기대
  출력을 지어내 적지 않는다 — 관측이 없으면 명령까지만 쓰고 결과란을 비운다
  ([설계 문서](docs/superpowers/specs/2026-10-04-argocd-study-design.md) §6의 "판정 기록
  규율"이 이 저장소 전체에 적용된다).
- **학습 노트는 `wiki/`**(`main` push 시 GitHub Actions가 단방향 미러한다) — 독자·통제가
  달라 [`docs/conventions/publishing.md`](docs/conventions/publishing.md)를 따른다.

## 커밋 컨벤션

- **Conventional Commits**를 따른다. 형식 `type(scope): 설명` — 설명은 한국어, 제목 **72자
  이내**. type 11종(`feat`·`fix`·`docs`·`style`·`refactor`·`perf`·`test`·`build`·`ci`·
  `chore`·`revert`) — 정본은 [`.gitlint`](.gitlint).
- gitlint가 `commit-msg` 스테이지로 강제하지만 **`pre-commit install --hook-type
  commit-msg`를 별도로 깔아야 로컬에서 작동한다**(`pre-commit install` 단독은 걸지 않는다) —
  이유는 [`AGENTS.md`](AGENTS.md) §강제 수단과 그 한계.
- git 워크플로(브랜치 전략·커밋 단위·공개 경고)는 [`docs/conventions/git.md`](docs/conventions/git.md).
- **커밋·푸시는 사용자 요청 시에만** 수행한다. 락 파일(`.terraform.lock.hcl`·`skills-lock.json`)은
  커밋 대상이다.

## 코딩 철학

1. **단순함** — 최소 인프라(YAGNI). 2스택이면 충분한 곳에 모듈·remote backend를 미리
   깔지 않는다(설계 §2-2 "범위 밖" 표가 이 판단의 기록이다).
2. **명시적** — 선언적 설정, 규칙은 문서로. ArgoCD의 `syncPolicy.automated`·`selfHeal`·
   `prune`처럼 **독립된 스위치를 하나로 뭉뚱그려 설명하지 않는다**.
3. **가독성** — 관심사 분리(스택 경계, `gitops/apps` vs `gitops/manifests`), 포매터 고정.
4. **비밀정보는 참조로** — Secret은 참조만, 값은 Git에 넣지 않는다.
5. **재사용은 3회부터 추출** — 억지 추상화를 먼저 만들지 않는다(Terraform 모듈화를 2스택
   평면 구조에 적용하지 않기로 한 것이 이 원칙의 적용례다, 설계 §2-2).
6. **추적 용이성** — 표준 파일명(`versions.tf`·`provider.tf`)·명시적 리소스 이름으로
   grep·점프가 쉬워야 한다.
7. **성공 신호를 의심한다** — "`Synced`/`Healthy`로 떴다"는 **컨트롤러가 그렇게 판단했다**
   이지 "의도한 상태다"가 아니다(수동 드리프트는 `selfHeal` 없이는 되돌아가지 않는다 —
   설계 Step 2가 그 실험이다). CI가 초록이어도 그것은 **커밋이 이미 공개된 뒤의 사후 신호**일
   뿐 봉쇄가 아니다 — 이 구분을 "막혀 있다"로 쓰지 않는다([`AGENTS.md`](AGENTS.md) 표).

## 프로젝트 구조 컨벤션

**소유권 경계가 이 저장소의 핵심 구조다**(설계 §3-1 "한 리소스는 한 주인만"):

| 주인 | 소유 대상 |
| --- | --- |
| `terraform/cluster/kind/` | kind 클러스터, 노드 레이블, 포트 매핑, kubeconfig |
| `terraform/platform/` | `argocd` 네임스페이스, ingress-nginx, ArgoCD, root Application 1개 |
| ArgoCD | `gitops/apps/**` 아래 모든 선언 (ArgoCD 자기 자신은 제외) |

- `gitops/apps/`는 root Application이 recurse로 읽는 디렉터리다. 하위 Application의
  `repoURL`은 **정적 YAML에 평문으로 중복**한다 — ArgoCD에 전역 변수가 없다(설계 D4).
- `gitops/manifests/**`(plain)·`gitops/charts/**`(Helm)는 **같은 앱의 다른 소스 타입**이다
  (Step 1 → Step 3 전환). 둘 다 지우지 않고 비교 자료로 남긴다.
- `helmfile.yaml`은 "또 하나의 배포 도구"가 아니라 **소유권 이전 실험**이다(설계 D7) —
  `terraform state rm` → `helmfile apply` 전환이 핵심이다.
- 전체 트리는 [설계 문서](docs/superpowers/specs/2026-10-04-argocd-study-design.md) §4.

## 테스트 컨벤션

4계층으로 나뉜다(비용 대비 신뢰도가 낮아지는 순서가 아니라 **실행 시점이 다른 순서**다):

1. **로컬 정적**(pre-commit) — `terraform fmt`·`tflint`·`yamllint`·`gitleaks`·`doc-lint` 등.
   `--no-verify`로 우회 가능하다.
2. **서버 정적**(`.github/workflows/ci.yml`) — 위와 같은 검사를 저장소 전체에 재실행한다.
   🔴 **봉쇄가 아니다** — `main`에 branch protection이 없고 직접 푸시 흐름이라, 커밋이
   **이미 공개된 뒤**에 도는 사후 신호다. 실효는 "훅을 안 깐 클론에서도 돈다"는 것 하나다.
3. **단위**(`.tftest.hcl`) — 변수 검증·`precondition` 로직을 클러스터 없이 검증한다.
4. **수동 관문**(Step별 완료 판정) — `plan` 0-diff, 파드 `Running`, HTTP 200, 상태 전이
   관측. **사람이 본다.** 각 Step의 판정 명령은 설계 문서 §6에 있고, **인프라에 붙는 검사는
   CI에 넣지 않는다**(인프라 가용성에 커밋이 묶이면 안 된다).

## 타임존 정책

- 이 저장소의 로그·상태(kind·ArgoCD·Kubernetes 이벤트)는 **UTC 그대로** 둔다 — 로컬 학습
  클러스터라 표시 변환의 이득이 적다.
- **Airflow DAG(Step 4)의 스케줄·표시만 KST(`Asia/Seoul`)로 명시**한다 — Airflow는
  스케줄 타임존을 DAG 단위로 선언할 수 있다(`timezone="Asia/Seoul"` 또는 pendulum
  객체). tz-aware datetime을 쓰고 naive datetime을 스케줄에 넣지 않는다.
- 범위가 Airflow DAG 하나뿐이라 세부 규칙은 Step 4 구현 시점에 위키 노트
  (`airflow-on-argocd.md`)로 구체화한다 — 지금은 원칙만 적는다.
