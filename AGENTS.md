# 프로젝트 AGENTS.md (argocd-study)

> 골격은 `../dagster-study`의 `AGENTS.md`에서 빌리고 내용은 이 저장소 기준으로 새로 썼다.
> 규칙 정본은 [`docs/conventions/`](docs/conventions/README.md)이고, 이 문서는 **에이전트
> 운영**(누가 무엇을 하고, 무엇이 실제로 강제되는가)을 다룬다. 코딩·커밋 컨벤션 요약은
> [`CLAUDE.md`](CLAUDE.md)를 본다.

## 작성 기준

이 문서는 **있는 것만** 적는다. `../dagster-study`에는 supervisor → worker 2계층, 저널
(기록관), 워커 경계 가드, 연구 게이트, plan 미러 같은 **에이전트 오케스트레이션 체계**가
있었다. 이 저장소에는 **그 체계가 없다** — 서브에이전트 4종과 스킬 5종만 있고, 호출·승인은
사용자(또는 메인 세션)가 직접 한다. 없는 체계를 전제한 설명을 옮기지 않는다.

## 프로젝트 목적

ArgoCD·Terraform·Helm·Helmfile을 한 저장소에서 다루며 GitOps를 체득하고, 과정을 GitHub
위키에 기록한다. 정본은 [설계 문서](docs/superpowers/specs/2026-10-04-argocd-study-design.md).

## 작업 방식

규칙을 정하거나 바꿀 때는 **작업 분해 → PDCA(Plan-Do-Check-Act)** 순으로 진행한다.
변경이 인프라(Terraform·K8s·Helm)에 걸치면 다음 관점을 점검한다:

- 소유권(누가 이 리소스의 유일한 주인인가, 설계 §3-1)
- 가역성(되돌릴 수 있는가 — 안 되면 사용자 승인부터 받는다)
- 비용·자원(이 저장소는 로컬 클러스터라 주로 **호스트 자원 경합**이 비용이다, 설계 R7)
- 관측 가능성(판정 명령이 있는가 — 없으면 Step 완료를 주장하지 않는다)

## 에이전트 구성 — 서브에이전트 4종

`.claude/agents/`에 있다. 전부 `../dagster-study`에서 **선별 이식하며 변형**했다
(원본 12종 중 4종, 설계 §7-1). 데이터 축 워커(`data-engineer`·`analyst`·`archivist` 등)와
`security`·`devops-qa`는 이 저장소에 대상이 없거나 저널 체계가 전제돼 제외했다.

| 에이전트 | 역할 | 쓰기 권한 |
| --- | --- | --- |
| `devops-engineer` | Terraform·Helm·Helmfile·ArgoCD Application 작성 | `terraform/**`·`gitops/**`·`helmfile.yaml` |
| `devops-verifier` | `argocd app get`의 Sync/Health를 선언과 대조(읽기 전용) | 없음 |
| `tech-writer` | `docs/**`·`README.md`·`wiki/**` 소유 | 문서만 |
| `researcher` | 외부 1차 출처 조사(읽기 전용) | 없음 |

호출·배정·승인은 **사용자 또는 메인 세션이 직접** 한다 — supervisor 역할을 대신하는
서브에이전트는 없다.

## 스킬 구성 — 5종

`.agents/skills/`에 원본을 두고 `.claude/skills/<name>`이 심링크한다(기존 `brainstorming`·
`writing-plans`·`subagent-driven-development`와 같은 구조). 출처·해시는
[`skills-lock.json`](skills-lock.json)이 정본이다.

| 스킬 | 쓰는 에이전트 | 용도 |
| --- | --- | --- |
| `kubernetes-specialist` | `devops-engineer`·`devops-verifier` | manifest·RBAC·네트워킹·GitOps 참고 |
| `terraform-style-guide` | `devops-engineer` | HCL 네이밍·구조 관례 |
| `terraform-test` | `devops-engineer` | `.tftest.hcl` 작성 |
| `git-commit` | 전원(사용자 승인 하에) | Conventional Commits 메시지 작성 보조 |
| `documentation` | `tech-writer` | 위키 노트·문서 구조화 |

🔴 이 5종은 `../dagster-study`가 **외부 GitHub 저장소에서 가져온 것을 다시 로컬 복사**한
것이다(`skills-lock.json`의 `source: "local:dagster-study"` + `originalSource` 필드가 원래
출처를 함께 적는다). `kubernetes-specialist`의 `references/configuration.md`는
`detect-private-key` 훅과 문자열이 일치하는 PEM 예시 머리말을 플레이스홀더로 바꿨다 —
의미는 바뀌지 않았다.

## 권한과 비가역 작업

정본은 [`.claude/settings.json`](.claude/settings.json)이다. `permissions.ask`에 걸린
명령(`git commit`·`git push`, `gh` 쓰기 서브커맨드, **`terraform apply`/`destroy`/`state rm`**,
**`helm install`/`upgrade`/`uninstall`**, **`helmfile apply`/`sync`/`destroy`**,
`kubectl apply`/`delete`, `kind delete cluster`)는 **실행 전 사용자 승인이 필요**하다.
`permissions.deny`는 `curl`/`wget`의 발신 동사(POST/PUT/PATCH/DELETE 등) 몇 개를 막는다 —
조회(GET)까지 막지는 않는다(막으면 조사 자체가 성립하지 않는다).

