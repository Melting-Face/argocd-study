# ArgoCD 스터디 환경 — Phase 1 (Step 0~2) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `terraform apply` 2회로 ArgoCD가 떠 있는 kind 클러스터를 세우고, Git 커밋만으로 podinfo를 배포한 뒤 드리프트와 self-heal을 관측한다.

**Architecture:** Terraform 2스택(`cluster/kind` → `platform`)이 클러스터와 플랫폼 설비(ingress-nginx·ArgoCD)를 소유하고, ArgoCD의 root Application이 `gitops/apps/`를 recurse로 읽어 그 이후를 소유한다. 스택 간 결합은 kubeconfig 경로 문자열 하나뿐이다. 각 작업은 위키 노트 1장으로 닫힌다.

**Tech Stack:** Terraform(`tehcyx/kind`, `hashicorp/helm`, `hashicorp/external`), kind on Podman, Helm, ingress-nginx, Argo CD, GitHub Actions, pre-commit

**Spec:** [`docs/superpowers/specs/2026-10-04-argocd-study-design.md`](../specs/2026-10-04-argocd-study-design.md)

---

## Global Constraints

- Terraform `required_version = ">= 1.5.0"`. 프로바이더는 **전부 버전 고정**한다 — `latest` 금지.
- `hashicorp/helm ~> 3.0`, `tehcyx/kind` 는 구현 시점 최신 안정판을 **정확한 버전으로** 고정.
- Helm chart `argo/argo-cd` **10.9.6** (ArgoCD **v3.5.3**). `extraObjects` 로 root Application 주입.
- ArgoCD 는 `configs.params."server.insecure" = true` — TLS 종료는 Ingress 가 한다.
- 호스트 포트: `80 -> 8081`, `443 -> 8444`. **8080/8443 은 기존 `lakehouse` 클러스터가 쓰므로 금지.**
- 호스트명: `argocd.localtest.me`, `podinfo.localtest.me` (`*.localtest.me` → `127.0.0.1`).
- kubeconfig: `~/.kube/argocd-study.config` — 기본 kubeconfig 를 오염시키지 않는다.
- kube context: `kind-argocd-study`. 프로바이더에 **반드시 고정**한다.
- 클러스터 이름: `argocd-study`.
- `var.repo_url` = `https://github.com/Melting-Face/argocd-study.git`
- 브랜치: `main`. root Application 의 `targetRevision` 도 `main`.
- `terraform_remote_state` 를 쓰지 않는다. 스택 간 결합은 kubeconfig 경로 문자열뿐이다.
- Terraform 이 `argocd` 네임스페이스는 만들지만, **애플리케이션 네임스페이스는 만들지 않는다**(ArgoCD 의 `CreateNamespace=true` 가 한다).
- `.claude/settings.json` 의 `hooks` 는 **0개**로 둔다.
- 코드 주석은 한국어, 변수·함수·리소스명은 영어. 들여쓰기 스페이스 4칸(HCL 은 `terraform fmt` 기본인 2칸을 따른다).
- 커밋은 Conventional Commits, 설명은 한국어, 제목 72자 이내.
- 위키 원본은 `wiki/<slug>.md` 평평 구조, 프론트매터 없음, 링크에 `.md` 를 **붙여** 쓴다.
- **관측하지 않은 실행 출력을 위키에 적지 않는다.** 관측이 없으면 명령까지만 쓰고 기대 출력을 비운다.

## Review Focus

- **`targetRevision: main` 인데 작업 브랜치에서 커밋** → 푸시해도 ArgoCD 가 아무 반응이 없다. 초보가 가장 자주 빠지는 침묵 실패다. (Task 6)
- **podman machine 이 중지 상태에서 `apply`** → 런타임 탐지는 바이너리만 보므로 통과하고, kind 가 뒤늦게 불친절한 에러로 죽는다. (Task 4)
- **`gitops/apps/` 가 빈 디렉터리일 때 root Application 의 상태** → `Healthy` 인가 `Unknown` 인가. Task 6 직전에 반드시 지나가는 상태다. (Task 6)
- **`*.localtest.me` 가 해석되지 않는 망**(오프라인·사내 DNS) → Ingress 접근이 전부 죽고 폴백 경로가 문서에 없다. (Task 5)
- **저장소를 private 로 바꾸면** ArgoCD 가 인증 없이 fetch 하다 조용히 실패한다. 지금은 public 이라 무인증으로 동작한다. (Task 6)

---

## File Structure

| 파일 | 책임 |
| --- | --- |
| `.pre-commit-config.yaml` `.yamllint.yaml` `.gitleaks.toml` `.gitlint` `.tflint.hcl` | 로컬 정적 게이트 |
| `.github/workflows/ci.yml` | 서버 정적 게이트. **인프라에 붙는 명령 금지** |
| `.github/workflows/wiki.yml` `scripts/wiki_linkify.py` `scripts/doc_lint.py` | 위키 배달 파이프라인 |
| `terraform/cluster/kind/*.tf` | 스택 A — 클러스터와 substrate 계약 3개 |
| `terraform/cluster/kind/scripts/detect-runtime.sh` | 컨테이너 런타임 탐지 (precondition 입력) |
| `terraform/platform/ingress.tf` `values/ingress-nginx.*.yaml` | substrate 의존이 **유일하게** 남는 지점 |
| `terraform/platform/argocd.tf` `values/argocd.yaml.tftpl` | ArgoCD + root Application |
| `gitops/apps/podinfo.yaml` | Application 선언 |
| `gitops/manifests/podinfo/*.yaml` | podinfo 리소스 |
| `wiki/*.md` | 관측 기록 |

