# 공통 코딩 규칙

> 이 문서는 `../dagster-study` `docs/conventions/general.md`(22.5KB)에서 이 저장소에 적용
> 대상이 있는 세 절(언어·들여쓰기, 파일 명명, 비밀정보)만 선별 이식한 것이다. 원본의
> 데이터·노트북·분석 전용 절(`dagster.md`·`dbt.md` 연동, `docs/analyses/**` 수치 규칙),
> 문서 정량 상한(줄 길이·표 셀·강조 마커·500줄), 시제 어휘 진단 모드(`--tense --wide`)는
> 이 저장소의 [`scripts/doc_lint.py`](../../scripts/doc_lint.py)가 **그 축을 두지 않기로
> 결정**했으므로(스크립트 머리 주석 참고) 여기서도 "집행된다"고 적지 않는다. 커밋 메시지
> 규약은 [git.md](git.md)가 정본이라 중복하지 않는다.

## 언어 (Language)

| 대상 | 언어 |
| --- | --- |
| 코드 주석 | **한국어** |
| 변수명·함수명·리소스명 등 식별자 | **영어** |
| 문서(`docs/`·`wiki/`) | **한국어** (식별자·명령어·경로는 원문) |
| 커밋 메시지 | **한국어** |

## 들여쓰기 (Indentation)

- **스페이스 4칸**을 기본으로 한다(Python·YAML 공통).
- **예외는 `.tf`(Terraform) — `terraform fmt`가 2-space로 강제**한다
  ([terraform.md](terraform.md) §3). 언어의 정규 포매터가 있으면 그것을 따르고, 전역
  규칙을 억지로 맞추지 않는다.
- 탭 문자는 쓰지 않는다.

## 파일 명명

- 저장소 전역에서 **영문 kebab-case**를 기본으로 한다(`writing-a-helm-chart.md`,
  `terraform-on-kind.md` 등). 대문자·공백·언더스코어는 쓰지 않는다.
- 고정 이름은 예외다 — `README.md`·`CLAUDE.md`·`AGENTS.md`·`Home.md`·`_Sidebar.md`는
  대문자·언더스코어를 그대로 유지한다(도구·플랫폼이 그 이름을 기대한다).
- `wiki/<slug>.md`의 `slug`는 **영문 kebab-case가 URL에 그대로 노출**된다
  ([publishing.md](publishing.md)). 한국어 파일명은 쓰지 않는다 — 제목(H1)에서 한국어를
  쓴다.

## 비밀정보 (Secrets)

- 키·토큰·비밀번호를 코드·설정 파일에 **하드코딩하지 않는다.**
- Kubernetes Secret은 참조로만 쓴다 — Application이 Secret을 **생성**하지 않고 **참조**만
  한다([k8s.md](k8s.md) §4). `kubectl create secret`으로 수동 생성한 값은 Git에 올리지 않는다.
- Terraform 변수로 비밀을 받을 때도 `.tfvars`는 커밋하지 않는다([terraform.md](terraform.md) §4).
- 이 저장소는 **public**이다 — `.env`·`.tfvars`·Secret 매니페스트가 실수로 섞여 들어가면
  그 순간 공개된다. `gitleaks`·`detect-private-key` pre-commit 훅이 방어선이지만 패턴
  방어는 봉쇄가 아니다([git.md](git.md) §5).

## 참고

- `../dagster-study` `docs/conventions/general.md` — 위 세 절의 원출처(로컬 저장소)
