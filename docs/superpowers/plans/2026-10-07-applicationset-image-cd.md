# ArgoCD 스터디 환경 — Phase 3 (ApplicationSet · 이미지 CD) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** root Application 을 Terraform 이 소유하는 ApplicationSet(List)으로 바꾸고, Airflow 를 우리 저장소의 umbrella chart + GHCR 커스텀 이미지로 배포하며, git tag push 한 번으로 이미지 빌드 → 태그 커밋 → ArgoCD pull 재배포가 사람 개입 없이 일어나게 한다.

**Architecture:** Terraform(`terraform/platform`)은 ArgoCD 와 ApplicationSet 과 **앱 목록**만 쥔다. 앱의 내용·버전은 Git(`gitops/charts/**`)이 쥐고, Git 에 자동으로 쓰는 주체는 GitHub Actions 하나다(values 의 태그 한 줄). 클러스터 안 Git 쓰기 자격증명은 0개다.

**Tech Stack:** ArgoCD v3.5.3 ApplicationSet(List generator, goTemplate), Helm v4.2.0, `apache-airflow/airflow` chart 1.22.0(umbrella dependency), `apache/airflow:3.2.2`, GitHub Actions(`ubuntu-24.04-arm`), GHCR, Terraform `helm_release`, `yq`, `actionlint`

**Spec:** [`docs/superpowers/specs/2026-10-07-applicationset-image-cd-design.md`](../specs/2026-10-07-applicationset-image-cd-design.md) — 실행자는 spec 과 이 계획을 함께 읽는다. 상위 설계 [`2026-10-04-argocd-study-design.md`](../specs/2026-10-04-argocd-study-design.md)

---

## Global Constraints

Phase 1·2 계획의 제약을 **전부 승계**한다([Phase 2 계획](2026-10-05-argocd-study-phase2.md) Global Constraints: 커밋 규약·KUBECONFIG·`--context kind-argocd-study`·`lakehouse` 불가침·관측하지 않은 출력 금지 등). 추가분:

- 앱 목록 원소는 **`name`·`path`·`namespace` 셋뿐** — 이미지 태그를 Terraform 에 넣지 않는다(spec §3-2 규칙 1)
- 이미지: `ghcr.io/melting-face/airflow-dags` (소문자 — GHCR 요구), 태그 형식 **`vX.Y.Z`**, 첫 태그 `v0.1.0`
- base 이미지 `apache/airflow:3.2.2`, chart dependency `airflow` **1.22.0** @ `https://airflow.apache.org` — 정확한 버전 고정
- 빌드 플랫폼 **`linux/arm64` 단일**, 러너 `ubuntu-24.04-arm`
- 워크플로 권한은 기본 `GITHUB_TOKEN` + `permissions: { contents: write, packages: write }` 만. PAT·저장소 Secret 추가 금지
- Airflow Secret 3종 — 이름·데이터 키 고정(spec §4-3, V5):
  `airflow-fernet-key`/`fernet-key`, `airflow-jwt-secret`/`jwt-secret`, `airflow-webserver-secret`/`api-secret-key`
- ApplicationSet 이름 `apps`, 네임스페이스 `argocd`. 생성 Application 의 `syncPolicy` 는 `automated.selfHeal: true`·`automated.prune: true`·`CreateNamespace=true` — block-style YAML 로 쓴다(빈 맵·flow-style 금지)
- 🔴 **`git push`·`git push --tags`·GHCR 패키지 가시성 변경은 외부 공개 행위다** — 해당 Step 은 **사용자에게 확인을 받은 뒤** 실행한다. 이 계획 전체가 `main` 직접 작업이다(Phase 1·2 와 동일, GitOps 가 구조적으로 요구)
- 🔴 `terraform apply` 는 역할 규율상 devops-engineer 가 하지 않는다 — 컨트롤러(사람 승인)가 실행한다
- 🔴 **외부 공개 행위 승인은 Task 단위 1회**(grilling Q5) — 컨트롤러가 Task 시작 시 그 Task 의 push·tag·GHCR 가시성·apply 목록을 제시하고 한 번에 승인받는다. 서브에이전트는 이 행위를 하지 않는다
- 태그는 **빌드 이벤트**, 배포 상태는 **`main` 의 values 한 줄**이다(grilling Q8). GHCR 태그는 불변이고, 롤백·재전진은 `git revert` 로 한다

