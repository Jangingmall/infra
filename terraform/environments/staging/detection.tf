# ------------------------------------------------------------
# CloudTrail -> EventBridge -> SNS 보안 이벤트 알림
#
# 🔴 CloudTrail 을 EventBridge 에 "연결"하는 리소스는 없다.
#    AWS API 호출은 CloudTrail 통합으로 기본 이벤트 버스에 자동으로 들어온다.
#    우리가 만드는 것은 규칙(패턴)과 타깃(SNS)뿐이다.
#
# 🔴 리전이 갈린다 — 그리고 양방향이다.
#    IAM·STS·root 콘솔 로그인 같은 전역 서비스 이벤트는 us-east-1 에만 들어온다.
#    서울에만 규칙을 두면 IAM 변경과 root 콘솔 로그인을 못 잡는다.
#
#    반대도 참이다. root-activity 패턴은 source 를 지정하지 않고
#    userIdentity.type = Root 만 본다. 이것은 서비스가 아니라 호출자 속성이라
#    root 가 서울 리소스를 만지면(EC2 종료·S3 삭제·EKS 삭제) 그 이벤트는
#    ap-northeast-2 에 들어온다. us-east-1 에만 두면 계정 탈취 시 가장 위험한
#    "root 로 리전 리소스 파괴"를 통째로 놓친다.
#    -> root-activity 규칙은 두 리전 모두에 둔다. 리전이 갈리므로 중복 알림은 없다.
#
#    iam-user-and-key 는 source = aws.iam 으로 전역 서비스를 고정하므로
#    us-east-1 에만 둔다. 서울에 둬도 매칭될 이벤트가 없다.
#
#    EventBridge 타깃은 규칙과 같은 리전이어야 하므로 SNS 토픽도 리전마다 만든다.
#
# 🔴 계정 단위 관심사인데 staging 에 둔 이유
#    root·IAM·CloudTrail 은 환경이 아니라 계정 것이다. 원래는 prod 가 맞지만
#    prod 는 apply 하지 않는 방침이라(9/28) 거기 두면 영구히 동작하지 않는다.
#    PR #88(GuardDuty·Security Hub)이 정확히 그 이유로 -target apply 가 필요했다.
#
# 🔴 이벤트 패턴은 detection/patterns/*.json 에 둔다.
#    scripts/validate-detection.sh 가 같은 파일을 AWS TestEventPattern 으로
#    검증하므로 코드와 테스트가 어긋날 수 없다.
#    (modules/alb 의 policies/alb-controller-policy.json 과 같은 방식)
#
# 🔴 10/6 종료 시 삭제 대상 — 종료 체크리스트에 추가해야 한다.
#    확인하지 않은 SNS 구독은 48시간 뒤 자동 소멸한다.
#
# 💰 AWS 서비스 이벤트 매칭은 무료. SNS 이메일은 월 1,000건 무료.
#    평시 발생 0건을 전제로 고른 규칙이라 사실상 $0.
# ------------------------------------------------------------

locals {
  # 평시에 절대 일어나지 않아야 하는 것만 고른다.
  # 보안그룹 변경·노드그룹 스케일은 apply 와 야간 정지마다 나서 제외했다.

  # 서울 — 리전 서비스
  detection_rules_apne2 = {
    cloudtrail-tampering = {
      description   = "CloudTrail 감사 로그 변조 시도"
      event_pattern = file("${path.module}/detection/patterns/cloudtrail-tampering.json")
    }

    # 🔑 10/28 무료 기간 종료 전 수동 비활성화를 잊으면 과금되고,
    #    반대로 실수로 미리 끄는 것도 막아야 한다. 양방향으로 알려준다.
    threat-detection-disable = {
      description   = "GuardDuty·Security Hub 비활성화 시도"
      event_pattern = file("${path.module}/detection/patterns/threat-detection-disable.json")
    }

    eks-cluster-destructive = {
      description   = "EKS 클러스터·노드그룹·애드온 삭제 시도"
      event_pattern = file("${path.module}/detection/patterns/eks-cluster-destructive.json")
    }

    # 🔑 버지니아와 같은 패턴 파일을 공유한다. 전역 이벤트는 us-east-1 이 잡고,
    #    root 가 서울 리소스를 만든/지운 이벤트는 여기가 잡는다.
    root-activity = {
      description   = "root 계정이 서울 리전 리소스를 조작 — 평시 0건이어야 한다"
      event_pattern = file("${path.module}/detection/patterns/root-activity.json")
    }
  }

  # 버지니아 — 전역 서비스 (IAM·STS·root 로그인)
  detection_rules_use1 = {
    root-activity = {
      description   = "root 계정 콘솔 로그인·전역 서비스 사용 — 평시 0건이어야 한다"
      event_pattern = file("${path.module}/detection/patterns/root-activity.json")
    }

    # 🔑 보안 회신의 "IAM 사용자 1개·액세스 키 0개·SSO 전용" 증빙을 탐지로 보장한다.
    iam-user-and-key = {
      description   = "IAM 사용자·액세스키 생성 — SSO 전용 방침 위반"
      event_pattern = file("${path.module}/detection/patterns/iam-user-and-key.json")
    }
  }
}

module "detection_apne2" {
  source = "../../modules/detection"

  project      = var.project
  env          = var.env
  name_suffix  = "apne2"
  alert_emails = var.detection_alert_emails
  rules        = local.detection_rules_apne2
}

module "detection_use1" {
  source = "../../modules/detection"

  providers = {
    aws = aws.us_east_1
  }

  project      = var.project
  env          = var.env
  name_suffix  = "use1"
  alert_emails = var.detection_alert_emails
  rules        = local.detection_rules_use1
}