### 🔴 `hooks: {}`로 둔 이유

`../dagster-study`의 훅 16개는 전부 **저널·워커 경계·연구 게이트·plan 미러라는 뒤에 있는
거버넌스 체계**를 전제한다. 예를 들어 `worker_path_guard.py`는 "이 서브에이전트가 쓸 수
있는 경로"를 저널·supervisor 승인 체계와 함께 판정하고, `research_gate_guard.py`는 2왕복
조사 프로토콜(1왕복 후보 수집 → supervisor 승인 → 2왕복 페치)이 있어야 의미가 선다.

**체계 없이 스크립트만 옮기면 오동작하거나 조용히 무력화된다** — 예를 들어 경로 가드만
옮기면 "막혔다"는 신호는 뜨지만 *왜 막혔는지·누구에게 재배정해야 하는지*를 알려줄 저널이
없어, 막힌 에이전트가 우회로를 찾거나 조용히 멈추는 쪽으로 간다. 이 저장소는 **supervisor가
없으므로 그 승인 흐름 자체가 존재하지 않는다.**

⇒ **훅 0개로 시작한다.** 필요해지면(예: 서브에이전트가 반복해서 경계 밖에 쓰는 사고가 실제로
나면) 그 사고를 근거로 **하나씩** 세운다 — 한꺼번에 가져오지 않는다.

## 🔴 강제 수단과 그 한계 (정직하게)

Task 1·2에서 **실측으로 확정한 한계**가 있고, 그걸 아는 것은 이 과제를 수행한 세션뿐이라
여기 적어 다음 작업자에게 전달한다. **"막혀 있다"로 쓰지 않는다** — 기계 강제가 없는
규칙을 막혀 있다고 적으면, 다음 사람이 그 자리에 실제로 방어선이 있다고 믿는다.

| 층 | 수단 | 실효 (실측) |
| --- | --- | --- |
| 로컬 정적 | pre-commit 18훅 | 🟡 **실수 방지** — `--no-verify`로 우회 가능 |
| 커밋 메시지 | gitlint | 🟡 `stage: commit-msg`라 `pre-commit run --all-files`로는 **안 돈다**. `pre-commit install --hook-type commit-msg`를 **별도로** 깔아야 하고, **CI는 검사하지 않는다** |
| 서버 정적 | `.github/workflows/ci.yml` | 🟡 **봉쇄가 아니다.** `gh api .../branches/main/protection` → `Branch not protected`(404, 실측). main 직접 푸시라 **커밋이 공개된 뒤** 도는 사후 신호다. 유일한 실효는 **"훅을 안 깐 클론에서도 돈다"** |
| 시크릿 | gitleaks + detect-private-key | 🟡 패턴 방어는 봉쇄가 아니다. **실측: gitleaks 기본 설정의 `.+EXAMPLE$` allowlist가 교과서 예시 키(`AKIAIOSFODNN7EXAMPLE`)를 흘린다** |
| 위키 평평 구조 | `doc_lint.py`의 `check_wiki_flat()` | ✅ 기계 강제(하위 디렉터리 `.md`를 FAIL). 없었다면 그 노트는 **조용히 미러되지 않았다** |
| 위키 편집 제한 | Settings → Wikis → Restrict editing | 🔴 **자동 관측 경로 없음.** `gh api` 응답에 대응 필드가 없다(`has_wiki`·`visibility`뿐). 사람의 화면 확인에만 의존하며, **꺼져도 알 수 없다.** 재검토 트리거: 위키 이력에 미러 아닌 커밋이 보이면 다시 본다 |
| 참조형 링크·HTML `<a>` 금지 | (없음) | 🔴 **규율뿐.** `doc_lint`도 `wiki_linkify`도 인식하지 않는다 |
| `permissions.ask`(이 Task에서 신설) | `.claude/settings.json` | 🟡 **하네스가 프롬프트를 띄우는가에 달렸다** — `../dagster-study`에서 맨이름 `WebFetch`/`WebSearch` 같은 패턴이 매칭되지 않아 죽은 규칙이 된 선례가 있다(실측). 이 저장소의 20개 패턴은 **아직 라이브 프로브로 검증하지 않았다** — Task 4 이후 실제 `terraform apply` 호출에서 처음 확인된다 |

**이 표 자체가 체계의 일부다** — 다음 작업자가 "pre-commit이 있으니 안전하다"처럼 층을
뭉뚱그려 읽지 않도록, 실효를 층별로 갈라 적는다.

## 완료 보고

작업을 마치면 다음을 포함해 보고한다 — 추정으로 채우지 않는다.

- **변경 산출물**: 파일 경로와 왜(적용한 정본 조항).
- **검증 결과**: 실행한 명령과 실제 출력(못 했으면 `미실행`으로 명시).
- **경계 준수**: 비가역 명령을 실행하지 않았음, 범위 밖 파일을 건드리지 않았음.
- **남은 우려**: 확인하지 못한 것, 다음 작업자가 알아야 할 것.