### Phase 2 가 남긴 상태 (이 계획의 출발점)
```
app root     Synced/Healthy  (gitops/apps, directory.recurse) — helm_release.root_app (Terraform)
app podinfo  Synced/Healthy  (gitops/charts/podinfo, Helm) — root 가 생성
helm 릴리스: ingress-nginx · argo-cd · root-app — 전부 Terraform 소유
gitops/values/airflow.yaml 존재(T3 산출, 미배포), docs/airflow-secret.md 존재
Phase 2 T4~T7 미착수 — T4 는 이 계획이 대체, T5~T7 은 이 계획 뒤에 실행(spec §9)
```

---

## Review Focus

- **첫 태그가 values 의 기존 태그와 같다** — values 초기값이 `v0.1.0` 이고 첫 릴리스 태그도 `v0.1.0` 이다. 태그 갱신 스크립트는 이 경우 **변경 없음으로 성공 종료**하고 빈 커밋을 만들지 않아야 한다(실패로 끝나면 첫 릴리스가 빨간불이 된다). (Task 2)
- **빌드 중 `main` 이 앞서 나감** — 사람이 태그 push 직후 다른 커밋을 push 하면 봇 push 가 non-fast-forward 로 거부된다. `pull --rebase` 후 1회 재시도하고, 그래도 실패하면 **워크플로 실패**로 끝나야 한다(조용히 성공 금지). (Task 2)
- **ApplicationSet 템플릿 필드가 Helm 에 먹힘** — 이스케이프를 하나라도 빠뜨리면 Helm 이 `{{ .name }}` 을 렌더해 **빈 문자열**이 된다. `helm lint` 는 통과한다. 렌더 결과에 `{{ .name }}`·`{{ .path }}`·`{{ .namespace }}` 리터럴이 **남아 있는지** 단언해야 잡힌다. (Task 4)
- **앱 목록이 비었거나 잘못됨** — `apps = []` 는 유효한 의도(앱 0개)로 렌더돼야 하고, 이름 중복·`gitops/charts/` 밖 경로·DNS-1123 위반 이름은 `plan` 에서 거부돼야 한다. 중복 이름은 ApplicationSet 컨트롤러가 런타임에야 거부하므로 Terraform 이 먼저 막는다. (Task 4)
- **태그가 `main` 밖 커밋을 가리킴 / 이미 있는 태그를 다시 push** — 전자는 `main` 의 `images/airflow/` 와 실행 이미지가 어긋나고, 후자는 레지스트리만 바뀌고 ArgoCD 는 모른다. 워크플로 `build` job 첫 단계에서 `git merge-base --is-ancestor "$GITHUB_SHA" origin/main` 실패 시, `docker buildx imagetools inspect ghcr.io/melting-face/airflow-dags:<tag>` 성공(이미 존재) 시 **둘 다 exit 1**(grilling Q1·Q2). (Task 2)
- **이미지는 올라갔는데 봇 커밋이 실패** — 태그 불변이라 태그 재push 로는 복구가 안 된다. `bump` job 을 분리해 GitHub "Re-run failed jobs" 가 `bump` 만 재실행하게 한다(grilling Q7). (Task 2)
- **렌더가 비결정적** — `*SecretName` 하나라도 빠지면 chart 가 그 Secret 을 랜덤 생성해 커밋마다 회전한다. 같은 chart 를 두 번 렌더해 **바이트 동일**한지와, 렌더 결과에 chart 생성 fernet/jwt/api Secret 이 **0개**인지 단언한다. (Task 3)

---

## File Structure

| 파일 | 책임 | Task |
| --- | --- | --- |
| `images/airflow/Dockerfile` | `apache/airflow:3.2.2` + `dags/` 복사 | 1 |
| `images/airflow/dags/hello.py` | 단일 태스크 DAG, `Asia/Seoul` | 1 |
| `images/airflow/tests/dag-import.test.sh` | 이미지 안에서 DAG import 오류 0 단언 | 1 |
| `scripts/bump-image-tag.sh` | values 파일의 태그 한 줄만 교체(멱등) | 2 |
| `scripts/tests/bump-image-tag.test.sh` | 위 스크립트의 변경·무변경·거부 케이스 | 2 |
| `.github/workflows/image.yml` | tag push → 빌드·푸시 → 태그 커밋 | 2 |
| `gitops/charts/airflow/{Chart.yaml,Chart.lock,values.yaml,.helmignore}` | 공식 chart umbrella (Phase 2 T4 대체) | 3 |
| `gitops/charts/airflow/tests/render.test.sh` | 렌더 결정성·secret 미생성·이미지 단언 | 3 |
| `terraform/platform/charts/appset/**` | ApplicationSet 로컬 chart (`root-app` 대체) | 4 |
| `terraform/platform/charts/appset/tests/render.test.sh` | 이스케이프 잔존·빈 목록 렌더 단언 | 4 |
| `terraform/platform/variables.tf`, `tests/validation.tftest.hcl` | `var.apps` 와 검증 | 4 |
| `terraform/platform/argocd.tf` | `root_app` 제거 → `appset` 추가 | 6 |
| `docs/airflow-secret.md` | Secret 3종 절차 | 5 |
| `.pre-commit-config.yaml`, `.github/workflows/ci.yml`, `.gitignore` | 훅·CI 갱신, `gitops/charts/*/charts/` 무시 | 2·3·4·6 |
| `wiki/{applicationset-list-generator,airflow-on-argocd,image-cd-with-actions}.md` | 관측 기록 | 6·8·9 |
| 상위 spec·Phase 2 계획·`CLAUDE.md`·`AGENTS.md`·`README.md`·`docs/conventions/terraform.md`·`.claude/agents/devops-*.md` | 소유권 표·경로 정정 | 10 |

