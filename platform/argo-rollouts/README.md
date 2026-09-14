# Argo Rollouts

장인몰 Backend의 Progressive Delivery를 관리하기 위한
Argo Rollouts 플랫폼 설정을 관리한다.

## 역할

Argo Rollouts는 다음 기능을 담당한다.

- Kubernetes Rollout CRD 제공
- Backend Blue/Green 배포 제어
- Active / Preview Service 전환
- ReplicaSet 상태 감시
- 수동 Promotion
- Rollback 및 이전 ReplicaSet 관리
- Dashboard를 통한 Rollout 상태 시각화

실제 Backend Rollout 정의는
`k8s/base/backend/`에서 관리한다.

## 설치 Namespace

`argo-rollouts`

Argo CD와 Argo Rollouts는 서로 다른 역할을 담당하므로
별도 Namespace로 분리한다.

구조:

    argocd
    └─ Argo CD

    argo-rollouts
    ├─ Argo Rollouts Controller
    └─ Argo Rollouts Dashboard

    app
    ├─ Backend Rollout
    ├─ backend-active
    └─ backend-preview

## Version

- Helm Chart: `2.43.1`
- Argo Rollouts: `v1.10.0`

Helm 설치 시 버전을 명시적으로 고정한다.

## CRD

Helm Chart를 통해 Argo Rollouts CRD를 설치한다.

- `installCRDs: true`
- `keepCRDs: true`

Helm Release가 제거되더라도 기존 Rollout 리소스를 보호할 수 있도록
CRD는 유지한다.

## Controller Scope

`clusterInstall: true`

Controller는 `argo-rollouts` Namespace에 설치되지만,
`app` Namespace를 포함한 클러스터 전체 Rollout을 감시한다.

## Dashboard

Rollout 배포 상태를 시각적으로 확인하기 위해 Dashboard를 배포한다.

초기에는 관리 UI를 외부에 직접 노출하지 않고
ClusterIP와 `kubectl port-forward`를 통해 접근한다.

설정:

    dashboard:
      enabled: true
      readonly: true
      replicas: 1

      service:
        type: ClusterIP
        port: 3100
        targetPort: 3100

Dashboard는 초기에는 조회 전용으로 사용한다.

실제 EKS 배포 후:

    kubectl port-forward \
      -n argo-rollouts \
      svc/argo-rollouts-dashboard \
      3100:3100

브라우저:

    http://localhost:3100

Dashboard를 Public LoadBalancer 또는 외부 ALB에 직접 연결하지 않는다.

## Metrics

Argo Rollouts Controller의 Metrics Service를 생성한다.

    controller:
      metrics:
        enabled: true

Prometheus Operator 구성이 완료되기 전까지
ServiceMonitor는 생성하지 않는다.

    serviceMonitor:
      enabled: false

## Backend Blue/Green

Backend는 Active / Preview Service 기반 Blue/Green 전략을 사용한다.

운영 트래픽:

    사용자
      ↓
     ALB
      ↓
    backend-active
      ↓
    Active ReplicaSet

새 버전 검증:

    backend-preview
      ↓
    Preview ReplicaSet

현재 단계에서는 Argo Rollouts가 AWS TargetGroup을 직접 제어하지 않는다.

    controller:
      awsVerifyTargetGroup: false

따라서 외부 Traffic Provider용 추가 RBAC도 현재는 비활성화한다.

    providerRBAC:
      enabled: false

ALB Traffic Routing 또는 Canary 전략은
실제 EKS / ALB 연동 단계에서 별도로 검증한다.

## 설치 순서

    1. argo-rollouts Namespace
            ↓
    2. Argo Rollouts CRD
            ↓
    3. Argo Rollouts Controller
            ↓
    4. Argo Rollouts Dashboard
            ↓
    5. Backend Rollout
            ↓
    6. backend-active / backend-preview

Backend Rollout을 적용하기 전에
Argo Rollouts CRD와 Controller가 먼저 준비되어 있어야 한다.
