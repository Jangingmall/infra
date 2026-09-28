# Config 없는 GuardDuty / Security Hub CSPM

## 범위와 소유권

- `environments/prod/threat_detection.tf`가 같은 AWS 계정/리전의 공통 탐지를 단독 관리한다.
- staging/prod의 VPC 이름과 무관하게 해당 계정/리전 범위에 적용된다. staging 전용 리소스가 아니다.
- 리전은 기존 AWS provider의 `var.region`을 사용한다. 적용 전 대상 계정 및 서울 리전임을 확인한다.
- GuardDuty 기본 탐지 → Security Hub CSPM findings 수집. 같은 계정/리전에서 AWS 기본 통합을 이용한다.
- AWS Config recorder/delivery channel, 보안 표준 구독, Inspector, Security Hub Essentials 업그레이드, 별도 알림 인프라는 추가하지 않는다.
- 선택 보호 기능은 비활성화한다. EKS 감사 로그/런타임 탐지 등 추가 보호까지 제공한다고 보고하지 않는다.

## 기능상 제한 및 보안팀 회신

Config를 사용하지 않으므로 Config 기반 설정 준수 점검은 제공하지 않는다.
보안 문서 5-2의 '표준 선택 후 활성화' 완료로 처리할 수 없다. 탐지 결과 수집 범위로 검수 기준을 조정하거나 예외 승인을 별도로 기록해야 한다.
5-1의 알림 담당자 및 테스트 finding 처리 확인도 코드 존재만으로 완료되지 않는다. 별도 알림 채널은 미구현이며 콘솔 findings 확인 담당자를 정해야 한다.

## 비용

- 무료 체험은 최초 사용 여부와 기능별 조건에 달려 있다. Terraform이 무료 체험 자격을 보장하지 않는다.
- AWS Config 리소스를 생성하지 않으므로 이 코드로 Config 기록을 시작하지 않는다. 다른 팀이 이미 켠 Config를 중지하지도 않는다.
- GuardDuty는 체험 종료 후 분석량 기준으로 과금된다. CSPM도 체험 종료 후 findings 수집 등 사용량에 따라 과금될 수 있다.
- detector 생성과 선택 기능 DISABLED 반영은 별도 API 호출이다. 생성 직후 및 부분 apply 실패 시 자동 활성화된 기능이 남지 않았는지 확인해야 한다.
- AWS가 새 보호 기능을 도입하면 provider 업그레이드 및 비용 검토를 통해 명시적 관리 범위를 재점검한다.
- 4~5일 검증 종료일과 무료 체험 만료일을 담당자가 기록한다. 자동 종료 기능은 없다.

## 배포 전 (이번 작업에서는 미실행)

1. 담당자·무료 체험 자격·사용 종료일·허용 비용·보안팀 검수 범위를 확인한다.
2. 기존 detector/hub가 생겼는지 재조회한다. 다른 state가 소유하면 중복 관리하지 않는다. 기존 리소스는 승인 후 import한다.
3. prod backend/변수로 `terraform init`, `terraform fmt -check`, `terraform validate`, `terraform plan`을 실행한다.
4. 이 파일만의 신규 구성은 detector 1개, 선택 기능 설정 6개, CSPM account 1개다. 전체 plan은 기존 변경도 포함하므로 모두 검토한다.
5. 앞서 CLI로 적용한 S3 계정 공개차단·EBS 기본 암호화는 별도 import가 필요하다. 이 작업에서 import하지 않았다.
6. 승인된 담당자가 apply한다. 전체 prod 인프라를 검토 없이 일괄 생성하지 않는다.

## 적용 후 완료 기준 (이번 작업에서는 미실행)

- GuardDuty detector ENABLED, 선택 기능 6종 DISABLED 확인.
- CSPM 활성화, enabled standards 빈 목록, AWS Config recorder 추가 생성 없음 확인.
- GuardDuty 통합 상태 Accepting findings 확인.
- 승인된 테스트 finding 생성 후 CSPM에서 수신 확인 (통상 수 분 소요). 테스트 결과를 담당자가 분류하고 처리한다.
- 실제 비용 화면에서 무료 체험 기간/추가 과금 여부 확인.
- 이 검증 없이 Prowler PASS 또는 서비스 연동 완료로 표시하지 않는다.

## 종료/삭제 주의

`prevent_destroy`로 환경 철거 시 우발적인 탐지 서비스 삭제를 막는다. 코드 블록 자체를 삭제하면 보호도 사라지므로 임의 제거하지 않는다.
4~5일 뒤 서비스 중지는 담당자 승인 후 별도 코드 변경 및 plan으로 진행한다. 서비스 삭제는 탐지 이력 손실을 유발할 수 있다.
선택 기능 resource를 코드에서 제거하는 것만으로 해당 기능이 비활성화되지는 않는다.

## 공식 근거

- [GuardDuty와 Security Hub CSPM 연동](https://docs.aws.amazon.com/guardduty/latest/ug/securityhub-integration.html)
- [AWS provider 5.x Security Hub account](https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/website/docs/r/securityhub_account.html.markdown)
- [GuardDuty feature 제약](https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/website/docs/r/guardduty_detector_feature.html.markdown)