---

## Task 1: Airflow 커스텀 이미지

**Files:**
- Create: `images/airflow/Dockerfile`, `images/airflow/dags/hello.py`, `images/airflow/tests/dag-import.test.sh`, `images/airflow/.dockerignore`

**Interfaces:**
- Produces: 빌드 컨텍스트 `images/airflow/` (Task 2 워크플로가 `context: images/airflow` 로 쓴다). DAG id **`hello`**(Task 8·9 가 UI·CLI 에서 이 id 로 찾는다)

- [ ] **Step 1: 실패하는 테스트 작성** — `dag-import.test.sh` 는 `podman build --platform linux/arm64 -t airflow-dags:test images/airflow` 후 `podman run --rm airflow-dags:test airflow dags list-import-errors -o json` 이 `[]` 인지, `airflow dags list -o json` 에 `"dag_id": "hello"` 가 있는지 단언한다. 실패 시 exit 1.
- [ ] **Step 2: 실행해 실패 확인** — `bash images/airflow/tests/dag-import.test.sh` → FAIL(Dockerfile 없음). 출력을 보고서에 남긴다.
- [ ] **Step 3: 구현** — `Dockerfile`: `FROM apache/airflow:3.2.2` + `COPY --chown=airflow:root dags/ /opt/airflow/dags/`. `hello.py`: `pendulum` tz-aware `start_date`(`tz="Asia/Seoul"`), `schedule=None`, 태스크 1개(`BashOperator` 또는 `@task`, 출력에 현재 KST 시각). 🔴 naive datetime 금지(CLAUDE.md 타임존 정책). 🔴 Airflow 3 import 경로를 쓴다 — `airflow.sdk` 의 `dag`/`task`. 옛 경로가 import 오류를 내면 Step 4 가 잡는다.
- [ ] **Step 4: 통과 확인** — 같은 명령 → PASS. `podman image inspect airflow-dags:test --format '{{.Architecture}}'` 가 `arm64`.
- [ ] **Step 5: 커밋** — `feat(airflow): 커스텀 이미지와 KST hello DAG 추가`

---

## Task 2: 태그 갱신 스크립트와 이미지 워크플로

**Files:**
- Create: `scripts/bump-image-tag.sh`, `scripts/tests/bump-image-tag.test.sh`, `.github/workflows/image.yml`
- Modify: `.pre-commit-config.yaml` (`actionlint` 훅 추가 — 버전 고정)

**Interfaces:**
- Consumes: Task 1 빌드 컨텍스트
- Produces: `scripts/bump-image-tag.sh <tag> <values-file>` — yq 경로 **`.airflow.images.airflow.tag`** 를 `<tag>` 로 바꾼다. 종료 코드: `0` + stdout `changed` / `0` + stdout `unchanged` / `2` = 태그 형식 위반(`^v[0-9]+\.[0-9]+\.[0-9]+$` 불일치) / `3` = 경로 없음. Task 3 의 values 파일이 이 경로를 가져야 한다.

- [ ] **Step 1: 실패하는 테스트 작성** — `bump-image-tag.test.sh` 가 임시 디렉터리의 픽스처 values(`airflow.images.airflow.tag: v0.1.0` + 주석 + 다른 키 몇 개)로 4 케이스를 단언한다:
  - `v0.1.1` → `changed`, exit 0, `git diff --no-index --numstat` 상 **변경 1줄**, 주석 보존
  - `v0.1.0`(같은 값) → `unchanged`, exit 0, 파일 바이트 동일
  - `0.1.1`·`v0.1`·`latest` → exit 2, 파일 불변
  - 경로가 없는 values → exit 3
