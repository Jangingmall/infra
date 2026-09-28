# GuardDuty / Security Hub CSPM — Config 없는 탐지 결과 수집

## [기획]
- 근거: 2026-09-28 사용자 요청. GuardDuty 및 Security Hub CSPM 추가, AWS Config 미사용. 앞선 코드-only 작업 범위 유지.
- 기준 SHA: 47bfef8. 기존 account_security.tf 미커밋 변경 보존.
- 허용 파일: 이 문서, prod/threat_detection.tf, staging/threat_detection.tf, terraform/THREAT_DETECTION.md.
- 경로의 prod/staging은 terraform/environments 아래를 뜻한다.
- 소유권: 같은 계정/리전에서 prod state 단독 소유. staging 중복 생성 없음.
- AC-1: GuardDuty 기본 탐지 활성화 선언, 선택 보호 기능은 명시적으로 비활성화.
- AC-2: Security Hub CSPM 활성화 선언, 기본 표준/새 control 자동 활성화 false. AWS Config/표준 구독 생성 없음.
- AC-3: 계정/리전 하드코딩 없음, 기존 provider 사용. 서비스 삭제 방지 선언.
- AC-4: 무료 체험 조건, Config 미사용의 제한, 배포 후 검증 및 종료 시 검토 절차 기록.
- 금지: AWS 변경, import/apply, 샘플 finding 생성, Git 커밋/push, 타 담당 코드 변경.

## [개발 요약]
- prod/threat_detection.tf: detector, 선택 기능 DISABLED, CSPM 표준 자동 활성화 방지.
- staging/threat_detection.tf: 같은 계정/리전 공유 계약.
- terraform/THREAT_DETECTION.md: 배포/비용/한계/검증 인계.
- 기준 SHA → 미커밋 diff. 기존 사용자 변경 보존. 타 담당 코드 침범 없음.
- 정적 검사 PASS: 두 서비스 선언, 기본 표준/자동 control 비활성화, 선택 기능 DISABLED, Config/standards 리소스 없음, staging 중복 소유 없음, 삭제 방지 2개.
- 신규 tf 파일 `git diff --no-index --check` 통과 (저장소 CRLF 변환 경고만 존재).
- Terraform 실행기 부재로 fmt/validate/plan 미실행. 실환경 연동 및 무료 체험 미검증.
- AWS 활성화/import/apply 및 Git 커밋/push 미실행.
- 작업 문서와 terraform/THREAT_DETECTION.md는 기존 ignore 규칙에 의해 로컬 파일로만 존재한다. 향후 공유/커밋 시 문서 추적 여부를 별도로 확인해야 한다. ignore 규칙은 변경하지 않음.

## [개발 요약] 2026-09-28 커밋·푸시 인계

- 사용자 최신 지시로 보안 작업 커밋·push 허용. 기존의 커밋 금지는 이번 인계에 한해 대체된다. PR 생성 및 AWS 적용은 제외.
- 최신 origin/main `b546a67` 기준 `codex/security-baseline` 브랜치. 변경은 보안 신규 파일과 그 인계 문서에 한정.
- 이 작업 문서 및 terraform/THREAT_DETECTION.md를 명시적으로 Git 추적에 포함. ignore 규칙 자체는 보존.
- 정적 검사 및 staged diff 공백 검사 통과. Terraform 실행기가 없어 fmt/validate/plan 미실행. 무료 체험 자격 및 실서비스 연동 미검증.
