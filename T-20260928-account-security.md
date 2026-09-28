# 계정 공통 보안 설정 코드 편입

## [기획]
- 목표: CLI로 먼저 켠 S3 계정 공개차단 및 EBS 기본 암호화를 Terraform 코드로 관리할 준비.
- 근거: 사용자 2026-09-28 승인. AWS 변경/import/apply 없이 코드만 작성. 기준 SHA `47bfef8`.
- 관리 계약: staging/prod는 같은 계정과 리전을 사용하며, 공통 설정의 state 소유자는 prod 한 곳. staging에는 중복 resource/import 없음.
- 수정 허용 파일: 이 작업 문서, `terraform/environments/prod/account_security.tf`, `terraform/environments/staging/account_security.tf` (모두 신규 파일).
- 계정 ID는 기존 `data.aws_caller_identity.current.account_id`, 리전은 기존 provider의 `var.region` 사용. 보호 옵션 true는 사용자 승인된 보안 기준이며 환경별 임의 비활성화 변수는 추가하지 않음.
- AC-1: prod에서 S3 공개차단 4종 및 EBS 기본 암호화 선언.
- AC-2: staging에 중복 소유 없이 공유 범위 명시.
- AC-3: 두 리소스 prevent_destroy, 기존 KMS 키/볼륨/타 담당 코드 미변경.
- AC-4: 이후 담당자가 사용할 import/plan 절차와 파괴적 동작 주의사항 문서화.
- 검증: 변경 파일 정적 점검, git diff --check. Terraform 실행기가 있으면 fmt -check/validate. 실환경 plan/import/apply는 이번 범위 제외.
- 커밋/push/PR 생성 없음.

## 추후 인계 절차 (이번에는 실행하지 않음)

prod 계정/리전 및 기존 state 소유권을 먼저 확인한다. 다른 state가 관리 중이면 중복 import하지 않는다.
기존 prod backend/변수로 초기화한 뒤, prod 디렉터리에서 아래 명령을 실행한다.
`<확인한-AWS-계정-ID>`는 실행 전 실제 대상 계정으로 치환해야 한다.

```text
terraform import aws_s3_account_public_access_block.shared <확인한-AWS-계정-ID>
terraform import aws_ebs_encryption_by_default.shared default
terraform plan
```

- import는 state를 변경하므로 담당자 승인 후 수행한다. staging에서는 실행하지 않는다.
- 이미 활성화한 설정이므로 이 두 리소스의 plan은 변경 없음이 기대된다. 전체 plan에 다른 변경이 있으면 별도 검토하고 apply하지 않는다.
- EBS 기본 KMS 키는 이 코드에서 관리하거나 교체하지 않는다. 기존 볼륨을 재암호화하지 않는다.
- S3는 계정 전역, EBS는 prod provider가 선택한 리전 범위. staging 계정/리전이 달라지면 현재 공유 계약을 재검토한다.
- prevent_destroy가 있는 동안 prod destroy도 이 두 리소스 때문에 중단될 수 있다. 계정 공통 설정은 환경 철거와 함께 삭제하지 않는다.
- 리소스 블록 자체를 코드에서 제거하면 prevent_destroy도 사라진다. 제거/이관은 별도 승인과 state 소유권 인계가 필요하다.
- 공식 AWS provider 문서: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_account_public_access_block
- EBS 삭제 시 기본 암호화가 꺼지는 동작: https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/website/docs/r/ebs_encryption_by_default.html.markdown

## [개발 요약]
- 기준 `47bfef8` → 미커밋 추가 파일 기준.
- prod/account_security.tf: 계정 공개차단 4종 및 리전 EBS 기본 암호화, 삭제 방지 선언.
- staging/account_security.tf: 적용 범위와 prod 단일 소유 계약 명시. 리소스 중복 생성 없음.
- 기존 파일 및 타 담당 코드 수정 없음. AWS 설정/state 변경 없음.
- 검증 결과는 아래에 추가한다.
- 정적 검사 PASS: prod 리소스 2개, 보호 옵션 5개 true, prevent_destroy 2개, staging resource/import 중복 없음, 계정 ID 동적 참조.
- 신규 tf 파일 각각 `git diff --no-index --check -- NUL <파일>` 통과.
- AC-1~4 코드/문서 기준 충족. Terraform 실행기가 PATH에 없어 fmt/validate 미실행. 실환경 plan/import/apply 미실행.
- 이 작업 문서는 기존 Git ignore 규칙으로 추적되지 않는 로컬 인계 문서다. 기존 ignore 규칙은 변경하지 않음.

## [개발 요약] 2026-09-28 커밋·푸시 인계

- 사용자 최신 지시로 보안 작업 커밋·push 허용. 기존의 커밋 금지는 이번 인계에 한해 대체된다. PR 생성 및 AWS 적용은 제외.
- 최신 origin/main `b546a67` 기준 `codex/security-baseline` 브랜치로 분리. 기존 커밋된 코드 변경 없음.
- 참조 문서 누락 방지를 위해 이 작업 문서도 명시적으로 Git 추적에 포함. ignore 규칙 자체는 변경하지 않음.
- 정적 검사 및 staged diff 공백 검사 통과. Terraform 실행기가 없어 fmt/validate/plan 미실행. 배포 전 import/state 소유권 확인 및 전체 plan 검토 필요.