- [ ] **Step 2: 실패 확인** — `bash scripts/tests/bump-image-tag.test.sh` → FAIL(스크립트 없음)
- [ ] **Step 3: 스크립트 구현** — `yq -i` 사용. 🔴 yq 가 들여쓰기·따옴표를 바꿔 **여러 줄 diff** 를 만들면 테스트가 잡는다 — 그 경우 `sed` 한 줄 치환으로 바꾸고 이유를 주석에 적는다.
- [ ] **Step 4: 통과 확인** — 같은 명령 → PASS. `shellcheck scripts/bump-image-tag.sh` 0건.
- [ ] **Step 5: 워크플로 작성** — `image.yml`, **job 2개**(grilling Q7):
  - `on: push: tags: ['v*.*.*']`, `concurrency: { group: image-airflow, cancel-in-progress: false }`
  - 공통 `runs-on: ubuntu-24.04-arm`
  - job `build`(`permissions: { contents: read, packages: write }`): checkout(태그 ref, `fetch-depth: 0`) → **조상 검사**(`git merge-base --is-ancestor "$GITHUB_SHA" origin/main`, 실패 시 exit 1 — Q1) → `docker/login-action`(ghcr.io, `${{ github.actor }}`, `${{ secrets.GITHUB_TOKEN }}`) → **불변 검사**(`docker buildx imagetools inspect` 가 성공하면 exit 1 — Q2) → `docker/build-push-action`(`context: images/airflow`, `platforms: linux/arm64`, `tags: ghcr.io/melting-face/airflow-dags:${{ github.ref_name }}`, `push: true`)
  - job `bump`(`needs: build`, `permissions: { contents: write }`): checkout `main` → `scripts/bump-image-tag.sh "${{ github.ref_name }}" gitops/charts/airflow/values.yaml` → `unchanged` 면 성공 종료 → `helm dependency build` + `helm template` 으로 렌더 확인(spec P3-R4) → 커밋 `chore(airflow): 이미지 태그를 <tag> 로 갱신`(작성자 `github-actions[bot]`) → `git push`, 실패 시 `git pull --rebase` 후 1회 재시도, 그래도 실패면 `exit 1`
  - 🔴 `bump` 가 실패하면 복구 = Actions UI "Re-run failed jobs"(`build` 는 재실행되지 않아 불변 검사에 걸리지 않는다). 이 절차를 워크플로 상단 주석에 적는다
  - 🔴 액션은 **커밋 SHA 또는 정확한 메이저 태그**로 고정하고 버전을 주석에 적는다
- [ ] **Step 6: 정적 검증** — `actionlint .github/workflows/image.yml` 0건. pre-commit `actionlint` 훅을 추가하고, `runs-on` 을 오타(`ubuntu-24.04-armm`)로 깨뜨려 **훅이 잡는지 관측한 뒤 되돌린다**.
- [ ] **Step 7: 커밋** — `ci(image): 태그 push 시 Airflow 이미지 빌드와 태그 커밋 워크플로 추가`. 🔴 이 Task 는 push 하지 않는다 — 워크플로 첫 실행은 Task 7.

---

## Task 3: Airflow umbrella chart

**Files:**
- Create: `gitops/charts/airflow/{Chart.yaml,Chart.lock,values.yaml,.helmignore}`, `gitops/charts/airflow/tests/render.test.sh`
- Delete: `gitops/values/airflow.yaml` (내용은 `values.yaml` 의 `airflow:` 아래로 이동, 주석 포함)
- Modify: `.gitignore`(`gitops/charts/*/charts/`), `.pre-commit-config.yaml`(`helm-lint` 대상·`check-yaml` exclude 에 `gitops/charts/airflow` 추가 — helm lint 전 `helm dependency build` 필요)

**Interfaces:**
- Consumes: Task 2 의 yq 경로 `.airflow.images.airflow.tag`
- Produces: `gitops/charts/airflow` — Task 4 의 앱 목록이 `path` 로 가리킨다. Secret 이름 3종(Global Constraints) — Task 5 가 그 이름으로 만든다

- [ ] **Step 1: 실패하는 테스트 작성** — `render.test.sh` 는 `helm dependency build` 후 `helm template airflow gitops/charts/airflow -n airflow` 를 **두 번** 실행해 단언한다:
  1. 두 렌더가 **바이트 동일**(렌더 결정성 — spec 성공 기준 5 의 정적 대응)
  2. `kind: Secret` 중 이름이 `*-fernet-key`·`*-jwt-secret`·`*-api-secret-key` 인 것이 **0개**
  3. 환경변수 `AIRFLOW__CORE__FERNET_KEY`·`AIRFLOW__API_AUTH__JWT_SECRET`·`AIRFLOW__API__SECRET_KEY` 의 `secretKeyRef` 가 각각 (`airflow-fernet-key`,`fernet-key`)·(`airflow-jwt-secret`,`jwt-secret`)·(`airflow-webserver-secret`,`api-secret-key`)
  4. 모든 airflow 컨테이너 이미지가 `ghcr.io/melting-face/airflow-dags:v0.1.0`
