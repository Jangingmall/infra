# staging도 적용받는 계정 공통 보안 설정이다. 별도 리소스를 선언하지 않는다.
# 소유 코드: ../prod/account_security.tf / 소유 state: prod
# - S3 공개차단 4종: 같은 AWS 계정의 모든 리전에 적용.
# - EBS 기본 암호화: 같은 AWS 계정이며 prod와 동일한 var.region일 때 적용.
# staging에 resource/import를 중복 추가하거나 prod 소유 설정을 삭제하지 않는다.
# 계정/리전 분리 시에는 별도 소유권 설계를 먼저 승인받는다.
# 인계 및 검증 절차: ../../../T-20260928-account-security.md
