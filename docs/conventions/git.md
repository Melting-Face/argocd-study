# Git 워크플로 규칙

> 이 문서는 `../dagster-study` `docs/conventions/git.md`를 이식한 것이 아니라 **골격만 빌려
> 다시 쓴 것**이다. 원본의 §1-1(브랜치 정리 자동화)·§7(worktree 의무화)은 **저널·병렬 세션
> 체계를 전제**해 들어내고([설계 문서](../superpowers/specs/2026-10-04-argocd-study-design.md) §9
> "체계가 따라와야 작동하는 것은 가져오지 않는다"), 이 저장소가 실제로 쓰는 세 가지
> (Conventional Commits·단일 `main` 브랜치·공개 저장소 경고)만 남긴다.
> 커밋 메시지 상세 규칙(type 11종·72자 제한)의 단일 출처는 루트 [`.gitlint`](../../.gitlint)다.

## 1. 브랜치 전략 — `main` 단일

- 이 저장소는 `main` 브랜치 하나로 운영한다. **직접 커밋·푸시가 승인된 작업 방식**이다
  (피처 브랜치·PR 흐름을 쓰지 않는다).
- 이 선택은 사고가 아니라 **GitOps가 전제하는 흐름**이다 — ArgoCD의 Application은
  `main`을 보고, Step 1부터 "커밋만으로 배포된다"가 성공 기준이다
  ([설계 문서](../superpowers/specs/2026-10-04-argocd-study-design.md) §1-3·§9).
- 대가는 **기계적 봉쇄가 없다**는 것이다 — `main`에 branch protection이 없고
  (`gh api repos/.../branches/main/protection` → `Branch not protected`, 실측),
  CI는 푸시 **후**에 도는 사후 신호일 뿐이다. 상세는 설계 문서 §9.

## 2. 커밋 단위 — 논리적으로 쪼갠다

- **한 커밋 = 한 관심사.** 서로 다른 type(`feat`/`fix`/`docs`/`refactor`)을 한 커밋에 섞지 않는다.
- 기능과 그 기능 전용 문서는 함께 커밋해도 되지만, 무관한 변경은 분리한다.
- 스테이징은 경로 단위로 고른다(`git add <path>`). 대화형 플래그(`-i`/`-p`)는 쓰지 않는다 —
  헝크 분리가 필요하면 파일이 여러 관심사를 담지 않게 작성해 파일 단위로 커밋을 설계한다.

## 3. 커밋 메시지 — Conventional Commits

- 형식 `type(scope): 설명` — `scope`는 선택, **설명은 한국어**, 제목 **72자 이내**.
- 허용 type 11종(`feat`·`fix`·`docs`·`style`·`refactor`·`perf`·`test`·`build`·`ci`·`chore`·`revert`) —
  정본은 [`.gitlint`](../../.gitlint).
- 파괴적 변경은 `type!: ...` 또는 본문에 `BREAKING CHANGE:` 표기.
- gitlint는 `stage: commit-msg`다 — `pre-commit run --all-files`로는 돌지 **않는다**(실측).
  로컬에서 실제로 작동시키려면 `pre-commit install --hook-type commit-msg`를 **별도로** 돌려야
  한다. 상세는 [`.pre-commit-config.yaml`](../../.pre-commit-config.yaml) gitlint 훅 주석.

## 4. 커밋 전 게이트 (pre-commit)

- 커밋 시 pre-commit이 린터·포매터·시크릿 스캔을 자동 실행한다
  (훅 목록의 단일 출처는 [`.pre-commit-config.yaml`](../../.pre-commit-config.yaml)).
- 훅 실패는 수정 후 재커밋한다. `--no-verify` 우회는 **실수 방지선을 끄는 것**이다 —
  이 저장소가 공개라 그 대가가 더 크다(§5).

## 5. 🔴 공개 저장소 = 커밋이 곧 발행이다 (R9)

이 저장소는 **public**이다. `main` 직접 푸시가 승인된 흐름이라 **PR 승인이라는 완충이 없다** —
`git push`를 누르는 순간 그 커밋은 이미 인터넷에 공개된다.

- 비밀값·자격증명·내부 전용 정보를 **커밋하기 전에** 반드시 뺀다. `gitleaks`·
  `detect-private-key` pre-commit 훅이 방어선이지만 **패턴 방어는 봉쇄가 아니다**
  (예: gitleaks 기본 allowlist가 교과서 예시 키를 흘린 사례, 설계 문서 §9 표).
- **되돌리기 어려운 작업**(force push·history 재작성·브랜치/태그 삭제)은 사전 확인 후 진행한다.
  공개 저장소에서는 force push가 이미 clone된 사본에 남은 과거를 지우지 못한다.
- 어시스턴트가 만든 커밋은 `Co-Authored-By` 트레일러를 남긴다.
- **커밋·푸시는 사용자가 요청할 때만** 수행한다(임의 커밋·푸시 금지) —
  `.claude/settings.json`의 `permissions.ask`가 `git commit`·`git push`를 승인 대상으로 둔
  이유다.

## 참고

- Conventional Commits: https://www.conventionalcommits.org/
- pre-commit: https://pre-commit.com/
- `../dagster-study` `docs/conventions/git.md` — 브랜치 전략·커밋 단위 골격의 원출처
  (worktree·브랜치 자동 정리 절은 이 저장소에 해당 체계가 없어 이식하지 않았다)