- [ ] **Step 2: 실패 확인** — FAIL(chart 없음)
- [ ] **Step 3: 구현** — `Chart.yaml`(`apiVersion: v2`, `name: airflow`, `version: 0.1.0`, dependency 고정), `helm dependency build` 로 `Chart.lock` 생성. values 는 기존 파일을 한 단계 들여쓰고 `images.airflow.{repository,tag}`, `fernetKeySecretName`, `jwtSecretName` 추가. `webserverSecretKeySecretName` 은 Airflow 2 전용이라 **삭제**하고 주석으로 이유를 남긴다.
- [ ] **Step 4: 통과 확인** — `bash gitops/charts/airflow/tests/render.test.sh` PASS, `helm lint --strict gitops/charts/airflow` 통과, pre-commit 전체 통과. `fernetKeySecretName` 한 줄을 지워 **단언 1·2 가 FAIL 하는지 관측하고 되돌린다**.
- [ ] **Step 4b: 기존 values 의미 보존(1회성 — 테스트에 넣지 않는다)** — 원본은 이 Task 가 지우므로 고정 커밋에서 꺼낸다: `git show f1484b4:gitops/values/airflow.yaml > <scratch>/orig.yaml` → 공식 chart tgz 를 그 values 로 직접 렌더한 결과와 umbrella 렌더를 diff. 허용 차이는 단언 2~4 가 만든 것(Secret 3종 생성 여부·`secretKeyRef` 이름·이미지·`checksum/*` 애너테이션)뿐이고, 그 외 0줄이어야 한다. diff 요약을 보고서에 남긴다(Secret 값은 가린다).
- [ ] **Step 5: 커밋** — `feat(airflow): 공식 chart umbrella 와 정적 Secret 참조 추가`. 🔴 클러스터를 건드리지 않는다 — 앱 목록에 아직 없다.

---

## Task 4: ApplicationSet chart 와 `var.apps`

**Files:**
- Create: `terraform/platform/charts/appset/{Chart.yaml,values.yaml,templates/applicationset.yaml}`, `terraform/platform/charts/appset/tests/render.test.sh`
- Modify: `terraform/platform/variables.tf`, `terraform/platform/tests/validation.tftest.hcl`, `.pre-commit-config.yaml`(helm-lint·check-yaml 대상에 `charts/appset` 추가)

**Interfaces:**
- Produces: chart values `namespace`(기본 `argocd`)·`repoUrl`(required)·`targetRevision`(기본 `main`)·`apps`(list, 기본 `[]`). Terraform `var.apps : list(object({ name = string, path = string, namespace = string }))`, 기본값 **podinfo 1개만**(`{ name = "podinfo", path = "gitops/charts/podinfo", namespace = "podinfo" }`) — airflow 는 Task 8 이 추가한다(이미지가 GHCR 에 생긴 뒤)
- 템플릿 형태는 spec §4-1 그대로(`goTemplate: true`, `missingkey=error`, elements 는 Helm `toYaml`, template 필드는 `'{{`{{ .x }}`}}'`)

- [ ] **Step 1: 실패하는 테스트 작성**
  - `render.test.sh`: (a) `--set repoUrl=https://github.com/Melting-Face/argocd-study.git` + 2개 앱 values 로 렌더 → `kind: ApplicationSet` 1개, `metadata.name: apps`, 렌더 결과에 리터럴 `{{ .name }}`·`{{ .path }}`·`{{ .namespace }}` 가 **남아 있음**, elements 2개 (b) `apps=[]` → 렌더 성공, `elements: []` (c) `repoUrl` 비움 → `helm template` 실패
  - `validation.tftest.hcl` 에 `run` 3개(`command = plan`, `expect_failures = [var.apps]`): `apps_reject_duplicate_names`, `apps_reject_path_outside_gitops_charts`(`path = "gitops/manifests/podinfo"`), `apps_reject_invalid_name`(`name = "Pod_Info"`)