---

## Task 1: 정적 품질 게이트

**Files:**
- Create: `.pre-commit-config.yaml` `.yamllint.yaml` `.gitleaks.toml` `.gitlint` `.tflint.hcl` `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `pre-commit run --all-files` 와 `ci.yml` 의 `lint` 잡. 이후 모든 태스크의 커밋이 여기를 통과한다.

- [ ] **Step 1: `.pre-commit-config.yaml` 작성 — spec §7-4 의 "이식" 목록만**

`pre-commit-hooks` 에서 `check-added-large-files` `check-json` `check-merge-conflict` `check-toml`
`check-yaml` `detect-private-key` `end-of-file-fixer` `trailing-whitespace`,
그리고 `gitleaks` `gitlint` `yamllint` `shellcheck` `terraform_fmt` `tflint` `ruff-check` `ruff-format`.
**`doc-lint`·`doc-links` 는 Task 2 에서 추가한다**(`scripts/doc_lint.py` 가 아직 없다).
`.tflint.hcl` 은 `terraform` 플러그인 기본 규칙셋만 켠다.

- [ ] **Step 2: 설정 파일 4개 작성**

`.yamllint.yaml`(line-length 120, document-start 비활성),
`.gitleaks.toml`(기본 규칙),
`.gitlint`(Conventional Commits 의 `type(scope): 설명`, 제목 72자),
`.tflint.hcl`.

- [ ] **Step 3: 게이트가 실제로 잡는지 확인 — 일부러 깨뜨린다**

```bash
printf 'a:\n  b: 1\n   c: 2\n' > /tmp/bad.yaml && cp /tmp/bad.yaml ./bad.yaml
pre-commit run yamllint --files bad.yaml    # 기대: FAIL
printf 'AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE\n' > leak.env
pre-commit run gitleaks --all-files          # 기대: FAIL
rm -f bad.yaml leak.env
```
🔴 **게이트가 통과하는 것을 작동 증거로 읽지 않는다.** 깨뜨렸을 때 **잡는 것**이 증거다.

- [ ] **Step 4: 전체 통과 확인**

```bash
pre-commit install && pre-commit run --all-files   # 기대: 전부 Passed
```

- [ ] **Step 5: `.github/workflows/ci.yml` 작성**

`on: [pull_request, push(main)]`, `concurrency` 로 중복 취소, `permissions: contents: read`.
`lint` 잡 하나에 `pre-commit run --all-files` + `terraform fmt -check -recursive` + `terraform validate`(각 스택 `-backend=false` 초기화 후).
🔴 **`terraform apply`·`kubectl`·`helm install` 을 넣지 않는다**(spec §7-6 원칙 1). 파일만 읽는다.
워크플로 상단에 그 원칙 4개를 주석으로 남긴다.

- [ ] **Step 6: 커밋**

```bash
git add .pre-commit-config.yaml .yamllint.yaml .gitleaks.toml .gitlint .tflint.hcl .github/workflows/ci.yml
git commit -m "build(lint): 정적 품질 게이트 추가"
git push
```
`gh run list --limit 1` 로 CI 가 녹색인지 확인한다.

---

## Task 2: 위키 파이프라인

**Files:**
- Create: `scripts/wiki_linkify.py` `scripts/doc_lint.py` `wiki/Home.md` `wiki/_Sidebar.md` `.github/workflows/wiki.yml`
- Modify: `.pre-commit-config.yaml` (`doc-lint`·`doc-links` 추가)

**Interfaces:**
- Produces: `wiki/<slug>.md` 를 커밋하면 `main` push 시 GitHub 위키로 미러된다. Task 4~8 이 노트를 여기에 쓴다.

- [ ] **Step 1: `scripts/wiki_linkify.py` 이식**

`/Users/jin/dagster-study/scripts/wiki_linkify.py` 를 **그대로** 복사한다.
인라인 링크의 `.md` 접미어만 뗀다. 절대 URL·순수 앵커·참조형 링크·HTML `<a>` 는 건드리지 않는다.

- [ ] **Step 2: 변환이 맞는지 테스트**

```bash
mkdir -p /tmp/wt && printf '[a](other-page.md) [b](https://x.com/y.md) [c](#절)\n' > /tmp/wt/t.md
python3 scripts/wiki_linkify.py /tmp/wt && cat /tmp/wt/t.md
# 기대: [a](other-page) [b](https://x.com/y.md) [c](#절)
```

- [ ] **Step 3: `scripts/doc_lint.py` 이식(변형)**

원본에서 **링크 존재 검사(`--links`)와 시제 검사만** 남기고 데이터·분석 규칙은 제거한다.
`ruff` 로 포맷한다.

- [ ] **Step 4: `wiki/Home.md` 와 `wiki/_Sidebar.md` 작성**

`_Sidebar.md` 는 spec §11 의 10장 구성을 **섹션 3개**(ArgoCD 축 / Terraform·Helm·Helmfile 축 / 교차 축)로 나눠 적고,
아직 없는 노트는 **목록에 올리지 않는다**(죽은 링크는 `doc-links` 가 잡는다).
맨 끝에 `⚠️ 자동 미러됨 — 웹 편집 금지` 를 둔다.
🔴 `wiki/README.md` 를 만들지 않는다.

- [ ] **Step 5: `.pre-commit-config.yaml` 에 `doc-lint`·`doc-links` 추가하고 전체 통과 확인**

```bash
pre-commit run --all-files   # 기대: 전부 Passed
```

- [ ] **Step 6: `.github/workflows/wiki.yml` 작성**

`on: push(main, paths: ['wiki/**', '.github/workflows/wiki.yml'])` + `workflow_dispatch`.
`wiki/` 를 임시 디렉터리에 복사 → `wiki_linkify.py` 실행 → `<repo>.wiki.git` clone → 덮어쓰기 → commit·push.
`GITHUB_TOKEN` 만 쓴다. 상단 주석에 **선행조건 2개**(웹 UI 에서 첫 페이지 생성 / Restrict editing to collaborators only)와
*"이 워크플로는 게이트가 아니라 배달부"* 를 남긴다.

- [ ] **Step 7: 커밋하고 미러 1회 확인**

```bash
git add scripts/ wiki/ .github/workflows/wiki.yml .pre-commit-config.yaml
git commit -m "build(wiki): 위키 미러 파이프라인 추가"
git push
gh run list --workflow=wiki.yml --limit 1
```
🧍 **선행조건 2개는 사람이 웹 UI 에서 먼저 한다.** 안 돼 있으면 워크플로가 `Repository not found` 로 죽는다 —
그때 자동 우회하지 말고 사람에게 올린다.

---

## Task 3: `../dagster-study` 자산 이식

**Files:**
- Create: `.claude/agents/{devops-engineer,devops-verifier,tech-writer,researcher}.md`,
  `.agents/skills/{kubernetes-specialist,terraform-style-guide,terraform-test,git-commit,documentation}/`,
  `.claude/skills/*` (심링크), `.claude/settings.json`,
  `docs/conventions/{terraform,git,k8s,general,publishing}.md`, `docs/conventions/README.md`,
  `CLAUDE.md` `AGENTS.md` `README.md`
- Modify: `skills-lock.json`

**Interfaces:**
- Produces: 에이전트 4종·스킬 5종·컨벤션 5종. Task 4 이후가 이 규약 위에서 작업한다.

- [ ] **Step 1: 스킬 5종 복사하고 심링크 구조를 맞춘다**

`.agents/skills/<name>/` 에 원본(`references/` 포함)을 복사하고
`.claude/skills/<name> -> ../../.agents/skills/<name>` 심링크를 건다(기존 2개와 동일 구조).
`skills-lock.json` 에 각 항목의 `computedHash` 를 기록한다 — 출처는 `local:dagster-study`.

- [ ] **Step 2: 에이전트 4종 이식하며 변형한다**

| 파일 | 삭제 | 추가 |
| --- | --- | --- |
| `devops-engineer.md` | compose·Dagster·Spark·Flink 절 | Helm chart / Helmfile / ArgoCD Application 절 |
| `devops-verifier.md` | 데이터 적재 검증 절 | `argocd app get` 의 Sync/Health 대조 절 |
| `tech-writer.md` | `docs/posts/**`·DUA 절 | `wiki/**` 소유와 §11 위키 규약 |
| `researcher.md` | DUA 질의유출 통제 절 | (없음) |

각 파일의 프론트매터 `description` 을 argocd-study 기준으로 다시 쓴다.

- [ ] **Step 3: `.claude/settings.json` 작성 — `hooks` 는 빈 객체**

`permissions.ask` 에 `git commit` `git push`, `gh` 쓰기 서브커맨드,
`terraform apply|destroy|state rm`, `helm install|upgrade|uninstall`,
`helmfile apply|sync|destroy`, `kubectl delete|apply`, `kind delete cluster` 를 넣는다(약 20개).
`permissions.deny` 에 `curl`·`wget` 발신 동사 몇 개.
🔴 `hooks: {}` 로 둔다. **이유를 주석이 아니라 `AGENTS.md` 에 적는다**(JSON 에 주석을 쓸 수 없다).

- [ ] **Step 4: 컨벤션 5종 이식하며 절삭한다**

- `terraform.md` — 거의 그대로. 2스택 분리와 `config_context` 고정을 이 프로젝트 기준으로 보강.
- `k8s.md` — **42KB → ~8KB.** §9 Spark·§9-2 Flink·§9-3·§9-4·§11 Iceberg·§12 CNPG 를 **삭제**하고 §1~8·§10 만 남긴다.
- `publishing.md` — **§4-1 위키 산출물 규약만** 남긴다. DUA·소규모셀·`docs/posts/**` 전부 삭제.
- `git.md` — Conventional Commits 규약, 브랜치 전략(`main` 단일), **커밋이 곧 공개**(R9)라는 경고만 남긴다.
  dagster-study 의 worktree·저널 연동 절은 삭제한다(해당 체계가 없다).
- `general.md` — 비밀정보 금지선, 파일 명명(영문 kebab-case), 들여쓰기·주석 언어 규칙만 남긴다.
  데이터·노트북·분석 관련 절은 전부 삭제한다.
- `README.md` — 5개 문서의 지도.

- [ ] **Step 5: `CLAUDE.md` `AGENTS.md` `README.md` 작성**

dagster-study 의 **섹션 골격만** 빌리고 내용은 새로 쓴다(문서화 원칙 / 커밋 컨벤션 / 코딩 철학 /
프로젝트 구조 컨벤션 / 테스트 컨벤션 / 타임존 정책).
`AGENTS.md` 에 **훅을 0개로 둔 이유**(체계가 따라와야 작동한다)를 명시한다.
`README.md` 에는 **전제조건**(podman rootful machine, `argocd`·`helmfile` 설치)과 `terraform apply` 2회 절차를 적는다.

- [ ] **Step 6: 링크 검사와 커밋**

```bash
pre-commit run --all-files   # doc-links 가 상대경로 링크를 검증한다
git add -A && git commit -m "chore(agents): dagster-study 자산 선별 이식"
git push
```

---

## Task 4: 스택 A — kind 클러스터

**Files:**
- Create: `terraform/cluster/kind/{versions,variables,main,outputs}.tf`,
  `terraform/cluster/kind/scripts/detect-runtime.sh`,
  `terraform/cluster/kind/tests/validation.tftest.hcl`,
  `terraform/cluster/README.md`
- Create: `wiki/terraform-on-kind.md` `wiki/terraform-stack-boundaries.md`

**Interfaces:**
- Produces (substrate 계약): outputs `kubeconfig_path` (string) · `kube_context` (string) ·
  `ingress_profile` (string, `"kind"`) · `storage_class` (string).
  Task 5·6 의 `terraform/platform` 이 **이 네 값을 variable 로 받는다**(remote state 참조 없음).

- [ ] **Step 1: `scripts/detect-runtime.sh` 작성**

`docker` → `nerdctl` → `podman` 순으로 `command -v` 하여 **먼저 발견된 것**을 JSON 으로 출력한다.
이 순서는 kind 라이브러리 `DetectNodeProvider()` 와 **같아야 한다**(spec §8 R1).
출력: `{"detected":"podman"}`. 아무것도 없으면 `{"detected":"none"}`.

- [ ] **Step 2: 실패하는 테스트를 먼저 쓴다 — `tests/validation.tftest.hcl`**

```hcl
run "reject_lakehouse_ports" {
    command = plan
    variables {
        http_host_port = 8080    # 기존 lakehouse 클러스터가 점유
    }
    expect_failures = [var.http_host_port]
}

run "reject_unknown_runtime" {
    command = plan
    variables {
        expected_runtime = "containerd"
    }
    expect_failures = [var.expected_runtime]
}

run "defaults_are_the_spec_values" {
    command = plan
    assert {
        condition     = var.cluster_name == "argocd-study" && var.http_host_port == 8081 && var.https_host_port == 8444
        error_message = "기본값이 spec Global Constraints 와 다르다"
    }
}
```

- [ ] **Step 3: 테스트가 실패하는지 확인**

```bash
cd terraform/cluster/kind && terraform init -backend=false && terraform test
# 기대: FAIL — 변수도 리소스도 아직 없다
```

- [ ] **Step 4: `versions.tf` · `variables.tf` 구현**

`required_version = ">= 1.5.0"`. 프로바이더 `tehcyx/kind`(정확한 버전), `hashicorp/external ~> 2.3`.

변수와 검증:
- `cluster_name` (default `"argocd-study"`)
- `node_image` (default: kind 와 호환되는 `kindest/node:v1.3x.x` 고정 태그)
- `http_host_port` (default `8081`) — `validation`: `!contains([8080, 8443], var.http_host_port)`
- `https_host_port` (default `8444`) — 같은 검증
- `expected_runtime` (default `"podman"`) — `validation`: `contains(["docker","nerdctl","podman"], ...)`
- `kubeconfig_path` (default `"~/.kube/argocd-study.config"`)

각 변수 `description` 에 **왜 그 값인지**를 한 줄로 적는다(8080 금지 이유 등).

- [ ] **Step 5: 테스트가 통과하는지 확인**

```bash
terraform test   # 기대: 3 run 전부 PASS
```

- [ ] **Step 6: `main.tf` 구현**

`data "external" "runtime"` 이 Step 1 의 스크립트를 실행한다.
`resource "kind_cluster" "this"` 에:
- `name`, `node_image`, `wait_for_ready = true`, `kubeconfig_path = pathexpand(var.kubeconfig_path)`
- `kind_config` 블록: `node { role = "control-plane" }` 에
  `extra_port_mappings` 2개(`80→var.http_host_port`, `443→var.https_host_port`, `listen_address = "127.0.0.1"`),
  `labels = { "ingress-ready" = "true" }`
- `lifecycle.precondition`: `data.external.runtime.result.detected == var.expected_runtime`,
  `error_message` 에 **왜 환경변수로 고칠 수 없는지**(kind 라이브러리 자동탐지는 `KIND_EXPERIMENTAL_PROVIDER` 를 보지 않는다)를 적는다.

🔴 `extra_port_mappings` 는 **클러스터 생성 시점에만 지정 가능**하다. 주석으로 남긴다.

- [ ] **Step 7: `outputs.tf` 구현 — substrate 계약 4개**

`kubeconfig_path` `kube_context`(= `"kind-${var.cluster_name}"`) `ingress_profile`(= `"kind"`) `storage_class`(= `"standard"`).
`outputs.tf` 상단에 **"이 네 값이 계약이다. 다른 substrate 구현은 같은 이름·타입으로 내보내면 `platform` 이 안 바뀐다"** 를 적는다.

- [ ] **Step 8: 실제로 클러스터를 세운다**

```bash
terraform apply
kubectl --kubeconfig ~/.kube/argocd-study.config get nodes      # Ready
kubectl --kubeconfig ~/.kube/argocd-study.config get node -o jsonpath='{.items[0].metadata.labels.ingress-ready}'   # true
terraform plan                                                   # No changes
```

- [ ] **Step 9: Review Focus — podman machine 중지 상태를 재현한다**

```bash
podman machine stop && terraform plan
```
precondition 은 **바이너리만 보므로 통과**하고 kind 가 뒤늦게 죽는다.
**그 에러 원문을 그대로** `wiki/terraform-on-kind.md` 에 옮기고, 선행조건으로 `podman machine start` 를 적는다.
`podman machine start` 로 복구한다.
🔴 지어내지 않는다 — **실제로 관측한 문구만** 적는다.

- [ ] **Step 10: 위키 노트 2장과 `terraform/cluster/README.md` 작성**

- `wiki/terraform-on-kind.md` — `tehcyx/kind` 스키마, **R1 전문**(`resource_cluster.go` 가 런타임 옵션을 안 넘기고
  `DetectNodeProvider()` 가 docker→nerdctl→podman 을 보며 `KIND_EXPERIMENTAL_PROVIDER` 를 **보지 않는다**),
  `precondition` 으로 전제를 선언한 방법, Step 9 에서 관측한 에러.
- `wiki/terraform-stack-boundaries.md` — 왜 2스택인가(provider chaining), 폭발반경,
  `terraform_remote_state` 를 **안 쓴** 이유와 그 대가.
- `terraform/cluster/README.md` — "다른 substrate 는 형제 디렉터리로. outputs 계약만 맞추면 `platform` 은 안 바뀐다."

`wiki/_Sidebar.md` 에 두 노트를 추가한다.

- [ ] **Step 11: 커밋**

```bash
git add terraform/cluster wiki/
git commit -m "feat(cluster): kind 클러스터 스택 추가"
git push
```

---

## Task 5: 스택 B — ingress-nginx

**Files:**
- Create: `terraform/platform/{versions,provider,variables,ingress}.tf`,
  `terraform/platform/values/ingress-nginx.kind.yaml`,
  `terraform/platform/values/ingress-nginx.loadbalancer.yaml`,
  `terraform/platform/tests/validation.tftest.hcl`

**Interfaces:**
- Consumes: Task 4 outputs 4개를 **variable 로** 받는다 — `kubeconfig_path` `kube_context` `ingress_profile` `storage_class`.
- Produces: `helm_release.ingress_nginx` — Task 6 이 `depends_on` 으로 참조한다.

- [ ] **Step 1: 실패하는 테스트를 먼저 쓴다 — `tests/validation.tftest.hcl`**

```hcl
run "reject_unknown_ingress_profile" {
    command = plan
    variables {
        ingress_profile = "traefik"
    }
    expect_failures = [var.ingress_profile]
}

run "repo_url_must_be_https_git" {
    command = plan
    variables {
        repo_url = "git@github.com:Melting-Face/argocd-study.git"
    }
    expect_failures = [var.repo_url]
}
```
두 번째는 **Task 6 의 `repo_url` 을 미리 고정**한다. ArgoCD 가 무인증 public fetch 를 하려면 HTTPS 여야 한다.

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd terraform/platform && terraform init -backend=false && terraform test   # 기대: FAIL
```

- [ ] **Step 3: `versions.tf` · `provider.tf` · `variables.tf` 구현**

`hashicorp/helm ~> 3.0`, `hashicorp/kubernetes ~> 2.38`.

```hcl
provider "helm" {
    kubernetes = {
        config_path    = pathexpand(var.kubeconfig_path)
        config_context = var.kube_context    # 🔴 비우면 current-context 를 따라간다
    }
}
```
변수: `kubeconfig_path` `kube_context` `ingress_profile`(validation: `contains(["kind","loadbalancer"], ...)`)
`storage_class` `repo_url`(validation: `startswith(var.repo_url, "https://")`)
`http_host_port`(default `8081`) — Task 6 의 `argocd_url` output 이 쓴다.

🔑 `http_host_port` 가 **두 스택에 중복 선언된다.** `terraform_remote_state` 를 안 쓰기로 한 대가다(spec D1).
변수 `description` 에 *"cluster 스택의 같은 이름 변수와 값이 일치해야 한다"* 를 적고,
`local.auto.tfvars.example` 에 두 값을 나란히 둔다.

- [ ] **Step 4: 테스트 통과 확인**

```bash
terraform test   # 기대: 2 run PASS
```

- [ ] **Step 5: values 2개와 `ingress.tf` 구현**

`values/ingress-nginx.kind.yaml`:
`controller.hostPort.enabled=true`, `controller.service.type=NodePort`,
`controller.nodeSelector."ingress-ready"="true"`,
`controller.tolerations` 에 control-plane taint,
`controller.watchIngressWithoutClass=true`.

`values/ingress-nginx.loadbalancer.yaml`: `controller.service.type=LoadBalancer` 만.

`ingress.tf`:
```hcl
resource "helm_release" "ingress_nginx" {
    name             = "ingress-nginx"
    repository       = "https://kubernetes.github.io/ingress-nginx"
    chart            = "ingress-nginx"
    version          = "<고정>"
    namespace        = "ingress-nginx"
    create_namespace = true
    wait             = true    # 🔴 Task 6 의 admission webhook 경합(R4) 대비
    values = [file("${path.module}/values/ingress-nginx.${var.ingress_profile}.yaml")]
}
```

- [ ] **Step 6: apply 하고 컨트롤러가 사는지 확인**

```bash
terraform apply -var-file=local.auto.tfvars
kubectl get pods -n ingress-nginx                                        # controller Running
kubectl get validatingwebhookconfiguration | grep ingress-nginx          # webhook 등록됨
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8081          # 404 (컨트롤러는 살아있고 라우트가 없다)
terraform plan                                                           # No changes
```
`local.auto.tfvars` 는 Task 4 의 output 값을 담는다. **`.gitignore` 에 `*.tfvars` 가 있으므로 커밋되지 않는다** —
`local.auto.tfvars.example` 을 대신 커밋한다.

- [ ] **Step 7: Review Focus — DNS 폴백 경로를 문서화한다**

```bash
dig +short argocd.localtest.me    # 기대: 127.0.0.1
```
해석되지 않는 망에서는 `/etc/hosts` 에 `127.0.0.1 argocd.localtest.me podinfo.localtest.me` 를 넣는 것이 폴백이다.
`terraform/platform/README.md` 에 **판정 명령과 폴백 절차**를 적는다.

- [ ] **Step 8: 커밋**

```bash
git add terraform/platform
git commit -m "feat(platform): ingress-nginx 릴리스 추가"
git push
```

---

## Task 6: 스택 B — ArgoCD + root Application

**Files:**
- Create: `terraform/platform/argocd.tf` `terraform/platform/outputs.tf`
  `terraform/platform/values/argocd.yaml.tftpl`
- Create: `wiki/argocd-bootstrap.md`
- Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: `helm_release.ingress_nginx` (Task 5), `var.repo_url`.
- Produces: `argocd` 네임스페이스에 ArgoCD v3.5.3 과 **root Application 1개**.
  root 는 `gitops/apps/` 를 `directory.recurse` 로 읽는다 — Task 7 이 여기에 파일을 넣는다.

- [ ] **Step 1: `values/argocd.yaml.tftpl` 작성**

```yaml
configs:
    params:
        server.insecure: true          # TLS 종료는 Ingress 가 한다
server:
    ingress:
        enabled: true
        ingressClassName: nginx
        hostname: argocd.localtest.me
extraObjects:
    - apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
          name: root
          namespace: argocd
      spec:
          project: default
          source:
              repoURL: "${repo_url}"
              targetRevision: main
              path: gitops/apps
              directory: { recurse: true }
          destination: { server: https://kubernetes.default.svc, namespace: argocd }
          syncPolicy:
              automated: { prune: true, selfHeal: true }
```
🔴 **`kubernetes_manifest` 를 쓰지 않는다**(spec D5). plan 시점에 Application CRD 가 없어 plan 이 죽는다.

- [ ] **Step 2: `argocd.tf` 구현**

```hcl
resource "helm_release" "argo_cd" {
    name       = "argo-cd"
    repository = "https://argoproj.github.io/argo-helm"
    chart      = "argo-cd"
    version    = "10.9.6"           # ArgoCD v3.5.3
    namespace  = "argocd"
    create_namespace = true
    wait       = true
    depends_on = [helm_release.ingress_nginx]    # 🔴 R4 admission webhook 경합
    values     = [templatefile("${path.module}/values/argocd.yaml.tftpl", { repo_url = var.repo_url })]
}
```
`outputs.tf` 에 `argocd_url`(= `"http://argocd.localtest.me:${var.http_host_port}"`) 과
초기 비밀번호 **조회 명령 문자열**을 내보낸다(값이 아니라 명령이다 — state 에 비밀을 남기지 않는다).

- [ ] **Step 3: apply 하고 UI 가 뜨는지 확인**

```bash
terraform apply
kubectl get pods -n argocd                                                      # 전부 Running
kubectl get ingress -n argocd                                                   # ADDRESS 할당
curl -sS -o /dev/null -w '%{http_code}\n' http://argocd.localtest.me:8081        # 200
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
argocd login argocd.localtest.me:8081 --username admin --insecure
argocd app list                                                                  # root 가 보인다
terraform plan                                                                   # No changes
```
**port-forward 없이 접근되는 것**이 Step 0 의 성공 기준이다.

- [ ] **Step 4: Review Focus — 빈 `gitops/apps/` 에서 root 의 상태를 관측한다**

`gitops/apps/` 는 아직 비어 있다(Task 7 전).
```bash
argocd app get root
```
`Synced`/`Healthy` 인지 `Unknown` 인지 **관측한 값을 그대로** 기록한다. 추측하지 않는다.

- [ ] **Step 5: Review Focus — `targetRevision` 과 브랜치 불일치를 재현한다**

```bash
git switch -c throwaway-branch
mkdir -p gitops/apps && printf '# placeholder\n' > gitops/apps/.gitkeep
git add -A && git commit -m "test: 브랜치 커밋" && git push -u origin throwaway-branch
argocd app get root     # 기대: 아무 변화 없음 — targetRevision 이 main 이다
git switch main && git push origin --delete throwaway-branch && git branch -D throwaway-branch
```
🔑 **이 침묵 실패가 초보가 가장 자주 빠지는 함정이다.** 관측 결과를 위키에 적는다.

- [ ] **Step 6: Review Focus — private 전환 시 거동을 문서로만 남긴다**

저장소를 private 로 바꾸면 ArgoCD 가 무인증 fetch 에 실패한다.
**실제로 전환하지 않는다**(되돌리기 번거롭고 Actions 동작에 영향). 대신
`wiki/argocd-bootstrap.md` 에 *"public 이라 repo 자격증명을 안 넣었다. private 로 바꾸면
`argocd repo add` 로 토큰을 등록해야 하며, 그 전까지는 조용히 실패한다"* 를 **미확인으로 명시**해 적는다.
🔴 **확인하지 않은 것을 확인했다고 쓰지 않는다.**

- [ ] **Step 7: `wiki/argocd-bootstrap.md` 작성**

Terraform 2스택 apply 절차, 컴포넌트 구조(repo-server / application-controller / redis / server),
초기 비밀번호 조회, **D5 `extraObjects` 를 쓴 이유**(`kubernetes_manifest` 의 plan 시점 CRD 제약),
Step 4·5 에서 관측한 것, Step 6 의 미확인 사항.

**spec §10 실패 모드 표를 함께 옮긴다** — 무엇이 깨지면 UI 가 살아 있고 무엇이 깨지면 끊기는지,
그리고 **ingress-nginx 가 죽었을 때만 `kubectl port-forward` 가 필요한 이유**(D3 self-locking 회피).
이 표는 Phase 1 에서 테스트하지 않으므로 **「미검증」으로 표시**한다.
`_Sidebar.md` 에 추가한다.

- [ ] **Step 8: 커밋**

```bash
git add terraform/platform wiki/
git commit -m "feat(platform): ArgoCD 와 root Application 추가"
git push
```

---

## Task 7: Step 1 — 첫 Application (podinfo)

**Files:**
- Create: `gitops/apps/podinfo.yaml`,
  `gitops/manifests/podinfo/{deployment,service,ingress}.yaml`
- Create: `wiki/first-application.md`
- Modify: `wiki/_Sidebar.md`
- Delete: `gitops/apps/.gitkeep` (있다면)

**Interfaces:**
- Consumes: root Application (Task 6) 이 `gitops/apps/` 를 recurse 로 읽는다.
- Produces: `podinfo` Application. Task 8 이 이것을 드리프트 대상으로 쓴다.

- [ ] **Step 1: `gitops/manifests/podinfo/` 3개를 손으로 작성한다**

- `deployment.yaml` — `ghcr.io/stefanprodan/podinfo:<고정 태그>`, `replicas: 1`,
  containerPort `9898`, `requests`/`limits` 명시(컨벤션 `k8s.md` §2).
- `service.yaml` — ClusterIP, port `9898`.
- `ingress.yaml` — `ingressClassName: nginx`, host `podinfo.localtest.me`.

🔴 Helm·Kustomize 를 쓰지 않는다. **plain manifest 를 직접 쓰는 것이 Step 1 의 교재다.**

- [ ] **Step 2: `gitops/apps/podinfo.yaml` 작성**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: podinfo, namespace: argocd }
spec:
    project: default
    source:
        repoURL: https://github.com/Melting-Face/argocd-study.git
        targetRevision: main
        path: gitops/manifests/podinfo
    destination: { server: https://kubernetes.default.svc, namespace: podinfo }
    syncPolicy:
        syncOptions: [CreateNamespace=true]
        # automated 를 넣지 않는다 — 수동 sync 로 무엇이 언제 일어나는지 본다
```
🔑 `repoURL` 이 평문이다(D4). Task 1 의 CI 에 **`gitops/**` 의 `repoURL` 이 전부 같은지 검사하는 스텝**을 추가한다.

- [ ] **Step 3: 커밋·푸시로만 앱이 생기는지 확인한다**

```bash
git add gitops/ && git commit -m "feat(gitops): podinfo Application 추가" && git push
argocd app list                       # podinfo 등장 — kubectl 을 쓰지 않았다
argocd app get podinfo                # Sync=OutOfSync (automated 가 없다)
```

- [ ] **Step 4: 수동 sync 하고 접속한다**

```bash
argocd app sync podinfo
argocd app get podinfo                # Synced / Healthy
kubectl get ns podinfo                # CreateNamespace=true 가 만들었다
curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081   # 200
```

- [ ] **Step 5: `wiki/first-application.md` 작성**

Application CRD 의 네 부분(`source` / `destination` / `project` / `syncPolicy`),
`OutOfSync` 와 `Missing` 의 차이, `CreateNamespace=true` 를 쓴 이유(§3-1 소유권 경계),
`repoURL` 을 평문 중복으로 둔 이유와 그 대가(D4).
**Step 3~4 에서 실제로 본 상태 전이**를 명령과 함께 적는다.
`_Sidebar.md` 에 추가한다.

- [ ] **Step 6: 커밋**

```bash
git add wiki/ .github/workflows/ci.yml
git commit -m "docs(wiki): 첫 Application 노트 추가"
git push
```

---

## Task 8: Step 2 — 드리프트와 self-heal

**Files:**
- Modify: `gitops/apps/podinfo.yaml` (실험마다 `syncPolicy` 변경)
- Create: `wiki/drift-and-selfheal.md`
- Modify: `wiki/_Sidebar.md`

**Interfaces:**
- Consumes: Task 7 의 `podinfo` Application.
- Produces: 없음(관측이 산출물이다). 마지막 상태는 `automated: {prune: true, selfHeal: true}`.

- [ ] **Step 1: 실험 1 — 수동 sync 상태에서 드리프트**

```bash
kubectl scale deploy podinfo -n podinfo --replicas=5
argocd app get podinfo        # OutOfSync 전이를 관측
argocd app diff podinfo       # diff 내용을 관측
```
명령과 **관측한 출력**을 노트에 적는다.

- [ ] **Step 2: 실험 2 — `automated` 만 켠다 (selfHeal 없음)**

`gitops/apps/podinfo.yaml` 에 `syncPolicy.automated: {}` 를 넣고 커밋·푸시.
```bash
argocd app get podinfo        # 수동 드리프트가 되돌아가는가?
```
🔑 **되돌아가지 않는 것이 이 Step 의 핵심 교훈이다** — 자동 sync 는 *Git 변경을 반영*하는 것이지
*클러스터 변경을 복구*하는 것이 아니다. `automated`·`selfHeal`·`prune` 은 **독립된 3개 스위치**다.

- [ ] **Step 3: 실험 3 — `selfHeal: true` 추가**

커밋·푸시 후 다시 `kubectl scale --replicas=5`.
```bash
argocd app get podinfo        # 복구되는가. 몇 초 걸리는가 (기본 조정 주기)
```
**복구 지연을 실제로 재어** 적는다.

- [ ] **Step 4: 실험 4 — prune**

`prune: false` 인 상태에서 `gitops/manifests/podinfo/ingress.yaml` 을 삭제·커밋·푸시.
```bash
kubectl get ingress -n podinfo    # 고아 리소스가 남는가
```
그 다음 `prune: true` 로 바꿔 커밋하고 재관측한다. 끝나면 `ingress.yaml` 을 되돌린다.

- [ ] **Step 5: 실험 5 — root 에서 앱을 지운다 (cascade)**

`gitops/apps/podinfo.yaml` 을 삭제·커밋·푸시.
```bash
argocd app list                  # podinfo 가 사라지는가
kubectl get all -n podinfo       # 하위 리소스는 어떻게 되는가
kubectl get ns podinfo           # 네임스페이스는 남는가
```
관측 후 파일을 되돌리고 `prune: true, selfHeal: true` 최종 상태로 커밋한다.

- [ ] **Step 6: `wiki/drift-and-selfheal.md` 작성**

실험 5개를 **선행 상태 → 조작 → 관측** 표로 정리하고, 각 항목에 명령과 실제 출력을 붙인다.
3개 스위치의 독립성을 본문 주제로 삼는다.
🔴 **관측하지 못한 것은 비워 두고 「미확인」으로 적는다.**
`_Sidebar.md` 에 추가한다.

- [ ] **Step 7: Phase 1 완료 검증 — 전체 파괴와 복원**

```bash
terraform -chdir=terraform/platform  destroy
terraform -chdir=terraform/cluster/kind destroy
terraform -chdir=terraform/cluster/kind apply
terraform -chdir=terraform/platform  apply
# Git 이 정본이므로 podinfo 가 자동 복원되어야 한다
argocd app list
curl -sS -o /dev/null -w '%{http_code}\n' http://podinfo.localtest.me:8081   # 200
```
🔑 **이것이 spec §1-3 성공 기준 5번이자 이 프로젝트의 수렴점이다.**
복원까지 걸린 시간과 수동 개입이 있었는지를 `wiki/argocd-bootstrap.md` 말미에 적는다.

- [ ] **Step 8: 커밋**

```bash
git add gitops/ wiki/
git commit -m "docs(wiki): 드리프트와 self-heal 관측 기록"
git push
```

---

## Phase 1 완료 기준

| spec 성공 기준 | 검증 위치 |
| --- | --- |
| 1. `terraform apply` 2회로 접근 가능한 ArgoCD | Task 6 Step 3 |
| 2. Git 커밋만으로 애플리케이션 배포 | Task 7 Step 3 |
| 3. 드리프트를 self-heal 이 복구하는 것을 관측 | Task 8 Step 3 |
| 4. Airflow 배포 | **Phase 2** |
| 5. 전체 파괴 후 `apply` 2회로 복원 | Task 8 Step 7 |
| 6. 위키 10장 | **Phase 1 은 5장** (`terraform-on-kind` `terraform-stack-boundaries` `argocd-bootstrap` `first-application` `drift-and-selfheal`) |

Phase 2(Step 3~5 — 자체 Helm chart / Airflow / Helmfile 소유권 이전)는 Phase 1 완료 후 별도 계획으로 작성한다.
