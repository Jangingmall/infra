# GuardDuty / Security Hub CSPM은 같은 계정/리전의 staging과 prod를 함께 관측한다.
# 소유 코드: ../prod/threat_detection.tf / 소유 state: prod.
# staging에 detector/hub를 중복 선언하거나 import하지 않는다.
# AWS Config 및 보안 표준 구독은 만들지 않는다. 탐지 결과 수집만 제공한다.
# 계정 또는 var.region이 분리되면 이 공유 계약을 다시 검토한다.
# 인계: ../../THREAT_DETECTION.md