- [ ] **Step 2: 실패 확인** — `bash terraform/platform/charts/appset/tests/render.test.sh` FAIL, `terraform -chdir=terraform/platform test` 의 새 run 3개 FAIL
- [ ] **Step 3: 구현** — chart 3파일과 `var.apps`(validation 3개: `length(distinct(names)) == length(names)`, `startswith(path, "gitops/charts/")`, `can(regex("^[a-z0-9]$|^[a-z0-9][-a-z0-9]*[a-z0-9]$", name))`(DNS-1123 label, 63자 이하 검사 추가)). 🔴 이스케이프 이유를 템플릿 주석에 적는다(root-app 템플릿 주석 형식 계승). 🔴 `argocd.tf` 는 이 Task 에서 **건드리지 않는다** — 교체는 Task 6.
- [ ] **Step 4: 통과 확인** — 두 테스트 PASS, `terraform validate`, `helm lint --strict`, pre-commit 전체. 이스케이프 하나를 일부러 지워 (a) 가 FAIL 하는 것을 **관측하고 되돌린다**.
- [ ] **Step 5: 커밋** — `feat(platform): ApplicationSet chart 와 앱 목록 변수 추가`

---

## Task 5: Airflow Secret 3종

**Files:**
- Modify: `docs/airflow-secret.md` (Secret 3종 절차, 네임스페이스 주인 = 사람, spec §5-1)

**Interfaces:**
- Consumes: Global Constraints 의 이름·키
- Produces: 클러스터의 `airflow` 네임스페이스와 Secret 3종 — Task 8 이 전제한다

- [ ] **Step 1: 문서 갱신** — 기존 1단계(네임스페이스 멱등 생성) 유지, 2단계를 Secret 3개로 확장. fernet 키는 `python3 -c 'from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())'`(🔴 fernet 은 32바이트 url-safe base64 형식이어야 한다 — `token_hex` 금지), jwt·api 는 `secrets.token_hex(16)`. 🔴 값이 셸 히스토리·문서에 남지 않게 `$(...)` 치환만 쓴다. "chart 가 스스로 만들게 두면 안 되는 이유"(spec F1) 한 단락.
- [ ] **Step 2: 실행(컨트롤러)** — 문서 절차대로 생성.
- [ ] **Step 3: 확인** — `kubectl --context kind-argocd-study -n airflow get secret airflow-fernet-key airflow-jwt-secret airflow-webserver-secret -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.data}{"\n"}{end}' | sed -E 's/:"[^"]+"/:<redacted>/g'` — 세 Secret 이 각자 기대 키 하나씩 갖는지(값은 출력하지 않는다)
- [ ] **Step 4: 커밋** — `docs(airflow): Secret 3종 수동 생성 절차로 확장`

---

## Task 6: root → ApplicationSet 이행 ★ 주인 교체 관측

**Files:**
- Modify: `terraform/platform/argocd.tf`(`root_app` 제거 → `appset` 추가), `terraform/platform/outputs.tf`(root 참조가 있으면)
- Delete: `terraform/platform/charts/root-app/`, `gitops/apps/`
- Modify: `.github/workflows/ci.yml`(D4 repoURL 검사 스텝 삭제 — spec §7), `.pre-commit-config.yaml`(root-app 경로 제거)
- Create: `wiki/applicationset-list-generator.md` / Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: Task 4 chart·`var.apps`
- Produces: `helm_release.appset`(`name = "appset"`, `chart = "${path.module}/charts/appset"`, `namespace = "argocd"`, `depends_on = [helm_release.argo_cd]`, `wait = true`, `values = [yamlencode({ repoUrl = var.repo_url, apps = var.apps })]`)

spec §5-5 순서를 **두 번의 apply** 로 지킨다.

- [ ] **Step 1: 사전 기록** — podinfo Deployment UID, `kubectl -n argocd get application podinfo -o jsonpath='{.metadata.finalizers} {.metadata.ownerReferences}'`, root 의 같은 필드. 보고서에 그대로 남긴다.
- [ ] **Step 2: apply #1 — root 제거** — `argocd.tf` 에서 `root_app` 블록 삭제, `charts/root-app/` 삭제 → `terraform plan`(삭제 1건만인지 확인) → 컨트롤러 `apply`. 관측: root Application 사라짐, **podinfo Application 잔존**(spec V3-d 추론의 판정), podinfo UID 불변.
  🔴 podinfo Application 이 사라지면 **즉시 멈추고 보고**한다 — 추론이 틀린 것이다.
- [ ] **Step 3: `gitops/apps/` 삭제 + D4 검사 삭제 + 커밋·push(사용자 확인)** — `refactor(gitops): root Application 과 gitops/apps 제거`. 이 시점 ArgoCD 에 Git 을 읽는 주인이 없으므로 prune 이 일어나지 않아야 한다.
- [ ] **Step 4: apply #2 — appset 추가** — `helm_release.appset` 추가 → `plan`(생성 1건) → 컨트롤러 `apply`.
- [ ] **Step 5: 관측 (G1·G2)** — `kubectl -n argocd get applicationset apps`, `argocd app list`, podinfo Application 의 `ownerReferences`(ApplicationSet `apps` 가 controller 인지)·`finalizers`(새로 붙었는지), **Deployment UID 불변**, Synced/Healthy. 인수 대신 오류가 나면 spec §5-5 대체 경로(non-cascade 삭제)를 쓰고 그 사실을 기록한다.
- [ ] **Step 6: `terraform plan` 0-diff 확인**
- [ ] **Step 7: 위키 + 커밋** — `applicationset-list-generator.md`: 두 겹 템플릿, Terraform 이 목록을 쥐는 이유, Step 1~5 의 관측(UID·ownerReferences·finalizers 전후 표). 커밋 `feat(platform): root Application 을 ApplicationSet 으로 교체` + `docs(wiki): ...` 분리.

---

## Task 7: 첫 이미지 릴리스 `v0.1.0`

**Files:** 없음(외부 상태만) — 관측은 Task 9 위키에 합친다

**Interfaces:**
- Consumes: Task 1·2·3 이 `main` 에 push 된 상태
- Produces: `ghcr.io/melting-face/airflow-dags:v0.1.0`(public) — Task 8 의 전제

- [ ] **Step 1: push 와 태그(사용자 확인)** — `git push origin main` 후 `git tag v0.1.0 && git push origin v0.1.0`
- [ ] **Step 2: 워크플로 관측** — `gh run watch`. 기대: 빌드·푸시 성공, 태그 갱신 단계가 **`unchanged` 로 종료**하고 봇 커밋이 **없다**(Review Focus 1). 실패하면 로그 원문을 보고서에 남긴다. 이 실행이 spec V1-c(`contents: write`)를 판정하지는 못한다는 점도 적는다(커밋이 없으므로).
- [ ] **Step 3: 패키지 가시성(사용자 확인)** — GHCR 패키지 설정에서 public 전환(spec F4). 확인: `podman logout ghcr.io; podman pull --platform linux/arm64 ghcr.io/melting-face/airflow-dags:v0.1.0` 이 **인증 없이** 성공.

---

## Task 8: Airflow 를 앱 목록에 추가 (G3·G5)

**Files:**
- Modify: `terraform/platform/variables.tf`(`var.apps` 기본값에 `{ name = "airflow", path = "gitops/charts/airflow", namespace = "airflow" }` 추가)
- Create: `wiki/airflow-on-argocd.md` / Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: Task 3 chart, Task 5 Secret, Task 7 이미지

- [ ] **Step 0: 자원 합계 관문(grilling Q9, Phase 2 T3 Step 4 이월)** — `helm template` 결과(airflow chart)의 CPU·메모리 requests·limits 합계 + 현재 클러스터 파드 requests 합계를 `kubectl --context kind-argocd-study describe node` 의 Allocatable 과 비교해 표로 남긴다. **requests 합계가 Allocatable 의 80% 를 넘으면 멈추고 보고**한다(80% 는 계획이 정한 값).
- [ ] **Step 1: plan** — `terraform plan` 이 `helm_release.appset` in-place 변경 1건(elements +1)만 보이는지. 이것이 spec §5-4 "앱 추가만 push" 경로의 첫 관측이다.
- [ ] **Step 2: apply(컨트롤러)**
- [ ] **Step 3: 관측 G3** — `argocd app get airflow`(Synced/Healthy), repo-server 가 의존성을 받았는지(Application 상태에 `ComparisonError` 없음 — spec V4 실측 판정), 파드 이미지가 `ghcr.io/melting-face/airflow-dags:v0.1.0`, UI(`airflow.localtest.me:8081`)에서 `hello` 수동 트리거 → success, 태스크 로그의 시각이 KST.
- [ ] **Step 4: 관측 G5 기준점** — fernet·jwt Secret 의 `resourceVersion` 과 airflow Deployment/StatefulSet 의 `metadata.generation` 기록(Task 9 에서 비교).
- [ ] **Step 5: 위키 + 커밋** — `airflow-on-argocd.md`: umbrella 를 택한 이유, 랜덤 Secret 문제와 3종 수동 생성, 네임스페이스 주인이 사람인 비대칭, KST DAG. 커밋 `feat(platform): 앱 목록에 airflow 추가` + `docs(wiki): ...`

---

## Task 9: 이미지 CD 종단 관측 `v0.1.1` (G4·G5·G6)

**Files:**
- Modify: `images/airflow/dags/hello.py`(출력 문구 변경 등 관측 가능한 작은 변경)
- Create: `wiki/image-cd-with-actions.md` / Modify: `wiki/_Sidebar.md`

- [ ] **Step 1: DAG 변경 커밋·push(사용자 확인)** — `feat(airflow): hello DAG 출력 문구 변경`. 관측: 이 push 만으로는 **아무것도 재배포되지 않는다**(파드 이미지 불변).
- [ ] **Step 2: 태그 push(사용자 확인)** — `git tag v0.1.1 && git push origin v0.1.1`, 시각 T0 기록(UTC)
- [ ] **Step 3: 관측 G4** — `gh run watch`(빌드 종료 T1), `git fetch && git log -1 origin/main`(봇 커밋 T2, 변경 1줄 — spec V1-c 판정), 봇 커밋에 **`ci.yml`·`image.yml` 이 새로 돌지 않았는지**(`gh run list` — spec V1 실측), ArgoCD 감지(`argocd app get airflow` 의 revision 변화 T3), 파드 이미지 `v0.1.1` 로 교체 완료 T4. T0~T4 를 표로 남긴다(spec 예상: T2→T3 ≤ 약 3분).
- [ ] **Step 4: 관측 G5** — Task 8 Step 4 와 비교: fernet·jwt Secret `resourceVersion` **불변**.
- [ ] **Step 5: 관측 G6** — `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository` 와 `-l argocd.argoproj.io/secret-type=repo-creds` 가 비었는지(Git 쓰기 자격증명 0).
- [ ] **Step 6: DAG 결과** — UI 에서 `hello` 재실행, 바뀐 문구 확인.
- [ ] **Step 7: 롤백 관측(grilling Q4, 사용자 승인)** — 봇 커밋을 `git revert` → push → 파드 이미지가 `v0.1.0` 으로 돌아가는 것과 경과 시간 관측 → 그 revert 를 다시 `git revert`(Q8) → `v0.1.1` 복귀 관측. 두 커밋 모두 `revert:` 타입. fernet·jwt `resourceVersion` 이 이 과정에서도 불변인지 확인.
- [ ] **Step 8: 위키 + 커밋** — `image-cd-with-actions.md`: tag → 빌드 → 커밋 → 폴링, Image Updater 를 안 쓴 이유(보안), T0~T4 표, 루프가 없는 이유 두 겹, **"태그는 빌드 이벤트, 배포 상태는 main"** 과 롤백·재전진 관측, 태그 불변·조상 검사·bump 재실행 복구. 커밋 `docs(wiki): ...`

---

## Task 10: 문서 정합

**Files:**
- Modify: `docs/superpowers/specs/2026-10-04-argocd-study-design.md`(§3-1·§4 트리·D4·D5·D7 에 "Phase 3 spec 으로 정정" 표기 — 본문 삭제 대신 정정 블록, 기존 D5 정정 형식 계승), `docs/superpowers/plans/2026-10-05-argocd-study-phase2.md`(T4 "Phase 3 가 대체", T5~T7 범위를 ingress-nginx 로 축소한다는 표기 — 체크박스는 건드리지 않는다), `CLAUDE.md`·`AGENTS.md`(소유권 표·`gitops/apps` 서술), `README.md`, `docs/conventions/terraform.md`, `.claude/agents/devops-engineer.md`·`devops-verifier.md`(`gitops/apps/*.yaml` 대조 서술 → ApplicationSet), `docs/superpowers/specs/2026-10-07-applicationset-image-cd-design.md`(상태 → 구현 완료, §11 🔴 항목을 관측 결과로 갱신)

- [ ] **Step 1: 잔존 참조 검사(실패 확인)** — `git grep -n -e 'gitops/apps' -e 'root-app' -e 'root Application' -e 'gitops/values/airflow' -- ':!docs/superpowers/plans/2026-10-0[45]*' ':!.superpowers'` → 현재 다수 히트
- [ ] **Step 2: 갱신** — 각 히트를 "역사 기록(정정 표기 유지)" 또는 "현행 서술(고침)" 으로 분류해 처리. 🔴 `CLAUDE.md`·`AGENTS.md` 는 요약이고 정본은 `docs/conventions/` 다 — 정본과 함께 갱신(CLAUDE.md 문서화 원칙).
- [ ] **Step 3: 확인** — Step 1 명령의 남은 히트가 전부 "역사 기록" 분류인지 보고서에 표로. pre-commit `doc-lint` 통과.
- [ ] **Step 4: 커밋** — `docs: Phase 3 소유권 변경을 설계·규약·에이전트 문서에 반영`
